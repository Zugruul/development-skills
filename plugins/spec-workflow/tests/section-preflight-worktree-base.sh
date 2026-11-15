#!/usr/bin/env bash
# section-preflight-worktree-base.sh -- sourced by run-tests.sh; do not run standalone.
# Task #581 (rpg SC-048 incident, 2026-11-15):
#   6. the gate pass was ONE marker per main checkout, so a lane that gated green in its
#      worktree was refused when another lane gated after it, or when the hook judged the
#      main checkout (which held another session's uncommitted files) instead of the lane.
#      Now: one marker per worktree, and the hook judges the tree its payload `cwd` names.
#   7. red-first measured `<local main>..HEAD`; a stale local main put main's own commits in
#      the range. Now: commits not reachable from the local OR the freshly fetched
#      origin/<mainBranch>, and a documented override with a recorded reason.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== gate pass per worktree, hook cwd, red-first base (#581) =="

_pwb_real() { ( cd -P "$1" && pwd -P ); }
_pwb_git() { git -c user.email=t@t -c user.name=t "$@"; }
_pwb_config() { # <repo-dir>: tracked project.json, gate "true", mainBranch main
    mkdir -p "$1/.neural-network"
    python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; c["project"]["mainBranch"]="main"; json.dump(c,open(sys.argv[2],"w"))' \
        "$FIX/valid.project.json" "$1/.neural-network/project.json"
}

# ---------------------------------------------------------------- 6. gate pass per worktree
PWB="$(_pwb_real "$(mktemp -d)")"
PM="$PWB/main"
mkdir -p "$PM" && git -C "$PM" init -q -b main
_pwb_config "$PM"
printf '.claude/\n' >"$PM/.gitignore"
git -C "$PM" add -A && _pwb_git -C "$PM" commit -q -m init
git -C "$PM" worktree add -q -b lane-a "$PWB/wt-a"
git -C "$PM" worktree add -q -b lane-b "$PWB/wt-b"
echo "a" >"$PWB/wt-a/a.txt"
echo "b" >"$PWB/wt-b/b.txt"
pwb_gate() { ( cd "$1" && env -u SPEC_WORKFLOW_REPO_ROOT bash "$PLUGIN/scripts/gate.sh" 2>&1 ); }
pwb_pre() { ( cd "$1" && env -u SPEC_WORKFLOW_REPO_ROOT bash "$PLUGIN/scripts/gate-preflight.sh" 2>&1 ); echo "rc=$?"; }

check "6 fixture: lane A gates green" "GATE PASS recorded" "$(pwb_gate "$PWB/wt-a")"
check "6 fixture: lane B gates green after A" "GATE PASS recorded" "$(pwb_gate "$PWB/wt-b")"
check "6a lane A's pass survives lane B's gate (one marker per worktree)" "rc=0" "$(pwb_pre "$PWB/wt-a")"
check "6a lane B's pass is valid too" "rc=0" "$(pwb_pre "$PWB/wt-b")"
n_markers="$(find "$PM/.claude/gate-pass.d" -type f 2>/dev/null | grep -c .)"
check_rc "6b two worktree markers under the main checkout's .claude/gate-pass.d/" 2 "$n_markers"
check_absent "6b a worktree gate does not write the main checkout's own marker" "x" "$([[ -f "$PM/.claude/gate-pass" ]] && echo x)"
out="$(pwb_gate "$PWB/wt-a")"
check "6b the pass line names the worktree's marker" ".claude/gate-pass.d/" "$out"

# the main checkout gates green, then a worktree gates: main's pass must stay valid
# (the worktree marker lands in main's .claude/, which the fingerprint must ignore even
# when .claude/ is not gitignored)
git -C "$PM" rm -q --cached .gitignore && rm -f "$PM/.gitignore" && _pwb_git -C "$PM" commit -q -m "drop ignore"
check "6c fixture: main checkout gates green" "GATE PASS recorded" "$(pwb_gate "$PM")"
pwb_gate "$PWB/wt-b" >/dev/null
check "6c main's pass survives a worktree gate writing into main/.claude/gate-pass.d" "rc=0" "$(pwb_pre "$PM")"
check "6c main checkout still uses .claude/gate-pass" "x" "$([[ -f "$PM/.claude/gate-pass" ]] && echo x)"

