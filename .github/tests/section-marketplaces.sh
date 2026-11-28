#!/usr/bin/env bash
# section-marketplaces.sh -- sourced by run-tests.sh; do not run standalone.
# check-marketplaces.sh keeps every maintained plugin usable in Claude Code, Codex and
# OpenCode; the archived marketplace is only checked for consistency.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash .github/tests/run-tests.sh" >&2; exit 2; }
echo "== check-marketplaces.sh =="
M_TMP="$(mktemp -d)"
CHECK="$REPO/.github/scripts/check-marketplaces.sh"

fixture() { # root folder -- one plugin that every client can use
    local root="$1" p="$1/plugins/x"
    rm -rf "$root"
    mkdir -p "$root/.claude-plugin" "$root/.agents/plugins" "$p/.claude-plugin" "$p/.codex-plugin" "$p/skills/go" "$p/hooks" "$p/opencode"
    echo '{"plugins":[{"name":"x","source":"./plugins/x","version":"1.0.0"}]}' >"$root/.claude-plugin/marketplace.json"
    echo '{"plugins":[{"name":"x","source":{"source":"local","path":"./plugins/x"}}]}' >"$root/.agents/plugins/marketplace.json"
    echo '{"name":"x","version":"1.0.0"}' >"$p/.claude-plugin/plugin.json"
    echo '{"name":"x","version":"1.0.0","skills":"./skills/"}' >"$p/.codex-plugin/plugin.json"
    printf -- '---\nname: go\ndescription: Goes. Use for go.\n---\n\nGo.\n' >"$p/skills/go/SKILL.md"
    echo '{"hooks":{}}' >"$p/hooks/hooks.json"
    echo 'export const X = async () => ({})' >"$p/opencode/x.js"
    printf '# x\n\n## Clients\n\n| Claude Code | Codex | OpenCode |\n\n## More\n' >"$p/README.md"
}
ck() { bash "$CHECK" "$@" 2>&1; }
# breaks NAME EXPECTED SHELL-COMMAND (run in the fixture's plugin folder)
breaks() {
    fixture "$M_TMP/root"
    (cd "$M_TMP/root/plugins/x" && eval "$3")
    local out rc
    out="$(ck "$M_TMP/root")"; rc=$?
    check_rc "$1: the check fails" 1 "$rc"
    check "$1: and says why" "$2" "$out"
}

fixture "$M_TMP/root"
out="$(ck "$M_TMP/root")"; rc=$?
check_rc "a plugin every client can use passes" 0 "$rc"
breaks "no Codex manifest" ".codex-plugin/plugin.json is missing" 'rm .codex-plugin/plugin.json'
breaks "the Codex version lags" "the Claude and Codex manifests differ in version" 'echo "{\"name\":\"x\",\"version\":\"0.9.0\",\"skills\":\"./skills/\"}" >.codex-plugin/plugin.json'
breaks "a skill name that is not its folder's (OpenCode)" "name is not its folder" 'sed -i.bak "s/^name: go/name: Go/" skills/go/SKILL.md'
breaks "a skill without a description" "has no description" 'sed -i.bak "/^description:/d" skills/go/SKILL.md'
breaks "an angle bracket in a description (Codex)" "angle bracket" 'sed -i.bak "s/Use for go\./Use for <go>./" skills/go/SKILL.md'
breaks "hooks with nothing for OpenCode" "no OpenCode plugin" 'rm -r opencode'
breaks "a README without the clients section" "no Clients section" 'echo "# x" >README.md'
breaks "a clients section that leaves one out" "does not name OpenCode" 'printf "## Clients\n\nClaude Code and Codex.\n\n## More\n\nOpenCode\n" >README.md'

fixture "$M_TMP/archived"
rm -r "$M_TMP/archived/plugins/x/opencode" "$M_TMP/archived/plugins/x/README.md"
out="$(ck "$M_TMP/archived")"; rc=$?
check_rc "the archived marketplace is only checked for consistency" 0 "$rc"

out="$(ck)"; rc=$?
check_rc "this repository passes" 0 "$rc"

rm -rf "$M_TMP"
unset -f fixture ck breaks
