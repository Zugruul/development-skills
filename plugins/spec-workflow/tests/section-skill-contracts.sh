#!/usr/bin/env bash
# section-skill-contracts.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
echo "== find-task SKILL.md contract =="
FTSKILL="$PLUGIN/skills/find-task/SKILL.md"
if [[ -f "$FTSKILL" ]]; then echo "ok   find-task/SKILL.md exists"; else echo "FAIL find-task/SKILL.md missing"; fails=$((fails + 1)); fi
check "find-task SKILL.md has allowed-tools frontmatter" "allowed-tools: Bash" "$(cat "$FTSKILL" 2>/dev/null)"
check "find-task SKILL.md wires board.sh issues" "board.sh\" issues" "$(cat "$FTSKILL" 2>/dev/null)"
check "find-task SKILL.md invokes similar.py via python3" "python3 \"\${CLAUDE_PLUGIN_ROOT}/scripts/similar.py\"" "$(cat "$FTSKILL" 2>/dev/null)"
# shellcheck disable=SC2016  # single quotes are intentional: literal grep pattern, not shell expansion
check_absent "find-task SKILL.md never invokes similar.py via bash" 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/similar.py"' "$(cat "$FTSKILL" 2>/dev/null)"

echo "== build-next SKILL.md: mandatory retro at PR close (SW-021, SPEC 8.2) =="
BNSKILL="$PLUGIN/skills/build-next/SKILL.md"
if [[ -f "$BNSKILL" ]]; then echo "ok   build-next/SKILL.md exists"; else echo "FAIL build-next/SKILL.md missing"; fails=$((fails + 1)); fi
BNBODY="$(cat "$BNSKILL" 2>/dev/null)"
check "build-next SKILL.md has a numbered Retro step" "**Retro" "$BNBODY"
check "build-next SKILL.md states the retro is MANDATORY at PR close" "MANDATORY at PR close" "$BNBODY"
check "build-next SKILL.md report step carries a retro-status line" "retro: done" "$BNBODY"
check "build-next SKILL.md report step's skip form states a reason" "retro: SKIPPED — <reason>" "$BNBODY"
check "build-next SKILL.md cross-references brains.md for retro mechanics" "references/brains.md" "$BNBODY"

echo "== auto-review.md: standing-consent front-load + per-artifact scoping (SW-033) =="
ARMD="$PLUGIN/skills/build-next/references/auto-review.md"
if [[ -f "$ARMD" ]]; then echo "ok   auto-review.md exists"; else echo "FAIL auto-review.md missing"; fails=$((fails + 1)); fi
ARBODY="$(cat "$ARMD" 2>/dev/null)"
check "auto-review.md front-load offers a STANDING CONSENT option" "STANDING CONSENT" "$ARBODY"
check "auto-review.md front-load labels the one-off merge as PER-ARTIFACT CONSENT" "PER-ARTIFACT CONSENT" "$ARBODY"
check "auto-review.md documents per-artifact consent scoping" "Per-artifact consent scoping." "$ARBODY"
check "auto-review.md states a one-time yes is not a policy" "a one-time yes is not a policy" "$ARBODY"
check "auto-review.md points the consent-model report line at build-next SKILL.md step 6" "SKILL.md step 6" "$ARBODY"
check "build-next SKILL.md report step states the consent model" "consent model" "$BNBODY"
check "build-next SKILL.md report step gives the standing-consent report token" "consent: standing (preauth ok)" "$BNBODY"
check "build-next SKILL.md report step gives the per-artifact report token" "consent: per-artifact (asked" "$BNBODY"
