#!/usr/bin/env bash
# section-guard-board-move-cd.sh -- sourced by run-tests.sh; do not run
# standalone. Contract: the runner already defines set -uo pipefail and has
# sourced _lib.sh (check/check_rc/check_absent/hookjsonpy) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file.
#
# Covers #151: guard-board-move.sh resolved the repo root from the hook's
# AMBIENT cwd and ignored a `cd <path> &&` embedded in the checked command,
# so an orchestrator whose session starts in the main checkout was falsely
# BLOCKED moving a lane's task whose worktree held the valid gate pass.
# The fix honours ONLY a literal cd immediately before the board.sh segment
# and falls back to the ambient root (i.e. blocks) on anything it cannot
# prove; the fingerprint is still compared against the recorded pass.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== guard-board-move.sh: literal leading cd resolves the root (#151) =="

_gbcd_real() { ( cd -P "$1" && pwd -P ); }
GBCD="$(_gbcd_real "$(mktemp -d)")"
GBCD_MAIN="$GBCD/main"
mkdir -p "$GBCD_MAIN"
git -C "$GBCD_MAIN" init -q
git -C "$GBCD_MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$GBCD_MAIN/.claude" "$GBCD_MAIN/.neural-network"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$GBCD_MAIN/.neural-network/project.json"
git -C "$GBCD_MAIN" add .neural-network/project.json
git -C "$GBCD_MAIN" -c user.email=t@t -c user.name=t commit -q -m "add project config"
GBCD_WA="$GBCD/wt-a"; GBCD_WB="$GBCD/wt-b"; GBCD_WC="$GBCD/wt-c"
git -C "$GBCD_MAIN" worktree add -q -b gbcd-a "$GBCD_WA"
git -C "$GBCD_MAIN" worktree add -q -b gbcd-b "$GBCD_WB"
git -C "$GBCD_MAIN" worktree add -q -b gbcd-c "$GBCD_WC"
echo "lane a work" >"$GBCD_WA/a.txt"
echo "lane b work, never gated" >"$GBCD_WB/b.txt"
# WA is the ONLY tree the recorded pass belongs to; WC is a clean sibling.
out="$(cd "$GBCD_WA" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "fixture: gate pass recorded from worktree A" "GATE PASS recorded" "$out"
GBCD_MARKER="$GBCD_MAIN/.claude/gate-pass"
mkdir -p "$GBCD/plain"          # ambient cwd that is no git checkout at all
# Decoys that make the relative-path fallback cases non-vacuous: from ambient
# $GBCD the relative name wt-a is the GATED tree, while a shell that changed
# directory in a way the guard cannot see (CDPATH, eval, source, ...) would
# really land in elsewhere/wt-a, which is ungated.
mkdir -p "$GBCD/elsewhere"
git -C "$GBCD_MAIN" worktree add -q -b gbcd-e "$GBCD/elsewhere/wt-a"
mkdir -p "$GBCD/plain/wt-a"
GBCD_NLIT=0
# literal directories whose NAMES hold characters the guard refuses to expand
# shellcheck disable=SC2016  # literal directory names, not expansions
for _n in 'dollar$X' 'star*' 'brace{a,b}' 'quest?' 'br[a]' 'back`tick' '-dash' '~tilde' $'tab\there'; do
    git -C "$GBCD_MAIN" worktree add -q -b "gbcd-lit-$(printf '%s' "$_n" | tr -dc "[:lower:]")$((++GBCD_NLIT))" "$GBCD/$_n"
done

