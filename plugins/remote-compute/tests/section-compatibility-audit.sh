#!/usr/bin/env bash
# Keep section-local state inside a function: the suite sources every section.
declare -F check >/dev/null 2>&1 || { echo "run tests/run-tests.sh" >&2; exit 2; }
compatibility_audit_section() {
    local audit_output audit_rc
    audit_output="$(python3 "$PLUGIN/tests/test_compatibility_audit.py" 2>&1)"
    audit_rc=$?
    check_rc "CDX-050 bounded audit contract and hermetic probes" 0 "$audit_rc"
    echo "$audit_output"
}
compatibility_audit_section
unset -f compatibility_audit_section
