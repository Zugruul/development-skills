#!/usr/bin/env bash
# section-capability-invoke.sh -- AST-063: argv-array invoke with
# schema-validated params (SPEC-ASSISTANT.md Sec11.5, Sec17.3, issue #338,
# docs/design/ast-E6.md). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant.adapters.invoke_argv (AST-063: argv-array invoke with schema-validated params, SPEC-ASSISTANT.md Sec11.5/Sec17.3) =="

CI_SCRIPTS="$PLUGIN/scripts"
CI_STUB_BIN="$FIX/stub-argv-echo"

# ci_run <python-body-file> -- runs python3 with the stub argvecho binary on
# a controlled PATH (never an ambient binary -- house lesson
# hermetic-path-fixtures-for-cli-tests), scripts/ on PYTHONPATH.
ci_run() {
    local body="$1"
    shift
    PATH="$CI_STUB_BIN:$PATH" PYTHONPATH="$CI_SCRIPTS" python3 "$body" "$@"
}

CI_TMPPY="$(mktemp -d)"

# ------------------------------------------------------------------------
echo "-- static: adapters.py never spawns a subprocess with shell=True (Sec17.3 -- no shell anywhere in the invoke path) --"
adapters_src="$(cat "$CI_SCRIPTS/assistant/adapters.py")"
check_absent "adapters.py: no shell=True anywhere in the file" "shell=True" "$adapters_src"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- happy path -- substitutes params into a templated exec argv and runs it via invoke_cli --"
cat >"$CI_TMPPY/happy.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--city={city}", "--unit={unit}"],
                          "params": {"city": {"type": "string"},
                                     "unit": {"type": "string", "allowlist": ["celsius", "fahrenheit"]}}})

result = adapters.invoke_argv(cap, {"city": "New York", "unit": "celsius"})
print("RC", result.returncode)
print("ARGV", result.argv)
print("STDOUT_HAS_CITY", "ARGV[0]=--city=New York" in result.stdout)
print("STDOUT_HAS_UNIT", "ARGV[1]=--unit=celsius" in result.stdout)
PYEOF
out="$(ci_run "$CI_TMPPY/happy.py" 2>&1)"
check "invoke_argv: exits 0 for a passing stub" "RC 0" "$out"
check "invoke_argv: returned argv is the substituted argv array" \
    "ARGV ['argvecho', '--city=New York', '--unit=celsius']" "$out"
check "invoke_argv: the child process actually received the substituted city" "STDOUT_HAS_CITY True" "$out"
check "invoke_argv: the child process actually received the substituted unit" "STDOUT_HAS_UNIT True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- placeholder substitution occurs only WITHIN a single argv element (Sec11.5), never spans/creates elements --"
cat >"$CI_TMPPY/single_element.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "prefix-{a}-{b}-suffix"],
                          "params": {"a": {"type": "string"}, "b": {"type": "string"}}})

result = adapters.invoke_argv(cap, {"a": "X;Y", "b": "Z|W"})
print("ARGC", len(result.argv))
print("ELEMENT", result.argv[-1])
lines = [l for l in result.stdout.splitlines() if l.startswith("ARGV[")]
print("N_ARGV_LINES", len(lines))
PYEOF
out="$(ci_run "$CI_TMPPY/single_element.py" 2>&1)"
check "invoke_argv: two placeholders in one template element still yield ONE argv element" "ARGC 2" "$out"
check "invoke_argv: both placeholders substituted within that single element, literally" \
    "ELEMENT prefix-X;Y-Z|W-suffix" "$out"
check "invoke_argv: the child process saw exactly ONE argv element for the templated slot (no word-splitting)" \
    "N_ARGV_LINES 1" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- injection-attempt fixtures land as literal argv text, never interpreted (Sec17.3) --"
cat >"$CI_TMPPY/injection.py" <<'PYEOF'
import collections
import sys
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--city={city}"],
                          "params": {"city": {"type": "string"}}})

payload = sys.argv[1]
result = adapters.invoke_argv(cap, {"city": payload})
lines = [l for l in result.stdout.splitlines() if l.startswith("ARGV[")]
print("N_ARGV_LINES", len(lines))
print("LITERAL_LINE_MATCH", lines == [f"ARGV[0]=--city={payload}"])
PYEOF
# shellcheck disable=SC2016  # payloads are single-quoted on purpose -- they must
# reach python as LITERAL text, never shell-expanded by this test harness itself.
for payload in '; rm -rf /' 'a | b' '$(whoami)' 'a && b' '`id`'; do
    out="$(ci_run "$CI_TMPPY/injection.py" "$payload" 2>&1)"
    check "invoke_argv: injection payload '$payload' -- exactly one literal argv line, never split/expanded" \
        "N_ARGV_LINES 1" "$out"
    check "invoke_argv: injection payload '$payload' -- arrives byte-for-byte, never interpreted" \
        "LITERAL_LINE_MATCH True" "$out"
