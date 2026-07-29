#!/usr/bin/env bash
# section-whisper-sidecar.sh -- issue #424: whisper.cpp sidecar capability
# (install + model download + process lifecycle behind capability.yaml +
# provisioning check, SPEC-ASSISTANT.md §13.2, docs/spec-deltas/applied/
# ast-051.md, docs/design/ast-E6.md). Sourced by run-tests.sh; do not run
# standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2046  # every `env $(ws_env ...)` call site below WANTS
# ws_env's output word-split into separate KEY=value tokens for `env`; its
# values are always mktemp-derived paths or plain integers, never
# space-containing, so this is safe unquoted (see ws_env's own comment).
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted
# on purpose -- they're expanded when eval'd inside the function, not at call
# site (same directive/reason as section-neural-view-lifecycle.sh).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== whisper-sidecar capability (issue #424: SPEC-ASSISTANT.md §13.2, install + lifecycle + provisioning) =="

WS_SCRIPTS="$PLUGIN/scripts"
WS_SKILL_DIR="$PLUGIN/skills/whisper-sidecar"
WS_STUB_BIN="$FIX/stub-whisper-server"
WS_STUB_SERVER="$WS_STUB_BIN/fake-whisper-server"

# ------------------------------------------------------------------------
# Process-lifecycle safety net (issue #424 brief: "never leave orphan
# processes in tests -- enumerate-state-machine-exits -- every start path
# needs a teardown; kill in test cleanup traps"). WS_LIVE_PIDS collects
# every pid this section EVER caused to be spawned (via `start` or a
# direct stub invocation); the EXIT trap best-effort SIGKILLs all of them
# regardless of whether the section's own tests passed, failed, or the
# suite aborted early -- registered on the CALLER's (run-tests.sh's) shell
# exit, the same `trap ... EXIT` idiom section-preflight.sh already uses
# for tmpdir cleanup.
WS_LIVE_PIDS=()
ws_track_pid() { WS_LIVE_PIDS+=("$1"); }
ws_cleanup() {
    local pid
    for pid in "${WS_LIVE_PIDS[@]-}"; do
        [[ -n "$pid" ]] && kill -9 "$pid" >/dev/null 2>&1 || true
    done
}
trap ws_cleanup EXIT

# ws_env <state_dir> <port> -- prints an `export`-ready env block wiring
# every hermetic override whisper_sidecar.py understands: a throwaway
# state dir, a per-test random port (never the real 8737 -- house
# lesson hermetic-path-fixtures-for-cli-tests, mirrors _rand_port's
# per-suite port-slice discipline), the stub binary as the install
# source, and a short start timeout so a never_bind test doesn't stall
# the suite.
ws_env() {
    local state="$1" port="$2"
    # All values here are mktemp-derived paths or plain integers -- never
    # contain spaces/shell metacharacters -- so plain KEY=value tokens
    # (word-split by the `env $(ws_env ...)` call sites below) are safe
    # without %q quoting.
    printf 'WHISPER_SIDECAR_STATE_DIR=%s WHISPER_SIDECAR_PORT=%s WHISPER_SIDECAR_BINARY_SRC=%s WHISPER_SIDECAR_MODEL_SRC=%s WHISPER_SIDECAR_START_TIMEOUT_SECONDS=2' \
        "$state" "$port" "$WS_STUB_SERVER" "$WS_MODEL_SRC"
}

WS_TMPD="$(mktemp -d)"
WS_MODEL_SRC="$WS_TMPD/fake-model.bin"
printf 'fake model bytes\n' >"$WS_MODEL_SRC"

# ------------------------------------------------------------------------
echo "-- unit: capability.yaml -- structurally valid, loads via capability_index.load_capability --"
out="$(PYTHONPATH="$WS_SCRIPTS" python3 - <<PY
from assistant import capability_index as ci
cap = ci.load_capability("$WS_SKILL_DIR")
print("IS_CAPABILITY", isinstance(cap, ci.Capability))
print("VERSION", cap.version)
print("EXEC", cap.invoke.get("exec"))
print("ACTION_ALLOWLIST", cap.invoke.get("params", {}).get("action", {}).get("allowlist"))
print("TTL", cap.provisioning.get("ttlSeconds"))
PY
)"
check "capability.yaml: loads as a valid Capability, not a CapabilityError" "IS_CAPABILITY True" "$out"
check "capability.yaml: version 1" "VERSION 1" "$out"
check "capability.yaml: invoke.exec templates the skill_dir and action tokens" \
    "EXEC ['python3', '{skill_dir}/whisper_sidecar.py', '{action}']" "$out"
