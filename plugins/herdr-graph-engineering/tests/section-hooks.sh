#!/usr/bin/env bash
# section-hooks.sh -- sourced by run-tests.sh; do not run standalone.
# The hooks inside lane agents only observe: they store what the agent claimed, print nothing,
# never fail, and leave at once in a pane that is neither a lane's nor the orchestrator's. In the
# orchestrator's pane the Stop hook keeps a question from being left unasked.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

H_TMP="$(mktemp -d)"
H_REPO="$H_TMP/repo"
git init -q -b main "$H_REPO" && git -C "$H_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
H_STATE_OLD="$XDG_STATE_HOME"; export XDG_STATE_HOME="$H_TMP/state"
hs() { local s="$1"; shift; (cd "$H_TMP" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$H_TMP" HERDR_ENV=1 HERDR_GRAPH_NO_SIGNAL=1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
hook() { local pane="$1" ev="$2"; printf '%s' "$3" | HERDR_PANE_ID="$pane" hs hook "$ev"; }
printf '%s' '{"agents": {"a": {"name": "claude-h", "pane_id": "w1:p2", "agent": "claude", "agent_status": "working"}, "o": {"name": "graph", "pane_id": "w1:p1", "agent": "claude", "agent_status": "idle"}}}' >"$H_TMP/state.json"
hs session set --key pane --value w1:p1 >/dev/null
hs session set --key orchestrator --value graph >/dev/null
hs lane new --repo "$H_REPO" --lane h --pattern investigate --idea x --owner graph >/dev/null
hs lane node --repo "$H_REPO" --lane h --node investigate --status running --agent claude-h >/dev/null
H_CLAIM="$H_REPO/.git/herdr-graph/claims/h/investigate.json"
hc() { jq -r "$1" "$H_CLAIM" 2>/dev/null; }
run="$(hs lane show --repo "$H_REPO" --lane h --json | jq -r .nodes.investigate.run)"

echo "== hooks: a foreign pane costs nothing =="
mkdir -p "$H_TMP/spy"
for t in yq herdr jq git; do printf '#!/bin/sh\necho %s >>"%s/spy.log"\n' "$t" "$H_TMP" >"$H_TMP/spy/$t"; chmod +x "$H_TMP/spy/$t"; done
out="$(printf '{"last_assistant_message":"NODE investigate RESULT: pass a"}' | PATH="$H_TMP/spy:$PATH" HERDR_PANE_ID=w7:p7 XDG_STATE_HOME="$H_TMP/state" bash "$PLUGIN/scripts/hook.sh" stop 2>&1)"; rc=$?
check_rc "it exits 0" 0 "$rc"
check "printing nothing" "[]" "[$out]"
check "and calls no yq, herdr, jq or git" "[]" "[$(cat "$H_TMP/spy.log" 2>/dev/null)]"
out="$(printf '{}' | env -u HERDR_PANE_ID XDG_STATE_HOME="$H_TMP/state" bash "$PLUGIN/scripts/hook.sh" stop 2>&1)"
check "outside herdr it does nothing" "[]" "[$out]"

echo "== hooks: the lane's turn end is a claim =="
out="$(hook w1:p2 stop '{"hook_event_name":"Stop","last_assistant_message":"All done.\n\nNODE investigate RESULT: pass abc1234\n","background_tasks":[],"session_crons":[]}')"; rc=$?
check_rc "the stop hook succeeds" 0 "$rc"
check "and prints no decision" "[]" "[$out]"
check "the claim holds the result" "result pass abc1234 stop-hook" "$(hc '"\(.kind) \(.result) \(.ref) \(.source)"')"
check "of this run" "$run" "$(hc .run)"
hook w1:p2 stop '{"last_assistant_message":"I was told to end with:\nNODE investigate RESULT: pass abc\nI will do that when done.","background_tasks":[]}' >/dev/null
check "a quoted line before more text is no result" "none" "$(hc .kind)"
hook w1:p2 stop '{"last_assistant_message":"Tests are running.","background_tasks":[{"id":"1"}]}' >/dev/null
check "background work means not finished" "busy" "$(hc .kind)"
hook w1:p2 prompt '{"prompt":"also do this"}' >/dev/null
check "a new turn drops the old claim" "gone" "$([ -f "$H_CLAIM" ] && echo there || echo gone)"

echo "== hooks: questions, permissions and failures =="
out="$(hook w1:p2 ask '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which time zone?","options":[{"label":"UTC"},{"label":"local"}]}]}}')"
check "the question hook prints nothing, so the dialog is untouched" "[]" "[$out]"
check "the exact question and options are kept" "Which time zone? [UTC | local]" "$(hc .ref)"
check "as a question" "question ask-hook" "$(hc '"\(.kind) \(.source)"')"
hook w1:p2 permission '{"tool_name":"AskUserQuestion","tool_input":{}}' >/dev/null
check "the dialog's own permission event keeps the question" "question" "$(hc .kind)"
hook w1:p2 ask-done '{"tool_name":"AskUserQuestion"}' >/dev/null
check "answered: the claim goes" "gone" "$([ -f "$H_CLAIM" ] && echo there || echo gone)"
out="$(hook w1:p2 permission '{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}')"
check "a permission request decides nothing" "[]" "[$out]"
check "it names the tool" "Bash: rm -rf build" "$(hc .ref)"
hook w1:p2 stop-failure '{"hook_event_name":"StopFailure","error":"rate_limit"}' >/dev/null
check "a failed turn is a failure claim" "failure rate_limit" "$(hc '"\(.kind) \(.ref)"')"
out="$(hook w1:p2 stop 'not json at all')"; rc=$?
check_rc "bad input never fails the agent" 0 "$rc"