# a red gate in lane B clears only lane B's pass
python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["commands"]["gate"]="false"; json.dump(c,open(p,"w"))' "$PWB/wt-b/.neural-network/project.json"
pwb_gate "$PWB/wt-b" >/dev/null
check "6d a red gate in lane B leaves lane A's pass" "rc=0" "$(pwb_pre "$PWB/wt-a")"
check "6d ... and clears lane B's" "rc=2" "$(pwb_pre "$PWB/wt-b")"
git -C "$PWB/wt-b" checkout -q -- .neural-network/project.json

# the hook judges the tree in the payload's cwd, not the process cwd. The main checkout
# holds another session's uncommitted file (the incident shape).
echo "other session's edit" >"$PM/dirty.txt"
pwb_hook() { # <process-cwd> <payload-cwd or ""> <command>
    python3 -c 'import json,sys; d={"tool_input":{"command":sys.argv[1]}}
if sys.argv[2]: d["cwd"]=sys.argv[2]
print(json.dumps(d))' "$3" "$2" \
        | (cd "$1" && env -u SPEC_WORKFLOW_REPO_ROOT bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?"
}
MV='board.sh move 7 "In review"'
check "6e hook: process cwd main, payload cwd lane A (gated): allowed" "rc=0" "$(pwb_hook "$PM" "$PWB/wt-a" "$MV")"
out="$(pwb_hook "$PM" "$PWB/wt-a/" "$MV")"
check "6e hook: payload cwd with a trailing slash: allowed" "rc=0" "$out"
mkdir -p "$PWB/wt-a/sub"
check "6e hook: payload cwd in a subdirectory of lane A: allowed" "rc=0" "$(pwb_hook "$PM" "$PWB/wt-a/sub" "$MV")"
out="$(pwb_hook "$PWB/wt-a" "$PM" "$MV")"
check "6e hook: payload cwd main (dirty, not gated), process cwd lane A: blocked" "rc=2" "$out"
check "6e hook: the block names the tree it judged" "tree $PM" "$out"
check "6e hook: no payload cwd keeps the process cwd (unchanged)" "rc=0" "$(pwb_hook "$PWB/wt-a" "" "$MV")"
check "6e hook: a payload cwd that is not a directory falls back to the process cwd" "rc=0" "$(pwb_hook "$PWB/wt-a" "$PWB/missing" "$MV")"
check "6e hook: a relative payload cwd is ignored" "rc=0" "$(pwb_hook "$PWB/wt-a" "wt-b" "$MV")"
check "6e hook: an explicit cd still wins over the payload cwd" "rc=2" "$(pwb_hook "$PM" "$PWB/wt-a" "cd $PWB/wt-b && $MV")"
rm -rf "$PWB"

# ---------------------------------------------------------------- 7. red-first base
RFB="$(_pwb_real "$(mktemp -d)")"
git init -q --bare -b main "$RFB/origin.git"
git clone -q "$RFB/origin.git" "$RFB/main" 2>/dev/null
_pwb_config "$RFB/main"
git -C "$RFB/main" add -A && _pwb_git -C "$RFB/main" commit -q -m "fixture config" && git -C "$RFB/main" push -q origin main 2>/dev/null
# someone else lands an implementation commit on origin/main; this clone's local main stays behind
git clone -q "$RFB/origin.git" "$RFB/other" 2>/dev/null
echo impl >"$RFB/other/upstream.sh" && git -C "$RFB/other" add -A && _pwb_git -C "$RFB/other" commit -q -m "feat: upstream impl" \
    && git -C "$RFB/other" push -q origin main 2>/dev/null
