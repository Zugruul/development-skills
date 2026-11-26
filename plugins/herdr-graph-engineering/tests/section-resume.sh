#!/usr/bin/env bash
# section-resume.sh -- sourced by run-tests.sh; do not run standalone.
# Surviving a compaction: the session file (session.sh), lane notes and extra done criteria
# (lane.sh note / done-extra), the one-block picture (resume.sh) and the Claude Code hooks.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

R_TMP="$(mktemp -d)"
RSC="$PLUGIN/scripts"
R_REPO="$R_TMP/repo" R_REPO2="$R_TMP/other"
for r in "$R_REPO" "$R_REPO2"; do
    git init -q -b main "$r" && git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
R_STATE="$R_TMP/state-home"
R_SCRATCH="$R_TMP/scratch"
mkdir -p "$R_SCRATCH"
# r SCRIPT ARGS...: run a plugin script with the stub herdr, a private state home, pane w1:p1
r() { local s="$1"; shift; (cd "$R_TMP" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$R_TMP" HERDR_ENV=1 HERDR_PANE_ID="${R_PANE:-w1:p1}" \
    XDG_STATE_HOME="$R_STATE" XDG_CONFIG_HOME="$R_TMP/config" bash "$RSC/$s.sh" "$@"); }
rst() { printf '%s' "$1" >"$R_TMP/state.json"; }
rlf() { yq -r "$1" "$(git -C "$2" rev-parse --path-format=absolute --git-common-dir)/herdr-graph/$3.yaml"; }
SESS="$R_STATE/herdr-graph/sessions/graph.yaml"
rst '{}'

echo "== resume: the session file =="
out="$(r session show 2>&1)"; rc=$?
check_rc "show without a session file says so" 6 "$rc"
check "the missing file is named" "NO SESSION graph" "$out"
out="$(r session set --key pane --value w1:p1 2>&1)"; rc=$?
check_rc "set writes the session file" 0 "$rc"
check "the session file lives in the user's state folder" "$SESS" "$(r session path)"
r session set --key scratch --value "$R_SCRATCH" >/dev/null
r session set --key orchestrator --value graph >/dev/null
check "set records the pane" "w1:p1" "$(yq -r .pane "$SESS")"
check "set records the scratch folder" "$R_SCRATCH" "$(yq -r .scratch "$SESS")"
out="$(r session set --key nonsense --value x 2>&1)"; rc=$?
check_rc "set refuses an unknown key" 2 "$rc"
out="$(r session add --list standing --text "new worktrees approved, except a new repository or an unseen gate" 2>&1)"; rc=$?
check_rc "add appends a standing answer" 0 "$rc"
check "add prints the item's id" "ADDED standing 1" "$out"
r session add --list standing --text "opencode folder access: Allow always" >/dev/null
check "both standing answers are kept" "2" "$(yq -r '.standing | length' "$SESS")"
out="$(r session add --list queued --text "add the panel shortcut" 2>&1)"; rc=$?
check_rc "a queued lane needs its lane name" 2 "$rc"
r session add --list queued --lane panel-shortcut --repo "$R_REPO" --ref "$R_SCRATCH/panel-shortcut-brief.md" --text "add the panel shortcut" >/dev/null
check "a queued lane keeps its brief path" "$R_SCRATCH/panel-shortcut-brief.md" "$(yq -r '.queued[0].ref' "$SESS")"
r session add --list renames --text "lane kinds renamed to ask-agent-kind" >/dev/null
r session add --list notes --text "the user decides merges; keep the 3-agent limit" >/dev/null
r session add --list files --ref "$R_SCRATCH/rev-1-posting.md" --text "posting file for PR 41" >/dev/null
out="$(r session add --list standing --text "use token ghp_abcdefghijklmnopqrstuvwxyz0123456789" 2>&1)"; rc=$?
check_rc "a secret is refused" 2 "$rc"
check "the refusal says why" "SECRET" "$out"
check_absent "the secret never reaches the file" "ghp_" "$(cat "$SESS")"
out="$(r session add --list bogus --text x 2>&1)"; rc=$?
check_rc "add refuses an unknown list" 2 "$rc"
r session add --list standing --text "temporary" >/dev/null
id="$(yq -r '.standing[] | select(.text == "temporary") | .id' "$SESS")"
out="$(r session del --list standing --id "$id" 2>&1)"; rc=$?
check_rc "del removes an item by id" 0 "$rc"
check_absent "the item is gone" "temporary" "$(cat "$SESS")"
out="$(r session del --list standing --id 999 2>&1)"; rc=$?
check_rc "del of an unknown id is refused" 6 "$rc"
r session add --list queued --lane gone-lane --text "x" >/dev/null
r session del --list queued --lane gone-lane >/dev/null
check_absent "del --lane removes a lane's items" "gone-lane" "$(cat "$SESS")"
check "find names the session of a pane" "graph" "$(r session find --pane w1:p1)"
out="$(r session find --pane w9:p9 2>&1)"; rc=$?
check_rc "find of an unknown pane fails" 1 "$rc"
out="$(r session --session "Not A Slug" show 2>&1)"; rc=$?
check_rc "a session name must be a slug" 2 "$rc"
check "show prints the file" "standing:" "$(r session show)"
check_absent "no temporary file or lock is left behind" "XXXX" "$(ls -a "$R_STATE/herdr-graph/sessions")"
check_absent "the lock is released" ".lock" "$(ls -a "$R_STATE/herdr-graph/sessions")"

echo "== resume: lane notes and extra done criteria =="
r lane new --repo "$R_REPO" --lane task-a --pattern solo --idea "fix the limiter" --gate "npm test" --branch feat/task-a --workspace w2 --owner graph >/dev/null
out="$(r lane note --repo "$R_REPO" --lane task-a --node impl --ref "$R_SCRATCH/task-a-followup.md" --text "follow-up sent: also update the docs" 2>&1)"; rc=$?
check_rc "note records a lane fact" 0 "$rc"
check "the note keeps its text" "also update the docs" "$(rlf '.notes[0].text' "$R_REPO" task-a)"
check "the note keeps its node and reference" "impl $R_SCRATCH/task-a-followup.md" "$(rlf '.notes[0] | .node + " " + .ref' "$R_REPO" task-a)"
check "the note is in the history" "note: follow-up sent" "$(rlf '.history | join("\n")' "$R_REPO" task-a)"
out="$(r lane note --repo "$R_REPO" --lane task-a --text "password=hunter22" 2>&1)"; rc=$?
check_rc "a secret note is refused" 2 "$rc"
out="$(r lane done-extra --repo "$R_REPO" --lane task-a --text "merged to main and this window runs the new plugin version" 2>&1)"; rc=$?
check_rc "done-extra adds a criterion" 0 "$rc"
check "the criterion starts unmet" "false" "$(rlf '.done_extra[0].met' "$R_REPO" task-a)"
out="$(r lane done-extra --repo "$R_REPO" --lane task-a --met 1 2>&1)"; rc=$?
check_rc "done-extra --met marks it" 0 "$rc"
check "the criterion is met" "true" "$(rlf '.done_extra[0].met' "$R_REPO" task-a)"
out="$(r lane done-extra --repo "$R_REPO" --lane task-a --met 7 2>&1)"; rc=$?
check_rc "an unknown criterion is refused" 6 "$rc"
r lane done-extra --repo "$R_REPO" --lane task-a --text "panel restarted" >/dev/null

echo "== resume: the picture after a compaction =="
# task-a: impl running, agent working. task-b: impl running, agent blocked. task-c: agent gone.
# task-d: not started. task-e (other repo): all nodes done, no PR yet. task-f: done with an open PR.
# task-g: done, PR merged, extra criterion unmet. task-h: done, merged, nothing left. task-i: failed gate.
r lane node --repo "$R_REPO" --lane task-a --node impl --status running --agent claude-task-a-impl >/dev/null
for l in task-b task-c task-d task-f task-g task-h task-i; do
    r lane new --repo "$R_REPO" --lane "$l" --pattern solo --idea "idea $l" --gate "npm test" --branch "feat/$l" --owner graph >/dev/null
done
r lane new --repo "$R_REPO2" --lane task-e --pattern solo --idea "idea e" --gate "make check" --branch feat/task-e --owner graph >/dev/null
r lane node --repo "$R_REPO" --lane task-b --node impl --status running --agent codex-task-b-impl >/dev/null
r lane ask --repo "$R_REPO" --lane task-b --node impl --text "Which environment, staging or production?" >/dev/null
r lane node --repo "$R_REPO" --lane task-c --node impl --status running --agent opencode-task-c-impl >/dev/null
for l in task-f task-g task-h task-i; do
    r lane node --repo "$R_REPO" --lane "$l" --node impl --status "done" --result pass --ref abc123 >/dev/null
done
for l in task-f task-g task-h; do
    r lane node --repo "$R_REPO" --lane "$l" --node tests --status "done" --result pass --exit 0 >/dev/null
    r lane set --repo "$R_REPO" --lane "$l" --key status --value "done" >/dev/null
done
r lane node --repo "$R_REPO" --lane task-i --node tests --status failed --result fail --exit 1 >/dev/null
r lane node --repo "$R_REPO2" --lane task-e --node impl --status "done" --result pass >/dev/null
r lane node --repo "$R_REPO2" --lane task-e --node tests --status "done" --result pass >/dev/null
r lane done-extra --repo "$R_REPO" --lane task-g --text "plugin reinstalled and panel restarted" >/dev/null
r lane new --repo "$R_REPO" --lane old-one --pattern solo --idea old --gate t >/dev/null
r lane close --repo "$R_REPO" --lane old-one >/dev/null
D1="$(git -C "$R_REPO" rev-parse --path-format=absolute --git-common-dir)/herdr-graph"
cat >"$D1/prs.json" <<'EOF'
{"fetched": 1, "lanes": {
 "task-f": [{"number": 12, "url": "https://github.com/o/r/pull/12", "state": "OPEN", "isDraft": true, "reviewDecision": ""}],
 "task-g": [{"number": 13, "url": "https://github.com/o/r/pull/13", "state": "MERGED", "isDraft": false, "reviewDecision": ""}],
 "task-h": [{"number": 14, "url": "https://github.com/o/r/pull/14", "state": "MERGED", "isDraft": false, "reviewDecision": ""}]}}
EOF
printf 'reviewer codex\npr-reviewer codex\n' >"$R_SCRATCH/graph-kinds"
printf 'folder trust for lane worktrees of this repository: yes\n' >"$R_SCRATCH/graph-dialogs"
rst "$(jq -cn --arg r2 "$R_REPO2" '{agents: {
    a: {name: "claude-task-a-impl", agent_status: "working", pane_id: "w2:p2"},
    b: {name: "codex-task-b-impl", agent_status: "blocked", pane_id: "w3:p2"},
    g: {name: "graph", agent_status: "working", pane_id: "w1:p1"}},
  workspaces: [{worktree: {repo_root: $r2}}]}')"

