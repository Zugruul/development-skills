#!/usr/bin/env bash
# section-codex-skill-lint.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# Asserts that EVERY SKILL.md in every shipped plugin passes Codex's skill
# linter (quick_validate.py). The most common failure it guards is angle
# brackets (< or >) in the `description:` frontmatter, which Codex rejects
# outright (CDX-005) -- but the check is the whole validator, so any future
# name/length/shape violation is caught too. The validator lives OUTSIDE this
# repo (in the skill-creator system skill), so when it is unavailable we SKIP
# with a visible note rather than crashing the suite or spuriously failing an
# environment that simply can't run the external check.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== codex-skill-lint =="

CODEX_SKILL_VALIDATOR="$HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py"
REPO="$(cd "$PLUGIN/../.." && pwd)"

if [[ ! -f "$CODEX_SKILL_VALIDATOR" ]] || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "SKIP codex skill lint — validator ($CODEX_SKILL_VALIDATOR) or python 'yaml' package unavailable"
else
    for skill in "$REPO"/plugins/*/skills/*/; do
        [[ -f "$skill/SKILL.md" ]] || continue
        rel="${skill#"$REPO"/}"
        out="$(python3 "$CODEX_SKILL_VALIDATOR" "$skill" 2>&1)"; rc=$?
        check_rc "$rel: validator exits 0" 0 "$rc"
        check "$rel: validator reports valid" "valid" "$out"
    done
fi
