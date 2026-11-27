#!/usr/bin/env bash
# section-capability-invoke-mcp.sh -- AST-064: MCP invoke flavor
# (SPEC-ASSISTANT.md Sec11.7, issue #339, docs/design/ast-E6.md). Sourced by
# run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# New section rather than folding into section-capability-invoke.sh
# (AST-063's argv flavor, already ~85 checks): kept as its OWN file so this
# task's red/green diff stays isolated and reviewable, matching the
# established pattern of separate sibling sections for closely related but
# distinct concerns (section-capability-index.sh / -roster.sh /
# -provisioning.sh are three files, not one). Flagged per the brief's
# "your call, flag it."
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant.adapters.invoke_mcp (AST-064: MCP invoke flavor, SPEC-ASSISTANT.md Sec11.7) =="

CIM_SCRIPTS="$PLUGIN/scripts"
CIM_STUB_BIN="$FIX/stub-mcp-server"

# cim_run <python-body-file> -- runs python3 with the stub mcpserver binary
# on a controlled PATH (never an ambient binary -- house lesson
# hermetic-path-fixtures-for-cli-tests), scripts/ on PYTHONPATH.
cim_run() {
    local body="$1"
    shift
    PATH="$CIM_STUB_BIN:$PATH" PYTHONPATH="$CIM_SCRIPTS" python3 "$body" "$@"
}

CIM_TMPPY="$(mktemp -d)"

# ------------------------------------------------------------------------
echo "-- static: adapters.py never spawns a subprocess with shell=True (Sec17.3 -- no shell anywhere in the invoke path) --"
adapters_src="$(cat "$CIM_SCRIPTS/assistant/adapters.py")"
check_absent "adapters.py: no shell=True anywhere in the file" "shell=True" "$adapters_src"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- happy path -- one JSON-RPC round trip, params reach the tool call intact --"
cat >"$CIM_TMPPY/happy.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather",
                                  "params": {"city": {"type": "string"}}}})

result = adapters.invoke_mcp(cap, {"city": "New York"})
print("RESULT", result.result)
print("REQUEST_METHOD", result.request["method"])
print("REQUEST_TOOL", result.request["params"]["name"])
print("REQUEST_ARGS", result.request["params"]["arguments"])
print("RESPONSE_ID_MATCHES", result.response["id"] == result.request["id"])
PYEOF
out="$(cim_run "$CIM_TMPPY/happy.py" 2>&1)"
check "invoke_mcp: result echoes the tool the server actually received" \
    "RESULT {'echoedTool': 'weather', 'echoedArguments': {'city': 'New York'}}" "$out"
check "invoke_mcp: the JSON-RPC request method is tools/call" "REQUEST_METHOD tools/call" "$out"
check "invoke_mcp: the JSON-RPC request names the declared tool" "REQUEST_TOOL weather" "$out"
check "invoke_mcp: the JSON-RPC request carries the validated params as arguments" \
    "REQUEST_ARGS {'city': 'New York'}" "$out"
check "invoke_mcp: the response id matches the request id (one round trip, correlated)" \
    "RESPONSE_ID_MATCHES True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- params schema reuses adapters.validate_params -- specific errors, no forked implementation --"
cat >"$CIM_TMPPY/schema_reuse.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather",
                                  "params": {"city": {"type": "string"}}}})