out="$(r resume --repo "$R_REPO" 2>&1)"; rc=$?
check_rc "resume runs" 0 "$rc"
check "the header names the session and pane" "RESUME graph (pane w1:p1)" "$out"
check "the scratch folder is named" "scratch: $R_SCRATCH" "$out"
check "it tells the orchestrator to re-start its listeners" "herdr:listen" "$out"
check "lanes from every repository with a Herdr workspace" "task-e" "$out"
check "lanes from the given repository" "task-a" "$out"
check_absent "closed lanes are left out" "old-one" "$out"
lane_block() { awk -v l="lane $1 " 'index($0, l) == 1 {f=1; print; next} f && /^lane / {exit} f && /^[A-Z]/ {exit} f' <<<"$out"; }
check "a working agent: listen to it" "next: listen to claude-task-a-impl" "$(lane_block task-a)"
check "a node's agent and its live state" "claude-task-a-impl (impl) working" "$(lane_block task-a)"
check "lane notes are shown" "follow-up sent: also update the docs" "$(lane_block task-a)"
check "extra done criteria are shown with their state" "[x] merged to main and this window runs the new plugin version" "$(lane_block task-a)"
check "an unmet extra criterion is open" "[ ] panel restarted" "$(lane_block task-a)"
check "the open question is shown" "Which environment, staging or production?" "$(lane_block task-b)"
check "a blocked lane: ask the user" "next: ask the user" "$(lane_block task-b)"
check "a gone agent is called gone" "opencode-task-c-impl (impl) gone" "$(lane_block task-c)"
check "a gone agent: check its work" "next: opencode-task-c-impl is gone" "$(lane_block task-c)"
check "a lane not started: start its ready node" "next: start impl (agent implementer)" "$(lane_block task-d)"
check "all nodes done without a pull request: open the draft" "next: open draft PR" "$(lane_block task-e)"
check "a done lane with an open pull request: ask the user to merge" "next: ask the user to merge #12" "$(lane_block task-f)"
check "the pull request and its state" "#12 OPEN draft https://github.com/o/r/pull/12" "$(lane_block task-f)"
check "merged but an extra criterion is unmet: finish it" "next: finish extra done: plugin reinstalled and panel restarted" "$(lane_block task-g)"
check "merged and nothing left: offer cleanup" "next: offer cleanup" "$(lane_block task-h)"
check "a failed gate: retry it" "next: lane.sh retry --lane task-i --node tests" "$(lane_block task-i)"
check "running agents are counted against the limit" "2 of 3 agents running" "$out"
check "queued lanes with their brief" "panel-shortcut" "$(sed -n '/^QUEUED/,/^[A-Z]/p' <<<"$out")"
check "the queued brief path" "$R_SCRATCH/panel-shortcut-brief.md" "$out"
check "standing answers" "opencode folder access: Allow always" "$(sed -n '/^STANDING ANSWERS/,/^[A-Z]/p' <<<"$out")"
check "standing kind choices from the scratch folder" "reviewer codex" "$(sed -n '/^STANDING KINDS/,/^[A-Z]/p' <<<"$out")"
check "standing dialog answers from the scratch folder" "folder trust for lane worktrees" "$out"
check "renames" "lane kinds renamed to ask-agent-kind" "$(sed -n '/^RENAMES/,/^[A-Z]/p' <<<"$out")"
check "notes" "keep the 3-agent limit" "$(sed -n '/^NOTES/,/^[A-Z]/p' <<<"$out")"
check "files" "$R_SCRATCH/rev-1-posting.md" "$(sed -n '/^FILES/,/^[A-Z]/p' <<<"$out")"
check "the per-lane next action ends the block" "END RESUME" "$(tail -1 <<<"$out")"

