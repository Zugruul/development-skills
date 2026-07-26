#!/usr/bin/env bash
# section-capability-index.sh -- AST-060: capability.yaml schema + version
# negotiation (SPEC-ASSISTANT.md §11.1, §11.6). Sourced by run-tests.sh; do
# not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant.capability_index (AST-060: capability.yaml schema + version negotiation, SPEC-ASSISTANT.md §11.1/§11.6) =="

CI_SCRIPTS="$PLUGIN/scripts"

ci_py() { # $1: python3 -c snippet body (assistant.capability_index importable); $2..: sys.argv[1:]
    local script="$1"; shift
    PLUGIN_SCRIPTS="$CI_SCRIPTS" python3 -c '
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
from assistant import capability_index as ci
'"$script" "$@"
}

# ci_skill_dir <capability.yaml body...> -- writes a fresh skill dir with the
# given capability.yaml content, prints the dir path.
ci_skill_dir() {
    local d; d="$(mktemp -d)"
    printf '%s\n' "$@" >"$d/capability.yaml"
    printf '%s' "$d"
}

# ------------------------------------------------------ well-formed, version 1
CI_D="$(ci_skill_dir \
    'version: 1' \
    'provisioning:' \
    '    check: ["which", "some-bin"]' \
    '    ttlSeconds: 300' \
    'permissions: ["net.read"]' \
    'invoke:' \
    '    exec: ["some-bin", "--flag"]')"
out="$(ci_py '
cap = ci.load_capability(sys.argv[1])
print(type(cap).__name__)
print(cap.version)
' "$CI_D")"
check "well-formed v1 capability.yaml loads as Capability" "Capability" "$out"
check "well-formed v1 capability.yaml: version is 1" "1" "$out"
rm -rf "$CI_D"

# ------------------------------------------------------ well-formed, permissions: [] (empty list is a valid, not just non-empty, permissions value)
CI_D="$(ci_skill_dir \
    'version: 1' \
    'provisioning:' \
    '    check: ["which", "some-bin"]' \
    '    ttlSeconds: 300' \
    'permissions: []' \
    'invoke:' \
    '    exec: ["some-bin"]')"
out="$(ci_py '
cap = ci.load_capability(sys.argv[1])
print(type(cap).__name__)
print(cap.permissions)
' "$CI_D")"
check "permissions: [] (empty list) loads as Capability, not rejected" "Capability" "$out"
check "permissions: [] round-trips as an empty list on the Capability" "[]" "$out"
rm -rf "$CI_D"

# ------------------------------------------------------ version: true (bool)
CI_D="$(ci_skill_dir \
    'version: true' \
    'provisioning:' \
    '    check: ["which", "some-bin"]' \
    '    ttlSeconds: 300' \
    'permissions: []' \
    'invoke:' \
    '    exec: ["some-bin"]')"
out="$(ci_py '
cap = ci.load_capability(sys.argv[1])
print(type(cap).__name__)
' "$CI_D")"
check "version: true (bool) is rejected, not silently version 1" "CapabilityError" "$out"
rm -rf "$CI_D"

# ------------------------------------------------------ version: 1.0 (float == in-range int)
CI_D="$(ci_skill_dir \
    'version: 1.0' \
    'provisioning:' \
    '    check: ["which", "some-bin"]' \
    '    ttlSeconds: 300' \
    'permissions: []' \
    'invoke:' \
    '    exec: ["some-bin"]')"
out="$(ci_py '
cap = ci.load_capability(sys.argv[1])
print(type(cap).__name__)
' "$CI_D")"
check "version: 1.0 (float) is rejected despite equalling an in-range int" "CapabilityError" "$out"
rm -rf "$CI_D"

# ------------------------------------------------------ out-of-range version
CI_D="$(ci_skill_dir \
    'version: 2' \
    'provisioning:' \
    '    check: ["which", "some-bin"]' \
    '    ttlSeconds: 300' \
    'permissions: []' \
    'invoke:' \
    '    exec: ["some-bin"]')"
