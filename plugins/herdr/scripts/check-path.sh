#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# check-path.sh -- is this worktree path safe for the target repository.
# Usage: check-path.sh --target CHECKOUT --path PATH [--target-rule]
# Why a script: a standalone clone nested inside another repository (its own .git,
# gitignored there) must not get its worktree inside that enclosing repository just
# because the enclosing repository's rule says so. Herdr does not check this.
# PATH is absolute (a leading ~/ is expanded). It is refused when its nearest existing
# directory belongs to a different repository than CHECKOUT (compared by the shared git
# dir, so linked worktrees of one repository are the same repository), unless
# --target-rule says the target repository's own instructions put it there.
# Prints PATH OK ... or PATH REFUSED ...; exits 1 when refused, 2 on a usage error.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/herdr.sh
. "$HERE/src/herdr.sh"

USAGE="check-path.sh --target CHECKOUT --path PATH [--target-rule]"
target="" path="" rule=0
while [ $# -gt 0 ]; do
    case "$1" in
        --target) need_value "$1" $#; target="$2"; shift 2 ;;
        --path) need_value "$1" $#; path="$2"; shift 2 ;;
        --target-rule) rule=1; shift ;;
        *) usage "$USAGE" ;;
    esac
done
[ -n "$target" ] && [ -n "$path" ] || usage "$USAGE"
case "$path" in \~/*) path="$HOME/${path#\~/}" ;; esac
case "$path" in /*) ;; *) die "--path must be absolute (got $path): a relative path would be judged against this shell's cwd." 2 ;; esac

repo_of() { # directory -> physical path of its repository's common git dir, empty outside git
    (cd "$1" 2>/dev/null && common="$(git rev-parse --git-common-dir 2>/dev/null)" && cd "$common" && pwd -P) || true
}
top_of() { # directory -> its working tree's toplevel, for messages only
    git -C "$1" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$1"
}

repo="$(repo_of "$target")"
[ -n "$repo" ] || die "PATH UNKNOWN: $target is not inside a git repository." 2
top="$(top_of "$target")"

dir="$path"
while [ ! -d "$dir" ]; do
    parent="$(dirname "$dir")"
    [ "$parent" = "$dir" ] && break
    dir="$parent"
done
other=""
[ -d "$dir" ] && other="$(repo_of "$dir")"

if [ -z "$other" ] || [ "$other" = "$repo" ] || [ "$rule" -eq 1 ]; then
    printf 'PATH OK target=%s path=%s\n' "$top" "$path"
    exit 0
fi
printf 'PATH REFUSED: %s is inside the working tree of %s, a different repository than the target %s. Only the target repository'"'"'s own location rule applies: use it, or Herdr'"'"'s worktree directory.\n' "$path" "$(top_of "$dir")" "$top"
exit 1
