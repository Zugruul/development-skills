#!/usr/bin/env bash
# section-capability-provisioning.sh -- AST-062: provisioning checks with a
# TTL cache + unavailable-with-reason (SPEC-ASSISTANT.md Sec11.1, Sec11.4,
# issue #337, docs/design/ast-E6.md). Sourced by run-tests.sh; do not run
# standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant.provisioning (AST-062: TTL-cached provisioning checks + unavailable-with-reason, SPEC-ASSISTANT.md Sec11.4) =="

CP_SCRIPTS="$PLUGIN/scripts"
CP_STUB_BIN="$FIX/stub-provisioning-check"

# cp_run <python-body-file> -- runs python3 with the stub provcheck binary on
# a controlled PATH (never an ambient binary -- house lesson
# hermetic-path-fixtures-for-cli-tests), scripts/ on PYTHONPATH.
cp_run() {
    local body="$1"
    PATH="$CP_STUB_BIN:$PATH" PYTHONPATH="$CP_SCRIPTS" python3 "$body"
}

CP_TMPPY="$(mktemp -d)"

# ------------------------------------------------------------------------
echo "-- unit: run_check -- passing check (exit 0) -> provisioned_ok=True, no reason --"
cat >"$CP_TMPPY/ok.py" <<'PYEOF'
from assistant import provisioning as prov

ok, reason = prov.run_check(["provcheck"], timeout=5)
print("OK", ok)
print("REASON", reason)
PYEOF
out="$(PROVCHECK_MODE=ok cp_run "$CP_TMPPY/ok.py" 2>&1)"
check "run_check: exit 0 -> provisioned_ok True" "OK True" "$out"
check "run_check: exit 0 -> no reason" "REASON None" "$out"

# ------------------------------------------------------------------------
echo "-- unit: run_check -- failing check (nonzero exit) -> unavailable, reason names exit code + stderr tail --"
cat >"$CP_TMPPY/fail.py" <<'PYEOF'
from assistant import provisioning as prov

ok, reason = prov.run_check(["provcheck"], timeout=5)
print("OK", ok)
print("REASON_HAS_EXIT_CODE", "7" in reason)
print("REASON_HAS_STDERR_TAIL", "sidecar not warmed up" in reason)
PYEOF
out="$(PROVCHECK_MODE=fail PROVCHECK_EXIT_CODE=7 PROVCHECK_STDERR="sidecar not warmed up" cp_run "$CP_TMPPY/fail.py" 2>&1)"
check "run_check: nonzero exit -> provisioned_ok False" "OK False" "$out"
check "run_check: reason names the exit code" "REASON_HAS_EXIT_CODE True" "$out"
check "run_check: reason includes the stderr tail" "REASON_HAS_STDERR_TAIL True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: run_check -- missing binary -> unavailable, reason names the missing binary --"
cat >"$CP_TMPPY/missing.py" <<'PYEOF'
from assistant import provisioning as prov

ok, reason = prov.run_check(["definitely-not-a-real-provcheck-binary"], timeout=5)
print("OK", ok)
print("REASON_NAMES_BINARY", "definitely-not-a-real-provcheck-binary" in reason)
PYEOF
out="$(PYTHONPATH="$CP_SCRIPTS" python3 "$CP_TMPPY/missing.py" 2>&1)"
check "run_check: missing binary -> provisioned_ok False" "OK False" "$out"
check "run_check: reason names the missing binary" "REASON_NAMES_BINARY True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: run_check -- timeout -> unavailable, reason names the timeout --"
cat >"$CP_TMPPY/hang.py" <<'PYEOF'
import time
from assistant import provisioning as prov

