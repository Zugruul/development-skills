#!/usr/bin/env bash
# section-opencode.sh -- sourced by run-tests.sh; do not run standalone.
# OpenCode has no hooks.json: opencode/herdr-graph.js, an OpenCode plugin, turns its events into
# the same calls of hook.sh, resume.sh and await.sh. Driven with a fake SDK client (needs node).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

echo "== opencode: the adapter =="
ADAPTER="$PLUGIN/opencode/herdr-graph.js"
if ! command -v node >/dev/null 2>&1; then
    check "node is on PATH, to test the OpenCode adapter" "yes" "no"
else
O_TMP="$(mktemp -d)"
O_REPO="$O_TMP/repo"
git init -q -b main "$O_REPO" && git -C "$O_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
O_STATE_OLD="$XDG_STATE_HOME"; export XDG_STATE_HOME="$O_TMP/state"
os() { local s="$1"; shift; (cd "$O_TMP" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$O_TMP" HERDR_ENV=1 HERDR_GRAPH_NO_SIGNAL=1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
# drive PANE SCRIPT_JSON
drive() { (cd "$O_TMP" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$O_TMP" HERDR_ENV=1 HERDR_GRAPH_NO_SIGNAL=1 HERDR_PANE_ID="$1" HERDR_GRAPH_TICK=0.2 HERDR_GRAPH_BATCH=0 HERDR_GRAPH_WAIT_MAX="${O_MAX:-2}" node "$FIX/opencode-driver.mjs" "${O_ADAPTER:-$ADAPTER}" "$2" 2>&1); }
ev() { jq -cn --arg t "$1" --argjson p "$2" '{event: {type: $t, properties: $p}}'; }
sc() { local s="$1"; shift; jq -cn --argjson s "$s" '{sessions: $s, steps: $ARGS.positional}' --jsonargs "$@"; }
idle() { ev session.idle "$(jq -cn --arg s "${1:-ses_main}" '{sessionID: $s}')"; }
SES='{"ses_main": {"last": "All done.\n\nNODE investigate RESULT: pass abc1234"}, "ses_child": {"parentID": "ses_main", "last": "NODE investigate RESULT: fail child"}}'
printf '%s' '{"agents": {"a": {"name": "opencode-o", "pane_id": "w1:p2", "agent": "opencode", "agent_status": "working"}, "o": {"name": "graph", "pane_id": "w1:p1", "agent": "opencode", "agent_status": "idle"}}}' >"$O_TMP/state.json"
os session set --key pane --value w1:p1 >/dev/null
os session set --key orchestrator --value graph >/dev/null
os lane new --repo "$O_REPO" --lane o --pattern investigate --idea x --owner graph >/dev/null
os lane node --repo "$O_REPO" --lane o --node investigate --status running --agent opencode-o >/dev/null
O_CLAIM="$O_REPO/.git/herdr-graph/claims/o/investigate.json"
oc_claim() { jq -r "$1" "$O_CLAIM" 2>/dev/null || echo gone; }

out="$(drive "" '{}')"
check "outside herdr it adds no hooks" "HOOKS " "$out"
check_absent "none at all" "event" "$out"
check "it exports one plugin function, as OpenCode loads every export" "EXPORTS HerdrGraphEngineering" "$out"

echo "== opencode: a lane agent's claims =="
out="$(drive w1:p2 "$(sc "$SES" "$(idle)")")"
check "the turn end is a claim" "result pass abc1234 stop-hook" "$(oc_claim '"\(.kind) \(.result) \(.ref) \(.source)"')"
check "of this session" "ses_main" "$(oc_claim .session_id)"
check_absent "and a lane agent is never prompted" "CALL " "$out"
drive w1:p2 "$(sc "$SES" "$(idle ses_child)")" >/dev/null
check "a subagent's turn end is not the agent's" "result pass abc1234" "$(oc_claim '"\(.kind) \(.result) \(.ref)"')"
out="$(drive w1:p2 "$(sc "$SES" '{"chat": {"session": "ses_main", "text": "also do this"}}')")"
check "a new message drops the old claim" "gone" "$(oc_claim .kind)"
Q='{"sessionID": "ses_main", "id": "que_1", "questions": [{"question": "Which time zone?", "header": "Zone", "options": [{"label": "UTC", "description": "d"}, {"label": "local", "description": "d"}]}]}'
drive w1:p2 "$(sc "$SES" "$(ev question.asked "$Q")")" >/dev/null
check "a question keeps its exact text and options" "question Which time zone? [UTC | local]" "$(oc_claim '"\(.kind) \(.ref)"')"
drive w1:p2 "$(sc "$SES" "$(ev question.replied '{"sessionID": "ses_main", "requestID": "que_1", "answers": [["UTC"]]}')")" >/dev/null
check "answered: the claim goes" "gone" "$(oc_claim .kind)"
drive w1:p2 "$(sc "$SES" "$(ev question.asked "$Q")" "$(ev question.rejected '{"sessionID": "ses_main", "requestID": "que_1"}')")" >/dev/null
check "dismissed: the claim goes" "gone" "$(oc_claim .kind)"
drive w1:p2 "$(sc "$SES" "$(ev permission.asked '{"sessionID": "ses_main", "id": "per_1", "permission": "bash", "patterns": ["rm *"], "metadata": {"command": "rm -rf build"}, "always": []}')")" >/dev/null
check "a permission request names the tool and command" "permission bash: rm -rf build" "$(oc_claim '"\(.kind) \(.ref)"')"
drive w1:p2 "$(sc "$SES" "$(ev permission.asked '{"sessionID": "ses_main", "id": "per_2", "permission": "external_directory", "patterns": ["/home/x/*"], "metadata": {}, "always": []}')")" >/dev/null
check "or the paths it asks for" "external_directory: /home/x/*" "$(oc_claim .ref)"
drive w1:p2 "$(sc "$SES" "$(ev session.error '{"sessionID": "ses_main", "error": {"name": "ProviderAuthError", "data": {"message": "login expired"}}}')" "$(idle)")" >/dev/null
check "a failed turn is a failure claim, which its idle event does not replace" "failure login expired" "$(oc_claim '"\(.kind) \(.ref)"')"
rm -f "$O_CLAIM"
drive w1:p2 "$(sc "$SES" "$(ev session.error '{"sessionID": "ses_main", "error": {"name": "MessageAbortedError", "data": {"message": "aborted"}}}')")" >/dev/null
check "the user's own interrupt is no failure" "gone" "$(oc_claim .kind)"

echo "== opencode: the orchestrator =="
os lane new --repo "$O_REPO" --lane q --pattern investigate --idea x --owner graph >/dev/null
os lane ask --repo "$O_REPO" --lane q --text "merge order?" >/dev/null
out="$(drive w1:p1 "$(sc "$SES" "$(idle)")")"
check "a turn that leaves a question unasked is continued" "CALL promptAsync ses_main" "$out"
check "with the reason" "open questions not yet put to the user: q #1" "$out"
check "keeping the agent the user chats with" '"agent":"build"' "$(drive w1:p1 "$(sc "$SES" '{"chat": {"session": "ses_main", "text": "hi"}}' "$(idle)")")"
out="$(O_MAX=1 drive w1:p1 "$(sc "$SES" "$(idle)" "$(idle)" '{"waitCall": 1500}')")"
check "only once in a row" "1" "$(grep -c 'open questions not yet put' <<<"$out")"
os lane asked --repo "$O_REPO" --lane q --id 1 >/dev/null
os session afk on >/dev/null
out="$(drive w1:p1 "$(sc "$SES" '{"chat": {"session": "ses_main", "text": "how is it going?"}}')")"
check "under AFK a message gets the reminder as a hidden part" '"synthetic":true' "$out"
check "that asks if they are still away" "still away" "$out"
check "tied to the message" '"messageID":"msg_1"' "$out"
os session afk off >/dev/null

echo "== opencode: the waiter =="
jq -c '.agents.a.agent_status = "blocked"' "$O_TMP/state.json" >"$O_TMP/state.new" && mv "$O_TMP/state.new" "$O_TMP/state.json"
out="$(O_MAX=20 drive w1:p1 "$(sc "$SES" "$(idle)" '{"waitCall": 15000}')")"
check "an event wakes the idle orchestrator chat" "CALL promptAsync ses_main" "$out"
check "with the watcher's message" "graph: o/investigate blocked" "$out"

echo "== opencode: after a compaction =="
out="$(drive w1:p1 "$(sc "$SES" '{"compacting": "ses_main"}' "$(ev session.compacted '{"sessionID": "ses_main"}')")")"
check "the resume block goes back into the chat" "CALL prompt ses_main" "$out"
check "without starting a turn" '"noReply":true' "$out"
check "and it is the block" "END RESUME" "$out"
check_absent "a lane agent gets none" "CALL " "$(drive w1:p2 "$(sc "$SES" "$(ev session.compacted '{"sessionID": "ses_main"}')")")"

echo "== opencode: installed as a symlink =="
mkdir -p "$O_TMP/plugins" && ln -s "$ADAPTER" "$O_TMP/plugins/herdr-graph-engineering.js"
printf '%s' '{"type":"module"}' >"$O_TMP/plugins/package.json"
rm -f "$O_CLAIM"
O_ADAPTER="$O_TMP/plugins/herdr-graph-engineering.js" drive w1:p2 "$(sc "$SES" "$(idle)")" >/dev/null
check "it finds its scripts through the link" "result pass abc1234" "$(oc_claim '"\(.kind) \(.result) \(.ref)"')"

rm -rf "$O_TMP"
export XDG_STATE_HOME="$O_STATE_OLD"
unset -f os drive ev sc idle oc_claim
unset O_ADAPTER
fi