try:
    adapters.invoke_mcp(cap, {"city": 42})
    print("TYPE_RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("TYPE_RAISED", True)
    print("TYPE_NAMES_PARAM", "city" in msg)
    print("TYPE_NAMES_KIND", "type" in msg.lower())

try:
    adapters.invoke_mcp(cap, {})
    print("MISSING_RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("MISSING_RAISED", True)
    print("MISSING_NAMES_PARAM", "city" in msg)

try:
    adapters.invoke_mcp(cap, {"city": "Rome", "extra": "surprise"})
    print("UNDECLARED_RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("UNDECLARED_RAISED", True)
    print("UNDECLARED_NAMES_PARAM", "extra" in msg)
    print("UNDECLARED_NAMES_KIND", "declared" in msg.lower())
PYEOF
out="$(cim_run "$CIM_TMPPY/schema_reuse.py" 2>&1)"
check "invoke_mcp: a type-invalid param raises ParamValidationError" "TYPE_RAISED True" "$out"
check "invoke_mcp: type error names the offending param" "TYPE_NAMES_PARAM True" "$out"
check "invoke_mcp: type error names the constraint kind" "TYPE_NAMES_KIND True" "$out"
check "invoke_mcp: a missing required param raises ParamValidationError" "MISSING_RAISED True" "$out"
check "invoke_mcp: missing-param error names the offending param" "MISSING_NAMES_PARAM True" "$out"
check "invoke_mcp: an undeclared param raises ParamValidationError" "UNDECLARED_RAISED True" "$out"
check "invoke_mcp: undeclared-param error names the offending param" "UNDECLARED_NAMES_PARAM True" "$out"
check "invoke_mcp: undeclared-param error names the constraint kind (not declared)" "UNDECLARED_NAMES_KIND True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- malformed declaration: invoke.mcp.server missing/empty/non-string -- specific error, never a raw crash --"
cat >"$CIM_TMPPY/bad_server.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])

for label, server in [("missing", None), ("empty", []), ("non_list", "mcpserver"), ("non_string_element", ["mcpserver", 5])]:
    invoke = {"mcp": {"tool": "weather"}}
    if server is not None:
        invoke["mcp"]["server"] = server
    cap = Capability(version=1, provisioning={}, permissions=[], invoke=invoke)
    try:
        adapters.invoke_mcp(cap, {})
        print(f"{label}: RAISED False")
    except adapters.ParamValidationError as e:
        msg = str(e)
        print(f"{label}: RAISED True")
        print(f"{label}: NAMES_SERVER", "server" in msg)
    except Exception as e:
        print(f"{label}: RAISED True WRONG_TYPE {type(e).__name__}")
PYEOF
out="$(cim_run "$CIM_TMPPY/bad_server.py" 2>&1)"
check "invoke_mcp: missing invoke.mcp.server raises ParamValidationError" "missing: RAISED True" "$out"
check "invoke_mcp: empty invoke.mcp.server raises ParamValidationError" "empty: RAISED True" "$out"
check "invoke_mcp: non-list invoke.mcp.server raises ParamValidationError" "non_list: RAISED True" "$out"
check "invoke_mcp: invoke.mcp.server with a non-string element raises ParamValidationError" "non_string_element: RAISED True" "$out"
check_absent "invoke_mcp: no malformed-server case raises the wrong exception type" "WRONG_TYPE" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- malformed declaration: invoke.mcp.tool missing/empty/non-string -- specific error --"
cat >"$CIM_TMPPY/bad_tool.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])

for label, tool in [("missing", None), ("empty", ""), ("non_string", 5)]:
    invoke = {"mcp": {"server": ["mcpserver"]}}
    if tool is not None:
        invoke["mcp"]["tool"] = tool
    cap = Capability(version=1, provisioning={}, permissions=[], invoke=invoke)
    try:
        adapters.invoke_mcp(cap, {})
        print(f"{label}: RAISED False")
    except adapters.ParamValidationError as e:
        msg = str(e)
        print(f"{label}: RAISED True")
        print(f"{label}: NAMES_TOOL", "tool" in msg)
PYEOF
out="$(cim_run "$CIM_TMPPY/bad_tool.py" 2>&1)"
check "invoke_mcp: missing invoke.mcp.tool raises ParamValidationError" "missing: RAISED True" "$out"
check "invoke_mcp: empty invoke.mcp.tool raises ParamValidationError" "empty: RAISED True" "$out"
check "invoke_mcp: non-string invoke.mcp.tool raises ParamValidationError" "non_string: RAISED True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- malformed declaration/params never even spawn the server (validated before any subprocess) --"
CIM_CALL_LOG="$(mktemp -u)"
cat >"$CIM_TMPPY/never_spawns.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather",
                                  "params": {"city": {"type": "string"}}}})
