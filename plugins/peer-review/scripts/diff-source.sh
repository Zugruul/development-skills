#!/usr/bin/env bash
# diff-source.sh [--base <ref>|--staged|--pr <n>] -- resolves the diff to
# review and preflights the `codex` binary (SPEC-PEER-REVIEW.md §6.1-6.4,
# §6.7). Pure/testable: given repo state + args, prints the diff to stdout
# and exits 0, or prints "nothing to review" + exits 0 on an empty diff
# (codex is never even preflighted on that path -- PRV-002 must never be
# reachable for a no-op review), or exits 2 with an install message on
# stderr if `codex` is missing from PATH.
#
# Default source: `git diff <mainBranch>...HEAD`, where <mainBranch> comes
# from the repo-local `git config peer-review.mainBranch` when set, else
# falls back to the literal "main" (§6.1).
set -uo pipefail

usage() {
    echo "usage: diff-source.sh [--base <ref> | --staged | --pr <n>]" >&2
}

mode="default"
ref=""
pr=""

while [[ $# -gt 0 ]]; do
    case "$1" in
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

case "$mode" in
    default)
        main_branch="$(git config --get peer-review.mainBranch 2>/dev/null || true)"
        main_branch="${main_branch:-main}"
        diff="$(git diff "$main_branch...HEAD" 2>&1)" || { echo "ERROR: git diff against '$main_branch' failed: $diff" >&2; exit 1; }
        ;;
    base)
        diff="$(git diff "$ref...HEAD" 2>&1)" || { echo "ERROR: git diff against '$ref' failed: $diff" >&2; exit 1; }
        ;;
    staged)
        diff="$(git diff --staged 2>&1)" || { echo "ERROR: git diff --staged failed: $diff" >&2; exit 1; }
        ;;
    pr)
        diff="$(gh pr diff "$pr" 2>&1)" || { echo "ERROR: gh pr diff $pr failed: $diff" >&2; exit 1; }
        ;;
esac

if [[ -z "$diff" ]]; then
    echo "nothing to review"
    exit 0
fi

if ! command -v codex >/dev/null 2>&1; then
    {
        echo "ERROR: codex not found on PATH."
        echo "Install the codex CLI (https://github.com/openai/codex) and ensure it is on PATH, then retry."
    } >&2
    exit 2
fi

printf '%s\n' "$diff"
