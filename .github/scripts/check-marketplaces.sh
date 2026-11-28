#!/usr/bin/env bash
# check-marketplaces.sh [ROOT...] -- consistency of each marketplace root (a folder
# holding .claude-plugin/marketplace.json and .agents/plugins/marketplace.json),
# which `claude plugin validate` does not cover. Defaults to the repository root
# and archived/. Reads files only; runs nothing from any plugin.
# A maintained root (any not named archived) must also keep each plugin usable in
# Claude Code, Codex and OpenCode (AGENTS.md, "Three clients").
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
[ "$#" -gt 0 ] || set -- . archived
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

three_clients() { # root, plugin name, plugin folder
    local root="$1" name="$2" dir="$3" skill folder front description section client
    [ "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" = "$(jq -r '.version' "$dir/.codex-plugin/plugin.json")" ] ||
        fail "$root: $name: the Claude and Codex manifests differ in version"
    for skill in "$dir"/skills/*/SKILL.md; do
        [ -f "$skill" ] || continue
        folder="$(basename "$(dirname "$skill")")"
        front="$(sed -n '2,/^---$/p' "$skill")"
        # OpenCode takes the name from here and wants it to be the folder's
        grep -qxF "name: $folder" <<<"$front" || fail "$root: $name: skills/$folder: the frontmatter name is not its folder"
        description="$(sed -n 's/^description: //p' <<<"$front")"
        [ -n "$description" ] || fail "$root: $name: skills/$folder has no description (Codex and OpenCode need one)"
        case "$description" in *'<'* | *'>'*) fail "$root: $name: skills/$folder: an angle bracket in the description (Codex rejects it)" ;; esac
    done
    # Claude Code and Codex run hooks.json; OpenCode runs only JavaScript plugins
    if [ -f "$dir/hooks/hooks.json" ] && ! ls "$dir"/opencode/*.js >/dev/null 2>&1; then
        fail "$root: $name: it has hooks and no OpenCode plugin (opencode/*.js) to do their work"
    fi
    section="$(awk '/^## / { on = ($0 == "## Clients") } on' "$dir/README.md" 2>/dev/null)"
    if [ -z "$section" ]; then
        fail "$root: $name: README.md has no Clients section"
    else
        for client in 'Claude Code' Codex OpenCode; do
            grep -qF "$client" <<<"$section" || fail "$root: $name: the Clients section of README.md does not name $client"
        done
    fi
}

for root in "$@"; do
    claude="$root/.claude-plugin/marketplace.json"
    codex="$root/.agents/plugins/marketplace.json"
    listed="$(jq -r '.plugins[].name' "$claude" | sort)"
    [ "$listed" = "$(jq -r '.plugins[].name' "$codex" | sort)" ] ||
        fail "$root: the Claude and Codex marketplaces list different plugins"
    on_disk="$(for d in "$root"/plugins/*/; do basename "$d"; done | sort)"
    [ "$listed" = "$on_disk" ] || fail "$root: the marketplaces do not list exactly the folders in $root/plugins"

    for name in $listed; do
        dir="$root/plugins/$name"
        [ "$(jq -r --arg n "$name" '.plugins[] | select(.name == $n) | .source' "$claude")" = "./plugins/$name" ] ||
            fail "$root: $name: the Claude source is not ./plugins/$name"
        [ "$(jq -r --arg n "$name" '.plugins[] | select(.name == $n) | .source.path' "$codex")" = "./plugins/$name" ] ||
            fail "$root: $name: the Codex source path is not ./plugins/$name"
        for host in .claude-plugin .codex-plugin; do
            [ "$(jq -r '.name' "$dir/$host/plugin.json")" = "$name" ] ||
                fail "$root: $name: $host/plugin.json is missing or names another plugin"
        done
        [ "$(jq -r '.skills // ""' "$dir/.codex-plugin/plugin.json")" = "./skills/" ] ||
            fail "$root: $name: the Codex skills path is not ./skills/"
        [ "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" = \
          "$(jq -r --arg n "$name" '.plugins[] | select(.name == $n) | .version' "$claude")" ] ||
            fail "$root: $name: plugin.json and the Claude marketplace entry differ in version"
        [ "$(basename "$root")" = archived ] || three_clients "$root" "$name" "$dir"
    done
    echo "checked $root: $(wc -w <<<"$listed" | tr -d ' ') plugins"
done

[ "$fails" -eq 0 ] || { echo "$fails FAILURE(S)"; exit 1; }
echo "ALL PASS"
