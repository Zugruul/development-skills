#!/usr/bin/env bash
# section-syntax.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
echo "== syntax =="
# Checks run-tests.sh, _lib.sh, and every section-*.sh (superset of the old
# single-file check -- the split itself now gets syntax-checked too).
for f in "$PLUGIN"/scripts/*.sh "$HERE"/*.sh; do
    if bash -n "$f"; then echo "ok   bash -n $(basename "$f")"; else echo "FAIL bash -n $f"; fails=$((fails + 1)); fi
done
for p in config.py identity_lib.py validate-config.py next.py similar.py ui-hub.py brain.py neural-view.py feedback.py telemetry.py; do
    if python3 -m py_compile "$PLUGIN/scripts/$p"; then
        echo "ok   py_compile $p"
    else
        echo "FAIL py_compile $p"; fails=$((fails + 1))
    fi
done
# anti-pattern: a .py script invoked via `bash` in a skill doc — dies parsing the docstring
# shellcheck disable=SC2016  # single quotes are intentional: this is a grep pattern, not a shell expansion
bad_invocations="$(grep -rn 'bash "\${CLAUDE_PLUGIN_ROOT}/scripts/[^"]*\.py"' "$PLUGIN"/skills/ 2>/dev/null || true)"
if [[ -z "$bad_invocations" ]]; then
    echo "ok   no skill invokes a .py script via bash"
else
    echo "FAIL skill(s) invoke a .py script via bash (must be python3):"
    echo "$bad_invocations"
    fails=$((fails + 1))
fi

# anti-pattern: an inline `python3 -c` embedded in a .sh script uses an f-string whose
# quote delimiter (") is nested inside its own {} expression -- e.g. f"{it["id"]}". That is
# only valid on Python 3.12+ (PEP 701); it raises a SyntaxError on the stock python3 shipped
# with macOS <= 14, Ubuntu <= 22.04, Debian 11/12, RHEL 8/9. py_compile above only checks
# standalone .py files and never sees inline `python3 -c` snippets, so this class of bug is
# otherwise invisible until it hits an interpreter older than whatever's first on the
# dev/CI PATH. Static, interpreter-independent: no old python3 needs to be installed.
inline_py_fstring_bugs=""
for f in "$PLUGIN"/scripts/*.sh; do
    hit="$(grep -nE 'f"[^"{}]*\{[^{}]*"[^{}]*\}' "$f" || true)"
    [[ -n "$hit" ]] && inline_py_fstring_bugs+="$f: $hit"$'\n'
done
if [[ -z "$inline_py_fstring_bugs" ]]; then
    echo "ok   no inline python3 -c f-string nests its own quote char in a {} expression (3.12+-only)"
else
    echo "FAIL inline python3 -c f-string nests its own quote char in a {} expression -- 3.12+-only syntax, breaks on older stock python3:"
    echo "$inline_py_fstring_bugs"
    fails=$((fails + 1))
fi