# gbcd_run <ambient-cwd> <command text> -> output + "rc=N" (stderr kept: it is the evidence)
gbcd_run() { hookjsonpy "$2" | (cd "$1" && env -u SPEC_WORKFLOW_REPO_ROOT bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?"; }
MV='board.sh move 7 "In review"'

# --- control: today's behaviour with no cd is unchanged ---------------------
out="$(gbcd_run "$GBCD_MAIN" "$MV")"
check "control: from main checkout, no cd: blocked (main's tree has no pass)" "rc=2" "$out"
out="$(gbcd_run "$GBCD_WA" "$MV")"
check "control: from worktree A (holds the pass), no cd: allowed" "rc=0" "$out"

# --- the fix: a literal leading cd resolves the root ------------------------
for amb in "$GBCD_MAIN" "$GBCD_WC" "$GBCD/plain"; do
    out="$(gbcd_run "$amb" "cd $GBCD_WA && $MV")"
    check "cd && from ambient $(basename "$amb"): allowed (rc=0)" "rc=0" "$out"
    out="$(gbcd_run "$amb" "cd $GBCD_WA; $MV")"
    check "cd ; from ambient $(basename "$amb"): allowed (rc=0)" "rc=0" "$out"
done
out="$(gbcd_run "$GBCD_MAIN" "cd \"$GBCD_WA\" && $MV")"
check "quoted cd target resolves literally: allowed" "rc=0" "$out"
out="$(gbcd_run "$GBCD_MAIN" "bash -c 'cd $GBCD_WA && $MV'")"
check "bash -c \"cd X && board.sh move\" wrapping: allowed" "rc=0" "$out"
out="$(gbcd_run "$GBCD" "cd wt-a && $MV")"
check "relative cd resolves against the ambient cwd: allowed" "rc=0" "$out"
out="$(gbcd_run "$GBCD_WA/.." "cd wt-a && $MV")"
check "relative cd with a dotdot ambient cwd: allowed" "rc=0" "$out"
mkdir -p "$GBCD_WA/sub"
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WA/sub && $MV")"
check "cd into a SUBDIRECTORY of the worktree resolves to its root: allowed" "rc=0" "$out"

# --- does not widen what passes: fingerprint still compared -----------------
out="$(gbcd_run "$GBCD_WA" "cd $GBCD_WB && $MV")"
check "cd to ungated tree B from the gated tree A: blocked" "rc=2" "$out"
check "cd to tree B: names the tree changed" "tree changed since the last recorded gate pass" "$out"
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WC && $MV")"
check "cd to a CLEAN sibling does not pass with another tree's fingerprint" "rc=2" "$out"
out="$(gbcd_run "$GBCD_MAIN" "bash -c 'cd $GBCD_WB && $MV'")"
check "bash -c cd to mismatching tree: blocked" "rc=2" "$out"

# --- fail closed: anything not provably the segment's cwd falls back --------
gbcd_blocked() { # label, command [, ambient cwd (default main)]: falls back to the AMBIENT tree and is blocked
    local amb="${3:-$GBCD_MAIN}" o
    o="$(gbcd_run "$amb" "$2")"
    check "fallback: $1 (blocked)" "rc=2" "$o"
    check "fallback: $1 (judged for the ambient tree $amb)" "tree $amb)" "$o"
}
gbcd_blocked "cd belongs to an earlier segment (&& echo ;)" "cd $GBCD_WA && echo hi; $MV"
gbcd_blocked "cd then || board.sh" "cd $GBCD_WA || $MV"
gbcd_blocked "cd then unrelated ; then board.sh" "cd $GBCD_WA; echo hi; $MV"
gbcd_blocked "cd only runs if an earlier command succeeds (a && cd; board.sh)" "true && cd $GBCD_WA; $MV"
gbcd_blocked "cd on the left of a pipe" "cd $GBCD_WA | $MV"
gbcd_blocked "cd in a subshell" "(cd $GBCD_WA && echo hi); $MV"
gbcd_blocked "cd to a variable" "cd \$WT && $MV"
gbcd_blocked "cd to a command substitution" "cd \$(echo $GBCD_WA) && $MV"
gbcd_blocked "cd to a backtick substitution" "cd \`echo $GBCD_WA\` && $MV"
gbcd_blocked "cd to a glob" "cd $GBCD/wt-* && $MV"
gbcd_blocked "cd to a brace expansion" "cd $GBCD/{wt-a,wt-b} && $MV"
gbcd_blocked "cd -" "cd - && $MV"
gbcd_blocked "bare cd" "cd && $MV"
gbcd_blocked "cd with a tilde" "cd ~/wt-a && $MV"
gbcd_blocked "cd to a nonexistent path" "cd $GBCD/nope && $MV"
gbcd_blocked "cd to a directory that is no git checkout" "cd $GBCD/plain && $MV"
gbcd_blocked "cd with options" "cd -P $GBCD_WA && $MV"
gbcd_blocked "relative cd after another cd" "cd $GBCD && cd wt-a && $MV"
gbcd_blocked "env prefix between cd and board.sh" "cd $GBCD_WA && FOO=1 $MV"
gbcd_blocked "cd outside bash -c, move inside" "cd $GBCD_WA && bash -c '$MV'"
gbcd_blocked "outer cd then relative cd inside bash -c" "cd $GBCD && bash -c 'cd wt-a && $MV'"
out="$(CDPATH="$GBCD" gbcd_run "$GBCD" "cd wt-a && $MV")"
check "fallback: relative cd with CDPATH set in the hook env (ambient has the pass tree as wt-a)" "rc=2" "$out"
check "fallback: CDPATH case judged for the ambient tree" "tree $GBCD" "$out"
# the last of several cds that IS literal and absolute, directly before board.sh, is honoured
out="$(gbcd_run "$GBCD_MAIN" "cd /nonexistent && cd $GBCD_WA && $MV")"
check "absolute cd directly before board.sh after an unrelated cd: honoured" "rc=0" "$out"

# --- BLOCKED message names the resolved root and the marker path ------------
out="$(gbcd_run "$GBCD_MAIN" "$MV")"
check "no-cd block names the resolved tree root" "$GBCD_MAIN" "$out"
check "no-cd block names the marker path checked" "$GBCD_MARKER" "$out"
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WB && $MV")"
check "cd block names the resolved (cd) tree root" "$GBCD_WB" "$out"
check "cd block names the marker path (primary checkout)" "$GBCD_MARKER" "$out"
rm -f "$GBCD_MARKER"
out="$(gbcd_run "$GBCD_WA" "$MV")"
check "missing-marker block names the tree root" "$GBCD_WA" "$out"
check "missing-marker block names the marker path" "$GBCD_MARKER" "$out"
out="$(cd "$GBCD_WA" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"


# --- #151 review round 1 -----------------------------------------------------
# S1: the real invocation form is `bash <path>/board.sh move ...`
BSH="bash $PLUGIN/scripts/board.sh move 7 \"In review\""
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WA && $BSH")"
check "S1: cd && bash path/board.sh move: allowed" "rc=0" "$out"
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WA; $BSH")"
check "S1: cd ; bash path/board.sh move: allowed" "rc=0" "$out"
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WB && $BSH")"
check "S1: bash path/board.sh into the ungated tree stays blocked" "rc=2" "$out"
check "S1: ... naming that tree" "tree $GBCD_WB" "$out"
gbcd_blocked "S1: bash form behind || " "cd $GBCD_WA || $BSH"

# C1: a newline after an operator is a CONTINUATION, not a separator
NL=$'\n'
gbcd_blocked "newline after || (cd skipped when the left side succeeds)" "true ||${NL}cd $GBCD_WA; $MV"
gbcd_blocked "newline after &&" "false &&${NL}cd $GBCD_WA; $MV"
gbcd_blocked "newline after a pipe" "echo x |${NL}cd $GBCD_WA; $MV"
gbcd_blocked "newline after |&" "echo x |&${NL}cd $GBCD_WA; $MV"
gbcd_blocked "blank lines after ||" "true ||${NL}${NL}cd $GBCD_WA; $MV"
gbcd_blocked "newline after || then &&" "true ||${NL}cd $GBCD_WA && $MV"
gbcd_blocked "cd inside a comment (own line)" "# note; cd $GBCD_WA${NL}$MV"
gbcd_blocked "cd inside a trailing comment" "echo hi # note; cd $GBCD_WA${NL}$MV"
gbcd_blocked "CR after the cd target (bash looks for A<CR>)" "cd $GBCD_WA"$'\r'"${NL}$MV"
gbcd_blocked "CR before ;" "cd $GBCD_WA"$'\r'"; $MV"
gbcd_blocked "cd redefined as a function" "cd() { :; }; cd $GBCD_WA && $MV"
gbcd_blocked "heredoc delimiter that spells the cd" "cat <<cd\\ $GBCD_WA${NL}body${NL}cd $GBCD_WA${NL}$MV"
gbcd_blocked "sentinel character smuggled after the target" "cd $GBCD_WA"$'\001'"; $MV"
# a newline-separated cd (a real separator) IS honoured
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WA${NL}$MV")"
check "newline-separated cd then move: honoured" "rc=0" "$out"

# C2: a relative target after a directory change the guard cannot see
# (ambient $GBCD: wt-a is GATED here, but elsewhere/wt-a -- where the shell
# would really be -- is not)
gbcd_blocked "CDPATH assigned in the command" "CDPATH=elsewhere; cd wt-a && $MV" "$GBCD"
gbcd_blocked "CDPATH exported in the command" "export CDPATH=elsewhere; cd wt-a; $MV" "$GBCD"
gbcd_blocked "eval changed the directory first" "eval 'cd elsewhere'; cd wt-a && $MV" "$GBCD"
printf 'cd elsewhere\n' >"$GBCD/inc.sh"
gbcd_blocked "sourced file changed the directory first" ". ./inc.sh; cd wt-a && $MV" "$GBCD"
gbcd_blocked "cd through a variable first" "x=cd; \$x elsewhere; cd wt-a && $MV" "$GBCD"
gbcd_blocked "eval then relative cd inside bash -c" "eval 'cd elsewhere'; bash -c 'cd wt-a && $MV'" "$GBCD"
gbcd_blocked "relative cd after any other command" "echo hi; cd wt-a && $MV" "$GBCD"
out="$(gbcd_run "$GBCD" "cd wt-a && $MV")"
check "control: relative cd as the first command from \$GBCD is honoured (wt-a is the gated tree)" "rc=0" "$out"
out="$(gbcd_run "$GBCD/plain" "cd wt-a && $MV")"
check "relative cd resolves against the ambient cwd, not another dir's same-named child" "rc=2" "$out"
check "... plain/wt-a is no git checkout, so it falls back to the ambient dir" "tree $GBCD/plain" "$out"
out="$(gbcd_run "$GBCD" "cd elsewhere/wt-a && $MV")"
check "relative cd into the ungated decoy: blocked" "rc=2" "$out"
check "... naming the decoy" "tree $GBCD/elsewhere/wt-a" "$out"

# S4: a tab in the issue number cannot smuggle a cd target
gbcd_blocked "tab-smuggled target in the issue number" "board.sh move \"7"$'\t'"$GBCD_WA\" \"In review\""
gbcd_blocked "newline-smuggled target in the issue number" "board.sh move \"7${NL}$GBCD_WA\" \"In review\""

# T1: names with characters the guard refuses to expand are never honoured,
# even though these directories exist literally (so honouring them would pass
# or at least resolve a different tree than the ambient one)
gbcd_blocked "literal dir with \$ in its name" "cd '$GBCD/dollar\$X' && $MV"
gbcd_blocked "literal dir with * in its name" "cd '$GBCD/star*' && $MV"
gbcd_blocked "literal dir with {} in its name" "cd '$GBCD/brace{a,b}' && $MV"
gbcd_blocked "literal dir with ? in its name" "cd '$GBCD/quest?' && $MV" "$GBCD"
gbcd_blocked "literal dir with [] in its name" "cd '$GBCD/br[a]' && $MV" "$GBCD"
gbcd_blocked "literal dir with a backtick in its name" "cd '$GBCD/back\`tick' && $MV" "$GBCD"
gbcd_blocked "literal dir with a tab in its name" "cd \"$GBCD/tab"$'\t'"here\" && $MV" "$GBCD"
gbcd_blocked "relative target starting with - (an option, not a dir)" "cd -dash && $MV" "$GBCD"
gbcd_blocked "relative target starting with ~ (quoted, literal dir exists)" "cd '~tilde' && $MV" "$GBCD"
gbcd_blocked "a quoted ; is data, not an operator" "cd $GBCD_WA \";\" $MV"
gbcd_blocked "a quoted && is data, not an operator" "cd $GBCD_WA '&&' $MV"
gbcd_blocked "cd after an opening paren and a newline" "(${NL}cd $GBCD_WA; $MV)"
gbcd_blocked "cd after a function definition keyword" "function cd { :; }; cd $GBCD_WA && $MV"
gbcd_blocked "non-numeric issue number never carries a cd" "cd $GBCD_WA && board.sh move abc \"In review\""
gbcd_blocked "cd A & move (background)" "cd $GBCD_WA & $MV"
gbcd_blocked "echo A ; move (a path that is no cd)" "echo $GBCD_WA; $MV"
gbcd_blocked "cd A && (move)" "cd $GBCD_WA && ($MV)"
gbcd_blocked "cd A with a redirection" "cd $GBCD_WA >/dev/null && $MV"
gbcd_blocked "{ cd A; move; }" "{ cd $GBCD_WA; $MV; }"

# several moves in one command, each judged in its own tree, either order
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WA && $MV && cd $GBCD_WB && board.sh move 8 \"In review\"")"
check "two moves, gated tree first then ungated: blocked" "rc=2" "$out"
check "... naming the ungated tree" "tree $GBCD_WB" "$out"
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WB && $MV && cd $GBCD_WA && board.sh move 8 \"In review\"")"
check "two moves, ungated tree first then gated: blocked" "rc=2" "$out"
check "... naming the ungated tree (first)" "tree $GBCD_WB" "$out"
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WA && $MV && cd $GBCD_WA && board.sh move 8 \"In review\"")"
check "two moves, both in the gated tree: allowed" "rc=0" "$out"