done

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- missing required param -- specific error names the param --"
cat >"$CI_TMPPY/missing.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--city={city}"],
                          "params": {"city": {"type": "string"}}})

try:
    adapters.invoke_argv(cap, {})
    print("RAISED", False)
except adapters.ParamValidationError as e:
    print("RAISED", True)
    print("NAMES_PARAM", "city" in str(e))
    print("NAMES_MISSING", "missing" in str(e).lower())
PYEOF
out="$(ci_run "$CI_TMPPY/missing.py" 2>&1)"
check "invoke_argv: missing required param raises ParamValidationError" "RAISED True" "$out"
check "invoke_argv: missing-param error names the offending param" "NAMES_PARAM True" "$out"
check "invoke_argv: missing-param error names the constraint kind (missing/required)" "NAMES_MISSING True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- type mismatch -- specific error names param, constraint kind, and the offending value shape --"
cat >"$CI_TMPPY/type_mismatch.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--city={city}"],
                          "params": {"city": {"type": "string"}}})

try:
    adapters.invoke_argv(cap, {"city": 42})
    print("RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_PARAM", "city" in msg)
    print("NAMES_TYPE", "type" in msg.lower())
    print("NAMES_OFFENDING_VALUE", "42" in msg)
PYEOF
out="$(ci_run "$CI_TMPPY/type_mismatch.py" 2>&1)"
check "invoke_argv: wrong-typed param raises ParamValidationError" "RAISED True" "$out"
check "invoke_argv: type error names the offending param" "NAMES_PARAM True" "$out"
check "invoke_argv: type error names the constraint kind (type)" "NAMES_TYPE True" "$out"
check "invoke_argv: type error shows the offending value" "NAMES_OFFENDING_VALUE True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- bool-before-int-guard: a bool never masquerades as a valid 'int' param (house lesson) --"
cat >"$CI_TMPPY/bool_guard.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--count={count}"],
                          "params": {"count": {"type": "int"}}})

# isinstance(True, int) is True -- a bool must NOT pass an 'int' param check.
try:
    adapters.invoke_argv(cap, {"count": True})
    print("RAISED", False)
except adapters.ParamValidationError as e:
    print("RAISED", True)
    print("NAMES_PARAM", "count" in str(e))

# A genuine int still passes.
result = adapters.invoke_argv(cap, {"count": 3})
print("REAL_INT_RC", result.returncode)
PYEOF
out="$(ci_run "$CI_TMPPY/bool_guard.py" 2>&1)"
check "invoke_argv: a bool value is rejected for an 'int'-typed param" "RAISED True" "$out"
check "invoke_argv: bool-rejection error names the offending param" "NAMES_PARAM True" "$out"
check "invoke_argv: a genuine int still validates and runs fine" "REAL_INT_RC 0" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- pattern mismatch -- specific error names param, pattern, and offending value --"
cat >"$CI_TMPPY/pattern.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--zip={zip}"],
                          "params": {"zip": {"type": "string", "pattern": "^[0-9]{5}$"}}})

try:
    adapters.invoke_argv(cap, {"zip": "abc"})
    print("RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_PARAM", "zip" in msg)
    print("NAMES_PATTERN", "pattern" in msg.lower())
    print("NAMES_OFFENDING_VALUE", "abc" in msg)

result = adapters.invoke_argv(cap, {"zip": "94110"})
print("VALID_RC", result.returncode)
PYEOF
out="$(ci_run "$CI_TMPPY/pattern.py" 2>&1)"
check "invoke_argv: pattern-violating param raises ParamValidationError" "RAISED True" "$out"
check "invoke_argv: pattern error names the offending param" "NAMES_PARAM True" "$out"
check "invoke_argv: pattern error names the constraint kind (pattern)" "NAMES_PATTERN True" "$out"
check "invoke_argv: pattern error shows the offending value" "NAMES_OFFENDING_VALUE True" "$out"
check "invoke_argv: a pattern-matching value still validates and runs fine" "VALID_RC 0" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- allowlist violation -- specific error names param, allowed values, and offending value --"
cat >"$CI_TMPPY/allowlist.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--unit={unit}"],
                          "params": {"unit": {"type": "string", "allowlist": ["celsius", "fahrenheit"]}}})

