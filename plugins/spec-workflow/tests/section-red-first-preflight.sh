#!/usr/bin/env bash
# section-red-first-preflight.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# #235 (CDX-031 gap #3): red-first-preflight.sh is a STRUCTURAL heuristic --
# it inspects commit ORDERING on a branch, not whether tests actually failed
# when run (no test execution happens). These fixtures build real git
# history (a local repo, main + a feature branch) and exercise the actual
# script, not a mock -- see docs/design/cdx-E3.md's "Follow-up: #235".
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== red-first TDD preflight (#235, CDX-031 gap #3: commit-ordering heuristic) =="

# _rf_repo <dir> -- inits a repo at <dir> with a "main" branch (one empty
# init commit), local git identity, and a valid fixture project.json
# (mainBranch already "main"), then checks out a "feature" branch off it.
# All subsequent commits in a case are made on "feature".
_rf_repo() {
    local dir="$1"
    mkdir -p "$dir"
    ( cd "$dir" && git init -q -b main . )
    git -C "$dir" config user.name "Fixture Human"
    git -C "$dir" config user.email "fixture@example.com"
    ( cd "$dir" && git commit -q --allow-empty -m init )
    mkdir -p "$dir/.claude"
    python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
        "$FIX/valid.project.json" "$dir/.claude/project.json"
    ( cd "$dir" && git add -A && git commit -q -m "fixture config" )
    ( cd "$dir" && git checkout -q -b feature )
}

# _rf_commit <dir> <path> <message> -- writes a one-line file at <path>
# (parent dirs created) and commits it alone on the current branch.
_rf_commit() {
    local dir="$1" path="$2" msg="$3"
    mkdir -p "$dir/$(dirname "$path")"
    echo "content-$msg-$RANDOM" > "$dir/$path"
    ( cd "$dir" && git add "$path" && git commit -q -m "$msg" )
}

RFS="$PLUGIN/scripts/red-first-preflight.sh"

# --- (a) proper order: test-only commit, then an impl-touching commit -> PASS.
T5A="$(mktemp -d)"
_rf_repo "$T5A"
_rf_commit "$T5A" "tests/foo.sh" "test(235): red"
_rf_commit "$T5A" "src/foo.sh" "feat(235): green"
out="$(bash "$RFS" --root "$T5A" --branch feature 2>&1)"; rc=$?
check_rc "red-first: (a) proper order passes -- exit 0" 0 "$rc"
check "red-first: (a) proper order -- silent stdout on pass" "" "$out"
rm -rf "$T5A"

# --- (b) a single commit touching BOTH test and impl files, no prior
# test-only commit -> FAIL, message names the commit.
T5B="$(mktemp -d)"
_rf_repo "$T5B"
mkdir -p "$T5B/tests" "$T5B/src"
echo t > "$T5B/tests/foo.sh"
echo i > "$T5B/src/foo.sh"
( cd "$T5B" && git add tests/foo.sh src/foo.sh && git commit -q -m "feat(235): mixed commit" )
BADSHA="$(cd "$T5B" && git rev-parse HEAD)"
out="$(bash "$RFS" --root "$T5B" --branch feature 2>&1)"; rc=$?
check_rc "red-first: (b) mixed test+impl commit fails -- nonzero exit" 2 "$rc"
check "red-first: (b) mixed commit -- message is actionable (BLOCKED)" "BLOCKED" "$out"
check "red-first: (b) mixed commit -- message names the offending sha" "$BADSHA" "$out"
rm -rf "$T5B"

# --- (c) an impl-touching commit exists but NO test-only commit exists
# anywhere before it on the branch -> FAIL.
T5C="$(mktemp -d)"
_rf_repo "$T5C"
_rf_commit "$T5C" "src/foo.sh" "feat(235): impl with no red step"
BADSHA_C="$(cd "$T5C" && git rev-parse HEAD)"
out="$(bash "$RFS" --root "$T5C" --branch feature 2>&1)"; rc=$?
check_rc "red-first: (c) impl with no earlier test-only commit fails" 2 "$rc"
check "red-first: (c) message is actionable (BLOCKED)" "BLOCKED" "$out"
check "red-first: (c) message names the offending sha" "$BADSHA_C" "$out"
rm -rf "$T5C"

# --- (d) a docs-only branch (zero impl-touching commits) -> PASS trivially.
T5D="$(mktemp -d)"
_rf_repo "$T5D"
_rf_commit "$T5D" "docs/notes.md" "docs(235): add notes"
_rf_commit "$T5D" "README.md" "docs(235): update readme"
out="$(bash "$RFS" --root "$T5D" --branch feature 2>&1)"; rc=$?
check_rc "red-first: (d) docs-only branch passes trivially" 0 "$rc"
rm -rf "$T5D"

# --- (e) a test-only branch (adding regression coverage, no impl change at
# all) -> PASS trivially.
T5E="$(mktemp -d)"
_rf_repo "$T5E"
_rf_commit "$T5E" "tests/regression.sh" "test(235): add regression coverage"
out="$(bash "$RFS" --root "$T5E" --branch feature 2>&1)"; rc=$?
check_rc "red-first: (e) test-only branch passes trivially" 0 "$rc"
rm -rf "$T5E"

# --- (f) multi-round: proper red-then-green pair, THEN a later commit that
# also touches impl files (e.g. a reviewer-requested fix-round commit) ->
# still PASS -- the rule only requires ONE qualifying test-only commit
# before the FIRST impl-touching commit, not before every subsequent one.
T5F="$(mktemp -d)"
_rf_repo "$T5F"
_rf_commit "$T5F" "tests/foo.sh" "test(235): red"
_rf_commit "$T5F" "src/foo.sh" "feat(235): green"
_rf_commit "$T5F" "src/foo.sh" "fix(235): reviewer-requested follow-up"
out="$(bash "$RFS" --root "$T5F" --branch feature 2>&1)"; rc=$?
check_rc "red-first: (f) multi-round (later impl commit) still passes" 0 "$rc"
rm -rf "$T5F"

# --- (g) --branch defaults to the current branch when omitted.
T5G="$(mktemp -d)"
_rf_repo "$T5G"
_rf_commit "$T5G" "tests/foo.sh" "test(235): red"
_rf_commit "$T5G" "src/foo.sh" "feat(235): green"
out="$(cd "$T5G" && bash "$RFS" --root "$T5G" 2>&1)"; rc=$?
check_rc "red-first: (g) --branch defaults to current branch -- passes" 0 "$rc"
rm -rf "$T5G"

# --- (h)/(i) wiring: board-queue.sh's _do_move() calls red-first-preflight.sh
# ALONGSIDE gate-preflight.sh on the "in review" transition. Fake `gh` as in
# section-gate-preflight.sh; a recorded gate pass isolates the assertion to
# red-first's own check (gate-preflight already has its own coverage).
T5H="$(mktemp -d)"
_rf_repo "$T5H"
_rf_commit "$T5H" "src/foo.sh" "feat(235): impl with no red step"
out="$(cd "$T5H" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "red-first wiring: gate pass recorded on fixture" "GATE PASS recorded" "$out"

T5HGH="$(mktemp -d)"
MUTATION_MARKER_H="$T5HGH/mutated"
cat >"$T5HGH/gh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
case "\$1 \$2" in
    "project item-list") echo '{"items":[{"id":"ITEM_7","content":{"number":7}}]}' ;;
    "project item-edit") touch "$MUTATION_MARKER_H" 2>/dev/null; echo "edited" ;;
    *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$T5HGH/gh"