# design-registry preflight gets the PRIMARY root of the cd'd tree
GBCD_D="$GBCD/design"; mkdir -p "$GBCD_D"
git -C "$GBCD_D" init -q
git -C "$GBCD_D" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$GBCD_D/.claude" "$GBCD_D/.neural-network" "$GBCD_D/docs/ui-options" "$GBCD_D/plugins/spec-workflow/templates"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$GBCD_D/.neural-network/project.json"
printf ".claude/gate-pass\n.claude/telemetry.jsonl\n.claude/lessons.jsonl\n" >"$GBCD_D/.gitignore"
echo template >"$GBCD_D/plugins/spec-workflow/templates/neural-view.html"
DESIGN_REGISTRY_ROOT="$GBCD_D" python3 "$PLUGIN/scripts/design-registry.py" backfill AST-151 --tags chat --finalized A --issue 11 >/dev/null
( cd "$GBCD_D" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m "design" )
git -C "$GBCD_D" worktree add -q -b gbcd-d "$GBCD/design-wt"
( cd "$GBCD/design-wt" && bash "$PLUGIN/scripts/gate.sh" >/dev/null 2>&1 )
out="$(gbcd_run "$GBCD/plain" "cd $GBCD/design-wt && board.sh move 11 \"In review\"")"
check "design-registry root follows the cd: UNAPPLIED design blocks (from a non-git ambient cwd)" "BLOCKED: issue #11" "$out"
# a design registered ONLY in the primary checkout (uncommitted, so invisible
# from the worktree's own docs/): the cd'd tree's PRIMARY root must be queried
DESIGN_REGISTRY_ROOT="$GBCD_D" python3 "$PLUGIN/scripts/design-registry.py" backfill AST-152 --tags chat --finalized A --issue 13 >/dev/null
out="$(gbcd_run "$GBCD/plain" "cd $GBCD/design-wt && board.sh move 13 \"In review\"")"
check "design-registry root is the PRIMARY root, not the cd'd worktree" "BLOCKED: issue #13" "$out"
out="$(gbcd_run "$GBCD/plain" "cd $GBCD/design-wt && board.sh move 12 \"In review\"")"
check "design-registry root follows the cd: another issue passes" "rc=0" "$out"


