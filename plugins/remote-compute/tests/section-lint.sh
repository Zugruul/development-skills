#!/usr/bin/env bash
# section-lint.sh -- sourced by run-tests.sh; do not run standalone.
# Lint parity with the coverage the moved files had (or should have had) under
# spec-workflow's suite: byte-compile every Python file (closing the
# pre-existing gap — nothing py_compile'd remote-compute.py before the
# extraction), run spec-workflow's snippet-lint over this plugin's tree, and
# keep the "no skill invokes a .py via bash" rule.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/remote-compute/tests/run-tests.sh" >&2; exit 2; }
echo "== lint: py_compile / snippet-lint / no bash-invoked .py =="

while IFS= read -r py; do
    out="$(python3 -m py_compile "$py" 2>&1)"; rc=$?
    check_rc "py_compile ${py#"$PLUGIN"/}" 0 "$rc"
    [[ $rc -ne 0 ]] && echo "     $out"
done < <(find "$PLUGIN/scripts" -name '*.py' | sort)

out="$(python3 "$SW/scripts/snippet-lint.py" "$PLUGIN" 2>&1)"; rc=$?
check_rc "snippet-lint over plugins/remote-compute exits 0" 0 "$rc"
[[ $rc -ne 0 ]] && echo "     $out"

bad="$(grep -rnE '(^|[^a-zA-Z0-9_])bash +"[^"]*\.py"' "$PLUGIN/skills/" 2>/dev/null || true)"
check_absent "no skill invokes a .py via bash" ".py" "$bad"
