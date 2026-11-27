#!/usr/bin/env bash
# check-marketplaces.sh [ROOT...] -- consistency of each marketplace root (a folder
# holding .claude-plugin/marketplace.json and .agents/plugins/marketplace.json),
# which `claude plugin validate` does not cover. Defaults to the repository root
# and archived/. Reads files only; runs nothing from any plugin.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
[ "$#" -gt 0 ] || set -- . archived
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

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
    done
    echo "checked $root: $(wc -w <<<"$listed" | tr -d ' ') plugins"
done

[ "$fails" -eq 0 ] || { echo "$fails FAILURE(S)"; exit 1; }
echo "ALL PASS"