out="$(r resume --repo "$R_REPO" --out "$R_TMP/snap.md" 2>&1)"; rc=$?
check_rc "resume --out runs" 0 "$rc"
check "--out writes the block to the file" "RESUME graph" "$(cat "$R_TMP/snap.md")"

out="$(R_PANE=w5:p5 r resume --repo "$R_REPO" 2>&1)"; rc=$?
check_rc "resume works without a session for this pane" 0 "$rc"
check "without a session it says so" "no session file" "$out"
check "without a session it still lists the lanes" "task-a" "$out"

echo "== resume: Claude Code hooks =="
SNAP="$R_STATE/herdr-graph/sessions/graph.resume.md"
rm -f "$SNAP"
out="$(printf '{"hook_event_name":"PreCompact","trigger":"auto"}' | r resume --hook pre-compact 2>&1)"; rc=$?
check_rc "the pre-compact hook succeeds" 0 "$rc"
check "the pre-compact hook writes a fresh snapshot" "RESUME graph" "$(cat "$SNAP" 2>/dev/null)"
rm -f "$SNAP"
out="$(printf '{}' | R_PANE=w5:p5 r resume --hook pre-compact 2>&1)"; rc=$?
check_rc "the hook in a chat that is not the orchestrator succeeds" 0 "$rc"
check_rc "and prints nothing" 0 "${#out}"
check_rc "and writes no snapshot" 1 "$([ -f "$SNAP" ]; echo $?)"
out="$(printf '{"hook_event_name":"SessionStart","source":"compact"}' | r resume --hook session-start 2>&1)"; rc=$?
check_rc "the session-start hook succeeds" 0 "$rc"
check "it injects the picture as context" "SessionStart" "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out" 2>&1)"
check "the context is the resume block" "RESUME graph" "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out" 2>&1)"
check "the context points at the skill's resume section" "After a compaction" "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$out" 2>&1)"
out="$(printf '{}' | R_PANE=w5:p5 r resume --hook session-start 2>&1)"; rc=$?
check_rc "session-start in another chat succeeds" 0 "$rc"
check_rc "and injects nothing" 0 "${#out}"
out="$(printf '{}' | PATH="/usr/bin:/bin" HERDR_PANE_ID=w1:p1 XDG_STATE_HOME="$R_STATE" bash "$RSC/resume.sh" --hook session-start 2>&1)"; rc=$?
check_rc "a hook never fails the chat, even without its tools" 0 "$rc"