start = time.monotonic()
ok, reason = prov.run_check(["provcheck"], timeout=1)
elapsed = time.monotonic() - start
print("OK", ok)
print("REASON_MENTIONS_TIMEOUT", "timed out" in reason or "timeout" in reason.lower())
print("BOUNDED", elapsed < 10)
PYEOF
out="$(PROVCHECK_MODE=hang PROVCHECK_HANG_SECONDS=30 cp_run "$CP_TMPPY/hang.py" 2>&1)"
check "run_check: hung check -> provisioned_ok False" "OK False" "$out"
check "run_check: reason names the timeout" "REASON_MENTIONS_TIMEOUT True" "$out"
check "run_check: kills the process well inside a 10s bound (not the 30s hang)" "BOUNDED True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: ProvisioningChecker -- caches a PASS for the TTL, honored via an injectable clock --"
cat >"$CP_TMPPY/ttl_pass.py" <<'PYEOF'
import collections
from assistant import provisioning as prov

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["provcheck"], "ttlSeconds": 60},
                  permissions=[], invoke={"exec": ["provcheck"]})

clock = {"now": 1000.0}
calls = {"n": 0}
def fake_run(argv, timeout):
    calls["n"] += 1
    return True, None

checker = prov.ProvisioningChecker(clock=lambda: clock["now"], run=fake_run)  # supported constructor seam -- no subprocess needed for this unit

ok1, _ = checker("whisper-sidecar", cap, "/tmp/whisper-sidecar")
clock["now"] += 30  # still within the 60s TTL
ok2, _ = checker("whisper-sidecar", cap, "/tmp/whisper-sidecar")
print("CALLS_WITHIN_TTL", calls["n"])
print("BOTH_OK", ok1 and ok2)

clock["now"] += 40  # now 70s after the first call -- TTL (60s) has lapsed
ok3, _ = checker("whisper-sidecar", cap, "/tmp/whisper-sidecar")
print("CALLS_AFTER_TTL_LAPSE", calls["n"])
print("STILL_OK", ok3)
PYEOF
out="$(PYTHONPATH="$CP_SCRIPTS" python3 "$CP_TMPPY/ttl_pass.py" 2>&1)"
check "ProvisioningChecker: only ONE real check call within the TTL window" "CALLS_WITHIN_TTL 1" "$out"
check "ProvisioningChecker: cached result honored (still ok) within the TTL" "BOTH_OK True" "$out"
check "ProvisioningChecker: a SECOND real check call fires once the TTL lapses" "CALLS_AFTER_TTL_LAPSE 2" "$out"
check "ProvisioningChecker: post-lapse recheck still reports ok" "STILL_OK True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: ProvisioningChecker -- NEGATIVE CACHING DECISION: a FAIL is ALSO cached for the TTL --"
# Deliberate divergence from assistant/preflight.py's auth-probe cache (which
# NEVER caches a FAIL): compile_index runs on an engine poll cadence, not
# once per human corrective action, so caching only the positive path would
# mean a not-yet-provisioned capability's check subprocess reruns on EVERY
# poll tick until it happens to pass -- exactly the "flapping check hammers
# the system" failure mode this task must avoid. TTL bounds staleness
# symmetrically either way (Sec11.4 wants an HONEST roster, not an
# instantaneous one).
cat >"$CP_TMPPY/ttl_fail.py" <<'PYEOF'
import collections
from assistant import provisioning as prov

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["provcheck"], "ttlSeconds": 60},
                  permissions=[], invoke={"exec": ["provcheck"]})

clock = {"now": 1000.0}
calls = {"n": 0}
def fake_run(argv, timeout):
    calls["n"] += 1
    return False, "sidecar not warmed up"

checker = prov.ProvisioningChecker(clock=lambda: clock["now"], run=fake_run)  # supported constructor seam

ok1, reason1 = checker("whisper-sidecar", cap, "/tmp/whisper-sidecar")
clock["now"] += 30  # within TTL
ok2, reason2 = checker("whisper-sidecar", cap, "/tmp/whisper-sidecar")
print("CALLS_WITHIN_TTL", calls["n"])
print("BOTH_UNAVAILABLE", (ok1, ok2) == (False, False))
print("REASON_CACHED", reason1 == reason2 == "sidecar not warmed up")

