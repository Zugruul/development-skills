#!/usr/bin/env bash
# section-brief-preflight.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced _lib.sh
# (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky.
# Covers #573: brief-preflight.sh (a dev or reviewer brief must carry a
# `## TODO UPKEEP` section naming a task id) and guard-brief-preflight.sh, the
# PreToolUse(Agent|Task) hook that runs it for dev-* / reviewer-* spawns.
# shellcheck disable=SC2016  # the single-quoted expectations are literal source text

declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brief-preflight (#573) =="

BP="$PLUGIN/scripts/brief-preflight.sh"
BG="$PLUGIN/scripts/guard-brief-preflight.sh"
BP_TMP="$(mktemp -d)"
mkdir -p "$BP_TMP/with/.neural-network" "$BP_TMP/without" "$BP_TMP/stubs"
cp "$FIX/valid.project.yaml" "$BP_TMP/with/.neural-network/project.yaml"
printf '#!/bin/sh\necho called >> "%s/gh-called"\nexit 1\n' "$BP_TMP" > "$BP_TMP/stubs/gh"
chmod +x "$BP_TMP/stubs/gh"

GOOD_BRIEF='## WHAT
Do the thing.

## TODO UPKEEP (required)
Task id 573; your role is dev. The human watches this record live.
- Completion: tick a TODO.

## DELIVERABLE
Report.'
NOID_BRIEF='## WHAT
Do the thing.

## TODO UPKEEP (required)
Keep the record current, it is watched live.

## DELIVERABLE
Task id 573 is mentioned only here, outside the section.'
NOSEC_BRIEF='## WHAT
Do the thing.

## DELIVERABLE
Report.'

# --- script: pass / fail ---
out="$(printf '%s\n' "$GOOD_BRIEF" | bash "$BP" dev-573 2>&1; echo "rc=$?")"
check "(a) dev brief with TODO UPKEEP + task id: passes" "rc=0" "$out"
out="$(printf '%s\n' "$GOOD_BRIEF" | bash "$BP" --agent reviewer-573-spec 2>&1; echo "rc=$?")"
check "(a2) reviewer brief with the section: passes (--agent form)" "rc=0" "$out"
out="$(printf '## TODO UPKEEP (required)\nTask id N; your role is <role>.\n' | bash "$BP" dev-x 2>&1; echo "rc=$?")"
check "(a3) template text 'Task id N' passes" "rc=0" "$out"

out="$(printf '%s\n' "$NOSEC_BRIEF" | bash "$BP" dev-573 2>&1; echo "rc=$?")"
check "(b) dev brief without the section: exit 1" "rc=1" "$out"
check "(b) message names the missing section" "TODO UPKEEP" "$out"
out="$(printf '%s\n' "$NOSEC_BRIEF" | bash "$BP" dev-573 2>&1 >/dev/null | wc -l | tr -d ' ')"
check "(b) message is one line" "1" "$out"
out="$(printf '%s\n' "$NOSEC_BRIEF" | bash "$BP" Reviewer-573 2>&1; echo "rc=$?")"
check "(b2) reviewer brief without the section (name case-insensitive): exit 1" "rc=1" "$out"

out="$(printf '%s\n' "$NOID_BRIEF" | bash "$BP" dev-573 2>&1; echo "rc=$?")"
check "(c) section without a task id: exit 1" "rc=1" "$out"
check "(c) message names the missing task id" "task id" "$out"

out="$(printf '%s\n' "$NOSEC_BRIEF" | bash "$BP" main 2>&1; echo "rc=$?")"
check "(d) non dev/reviewer agent is not checked" "rc=0" "$out"
out="$(printf '%s\n' "$NOSEC_BRIEF" | bash "$BP" developer-9 2>&1; echo "rc=$?")"
check "(d2) 'developer-9' is not a dev-* name" "rc=0" "$out"

# --- round 1: id spellings, heading, fences, pr-reviewer ---
sec() { printf '## TODO UPKEEP (required)\n%s\n\n## DELIVERABLE\nx\n' "$1"; }
for spelling in 'Task ID #573; your role is dev.' 'Task id: 5' 'Task  id 5' 'task id 573-b'; do
    out="$(sec "$spelling" | bash "$BP" dev-573 2>&1; echo "rc=$?")"
    check "(r1) id spelling passes: $spelling" "rc=0" "$out"
done
out="$(sec 'The subtask id x is all we say here' | bash "$BP" dev-573 2>&1; echo "rc=$?")"
check "(r1) 'subtask id x' does not count as naming a task id" "rc=1" "$out"
out="$(printf '## TODO UPKEEPING\nTask id 5\n' | bash "$BP" dev-573 2>&1; echo "rc=$?")"
check "(r1) '## TODO UPKEEPING' is not the section" "rc=1" "$out"
out="$(printf '## TODO UPKEEP\nTask id 5\n' | bash "$BP" dev-573 2>&1; echo "rc=$?")"
check "(r1) heading at end of line counts" "rc=0" "$out"
out="$(printf 'Example:\n```\n## TODO UPKEEP (required)\nTask id 5; your role is dev.\n```\n## DELIVERABLE\nx\n' | bash "$BP" dev-573 2>&1; echo "rc=$?")"
check "(r1) a fenced TODO UPKEEP section does not count" "rc=1" "$out"
out="$(printf 'Example:\n~~~\n## TODO UPKEEP (required)\nTask id 5\n~~~\n' | bash "$BP" dev-573 2>&1; echo "rc=$?")"
check "(r1) a tilde-fenced section does not count" "rc=1" "$out"
out="$(printf '## TODO UPKEEP (required)\n```\n## not a heading\ntask-state.sh show --id N\n```\nTask id 5; your role is dev.\n' | bash "$BP" dev-573 2>&1; echo "rc=$?")"
check "(r1) real section with a fenced example, id after the fence, passes" "rc=0" "$out"
out="$(printf '%s\n' "$NOSEC_BRIEF" | bash "$BP" pr-reviewer-pr5 2>&1; echo "rc=$?")"
check "(r1) pr-reviewer-* brief without the section: exit 1" "rc=1" "$out"

# --- hook ---
hook_json() { # name-key name prompt description
    python3 -c 'import json,sys
ti={"prompt":sys.argv[3],"description":sys.argv[2],"subagent_type":"general-purpose"}
if sys.argv[1]: ti["name"]=sys.argv[1]
print(json.dumps({"tool_name":"Agent","tool_input":ti}))' "$1" "$2" "$3"
}
hook() { (cd "$BP_TMP/$1" && SPEC_WORKFLOW_REPO_ROOT="$BP_TMP/$1" PATH="$BP_TMP/stubs:$PATH" bash "$BG" 2>&1; echo "rc=$?"); }

out="$(hook_json '' 'dev-573 implement the thing' "$NOSEC_BRIEF" | hook with)"
check "(e) hook blocks a dev spawn without the section (rc 0 + deny JSON)" '"permissionDecision": "deny"' "$out"
check "(e) deny reason names the section" "TODO UPKEEP" "$out"
check_absent "(e) hook never crashes" "Traceback" "$out"
out="$(hook_json 'reviewer-573-spec' 'review it' "$NOID_BRIEF" | hook with)"
check "(e2) name from tool_input.name wins; blocks reviewer without task id" "task id" "$out"
out="$(hook_json 'dev-573' 'unrelated words' "$GOOD_BRIEF" | hook with)"
check_absent "(f) dev spawn with the section is allowed" "deny" "$out"
check "(f) allowed with rc 0" "rc=0" "$out"
out="$(hook_json '' 'explore the tree' "$NOSEC_BRIEF" | hook with)"
check_absent "(g) non dev/reviewer spawn is not checked" "deny" "$out"
out="$(hook_json '' 'dev-573 implement the thing' "$NOSEC_BRIEF" | hook without)"
check_absent "(h) outside a spec-workflow repo the hook allows" "deny" "$out"
out="$(printf 'not json{' | hook with)"
check "(i) malformed JSON allows" "rc=0" "$out"
check_absent "(i) malformed JSON does not deny" "deny" "$out"
out="$(printf '{"tool_input":"x"}' | hook with)"
check "(i2) odd tool_input shape allows" "rc=0" "$out"
check_absent "(i2) odd shape does not crash" "Traceback" "$out"
out="$(hook_json '' 'pr-reviewer-pr5 review the PR' "$NOSEC_BRIEF" | hook with)"
check "(r1) hook blocks a pr-reviewer-* spawn without the section" '"permissionDecision": "deny"' "$out"
out="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"TaskCreate","tool_input":{"name":"dev-573","prompt":sys.argv[1]}}))' "$NOSEC_BRIEF" | hook with)"
check_absent "(r1) hook ignores tool_name other than Agent/Task" "deny" "$out"
out="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Task","tool_input":{"name":"dev-573","prompt":sys.argv[1]}}))' "$NOSEC_BRIEF" | hook with)"
check "(r1) hook still checks tool_name Task" '"permissionDecision": "deny"' "$out"

