#!/usr/bin/env bash
# design-registry-preflight.sh -- hook-independent check: does this issue
# have an UNAPPLIED finalized UI design registered against it? (issue
# #461, team-lead round-2 review item 1: mechanical enforcement, not
# prose -- guard-board-move.sh's own wording was never actually wired to
# anything before this).
#
# Mirrors gate-preflight.sh and two-pass-review-preflight.sh's CLI shape
# and exit-code contract so any caller (board-queue.sh's _do_move
# function, the guard-board-move.sh hook, a Codex explicit workflow step,
# or a human) can invoke the same logic identically. Read-only, no side
# effects.
#
# KNOWN LIMITATION, stated plainly: this can only enforce what a design
# record actually declares via its issue field (design-registry.py's
# for-issue verb). That field is populated by the ui-options skill at
# generation time (it already knows the issue number in context); every
# design backfilled before this field existed (AST-021/022/044/069/083,
# the voice-visualizer rounds) has no issue set and is therefore invisible
# to this check. There is no reliable, offline way to derive a board issue
# number from a design spec taskId -- AST-083 does not imply issue #83; a
# board issue move takes the literal GitHub issue number, a completely
# separate id space from a spec taskId (confirmed against board-queue.sh's
# own move function and telemetry.py's own convention, which use the raw
# issue number throughout, never a taskId). This check is
# forward-enforcing only: it closes the gap for every design registered
# from here on, not retroactively for history.
#
# Usage: design-registry-preflight.sh [--root <path>] --issue <N>
#   --root default: git toplevel (or cwd if not in a git repo).
#   --issue required: the board issue number being moved to In review.
# Exit 0: no UNAPPLIED finalized design is registered against this issue
#   (including: none is registered against it at all -- the common case).
# Exit 2, actionable message on stderr: at least one is, and no override
#   was given.
#
# Override: DESIGN_REGISTRY_OVERRIDE=<note> -- the explicit override note
# the team lead's ask requires. Same escape-hatch shape as
# SERIAL_DELIVERY_OVERRIDE=1 in guard-board-move.sh, but the value itself
# IS the recorded note (not a bare boolean): it is echoed to stderr so the
# override is visible in the same conversation/log that authorized it,
# rather than silently swallowed.
#
# FAIL-OPEN CONTRACT (stated explicitly here, review round 3 item 2 -- a
# grep for fail-open/advisory/never-block previously found nothing): a
# registry query error (design-registry.py crashes, exits nonzero, or is
# missing entirely) NEVER blocks the move -- this script always exits 0
# on that path, the same posture every other *-preflight.sh advisory in
# this plugin uses for its own "can't determine, don't wedge the loop"
# case. That default is correct (an offline/broken registry must never
# stop the build loop), but silent is not: a PERMANENTLY broken registry
# would look identical to a clean one otherwise. The error path below
# always prints a WARNING naming the failure, so a broken registry is
# visible in the same conversation/log a human would already be reading,
# not just in this script's own exit code.
#
# EXCEPTION -- an unreadable SIDECAR is not the same failure class
# (review round 4, finding 1): rc=3 from `for-issue` means the tool ran
# fine but found a specific design record it could not trust (a sidecar
# that exists but fails to parse -- see design-registry.py's
# cmd_for_issue docstring). That is closer to the TAG_PATH_MAP fail-safe
# precedent (5c6227f: fail-safe refusal on data it cannot resolve) than
# to "the tool is broken" -- an unreadable record that might govern this
# issue must not be waved through by the same fail-open branch that
# exists for a genuinely offline/crashed registry, or the two failure
# classes blur into one and the stricter case silently loses its BLOCK.
# Checked before the generic fail-open branch below so rc=3 can never
# fall through into it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=""
ISSUE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "usage: design-registry-preflight.sh [--root <path>] --issue <N>" >&2; exit 2; }
            ROOT="$2"; shift 2 ;;
        --issue)
            [[ $# -ge 2 ]] || { echo "usage: design-registry-preflight.sh [--root <path>] --issue <N>" >&2; exit 2; }
            ISSUE="$2"; shift 2 ;;
        *) echo "usage: design-registry-preflight.sh [--root <path>] --issue <N>" >&2; exit 2 ;;
    esac
done
[[ -n "$ROOT" ]] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ -z "$ISSUE" ]]; then
    echo "usage: design-registry-preflight.sh [--root <path>] --issue <N>" >&2
    exit 2
fi

SCRIPT="$HERE/design-registry.py"
if [[ ! -f "$SCRIPT" ]]; then
    echo "WARNING: design-registry-preflight could not query the registry (guard not enforced) -- $SCRIPT is missing." >&2
    exit 0
fi

# stderr is CAPTURED (not discarded) specifically so a genuine crash's
# message can be surfaced in the WARNING below -- for-issue's own normal
# "nothing registered for this issue" case is exit 0 either way (see
# design-registry.py's cmd_for_issue), so capturing stderr here never
# changes behavior for that common, non-error path.
OUT="$(DESIGN_REGISTRY_ROOT="$ROOT" python3 "$SCRIPT" for-issue "$ISSUE" 2>&1)"
RC=$?

if [[ $RC -eq 3 ]]; then
    if [[ -n "${DESIGN_REGISTRY_OVERRIDE:-}" ]]; then
        echo "WARNING: design-registry-preflight overridden for issue #$ISSUE (DESIGN_REGISTRY_OVERRIDE=\"$DESIGN_REGISTRY_OVERRIDE\") -- proceeding despite unreadable sidecar data: $(head -3 <<<"$OUT" | tr '\n' ' ')" >&2
        exit 0
    fi
    echo "BLOCKED: issue #$ISSUE's design registry has unreadable sidecar data -- cannot confirm no design blocks this move: $(head -3 <<<"$OUT" | tr '\n' ' ') -- fix the corrupt sidecar, then retry the move to In review. Override with DESIGN_REGISTRY_OVERRIDE=\"<why>\" if this is intentional." >&2
    exit 2
fi

if [[ $RC -ne 0 ]]; then
    echo "WARNING: design-registry-preflight could not query the registry (guard not enforced) -- for-issue exited $RC for issue #$ISSUE: $(head -3 <<<"$OUT" | tr '\n' ' ')" >&2
    exit 0
fi

UNAPPLIED_LINES="$(grep 'staleness=UNAPPLIED' <<<"$OUT" || true)"
if [[ -z "$UNAPPLIED_LINES" ]]; then
    exit 0
fi

if [[ -n "${DESIGN_REGISTRY_OVERRIDE:-}" ]]; then
    echo "WARNING: design-registry-preflight overridden for issue #$ISSUE (DESIGN_REGISTRY_OVERRIDE=\"$DESIGN_REGISTRY_OVERRIDE\") -- proceeding despite: $UNAPPLIED_LINES" >&2
    exit 0
fi

echo "BLOCKED: issue #$ISSUE has a FINALIZED UI design that was never marked applied -- $UNAPPLIED_LINES -- run design-registry.py applied <id> <commit-or-note> once the decision actually landed in code, then retry the move to In review. Override with DESIGN_REGISTRY_OVERRIDE=\"<why>\" if this is intentional." >&2
exit 2