try:
    adapters.invoke_mcp(cap, {"city": 42})
except adapters.ParamValidationError:
    pass
PYEOF
MCP_CALL_LOG="$CIM_CALL_LOG" cim_run "$CIM_TMPPY/never_spawns.py" >/dev/null 2>&1
if [[ -f "$CIM_CALL_LOG" ]]; then
    echo "FAIL invoke_mcp: an invalid call must not spawn the server (call-log file was created)"
    fails=$((fails + 1))
else
    echo "ok   invoke_mcp: an invalid call never spawns the server (no call-log file created)"
fi
rm -f "$CIM_CALL_LOG"

# Positive control (house pattern): a VALID call DOES spawn the server.
CIM_CALL_LOG2="$(mktemp -u)"
cat >"$CIM_TMPPY/does_spawn.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})
adapters.invoke_mcp(cap, {})
PYEOF
MCP_CALL_LOG="$CIM_CALL_LOG2" cim_run "$CIM_TMPPY/does_spawn.py" >/dev/null 2>&1
if [[ -f "$CIM_CALL_LOG2" ]]; then
    echo "ok   invoke_mcp: positive control -- a VALID call DOES spawn the server (call-log file created)"
else
    echo "FAIL invoke_mcp: positive control -- a VALID call must spawn the server (call-log file missing)"
    fails=$((fails + 1))
fi
rm -f "$CIM_CALL_LOG2"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- the server's JSON-RPC error is a distinct, specific error (McpToolError) --"
cat >"$CIM_TMPPY/tool_error.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})
try:
    adapters.invoke_mcp(cap, {})
    print("RAISED", False)
except adapters.McpToolError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_TOOL", "weather" in msg)
    print("NAMES_CODE", "-32000" in msg)
    print("NAMES_MESSAGE", "sidecar offline" in msg)
PYEOF
out="$(MCP_MODE=tool_error MCP_ERROR_MESSAGE="sidecar offline" cim_run "$CIM_TMPPY/tool_error.py" 2>&1)"
check "invoke_mcp: a JSON-RPC error response raises McpToolError" "RAISED True" "$out"
check "invoke_mcp: McpToolError names the tool that failed" "NAMES_TOOL True" "$out"
check "invoke_mcp: McpToolError includes the JSON-RPC error code" "NAMES_CODE True" "$out"
check "invoke_mcp: McpToolError includes the JSON-RPC error message" "NAMES_MESSAGE True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- non-JSON server stdout raises McpUnparseableOutput, never a raw JSONDecodeError --"
cat >"$CIM_TMPPY/garbage.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})
try:
    adapters.invoke_mcp(cap, {})
    print("RAISED", False)
    print("RIGHT_TYPE", False)
except adapters.McpUnparseableOutput:
    print("RAISED", True)
    print("RIGHT_TYPE", True)
except Exception as e:
    print("RAISED", True)
    print("RIGHT_TYPE", False, type(e).__name__)
PYEOF
out="$(MCP_MODE=garbage cim_run "$CIM_TMPPY/garbage.py" 2>&1)"
check "invoke_mcp: non-JSON stdout raises (something)" "RAISED True" "$out"
check "invoke_mcp: non-JSON stdout raises McpUnparseableOutput specifically, never a raw JSONDecodeError" \
    "RIGHT_TYPE True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- a response with neither result nor error raises McpUnparseableOutput (JSON-RPC 2.0 requires exactly one) --"
cat >"$CIM_TMPPY/bad_shape.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})
try:
    adapters.invoke_mcp(cap, {})
    print("RAISED", False)
except adapters.McpUnparseableOutput:
    print("RAISED", True)