try:
    adapters.invoke_argv(cap, {"unit": "kelvin"})
    print("RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_PARAM", "unit" in msg)
    print("NAMES_ALLOWLIST", "allowlist" in msg.lower())
    print("NAMES_OFFENDING_VALUE", "kelvin" in msg)
    print("NAMES_ALLOWED_VALUES", "celsius" in msg and "fahrenheit" in msg)
PYEOF
out="$(ci_run "$CI_TMPPY/allowlist.py" 2>&1)"
check "invoke_argv: not-allowlisted param raises ParamValidationError" "RAISED True" "$out"
check "invoke_argv: allowlist error names the offending param" "NAMES_PARAM True" "$out"
check "invoke_argv: allowlist error names the constraint kind (allowlist)" "NAMES_ALLOWLIST True" "$out"
check "invoke_argv: allowlist error shows the offending value" "NAMES_OFFENDING_VALUE True" "$out"
check "invoke_argv: allowlist error shows the allowed values" "NAMES_ALLOWED_VALUES True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- undeclared param -- specific error names it, distinct from a missing-required error --"
cat >"$CI_TMPPY/undeclared.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--city={city}"],
                          "params": {"city": {"type": "string"}}})

try:
    adapters.invoke_argv(cap, {"city": "Rome", "extra": "surprise"})
    print("RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_PARAM", "extra" in msg)
    print("NAMES_UNDECLARED", "declared" in msg.lower())
PYEOF
out="$(ci_run "$CI_TMPPY/undeclared.py" 2>&1)"
check "invoke_argv: an undeclared param raises ParamValidationError" "RAISED True" "$out"
check "invoke_argv: undeclared-param error names the offending param" "NAMES_PARAM True" "$out"
check "invoke_argv: undeclared-param error names the constraint kind (not declared)" "NAMES_UNDECLARED True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- validation runs BEFORE execution -- an invalid call never even spawns the child process --"
CI_CALL_LOG="$(mktemp -u)"
cat >"$CI_TMPPY/never_spawns.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--city={city}"],
                          "params": {"city": {"type": "string"}}})

try:
    adapters.invoke_argv(cap, {"city": 42})
except adapters.ParamValidationError:
    pass
PYEOF
ARGVECHO_CALL_LOG="$CI_CALL_LOG" ci_run "$CI_TMPPY/never_spawns.py" >/dev/null 2>&1
if [[ -f "$CI_CALL_LOG" ]]; then
    check_rc "invoke_argv: an invalid call must not create the child's call-log file (never spawned)" 1 0
else
    echo "ok   invoke_argv: an invalid call never spawns the child process (no call-log file created)"
fi
rm -f "$CI_CALL_LOG"

# Positive control (house pattern, mirrors #337's disabled-capability test):
# the "never spawns" proof above is only meaningful alongside proof that a
# VALID call DOES spawn -- otherwise a broken invoke_argv that never calls
# invoke_cli at all would pass the negative check for the wrong reason.
CI_CALL_LOG2="$(mktemp -u)"
cat >"$CI_TMPPY/does_spawn.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--city={city}"],
                          "params": {"city": {"type": "string"}}})
adapters.invoke_argv(cap, {"city": "Rome"})
PYEOF
ARGVECHO_CALL_LOG="$CI_CALL_LOG2" ci_run "$CI_TMPPY/does_spawn.py" >/dev/null 2>&1
if [[ -f "$CI_CALL_LOG2" ]]; then
    echo "ok   invoke_argv: positive control -- a VALID call DOES create the child's call-log file (actually spawns)"
else
    echo "FAIL invoke_argv: positive control -- a VALID call must spawn the child process (call-log file missing)"
    fails=$((fails + 1))
fi
rm -f "$CI_CALL_LOG2"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- required:false, param omitted and NOT referenced by any placeholder -- succeeds --"
cat >"$CI_TMPPY/optional_unreferenced.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--fixed=1"],
                          "params": {"flag": {"type": "string", "required": False}}})

result = adapters.invoke_argv(cap, {})
print("RC", result.returncode)
PYEOF
out="$(ci_run "$CI_TMPPY/optional_unreferenced.py" 2>&1)"
check "invoke_argv: an omitted optional param with no placeholder reference runs fine" "RC 0" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- required:false, param omitted but STILL referenced by a placeholder -- specific error (MAJOR fix) --"
cat >"$CI_TMPPY/optional_referenced.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--flag={flag}"],
                          "params": {"flag": {"type": "string", "required": False}}})

