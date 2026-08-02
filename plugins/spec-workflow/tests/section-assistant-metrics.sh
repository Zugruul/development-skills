#!/usr/bin/env bash
# section-assistant-metrics.sh -- AST-042: Prometheus exposition endpoint
# (SPEC-ASSISTANT.md Sec10.4, E4, issue #328, docs/design/ast-E4.md).
# Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant metrics (AST-042: Prometheus exposition endpoint, SPEC-ASSISTANT.md Sec10.4) =="

AM_SCRIPTS="$PLUGIN/scripts"

am_repo() {
    local dir="$1" main="$2" prom_enabled="$3" host="$4" port="$5"
    mkdir -p "$dir/.claude"
    printf "%s\n" "# neural-network" >"$dir/.claude/.neural-network"
    {
        printf "%s\n" \
            "schemaVersion: 2" \
            "assistant:" \
            "    version: 1" \
            "    enabled: true" \
            "    names: [$main]" \
            "    systemPrompt: |" \
            "        You are $main." \
            "    llm:" \
            "        provider: openai" \
            "        model: gpt-5.6-sol" \
            "    capabilities:" \
            "        codex:" \
            "            enabled: true" \
            "            provisioning:" \
            "                bin: codex" \
            "    observability:" \
            "        metrics:" \
            "            prometheus:" \
            "                enabled: $prom_enabled" \
            "                host: $host" \
            "                port: $port"
    } >"$dir/.claude/project.yaml"
}

# ------------------------------------------------------------------------
echo "-- unit: metrics_text computes exact counters from a fixture traces db --"
counters_out="$(SCRIPTS_DIR="$AM_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="am-counters-")
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()

# two ok turns, one error turn
observability.emit(q, root, {"kind": "turn.start", "turn_id": "t1", "ts": "2026-01-01T00:00:00+00:00"})
observability.emit(q, root, {"kind": "recall.summary", "turn_id": "t1"})
observability.emit(q, root, {"kind": "provider.call", "turn_id": "t1"})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "t1", "status": "ok", "ts": "2026-01-01T00:00:01+00:00"})

observability.emit(q, root, {"kind": "turn.start", "turn_id": "t2", "ts": "2026-01-01T00:01:00+00:00"})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "t2", "status": "ok", "ts": "2026-01-01T00:01:03+00:00"})

observability.emit(q, root, {"kind": "turn.start", "turn_id": "t3", "ts": "2026-01-01T00:02:00+00:00"})
observability.emit(q, root, {"kind": "provider.error", "turn_id": "t3", "status": "error"})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "t3", "status": "error", "ts": "2026-01-01T00:02:00+00:00"})

observability.emit(q, root, {"kind": "distill.batch", "payload": {"minted": ["note-a", "note-b"], "bumped": []}})
observability.emit(q, root, {"kind": "distill.batch", "payload": {"minted": ["note-c"], "bumped": []}})

deadline = time.monotonic() + 5.0
rows = []
while time.monotonic() < deadline:
    rows = observability.query(root, limit=1000)
    if len(rows) >= 10:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=3)

text = observability.metrics_text([("jarvis", root)])
print("---BEGIN---")
print(text)
print("---END---")
PY
)"
check "metrics_text: turns_total ok=2 for jarvis" 'assistant_turns_total{root="jarvis",status="ok"} 2' "$counters_out"
check "metrics_text: turns_total error=1 for jarvis" 'assistant_turns_total{root="jarvis",status="error"} 1' "$counters_out"
check "metrics_text: provider_errors_total=1" 'assistant_provider_errors_total{root="jarvis"} 1' "$counters_out"
check "metrics_text: distill_batches_total=2" 'assistant_distill_batches_total{root="jarvis"} 2' "$counters_out"
check "metrics_text: notes_minted_total=3 (2+1 across both batches)" 'assistant_notes_minted_total{root="jarvis"} 3' "$counters_out"
check "metrics_text: events_total counts the turn family (3 starts + 3 ends = 6)" 'assistant_events_total{root="jarvis",kind="turn"} 6' "$counters_out"
check "metrics_text: turn_duration_seconds_count=3 (three completed turn pairs)" 'assistant_turn_duration_seconds_count{root="jarvis"} 3' "$counters_out"
check "metrics_text: turn_duration_seconds_sum totals 1s+3s+0s=4" 'assistant_turn_duration_seconds_sum{root="jarvis"} 4' "$counters_out"
check "metrics_text: le=+Inf bucket equals the total count" 'assistant_turn_duration_seconds_bucket{root="jarvis",le="+Inf"} 3' "$counters_out"
check "metrics_text: le=5 bucket includes all three turns (1s,3s,0s all <=5s)" 'assistant_turn_duration_seconds_bucket{root="jarvis",le="5"} 3' "$counters_out"
check "metrics_text: le=0.1 bucket only includes the instantaneous (0s) turn" 'assistant_turn_duration_seconds_bucket{root="jarvis",le="0.1"} 1' "$counters_out"

