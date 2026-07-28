#!/usr/bin/env bash
# section-guard-board-move-parse.sh -- sourced by run-tests.sh; do not run
# standalone. Contract: the runner already defines set -uo pipefail and has
# sourced _lib.sh (check/check_rc/check_absent/hookjson/hookjsonpy) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# Covers #444: guard-board-move.sh's parser (shlex over the raw command
# string) has no concept of heredoc syntax. A heredoc BODY -- issue-comment
# text posted via the documented `board.sh comment <n> <<DELIM ...`
# pattern, or a file being written that happens to quote this very guard's
# own doc comments -- is DATA, never the command being run, but before the
# #444 fix it was either (a) misread by shlex as more shell tokens (a body
# that happens to contain the literal words board.sh/move/a status name in
# sequence matched the real pattern, a false positive) or (b) broke shlex's
# tokenizing outright (one stray apostrophe in ordinary prose is enough),
# which routed into the fail-closed substring check against the RAW
# (un-stripped) text -- which still contains "board.sh"/"move" whenever the
# BODY merely mentions them. Both are reproduced below exactly as reported
# live (three real hits: repeatedly blocked posting an issue comment, and
# blocked editing this very file), plus regression coverage proving the fix
# does not over-permit: a genuinely ambiguous COMMAND (no heredoc involved)
# still fails closed, and a real move compounded with an unrelated trailing
# heredoc is still caught.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== guard-board-move.sh parser: heredoc/stdin bodies are DATA, not command surface (#444) =="

