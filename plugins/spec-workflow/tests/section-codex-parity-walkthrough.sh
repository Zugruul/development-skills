#!/usr/bin/env bash
# section-codex-parity-walkthrough.sh -- sourced by run-tests.sh; do not run
# standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# CDX-031 (#188, SPEC-CODEX-COMPAT.md §9.2): pins the completeness of the
# build-next/implement-task Codex-path parity walkthrough audit recorded in
# docs/design/cdx-E3.md's "CDX-031" section. This is a structural/regression
# guard on the audit DOCUMENT (every one of the 9 named invariants still
# carries a verdict, and the doc's own headline finding hasn't silently
# drifted) -- it does not re-verify the underlying codebase claims the doc
# makes; that is a job for whichever future task next touches this section.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== codex-parity-walkthrough =="

REPO="$(cd "$PLUGIN/../.." && pwd)"
CDX_E3="$REPO/docs/design/cdx-E3.md"

if [[ ! -f "$CDX_E3" ]]; then
    check "docs/design/cdx-E3.md exists" "EXISTS" "MISSING"
else
    cdx_content="$(cat "$CDX_E3")"
    check "docs/design/cdx-E3.md exists" "EXISTS" "EXISTS"

    # Each of the 9 §9.2 invariants must have both its key phrase and a
    # verdict word present in the doc -- confirms the audit section still
    # names every invariant and still assigns it one of the 3 verdicts.
    # cdx-E3.md's own convention: one invariant per paragraph, each written
    # as a SINGLE (unwrapped) line -- "**N. <name> -- VERDICT.** <body>".
    # The check therefore reads only the LINE the phrase was found on, not
    # a multi-line window: a wider window (tried first, then reverted after
    # review) risked reaching into the NEXT invariant's own heading/verdict
    # a couple of lines down and passing even when THIS invariant's own
    # verdict word was missing -- a same-line check can't have that failure
    # mode regardless of how many invariants precede or follow it.
    cpw_verdict_re="SCRIPT-ENFORCED|PROSE-ONLY|HOOK-ONLY"

    cpw_check_invariant() { # label  key-phrase
        local label="$1" phrase="$2"
        check "cdx-E3.md names invariant: $label" "$phrase" "$cdx_content"
        local this_line
        this_line="$(grep -F -- "$phrase" "$CDX_E3" | head -1)"
        if grep -Eq "$cpw_verdict_re" <<<"$this_line"; then r=HAS_VERDICT; else r=NO_VERDICT; fi
        check "cdx-E3.md gives invariant a verdict: $label" "HAS_VERDICT" "$r"
    }

    cpw_check_invariant "1 truthful board-status transitions" "Truthful board-status transitions"
    cpw_check_invariant "2 human-issue-comment steering read" "Human-issue-comment steering read"
    cpw_check_invariant "3 red-first TDD" "Red-first TDD"
    cpw_check_invariant "4 independent two-pass review" "Independent two-pass review"
    cpw_check_invariant "5 identity-brain isolation" "Identity-brain isolation"
    cpw_check_invariant "6 mandatory retro/feedback at PR close" "Mandatory retro/feedback at PR close"
    cpw_check_invariant "7 checkpoint behavior" "Checkpoint behavior"
    cpw_check_invariant "8 isolated concurrency lanes / maxInProgress" "Isolated concurrency lanes"
    cpw_check_invariant "9 bounded auto-merge review rounds" "Bounded auto-merge review rounds"

    # Invariant #1 is the only one of the 9 with genuine "hooks absent"
    # simulation test coverage -- the doc must keep citing it by name.
    check "cdx-E3.md names section-gate-preflight.sh as invariant #1's coverage" \
        "section-gate-preflight.sh" "$cdx_content"

    # Pin the audit's headline finding: 8 of the 9 invariants are NOT
    # SCRIPT-ENFORCED. A future edit that silently changes this claim
    # without updating the surrounding prose should fail this check.
    check "cdx-E3.md summary table asserts 8 of 9 invariants are prose-only" \
        "8 of 9 invariants are currently prose-only" "$cdx_content"
fi