# ------------------------------------------------------------------------
echo "-- unit: metrics_text output is a Prometheus text-format 0.0.4 lint pass --"
lint_out="$(SCRIPTS_DIR="$AM_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="am-lint-")
text = observability.metrics_text([("jarvis", root)])
lines = text.splitlines()

metric_names = [
    "assistant_turns_total", "assistant_provider_errors_total",
    "assistant_events_total", "assistant_distill_batches_total",
    "assistant_notes_minted_total", "assistant_turn_duration_seconds",
]
help_present = all(any(l == "# HELP %s %s" % (m, "") or l.startswith("# HELP %s " % m) for l in lines) for m in metric_names)
type_present = all(("# TYPE %s counter" % m in lines) or ("# TYPE %s histogram" % m in lines) for m in metric_names)

print("HELP_PRESENT_ALL", help_present)
print("TYPE_PRESENT_ALL", type_present)
print("ENDS_WITH_NEWLINE", text.endswith("\n"))
print("NO_BLANK_LINES", not any(l == "" for l in lines))
PY
)"
check "lint: every metric has a # HELP line" "HELP_PRESENT_ALL True" "$lint_out"
check "lint: every metric has a # TYPE line" "TYPE_PRESENT_ALL True" "$lint_out"
check "lint: output ends with a trailing newline" "ENDS_WITH_NEWLINE True" "$lint_out"
check "lint: no blank lines in the exposition body" "NO_BLANK_LINES True" "$lint_out"

# ------------------------------------------------------------------------
echo "-- unit: metrics_text escapes label values (Prometheus text-format 0.0.4 escaping) --"
escape_out="$(SCRIPTS_DIR="$AM_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="am-escape-")
text = observability.metrics_text([('weird "name"\\with\\backslash', root)])
print("ESCAPED_QUOTE", '\\"name\\"' in text)
print("ESCAPED_BACKSLASH", "with\\\\backslash" in text)
PY
)"
check "escaping: a double quote in a label value is backslash-escaped" "ESCAPED_QUOTE True" "$escape_out"
check "escaping: a backslash in a label value is escaped first (doubled)" "ESCAPED_BACKSLASH True" "$escape_out"

# ------------------------------------------------------------------------
echo "-- unit: metrics_text renders multiple roots side by side, labeled per root --"
multi_out="$(SCRIPTS_DIR="$AM_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root_a = tempfile.mkdtemp(prefix="am-multi-a-")
root_b = tempfile.mkdtemp(prefix="am-multi-b-")

for root, tid in ((root_a, "a1"), (root_b, "b1")):
    q = queue.Queue()
    stop = threading.Event()
    t = threading.Thread(target=observability.run_writer, args=(q, stop))
    t.start()
    observability.emit(q, root, {"kind": "turn.start", "turn_id": tid})
    observability.emit(q, root, {"kind": "turn.end", "turn_id": tid, "status": "ok"})
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if len(observability.query(root)) >= 2:
            break
        time.sleep(0.2)
    stop.set()
    t.join(timeout=3)