GBMP_T="$(mktemp -d)"
( cd "$GBMP_T" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$GBMP_T/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$GBMP_T/.claude/project.json"

# Build multi-line command strings containing literal apostrophes/quotes as
# TEST DATA via $'...' ANSI-C quoting (every apostrophe explicitly escaped
# as \' so this file's own bash parsing never sees a raw, unescaped one).

# --- live incident #1: posting an issue comment via the documented
# `board.sh comment <n> <<DELIM ...` pattern, whose BODY mentions moving to
# In review and references board.sh by name, with an apostrophe in the
# prose -- reported: blocked 3x trying to post exactly this. Not a move at
# all (it is a `comment`), must be allowed outright. -----------------------
GBMP_COMMENT_CMD=$'board.sh comment 42 <<\'EOF\'\nThanks for the review, I\'ll go ahead and move this to In review once tests pass. board.sh output looks fine too.\nEOF\n'
out="$(hookjsonpy "$GBMP_COMMENT_CMD" | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "live incident #1: comment body mentioning move/In review/board.sh (with apostrophe) is allowed" "rc=0" "$out"
check_absent "live incident #1: never mis-blocked as unparseable" "BLOCKED" "$out"

# --- live incident #2: editing guard-board-move.sh itself via a heredoc
# whose body quotes the file's own doc comments (board.sh move ..., plus an
# apostrophe in "isn't"). Not board.sh at all (it is `cat > file`), must be
# allowed outright. ---------------------------------------------------------
GBMP_EDIT_CMD=$'cat > guard-board-move.sh <<\'PYEOF\'\n# block board.sh move <n> "In review"\n# this confirms it isn\'t a move to \'In review\'.\nPYEOF\n'
out="$(hookjsonpy "$GBMP_EDIT_CMD" | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "live incident #2: editing the guard file itself (heredoc quotes its own text) is allowed" "rc=0" "$out"
check_absent "live incident #2: never mis-blocked as unparseable" "BLOCKED" "$out"

# =============================================================================
# Round-2 review (REQUEST_CHANGES): the first stripper was a regex over RAW
# text with no notion of quoting, so it could delete REAL command surface --
# not just fail to strip fake ones. The reviewer confirmed four bypasses by
# RUNNING them against the real hook (each BLOCKED with stripping neutered,
# ALLOWED with the regex-based fix) plus a fail-OPEN hole in the fail-closed
# path itself. All five are pinned below against the quote-aware scanner
# that replaced the regex.
# =============================================================================

# --- bypass 1: a FAKE introducer inside a quoted string. `echo "harmless
# <<EOF"` is not a heredoc at all (the `<<EOF` is just characters inside a
# double-quoted argument) -- the regex-based stripper was quote-blind, read
# `<<EOF"` as a real introducer, and swallowed the REAL move on the next
# line as fake "body". Must be recognized as a genuine review-move (no gate
# pass recorded yet in this fixture -> blocked for THAT reason, not
# silently allowed). -------------------------------------------------------
GBMP_BYPASS1=$'echo "harmless <<EOF"\nboard.sh move 5 "In review"\nEOF\n'
out="$(hookjsonpy "$GBMP_BYPASS1" | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "bypass1 (quoted fake introducer): real move recognized, blocked for no-pass" "no recorded gate pass" "$out"
check_absent "bypass1: never silently allowed" "rc=0" "$out"

# --- bypass 2: the same quoted-fake-introducer shape, joined with && on one
# line instead of a newline. A filler body line between the introducer and
# the terminator is REQUIRED here: round-1's regex needed at least one body
# line (`.*?\n`) to match at all, so a 2-line shape with no body in between
# never matched its own (broken) stripper and was already blocked by
# accident -- pinning nothing. With the filler line present, round-1
# genuinely strips (and thereby loses) this real move; round-2 does not. --
GBMP_BYPASS2=$'echo "harmless <<EOF" && board.sh move 5 "In review"\nfiller body line\nEOF\n'
out="$(hookjsonpy "$GBMP_BYPASS2" | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "bypass2 (quoted fake introducer + &&): real move recognized, blocked for no-pass" "no recorded gate pass" "$out"
check_absent "bypass2: never silently allowed" "rc=0" "$out"

# --- bypass 3: the <<- + tab-indented-terminator variant of the same
# quoted-fake-introducer trick. ---------------------------------------------
GBMP_BYPASS3=$'echo "harmless <<-EOF"\nboard.sh move 5 "In review"\n\tEOF\n'
out="$(hookjsonpy "$GBMP_BYPASS3" | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "bypass3 (quoted fake <<- introducer, tab terminator): real move recognized, blocked for no-pass" "no recorded gate pass" "$out"
check_absent "bypass3: never silently allowed" "rc=0" "$out"

# --- bypass 4: arithmetic left-shift, `$((1 << 3))`, misread as a fake
# introducer -- not a redirection at all. A trailing terminator line
# ("3", matching round-1's \w+ delimiter capture off the "3" in "<< 3))")
# is REQUIRED here: without one anywhere in the text, round-1's regex never
# found a matching terminator and never matched at all, so this shape was
# already blocked by accident (nothing stripped) -- pinning nothing. With
# the "3" line present, round-1 genuinely strips the real move as fake
# body; round-2 does not (delimiters must be quoted, and 3 is not). -------
GBMP_BYPASS4=$'echo $((1 << 3))\nboard.sh move 5 "In review"\n3\n'
out="$(hookjsonpy "$GBMP_BYPASS4" | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "bypass4 (arithmetic << as fake introducer): real move recognized, blocked for no-pass" "no recorded gate pass" "$out"
check_absent "bypass4: never silently allowed" "rc=0" "$out"

# --- fail-closed erosion: a heredoc-SHAPED but UNQUOTED-delimiter wrapper
# around a genuinely truncated/unbalanced fragment. `foo <<Z` (Z unquoted)
# must NOT be recognized as a real introducer -- shlex still raises on the
# raw text's genuinely unbalanced quote, and the existing substring
# fail-closed check must still fire, exactly as if the `foo <<Z`/`Z`
# wrapper were not there at all. This is the fail-OPEN hole: the previous
# fix's commit message claimed "genuinely ambiguous commands still fail
# closed" as an unqualified guarantee, but this exact shape slipped through
# once the substring check ran on stripped text that had lost the
# ambiguous words along with the (falsely trusted) "heredoc". -------------
GBMP_EROSION=$'foo <<Z\nboard.sh move 5 "In review\nZ\n'
out="$(hookjsonpy "$GBMP_EROSION" | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "fail-closed erosion (foo <<Z, unquoted): still fails closed" "BLOCKED: could not safely parse" "$out"
check "fail-closed erosion: exit code 2" "rc=2" "$out"

# --- LOW-priority fixes (safe under-strip direction) pinned too: an empty
# heredoc body (terminator on the very next line), and a hyphenated
# delimiter (bash allows non-word characters like "-" in a quoted
# delimiter; the old regex's \w+ did not). -----------------------------
GBMP_EMPTY_BODY=$'cat <<\'EOF\'\nEOF\n'
out="$(hookjsonpy "$GBMP_EMPTY_BODY" | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "empty heredoc body: allowed, no crash" "rc=0" "$out"

GBMP_HYPHEN_DELIM=$'cat <<\'EOF-1\'\nsome content\nEOF-1\n'
out="$(hookjsonpy "$GBMP_HYPHEN_DELIM" | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "hyphenated delimiter (EOF-1): allowed" "rc=0" "$out"

# --- primary-path false positive (distinct failure mode from #1/#2 above):
# a heredoc BODY with NO apostrophe at all -- so shlex tokenizes the WHOLE
# raw text "successfully" -- that itself contains a literal
# `board.sh move 9 "In review"`-shaped line. Before the fix this was
# genuinely (mis)matched as a real review-move and routed into
# gate-preflight -- observably wrong since the actual command is `cat > a
# file`, nothing to do with board.sh. --------------------------------------
GBMP_BODY_MATCH_CMD=$'cat > somefile.txt <<\'EOF\'\nboard.sh move 9 "In review"\nEOF\n'
out="$(hookjsonpy "$GBMP_BODY_MATCH_CMD" | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "heredoc body containing a literal board.sh-move-shaped line is allowed (not a real move)" "rc=0" "$out"

# --- regression: a REAL move to In review, compounded with an unrelated
# trailing heredoc'd command, must still be caught (no gate pass ->
# blocked) -- the fix must not blind the guard to genuine review-moves that
# merely happen to share a command line with a heredoc. --------------------
GBMP_REAL_PLUS_HEREDOC=$'board.sh move 7 "In review" && cat <<\'EOF\'\nnoise\nEOF\n'
out="$(hookjsonpy "$GBMP_REAL_PLUS_HEREDOC" | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "real move compounded with a trailing heredoc is still caught" "rc=2" "$out"
check "real move compounded with a trailing heredoc: correct (no-pass) reason, not a parse failure" "no recorded gate pass" "$out"
check_absent "real move compounded with a trailing heredoc: not misreported as unparseable" "could not safely parse" "$out"

# --- regression: a genuinely ambiguous COMMAND -- no heredoc anywhere, a
# real truncated/unbalanced quote on the command surface itself -- must
# still fail closed exactly as before. This is the "genuinely ambiguous
# COMMAND" case the fix must NOT weaken. ------------------------------------
out="$(hookjson 'bash board.sh move 7 \"In review' | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "genuinely unbalanced command (no heredoc) still fails closed" "BLOCKED: could not safely parse" "$out"
check "genuinely unbalanced command (no heredoc) exit code" "rc=2" "$out"

# --- regression: a real move via the ordinary (non-heredoc) pattern, with
# a recorded gate pass present, is still allowed -- proving the
# heredoc-stripping does not disturb the ordinary green-path outcome. ------
out="$(cd "$GBMP_T" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "fixture: gate pass recorded" "GATE PASS recorded" "$out"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$GBMP_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "real move allowed with a fresh recorded pass (ordinary green path unaffected)" "rc=0" "$out"

rm -rf "$GBMP_T"