PYEOF
out="$(MCP_MODE=bad_shape cim_run "$CIM_TMPPY/bad_shape.py" 2>&1)"
check "invoke_mcp: a response with neither result nor error raises McpUnparseableOutput" "RAISED True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- a response with BOTH result and error raises McpUnparseableOutput (exactly one, never both) --"
cat >"$CIM_TMPPY/both_fields.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})
try:
    adapters.invoke_mcp(cap, {})
    print("RAISED", False)
except adapters.McpUnparseableOutput:
    print("RAISED", True)
PYEOF
out="$(MCP_MODE=both_fields cim_run "$CIM_TMPPY/both_fields.py" 2>&1)"
check "invoke_mcp: a response carrying both result and error raises McpUnparseableOutput" "RAISED True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- a mismatched response id raises McpUnparseableOutput (one round trip, correlated by id) --"
cat >"$CIM_TMPPY/wrong_id.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})
try:
    adapters.invoke_mcp(cap, {})
    print("RAISED", False)
except adapters.McpUnparseableOutput as e:
    print("RAISED", True)
    print("NAMES_ID", "id" in str(e).lower())
PYEOF
out="$(MCP_MODE=wrong_id cim_run "$CIM_TMPPY/wrong_id.py" 2>&1)"
check "invoke_mcp: a mismatched response id raises McpUnparseableOutput" "RAISED True" "$out"
check "invoke_mcp: mismatched-id error mentions id correlation" "NAMES_ID True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- a nonzero server exit raises adapters.NonzeroExit, never a raw crash --"
cat >"$CIM_TMPPY/nonzero.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})
try:
    adapters.invoke_mcp(cap, {})
    print("RAISED", False)
except adapters.NonzeroExit as e:
    print("RAISED", True)
    print("NAMES_STDERR", "server crashed" in str(e))
PYEOF
out="$(MCP_MODE=nonzero cim_run "$CIM_TMPPY/nonzero.py" 2>&1)"
check "invoke_mcp: a nonzero server exit raises adapters.NonzeroExit" "RAISED True" "$out"
check "invoke_mcp: NonzeroExit error includes the server's stderr" "NAMES_STDERR True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- still honors invoke_cli's mandatory timeout (not a new, unbounded invocation path) --"
cat >"$CIM_TMPPY/timeout.py" <<'PYEOF'
import collections
import time
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})

start = time.monotonic()
try:
    adapters.invoke_mcp(cap, {}, timeout=1)
    print("RAISED", False)
except adapters.Timeout:
    print("RAISED", True)
elapsed = time.monotonic() - start
print("BOUNDED", elapsed < 10)
PYEOF
out="$(MCP_MODE=hang MCP_HANG_SECONDS=30 cim_run "$CIM_TMPPY/timeout.py" 2>&1)"
check "invoke_mcp: a hung MCP server still raises adapters.Timeout" "RAISED True" "$out"
check "invoke_mcp: kills the process well inside a 10s bound (not the 30s hang)" "BOUNDED True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- server launch argv is never templated/shell-interpreted; injection-shaped tool/param values arrive as literal JSON data --"
cat >"$CIM_TMPPY/injection.py" <<'PYEOF'
import collections
import sys
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather",
                                  "params": {"city": {"type": "string"}}}})

payload = sys.argv[1]
result = adapters.invoke_mcp(cap, {"city": payload})
print("ECHOED_LITERALLY", result.result["echoedArguments"]["city"] == payload)
PYEOF
# shellcheck disable=SC2016  # payloads are single-quoted on purpose -- they must
# reach python as LITERAL text, never shell-expanded by this test harness itself.
for payload in '; rm -rf /' 'a | b' '$(whoami)' 'a && b' '`id`'; do
    out="$(cim_run "$CIM_TMPPY/injection.py" "$payload" 2>&1)"
    check "invoke_mcp: injection-shaped param '$payload' arrives at the tool call byte-for-byte, never interpreted" \
        "ECHOED_LITERALLY True" "$out"