if [[ -f "$BP_TMP/gh-called" ]]; then
    echo "FAIL (j) hook and script made no gh/network call"; fails=$((fails + 1))
else
    echo "ok   (j) hook and script made no gh/network call"
fi
check_absent "(j) scripts do not reference gh/curl" "curl" "$(cat "$BP" "$BG" 2>&1)"

# --- hooks.json ---
HJ="$(cat "$PLUGIN/hooks/hooks.json")"
check "(k) hooks.json has an Agent|Task PreToolUse matcher" '"matcher": "Agent|Task"' "$HJ"
check "(k) hooks.json runs guard-brief-preflight.sh" 'guard-brief-preflight.sh' "$HJ"

# --- docs pins ---
IT="$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
CC="$(cat "$PLUGIN/skills/build-next/references/concurrency.md")"
AR="$(cat "$PLUGIN/skills/build-next/references/auto-review.md")"
RD="$(cat "$PLUGIN/README.md")"
check "(l) implement-task: hook blocks the spawn" "blocks a dev-* or reviewer-* spawn whose brief lacks the TODO UPKEEP section" "$IT"
check "(l) implement-task: how the name is read" "first word of the Agent description" "$IT"
check "(l) implement-task: Codex runs the script by hand" "Codex users run \`brief-preflight.sh\` by hand before delegating" "$IT"
check "(l) concurrency: hook blocks the spawn" "blocks a dev-* or reviewer-* spawn whose brief lacks the TODO UPKEEP section" "$CC"
check "(l) concurrency: Codex runs the script by hand" "Codex users run \`brief-preflight.sh\` by hand before delegating" "$CC"
check "(l) auto-review: names brief-preflight.sh" "brief-preflight.sh" "$AR"
check "(m) README lists brief-preflight.sh" "\`brief-preflight.sh\`" "$RD"
check "(m) README lists guard-brief-preflight.sh" "\`guard-brief-preflight.sh\`" "$RD"
DL="$(delta_body 573)"
check "(n) delta exists for 573" "task: 573" "$DL"
check "(n) delta names the script" "brief-preflight.sh" "$DL"
check "(n) delta carries the Codex parity note" "Codex" "$DL"

check "(r1) implement-task: pr-reviewer named" "pr-reviewer-*" "$IT"
check "(r1) auto-review: pr-reviewer named" "pr-reviewer-*" "$AR"
check "(r1) README: pr-reviewer named" "pr-reviewer-*" "$RD"
check "(r1) delta: pr-reviewer in the name pattern" "pr-reviewer" "$DL"
check "(r1) delta: id grammar allows ':' and '#'" "optional \`:\` or \`#\`" "$DL"
_after() { python3 -c 'import sys; s=open(sys.argv[1]).read(); a=s.index(sys.argv[2]); b=s.index(sys.argv[3]); print("ok" if b>a else "bad")' "$@"; }
check "(r1) implement-task: preflight note follows the template" "ok" "$(_after "$PLUGIN/skills/implement-task/SKILL.md" '- Always pass `--agent <role>` and task id N.
```' '**Brief preflight (#573).**' 2>&1 | tail -1)"
check "(r1) README: preflight paragraph is not wedged before the JSON block it follows" "ok" "$(_after "$PLUGIN/README.md" '`brief-preflight.sh` (#573) checks' '`guard-board-move.sh` and `guard-brain-access.sh` ship' 2>&1 | tail -1)"

rm -rf "$BP_TMP"
