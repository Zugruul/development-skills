#!/usr/bin/env bash
# diff-source.sh [--preflight-bin <name>] [--base <ref>|--staged|--pr <n>]
# -- resolves the diff to review and preflights a provider's CLI binary
# (SPEC-PEER-REVIEW.md §6.1-6.4, §6.7; --preflight-bin added CDX-054, the
# #202/#203 addendum -- this diff-resolution logic is genuinely
# provider-neutral, only the preflight binary itself varies by provider, so
# it is a flag here rather than a forked second copy of this script per
# provider). Pure/testable: given repo state + args, prints the diff to
# stdout and exits 0, or prints "nothing to review" + exits 0 on an empty
# diff (the preflight binary is never even checked on that path -- a
# review script must never be reachable for a no-op review), or exits 2
# with an install message on stderr if the preflight binary is missing
# from PATH.
#
# --preflight-bin <name> defaults to "codex" (the only provider that
# existed before CDX-054), preserving every prior caller's behavior
# unchanged. Callers pass their own provider's CLI binary name -- by
# convention (see providers.tsv) a provider's registry id IS its CLI
# binary name on PATH, so callers can pass <provider_id> directly with no
# separate lookup.
#
# Default source: `git diff <mainBranch>...HEAD`, where <mainBranch> comes
# from the repo-local `git config peer-review.mainBranch` when set, else
# falls back to the literal "main" (§6.1).
set -uo pipefail

usage() {
    echo "usage: diff-source.sh [--preflight-bin <name>] [--base <ref> | --staged | --pr <n>]" >&2
}

mode="default"
ref=""
pr=""
preflight_bin="codex"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --preflight-bin)
            [[ $# -ge 2 ]] || { echo "ERROR: --preflight-bin requires a <name> argument" >&2; usage; exit 2; }
            preflight_bin="$2"
            shift 2
            ;;
        --base)
            [[ $# -ge 2 ]] || { echo "ERROR: --base requires a <ref> argument" >&2; usage; exit 2; }
            mode="base"
            ref="$2"
            shift 2
            ;;
        --staged)
            mode="staged"
            shift
            ;;
        --pr)
            [[ $# -ge 2 ]] || { echo "ERROR: --pr requires a <n> argument" >&2; usage; exit 2; }
            mode="pr"
            pr="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unrecognized argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

# stderr is captured to a temp file, not merged into $diff, so an
# advice/hint line git or gh might emit on stderr on an otherwise-successful
# (zero-exit) run never pollutes the diff text that gets embedded in the
# codex prompt (PRV-002 follow-up). It's only read back for the error
# message on an actual (nonzero-exit) failure.
err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

case "$mode" in
    default)
        main_branch="$(git config --get peer-review.mainBranch 2>/dev/null || true)"
        main_branch="${main_branch:-main}"
        diff="$(git diff "$main_branch...HEAD" 2>"$err_file")" || { echo "ERROR: git diff against '$main_branch' failed: $(cat "$err_file")" >&2; exit 1; }
        ;;
    base)
        diff="$(git diff "$ref...HEAD" 2>"$err_file")" || { echo "ERROR: git diff against '$ref' failed: $(cat "$err_file")" >&2; exit 1; }
        ;;
    staged)
        diff="$(git diff --staged 2>"$err_file")" || { echo "ERROR: git diff --staged failed: $(cat "$err_file")" >&2; exit 1; }
        ;;
    pr)
        diff="$(gh pr diff "$pr" 2>"$err_file")" || { echo "ERROR: gh pr diff $pr failed: $(cat "$err_file")" >&2; exit 1; }
        ;;
esac

if [[ -z "$diff" ]]; then
    echo "nothing to review"
    exit 0
fi

if ! command -v "$preflight_bin" >/dev/null 2>&1; then
    {
        echo "ERROR: $preflight_bin not found on PATH."
        echo "Install the $preflight_bin CLI and ensure it is on PATH, then retry."
    } >&2
    exit 2
fi

printf '%s\n' "$diff"