done

# ------------------------------------------------------------------------
# Round 2 (issue #339): line-by-line, id-correlated response parsing
# (MINOR 1) -- json.loads(entire stdout) breaks on real stdio MCP servers
# that emit a notification or a plain log line before the actual reply.
# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- happy path -- a JSON-RPC NOTIFICATION line before the real reply is ignored as noise --"
cat >"$CIM_TMPPY/after_notification.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather",
                                  "params": {"city": {"type": "string"}}}})
result = adapters.invoke_mcp(cap, {"city": "New York"})
print("RESULT", result.result)
PYEOF
out="$(MCP_MODE=ok_after_notification cim_run "$CIM_TMPPY/after_notification.py" 2>&1)"
check "invoke_mcp: a notification line before the reply doesn't break parsing -- the real reply is still found" \
    "RESULT {'echoedTool': 'weather', 'echoedArguments': {'city': 'New York'}}" "$out"

echo "-- unit: invoke_mcp -- happy path -- a plain, non-JSON log line before the real reply is ignored as noise --"
cat >"$CIM_TMPPY/after_log_line.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather",
                                  "params": {"city": {"type": "string"}}}})
result = adapters.invoke_mcp(cap, {"city": "New York"})
print("RESULT", result.result)
PYEOF
out="$(MCP_MODE=ok_after_log_line cim_run "$CIM_TMPPY/after_log_line.py" 2>&1)"
check "invoke_mcp: a non-JSON log line before the reply doesn't break parsing -- the real reply is still found" \
    "RESULT {'echoedTool': 'weather', 'echoedArguments': {'city': 'New York'}}" "$out"

# ------------------------------------------------------------------------
# Round 2 (issue #339): parse-before-returncode (MINOR 2) -- a well-formed
# error reply is authoritative even if the server ALSO exits nonzero.
# ------------------------------------------------------------------------
echo "-- unit: invoke_mcp -- a JSON-RPC error reply AND a nonzero exit -- the richer McpToolError wins over a bare NonzeroExit --"
cat >"$CIM_TMPPY/tool_error_nonzero.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})
try:
    adapters.invoke_mcp(cap, {})
    print("RAISED", False)
    print("RIGHT_TYPE", False)
except adapters.McpToolError as e:
    msg = str(e)
    print("RAISED", True)
    print("RIGHT_TYPE", True)
    print("NAMES_TOOL", "weather" in msg)
    print("NAMES_CODE", "-32000" in msg)
    print("NAMES_MESSAGE", "sidecar offline" in msg)
except adapters.NonzeroExit:
    print("RAISED", True)
    print("RIGHT_TYPE", False, "NonzeroExit (lost the error detail)")
PYEOF
out="$(MCP_MODE=tool_error_nonzero MCP_ERROR_MESSAGE="sidecar offline" cim_run "$CIM_TMPPY/tool_error_nonzero.py" 2>&1)"
check "invoke_mcp: error-reply-and-nonzero-exit raises (something)" "RAISED True" "$out"
check "invoke_mcp: error-reply-and-nonzero-exit raises McpToolError specifically, never a bare NonzeroExit" \
    "RIGHT_TYPE True" "$out"
check "invoke_mcp: the McpToolError still names the tool" "NAMES_TOOL True" "$out"
check "invoke_mcp: the McpToolError still includes the JSON-RPC error code" "NAMES_CODE True" "$out"
check "invoke_mcp: the McpToolError still includes the JSON-RPC error message (not lost to a bare NonzeroExit)" \
    "NAMES_MESSAGE True" "$out"

# ------------------------------------------------------------------------
# Round 2 (issue #339): declaration-shape validation for params SCHEMA and
# params ARGUMENT (MINORs 3/4) -- shared validate_params fix, so these
# also cover invoke_argv (section-capability-invoke.sh keeps its own
# argv-flavor-specific tests; these confirm the shared function itself).
# ------------------------------------------------------------------------
echo "-- unit: validate_params -- a list-shaped params SCHEMA (capability-authoring typo) raises a specific schema error, not a misleading 'not declared' --"
cat >"$CIM_TMPPY/list_schema.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather", "params": ["city"]}})

