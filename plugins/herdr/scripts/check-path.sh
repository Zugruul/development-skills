#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# check-path.sh -- is this worktree path safe for the target repository.
# Usage: check-path.sh --target CHECKOUT --path PATH [--target-rule]
# Why a script: a standalone clone nested inside another repository (its own .git,
# gitignored there) must not get its worktree inside that enclosing repository just
# because the enclosing repository's rule says so. Herdr does not check this.
# The target is the git toplevel of CHECKOUT. PATH is refused when its nearest existing
# directory belongs to a different repository's working tree, unless --target-rule says
# the target repository's own instructions put it there.
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

top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" ||
    die "PATH UNKNOWN: $target is not inside a git repository." 2
top="$(cd "$top" && pwd -P)"

dir="$path"
while [ ! -d "$dir" ]; do
    parent="$(dirname "$dir")"
    [ "$parent" = "$dir" ] && break
    dir="$parent"
done
other=""
if [ -d "$dir" ]; then
    other="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$other" ] && other="$(cd "$other" && pwd -P)"
fi

if [ -z "$other" ] || [ "$other" = "$top" ] || [ "$rule" -eq 1 ]; then
    printf 'PATH OK target=%s path=%s\n' "$top" "$path"
    exit 0
fi
printf 'PATH REFUSED: %s is inside the working tree of %s, not of the target repository %s. A location rule from an enclosing repository does not apply to a nested clone: use the target'"'"'s own rule, or Herdr'"'"'s worktree directory.\n' "$path" "$other" "$top"
exit 1