check "capability.yaml: action is schema-validated via an allowlist" \
    "ACTION_ALLOWLIST ['install', 'start', 'stop', 'status']" "$out"
check "capability.yaml: provisioning TTL is set (not per-turn rechecked)" "TTL 30" "$out"

# ------------------------------------------------------------------------
echo "-- unit: whisper_sidecar.py -- fresh state: status reports NOT INSTALLED, specific + actionable --"
WS_P1="$(_rand_port)"; WS_S1="$WS_TMPD/state1"
out="$(env $(ws_env "$WS_S1" "$WS_P1") python3 "$WS_SKILL_DIR/whisper_sidecar.py" status 2>&1)"; rc=$?
check_rc "status (fresh): exits nonzero" 1 "$rc"
check "status (fresh): names install as the fix action" "run the whisper-sidecar capability's 'install' action" "$out"

# ------------------------------------------------------------------------
echo "-- unit: whisper_sidecar.py -- install fetches from a LOCAL fixture path (no network), is idempotent --"
out="$(env $(ws_env "$WS_S1" "$WS_P1") python3 "$WS_SKILL_DIR/whisper_sidecar.py" install 2>&1)"; rc=$?
check_rc "install: exits 0" 0 "$rc"
check "install: reports the installed binary/model paths" "installed (binary=" "$out"
check "install: binary is actually present after install" "$([[ -x "$WS_S1/bin/whisper-server" ]] && echo yes || echo no)" "yes"
check "install: model is actually present after install" "$([[ -f "$WS_S1/models/ggml-model.bin" ]] && echo yes || echo no)" "yes"

out2="$(env $(ws_env "$WS_S1" "$WS_P1") python3 "$WS_SKILL_DIR/whisper_sidecar.py" install 2>&1)"; rc2=$?
check_rc "install: a second call is idempotent, still exits 0" 0 "$rc2"
check "install: a second call reports already-installed, doesn't refetch" "already installed" "$out2"

echo "-- unit: whisper_sidecar.py -- install failure (bad source) is specific, never a raw traceback --"
WS_S_BADINSTALL="$WS_TMPD/state-badinstall"
out="$(WHISPER_SIDECAR_STATE_DIR="$WS_S_BADINSTALL" WHISPER_SIDECAR_BINARY_SRC="/definitely/not/a/real/path" WHISPER_SIDECAR_MODEL_SRC="$WS_MODEL_SRC" python3 "$WS_SKILL_DIR/whisper_sidecar.py" install 2>&1)"; rc=$?
check_rc "install (bad binary source): exits nonzero" 1 "$rc"
check "install (bad binary source): names the offending source, no traceback" "could not fetch whisper-server binary from '/definitely/not/a/real/path'" "$out"
check_absent "install (bad binary source): no raw Python traceback leaks to the operator" "Traceback (most recent call last)" "$out"

# ------------------------------------------------------------------------
echo "-- unit: whisper_sidecar.py -- installed but not running: status is specific, distinct from not-installed --"
out="$(env $(ws_env "$WS_S1" "$WS_P1") python3 "$WS_SKILL_DIR/whisper_sidecar.py" status 2>&1)"; rc=$?
check_rc "status (installed, not running): exits nonzero" 1 "$rc"
check "status (installed, not running): names start as the fix action" "run the whisper-sidecar capability's 'start' action" "$out"
check_absent "status (installed, not running): never claims it's not installed" "not installed" "$out"

# ------------------------------------------------------------------------
echo "-- unit: whisper_sidecar.py -- start spawns a detached process that becomes healthy; status then reports healthy --"
out="$(env $(ws_env "$WS_S1" "$WS_P1") python3 "$WS_SKILL_DIR/whisper_sidecar.py" start 2>&1)"; rc=$?
check_rc "start: exits 0 once healthy" 0 "$rc"
check "start: reports the healthy port" "started: whisper-server is running on 127.0.0.1:$WS_P1" "$out"
WS_PID1="$(cat "$WS_S1/whisper-server.pid" 2>/dev/null || true)"
ws_track_pid "$WS_PID1"
check "start: the spawned process is genuinely alive" "$(kill -0 "$WS_PID1" 2>/dev/null && echo alive || echo dead)" "alive"

out="$(env $(ws_env "$WS_S1" "$WS_P1") python3 "$WS_SKILL_DIR/whisper_sidecar.py" status 2>&1)"; rc=$?
check_rc "status (after start): exits 0" 0 "$rc"
check "status (after start): reports healthy" "healthy: whisper-server is running on 127.0.0.1:$WS_P1" "$out"

