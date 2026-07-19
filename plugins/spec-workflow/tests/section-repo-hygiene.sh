#!/usr/bin/env bash
# section-repo-hygiene.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# Asserts facts about THIS repo's own live checkout state (not a fixture
# temp repo) -- specifically SPEC-MEMORY.md §6.5's commit policy: the
# feedback feed/archive must not be gitignored, and the local-state manifest
# (the source of truth for what should be tracked) must agree. Catches
# either side drifting out of sync, not just the direction fixed by MEM-004.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== repo-hygiene =="

REPO="$(cd "$PLUGIN/../.." && pwd)"

git -C "$REPO" check-ignore .claude/feedbacks/feed.yaml >/dev/null 2>&1
rc=$?
check_rc "feedbacks/ is NOT gitignored (git check-ignore exits nonzero)" 1 "$rc"

manifest="$(cat "$PLUGIN/scripts/local-state.manifest" 2>/dev/null)"
check "local-state.manifest tracks .claude/feedbacks/" "track	.claude/feedbacks/" "$manifest"