try:
    adapters.invoke_argv(cap, {})
    print("RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_PARAM", "flag" in msg)
    print("NAMES_PLACEHOLDER", "placeholder" in msg.lower())

# Supplying it explicitly still works fine.
result = adapters.invoke_argv(cap, {"flag": "on"})
print("SUPPLIED_RC", result.returncode)
PYEOF
out="$(ci_run "$CI_TMPPY/optional_referenced.py" 2>&1)"
check "invoke_argv: an optional param omitted but referenced by a placeholder raises ParamValidationError (never a raw KeyError)" \
    "RAISED True" "$out"
check "invoke_argv: the placeholder-coverage error names the offending param" "NAMES_PARAM True" "$out"
check "invoke_argv: the placeholder-coverage error names the constraint kind (placeholder)" "NAMES_PLACEHOLDER True" "$out"
check "invoke_argv: the same optional param, explicitly supplied, runs fine" "SUPPLIED_RC 0" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- malformed regex in a param's own schema -- specific error, never a raw re.error (MAJOR fix) --"
cat >"$CI_TMPPY/bad_pattern.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--x={x}"],
                          "params": {"x": {"type": "string", "pattern": "[unclosed"}}})

try:
    adapters.invoke_argv(cap, {"x": "abc"})
    print("RAISED", False)
    print("RIGHT_TYPE", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("RIGHT_TYPE", True)
    print("NAMES_PARAM", "x" in msg)
    print("NAMES_PATTERN_TEXT", "[unclosed" in msg)
except Exception as e:
    print("RAISED", True)
    print("RIGHT_TYPE", False, type(e).__name__)
PYEOF
out="$(ci_run "$CI_TMPPY/bad_pattern.py" 2>&1)"
check "invoke_argv: a malformed schema regex raises (something)" "RAISED True" "$out"
check "invoke_argv: a malformed schema regex raises ParamValidationError specifically, never a raw re.error" "RIGHT_TYPE True" "$out"
check "invoke_argv: malformed-regex error names the offending param" "NAMES_PARAM True" "$out"
check "invoke_argv: malformed-regex error includes the bad pattern text" "NAMES_PATTERN_TEXT True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- non-string invoke.exec element -- specific error, never a raw TypeError (MAJOR fix) --"
cat >"$CI_TMPPY/bad_exec_element.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", 5], "params": {}})

try:
    adapters.invoke_argv(cap, {})
    print("RAISED", False)
    print("RIGHT_TYPE", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("RIGHT_TYPE", True)
    print("NAMES_INDEX", "[1]" in msg)
    print("NAMES_GOT_INT", "int" in msg)
except Exception as e:
    print("RAISED", True)
    print("RIGHT_TYPE", False, type(e).__name__)
PYEOF
out="$(ci_run "$CI_TMPPY/bad_exec_element.py" 2>&1)"
check "invoke_argv: a non-string invoke.exec element raises (something)" "RAISED True" "$out"
check "invoke_argv: a non-string invoke.exec element raises ParamValidationError specifically, never a raw TypeError" \
    "RIGHT_TYPE True" "$out"
check "invoke_argv: non-string-element error names the offending index" "NAMES_INDEX True" "$out"
check "invoke_argv: non-string-element error names the offending type" "NAMES_GOT_INT True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- 'number' type accepts int and float, rejects bool and non-numeric --"
cat >"$CI_TMPPY/number_type.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--n={n}"], "params": {"n": {"type": "number"}}})

print("INT_RC", adapters.invoke_argv(cap, {"n": 3}).returncode)
print("FLOAT_RC", adapters.invoke_argv(cap, {"n": 3.5}).returncode)

try:
    adapters.invoke_argv(cap, {"n": True})
    print("BOOL_RAISED", False)
except adapters.ParamValidationError:
    print("BOOL_RAISED", True)

try:
    adapters.invoke_argv(cap, {"n": "not-a-number"})
    print("STR_RAISED", False)
except adapters.ParamValidationError:
    print("STR_RAISED", True)
PYEOF
out="$(ci_run "$CI_TMPPY/number_type.py" 2>&1)"
check "invoke_argv: 'number' type accepts an int" "INT_RC 0" "$out"
check "invoke_argv: 'number' type accepts a float" "FLOAT_RC 0" "$out"
check "invoke_argv: 'number' type rejects a bool (bool-before-int-guard)" "BOOL_RAISED True" "$out"
check "invoke_argv: 'number' type rejects a non-numeric string" "STR_RAISED True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- 'bool' type accepts only real booleans --"
cat >"$CI_TMPPY/bool_type.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--b={b}"], "params": {"b": {"type": "bool"}}})