# --- #151 review round 2 -----------------------------------------------------
# R1: backslash-newline is DELETED by bash, so the newline after it still
# continues the operator (shlex would turn it into a whitespace token)
BS=$'\\'
gbcd_blocked "|| backslash-newline blank line" "true || ${BS}${NL}${NL}cd $GBCD_WA; $MV"
gbcd_blocked "&& backslash-newline blank line" "false && ${BS}${NL}${NL}cd $GBCD_WA; $MV"
gbcd_blocked "pipe backslash-newline blank line" "echo x | ${BS}${NL}${NL}cd $GBCD_WA; $MV"
gbcd_blocked "|| newline backslash-newline blank line" "true ||${NL}${BS}${NL}${NL}cd $GBCD_WA; $MV"
gbcd_blocked "|| backslash-newline blank line holding a space" "true || ${BS}${NL} ${NL}cd $GBCD_WA; $MV"
# R2: the sentinel character inside a nested bash -c string
SEN=$'\001'
gbcd_blocked "sentinel after the target inside bash -c (;)" "bash -c 'cd $GBCD_WA$SEN; $MV'"
gbcd_blocked "sentinel after the target inside bash -c (&&)" "bash -c 'cd $GBCD_WA$SEN && $MV'"
# R3: a heredoc operator glued to a word hides a fake cd line in its body
gbcd_blocked "heredoc operator glued to a word" "cat<<cd\\ $GBCD_WA${NL}body${NL}cd $GBCD_WA${NL}$MV"
gbcd_blocked "fd-numbered heredoc glued to a word" "cat 3<<cd\\ $GBCD_WA${NL}body${NL}cd $GBCD_WA${NL}$MV"
# T2: a ; inside a double-quoted bash -c string is data for the OUTER scan but a
# real operator for the inner command, which IS honoured
out="$(gbcd_run "$GBCD_MAIN" "bash -c \"cd $GBCD_WA; board.sh move 7 \\\"In review\\\"\"")"
check "bash -c with double quotes: inner cd ; move honoured" "rc=0" "$out"
# T2: an unseen directory change before a doubly nested bash -c
gbcd_blocked "eval then doubly nested bash -c with a relative cd" "eval 'cd elsewhere'; bash -c \"bash -c 'cd wt-a && board.sh move 7 \\\"In review\\\"'\"" "$GBCD"