echo "-- unit: whisper_sidecar.py -- start is idempotent -- never spawns a second instance while already healthy --"
out="$(env $(ws_env "$WS_S1" "$WS_P1") python3 "$WS_SKILL_DIR/whisper_sidecar.py" start 2>&1)"; rc=$?
check_rc "start (already running): exits 0" 0 "$rc"
check "start (already running): reports already-running, doesn't re-spawn" "already running on 127.0.0.1:$WS_P1" "$out"
WS_PID1B="$(cat "$WS_S1/whisper-server.pid" 2>/dev/null || true)"
check "start (already running): the SAME pid is still tracked (no second spawn)" "$WS_PID1B" "$WS_PID1"

# ------------------------------------------------------------------------
echo "-- unit: whisper_sidecar.py -- stop terminates the process, clears the pidfile, is idempotent --"
out="$(env $(ws_env "$WS_S1" "$WS_P1") python3 "$WS_SKILL_DIR/whisper_sidecar.py" stop 2>&1)"; rc=$?
check_rc "stop: exits 0" 0 "$rc"
check "stop: reports stopped" "stopped" "$out"
check "stop: the process is genuinely gone" "$(kill -0 "$WS_PID1" 2>/dev/null && echo alive || echo dead)" "dead"
check "stop: the pidfile is removed" "$([[ -f "$WS_S1/whisper-server.pid" ]] && echo present || echo absent)" "absent"

out="$(env $(ws_env "$WS_S1" "$WS_P1") python3 "$WS_SKILL_DIR/whisper_sidecar.py" stop 2>&1)"; rc=$?
check_rc "stop (already stopped): still exits 0 (idempotent)" 0 "$rc"
check "stop (already stopped): reports not running" "not running" "$out"

# ------------------------------------------------------------------------
echo "-- unit: whisper_sidecar.py -- a stale pidfile (process already dead) is detected and cleared, not misreported --"
WS_S_STALE="$WS_TMPD/state-stale"; WS_P_STALE="$(_rand_port)"
mkdir -p "$WS_S_STALE/bin" "$WS_S_STALE/models"
cp "$WS_STUB_SERVER" "$WS_S_STALE/bin/whisper-server"; chmod +x "$WS_S_STALE/bin/whisper-server"
cp "$WS_MODEL_SRC" "$WS_S_STALE/models/ggml-model.bin"
echo "999999" >"$WS_S_STALE/whisper-server.pid"  # a pid that (almost certainly) does not exist
out="$(WHISPER_SIDECAR_STATE_DIR="$WS_S_STALE" WHISPER_SIDECAR_PORT="$WS_P_STALE" python3 "$WS_SKILL_DIR/whisper_sidecar.py" status 2>&1)"; rc=$?
check_rc "status (stale pidfile): exits nonzero" 1 "$rc"
check "status (stale pidfile): reports not running, names the cleared stale pidfile" \
    "not running (a stale pidfile was cleared)" "$out"
check "status (stale pidfile): the stale pidfile is actually removed" \
    "$([[ -f "$WS_S_STALE/whisper-server.pid" ]] && echo present || echo absent)" "absent"

echo "-- unit: whisper_sidecar.py -- port occupied by an UNRELATED process (dead pidfile pid) is refused, never force-started --"
WS_P_CONFLICT="$(_rand_port)"
env WHISPER_STUB_MODE=ok python3 "$WS_STUB_SERVER" --port "$WS_P_CONFLICT" --model x &
WS_BYSTANDER_PID=$!
ws_track_pid "$WS_BYSTANDER_PID"
# give the bystander a moment to actually bind
for _i in 1 2 3 4 5 6 7 8 9 10; do
    (exec 3<>"/dev/tcp/127.0.0.1/$WS_P_CONFLICT") 2>/dev/null && break
    sleep 0.2
done
WS_S_CONFLICT="$WS_TMPD/state-conflict"
mkdir -p "$WS_S_CONFLICT/bin" "$WS_S_CONFLICT/models"
cp "$WS_STUB_SERVER" "$WS_S_CONFLICT/bin/whisper-server"; chmod +x "$WS_S_CONFLICT/bin/whisper-server"
cp "$WS_MODEL_SRC" "$WS_S_CONFLICT/models/ggml-model.bin"
echo "999998" >"$WS_S_CONFLICT/whisper-server.pid"  # dead pid, but the port IS genuinely occupied
out="$(WHISPER_SIDECAR_STATE_DIR="$WS_S_CONFLICT" WHISPER_SIDECAR_PORT="$WS_P_CONFLICT" WHISPER_SIDECAR_START_TIMEOUT_SECONDS=2 python3 "$WS_SKILL_DIR/whisper_sidecar.py" start 2>&1)"; rc=$?
check_rc "start (port held by a stranger): refuses, exits nonzero" 1 "$rc"
check "start (port held by a stranger): names the port conflict, never silently rebinds/kills it" \
    "is occupied by an unrelated process" "$out"