clock["now"] += 40  # TTL lapsed
ok3, _ = checker("whisper-sidecar", cap, "/tmp/whisper-sidecar")
print("CALLS_AFTER_TTL_LAPSE", calls["n"])
PYEOF
out="$(PYTHONPATH="$CP_SCRIPTS" python3 "$CP_TMPPY/ttl_fail.py" 2>&1)"
check "ProvisioningChecker: a FAIL is cached too -- only ONE real check call within the TTL" "CALLS_WITHIN_TTL 1" "$out"
check "ProvisioningChecker: both reads within the TTL report unavailable" "BOTH_UNAVAILABLE True" "$out"
check "ProvisioningChecker: the cached reason string is reused verbatim" "REASON_CACHED True" "$out"
check "ProvisioningChecker: a FAIL still rechecks once the TTL lapses (never permanently stuck)" \
    "CALLS_AFTER_TTL_LAPSE 2" "$out"

# ------------------------------------------------------------------------
echo "-- unit: ProvisioningChecker -- cache key is name + check argv -- an argv change never serves a stale result --"
cat >"$CP_TMPPY/argv_change.py" <<'PYEOF'
import collections
from assistant import provisioning as prov

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])

clock = {"now": 1000.0}
calls = []
def fake_run(argv, timeout):
    calls.append(list(argv))
    return True, None

checker = prov.ProvisioningChecker(clock=lambda: clock["now"], run=fake_run)  # supported constructor seam

cap_v1 = Capability(version=1, provisioning={"check": ["provcheck", "--v1"], "ttlSeconds": 60},
                     permissions=[], invoke={"exec": ["provcheck"]})
checker("whisper-sidecar", cap_v1, "/tmp/whisper-sidecar")
checker("whisper-sidecar", cap_v1, "/tmp/whisper-sidecar")  # still cached, no new call

# config CHANGE: the skill's provisioning.check argv is edited (e.g. a new
# flag) -- this MUST be treated as a fresh capability, never served the old
# argv's cached verdict, even though we're still well within the old TTL.
cap_v2 = Capability(version=1, provisioning={"check": ["provcheck", "--v2"], "ttlSeconds": 60},
                     permissions=[], invoke={"exec": ["provcheck"]})
checker("whisper-sidecar", cap_v2, "/tmp/whisper-sidecar")

print("N_CALLS", len(calls))
print("SECOND_CALL_USES_NEW_ARGV", calls[-1] == ["provcheck", "--v2"])
PYEOF
out="$(PYTHONPATH="$CP_SCRIPTS" python3 "$CP_TMPPY/argv_change.py" 2>&1)"
check "ProvisioningChecker: repeat call with the SAME argv reuses the cache (one real call)" "N_CALLS 2" "$out"
check "ProvisioningChecker: a check argv edit runs a fresh check under the new argv" "SECOND_CALL_USES_NEW_ARGV True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: ProvisioningChecker -- bool-guard on ttlSeconds: a bool never masquerades as a TTL --"
cat >"$CP_TMPPY/bool_guard.py" <<'PYEOF'
import collections
from assistant import provisioning as prov

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
# isinstance(True, int) is True -- a malformed/legacy ttlSeconds: true must
# never be treated as ttlSeconds=1 (a real 1-second TTL); it degrades to
# "always recheck" (ttl<=0), never a crash and never a bogus 1s cache.
cap = Capability(version=1, provisioning={"check": ["provcheck"], "ttlSeconds": True},
                  permissions=[], invoke={"exec": ["provcheck"]})

clock = {"now": 1000.0}
calls = {"n": 0}
def fake_run(argv, timeout):
    calls["n"] += 1
    return True, None
checker = prov.ProvisioningChecker(clock=lambda: clock["now"], run=fake_run)  # supported constructor seam

checker("x", cap, "/tmp/x")
clock["now"] += 0.001
checker("x", cap, "/tmp/x")
print("CALLS", calls["n"])
PYEOF
out="$(PYTHONPATH="$CP_SCRIPTS" python3 "$CP_TMPPY/bool_guard.py" 2>&1)"
check "ProvisioningChecker: ttlSeconds: true is bool-guarded, never read as a 1s TTL (always rechecks)" "CALLS 2" "$out"

