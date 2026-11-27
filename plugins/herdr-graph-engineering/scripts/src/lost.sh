#!/usr/bin/env bash
# src/lost.sh -- sourced by the scripts one level up; not run by itself.
# Removing a worktree deletes its ignored files too, and git calls such a checkout clean.
# This splits them: build output that is safe to lose (target/, node_modules/, build/, plus the
# names or globs, one per line, in ~/.config/herdr-graph/safe-to-lose; a trailing / means a
# folder at any depth) and everything else.
# The variables are read by the scripts that source this file.
# shellcheck disable=SC2034

safe_patterns() {
    printf '%s\n' target/ node_modules/ build/
    cat "${XDG_CONFIG_HOME:-$HOME/.config}/herdr-graph/safe-to-lose" 2>/dev/null
}

# 0 when an ignored entry (a file, or a folder with a trailing /) matches a safe pattern.
safe_entry() { # entry, patterns
    local entry="$1" pat part rest
    while IFS= read -r pat; do
        case "$pat" in '' | '#'*) continue ;; esac
        case "$pat" in
            */)
                pat="${pat%/}"
                # the entry's folders: all parts of a folder entry, all but the last of a file
                rest="$entry"
                while [ "${rest#*/}" != "$rest" ]; do
                    part="${rest%%/*}" rest="${rest#*/}"
                    # shellcheck disable=SC2254  # the pattern is meant to glob
                    case "$part" in $pat) return 0 ;; esac
                done ;;
            *)
                # shellcheck disable=SC2254
                case "$entry" in $pat) return 0 ;; esac
                # shellcheck disable=SC2254
                case "${entry##*/}" in $pat) return 0 ;; esac ;;
        esac
    done <<<"$2"
    return 1
}

# Sets LOST and SAFE, each a comma list of a checkout's ignored files and folders.
ignored_split() { # checkout
    local entry patterns
    LOST="" SAFE=""
    [ -n "$1" ] || return 0
    patterns="$(safe_patterns)"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if safe_entry "$entry" "$patterns"; then SAFE="$SAFE${SAFE:+, }$entry"; else LOST="$LOST${LOST:+, }$entry"; fi
    done < <(git -C "$1" ls-files --others --ignored --exclude-standard --directory 2>/dev/null)
}
