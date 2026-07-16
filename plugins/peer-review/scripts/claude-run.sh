#!/usr/bin/env bash
# claude-run.sh [--model <slug>] [--base <ref> | --staged | <pr-number>] --
# the Claude provider's own entry point for /peer-review's "run" stage
# (CDX-054; providers.tsv's claude row: run_script=claude-run.sh), mirroring
# run.sh's wiring for the codex provider (PRV-003/PRV-004). Pure wiring, no
# review logic of its own: translates its own args into diff-source.sh's
# flags -- always adding --preflight-bin claude, so this provider's
# diff-emptiness check never preflights codex (CDX-054 addendum: diff-
# source.sh's preflight binary must be provider-specific) -- runs it, and,
# only when it produced actual diff text rather than the "nothing to
# review" sentinel, hands that diff (plus --model, if given) to
# claude-review.sh and prints its rendered findings. Never modifies any
# file: the only write is the diff to a private tempfile, cleaned up on
# exit.
#
# claude-review.sh mirrors peer-review.sh's shape (a diff-text-file
# argument, not diff-source.sh's --base/--staged/--pr flags), so it can't be
# wired directly as providers.tsv's run_script the way peer-review.sh is
# for codex -- this thin wrapper exists for the same reason run.sh does,
# just for the Claude provider.
#
# --model may appear anywhere in argv (before or after --base/--staged/the
# PR number) -- it is extracted first, independent of position, then the
# remaining single positional argument is parsed exactly as before.
set -uo pipefail

usage() {
    echo "usage: claude-run.sh [--model <slug>] [--base <ref> | --staged | <pr-number>]" >&2
}

# PEER_REVIEW_STUBS lets tests point this at stub diff-source.sh/
# claude-review.sh instead of the real, already-tested scripts -- this
# script's own tests exist to cover its wiring, not re-prove theirs.
HERE="${PEER_REVIEW_STUBS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DIFF_SOURCE="$HERE/diff-source.sh"
CLAUDE_REVIEW="$HERE/claude-review.sh"

model=""
rest=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            [[ $# -ge 2 && "$2" != --* ]] || { echo "ERROR: --model requires a <slug> argument" >&2; usage; exit 2; }
            model="$2"
            shift 2
            ;;
        *)
            rest+=("$1")
            shift
            ;;
    esac
done

ds_args=(--preflight-bin claude)
case "${rest[0]:-}" in
    --base)
        [[ ${#rest[@]} -ge 2 ]] || { echo "ERROR: --base requires a <ref> argument" >&2; usage; exit 2; }
        ds_args+=(--base "${rest[1]}")
        if [[ ${#rest[@]} -gt 2 ]]; then
            echo "ERROR: unrecognized extra argument: ${rest[2]}" >&2
            usage
            exit 2
        fi
        ;;
    --staged)
        ds_args+=(--staged)
        if [[ ${#rest[@]} -gt 1 ]]; then
            echo "ERROR: unrecognized extra argument: ${rest[1]}" >&2
            usage
            exit 2
        fi
        ;;
    "")
        ;;
    *)
        ds_args+=(--pr "${rest[0]}")
        if [[ ${#rest[@]} -gt 1 ]]; then
            echo "ERROR: unrecognized extra argument: ${rest[1]}" >&2
            usage
            exit 2
        fi
        ;;
esac

diff_text="$(bash "$DIFF_SOURCE" "${ds_args[@]}")"
ds_rc=$?

if [[ $ds_rc -ne 0 ]]; then
    exit "$ds_rc"
fi

if [[ "$diff_text" == "nothing to review" ]]; then
    echo "nothing to review"
    exit 0
fi

diff_file="$(mktemp)"
trap 'rm -f "$diff_file"' EXIT
printf '%s\n' "$diff_text" >"$diff_file"

cr_args=()
if [[ -n "$model" ]]; then
    cr_args=(--model "$model")
fi

bash "$CLAUDE_REVIEW" ${cr_args[@]+"${cr_args[@]}"} "$diff_file"
exit $?