out="$(ci_py '
cap = ci.load_capability(sys.argv[1])
print(type(cap).__name__)
print(cap.reason)
' "$CI_D")"
check "out-of-range version (2) yields a CapabilityError, not an exception" "CapabilityError" "$out"
check "out-of-range version reason names the unsupported version" "version 2" "$out"
check "out-of-range version reason says never executed" "never executed" "$out"
rm -rf "$CI_D"

out_rc="$(ci_py '
try:
    cap = ci.load_capability(sys.argv[1])
    print("NO-RAISE")
except Exception as e:
    print("RAISED:" + type(e).__name__)
' "$(ci_skill_dir \
    'version: 2' \
    'provisioning:' \
    '    check: ["which", "some-bin"]' \
    '    ttlSeconds: 300' \
    'permissions: []' \
    'invoke:' \
    '    exec: ["some-bin"]')")"
check "out-of-range version never raises" "NO-RAISE" "$out_rc"

# ------------------------------------------------------ missing version key
CI_D="$(ci_skill_dir \
    'provisioning:' \
    '    check: ["which", "some-bin"]' \
    '    ttlSeconds: 300' \
    'permissions: []' \
    'invoke:' \
    '    exec: ["some-bin"]')"
out="$(ci_py '
cap = ci.load_capability(sys.argv[1])
print(type(cap).__name__)
print(cap.reason)
' "$CI_D")"
check "missing version key: CapabilityError" "CapabilityError" "$out"
check "missing version key: reason names the missing field" "missing required key 'version'" "$out"
rm -rf "$CI_D"

# ------------------------------------------------------ invoke missing both exec and mcp
CI_D="$(ci_skill_dir \
    'version: 1' \
    'provisioning:' \
    '    check: ["which", "some-bin"]' \
    '    ttlSeconds: 300' \
    'permissions: []' \
    'invoke: {}')"
out="$(ci_py '
cap = ci.load_capability(sys.argv[1])
print(type(cap).__name__)
print(cap.reason)
' "$CI_D")"
check "invoke missing both exec and mcp: CapabilityError" "CapabilityError" "$out"
check "invoke missing both exec and mcp: reason names invoke" "invoke" "$out"
rm -rf "$CI_D"

# ------------------------------------------------------ invoke: exec argv flavor validates structurally
out="$(ci_py '
cap = {
    "version": 1,
    "provisioning": {"check": ["which", "x"], "ttlSeconds": 60},
    "permissions": [],
    "invoke": {"exec": ["x", "--flag"]},
}
errs = ci.validate_capability(cap)
print(errs)
')"
check "invoke: {exec: [...]} validates with no errors" "[]" "$out"

# ------------------------------------------------------ invoke: mcp flavor validates structurally
out="$(ci_py '
cap = {
    "version": 1,
    "provisioning": {"check": ["which", "x"], "ttlSeconds": 60},
    "permissions": [],
    "invoke": {"mcp": {"command": ["x"], "args": []}},
}
errs = ci.validate_capability(cap)
print(errs)
')"
check "invoke: {mcp: {...}} validates with no errors" "[]" "$out"

# ------------------------------------------------------ invoke with BOTH exec and mcp is rejected
out="$(ci_py '
cap = {
    "version": 1,
    "provisioning": {"check": ["which", "x"], "ttlSeconds": 60},
    "permissions": [],
    "invoke": {"exec": ["x"], "mcp": {}},
}
errs = ci.validate_capability(cap)
print(errs)
')"
check "invoke with both exec and mcp is rejected" "exactly one of 'exec' or 'mcp'" "$out"

# ------------------------------------------------------ malformed provisioning (missing ttlSeconds)
out="$(ci_py '
cap = {
    "version": 1,
    "provisioning": {"check": ["which", "x"]},
    "permissions": [],
    "invoke": {"exec": ["x"]},
}
errs = ci.validate_capability(cap)
print(errs)
')"
check "missing provisioning.ttlSeconds names the exact field" "provisioning: missing required key 'ttlSeconds'" "$out"

# ------------------------------------------------------ SUPPORTED_VERSION_RANGE constant
out="$(ci_py '
print(ci.SUPPORTED_VERSION_RANGE)
')"
check "SUPPORTED_VERSION_RANGE is (1, 1) -- v1 ships exactly one supported version" "(1, 1)" "$out"