text = observability.metrics_text([("assistant-a", root_a), ("assistant-b", root_b)])
print("HAS_A", 'assistant_turns_total{root="assistant-a",status="ok"} 1' in text)
print("HAS_B", 'assistant_turns_total{root="assistant-b",status="ok"} 1' in text)
# each metric name HELP/TYPE pair appears exactly once even with 2 roots
print("SINGLE_HELP_TURNS", text.count("# HELP assistant_turns_total") == 1)
PY
)"
check "multi-root: assistant-a's counters are present and correctly labeled" "HAS_A True" "$multi_out"
check "multi-root: assistant-b's counters are present and correctly labeled" "HAS_B True" "$multi_out"
check "multi-root: a metric's HELP/TYPE pair is declared once, not once per root" "SINGLE_HELP_TURNS True" "$multi_out"

# ------------------------------------------------------------------------
echo "-- integration: disabled config -> no exposition server bound (connection refused) --"
_amd_root="$(mktemp -d)"
am_repo "$_amd_root" jarvis false 127.0.0.1 0
amd_port="$(_rand_port)"

disabled_out="$(SCRIPTS_DIR="$AM_SCRIPTS" ROOT="$_amd_root" python3 - <<'PY'
import os, sys, socket
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

root = os.environ["ROOT"]
state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    print("METRICS_SERVER_NONE", e._metrics_server is None)
finally:
    e.stop()
PY
)"
check "disabled: no server object is created when no root enables prometheus" "METRICS_SERVER_NONE True" "$disabled_out"

# A bounded-timeout connect attempt against a port nothing bound to must
# refuse promptly -- never hang (FAIL-FAST per this section's registration).
refused_out="$(SCRIPTS_DIR="$AM_SCRIPTS" ROOT="$_amd_root" PORT="$amd_port" python3 - <<'PY'
import os, sys, socket, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

root = os.environ["ROOT"]
port = int(os.environ["PORT"])
state_dir = os.path.join(root, ".claude", "assistant-engine-state-2")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    refused = False
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
        s.close()
    except (ConnectionRefusedError, OSError):
        refused = True
    print("CONNECTION_REFUSED", refused)
finally:
    e.stop()
PY
)"
check "disabled: connecting to an arbitrary port (nothing bound) is refused, bounded-time" "CONNECTION_REFUSED True" "$refused_out"
rm -rf "$_amd_root"

# ------------------------------------------------------------------------
echo "-- integration: enabled config -> scrape round-trip over HTTP --"
_ame_root="$(mktemp -d)"
ame_port="$(_rand_port)"
am_repo "$_ame_root" jarvis true 127.0.0.1 "$ame_port"

scrape_out="$(SCRIPTS_DIR="$AM_SCRIPTS" ROOT="$_ame_root" PORT="$ame_port" python3 - <<'PY'
import os, sys, time, urllib.request, urllib.error
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, engine, observability

root = os.environ["ROOT"]
port = int(os.environ["PORT"])

def stub_complete(context, **kwargs):
    return {"text": "reply", "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    print("SERVER_BOUND", e._metrics_server is not None)

    url = "http://127.0.0.1:%d/metrics" % port
    deadline = time.monotonic() + 5.0
    body = None
    status = None
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2.0) as resp:
                status = resp.status
                body = resp.read().decode("utf-8")
            break
        except (urllib.error.URLError, ConnectionRefusedError):
            time.sleep(0.2)
    print("SCRAPE_STATUS", status)
    print("SCRAPE_HAS_HELP", body is not None and "# HELP assistant_turns_total" in body)

    # a real chat turn, then scrape again -- computed-not-stored: the
    # second scrape must reflect the new turn (no caching/staleness).
    status2, _payload, _ct = e.handle("POST", "/assistant/chat", body={"message": "hello"})
    print("CHAT_STATUS", status2)

    deadline2 = time.monotonic() + 5.0
    body2 = None
    while time.monotonic() < deadline2:
        with urllib.request.urlopen(url, timeout=2.0) as resp:
            body2 = resp.read().decode("utf-8")
        if 'assistant_turns_total{root="jarvis",status="ok"} 1' in body2:
            break
        time.sleep(0.2)
    print("SECOND_SCRAPE_REFLECTS_NEW_TURN", body2 is not None and 'assistant_turns_total{root="jarvis",status="ok"} 1' in body2)

    unknown_status = None
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/not-metrics" % port, timeout=2.0) as resp:
            unknown_status = resp.status
    except urllib.error.HTTPError as exc:
        unknown_status = exc.code
    print("UNKNOWN_PATH_404", unknown_status == 404)
