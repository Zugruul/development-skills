#!/usr/bin/env bash
# section-conventional-commit-mandate.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# #406: the repo's CHANGELOG is generated from squash-merge commit subjects
# classified as conventional commits (type(scope): description). That only
# works if every future merge subject actually classifies -- so the two
# places that decide what a merge's title/subject looks like must mandate
# the convention in prose: implement-task/SKILL.md's dev-brief template
# (PR title + commit subjects) and build-next/references/auto-review.md's
# squash-merge step (the merge commit subject itself). This section pins
# that both docs state the mandate, naming the allowed type list.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== conventional-commit merge-title mandate (#406) =="

ALLOWED_TYPES="feat fix perf refactor docs test chore ci build style"

ITBODY="$(cat "$PLUGIN/skills/implement-task/SKILL.md" 2>/dev/null)"
check "implement-task SKILL.md mandates conventional-commit PR title + commit subjects" "conventional commit" "$ITBODY"
check "implement-task SKILL.md names the allowed conventional-commit types" "$ALLOWED_TYPES" "$ITBODY"
check "implement-task SKILL.md gives a scoped conventional-commit example" "feat(AST-060):" "$ITBODY"

ARBODY="$(cat "$PLUGIN/skills/build-next/references/auto-review.md" 2>/dev/null)"
check "auto-review.md mandates the squash-merge commit subject be a conventional-commit line" "conventional commit" "$ARBODY"
check "auto-review.md names the allowed conventional-commit types" "$ALLOWED_TYPES" "$ARBODY"
check "auto-review.md ties the squash subject to the generated CHANGELOG" "CHANGELOG" "$ARBODY"