UP="$(git -C "$RFB/other" rev-parse HEAD)"
git -C "$RFB/main" fetch -q origin
git -C "$RFB/main" worktree add -q -b sc/48-lane "$RFB/lane" origin/main 2>/dev/null
mkdir -p "$RFB/lane/tests" && echo t >"$RFB/lane/tests/t.sh" && git -C "$RFB/lane" add -A && _pwb_git -C "$RFB/lane" commit -q -m "test: red"
echo f >"$RFB/lane/fix.sh" && git -C "$RFB/lane" add -A && _pwb_git -C "$RFB/lane" commit -q -m "fix: green"
RF="$PLUGIN/scripts/red-first-preflight.sh"
rfb() { ( cd "$1" && shift && env -u SPEC_WORKFLOW_REPO_ROOT "$@" bash "$RF" 2>&1 ); echo "rc=$?"; }

out="$(rfb "$RFB/lane")"
check "7a stale local main: the lane passes (base is origin/main, not local main)" "rc=0" "$out"
check_absent "7a the upstream commit is never blamed" "$UP" "$out"
# origin advances again and this clone has not fetched: the check fetches first
echo more >"$RFB/other/upstream2.sh" && git -C "$RFB/other" add -A && _pwb_git -C "$RFB/other" commit -q -m "feat: more upstream" \
    && git -C "$RFB/other" push -q origin main 2>/dev/null
git -C "$RFB/lane" merge -q --no-edit origin/main 2>/dev/null   # nothing new yet (not fetched)
git -C "$RFB/lane" pull -q --no-rebase --no-edit origin main 2>/dev/null  # the lane merges the newest main
git -C "$RFB/main" update-ref refs/remotes/origin/main "$UP"            # this clone's origin/main is stale again
out="$(rfb "$RFB/lane")"
check "7b stale origin/main is fetched before measuring: passes" "rc=0" "$out"
# no remote at all: falls back to the local main branch, as before
git -C "$RFB/main" remote remove origin
out="$(rfb "$RFB/lane")"
check "7c no origin remote: falls back to local main (still measured, no crash)" "rc=" "$out"

# 7d. red proved by reverting the fix: test and code in ONE commit -> blocked, with the override named
git -C "$RFB/main" worktree add -q -b sc/49-one "$RFB/one" main 2>/dev/null
mkdir -p "$RFB/one/tests" && echo t >"$RFB/one/tests/u.sh" && echo f >"$RFB/one/fix2.sh"
git -C "$RFB/one" add -A && _pwb_git -C "$RFB/one" commit -q -m "fix: test and code together"
out="$(rfb "$RFB/one")"
check "7d one combined commit is blocked" "rc=2" "$out"
check "7d the block names the override" "RED_FIRST_OVERRIDE=" "$out"
out="$(rfb "$RFB/one" RED_FIRST_OVERRIDE="x")"
check "7d a too-short reason is not accepted" "rc=2" "$out"
check "7d ... and says why" "at least 20 characters" "$out"
out="$(rfb "$RFB/one" RED_FIRST_OVERRIDE="proved red by reverting fix2.sh: tests/u.sh failed")"
check "7d a real reason is accepted" "rc=0" "$out"
check "7d the override is printed" "red-first overridden" "$out"
check "7d the reason is recorded in telemetry" "proved red by reverting fix2.sh" "$(cat "$RFB/main/.claude/telemetry.jsonl" 2>/dev/null)"
check "7d the record kind" '"kind": "red-first-override"' "$(cat "$RFB/main/.claude/telemetry.jsonl" 2>/dev/null)"
rm -rf "$RFB"

# ---------------------------------------------------------------- docs
IT="$PLUGIN/skills/implement-task/SKILL.md"
check "docs: implement-task names RED_FIRST_OVERRIDE" "RED_FIRST_OVERRIDE" "$(cat "$IT")"
check "docs: implement-task covers proving red by reverting the fix" "reverting the fix" "$(cat "$IT")"
check "docs: gate skill says the pass is per worktree" "per worktree" "$(cat "$PLUGIN/skills/gate/SKILL.md")"
check "docs: spec delta exists" "§" "$(cat "$PLUGIN/../../docs/spec-deltas/581.md" 2>/dev/null)"
