#!/usr/bin/env bash
# section-drift.sh -- sourced by run-tests.sh; do not run standalone.
# Live lane state: a node recorded running whose agent has finished, asks, is blocked or is gone
# shows under NEEDS YOU without the orchestrator recording anything (status.sh reads Herdr's
# agent list and drift.sh's cache of each agent's RESULT line); drift.sh prints every mismatch
# between the lane files and the live agents with the lane.sh command that would fix it; a lane
# whose own pull request merged waits in NEEDS YOU for the cleanup confirmation.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

D_TMP="$(mktemp -d)"
D_REPO="$D_TMP/repo"
git init -q -b main "$D_REPO" && git -C "$D_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
export XDG_CONFIG_HOME="$D_TMP/config"
dg() { local s="$1"; shift; (cd "$D_TMP" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$D_TMP" HERDR_ENV=1 NO_COLOR=1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
dst() { printf '%s' "$1" >"$D_TMP/state.json"; : >"$D_TMP/calls.log"; }
D_DIR="$(git -C "$D_REPO" rev-parse --path-format=absolute --git-common-dir)/herdr-graph"
sect() { dg status --json --repo "$D_REPO" | jq -r --arg l "$1" '.[] | select(.lane == $l) | .section'; }
lj() { dg status --json --repo "$D_REPO" | jq -r --arg l "$1" ".[] | select(.lane == \$l) | $2"; }
# one investigate lane per case, its node running on agent claude-<lane>
for l in ask fin bad gone busy stuck quiet; do
    dg lane new --repo "$D_REPO" --lane "$l" --pattern investigate --idea "look at $l" >/dev/null
    dg lane node --repo "$D_REPO" --lane "$l" --node investigate --status running --agent "claude-$l" >/dev/null
done
# the brief on screen carries the template line; only a real RESULT line counts
# shellcheck disable=SC2016  # the backticks are text on the screen
TPL='End with: `NODE investigate RESULT: <pass|fail|question> <ref>`'
agent() { # lane status screen [seq]
    jq -cn --arg l "$1" --arg s "$2" --arg t "$3" --argjson q "${4:-3}" \
        '{name: "claude-\($l)", pane_id: "w-\($l):p1", agent_status: $s, state_change_seq: $q, screen: $t}'
}
AGENTS="$(jq -cn \
    --argjson a "$(agent ask idle "$TPL
I have 4 questions, see the file.
NODE investigate RESULT: question /tmp/ask-questions.md")" \
    --argjson b "$(agent fin idle "$TPL
⏺ NODE investigate RESULT: pass 1a2b3c4")" \
    --argjson c "$(agent bad "done" "NODE investigate RESULT: fail could not build")" \
    --argjson d "$(agent busy working "NODE investigate RESULT: pass oldold1")" \
    --argjson e "$(agent stuck blocked "Allow running rm -rf build? (y/n)")" \
    --argjson f "$(agent quiet idle "$TPL
I stopped here.")" \
    '{agents: {a: $a, b: $b, c: $c, d: $d, e: $e, f: $f}}')"
dst "$AGENTS"

echo "== drift: status never waits on a screen read =="
check_absent "status.sh reads no agent screen" "agent read" "$(cat "$D_TMP/calls.log")"
check "a blocked agent's lane needs the user" "needs" "$(sect stuck)"
check "and says the agent is blocked" "claude-stuck is blocked" "$(lj stuck '.attention | join(" ")')"
check "a gone agent's lane needs the user at once" "needs" "$(sect gone)"
check "and says the agent is gone" "agent claude-gone is gone" "$(lj gone '.attention | join(" ")')"
check "a working agent's lane is working" "working" "$(sect busy)"
check "a finished agent not yet read stays working until drift.sh reads it" "working" "$(sect fin)"

echo "== drift: drift.sh reads the finished agents and prints the mismatches =="
: >"$D_TMP/calls.log"
before="$(cat "$D_DIR"/*.yaml | shasum)"
out="$(dg drift --repo "$D_REPO")"; rc=$?
check_rc "drift.sh exits 0" 0 "$rc"
check "drift.sh never writes a lane file" "$before" "$(cat "$D_DIR"/*.yaml | shasum)"
check "it reads the screen of a finished agent" "agent read claude-fin --source" "$(cat "$D_TMP/calls.log")"
check_absent "it never reads a working agent's screen" "agent read claude-busy" "$(cat "$D_TMP/calls.log")"
check "a question is a mismatch, with the ask command" "DRIFT ask/investigate question: claude-ask asks: /tmp/ask-questions.md | lane.sh ask --repo $D_REPO --lane ask --node investigate --text" "$out"
check "a pass is a mismatch, to verify before recording" "DRIFT fin/investigate finished pass 1a2b3c4: verify it, then | lane.sh node --repo $D_REPO --lane fin --node investigate --status done --result pass --ref 1a2b3c4" "$out"
check "a fail is a mismatch with the failed command" "DRIFT bad/investigate finished fail could not build" "$out"
check "a fail records failed" "--lane bad --node investigate --status failed --result fail" "$out"
check "a blocked agent is a mismatch" "DRIFT stuck/investigate blocked: claude-stuck" "$out"
check "a gone agent is a mismatch" "DRIFT gone/investigate gone: agent claude-gone" "$out"
check "an idle agent without a RESULT line is a mismatch" "DRIFT quiet/investigate stopped: claude-quiet is idle without a RESULT line" "$out"
check_absent "a working agent is no mismatch" "busy/" "$out"
check_absent "the brief's template line is no RESULT" "<pass|fail|question>" "$out"
check "the reads are cached next to the lane files" "1a2b3c4" "$(jq -r '.agents["claude-fin"].ref' "$D_DIR/live.json")"

echo "== drift: status shows the cached results in the right section =="
check "a question: NEEDS YOU" "needs" "$(sect ask)"
check "the agent's question is the lane's question" "investigate (claude-ask) asks: /tmp/ask-questions.md" "$(lj ask '.question')"
check "marked as read from the agent, not recorded" "true" "$(lj ask '.question_live')"
check "a pass: NEEDS YOU" "needs" "$(sect fin)"
check "as finished, to check and record" "investigate finished: pass 1a2b3c4 (claude-fin); check and record" "$(lj fin '.attention | join(" ")')"
check "a fail: NEEDS YOU" "needs" "$(sect bad)"
check "an idle agent without a result: NEEDS YOU" "claude-quiet stopped without a RESULT line" "$(lj quiet '.attention | join(" ")')"
check "still working: working" "working" "$(sect busy)"
txt="$(dg status --text --repo "$D_REPO")"
check "status --text shows what needs the user" "! investigate finished: pass 1a2b3c4 (claude-fin); check and record" "$txt"
check "status --text shows the agent's question" "? investigate (claude-ask) asks: /tmp/ask-questions.md" "$txt"
check "the tab bar counts them" "🔴 6" "$(dg status --line --repo "$D_REPO")"
frame="$(cd "$D_REPO" && env -u HERDR_PANE_ID -u HERDR_TAB_ID PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$D_TMP" HERDR_ENV=1 NO_COLOR=1 bash "$PLUGIN/scripts/panel.sh" --frame --width 160)"
check "the panel shows it under NEEDS YOU" "investigate finished: pass 1a2b3c4 (claude-fin); check and record" "$frame"

echo "== drift: a cached result is dropped once the agent moves on =="
dst "$(jq -c '.agents.b.state_change_seq = 9' <<<"$AGENTS")"
check "a newer state of the agent ignores the old read" "working" "$(sect fin)"
dst "$(jq -c '.agents.b.agent_status = "working"' <<<"$AGENTS")"
check "a working agent ignores the old read" "working" "$(sect fin)"
dst "$AGENTS"
dg lane node --repo "$D_REPO" --lane fin --node investigate --status "done" --result pass --ref 1a2b3c4 >/dev/null
check "once recorded the lane follows its file" "working" "$(sect fin)"
check "with nothing left to show" "0" "$(lj fin '.attention | length')"
check_absent "and drift.sh has nothing to say about it" "fin/" "$(dg drift --repo "$D_REPO")"
check "--quiet only refreshes the cache" "" "$(dg drift --repo "$D_REPO" --quiet)"

echo "== drift: a merged pull request waits for the cleanup confirmation =="
for l in ask bad gone busy stuck quiet; do dg lane close --repo "$D_REPO" --lane "$l" >/dev/null; done
dg lane new --repo "$D_REPO" --lane merged --pattern investigate --idea "see https://github.com/o/r/pull/4" --branch feat/merged >/dev/null
dg lane new --repo "$D_REPO" --lane other --pattern investigate --idea "about https://github.com/o/r/pull/4" --branch feat/other >/dev/null
dg lane new --repo "$D_REPO" --lane kept --pattern investigate --idea x --branch feat/kept >/dev/null
dg lane set --repo "$D_REPO" --lane kept --key cleanup --value declined >/dev/null
pr() { jq -cn --argjson n "$1" --arg b "$2" --arg s "$3" '{number: $n, url: "https://github.com/o/r/pull/\($n)", state: $s, isDraft: false, reviewDecision: "", headRefName: $b}'; }
jq -cn --argjson a "$(pr 5 feat/merged MERGED)" --argjson b "$(pr 4 feat/x MERGED)" --argjson c "$(pr 6 feat/kept MERGED)" \
    '{fetched: 1, lanes: {merged: [$b, $a], other: [$b], kept: [$c]}}' >"$D_DIR/prs.json"
check "a lane whose own pull request merged needs the user" "needs" "$(sect merged)"
check "it says so, an unfinished lane never as waiting for cleanup" "PR #5 merged but the lane is unfinished (investigate)" "$(lj merged '.attention | join(" ")')"
check "a merged pull request it only mentions does not count" "working" "$(sect other)"
check "a declined cleanup does not ask again" "working" "$(sect kept)"
check "drift.sh points to cleanup.sh" "DRIFT merged pr-merged: PR #5 merged | cleanup.sh check --repo $D_REPO --lane merged" "$(dg drift --repo "$D_REPO")"
dg lane set --repo "$D_REPO" --lane merged --key cleanup --value ready >/dev/null
dg lane set --repo "$D_REPO" --lane merged --key cleanup --value confirmed >/dev/null
check "a confirmed cleanup says what runs next" "PR #5 merged, cleanup confirmed: cleanup.sh run" "$(lj merged '.attention | join(" ")')"
dg lane close --repo "$D_REPO" --lane merged >/dev/null
check_absent "a closed lane needs nothing" "merged pr-merged" "$(dg drift --repo "$D_REPO")"

echo "== drift: prs.sh records each pull request's branch =="
check "prs.sh asks gh for the head branch" "headRefName" "$(grep -E '^FIELDS=' "$PLUGIN/scripts/prs.sh")"

echo "== drift: no herdr, no drift =="
for l in other kept; do dg lane close --repo "$D_REPO" --lane "$l" >/dev/null; done
check "with nothing out of step drift.sh says so" "NO DRIFT" "$(dg drift --repo "$D_REPO")"
rm -rf "$D_TMP"
unset XDG_CONFIG_HOME