# --- #151 review (independent), round 1 -------------------------------------
# The sentinel trust check must refuse a cd on its own: these place the byte
# where BAD_TARGET cannot catch it (inside a quoted word / escaped / far from
# the target), so only trust_cd stops them
gbcd_blocked "sentinel + ; inside a quoted word before the cd" "echo '$SEN;' cd $GBCD_WA; $MV"
gbcd_blocked "escaped sentinel-then-; before the cd" "echo x $SEN\; cd $GBCD_WA; $MV"
# backslash-newline is DELETED by bash, not a separator
gbcd_blocked "backslash-newline is no separator before the cd" "echo a ${BS}${NL}cd $GBCD_WA; $MV"
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WA && ${BS}${NL}$MV")"
check "backslash-newline continuing the line after && keeps the cd honoured" "rc=0" "$out"
# zsh forms that run the move in the ambient directory: for/select/repeat
# bodies and function definitions look like plain ; separated commands
gbcd_blocked "empty for list (zsh) before the cd" "for x in; cd $GBCD_WA; $MV"
gbcd_blocked "select loop before the cd" "select x in; cd $GBCD_WA; $MV"
gbcd_blocked "repeat 0 before the cd" "repeat 0; cd $GBCD_WA; $MV"
gbcd_blocked "function definition f() before the cd" "f(); cd $GBCD_WA; $MV"
gbcd_blocked "function definition f() newline before the cd" "f()${NL}cd $GBCD_WA; $MV"
gbcd_blocked "paren group before the cd" "(true); cd $GBCD_WA; $MV"