finally:
    e.stop()
    print("ENGINE_STOPPED_CLEANLY", True)
PY
)"
check "scrape: engine binds the shared metrics server when a root enables it" "SERVER_BOUND True" "$scrape_out"
check "scrape: GET /metrics returns 200" "SCRAPE_STATUS 200" "$scrape_out"
check "scrape: response body is Prometheus exposition text" "SCRAPE_HAS_HELP True" "$scrape_out"
check "scrape: an unrelated path returns 404" "UNKNOWN_PATH_404 True" "$scrape_out"
check "scrape: computed-not-stored -- a second scrape after a new turn reflects it" "SECOND_SCRAPE_REFLECTS_NEW_TURN True" "$scrape_out"
check "scrape: engine.stop() shuts the metrics server down cleanly" "ENGINE_STOPPED_CLEANLY True" "$scrape_out"
if [[ "$scrape_out" != *"SCRAPE_STATUS 200"* ]]; then echo "$scrape_out" >&2; fi
rm -rf "$_ame_root"

# ------------------------------------------------------------------------
echo "-- integration: server start/stop is clean -- no leaked thread, port freed --"
_ams_root="$(mktemp -d)"
ams_port="$(_rand_port)"
am_repo "$_ams_root" jarvis true 127.0.0.1 "$ams_port"

leak_out="$(SCRIPTS_DIR="$AM_SCRIPTS" ROOT="$_ams_root" PORT="$ams_port" python3 - <<'PY'
import os, sys, socket, threading, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

root = os.environ["ROOT"]
port = int(os.environ["PORT"])

before_threads = {t.name for t in threading.enumerate()}

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()

deadline = time.monotonic() + 5.0
bound = False
while time.monotonic() < deadline:
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=1.0)
        s.close()
        bound = True
        break
    except (ConnectionRefusedError, OSError):
        time.sleep(0.2)
print("BOUND_WHILE_RUNNING", bound)

e.stop()
time.sleep(0.3)
after_threads = {t.name for t in threading.enumerate()}
print("NO_LEAKED_METRICS_THREAD", "assistant-metrics" not in after_threads)

refused_after_stop = False
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
    s.close()
except (ConnectionRefusedError, OSError):
    refused_after_stop = True
print("PORT_FREED_AFTER_STOP", refused_after_stop)
PY
)"
check "start/stop: the server is actually reachable while the engine is running" "BOUND_WHILE_RUNNING True" "$leak_out"
check "start/stop: no assistant-metrics thread survives engine.stop()" "NO_LEAKED_METRICS_THREAD True" "$leak_out"
check "start/stop: the port is refused (freed) after engine.stop()" "PORT_FREED_AFTER_STOP True" "$leak_out"
rm -rf "$_ams_root"

# ------------------------------------------------------------------------
echo "-- unit: engine resolves per-root observability.metrics.prometheus config --"
cfg_out="$(SCRIPTS_DIR="$AM_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

root = tempfile.mkdtemp(prefix="am-cfg-")
os.makedirs(os.path.join(root, ".claude"), exist_ok=True)
with open(os.path.join(root, ".claude", ".neural-network"), "w") as f:
    f.write("# neural-network\n")
with open(os.path.join(root, ".claude", "project.yaml"), "w") as f:
    f.write(
        "schemaVersion: 2\n"
        "assistant:\n"
        "    version: 1\n"
        "    enabled: true\n"
        "    names: [jarvis]\n"
        "    systemPrompt: |\n"
        "        You are jarvis.\n"
        "    llm:\n"
        "        provider: openai\n"
        "        model: gpt-5.6-sol\n"
        "    capabilities:\n"
        "        codex:\n"
        "            enabled: true\n"
        "            provisioning:\n"
        "                bin: codex\n"
        "    observability:\n"
        "        metrics:\n"
        "            prometheus:\n"
        "                enabled: true\n"
        "                host: 0.0.0.0\n"
        "                port: 9999\n"
    )

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
cfg = e._metrics_config_for(root)
print("ENABLED", cfg.get("enabled") if cfg else None)
print("HOST", cfg.get("host") if cfg else None)
print("PORT", cfg.get("port") if cfg else None)

