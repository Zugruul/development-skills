#!/usr/bin/env bash
# section-guard-pr-create.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# Covers issue #76 (board-reflects enforcement, PR-creation side):
# guard-pr-create.sh, a PreToolUse(Bash) hook blocking `gh pr create` unless
# the PR body references a board issue ("Closes #N"/"Fixes #N" or
# "<slug>#N"), and warning (non-blocking) when the current branch doesn't
# match project.branchPattern. Same parsing discipline as guard-board-move.sh
# (SW-011): parse the real argv of a `gh pr create` invocation, never
# substring-match the whole command line.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== guard-pr-create.sh (#76) =="

GT="$(mktemp -d)"
( cd "$GT" && git init -q . && git commit -q --allow-empty -m init && git branch -m fx/76-board-enforcement )
mkdir -p "$GT/.claude"
cp "$FIX/valid.project.yaml" "$GT/.claude/project.yaml"

hookjson_pr() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"; }
guard() { (cd "$GT" && bash "$PLUGIN/scripts/guard-pr-create.sh" 2>&1); }

# --- (a) PR body with a closing-keyword reference passes ---
out="$(hookjson_pr 'gh pr create --title "add thing" --body "Closes #76"' | guard; echo "rc=$?")"
check "(a) body with Closes #N: allowed" "rc=0" "$out"
check_absent "(a) body with Closes #N: no BLOCKED text" "BLOCKED" "$out"

# --- (a2) PR body with a qualified <slug>#N reference (no closing verb) passes ---
out="$(hookjson_pr 'gh pr create --title "add thing" --body "development-skills#76 lands the enforcement guard"' | guard; echo "rc=$?")"
check "(a2) body with qualified slug#N: allowed" "rc=0" "$out"

# --- (b) PR body without any board-issue reference blocks ---
out="$(hookjson_pr 'gh pr create --title "add thing" --body "just a change, no ticket"' | guard; echo "rc=$?")"
check "(b) body without a reference: blocked" "rc=2" "$out"
check "(b) block message: names the missing reference" "does not reference a board issue" "$out"

# --- (c) embedded '#N' in a non-body argument (title) must not false-positive-allow ---
BODYFILE="$GT/pr-body.txt"
printf 'no ref here, just prose' > "$BODYFILE"
out="$(hookjson_pr "gh pr create --title \"notes #76 for later\" --body-file \"$BODYFILE\"" | guard; echo "rc=$?")"
check "(c) '#76' in --title does not satisfy the body-reference check" "rc=2" "$out"
check "(c) block message still complains about the body" "does not reference a board issue" "$out"
rm -f "$BODYFILE"

# --- (c2) --body-file pointing at a real file WITH a reference is read and passes ---
BODYFILE2="$GT/pr-body-ok.txt"
printf 'Fixes #76\n\nDetails...' > "$BODYFILE2"
out="$(hookjson_pr "gh pr create --title \"add thing\" --body-file \"$BODYFILE2\"" | guard; echo "rc=$?")"
check "(c2) --body-file with a reference: allowed" "rc=0" "$out"
rm -f "$BODYFILE2"

# --- (d) --body-file - (stdin) cannot be inspected: fails closed ---
out="$(hookjson_pr 'gh pr create --title "add thing" --body-file -' | guard; echo "rc=$?")"
check "(d) --body-file - (stdin): blocked" "rc=2" "$out"
check "(d) block message: names the stdin problem" "cannot inspect" "$out"

# --- (e) neither --body nor --body-file given: fails closed ---
out="$(hookjson_pr 'gh pr create --title "add thing" --fill' | guard; echo "rc=$?")"
check "(e) no body flag at all: blocked" "rc=2" "$out"
check "(e) block message: no --body/--body-file" "no --body/--body-file" "$out"

# --- (f) unparseable gh pr create invocation fails closed ---
out="$(hookjson_pr 'gh pr create --body "Closes #76' | guard; echo "rc=$?")"
check "(f) unparseable invocation: blocked" "rc=2" "$out"
check "(f) block message: names the parse problem" "could not safely parse" "$out"

# --- (g) non-'gh pr create' commands pass through untouched ---
out="$(hookjson_pr 'git status' | guard; echo "rc=$?")"
check "(g) unrelated command: allowed" "rc=0" "$out"
check_absent "(g) unrelated command: no output at all" "BLOCKED" "$out"

# --- (h) branch-pattern warning (non-blocking) when the branch doesn't match project.branchPattern ---
( cd "$GT" && git checkout -q -b some-random-branch )
out="$(hookjson_pr 'gh pr create --title "add thing" --body "Closes #76"' | guard; echo "rc=$?")"
check "(h) mismatched branch: still allowed (warn, not block)" "rc=0" "$out"
check "(h) mismatched branch: warns about project.branchPattern" "does not match project.branchPattern" "$out"
( cd "$GT" && git checkout -q fx/76-board-enforcement )