# --- non-move commands and heredocs are unaffected --------------------------
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WB && board.sh comment 7 hi")"
check "cd + non-move board.sh: allowed" "rc=0" "$out"
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WB && echo hi")"
check "cd without board.sh: allowed" "rc=0" "$out"
out="$(gbcd_run "$GBCD_MAIN" "cd $GBCD_WB && board.sh move 7 \"In progress\"")"
check "cd + move to a non-review status: allowed" "rc=0" "$out"
GBCD_HD=$'cd '"$GBCD_WA"$' && board.sh comment 7 <<\'EOF\'\nI\'ll move it: board.sh move 7 "In review"\nEOF\n'
out="$(gbcd_run "$GBCD_MAIN" "$GBCD_HD")"
check "cd + heredoc comment whose body mentions a move: allowed (#444)" "rc=0" "$out"
GBCD_HD2=$'cd '"$GBCD_WA"$' && board.sh move 7 "In review" <<\'EOF\'\nbody\nEOF\n'
out="$(gbcd_run "$GBCD_MAIN" "$GBCD_HD2")"
check "cd + real move with a trailing heredoc: honoured, allowed" "rc=0" "$out"
GBCD_HD3=$'cat <<\'EOF\'\ncd '"$GBCD_WA"$' && x\nEOF\nboard.sh move 7 "In review"\n'
out="$(gbcd_run "$GBCD_MAIN" "$GBCD_HD3")"
check "a cd inside a heredoc BODY is data, never honoured: blocked" "rc=2" "$out"