check "start (port held by a stranger): the bystander process is still alive (never touched)" \
    "$(kill -0 "$WS_BYSTANDER_PID" 2>/dev/null && echo alive || echo dead)" "alive"
kill -9 "$WS_BYSTANDER_PID" >/dev/null 2>&1 || true

# ------------------------------------------------------------------------
echo "-- unit: whisper_sidecar.py -- start gives up honestly if the server never becomes healthy (never_bind) --"
WS_S_NEVER="$WS_TMPD/state-never"; WS_P_NEVER="$(_rand_port)"
mkdir -p "$WS_S_NEVER/bin" "$WS_S_NEVER/models"
cp "$WS_STUB_SERVER" "$WS_S_NEVER/bin/whisper-server"; chmod +x "$WS_S_NEVER/bin/whisper-server"
cp "$WS_MODEL_SRC" "$WS_S_NEVER/models/ggml-model.bin"
out="$(WHISPER_SIDECAR_STATE_DIR="$WS_S_NEVER" WHISPER_SIDECAR_PORT="$WS_P_NEVER" WHISPER_SIDECAR_START_TIMEOUT_SECONDS=1 WHISPER_STUB_MODE=never_bind python3 "$WS_SKILL_DIR/whisper_sidecar.py" start 2>&1)"; rc=$?
check_rc "start (server never binds): exits nonzero, never hangs the suite" 1 "$rc"
check "start (server never binds): reports the bounded timeout, points at the log for diagnosis" \
    "did not become healthy on port $WS_P_NEVER within" "$out"
WS_NEVER_PID="$(cat "$WS_S_NEVER/whisper-server.pid" 2>/dev/null || true)"
[[ -n "$WS_NEVER_PID" ]] && ws_track_pid "$WS_NEVER_PID"

# ------------------------------------------------------------------------
echo "-- unit: whisper_sidecar.py -- stop escalates to SIGKILL against a SIGTERM-ignoring process --"
WS_S_STUBBORN="$WS_TMPD/state-stubborn"; WS_P_STUBBORN="$(_rand_port)"
mkdir -p "$WS_S_STUBBORN/bin" "$WS_S_STUBBORN/models"
cp "$WS_STUB_SERVER" "$WS_S_STUBBORN/bin/whisper-server"; chmod +x "$WS_S_STUBBORN/bin/whisper-server"
cp "$WS_MODEL_SRC" "$WS_S_STUBBORN/models/ggml-model.bin"
out="$(WHISPER_SIDECAR_STATE_DIR="$WS_S_STUBBORN" WHISPER_SIDECAR_PORT="$WS_P_STUBBORN" WHISPER_SIDECAR_START_TIMEOUT_SECONDS=3 WHISPER_STUB_MODE=ignore_sigterm python3 "$WS_SKILL_DIR/whisper_sidecar.py" start 2>&1)"; rc=$?
check_rc "start (stubborn server): still exits 0 (it DOES become healthy, it just won't die politely later)" 0 "$rc"
WS_STUBBORN_PID="$(cat "$WS_S_STUBBORN/whisper-server.pid" 2>/dev/null || true)"
ws_track_pid "$WS_STUBBORN_PID"

out="$(WHISPER_SIDECAR_STATE_DIR="$WS_S_STUBBORN" WHISPER_SIDECAR_PORT="$WS_P_STUBBORN" python3 "$WS_SKILL_DIR/whisper_sidecar.py" stop 2>&1)"; rc=$?
check_rc "stop (SIGTERM-ignoring process): still exits 0 -- SIGKILL escalation succeeds" 0 "$rc"
check "stop (SIGTERM-ignoring process): reports stopped despite the process ignoring SIGTERM" "stopped" "$out"
check "stop (SIGTERM-ignoring process): the process is genuinely gone after SIGKILL escalation" \
    "$(kill -0 "$WS_STUBBORN_PID" 2>/dev/null && echo alive || echo dead)" "dead"

# ------------------------------------------------------------------------
echo "-- whitebox unit: whisper_sidecar._diagnose -- the full health-state enumeration, directly (issue #424's protocol-layer-failure-enumeration lesson) --"
out="$(PYTHONPATH="$WS_SKILL_DIR" python3 - <<'PY'
import os, socket, tempfile
import whisper_sidecar as ws

