#!/usr/bin/env bash
# src/git.sh -- sourced by the scripts one level up; not run by itself.
#   gitc DIR ARGS...   git -C DIR ARGS..., stdout only, trailing newline trimmed
#   abs_path PATH      absolute form of PATH (it need not exist)
#   shquote WORD       WORD as one shell word

gitc() {
    local dir="$1"
    shift
    git -C "$dir" "$@" 2>/dev/null
}

abs_path() {
    local p="$1"
    # shellcheck disable=SC2088  # matching a literal ~/ prefix, not expanding it
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p#\~/}" ;;
    esac
    case "$p" in
        /*) ;;
        *) p="$(pwd)/$p" ;;
    esac
    if [ -d "$p" ]; then
        (cd "$p" && pwd)
    else
        printf '%s\n' "$p"
    fi
}

shquote() {
    local LC_ALL=C re='^[A-Za-z0-9_@%+=:,./~-]+$' q="'\\''"
    if [[ "$1" =~ $re ]]; then
        printf '%s' "$1"
    else
        printf "'%s'" "${1//\'/$q}"
    fi
}