HJ="$PLUGIN/hooks/hooks.json"
check "the plugin ships Claude Code hooks" "PreCompact" "$(jq -r '.hooks | keys | join(" ")' "$HJ" 2>&1)"
check "the session-start hook fires after a compaction only" "compact" "$(jq -r '.hooks.SessionStart[0].matcher' "$HJ" 2>&1)"
check "the pre-compact hook runs resume.sh" 'resume.sh" --hook pre-compact' "$(jq -r '.hooks.PreCompact[0].hooks[0].command' "$HJ" 2>&1)"
check "the session-start hook runs resume.sh" 'resume.sh" --hook session-start' "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HJ" 2>&1)"
check "the hooks use the plugin root" '${CLAUDE_PLUGIN_ROOT}' "$(cat "$HJ" 2>&1)"

echo "== resume: the skill and the docs =="
orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: a section for after a compaction" "After a compaction (or a new session)" "$orch"
check "orchestrate: runs resume first" 'bash "../../scripts/resume.sh"' "$orch"
check "orchestrate: re-starts listeners for live agents" "re-start \`herdr:listen\`" "$orch"
check "orchestrate: records its pane in the session" "session.sh\" set --key pane" "$orch"
check "orchestrate: keeps standing answers in the session file" "session.sh\" add --list standing" "$orch"
check "orchestrate: queued lanes go in the session file" "add --list queued" "$orch"
check "orchestrate: extra done criteria go in the lane file" "lane.sh done-extra" "$orch"
check "orchestrate: follow-ups go in the lane file" "lane.sh note" "$orch"
check "orchestrate: never stores secrets" "Never store a token" "$orch"
rd="$(cat "$PLUGIN/README.md")"
check "README: the /compact focus text" "/compact" "$rd"
check "README: the plain resume command for other clients" "resume.sh" "$rd"
check "README: the hooks are Claude Code only" "PreCompact" "$rd"

rm -rf "$R_TMP"
