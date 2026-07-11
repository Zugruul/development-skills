#!/usr/bin/env bash
# section-snippet-lint.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# Covers #45: scripts/snippet-lint.py generalizes the single f-string regex
# that used to live in section-syntax.sh into two gate-wide floors -- PYTHON
# (3.9, via ast.parse feature_version, plus the inherited f-string regex for
# the one case feature_version provably can't see -- see the script's module
# docstring) and BASH (3.2, mechanical construct checks). Each fixture case
# gets its own scratch "plugin dir" (a scripts/ + tests/ pair) since the
# linter's CLI contract globs <dir>/scripts/*.sh and <dir>/tests/*.sh --
# sharing one tmpdir across cases would let an earlier case's planted file
# leak into a later case's scan.
#
# Fixture bodies live in fixtures/snippet-lint/*.sh, NOT inline here, on
# purpose: this file is itself a tests/*.sh file, and the real-tree check
# below scans tests/*.sh. An earlier draft embedded the bad patterns via
# inline heredocs directly in this file's source and the real-tree check
# then found its OWN fixture text and failed -- the checker recursing into
# its own test fixtures. fixtures/snippet-lint/ is a subdirectory, which the
# linter's flat `tests/*.sh` glob does not descend into, so copying from
# there sidesteps the self-match entirely.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
LINT="$PLUGIN/scripts/snippet-lint.py"
SNIPFIX="$FIX/snippet-lint"

# check_empty <name> <actual-output> -- asserts exactly empty output (the
# lint's clean-tree contract). check/check_absent both do substring
# matching, and an empty needle is a substring of anything, so neither can
# express "no findings at all" -- this is the one assertion this file needs
# that _lib.sh's helpers don't cover.
check_empty() {
    if [[ -z "$2" ]]; then
        echo "ok   $1"
    else
        echo "FAIL $1 — expected empty output, got: $(head -3 <<<"$2")"
        fails=$((fails + 1))
    fi
}

echo "== snippet-lint.py: real tree =="
out="$(python3 "$LINT" "$PLUGIN" 2>&1)"
check_rc "real scripts/*.sh + tests/*.sh are clean (no version-floor findings)" 0 "$?"
check_empty "real-tree scan prints nothing when clean" "$out"

echo "== snippet-lint.py: 3.12-only nested-quote f-string caught (python3 -c, the original #15 pattern) =="
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/nested-fstring-c.sh" "$T/scripts/bad.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "nested-quote f-string: nonzero exit" 1 "$rc"
check "nested-quote f-string: reported" "3.12+-only" "$out"
rm -rf "$T"

echo "== snippet-lint.py: same pattern via a heredoc is also caught =="
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/nested-fstring-heredoc.sh" "$T/tests/bad-heredoc.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "heredoc nested-quote f-string: nonzero exit" 1 "$rc"
check "heredoc nested-quote f-string: reported" "3.12+-only" "$out"
rm -rf "$T"

echo "== snippet-lint.py: a grammar-level 3.10+ construct (match statement) is caught by feature_version =="
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/match-statement.sh" "$T/scripts/bad-match.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "match statement: nonzero exit" 1 "$rc"
check "match statement: reported as python floor violation" "python floor (3.9)" "$out"
rm -rf "$T"

echo "== snippet-lint.py: a clean snippet passes =="
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/clean.sh" "$T/scripts/good.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "clean snippet: exit 0" 0 "$rc"
check_empty "clean snippet: no output" "$out"
rm -rf "$T"

echo "== snippet-lint.py: bash single-quote concatenation idiom ('\"'\"') is not a false positive =="
# Regression for a real finding this task's own red evidence surfaced: naive
# extraction stops at the FIRST raw ' it sees, but bash has no way to escape
# a ' inside a '...'-string -- the standard idiom closes/reopens around a
# double-quoted quote char ('"'"'), e.g. board.sh's `f'"'"'{f["id"]}'"'"'`.
# That's valid, clean python (an f-string with a literal quote delimiter,
# not the nested-quote-in-{}-expression bug) and must not be flagged.
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/quote-idiom.sh" "$T/scripts/quote-idiom.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "quote-concatenation idiom: exit 0 (no false positive)" 0 "$rc"
check_empty "quote-concatenation idiom: no output" "$out"
rm -rf "$T"