# STATE_STARTING: pid alive, port genuinely not open yet.
state_dir = tempfile.mkdtemp(prefix="ws-diag-starting-")
os.makedirs(os.path.join(state_dir, "bin"))
os.makedirs(os.path.join(state_dir, "models"))
open(os.path.join(state_dir, "bin", ws.BIN_NAME), "w").close()
os.chmod(os.path.join(state_dir, "bin", ws.BIN_NAME), 0o755)
open(os.path.join(state_dir, "models", ws.MODEL_NAME), "w").close()
ws._write_pid(state_dir, os.getpid())  # THIS test process is definitely alive
port = 0
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    # deliberately never listen() -- port picked but not bound by anyone else
state, reason = ws._diagnose(state_dir, port)
print("STARTING_STATE", state)
print("STARTING_REASON_HAS_PID", str(os.getpid()) in reason)
PY
)"
check "whitebox _diagnose: pid alive + port closed => STATE_STARTING" "STARTING_STATE starting" "$out"
check "whitebox _diagnose: STARTING reason names the alive pid" "STARTING_REASON_HAS_PID True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_capability -- whisper-sidecar dispatches action=status through the real capability.yaml/invoke machinery --"
WS_S_INTEGRATION="$WS_TMPD/state-integration"
out="$(env $(ws_env "$WS_S_INTEGRATION" "$(_rand_port)") PYTHONPATH="$WS_SCRIPTS" python3 - <<PY
from assistant import capability_index as ci

cap = ci.load_capability("$WS_SKILL_DIR")
cfg = {"capabilities": {"whisper-sidecar": {"enabled": True}}}
result = ci.invoke_capability("whisper-sidecar", cap, {"action": "status"}, cfg, skill_dir="$WS_SKILL_DIR")
print("RETURNCODE", result.returncode)
print("STDERR_NAMES_INSTALL", "install" in result.stderr)
PY
)"
check "invoke_capability: dispatches to the whisper-sidecar capability's real invoke.exec (status on fresh state)" \
    "RETURNCODE 1" "$out"
check "invoke_capability: the specific not-installed reason reaches the caller via stderr" \
    "STDERR_NAMES_INSTALL True" "$out"

echo "-- unit: invoke_capability -- action param is schema-validated via the allowlist (Sec11.5, reused not forked) --"
out="$(PYTHONPATH="$WS_SCRIPTS" python3 - <<PY
from assistant import capability_index as ci
from assistant import adapters

cap = ci.load_capability("$WS_SKILL_DIR")
cfg = {"capabilities": {"whisper-sidecar": {"enabled": True}}}
try:
    ci.invoke_capability("whisper-sidecar", cap, {"action": "delete-everything"}, cfg, skill_dir="$WS_SKILL_DIR")
    print("RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_ACTION", "action" in msg)
    print("NAMES_ALLOWLIST", "allowlist" in msg.lower())
PY
)"
check "invoke_capability: an action outside the allowlist raises ParamValidationError" "RAISED True" "$out"
check "invoke_capability: the error names the action param" "NAMES_ACTION True" "$out"
check "invoke_capability: the error names the constraint kind (allowlist)" "NAMES_ALLOWLIST True" "$out"

echo "-- unit: invoke_capability -- a DISABLED whisper-sidecar refuses every action, never spawns whisper_sidecar.py (Sec17.2) --"
WS_DISABLED_LOG="$(mktemp -u)"
out="$(WHISPER_SIDECAR_STATE_DIR="$WS_TMPD/state-disabled" PYTHONPATH="$WS_SCRIPTS" python3 - <<PY
from assistant import capability_index as ci

cap = ci.load_capability("$WS_SKILL_DIR")
cfg = {"capabilities": {"whisper-sidecar": {"enabled": False}}}
try:
    ci.invoke_capability("whisper-sidecar", cap, {"action": "start"}, cfg, skill_dir="$WS_SKILL_DIR")
    print("RAISED", False)
except ci.CapabilityDisabledError as e:
    print("RAISED", True)
    print("NAMES_CAPABILITY", "whisper-sidecar" in str(e))
PY
)"
check "invoke_capability: a disabled whisper-sidecar refuses even a 'start' action" "RAISED True" "$out"
check "invoke_capability: the refusal names the capability" "NAMES_CAPABILITY True" "$out"
if [[ -f "$WS_DISABLED_LOG" ]]; then
    echo "FAIL invoke_capability: a disabled whisper-sidecar must never spawn whisper_sidecar.py"
    fails=$((fails + 1))