configs = e._discover_metrics_configs()
print("DISCOVERED_HOST_PORT", [(h, p) for _r, h, p in configs])

other_root = tempfile.mkdtemp(prefix="am-cfg-none-")
cfg_none = e._metrics_config_for(other_root)
print("NO_MARKER_ROOT_CFG", cfg_none)
PY
)"
check "metrics config: engine reads enabled from observability.metrics.prometheus" "ENABLED True" "$cfg_out"
check "metrics config: engine reads an explicit non-loopback host verbatim (user's choice)" "HOST 0.0.0.0" "$cfg_out"
check "metrics config: engine reads port from observability.metrics.prometheus" "PORT 9999" "$cfg_out"
check "metrics config: _discover_metrics_configs surfaces the resolved (host, port)" "DISCOVERED_HOST_PORT [('0.0.0.0', 9999)]" "$cfg_out"
check "metrics config: a non-candidate root resolves to None" "NO_MARKER_ROOT_CFG None" "$cfg_out"

# ------------------------------------------------------------------------
echo "-- unit: localhost default binding when host/port are omitted --"
default_out="$(SCRIPTS_DIR="$AM_SCRIPTS" python3 -c "
import sys
sys.path.insert(0, '$AM_SCRIPTS')
from assistant import observability
print('DEFAULT_HOST', observability.DEFAULT_METRICS_HOST)
print('DEFAULT_PORT', observability.DEFAULT_METRICS_PORT)
")"
check "defaults: localhost (127.0.0.1) is the default metrics host" "DEFAULT_HOST 127.0.0.1" "$default_out"
check "defaults: 9464 is the default metrics port (spec §6 example)" "DEFAULT_PORT 9464" "$default_out"

# ------------------------------------------------------------------------
# #392 ride-along nits
# ------------------------------------------------------------------------
echo "-- #392: the inert daemon_threads attr is gone from _MetricsHTTPServer --"
obs_src="$(cat "$AM_SCRIPTS/assistant/observability.py")"
check_absent "#392: daemon_threads is removed (HTTPServer is not threaded, the attr did nothing)" "daemon_threads" "$obs_src"

echo "-- #392: omitted host/port end-to-end falls back to 127.0.0.1:DEFAULT_METRICS_PORT --"
_amf_root="$(mktemp -d)"
mkdir -p "$_amf_root/.claude"
printf "%s\n" "# neural-network" >"$_amf_root/.claude/.neural-network"
printf "%s\n" \
    "schemaVersion: 2" \
    "assistant:" \
    "    version: 1" \
    "    enabled: true" \
    "    names: [jarvis]" \
    "    systemPrompt: |" \
    "        You are jarvis." \
    "    llm:" \
    "        provider: openai" \
    "        model: gpt-5.6-sol" \
    "    capabilities:" \
    "        codex:" \
    "            enabled: true" \
    "            provisioning:" \
    "                bin: codex" \
    "    observability:" \
    "        metrics:" \
    "            prometheus:" \
    "                enabled: true" \
    >"$_amf_root/.claude/project.yaml"
amf_port="$(_rand_port)"

fallback_out="$(SCRIPTS_DIR="$AM_SCRIPTS" ROOT="$_amf_root" PORT="$amf_port" python3 - <<'PY'
import os, socket, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine, observability

root = os.environ["ROOT"]
port = int(os.environ["PORT"])
# Monkeypatch the module-level default port to a free, test-owned port so
# this test verifies the ACTUAL fallback code path
# (`host = cfg.get("host") or observability.DEFAULT_METRICS_HOST`) without
# fighting over the real default 9464, which may be in use elsewhere.
observability.DEFAULT_METRICS_PORT = port

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    configs = e._discover_metrics_configs()
    print("DISCOVERED_HOST_PORT", [(h, p) for _r, h, p in configs])

    deadline = time.monotonic() + 5.0
    bound = False
    while time.monotonic() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=1.0)
            s.close()
            bound = True
            break
        except (ConnectionRefusedError, OSError):
            time.sleep(0.2)
    print("BOUND_ON_DEFAULT_PORT", bound)
finally:
    e.stop()
