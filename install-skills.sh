#!/usr/bin/env bash
# install-skills.sh {claude|opencode|codex|all} [--global] -- client-neutral install.
#
# Links every plugins/*/skills/<name>/ (anything carrying a SKILL.md) into each client's
# skill folder, so all three clients use the SAME canonical files, and links every
# OpenCode plugin (plugins/<plugin>/opencode/*.js) into OpenCode's plugin folder:
#
#   client     in a project                  --global (every project and worktree)
#   claude     <project>/.claude/skills/     ${CLAUDE_CONFIG_DIR:-~/.claude}/skills/
#   codex      <project>/.agents/skills/     ~/.agents/skills/
#   opencode   <project>/.opencode/          ${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-~/.config}/opencode}/
#                skills/ and plugins/          skills/ and plugins/
#
# For Claude Code and Codex it is an alternative to their marketplace: use one or the
# other, not both, to avoid duplicate entries.
#
# Links, never copies: edits to the canonical files are live. One exception: OpenCode
# knows a skill by the name in its frontmatter, and also reads .claude/skills and
# .agents/skills. So when two skills share a name, the later one gets a pointer: a folder
# <plugin>-<skill> whose SKILL.md has that name and sends the agent to the real file.
# A file or folder that this script did not make is NEVER overwritten: it refuses.
# DEV_SKILLS_PROJECT_ROOT installs into a project other than the current folder.
set -euo pipefail
LC_ALL=C # one order of plugins everywhere, so the same skill keeps the short name

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${DEV_SKILLS_PROJECT_ROOT:-${LUMA_SKILLS_PROJECT_ROOT:-$PWD}}"
MARK='<!-- install-skills.sh pointer:'
GLOBAL=0

usage() {
    printf 'Usage: %s {claude|opencode|codex|all} [--global]\n' "$0" >&2
    printf 'Set DEV_SKILLS_PROJECT_ROOT to install into a different project root.\n' >&2
}

client_root() { # client -> the folder that holds its skills/ (and OpenCode's plugins/)
    case "$1:$GLOBAL" in
        claude:0) printf '%s/.claude' "$PROJECT_ROOT" ;;
        claude:1) printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
        opencode:0) printf '%s/.opencode' "$PROJECT_ROOT" ;;
        opencode:1) printf '%s' "${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}" ;;
        codex:0) printf '%s/.agents' "$PROJECT_ROOT" ;;
        codex:1) printf '%s/.agents' "$HOME" ;;
    esac
}

refuse() {
    printf 'Refusing to overwrite existing %s: %s\n' "$1" "$2" >&2
    exit 1
}

links_to() { # path, real target -> 0 when path is a link that leads to the target
    local to
    [ -L "$1" ] || return 1
    to="$(readlink "$1")"
    [ "${to#/}" != "$to" ] || to="$(dirname "$1")/$to"
    if [ -d "$2" ]; then
        [ "$(cd "$to" 2>/dev/null && pwd -P)" = "$(cd "$2" && pwd -P)" ]
    else
        [ -e "$to" ] && [ "$to" -ef "$2" ]
    fi
}

# Our pointer for this very skill: it may be written again, to take the source's changes.
own_pointer() { # folder, source skill folder
    [ ! -L "$1" ] && [ -f "$1/SKILL.md" ] && grep -qxF -- "$MARK $2/SKILL.md -->" "$1/SKILL.md"
}

write_pointer() { # folder, name, source skill folder
    local description
    description="$(sed -n '2,/^---$/s/^description: //p' "$3/SKILL.md")"
    mkdir -p "$1"
    cat >"$1/SKILL.md" <<POINTER
---
name: $2
description: $description
---

$MARK $3/SKILL.md -->

Another skill has this skill's short name, so it is installed as \`$2\`. Read
\`$3/SKILL.md\` and follow it. Its folder is
\`$3\`: take the relative paths in it from there.
POINTER
}

install_client() {
    local client="$1" root plugin plugin_name skill source name destination seen=" "
    root="$(client_root "$client")"
    mkdir -p "$root/skills"

    for plugin in "$SCRIPT_DIR"/plugins/*/; do
        [ -d "$plugin/skills" ] || continue
        plugin_name="$(basename "$plugin")"
        for skill in "$plugin"skills/*/; do
            [ -f "$skill/SKILL.md" ] || continue
            name="$(basename "$skill")"
            source="$(cd "$skill" && pwd)"
            destination="$root/skills/$name"
            case "$seen" in
                *" $name "*) ;;
                *)
                    seen="$seen$name "
                    if links_to "$destination" "$source"; then continue; fi
                    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
                        ln -s "$source" "$destination"
                        continue
                    fi
                    ;;
            esac
            name="$plugin_name-$name"
            destination="$root/skills/$name"
            # an earlier version of this script linked the folder itself under this name
            if links_to "$destination" "$source"; then rm "$destination"; fi
            if [ -e "$destination" ] || [ -L "$destination" ]; then
                own_pointer "$destination" "$source" || refuse skill "$destination"
            fi
            write_pointer "$destination" "$name" "$source"
        done
    done

    if [ "$client" = opencode ]; then
        for plugin in "$SCRIPT_DIR"/plugins/*/; do
            plugin_name="$(basename "$plugin")"
            for source in "$plugin"opencode/*.js; do
                [ -f "$source" ] || continue
                mkdir -p "$root/plugins"
                destination="$root/plugins/$plugin_name.js"
                source="$(cd "$(dirname "$source")" && pwd)/$(basename "$source")"
                if links_to "$destination" "$source"; then continue; fi
                [ ! -e "$destination" ] && [ ! -L "$destination" ] || refuse "OpenCode plugin" "$destination"
                ln -s "$source" "$destination"
            done
        done
    fi
    printf 'Installed development-skills for %s in %s\n' "$client" "$root"
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
if [ "$#" -eq 2 ]; then
    [ "$2" = --global ] || { usage; exit 2; }
    GLOBAL=1
fi
case "$1" in
    all)
        install_client claude
        install_client opencode
        install_client codex
        ;;
    claude | opencode | codex) install_client "$1" ;;
    *) usage; exit 2 ;;
esac