else
    echo "ok   invoke_capability: a disabled whisper-sidecar never spawns whisper_sidecar.py"
fi

# ------------------------------------------------------------------------
echo "-- end-to-end: compile_index -- the REAL provisioning checker reports this capability's actual state honestly --"
WS_S_E2E="$WS_TMPD/state-e2e"; WS_P_E2E="$(_rand_port)"
out="$(env $(ws_env "$WS_S_E2E" "$WS_P_E2E") PYTHONPATH="$WS_SCRIPTS" python3 - <<PY
from assistant import capability_index as ci

skills_root = "$PLUGIN/skills"
cfg = {"capabilities": {"whisper-sidecar": {"enabled": True}}}
index = ci.compile_index(skills_root, cfg, embed_fn=lambda texts: None)
names = [e.name for e in index.entries]
print("IN_INDEX", "whisper-sidecar" in names)
if "whisper-sidecar" in names:
    e = [e for e in index.entries if e.name == "whisper-sidecar"][0]
    print("PROVISIONED_OK", e.provisioned_ok)
    print("REASON_NAMES_INSTALL", "install" in (e.unavailable_reason or ""))
PY
)"
check "compile_index: the whisper-sidecar capability enters the index (enabled, version-ok)" "IN_INDEX True" "$out"
check "compile_index: honestly reports NOT provisioned on fresh state (never a crash, never a false positive)" \
    "PROVISIONED_OK False" "$out"
check "compile_index: the real reason names the install action, from the ACTUAL check script (cwd wiring works)" \
    "REASON_NAMES_INSTALL True" "$out"

# ------------------------------------------------------------------------
# neural-view boot auto-start: `serve` health-checks this sidecar at boot and
# auto-STARTS it iff installed-but-not-running (never installs -- install
# stays explicit), opt-out via --no-sidecar / NEURAL_VIEW_NO_SIDECAR=1, and
# NO sidecar outcome may ever block or crash neural-view's own boot. Driven
# end-to-end here: the real neural-view `start` spawns the real `serve`,
# whose one "whisper-sidecar:" outcome line lands in
# <NEURAL_VIEW_STATE>/server.log. The auto-start runs on a daemon thread, so
# every log assertion POLLS (ws_nv_log_wait) instead of racing boot. Same
# hermetic WHISPER_SIDECAR_* overrides as the direct lifecycle tests above --
# never the real port 8737 or ~/.claude state.
echo "-- e2e: neural-view boot auto-starts this sidecar (installed + not running) --"
WS_NV="$PLUGIN/scripts/neural-view.py"
WS_NV_PORT=""   # assigned (exported) by each lifecycle_start call below; pre-declared for SC2153
WS_NV_ROOT="$WS_TMPD/nv-root"; mkdir -p "$WS_NV_ROOT/.claude"
WS_NV_SCAN="$WS_TMPD/nv-scan-empty"; mkdir -p "$WS_NV_SCAN"

ws_nv_log_wait() { # <server.log> <substring> -- poll up to ~5s for a daemon-thread log line
    local log="$1" want="$2" _i
    for _i in $(seq 1 50); do
        [[ -f "$log" ]] && grep -qF -- "$want" "$log" && return 0
        sleep 0.1
    done
    return 1
}
ws_nv_check_log() { # <name> <server.log> <substring>
    if ws_nv_log_wait "$2" "$3"; then
        echo "ok   $1"
    else
        echo "FAIL $1 — server.log never contained: $3"
        echo "     log tail: $(tail -5 "$2" 2>/dev/null)"
        fails=$((fails + 1))
    fi
}
ws_nv_install() { # <state_dir> -- stage the stub as an already-installed sidecar
    mkdir -p "$1/bin" "$1/models"
    cp "$WS_STUB_SERVER" "$1/bin/whisper-server"; chmod +x "$1/bin/whisper-server"
    cp "$WS_MODEL_SRC" "$1/models/ggml-model.bin"
}

# (a) installed + not running: boot fires the sidecar up
WS_NV_S_AUTO="$WS_TMPD/nv-sidecar-auto"; WS_NV_P_AUTO="$(_rand_port)"
ws_nv_install "$WS_NV_S_AUTO"
WS_NV_STATE_AUTO="$WS_TMPD/nv-state-auto"
# NEURAL_VIEW_NO_SIDECAR= (empty) re-enables the auto-start these tests
# exercise -- run-tests.sh exports NEURAL_VIEW_NO_SIDECAR=1 suite-wide so no
# OTHER section's neural-view boot can ever reach the real sidecar state.
lifecycle_start "neural-view starts (sidecar installed, not running)" WS_NV_PORT \
    'env NEURAL_VIEW_NO_SIDECAR= NEURAL_VIEW_STATE="$WS_NV_STATE_AUTO" NEURAL_VIEW_SCAN="$WS_NV_SCAN" $(ws_env "$WS_NV_S_AUTO" "$WS_NV_P_AUTO") python3 "$WS_NV" start --dir "$WS_NV_ROOT" --port "$WS_NV_PORT"'