# --- serialDelivery (In progress): state resolved from the cd'd tree --------
GBCD_S="$GBCD/serial"; mkdir -p "$GBCD_S"
git -C "$GBCD_S" init -q
git -C "$GBCD_S" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$GBCD_S/.claude" "$GBCD_S/.neural-network"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c.setdefault("methodology",{})["serialDelivery"]=True; c["methodology"]["maxInProgress"]=1; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$GBCD_S/.neural-network/project.json"
git -C "$GBCD_S" add .neural-network/project.json
git -C "$GBCD_S" -c user.email=t@t -c user.name=t commit -q -m cfg
git -C "$GBCD_S" worktree add -q -b gbcd-s "$GBCD/serial-wt"
echo '{"9":{"status":"In progress"}}' >"$GBCD_S/.claude/board-cache.json"
SP='board.sh move 7 "In progress"'
out="$(gbcd_run "$GBCD/serial-wt" "$SP")"
check "serialDelivery from a linked worktree: reads the PRIMARY cache, blocks" "serial delivery" "$out"
out="$(gbcd_run "$GBCD/plain" "cd $GBCD/serial-wt && $SP")"
check "serialDelivery: cd to the worktree from a non-git ambient cwd blocks" "serial delivery" "$out"
out="$(gbcd_run "$GBCD/plain" "$SP")"
check_absent "serialDelivery: no cd from a non-git ambient cwd stays as today (no serial block)" "serial delivery" "$out"

rm -rf "$GBCD"