try:
    adapters.invoke_mcp(cap, {"city": "Rome"})
    print("RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_SCHEMA", "schema" in msg.lower())
    print("NAMES_MAPPING", "mapping" in msg.lower())
    print("MISLEADING_NOT_DECLARED", "not declared" in msg.lower())
PYEOF
out="$(cim_run "$CIM_TMPPY/list_schema.py" 2>&1)"
check "invoke_mcp: a list-shaped invoke.mcp.params raises ParamValidationError" "RAISED True" "$out"
check "invoke_mcp: list-shaped-schema error names it as a schema problem" "NAMES_SCHEMA True" "$out"
check "invoke_mcp: list-shaped-schema error says the schema must be a mapping" "NAMES_MAPPING True" "$out"
check "invoke_mcp: list-shaped-schema error does NOT misleadingly blame the caller with 'not declared'" \
    "MISLEADING_NOT_DECLARED False" "$out"

# Also exercised directly against validate_params (the shared function
# invoke_argv also calls) -- proves the fix isn't invoke_mcp-specific.
cat >"$CIM_TMPPY/list_schema_direct.py" <<'PYEOF'
from assistant import adapters

errs = adapters.validate_params(["city"], {"city": "Rome"})
print("ERRS", errs)
PYEOF
out="$(cim_run "$CIM_TMPPY/list_schema_direct.py" 2>&1)"
check "validate_params: a list-shaped schema argument raises a schema-mapping error directly (shared by both flavors)" \
    "must be a mapping" "$out"

echo "-- unit: invoke_mcp -- a non-mapping params ARGUMENT (e.g. a list) raises a specific error, never a silent {} coercion --"
cat >"$CIM_TMPPY/list_params_arg.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})

try:
    adapters.invoke_mcp(cap, ["Rome"])
    print("RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_MAPPING", "mapping" in msg.lower())
PYEOF
out="$(cim_run "$CIM_TMPPY/list_params_arg.py" 2>&1)"
check "invoke_mcp: a list-shaped params argument raises ParamValidationError (never silently coerced to {})" \
    "RAISED True" "$out"
check "invoke_mcp: list-shaped-params-argument error says params must be a mapping" "NAMES_MAPPING True" "$out"

# Also exercised directly against validate_params (shared by invoke_argv).
cat >"$CIM_TMPPY/list_params_arg_direct.py" <<'PYEOF'
from assistant import adapters

errs = adapters.validate_params({"city": {"type": "string"}}, ["Rome"])
print("ERRS", errs)
PYEOF
out="$(cim_run "$CIM_TMPPY/list_params_arg_direct.py" 2>&1)"
check "validate_params: a list-shaped params argument raises a params-mapping error directly (shared by both flavors)" \
    "must be a mapping" "$out"

# Positive control: None for either (the normal "nothing declared/supplied"
# case) must NOT trip the new mapping checks.
cat >"$CIM_TMPPY/none_is_fine.py" <<'PYEOF'
from assistant import adapters

print("SCHEMA_NONE_ERRS", adapters.validate_params(None, {}))
print("PARAMS_NONE_ERRS", adapters.validate_params({}, None))
print("BOTH_NONE_ERRS", adapters.validate_params(None, None))
PYEOF
out="$(cim_run "$CIM_TMPPY/none_is_fine.py" 2>&1)"
check "validate_params: schema=None is still the normal no-schema-declared case (no error)" "SCHEMA_NONE_ERRS []" "$out"
check "validate_params: params=None is still the normal no-params-supplied case (no error)" "PARAMS_NONE_ERRS []" "$out"
check "validate_params: both None together is still fine (no error)" "BOTH_NONE_ERRS []" "$out"