PY
)"
check "fallback: omitted host/port resolves to (127.0.0.1, DEFAULT_METRICS_PORT)" "DISCOVERED_HOST_PORT [('127.0.0.1'," "$fallback_out"
check "fallback: the shared server actually binds on that resolved default port" "BOUND_ON_DEFAULT_PORT True" "$fallback_out"
rm -rf "$_amf_root"

# ------------------------------------------------------------------------
echo "-- #392: metrics_text escapes a newline in a label value --"
newline_escape_out="$(SCRIPTS_DIR="$AM_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import observability

root = tempfile.mkdtemp(prefix="am-escape-nl-")
text = observability.metrics_text([("multi\nline", root)])
print("ESCAPED_NEWLINE", "multi\\nline" in text)
print("NO_RAW_NEWLINE_IN_LABEL", "root=\"multi\nline\"" not in text)
PY
)"
check "escaping: a newline in a label value is backslash-escaped" "ESCAPED_NEWLINE True" "$newline_escape_out"
check "escaping: no raw newline leaks into a label value" "NO_RAW_NEWLINE_IN_LABEL True" "$newline_escape_out"

# ------------------------------------------------------------------------
echo "== assistant metrics endpoint (AST-043: GET /assistant/metrics, SPEC-ASSISTANT.md Sec10.5, issue #329) =="

echo "-- integration: GET /assistant/metrics returns the same counters metrics_text/Prometheus expose --"
_ame2_root="$(mktemp -d)"
at_repo_for_metrics() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude"
    printf "%s\n" "# neural-network" >"$dir/.claude/.neural-network"
    printf "%s\n" \
        "schemaVersion: 2" \
        "assistant:" \
        "    version: 1" \
        "    enabled: true" \
        "    names: [$main]" \
        "    systemPrompt: |" \
        "        You are $main." \
        "    llm:" \
        "        provider: openai" \
        "        model: gpt-5.6-sol" \
        "    capabilities:" \
        "        codex:" \
        "            enabled: true" \
        "            provisioning:" \
        "                bin: codex" \
        >"$dir/.claude/project.yaml"
}
at_repo_for_metrics "$_ame2_root" jarvis

metrics_endpoint_out="$(SCRIPTS_DIR="$AM_SCRIPTS" ROOT="$_ame2_root" python3 - <<'PY'
import os, sys, threading, queue, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine, observability

root = os.environ["ROOT"]

# Seed traces.sqlite directly via the writer (same fixture shape as the
# metrics_text unit test above) so this endpoint tests expected numbers are
# cross-checked against that same fixture rather than invented separately.
q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=observability.run_writer, args=(q, stop))
t.start()
observability.emit(q, root, {"kind": "turn.start", "turn_id": "t1", "ts": "2026-01-01T00:00:00+00:00"})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "t1", "status": "ok", "ts": "2026-01-01T00:00:01+00:00"})
observability.emit(q, root, {"kind": "turn.start", "turn_id": "t2", "ts": "2026-01-01T00:01:00+00:00"})
observability.emit(q, root, {"kind": "provider.error", "turn_id": "t2", "status": "error"})
observability.emit(q, root, {"kind": "turn.end", "turn_id": "t2", "status": "error", "ts": "2026-01-01T00:01:00+00:00"})
deadline = time.monotonic() + 5.0
while time.monotonic() < deadline:
    if len(observability.query(root, limit=100)) >= 5:
        break
    time.sleep(0.2)
stop.set()
t.join(timeout=3)

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
status, payload, ct = e.handle("GET", "/assistant/metrics")
print("STATUS", status)
print("CONTENT_TYPE", ct)
roots = payload.get("roots", {})
jarvis = roots.get("jarvis", {})
print("HAS_JARVIS_ROOT", "jarvis" in roots)
print("TURNS_OK", jarvis.get("turnsByStatus", {}).get("ok"))
print("TURNS_ERROR", jarvis.get("turnsByStatus", {}).get("error"))
print("PROVIDER_ERRORS", jarvis.get("providerErrors"))
print("TURN_DURATION_COUNT", jarvis.get("turnDuration", {}).get("count"))
PY
)"
check "metrics endpoint: GET /assistant/metrics returns 200" "STATUS 200" "$metrics_endpoint_out"
check "metrics endpoint: application/json content type" "CONTENT_TYPE application/json" "$metrics_endpoint_out"
check "metrics endpoint: the resolved root label is a top-level key" "HAS_JARVIS_ROOT True" "$metrics_endpoint_out"
check "metrics endpoint: ok-turn counter matches the traces fixture" "TURNS_OK 1" "$metrics_endpoint_out"
check "metrics endpoint: error-turn counter matches the traces fixture" "TURNS_ERROR 1" "$metrics_endpoint_out"
check "metrics endpoint: provider error counter matches the traces fixture" "PROVIDER_ERRORS 1" "$metrics_endpoint_out"
check "metrics endpoint: turn duration sample count matches the traces fixture" "TURN_DURATION_COUNT 2" "$metrics_endpoint_out"
rm -rf "$_ame2_root"