out="$(cd "$T5H" && PATH="$T5HGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 7 "In review" 2>&1)"; rc=$?
check "red-first wiring: (h) board.sh move blocked -- gate pass alone isn't enough" "BLOCKED" "$out"
if [[ "$rc" -ne 0 ]]; then
    echo "ok   red-first wiring: (h) blocked move -- nonzero exit"
else
    echo "FAIL red-first wiring: (h) blocked move -- nonzero exit (got rc=$rc)"
    fails=$((fails+1))
fi
if [[ -f "$MUTATION_MARKER_H" ]]; then
    echo "FAIL red-first wiring: (h) blocked move must not reach gh project item-edit"
    fails=$((fails+1))
else
    echo "ok   red-first wiring: (h) blocked move never reached gh project item-edit"
fi

# (i) same fixture: a test-only commit added AFTER the offending impl
# commit does NOT retroactively fix ordering -- still blocked (re-record
# the gate pass since the tree changed).
_rf_commit "$T5H" "tests/foo.sh" "test(235): red (added after the fact, too late)"
out="$(cd "$T5H" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "red-first wiring: (i) gate pass re-recorded after tree change" "GATE PASS recorded" "$out"
out="$(cd "$T5H" && PATH="$T5HGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 7 "In review" 2>&1)"; rc=$?
check "red-first wiring: (i) move still blocked -- a later test-only commit doesn't fix ordering" "BLOCKED" "$out"
if [[ "$rc" -ne 0 ]]; then
    echo "ok   red-first wiring: (i) still blocked -- nonzero exit"
else
    echo "FAIL red-first wiring: (i) still blocked -- nonzero exit (got rc=$rc)"
    fails=$((fails+1))
fi
rm -rf "$T5H" "$T5HGH"

# (j) fresh fixture with PROPER order (test-only commit before the impl
# commit) -- board.sh move to "In review" must succeed, reaching gh.
T5J="$(mktemp -d)"
_rf_repo "$T5J"
_rf_commit "$T5J" "tests/foo.sh" "test(235): red"
_rf_commit "$T5J" "src/foo.sh" "feat(235): green"
out="$(cd "$T5J" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "red-first wiring: (j) gate pass recorded" "GATE PASS recorded" "$out"
T5JGH="$(mktemp -d)"
MUTATION_MARKER_J="$T5JGH/mutated"
cat >"$T5JGH/gh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
case "\$1 \$2" in
    "project item-list") echo '{"items":[{"id":"ITEM_7","content":{"number":7}}]}' ;;
    "project item-edit") touch "$MUTATION_MARKER_J" 2>/dev/null; echo "edited" ;;
    *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$T5JGH/gh"
out="$(cd "$T5J" && PATH="$T5JGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 7 "In review" 2>&1)"; rc=$?
check "red-first wiring: (j) proper order -- move succeeds" "moved #7 -> In review" "$out"
check_rc "red-first wiring: (j) proper order -- exit 0" 0 "$rc"
if [[ -f "$MUTATION_MARKER_J" ]]; then
    echo "ok   red-first wiring: (j) allowed move reached gh project item-edit"
else
    echo "FAIL red-first wiring: (j) allowed move should have reached gh project item-edit"
    fails=$((fails+1))
fi
rm -rf "$T5J" "$T5JGH"
