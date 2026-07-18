#!/usr/bin/env bash
# section-skill-contracts.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== find-task SKILL.md contract =="
FTSKILL="$PLUGIN/skills/find-task/SKILL.md"
if [[ -f "$FTSKILL" ]]; then echo "ok   find-task/SKILL.md exists"; else echo "FAIL find-task/SKILL.md missing"; fails=$((fails + 1)); fi
check "find-task SKILL.md has allowed-tools frontmatter" "allowed-tools: Bash" "$(cat "$FTSKILL" 2>/dev/null)"
check "find-task SKILL.md wires board.sh issues" "board.sh\" issues" "$(cat "$FTSKILL" 2>/dev/null)"
check "find-task SKILL.md invokes similar.py via python3" 'python3 "../../scripts/similar.py"' "$(cat "$FTSKILL" 2>/dev/null)"
# shellcheck disable=SC2016  # single quotes are intentional: literal grep pattern, not shell expansion
check_absent "find-task SKILL.md never invokes similar.py via bash" 'bash "../../scripts/similar.py"' "$(cat "$FTSKILL" 2>/dev/null)"

echo "== build-next SKILL.md: mandatory retro at PR close (SW-021, SPEC 8.2) =="
BNSKILL="$PLUGIN/skills/build-next/SKILL.md"
if [[ -f "$BNSKILL" ]]; then echo "ok   build-next/SKILL.md exists"; else echo "FAIL build-next/SKILL.md missing"; fails=$((fails + 1)); fi
BNBODY="$(cat "$BNSKILL" 2>/dev/null)"
check "build-next SKILL.md has a numbered Retro step" "**Retro" "$BNBODY"
check "build-next SKILL.md states the retro is MANDATORY at PR close" "MANDATORY at PR close" "$BNBODY"
check "build-next SKILL.md report step carries a retro-status line" "retro: done" "$BNBODY"
check "build-next SKILL.md report step's skip form states a reason" "retro: SKIPPED — <reason>" "$BNBODY"
check "build-next SKILL.md cross-references brains.md for retro mechanics" "references/brains.md" "$BNBODY"

echo "== build-next SKILL.md: pickup/resume announces a task summary (#213) =="
check "build-next SKILL.md's pickup step announces the summary before other action" "Announce the pickup/resume" "$BNBODY"
check "build-next SKILL.md summary includes the task id and title" "the task id and title" "$BNBODY"
check "build-next SKILL.md summary includes a plain-language brief" "brief plain-language summary" "$BNBODY"
check "build-next SKILL.md summary includes an unordered list of remaining work" "an unordered list of what still needs to be done" "$BNBODY"
check "build-next SKILL.md summary fires on resume, not just a fresh pick" "whether the task is freshly picked or being resumed mid-flight" "$BNBODY"

echo "== auto-review.md: no-interactive-branch decision table (SW-085) =="
ARMD="$PLUGIN/skills/build-next/references/auto-review.md"
if [[ -f "$ARMD" ]]; then echo "ok   auto-review.md exists"; else echo "FAIL auto-review.md missing"; fails=$((fails + 1)); fi
ARBODY="$(cat "$ARMD" 2>/dev/null)"
# DO-NOT phrases (verbatim) -- the exact anti-patterns #85 was filed against.
check "auto-review.md forbids asking the human to configure reviewerTokenEnv" "do not ask the human to configure reviewerTokenEnv" "$ARBODY"
check "auto-review.md forbids merge-yourself/disable-autoMerge menus" "do not offer merge-yourself / disable-autoMerge menus while autoMerge is true" "$ARBODY"
check "auto-review.md names an agent-decidable menu a protocol violation" "a menu of options the agent could decide itself is a protocol violation" "$ARBODY"
# Decision-table rows, keyed off merge-mode.sh requirements' output contract.
check "auto-review.md decision table: requirements none/unknown merges autonomously" "requirements: none" "$ARBODY"
check "auto-review.md decision table: unknown requirements row present" "requirements: unknown" "$ARBODY"
check "auto-review.md decision table: formal-review-required row present" "formal-review-required" "$ARBODY"
check "auto-review.md decision table: reviewerTokenEnv set -> formal approve + merge" "gh pr review <n> --approve" "$ARBODY"
check "auto-review.md decision table: no token is the ONE legitimate blocked-on-human" "the ONE legitimate blocked-on-human" "$ARBODY"
check "auto-review.md records the blocked-on-human handoff ONCE in the cache" "recorded ONCE" "$ARBODY"
# LOCAL-ROUTE fallback (standard path, not a rare escape hatch).
check "auto-review.md documents the LOCAL-ROUTE fallback" "## 5. LOCAL-ROUTE fallback" "$ARBODY"
check "auto-review.md names the self-authored-PR permission floor" "self-authored-PR floor" "$ARBODY"
check "auto-review.md local-route uses a clean worktree for the squash-merge" "clean worktree" "$ARBODY"
check "auto-review.md local-route closes the PR via REST naming the merge SHA" "close the PR via REST" "$ARBODY"
check "auto-review.md local-route detects the hard-block once and never re-attempts the gated call" "never re-attempts the gated call" "$ARBODY"
check "auto-review.md forbids parking approved work as a standing ask" "never parks approved work as a standing ask" "$ARBODY"
check "auto-review.md points the merge-route report line at build-next SKILL.md step 6" "SKILL.md step 6" "$ARBODY"
# On-behalf recipe paste order (SW-065): --author is a `git commit` option,
# not a global one -- the template must place it AFTER `commit`, never in the
# `flags:` (pre-`commit`) position, or pasting it verbatim fails at the shell.
check "auto-review.md on-behalf recipe: flags line goes before commit" "git <paste flags line> commit" "$ARBODY"
check "auto-review.md on-behalf recipe: commit-flags line goes after commit" "commit <paste commit-flags line> -m" "$ARBODY"
check_absent "auto-review.md on-behalf recipe: --author never lands in the pre-commit flags position" "flags line> --author" "$ARBODY"
# Verdict-delivery instruction (#66): a reviewer can finish analysis and idle
# without transmitting the result -- the brief must say the review isn't done
# until the verdict reaches the orchestrator over messaging.
check "auto-review.md brief mandates delivering the verdict over messaging, not just producing it" "Completing analysis without sending it means the review never happened" "$ARBODY"
check "build-next SKILL.md report step states the merge route" "merge route" "$BNBODY"
check "build-next SKILL.md report step gives the requirements report token" "requirements: <verdict from merge-mode.sh requirements>" "$BNBODY"
check "build-next SKILL.md report step gives the local-route report token" "route: local-route" "$BNBODY"
echo "== build-next SKILL.md: autonomous-decision operating rule (SW-085) =="
check "build-next SKILL.md operating rule: no AskUserQuestion in auto mode absent a hard denial" "does not use AskUserQuestion unless a hard permission denial or an explicit instruction requires human direction" "$BNBODY"

