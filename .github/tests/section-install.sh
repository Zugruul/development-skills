#!/usr/bin/env bash
# section-install.sh -- sourced by run-tests.sh; do not run standalone.
# install-skills.sh: every maintained skill under a name of its own in each client's folder,
# and the OpenCode plugins, in a project or user-wide.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash .github/tests/run-tests.sh" >&2; exit 2; }
echo "== install-skills.sh =="
I_TMP="$(mktemp -d)"
mkdir -p "$I_TMP/home" "$I_TMP/proj"
inst() { env -u CLAUDE_CONFIG_DIR -u OPENCODE_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$I_TMP/home" DEV_SKILLS_PROJECT_ROOT="$I_TMP/proj" bash "$REPO/install-skills.sh" "$@" 2>&1; }
skill_names() { # skills folder -> the frontmatter name of each skill
    local f
    for f in "$1"/*/SKILL.md; do sed -n 's/^name: //p' "$f" | head -1; done
}
want="$(find "$REPO/plugins" -path '*/skills/*/SKILL.md' | wc -l | tr -d ' ')"

for pair in claude:.claude/skills codex:.agents/skills opencode:.opencode/skills; do
    client="${pair%%:*}" dir="$I_TMP/proj/${pair#*:}"
    out="$(inst "$client")"; rc=$?
    check_rc "$client: installs" 0 "$rc"
    check "$client: every skill is there" "$want" "$(find "$dir"/*/SKILL.md | wc -l | tr -d ' ')"
    check "$client: OpenCode reads this folder too, so every name is its own" "$want" "$(skill_names "$dir" | sort -u | wc -l | tr -d ' ')"
    bad=""
    for d in "$dir"/*/; do d="${d%/}"; [[ "$(sed -n 's/^name: //p' "$d/SKILL.md" | head -1)" == "${d##*/}" ]] || bad="$bad ${d##*/}"; done
    check "$client: each name is its folder's name" "[]" "[$bad]"
    out="$(inst "$client")"; rc=$?
    check_rc "$client: installing again changes nothing and succeeds" 0 "$rc"
done

OS="$I_TMP/proj/.opencode"
r=NO; [[ -L "$OS/skills/orchestrate" ]] && r=LINK
check "a skill with a free name stays a link, so edits are live" LINK "$r"
check "the graph orchestrator keeps the short name" "herdr-graph-engineering" "$(readlink "$OS/skills/orchestrate")"
second="$(cat "$OS/skills/herdr-simple-orchestrate-orchestrate/SKILL.md")"
check "the second one is a pointer under its own name" "name: herdr-simple-orchestrate-orchestrate" "$second"
check "with a description" "description: " "$second"
check "that sends the agent to the real file" "$REPO/plugins/herdr-simple-orchestrate/skills/orchestrate/SKILL.md" "$second"

echo "== install-skills.sh: the OpenCode plugins =="
check "opencode: the graph plugin is linked" "$REPO/plugins/herdr-graph-engineering/opencode/herdr-graph.js" "$(readlink "$OS/plugins/herdr-graph-engineering.js")"
r=NO; [[ -e "$I_TMP/proj/.claude/plugins" || -e "$I_TMP/proj/.agents/plugins" ]] && r=YES
check "no other client gets it" NO "$r"
rm "$OS/plugins/herdr-graph-engineering.js"; echo mine >"$OS/plugins/herdr-graph-engineering.js"
out="$(inst opencode)"; rc=$?
check_rc "a file of the user's is never overwritten" 1 "$rc"
check "and the refusal names it" "herdr-graph-engineering.js" "$out"
check "it is left as it was" "mine" "$(cat "$OS/plugins/herdr-graph-engineering.js")"

echo "== install-skills.sh: user-wide =="
out="$(inst opencode --global)"; rc=$?
check_rc "opencode --global installs" 0 "$rc"
r=NO; [[ -L "$I_TMP/home/.config/opencode/plugins/herdr-graph-engineering.js" && -f "$I_TMP/home/.config/opencode/skills/worktree/SKILL.md" ]] && r=YES
check "into OpenCode's config folder, for every worktree" YES "$r"
inst codex --global >/dev/null; inst claude --global >/dev/null
r=NO; [[ -f "$I_TMP/home/.agents/skills/worktree/SKILL.md" && -f "$I_TMP/home/.claude/skills/worktree/SKILL.md" ]] && r=YES
check "codex and claude have their user folders too" YES "$r"
OPENCODE_CONFIG_DIR="$I_TMP/ocdir" HOME="$I_TMP/home" bash "$REPO/install-skills.sh" opencode --global >/dev/null 2>&1
r=NO; [[ -L "$I_TMP/ocdir/plugins/herdr-graph-engineering.js" ]] && r=YES
check "OPENCODE_CONFIG_DIR is honoured" YES "$r"
inst opencode --everywhere >/dev/null; rc=$?
check_rc "an unknown option is a usage error" 2 "$rc"

rm -rf "$I_TMP"
unset -f inst skill_names