# ------------------------------------------------------------------------
echo "-- unit: compile_index -- the REAL checker is now the default (AST-062 wires it in) --"
out="$(SCRIPTS_DIR="$CP_SCRIPTS" PATH="$CP_STUB_BIN:$PATH" PROVCHECK_MODE=ok python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="cp-default-real-ok-")
skills_root = os.path.join(root, "skills")
d = os.path.join(skills_root, "provisioned-skill")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "capability.yaml"), "w") as fh:
    fh.write("version: 1\nprovisioning:\n    check: [\"provcheck\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"provcheck\"]\n")

cfg = {"capabilities": {"provisioned-skill": {"enabled": True}}}
index = ci.compile_index(skills_root, cfg, embed_fn=lambda texts: None)
e = index.entries[0]
print("PROVISIONED_OK", e.provisioned_ok)
print("UNAVAILABLE_REASON", e.unavailable_reason)
PY
)"
check "compile_index: no override -> a genuinely passing check reports provisioned_ok True" "PROVISIONED_OK True" "$out"
check "compile_index: no override -> a genuinely passing check has no reason" "UNAVAILABLE_REASON None" "$out"

echo "-- unit: compile_index -- the REAL default checker marks a genuinely failing check unavailable + reason --"
out="$(SCRIPTS_DIR="$CP_SCRIPTS" PATH="$CP_STUB_BIN:$PATH" PROVCHECK_MODE=fail PROVCHECK_EXIT_CODE=9 PROVCHECK_STDERR="whisper sidecar not running" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="cp-default-real-fail-")
skills_root = os.path.join(root, "skills")
d = os.path.join(skills_root, "whisper-sidecar")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "capability.yaml"), "w") as fh:
    fh.write("version: 1\nprovisioning:\n    check: [\"provcheck\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"provcheck\"]\n")

cfg = {"capabilities": {"whisper-sidecar": {"enabled": True}}}
index = ci.compile_index(skills_root, cfg, embed_fn=lambda texts: None)
print("N_ENTRIES", len(index.entries))
e = index.entries[0]
print("STILL_IN_INDEX", e.enabled)
print("PROVISIONED_OK", e.provisioned_ok)
print("REASON_HAS_EXIT_CODE", "9" in e.unavailable_reason)
print("REASON_HAS_STDERR", "whisper sidecar not running" in e.unavailable_reason)
PY
)"
check "compile_index: enabled+version-ok+genuinely-failing-check STILL enters the index (Sec11.4)" "N_ENTRIES 1" "$out"
check "compile_index: unprovisioned entry stays enabled=True (flagged, not hidden)" "STILL_IN_INDEX True" "$out"
check "compile_index: real default checker reports provisioned_ok False on a real failure" "PROVISIONED_OK False" "$out"
check "compile_index: real default checker's reason names the exit code" "REASON_HAS_EXIT_CODE True" "$out"
check "compile_index: real default checker's reason includes the stderr tail" "REASON_HAS_STDERR True" "$out"

echo "-- unit: compile_index -- injectable provisioning_checker seam still overrides the real default --"
out="$(SCRIPTS_DIR="$CP_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="cp-inject-still-works-")
skills_root = os.path.join(root, "skills")
d = os.path.join(skills_root, "any-skill")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "capability.yaml"), "w") as fh:
    fh.write("version: 1\nprovisioning:\n    check: [\"nonexistent-binary-never-runs\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"x\"]\n")

def fake_checker(name, capability, skill_dir):
    return True, None

cfg = {"capabilities": {"any-skill": {"enabled": True}}}
index = ci.compile_index(skills_root, cfg, provisioning_checker=fake_checker, embed_fn=lambda texts: None)
e = index.entries[0]
print("PROVISIONED_OK", e.provisioned_ok)
PY
)"
check "compile_index: an injected provisioning_checker still fully overrides the real default (tests stay hermetic)" \
    "PROVISIONED_OK True" "$out"

echo "-- unit: compile_index -- a DISABLED capability spawns ZERO provisioning-check subprocesses (Sec11.2: disabled is invisible, checked upstream of provisioning) --"
CP_CALL_LOG="$(mktemp -u)"
out="$(SCRIPTS_DIR="$CP_SCRIPTS" PATH="$CP_STUB_BIN:$PATH" PROVCHECK_MODE=ok PROVCHECK_CALL_LOG="$CP_CALL_LOG" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="cp-disabled-no-spawn-")
skills_root = os.path.join(root, "skills")
d = os.path.join(skills_root, "whisper-sidecar")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "capability.yaml"), "w") as fh:
    fh.write("version: 1\nprovisioning:\n    check: [\"provcheck\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"provcheck\"]\n")

