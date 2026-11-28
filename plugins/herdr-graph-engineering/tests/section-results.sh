#!/usr/bin/env bash
# section-results.sh -- sourced by run-tests.sh; do not run standalone.
# What an agent finished with, read strictly: the hook claim first, then the result file, then a
# screen line that only a real RESULT line matches. Quotes and examples never count, every claim
# says where it came from, a rejected one stays quiet, and a step never finishes a node.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

V_TMP="$(mktemp -d)"
V_REPO="$V_TMP/repo"
git init -q -b main "$V_REPO" && git -C "$V_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
vs() { local s="$1"; shift; (cd "$V_TMP" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$V_TMP" HERDR_ENV=1 NO_COLOR=1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
vst() { printf '%s' "$1" >"$V_TMP/state.json"; : >"$V_TMP/calls.log"; }
V_DIR="$(git -C "$V_REPO" rev-parse --path-format=absolute --git-common-dir)/herdr-graph"
# the parser alone: "kind result ref" of the last real line
vparse() { bash -c '. "$1/scripts/src/result.sh"; screen_claim work "$2" | jq -r "[.kind, .result, .ref] | join(\"|\")"' _ "$PLUGIN" "$1"; }
vlast() { bash -c '. "$1/scripts/src/result.sh"; last_line_claim work "$2" | jq -r "[.kind, .result, .ref] | join(\"|\")"' _ "$PLUGIN" "$1"; }

# shellcheck disable=SC2016  # backticks in the screens are text
{
echo "== results: only a real RESULT line counts on a screen =="
check "A: a quoted example is no result" "none||" "$(vparse '> end with a line like "NODE work RESULT: fail <ref>"')"
check "B: the same in backticks is no result" "none||" "$(vparse 'end with a line like `NODE work RESULT: fail <ref>`')"
check "C: an example in prose is no result" "none||" "$(vparse 'for example: NODE work RESULT: fail build-log.txt')"
check "D: the template is no result" "none||" "$(vparse 'NODE work RESULT: <pass|fail|question> <ref>')"
check "E: screen junk after two spaces is dropped" "result|pass|1a2b3c4" "$(vparse '  NODE work RESULT: pass 1a2b3c4      Jump to bottom (ctrl+End)')"
check "F: a later quote does not beat the real line" "result|pass|abc1234" "$(vparse 'NODE work RESULT: pass abc1234
I was told to write "NODE work RESULT: fail <ref>"
  > NODE work RESULT: fail build-log.txt')"
check "a known bullet before the line is fine" "result|pass|abc1234" "$(vparse '⏺ NODE work RESULT: pass abc1234')"
check "a fail may give its reason in words" "result|fail|could not build" "$(vparse 'NODE work RESULT: fail could not build')"
check "a pass with words after the ref is no result" "none||" "$(vparse 'NODE work RESULT: pass is what I print at the end')"
check "another node's line is no result" "none||" "$(vparse 'NODE other RESULT: pass abc1234')"
check "G: a step after a result is the last word" "step|pass|abc1234" "$(vparse 'NODE work RESULT: pass old1111
NODE work STEP: build pass abc1234')"

echo "== results: a hook reads only the last non-empty line of the final message =="
check "the last line is the result" "result|pass|abc1234" "$(vlast 'Done.

NODE work RESULT: pass abc1234

')"
check "a result followed by more text is none" "none||" "$(vlast 'NODE work RESULT: pass abc1234
Next I will also run the linter.')"
check "the whole line in backticks counts" "result|question|/tmp/q.md" "$(vlast '`NODE work RESULT: question /tmp/q.md`')"


echo "== results: a question counts only while no newer prompt follows it =="
V_BOX='────────────────────────
❯ 
────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)'
check "the question is the newest exchange" "result|question|/tmp/q.md" "$(vparse "⏺ NODE work RESULT: question /tmp/q.md
$V_BOX")"
check "answered by a newer prompt: no question" "none||" "$(vparse "⏺ NODE work RESULT: question /tmp/q.md

❯ Use UTC, the user says.

⏺ Done, the clock is UTC now.
$V_BOX")"
check "the same with a codex prompt" "none||" "$(vparse 'NODE work RESULT: question /tmp/q.md
› Use UTC.
• Done.
› Explain this codebase')"
check "a placeholder or draft in the input box is no newer prompt" "result|question|/tmp/q.md" "$(vparse 'NODE work RESULT: question /tmp/q.md
────────────────────────
❯ Try "fix lint errors"
────────────────────────')"
check "a question asked again after the answer counts" "result|question|/tmp/q2.md" "$(vparse "NODE work RESULT: question /tmp/q.md
❯ Use UTC.
⏺ NODE work RESULT: question /tmp/q2.md
$V_BOX")"
check "a pass is not undone by a later prompt" "result|pass|abc1234" "$(vparse "NODE work RESULT: pass abc1234
❯ thanks
$V_BOX")"

}

echo "== results: claim, then result file, then screen =="
vs lane new --repo "$V_REPO" --lane w --pattern investigate --idea x >/dev/null
out="$(vs lane node --repo "$V_REPO" --lane w --node investigate --status running --agent claude-w --output "$V_TMP/w-out.md")"
run="$(vs lane show --repo "$V_REPO" --lane w --json | jq -r .nodes.investigate.run)"
check "a running node gets a run id, printed" "RUN $run" "$out"
check_absent "the run id is not empty" "null" "$run"
vs lane node --repo "$V_REPO" --lane w --node investigate --status running >/dev/null
check "recording running again keeps the run" "$run" "$(vs lane show --repo "$V_REPO" --lane w --json | jq -r .nodes.investigate.run)"
vagent() { jq -cn --arg s "$1" --arg t "${2:-}" '{agents: {a: {name: "claude-w", pane_id: "w1:p1", agent_status: $s, state_change_seq: 3, screen: $t}}}'; }
vdrift() { vs drift --repo "$V_REPO"; }
vjson() { vs status --json --repo "$V_REPO" | jq -r ".[] | select(.lane == \"w\") | $1"; }
claim() { # json fields
    mkdir -p "$V_DIR/claims/w"; jq -cn --arg r "$run" "{run: \$r, source: \"stop-hook\", at: \"2026-11-26T10:00:00Z\"} + $1" >"$V_DIR/claims/w/investigate.json"; }
vst "$(vagent idle 'NODE investigate RESULT: fail screen-ref')"
check "with nothing else, the screen is read, and says so" "# source: screen" "$(vdrift)"
check "the screen line is kept as evidence" "NODE investigate RESULT: fail screen-ref" "$(jq -r '.agents["claude-w"].line' "$V_DIR/live.json")"
jq -cn --arg r "$run" '{node: "investigate", run: $r, result: "pass", ref: "file-ref", final: true}' >"$V_TMP/w-out.md.result.json"
out="$(vdrift)"
check "a result file beats the screen" "finished pass file-ref" "$out"
check "and says so" "# source: result-file" "$out"
jq -cn '{node: "investigate", run: "old-run", result: "pass", ref: "stale-ref", final: true}' >"$V_TMP/w-out.md.result.json"
check "a result file of an old run is ignored" "finished fail screen-ref" "$(vdrift)"
echo '{broken' >"$V_TMP/w-out.md.result.json"
check "a broken result file is ignored" "finished fail screen-ref" "$(vdrift)"
jq -cn --arg r "$run" '{node: "other", run: $r, result: "pass", ref: "wrong-node", final: true}' >"$V_TMP/w-out.md.result.json"
check "a result file of another node is ignored" "finished fail screen-ref" "$(vdrift)"
claim '{kind: "result", result: "pass", ref: "hook-ref", line: "NODE investigate RESULT: pass hook-ref"}'
vst "$(vagent idle 'NODE investigate RESULT: fail screen-ref')"
out="$(vdrift)"
check "the hook claim beats the file and the screen" "finished pass hook-ref" "$out"
check "and says it came from the stop hook" "# source: stop-hook" "$out"
check_absent "with a claim the screen is not read" "agent read" "$(cat "$V_TMP/calls.log")"
check "status.sh shows a claim without any screen read" "investigate finished: pass hook-ref" "$(vjson '.attention | join(" ")')"
vst "$(vagent working)"
check "a working agent has no finished claim" "working" "$(vjson .section)"
vst '{"agents": {}}'
check "a gone agent that claimed a result shows the result" "finished: pass hook-ref" "$(vjson '.attention | join(" ")')"
claim '{kind: "none"}'
vst "$(vagent idle 'NODE investigate RESULT: pass quoted-ref')"
rm -f "$V_TMP/w-out.md.result.json"
out="$(vdrift)"
check "a turn that ended without a result is stopped, whatever the screen says" "stopped: claude-w" "$out"
check_absent "no result is taken from the screen" "recent-unwrapped" "$(cat "$V_TMP/calls.log")"
claim '{kind: "busy", background: 1}'
check "background work is not finished" "NO DRIFT" "$(vdrift)"
claim '{kind: "question", ref: "Use UTC? [Yes | No]", source: "ask-hook"}'
vst "$(vagent blocked)"
check "the question hook gives the exact question" "claude-w asks: Use UTC? [Yes | No]" "$(vdrift)"
claim '{kind: "permission", ref: "Bash: rm -rf build", source: "permission-hook"}'
check "a permission request names the tool" "blocked: claude-w waits for approval (Bash: rm -rf build)" "$(vdrift)"
claim '{kind: "failure", ref: "rate_limit", source: "stop-failure-hook"}'
vst "$(vagent idle)"
check "a failed turn is reported as a failed agent" "agent-failed: claude-w: rate_limit" "$(vdrift)"
claim '{kind: "result", result: "pass", ref: "x1", run: "old"}'
vst "$(vagent idle 'nothing here')"
check "a claim of an old run is ignored" "stopped: claude-w" "$(vdrift)"

echo "== results: idle with background work is not stopped =="
rm -f "$V_DIR/claims/w/investigate.json" "$V_TMP/w-out.md.result.json"
vkind() { rm -f "$V_DIR/live.json"; vst "$(vagent idle "$2" | jq -c --arg k "$1" '.agents.a.agent = $k')"; vdrift; }
vclaude() { printf '⏺ The build runs in the background.\n\n%s\n\n────────────────────────\n❯ \n────────────────────────\n  %s' "$1" "$2"; }
check "claude: shells still running" "NO DRIFT" "$(vkind claude "$(vclaude '✻ Cooked for 3m 2s · 2 shells still running' '⏵⏵ bypass permissions on')")"
check "claude: one shell in the footer" "NO DRIFT" "$(vkind claude "$(vclaude '✻ Brewed for 9s' '⏵⏵ accept edits on · 1 shell · ↓ to manage')")"
check "claude: a background agent" "NO DRIFT" "$(vkind claude "$(vclaude '✻ Waiting for 1 background agent to finish' '? for shortcuts')")"
check "claude: no background work is stopped" "stopped: claude-w" "$(vkind claude "$(vclaude '✻ Cooked for 3m 2s' '⏵⏵ bypass permissions on')")"
check "claude: words in the transcript do not count" "stopped: claude-w" "$(vkind claude "⏺ I saw 2 shells still running earlier.
a
b
c
d
$(vclaude '✻ Cooked for 3s' '? for shortcuts')")"
check "codex: a background terminal" "NO DRIFT" "$(vkind codex '• Started the server.

  2 background terminals running · /ps to view · /stop to close

› Explain this codebase')"
check "codex: none is stopped" "stopped: claude-w" "$(vkind codex '• Done.

› Explain this codebase')"
claim '{kind: "none"}'
check "a stop hook with nothing left but a running shell on screen is not stopped" "NO DRIFT" "$(vkind claude "$(vclaude '✻ Cooked for 1m · 1 shell still running' '? for shortcuts')")"
check "status.sh agrees" "working" "$(vjson .section)"

echo "== results: a rejected claim stays quiet, a new one says so =="
claim '{kind: "result", result: "pass", ref: "bad-ref"}'
vs lane reject --repo "$V_REPO" --lane w --node investigate --ref bad-ref --text "no commit behind it" >/dev/null
check "the rejection is kept" "no commit behind it" "$(vs lane show --repo "$V_REPO" --lane w --json | jq -r '.nodes.investigate.rejected[0].why')"
check "a rejected claim is not reported again" "NO DRIFT" "$(vdrift)"
claim '{kind: "result", result: "pass", ref: "good-ref"}'
check "a new ref reports, counting the rejected one" "after 1 rejected" "$(vdrift)"

echo "== results: a step never finishes a node =="
claim '{kind: "step", result: "fail", ref: "log.txt", name: "build"}'
out="$(vdrift)"
check "a failed step is reported" "step-fail: claude-w: build fail log.txt" "$out"
check "with the step command" "lane.sh step --repo $V_REPO --lane w --node investigate --name build --result fail" "$out"
vs lane step --repo "$V_REPO" --lane w --node investigate --name build --result pass --ref abc >/dev/null
check "the step is recorded" "build pass abc" "$(vs lane show --repo "$V_REPO" --lane w --json | jq -r '.nodes.investigate.steps[0] | "\(.name) \(.result) \(.ref)"')"
check "the node keeps running" "running" "$(vs lane show --repo "$V_REPO" --lane w --json | jq -r .nodes.investigate.status)"
claim '{kind: "none"}'
check "the recorded step shows in the lane's progress" "step build pass abc" "$(vs status --text --repo "$V_REPO")"

rm -rf "$V_TMP"
unset -f vkind vclaude vs vst vparse vlast vagent vdrift vjson claim
