#!/usr/bin/env bash
# section-commit-convention-config.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# #418: two new optional project.yaml keys (commit.convention,
# commit.systemPrompt) let a repo tune commit-message LANGUAGE/STRUCTURE
# because a squash-merge body renders verbatim into the generated CHANGELOG
# (#404) and dense prose there is unreadable to a human. This pins that both
# consumption points -- implement-task/SKILL.md's dev-brief template and
# build-next/references/auto-review.md's squash-merge step -- reference the
# two config keys and keep #406's conventional-commit mandate intact
# (parameterized, not replaced): the mandate now reads "follow the
# configured convention (default conventional-commits)" instead of
# hardcoding conventional-commits as the only option. Mirrors
# section-conventional-commit-mandate.sh's shape for the sibling concern.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== commit.convention / commit.systemPrompt config wiring (#418) =="

ITBODY="$(cat "$PLUGIN/skills/implement-task/SKILL.md" 2>/dev/null)"
check "implement-task SKILL.md references cfg:commit.convention" "cfg:commit.convention" "$ITBODY"
check "implement-task SKILL.md references cfg:commit.systemPrompt" "cfg:commit.systemPrompt" "$ITBODY"
check "implement-task SKILL.md keeps the parameterized mandate wording" "the configured convention" "$ITBODY"
check "implement-task SKILL.md still names conventional-commits as the default" "default conventional-commits" "$ITBODY"

ARBODY="$(cat "$PLUGIN/skills/build-next/references/auto-review.md" 2>/dev/null)"
check "auto-review.md references cfg:commit.convention" "cfg:commit.convention" "$ARBODY"
check "auto-review.md references cfg:commit.systemPrompt" "cfg:commit.systemPrompt" "$ARBODY"
check "auto-review.md keeps the parameterized mandate wording" "the configured convention" "$ARBODY"
check "auto-review.md still names conventional-commits as the default" "default conventional-commits" "$ARBODY"

echo "== commit.convention / commit.systemPrompt: setup-project asks the human (#418) =="
SPBODY="$(cat "$PLUGIN/skills/setup-project/SKILL.md" 2>/dev/null)"
check "setup-project SKILL.md asks about commit convention" "Commit convention" "$SPBODY"
check "setup-project SKILL.md recommends conventional-commits as the default" "conventional-commits" "$SPBODY"
check "setup-project SKILL.md shows the default commitSystemPrompt" "Simple titles" "$SPBODY"

echo "== commit.convention / commit.systemPrompt: sync-project-configs rule documented (#418) =="
SCBODY="$(cat "$PLUGIN/skills/sync-project-configs/SKILL.md" 2>/dev/null)"
check "sync-project-configs SKILL.md documents ensure-commit-config rule" "ensure-commit-config" "$SCBODY"