cfg = {"capabilities": {"whisper-sidecar": {"enabled": False}}}
index = ci.compile_index(skills_root, cfg, embed_fn=lambda texts: None)
print("N_ENTRIES", len(index.entries))
PY
)"
check "compile_index: a disabled capability still compiles (just never provisioning-checked)" "N_ENTRIES 0" "$out"
# The stub binary appends one "call" line to $PROVCHECK_CALL_LOG on every
# invocation (see fixtures/stub-provisioning-check/provcheck); zero
# provisioning-check subprocesses means the log is never even created.
if [[ -f "$CP_CALL_LOG" ]]; then
    echo "FAIL compile_index: a disabled capability's provisioning.check binary is NEVER invoked — call log exists: $(cat "$CP_CALL_LOG")"
    fails=$((fails + 1))
else
    echo "ok   compile_index: a disabled capability's provisioning.check binary is NEVER invoked"
fi
rm -f "$CP_CALL_LOG"

# ------------------------------------------------------------------------
echo "-- unit: turns._render_roster_entries (via compose_context) -- an unavailable entry renders its reason, never as usable --"
out="$(PYTHONPATH="$CP_SCRIPTS" python3 - <<'PY'
from assistant import turns

persona_cfg = {"systemPrompt": "P", "names": ["Solo"]}

def roster_provider():
    return [{"name": "whisper-sidecar", "one-liner": "local speech-to-text",
              "available": False, "reason": "provisioning check exited 9: sidecar not running"}]

result = turns.compose_context(persona_cfg, roster_provider, None, {}, "hello")
sys_text = result["context_for_adapter"]["system"]
print("NAMES_UNAVAILABLE", "unavailable" in sys_text)
print("HAS_REASON", "sidecar not running" in sys_text)
print("NEVER_SAYS_AVAILABLE_FOR_IT", "whisper-sidecar (available)" not in sys_text)
PY
)"
check "roster rendering: an unavailable entry is rendered as unavailable" "NAMES_UNAVAILABLE True" "$out"
check "roster rendering: the specific reason text reaches the persona prompt" "HAS_REASON True" "$out"
check "roster rendering: an unavailable entry never reads as (available)" "NEVER_SAYS_AVAILABLE_FOR_IT True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: engine._roster_provider_for -- unavailable_reason flows from the compiled index into the roster dict --"
out="$(SCRIPTS_DIR="$CP_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci, engine

state_dir = tempfile.mkdtemp(prefix="cp-engine-state-")
eng = engine.AssistantEngine(repos_getter=lambda: [], state_dir=state_dir)

root = "/tmp/cp-engine-root"
entry = ci.CapabilityIndexEntry(
    name="whisper-sidecar", one_liner="local speech-to-text", keywords=["speech", "text", "local"],
    embedding=None, enabled=True, provisioned_ok=False,
    unavailable_reason="provisioning check exited 9: sidecar not running",
)
index = ci.CapabilityIndex(entries=(entry,))
eng._on_capability_index_compiled(root, index)

provider = eng._roster_provider_for(root, "speech text local")  # exact keyword overlap
                                                                  # with the entry -- Jaccard 1.0,
                                                                  # guaranteed non-ambiguous single winner
entries = provider()
print("N", len(entries))
d = entries[0]
print("NAME", d.get("name"))
print("AVAILABLE", d.get("available"))
print("REASON", d.get("reason"))
PY
)"
check "engine roster provider: exactly one entry surfaces" "N 1" "$out"
check "engine roster provider: entry name is the capability name" "NAME whisper-sidecar" "$out"
check "engine roster provider: available reflects provisioned_ok (False)" "AVAILABLE False" "$out"
check "engine roster provider: unavailable_reason flows through as 'reason'" \
    "REASON provisioning check exited 9: sidecar not running" "$out"