echo "== queue SKILL.md contract (#154) =="
QSKILL="$PLUGIN/skills/queue/SKILL.md"
if [[ -f "$QSKILL" ]]; then echo "ok   queue/SKILL.md exists"; else echo "FAIL queue/SKILL.md missing"; fails=$((fails + 1)); fi
QBODY="$(cat "$QSKILL" 2>/dev/null)"
check "queue SKILL.md has name frontmatter" "name: queue" "$QBODY"
check "queue SKILL.md has allowed-tools frontmatter" "allowed-tools: Bash" "$QBODY"
# shellcheck disable=SC2016  # single quotes are intentional: literal grep pattern, not shell expansion
check "queue SKILL.md has the preflight pre-start check line" 'Pre-start check: !`bash "../../scripts/preflight.sh"' "$QBODY"
check "queue SKILL.md instructs to STOP on PREFLIGHT FAIL" "PREFLIGHT FAIL" "$QBODY"
check "queue SKILL.md wires board.sh next" "board.sh\" next" "$QBODY"
check "queue SKILL.md wires board.sh show to enrich candidates" "board.sh\" show" "$QBODY"
check "queue SKILL.md states it is read-only" "READ-ONLY" "$QBODY"
check "queue SKILL.md states no board mutation is ever made" "no board mutation" "$QBODY"
check "queue SKILL.md explains the PICK/RESUME decision meaning" "RESUME" "$QBODY"
check "queue SKILL.md documents the WIP-limit meaning of RESUME" "WIP limit" "$QBODY"
check "queue SKILL.md tells the human they can steer via comments or Priority" "commenting on an issue" "$QBODY"

echo "== plugin README documents the queue skill =="
QREADME="$(cat "$PLUGIN/README.md" 2>/dev/null)"
check "plugin README lists the queue skill in the skills table" "| \`queue\` |" "$QREADME"

echo "== changelog-generate SKILL.md contract (#165) =="
CLSKILL="$PLUGIN/skills/changelog-generate/SKILL.md"
if [[ -f "$CLSKILL" ]]; then echo "ok   changelog-generate/SKILL.md exists"; else echo "FAIL changelog-generate/SKILL.md missing"; fails=$((fails + 1)); fi
CLBODY="$(cat "$CLSKILL" 2>/dev/null)"
check "changelog-generate SKILL.md has name frontmatter" "name: changelog-generate" "$CLBODY"
check "changelog-generate SKILL.md wires changelog.sh" "changelog.sh\"" "$CLBODY"
check "changelog-generate SKILL.md states it is read-only" "READ-ONLY" "$CLBODY"

echo "== plugin + root README document the changelog-generate skill (#165) =="
RROOTREADME="$(cat "$HERE/../../../README.md" 2>/dev/null)"
check "plugin README lists the changelog-generate skill in the skills table" "| \`changelog-generate\` |" "$QREADME"
check "root README lists the changelog-generate skill in the skills table" "| \`changelog-generate\` |" "$RROOTREADME"
