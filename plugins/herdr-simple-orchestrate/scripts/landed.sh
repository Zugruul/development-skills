#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# landed.sh -- is a checkout's branch on the main branch, with or without a pull request.
# Usage: landed.sh [--cwd DIR] [--branch B] [--target B] [--remote R]
# Git only: no fetch, no ref or file changed. Recognises the same commits, and the same
# content after a squash, cherry-pick or rebase. Prints a ROW line to copy, or says there is none.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/herdr.sh
. "$HERE/src/herdr.sh"
# shellcheck source=src/require.sh
. "$HERE/src/require.sh"
# shellcheck source=src/git.sh
. "$HERE/src/git.sh"

LANDED_SCAN=200 # commits on the target looked at to name the one where the work landed
USAGE="landed.sh [--cwd DIR] [--branch B] [--target B] [--remote R]"
cwd="" branch="" target="" remote="origin"
while [ $# -gt 0 ]; do
    case "$1" in
        --cwd) need_value "$1" $#; cwd="$2"; shift 2 ;;
        --branch) need_value "$1" $#; branch="$2"; shift 2 ;;
        --target) need_value "$1" $#; target="$2"; shift 2 ;;
        --remote) need_value "$1" $#; remote="$2"; shift 2 ;;
        *) usage "$USAGE" ;;
    esac
done
require_herdr
cwd="$(abs_path "${cwd:-$(pwd)}")"
gitc "$cwd" rev-parse --git-dir >/dev/null || die "$cwd is not in a git repository"
given_branch="$branch"
[ -n "$branch" ] || branch="$(gitc "$cwd" rev-parse --abbrev-ref HEAD)"
tip="$(gitc "$cwd" rev-parse --verify --quiet "$branch^{commit}")" || die "branch '$branch' does not resolve to a commit in $cwd"
short() { gitc "$cwd" rev-parse --short "$1"; }

# True when merging $1 (tip) into $2 (commit) would change nothing.
brings_nothing() {
    local out
    out="$(gitc "$cwd" merge-tree --write-tree "$2" "$1")" || return 1
    [ -n "$out" ] || return 1
    [ "${out%%[[:space:]]*}" = "$(gitc "$cwd" rev-parse "$2^{tree}")" ]
}

# Is the work at $1 in $2? Sets FOUND_HOW and FOUND_AT; returns 1 when not.
landed_on() {
    local t="$1" ref="$2" base c last=""
    if gitc "$cwd" merge-base --is-ancestor "$t" "$ref"; then
        FOUND_HOW="same commits" FOUND_AT="$(short "$t")"
        return 0
    fi
    base="$(gitc "$cwd" merge-base "$t" "$ref")" || return 1
    [ -n "$base" ] && brings_nothing "$t" "$ref" || return 1
    for c in $(gitc "$cwd" rev-list --first-parent --reverse "$base..$ref" | tail -n "$LANDED_SCAN"); do
        if brings_nothing "$t" "$c"; then
            last="$c"
            break
        fi
    done
    FOUND_HOW="same content" FOUND_AT="$(short "${last:-$ref}")"
    return 0
}

if [ -z "$target" ]; then
    head="$(gitc "$cwd" symbolic-ref --quiet --short "refs/remotes/$remote/HEAD")"
    case "$head" in */*) target="${head#*/}" ;; *) target="main" ;; esac
fi
remote_ref="refs/remotes/$remote/$target"
local_ref="refs/heads/$target"
has_remote=0 has_local=0
gitc "$cwd" rev-parse --verify --quiet "$remote_ref" >/dev/null && has_remote=1
gitc "$cwd" rev-parse --verify --quiet "$local_ref" >/dev/null && has_local=1
[ "$has_remote$has_local" != "00" ] || die "no branch $target here, locally or on $remote (give --target)"

printf 'LANDED CHECK branch=%s tip=%s target=%s\n' "$branch" "$(short "$tip")" "$target"
if [ "$has_remote" -eq 1 ]; then
    printf '  note: %s/%s is as of this checkout'"'"'s last fetch; nothing was fetched now\n' "$remote" "$target"
else
    printf '  note: no %s/%s here, so only the local %s can be checked\n' "$remote" "$target" "$target"
fi
if [ -z "$given_branch" ] && [ -n "$(gitc "$cwd" status --porcelain)" ]; then
    printf '  note: %s has uncommitted changes; they are on no branch and not part of this check\n' "$cwd"
fi

if [ "$branch" = "$target" ]; then
    ahead=""
    [ "$has_remote" -eq 1 ] && ahead="$(gitc "$cwd" rev-list --count "$remote_ref..$tip")"
    if [ -n "$ahead" ] && [ "$ahead" != "0" ]; then
        printf 'LOCAL %s @ %s: %s commit(s) on %s are not on %s/%s\n' "$target" "$(short "$tip")" "$ahead" "$target" "$remote" "$target"
        printf 'ROW  ⚪ direct  local   %s @ %s\n' "$target" "$(short "$tip")"
    else
        ref="$local_ref"
        [ "$has_remote" -eq 1 ] && ref="$remote_ref"
        # shellcheck disable=SC2016  # literal backticks in the message
        printf 'ON TARGET: the checkout is on %s itself with nothing unpushed. Git cannot tell which of its commits are this agent'"'"'s: take the commit from the agent and check it with `git merge-base --is-ancestor <commit> %s`.\n' "$target" "$ref"
    fi
    exit 0
fi

if [ "$has_remote" -eq 1 ] && landed_on "$tip" "$remote_ref"; then
    printf 'MERGED %s/%s @ %s (%s)\n' "$remote" "$target" "$FOUND_AT" "$FOUND_HOW"
    if [ "$FOUND_HOW" = "same commits" ]; then
        echo "  note: a branch with no commits of its own also reads as merged. Use the row only for an agent that made commits."
    fi
    printf 'ROW  🟣 direct  merged  %s @ %s\n' "$target" "$FOUND_AT"
    exit 0
fi
if [ "$has_local" -eq 1 ] && landed_on "$tip" "$local_ref"; then
    printf 'LOCAL %s @ %s (%s): on the local %s only, not on %s/%s\n' "$target" "$FOUND_AT" "$FOUND_HOW" "$target" "$remote" "$target"
    printf 'ROW  ⚪ direct  local   %s @ %s\n' "$target" "$FOUND_AT"
    exit 0
fi
printf 'NOT MERGED: %s is not on %s, as the same commits or as the same content. No row.\n' "$branch" "$target"
