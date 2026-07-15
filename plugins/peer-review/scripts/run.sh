#!/usr/bin/env bash
# run.sh [--base <ref> | --staged | <pr-number>] -- the /peer-review skill's
# orchestration layer (PRV-003, SPEC-PEER-REVIEW.md §6.10). Pure wiring, no
# review logic of its own: translates its own args into diff-source.sh's
# flags, runs it, and -- only when it produced actual diff text rather than
# the "nothing to review" sentinel -- hands that diff to peer-review.sh and
# prints its rendered findings. Never modifies any file (§6.9): the only
# write is the diff to a private tempfile, cleaned up on exit.
set -uo pipefail

usage() {
    echo "usage: run.sh [--base <ref> | --staged | <pr-number>]" >&2
}

# PEER_REVIEW_STUBS lets tests point this at stub diff-source.sh/
# peer-review.sh instead of the real, already-tested (PRV-001/PRV-002)
# scripts -- this script's own tests exist to cover its wiring, not re-prove
# theirs.
HERE="${PEER_REVIEW_STUBS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DIFF_SOURCE="$HERE/diff-source.sh"
PEER_REVIEW="$HERE/peer-review.sh"

ds_args=()
case "${1:-}" in
    --base)
        [[ $# -ge 2 ]] || { echo "ERROR: --base requires a <ref> argument" >&2; usage; exit 2; }
        ds_args=(--base "$2")
        shift 2
        ;;
    --staged)
        ds_args=(--staged)
        shift
        ;;
    "")
        ;;
    *)
        ds_args=(--pr "$1")
        shift
        ;;
esac

if [[ $# -gt 0 ]]; then
    echo "ERROR: unrecognized extra argument: $1" >&2
    usage
    exit 2
fi

diff_text="$(bash "$DIFF_SOURCE" ${ds_args[@]+"${ds_args[@]}"})"
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

bash "$PEER_REVIEW" "$diff_file"
exit $?