ws_nv_check_log "auto-start: boot logs the sidecar coming up" "$WS_NV_STATE_AUTO/server.log" \
    "whisper-sidecar: started: whisper-server is running on 127.0.0.1:$WS_NV_P_AUTO"
WS_NV_SIDE_PID="$(cat "$WS_NV_S_AUTO/whisper-server.pid" 2>/dev/null || true)"
[[ -n "$WS_NV_SIDE_PID" ]] && ws_track_pid "$WS_NV_SIDE_PID"
check "auto-start: the sidecar process is genuinely alive" \
    "$([[ -n "$WS_NV_SIDE_PID" ]] && kill -0 "$WS_NV_SIDE_PID" 2>/dev/null && echo alive || echo dead)" "alive"
out="$(env $(ws_env "$WS_NV_S_AUTO" "$WS_NV_P_AUTO") python3 "$WS_SKILL_DIR/whisper_sidecar.py" status 2>&1)"; rc=$?
check_rc "auto-start: sidecar status exits 0 after neural-view boot" 0 "$rc"
check "auto-start: sidecar status reports healthy on the test port" \
    "healthy: whisper-server is running on 127.0.0.1:$WS_NV_P_AUTO" "$out"
env NEURAL_VIEW_STATE="$WS_NV_STATE_AUTO" python3 "$WS_NV" stop >/dev/null 2>&1
env $(ws_env "$WS_NV_S_AUTO" "$WS_NV_P_AUTO") python3 "$WS_SKILL_DIR/whisper_sidecar.py" stop >/dev/null 2>&1

# (b) NEURAL_VIEW_NO_SIDECAR=1: auto-start is skipped, logged, sidecar untouched
echo "-- e2e: neural-view boot skips the sidecar when NEURAL_VIEW_NO_SIDECAR=1 --"
WS_NV_STATE_ENVOFF="$WS_TMPD/nv-state-envoff"
lifecycle_start "neural-view starts (env opt-out)" WS_NV_PORT \
    'env NEURAL_VIEW_NO_SIDECAR=1 NEURAL_VIEW_STATE="$WS_NV_STATE_ENVOFF" NEURAL_VIEW_SCAN="$WS_NV_SCAN" $(ws_env "$WS_NV_S_AUTO" "$WS_NV_P_AUTO") python3 "$WS_NV" start --dir "$WS_NV_ROOT" --port "$WS_NV_PORT"'
ws_nv_check_log "env opt-out: boot logs that auto-start is disabled" "$WS_NV_STATE_ENVOFF/server.log" \
    "whisper-sidecar: auto-start disabled"
check "env opt-out: the sidecar was never spawned (no pidfile)" \
    "$([[ -f "$WS_NV_S_AUTO/whisper-server.pid" ]] && echo present || echo absent)" "absent"
env NEURAL_VIEW_STATE="$WS_NV_STATE_ENVOFF" python3 "$WS_NV" stop >/dev/null 2>&1
# belt-and-braces: if a regression DID spawn it, reap it so later tests stay clean
env $(ws_env "$WS_NV_S_AUTO" "$WS_NV_P_AUTO") python3 "$WS_SKILL_DIR/whisper_sidecar.py" stop >/dev/null 2>&1

# (c) --no-sidecar on `start`: same skip, proving the flag is FORWARDED to the serve child
echo "-- e2e: neural-view start --no-sidecar forwards the opt-out to its serve child --"
WS_NV_STATE_FLAGOFF="$WS_TMPD/nv-state-flagoff"
lifecycle_start "neural-view starts (--no-sidecar)" WS_NV_PORT \
    'env NEURAL_VIEW_STATE="$WS_NV_STATE_FLAGOFF" NEURAL_VIEW_SCAN="$WS_NV_SCAN" $(ws_env "$WS_NV_S_AUTO" "$WS_NV_P_AUTO") python3 "$WS_NV" start --dir "$WS_NV_ROOT" --port "$WS_NV_PORT" --no-sidecar'