print("TRUE_RC", adapters.invoke_argv(cap, {"b": True}).returncode)
print("FALSE_RC", adapters.invoke_argv(cap, {"b": False}).returncode)

try:
    adapters.invoke_argv(cap, {"b": 1})
    print("INT_RAISED", False)
except adapters.ParamValidationError:
    print("INT_RAISED", True)
PYEOF
out="$(ci_run "$CI_TMPPY/bool_type.py" 2>&1)"
check "invoke_argv: 'bool' type accepts True" "TRUE_RC 0" "$out"
check "invoke_argv: 'bool' type accepts False" "FALSE_RC 0" "$out"
check "invoke_argv: 'bool' type rejects a plain int (1 is not a bool)" "INT_RAISED True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- unknown declared type -- specific schema error --"
cat >"$CI_TMPPY/unknown_type.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--x={x}"], "params": {"x": {"type": "money"}}})

try:
    adapters.invoke_argv(cap, {"x": "5"})
    print("RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_PARAM", "x" in msg)
    print("NAMES_UNKNOWN_TYPE", "money" in msg)
PYEOF
out="$(ci_run "$CI_TMPPY/unknown_type.py" 2>&1)"
check "invoke_argv: an unknown declared type raises ParamValidationError" "RAISED True" "$out"
check "invoke_argv: unknown-type error names the offending param" "NAMES_PARAM True" "$out"
check "invoke_argv: unknown-type error names the unknown type itself" "NAMES_UNKNOWN_TYPE True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- 'pattern' declared on a non-string type -- specific schema error --"
cat >"$CI_TMPPY/pattern_on_non_string.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--n={n}"],
                          "params": {"n": {"type": "int", "pattern": "^[0-9]+$"}}})

try:
    adapters.invoke_argv(cap, {"n": 5})
    print("RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_PARAM", "n" in msg)
    print("NAMES_PATTERN_ONLY_STRING", "only valid for type" in msg)
PYEOF
out="$(ci_run "$CI_TMPPY/pattern_on_non_string.py" 2>&1)"
check "invoke_argv: 'pattern' on a non-string-typed param raises ParamValidationError" "RAISED True" "$out"
check "invoke_argv: pattern-on-non-string error names the offending param" "NAMES_PARAM True" "$out"
check "invoke_argv: pattern-on-non-string error explains the constraint (only valid for type 'string')" \
    "NAMES_PATTERN_ONLY_STRING True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- non-mapping param spec entry -- specific schema error --"
cat >"$CI_TMPPY/non_mapping_spec.py" <<'PYEOF'
import collections
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho", "--x={x}"], "params": {"x": "not-a-mapping"}})

try:
    adapters.invoke_argv(cap, {"x": "5"})
    print("RAISED", False)
except adapters.ParamValidationError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_PARAM", "x" in msg)
    print("NAMES_MAPPING", "mapping" in msg.lower())
PYEOF
out="$(ci_run "$CI_TMPPY/non_mapping_spec.py" 2>&1)"
check "invoke_argv: a non-mapping param spec entry raises ParamValidationError" "RAISED True" "$out"
check "invoke_argv: non-mapping-spec error names the offending param" "NAMES_PARAM True" "$out"
check "invoke_argv: non-mapping-spec error names the constraint kind (must be a mapping)" "NAMES_MAPPING True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_argv -- still honors invoke_cli's mandatory timeout (not a new, unbounded invocation path) --"
cat >"$CI_TMPPY/timeout.py" <<'PYEOF'
import collections
import time
from assistant import adapters

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={"check": ["true"], "ttlSeconds": 60}, permissions=[],
                  invoke={"exec": ["argvecho"], "params": {}})

start = time.monotonic()
try:
    adapters.invoke_argv(cap, {}, timeout=1)
    print("RAISED", False)
except adapters.Timeout:
    print("RAISED", True)
elapsed = time.monotonic() - start
print("BOUNDED", elapsed < 10)
PYEOF
out="$(ARGVECHO_MODE=hang ARGVECHO_HANG_SECONDS=30 ci_run "$CI_TMPPY/timeout.py" 2>&1)"
check "invoke_argv: a hung invoke.exec still raises adapters.Timeout" "RAISED True" "$out"
check "invoke_argv: kills the process well inside a 10s bound (not the 30s hang)" "BOUNDED True" "$out"