echo "== hooks: a pane whose node moved on records nothing =="
hs lane node --repo "$H_REPO" --lane h --node investigate --status "done" --result pass >/dev/null
rm -f "$H_CLAIM"
hook w1:p2 stop '{"last_assistant_message":"NODE investigate RESULT: pass late"}' >/dev/null
check "no claim for a finished node" "gone" "$([ -f "$H_CLAIM" ] && echo there || echo gone)"

echo "== hooks: the orchestrator leaves no question unasked =="
hs lane new --repo "$H_REPO" --lane q --pattern investigate --idea x --owner graph >/dev/null
hs lane ask --repo "$H_REPO" --lane q --text "merge order?" >/dev/null
out="$(hook w1:p1 stop '{"stop_hook_active":false}')"
check "the turn may not end" '"decision":"block"' "$out"
check "it names the lane and question" "q #1" "$out"
check "a second stop is let through" "[]" "[$(hook w1:p1 stop '{"stop_hook_active":true}')]"
hs session afk on >/dev/null
check "under AFK a question waits without a dialog" "[]" "[$(hook w1:p1 stop '{"stop_hook_active":false}')]"
out="$(hook w1:p1 prompt '{"prompt":"how is it going?"}')"
check "a message while AFK reminds to show the list and ask" "still away" "$out"
check "as added context" "UserPromptSubmit" "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")"
check "the watcher's own message is not the user" "[]" "[$(hook w1:p1 prompt '{"prompt":"GRAPH EVENT (from the watcher, not the user): a/b blocked"}')]"
hs session afk off >/dev/null
check "AFK off: no reminder" "[]" "[$(hook w1:p1 prompt '{"prompt":"hi"}')]"
hs lane asked --repo "$H_REPO" --lane q --id 1 >/dev/null
check "once asked the turn may end" "[]" "[$(hook w1:p1 stop '{"stop_hook_active":false}')]"
hs lane new --repo "$H_REPO" --lane other --pattern investigate --idea x --owner someone-else >/dev/null
hs lane ask --repo "$H_REPO" --lane other --text "not mine" >/dev/null
check "another orchestrator's questions are not mine" "[]" "[$(hook w1:p1 stop '{"stop_hook_active":false}')]"

echo "== hooks: the manifests =="
HJ="$PLUGIN/hooks/hooks.json"
hcmd() { jq -r --arg e "$1" '[.hooks[$e][]?.hooks[].command] | join("\n")' "$HJ"; }
for pair in Stop:stop UserPromptSubmit:prompt PreToolUse:ask PostToolUse:ask-done PermissionRequest:permission StopFailure:stop-failure; do
    check "${pair%:*} runs hook.sh ${pair#*:}" "hook.sh\" ${pair#*:}" "$(hcmd "${pair%:*}")"
done
check "the question hooks match only AskUserQuestion" "AskUserQuestion AskUserQuestion" "$(jq -r '"\(.hooks.PreToolUse[0].matcher) \(.hooks.PostToolUse[0].matcher)"' "$HJ")"
check "no hook guards commands" "2" "$(jq '[.hooks.PreToolUse, .hooks.PostToolUse] | length' "$HJ")"
w="$(jq -c '[.hooks.Stop[].hooks[] | select(.command | test("await.sh"))][0]' "$HJ")"
check "a Stop hook arms the waiter" 'await.sh\" --hook' "$w"
check "waking the chat" '"asyncRewake":true' "$w"
check "with a long enough timeout" '"timeout":86400' "$w"
# the events Herdr 0.9.5 was seen to run plugin hooks for
H_VERIFIED=" pane.agent_status_changed pane.closed pane.exited tab.closed workspace.closed worktree.removed "
bad=""
for ev in $(sed -n 's/^on = "\(.*\)"$/\1/p' "$PLUGIN/herdr-plugin.toml"); do
    case "$H_VERIFIED" in *" $ev "*) ;; *) bad="$bad $ev" ;; esac
done
check "every Herdr event the plugin hooks is a verified one" "[]" "[$bad]"
for ev in pane.agent_status_changed pane.closed pane.exited tab.closed workspace.closed; do
    check "the plugin listens to $ev" "on = \"$ev\"" "$(cat "$PLUGIN/herdr-plugin.toml")"
done

rm -rf "$H_TMP"
export XDG_STATE_HOME="$H_STATE_OLD"
unset -f hs hook hc hcmd