# --- (i) matching branch: no warning ---
out="$(hookjson_pr 'gh pr create --title "add thing" --body "Closes #76"' | guard; echo "rc=$?")"
check "(i) matching branch: allowed" "rc=0" "$out"
check_absent "(i) matching branch: no spurious warning" "does not match project.branchPattern" "$out"

# --- (j) bash -c wrapped invocation still parsed (SW-011 discipline) ---
BASHC_PR='bash -c '\''gh pr create --title "x" --body "no ref here"'\'''
out="$(hookjson_pr "$BASHC_PR" | guard; echo "rc=$?")"
check "(j) bash -c wrapped, no ref: still blocked" "rc=2" "$out"

# --- (k) review round 1, BLOCKING: heredoc BODY text containing "gh pr create" is
# being WRITTEN (to a file, via cat), not RUN -- must not be mistaken for a real
# invocation (SW-011's exact false-positive class: text sitting inside something
# else gets substring/position-matched as if it were a live command). ---
HEREDOC_CMD='cat > notes.txt <<EOF
gh pr create --body test
EOF'
out="$(hookjson_pr "$HEREDOC_CMD" | guard; echo "rc=$?")"
check "(k) heredoc body mentioning gh pr create: NOT treated as a real invocation" "rc=0" "$out"
check_absent "(k) heredoc body: no BLOCKED text" "BLOCKED" "$out"

# --- (k2) a REAL gh pr create after && (a genuine command-start position,
# following a compound-command operator) must still be caught ---
out="$(hookjson_pr 'git add . && gh pr create --title "x" --body "no ref here"' | guard; echo "rc=$?")"
check "(k2) real invocation after &&, no ref: still blocked" "rc=2" "$out"
out="$(hookjson_pr 'git add . && gh pr create --title "x" --body "Closes #76"' | guard; echo "rc=$?")"
check "(k2) real invocation after &&, with ref: allowed" "rc=0" "$out"

# --- (k3) env-prefixed real invocation is still recognized (not just skipped
# because it isn't at token position 0) ---
out="$(hookjson_pr 'env GH_TOKEN=x gh pr create --title "x" --body "no ref here"' | guard; echo "rc=$?")"
check "(k3) env-prefixed invocation, no ref: still blocked" "rc=2" "$out"

# --- (l) review round 1, BLOCKING: --body-file must resolve against the hook's
# ACTUAL cwd, not unconditionally against the repo root ---
guard_at() { (cd "$1" && bash "$PLUGIN/scripts/guard-pr-create.sh" 2>&1); }
mkdir -p "$GT/sub"
printf 'no ref at all' > "$GT/relbody.txt"
printf 'Closes #76' > "$GT/sub/relbody.txt"
out="$(hookjson_pr 'gh pr create --title "x" --body-file relbody.txt' | guard_at "$GT/sub"; echo "rc=$?")"
check "(l) --body-file resolved against the hook's cwd (subdir), not repo root: allowed" "rc=0" "$out"

# --- (l2) a leading 'cd' within the SAME command string is tracked, so a
# relative --body-file after it resolves against the post-cd directory ---
out="$(hookjson_pr 'cd sub && gh pr create --title "x" --body-file relbody.txt' | guard_at "$GT"; echo "rc=$?")"
check "(l2) leading 'cd sub &&' tracked: --body-file resolves inside sub, not repo root" "rc=0" "$out"
rm -f "$GT/relbody.txt" "$GT/sub/relbody.txt"
rmdir "$GT/sub"

# --- (m) review round 3, BLOCKING: a heredoc body containing a compound-command
# SEPARATOR ("&&") inside the written TEXT must not flip command-start tracking
# back on -- shlex flattens the heredoc body into the same token stream, so the
# literal "&&" mid-text is indistinguishable from a real operator to a
# position-only tracker. The heredoc's body range (through its matching,
# word-for-word terminator) must be excluded from the scan entirely. ---
HEREDOC_SEP_CMD='cat > notes.txt <<EOF
setup && gh pr create --body test
EOF'
out="$(hookjson_pr "$HEREDOC_SEP_CMD" | guard; echo "rc=$?")"
check "(m) heredoc body containing '&&' before gh pr create text: NOT a real invocation" "rc=0" "$out"
check_absent "(m) heredoc body with embedded separator: no BLOCKED text" "BLOCKED" "$out"

# --- (m2) <<- heredoc (tab-stripped terminator) is also excluded ---
HEREDOC_DASH_CMD='cat > notes.txt <<-EOF
	gh pr create --body test
	EOF'
out="$(hookjson_pr "$HEREDOC_DASH_CMD" | guard; echo "rc=$?")"
check "(m2) <<- heredoc body: NOT a real invocation" "rc=0" "$out"

# --- (m3) quoted-delimiter heredoc ( <<'EOF' ) is also excluded ---
HEREDOC_QUOTED_CMD='cat > notes.txt <<'\''EOF'\''
gh pr create --body test
EOF'
out="$(hookjson_pr "$HEREDOC_QUOTED_CMD" | guard; echo "rc=$?")"
check "(m3) quoted-delimiter heredoc body: NOT a real invocation" "rc=0" "$out"

rm -rf "$GT"