echo "== snippet-lint.py: a bash-4+ construct is caught =="
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/bash4-constructs.sh" "$T/scripts/bad-bash4.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
# NOTE: several check labels below quote a bash-4+ construct's name as
# plain text, which is itself a linter trigger substring -- each such line
# carries its own bash4-ok marker so the real-tree self-check above doesn't
# flag THIS file for a check LABEL, not real usage.
check_rc "bash-4+ constructs: nonzero exit" 1 "$rc"
check "declare -A caught" "declare -A" "$out"  # bash4-ok: check-label text, not a real declaration
check "mapfile caught" "mapfile" "$out"  # bash4-ok: check-label text, not a real invocation
check "case-conversion caught" "case conversion" "$out"
check "negative-length substring caught" "negative-length substring" "$out"
check "&>> caught" "&>>" "$out"  # bash4-ok: check-label text, not a real redirect
rm -rf "$T"

echo "== snippet-lint.py: a bash4-ok marker suppresses one line's finding =="
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/bash4-marked.sh" "$T/scripts/marked.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "marked bash-4+ line: exit 0 (suppressed)" 0 "$rc"
check_empty "marked line: no output" "$out"
rm -rf "$T"

echo "== snippet-lint.py: a bash4-ok marker with NO reason text is not honored =="
# Round-1 review finding: an empty '# bash4-ok:' documented nothing and was
# silently treated the same as a justified one. The reason after the colon
# must be non-empty (non-whitespace) or the marker doesn't count.
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/bash4-marked-empty-reason.sh" "$T/scripts/marked-empty.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "empty-reason marker: nonzero exit (not suppressed)" 1 "$rc"
check "empty-reason marker: still reported" "declare -A" "$out"  # bash4-ok: check-label text, not a real declaration
rm -rf "$T"

echo "== snippet-lint.py: double-quoted python3 -c bodies (round-1 review finding) =="
# Round-1 review finding: a double-quoted -c argument (used precisely
# because the body needs bash $var interpolation -- see board.sh/session-
# init.sh/neural-view-template.sh/pagination.sh's real occurrences) was never
# extracted at all -- a version-floor violation inside one was invisible.
# Fixed by extending extraction to double-quote-delimited bodies too,
# neutralizing each interpolation site ($var/${var}/$(...)/`...`) to a
# placeholder before ast.parse (a real bash environment is never required).
#
# NOTE: none of the check labels/comments in this block spell out the
# literal opener text this fixes (python3 SPACE -c SPACE quote-char, or
# python3 ... <<DELIM) -- that exact adjacency is this linter's own
# extraction trigger, and this file is itself a scanned tests/*.sh file (see
# the header comment above for the first time this bit us).
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/dq-match-with-interpolation.sh" "$T/scripts/dq-bad.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "double-quoted -c with a 3.9-floor violation: nonzero exit" 1 "$rc"
check "double-quoted -c with a 3.9-floor violation: reported" "python floor (3.9)" "$out"
rm -rf "$T"

T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/dq-interpolation-clean.sh" "$T/scripts/dq-good.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "double-quoted -c with interpolation, valid python: exit 0" 0 "$rc"
check_empty "double-quoted -c with interpolation, valid python: no output" "$out"
rm -rf "$T"

echo "== snippet-lint.py: a bare, unquoted-delimiter python3 heredoc is scanned =="
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/bare-heredoc-match.sh" "$T/scripts/bare.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "unquoted-delimiter heredoc with a violation: nonzero exit" 1 "$rc"
check "unquoted-delimiter heredoc with a violation: reported" "python floor (3.9)" "$out"
rm -rf "$T"

echo "== snippet-lint.py: a python3 -m MODULE heredoc is scanned =="
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/module-heredoc-match.sh" "$T/scripts/mod.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "-m MODULE heredoc with a violation: nonzero exit" 1 "$rc"
check "-m MODULE heredoc with a violation: reported" "python floor (3.9)" "$out"
rm -rf "$T"

echo "== snippet-lint.py: a <<-'DELIM' dash-heredoc (tab-stripped) is scanned =="
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/dash-heredoc-match.sh" "$T/scripts/dash.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "dash-heredoc (<<-'PY', tab-indented) with a violation: nonzero exit" 1 "$rc"
check "dash-heredoc with a violation: reported" "python floor (3.9)" "$out"
rm -rf "$T"

echo "== snippet-lint.py: an unterminated python3 -c argument is reported UNSCANNED, never silent =="
T="$(mktemp -d)"
mkdir -p "$T/scripts" "$T/tests"
cp "$SNIPFIX/unterminated-dq.sh" "$T/scripts/unterminated.sh"
out="$(python3 "$LINT" "$T" 2>&1)"; rc=$?
check_rc "unterminated -c argument: nonzero exit" 1 "$rc"
check "unterminated -c argument: reported as UNSCANNED, not silently skipped" "UNSCANNED" "$out"
rm -rf "$T"