# ------------------------------------------------------------------------
echo "-- unit: GET /assistant/metrics gives a zero-state root when it has no traces db yet --"
_amz_root="$(mktemp -d)"
at_repo_for_metrics "$_amz_root" jarvis
zero_out="$(SCRIPTS_DIR="$AM_SCRIPTS" ROOT="$_amz_root" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

root = os.environ["ROOT"]
state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
status, payload, _ct = e.handle("GET", "/assistant/metrics")
jarvis = payload.get("roots", {}).get("jarvis", {})
print("STATUS", status)
print("TURN_DURATION_COUNT", jarvis.get("turnDuration", {}).get("count"))
print("PROVIDER_ERRORS", jarvis.get("providerErrors"))
print("NO_ERROR_RAISED", True)
PY
)"
check "metrics endpoint: a fresh root with no traces db returns 200, never an error" "STATUS 200" "$zero_out"
check "metrics endpoint: a fresh root has zero turn duration count" "TURN_DURATION_COUNT 0" "$zero_out"
check "metrics endpoint: a fresh root has zero provider errors" "PROVIDER_ERRORS 0" "$zero_out"
rm -rf "$_amz_root"

# ------------------------------------------------------------------------
echo "-- integration: metrics port already held -> start() degrades (warns, no server), never a boot crash --"
# 2026-08-02 live incident: a stale neural-view from another worktree kept
# holding the SHARED exposition port (Sec10.4: one server per machine), so
# every later `serve` died at boot inside engine.start() on EADDRINUSE --
# taking the WHOLE server down over an optional observability side-car.
# Bind failure must degrade exactly like the whisper sidecar's boot posture:
# one stderr line, no metrics server mounted, everything else up.
_amb_root="$(mktemp -d)"
_amb_port="$(_rand_port)"
am_repo "$_amb_root" jarvis true 127.0.0.1 "$_amb_port"

bindfail_out="$(SCRIPTS_DIR="$AM_SCRIPTS" ROOT="$_amb_root" PORT="$_amb_port" python3 - 2>&1 <<'PY'
import os, socket, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

root = os.environ["ROOT"]
port = int(os.environ["PORT"])
blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
blocker.bind(("127.0.0.1", port))
blocker.listen(1)

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
try:
    e.start()
    print("START_SURVIVED", True)
except OSError:
    # RED state: start() raised AFTER its non-daemon workers spawned --
    # stop() them or this fixture process never exits.
    print("START_SURVIVED", False)
    e.stop()
    blocker.close()
    raise SystemExit(0)
try:
    print("METRICS_SERVER_NONE", e._metrics_server is None)
    print("METRICS_THREAD_NONE", e._metrics_thread is None)
finally:
    e.stop()
    print("STOP_OK", True)
blocker.close()
PY
)"
check "bind-failure: engine.start() survives an already-held metrics port" "START_SURVIVED True" "$bindfail_out"
check "bind-failure: no metrics server object is mounted" "METRICS_SERVER_NONE True" "$bindfail_out"
check "bind-failure: no metrics thread is left behind" "METRICS_THREAD_NONE True" "$bindfail_out"
check "bind-failure: stop() still shuts down cleanly" "STOP_OK True" "$bindfail_out"
check "bind-failure: one warning names the disabled exposition" "metrics exposition disabled" "$bindfail_out"
check "bind-failure: the warning names the exact port it could not bind" "$_amb_port" "$bindfail_out"
rm -rf "$_amb_root"