ws_nv_check_log "--no-sidecar: boot logs that auto-start is disabled" "$WS_NV_STATE_FLAGOFF/server.log" \
    "whisper-sidecar: auto-start disabled"
check "--no-sidecar: the sidecar was never spawned (no pidfile)" \
    "$([[ -f "$WS_NV_S_AUTO/whisper-server.pid" ]] && echo present || echo absent)" "absent"
env NEURAL_VIEW_STATE="$WS_NV_STATE_FLAGOFF" python3 "$WS_NV" stop >/dev/null 2>&1
env $(ws_env "$WS_NV_S_AUTO" "$WS_NV_P_AUTO") python3 "$WS_SKILL_DIR/whisper_sidecar.py" stop >/dev/null 2>&1

# (d) not installed: ONE honest log line, never an install, boot continues normally
echo "-- e2e: neural-view boot logs honestly when the sidecar is not installed (never auto-installs) --"
WS_NV_S_MISSING="$WS_TMPD/nv-sidecar-missing"; mkdir -p "$WS_NV_S_MISSING"
WS_NV_STATE_MISSING="$WS_TMPD/nv-state-missing"
lifecycle_start "neural-view starts (sidecar not installed)" WS_NV_PORT \
    'env NEURAL_VIEW_NO_SIDECAR= NEURAL_VIEW_STATE="$WS_NV_STATE_MISSING" NEURAL_VIEW_SCAN="$WS_NV_SCAN" $(ws_env "$WS_NV_S_MISSING" "$(_rand_port)") python3 "$WS_NV" start --dir "$WS_NV_ROOT" --port "$WS_NV_PORT"'
ws_nv_check_log "not installed: one honest skip line naming the state" "$WS_NV_STATE_MISSING/server.log" \
    "whisper-sidecar: auto-start skipped — whisper-server is not installed"
check "not installed: nothing was auto-installed (state dir stays empty)" \
    "$([[ -e "$WS_NV_S_MISSING/bin/whisper-server" ]] && echo present || echo absent)" "absent"
out="$(env NEURAL_VIEW_STATE="$WS_NV_STATE_MISSING" python3 "$WS_NV" status 2>&1)"
check "not installed: neural-view itself still boots and reports RUNNING" "RUNNING http://127.0.0.1:$WS_NV_PORT" "$out"
env NEURAL_VIEW_STATE="$WS_NV_STATE_MISSING" python3 "$WS_NV" stop >/dev/null 2>&1

# (e) sidecar start FAILURE (server never becomes healthy) must never take down neural-view
echo "-- e2e: a failing sidecar start never blocks or crashes neural-view boot --"
WS_NV_S_FAIL="$WS_TMPD/nv-sidecar-fail"; WS_NV_P_FAIL="$(_rand_port)"
ws_nv_install "$WS_NV_S_FAIL"
WS_NV_STATE_FAIL="$WS_TMPD/nv-state-fail"
lifecycle_start "neural-view starts (sidecar will fail to become healthy)" WS_NV_PORT \
    'env NEURAL_VIEW_NO_SIDECAR= WHISPER_STUB_MODE=never_bind NEURAL_VIEW_STATE="$WS_NV_STATE_FAIL" NEURAL_VIEW_SCAN="$WS_NV_SCAN" $(ws_env "$WS_NV_S_FAIL" "$WS_NV_P_FAIL") python3 "$WS_NV" start --dir "$WS_NV_ROOT" --port "$WS_NV_PORT"'
ws_nv_check_log "sidecar failure: logged honestly as a failed auto-start" "$WS_NV_STATE_FAIL/server.log" \
    "whisper-sidecar: auto-start failed — whisper-server did not become healthy on port $WS_NV_P_FAIL"
out="$(env NEURAL_VIEW_STATE="$WS_NV_STATE_FAIL" python3 "$WS_NV" status 2>&1)"
check "sidecar failure: neural-view is STILL running after the sidecar gave up" "RUNNING http://127.0.0.1:$WS_NV_PORT" "$out"
out="$(cat "$WS_NV_STATE_FAIL/server.log" 2>/dev/null)"
check_absent "sidecar failure: no raw Python traceback leaks into the server log" "Traceback (most recent call last)" "$out"
WS_NV_FAIL_PID="$(cat "$WS_NV_S_FAIL/whisper-server.pid" 2>/dev/null || true)"
[[ -n "$WS_NV_FAIL_PID" ]] && ws_track_pid "$WS_NV_FAIL_PID"
env NEURAL_VIEW_STATE="$WS_NV_STATE_FAIL" python3 "$WS_NV" stop >/dev/null 2>&1
