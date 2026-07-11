#!/usr/bin/env bash
# section-syntax.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
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

# SUPERSEDED (#45): this section used to also grep scripts/*.sh for the one
# 3.12+-only nested-quote f-string pattern (e.g. f"{it["id"]}"). That check
# now lives in section-snippet-lint.sh's scripts/snippet-lint.py, which
# folds it into a gate-wide version-floor lint over every inline python3 -c
# / heredoc snippet (both scripts/ and tests/) PLUS a bash-3.2-floor
# construct check -- generalizing this single pattern instead of duplicating
# it here. Perturbation-tested before removal: reintroducing this exact
# pattern into a scratch copy of a real script (board.sh) was confirmed
# caught by the new lint (see the retro/PR notes for #45).

