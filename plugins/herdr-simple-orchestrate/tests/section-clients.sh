#!/usr/bin/env bash
# section-clients.sh -- sourced by run-tests.sh; do not run standalone.
# Every skill must be followable in Claude Code, Codex and OpenCode.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-simple-orchestrate/tests/run-tests.sh" >&2; exit 2; }
echo "== clients: skills work in Claude Code, Codex and OpenCode =="

for f in "$PLUGIN"/skills/*/SKILL.md; do
    skill="$(basename "$(dirname "$f")")"
    text="$(cat "$f")"
    body="$(awk 'n >= 2 { print } /^---$/ { n++ }' "$f")"
    # install-skills.sh links skill folders: a tool that tidies "../.." as text would miss the plugin
    if grep -qF '../../' <<<"$body"; then
        check "$skill: takes ../../ from the real folder of a linked skill" "If this skill folder is a symlink" "$body"
    fi
    # only Claude Code fills in the placeholder
    if grep -qF '$ARGUMENTS' <<<"$body"; then
        check "$skill: says where the argument is when the placeholder stays" "leaves that placeholder as it is" "$body"
    fi
    if grep -qF 'AskUserQuestion' <<<"$body"; then
        check "$skill: names the other clients' question tools" "request_user_input" "$text"
        check "$skill: says what to do without a question tool" "ithout a question tool" "$text"
    fi
    # OpenCode lists a skill by its bare name
    if grep -qE '`herdr:[a-z-]+`' <<<"$body"; then
        check "$skill: says how OpenCode names another plugin's skill" "OpenCode names a skill without its plugin" "$body"
    fi
done
