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
    mkdir -p "$dir/.claude" "$dir/.neural-network"
    python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
        "$FIX/valid.project.json" "$dir/.neural-network/project.json"
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

# --- (e2) a red commit that ALSO carries its design doc still counts as the
# red commit: docs are not implementation (a docs-only commit is already
# accepted on its own), so tests+docs must not be misread as impl and fail a
# branch that did follow red-first.
T5E2="$(mktemp -d)"
_rf_repo "$T5E2"
mkdir -p "$T5E2/tests" "$T5E2/docs"
echo "red" > "$T5E2/tests/section-thing.sh"
echo "plan" > "$T5E2/docs/design/thing.md" 2>/dev/null || { mkdir -p "$T5E2/docs/design"; echo "plan" > "$T5E2/docs/design/thing.md"; }
( cd "$T5E2" && git add -A && git commit -q -m "test(1): red suite + design doc" )
_rf_commit "$T5E2" "src/thing.py" "feat(1): implement"
out="$(bash "$RFS" --root "$T5E2" --branch feature 2>&1)"; rc=$?
check_rc "red-first: (e2) tests+docs counts as the red commit" 0 "$rc"
rm -rf "$T5E2"

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
    "api graphql") exec python3 "\$GH_GQL_ADAPTER" "\$0" "\$@" ;;
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
    "api graphql") exec python3 "\$GH_GQL_ADAPTER" "\$0" "\$@" ;;
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

# --- #551: Rust test files kept in src/ are recognized by NAME. Each case is a
# branch whose first commit touches ONLY the given path, then an impl commit.
# Test-name paths: the first commit is a RED commit, so the branch passes.
# Near-miss paths: the first commit is implementation, so the branch is blocked.
_rf_rust_case() {
    local want="$1" path="$2" d out rc
    d="$(mktemp -d)"
    _rf_repo "$d"
    _rf_commit "$d" "$path" "test(551): first commit"
    _rf_commit "$d" "src/impl.sh" "feat(551): green"
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    if [[ "$want" == "test" ]]; then
        check_rc "red-first #551: $path is a test file -- exit 0" 0 "$rc"
    else
        check_rc "red-first #551: $path is implementation -- blocked" 2 "$rc"
        check "red-first #551: $path -- message is BLOCKED" "BLOCKED" "$out"
    fi
    rm -rf "$d"
}
for p in server/crates/rpg_server/src/server/world_step_bench.rs \
         src/world_tests.rs src/world_test.rs src/world_bench.rs \
         crates/x/benches/throughput.rs benches/a/b.rs; do
    _rf_rust_case test "$p"
done
for p in src/attest.rs src/contest.rs src/benches.rs src/tests_helper.rs \
         src/testbench.rs src/latest.rs src/bench.rs; do
    _rf_rust_case impl "$p"
done

# --- A C++ project keeps tests in a capitalised Tests/ directory (Unreal plugins).
# Only the exact directory name counts: Testsuite/ and tests.cpp stay implementation.
for p in client/unreal/Plugins/RpgPredict/Tests/EntityAgreement.h \
         Plugins/X/Tests/Foo.cpp Tests/Bar.cpp; do
    _rf_rust_case test "$p"
done
for p in Plugins/X/Testsuite/Foo.cpp src/Tests.cpp; do
    _rf_rust_case impl "$p"
done

# --- #552: inline `#[cfg(test)]` tests in a source file. Each case builds a real
# repo: <base> is committed on main, the branch's first commit rewrites it to
# <new> (plus any extra files), then an impl commit follows. `pass` = the first
# commit reads as a RED commit; `block` = it reads as implementation (the branch
# is blocked, naming that commit). When in doubt the guard must block.
_rf_inline_case() {
    local want="$1" label="$2" base="$3" new="$4" path="${5:-src/lib.rs}" d out rc sha
    d="$(mktemp -d)"
    _rf_repo "$d"
    ( cd "$d" && git checkout -q main )
    if [[ -n "$base" ]]; then
        mkdir -p "$d/$(dirname "$path")"
        printf '%s\n' "$base" > "$d/$path"
        ( cd "$d" && git add -A && git commit -q -m "base" )
    fi
    ( cd "$d" && git checkout -q -B feature )
    mkdir -p "$d/$(dirname "$path")"
    printf '%s\n' "$new" > "$d/$path"
    ( cd "$d" && git add -A && git commit -q -m "test(552): first" )
    sha="$(cd "$d" && git rev-parse HEAD)"
    _rf_commit "$d" "src/impl.sh" "feat(552): green"
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    if [[ "$want" == "pass" ]]; then
        check_rc "red-first #552: $label -- passes" 0 "$rc"
    else
        check_rc "red-first #552: $label -- blocked" 2 "$rc"
        check "red-first #552: $label -- names the commit" "$sha" "$out"
    fi
    rm -rf "$d"
}

IFS= read -r -d '' RS_BASE <<'EOF' || true
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn adds() {
        assert_eq!(add(1, 2), 3);
    }
}
EOF
RS_BASE="${RS_BASE%$'\n'}"
RS_PROD="${RS_BASE%%#\[cfg(test)\]*}"   # the production part only
RS_PROD="${RS_PROD%$'\n'}"

# pass cases
_rf_inline_case pass "test added in existing mod tests" "$RS_BASE" "${RS_BASE%\}}
    #[test]
    fn adds_more() {
        assert_eq!(add(2, 2), 4);
    }
}"
_rf_inline_case pass "new cfg(test) mod added to a file without one" "$RS_PROD" "$RS_BASE"
_rf_inline_case pass "cfg(test) accessor with doc comment beside an impl" \
"pub struct S { v: u8 }
impl S {
    pub fn new() -> S { S { v: 0 } }
}" \
"pub struct S { v: u8 }
impl S {
    pub fn new() -> S { S { v: 0 } }
    /// A test value.
    #[cfg(test)]
    pub(crate) fn peek(&self) -> u8 {
        self.v
    }
}"
_rf_inline_case pass "cfg(all(test, unix)) mod" "$RS_PROD" "$RS_PROD

#[cfg(all(test, unix))]
mod unix_tests {
    #[test]
    fn t() { assert!(true); }
}"
_rf_inline_case pass "cfg(test) use and cfg(test) function" "$RS_PROD" "$RS_PROD

#[cfg(test)]
use std::collections::HashMap;

#[cfg(test)]
fn helper() -> usize { 1 }"
_rf_inline_case pass "deleting a test from mod tests" "$RS_BASE" "$RS_PROD

#[cfg(test)]
mod tests {
    use super::*;
}"
_rf_inline_case pass "braces in strings, raw strings, chars and nested comments" "$RS_PROD" "$RS_PROD

#[cfg(test)]
mod tests {
    /* outer /* nested } */ still comment { */
    #[test]
    fn t() {
        let a = \"}{\";
        let b = r#\"} \" {\"#;
        let c = '}';
        let d = '\\'';
        let e: &'static str = \"x\";
        assert!(a.len() + b.len() + e.len() > 0 && c != d);
    }
}"

# block cases
_rf_inline_case block "change to production code" "$RS_BASE" "${RS_BASE/a + b/a + b + 0}"
_rf_inline_case block "test added plus production change" "$RS_BASE" "${RS_BASE/a + b/a - b}
"
_rf_inline_case block "a comment line beside the block" "$RS_PROD" "$RS_PROD

// note
#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert!(true); }
}"
_rf_inline_case block "cfg(test) attribute deleted, module kept" "$RS_BASE" "${RS_BASE/\#\[cfg(test)\]/}"
_rf_inline_case block "cfg(not(test))" "$RS_PROD" "$RS_PROD

#[cfg(not(test))]
mod tests {
    pub fn t() {}
}"
_rf_inline_case block "cfg(any(test, feature))" "$RS_PROD" "$RS_PROD

#[cfg(any(test, feature = \"x\"))]
mod tests {
    pub fn t() {}
}"
_rf_inline_case block "attribute only inside a comment" "$RS_PROD" "$RS_PROD

// #[cfg(test)]
mod tests {
    pub fn t() {}
}"
_rf_inline_case block "attribute only inside a string" "$RS_PROD" "$RS_PROD

const S: &str = \"#[cfg(test)] mod t {\";
pub fn evil() -> usize { S.len() }"
_rf_inline_case block "unmatched braces" "$RS_PROD" "$RS_PROD

#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert!(true); }
}
}"
_rf_inline_case block "unterminated string" "$RS_PROD" "$RS_PROD

#[cfg(test)]
mod tests {
    fn t() { let s = \"oops; }
}"
_rf_inline_case block "production code swallowed into the block by moving a brace" \
"fn a() {}
#[cfg(test)]
mod tests {
    fn t() {}
}
fn prod() { launch(); }" \
"fn a() {}
#[cfg(test)]
mod tests {
    fn t() {}
fn prod() { launch(); }
}"
_rf_inline_case block "whitespace-only change to a test" "$RS_BASE" "${RS_BASE/    use super::\*;/    use super::\*;   }"
_rf_inline_case block "a mod.rs line declaring a new test module" "pub mod a;" "pub mod a;
#[cfg(test)]
mod a_checks;" "src/mod.rs"
_rf_inline_case block "non-Rust file with cfg(test) text" "" "#[cfg(test)]
mod tests { }" "src/x.py"
_rf_inline_case block "file outside Rust modules: C header" "" "#[cfg(test)]
mod tests { }" "src/x.h"

# binary / unparseable, rename, very large file, and Rust-plus-other-file cases
_rf_special() {
    local d out rc sha
    # binary (not UTF-8) Rust file
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q main && printf '%s\n' "$RS_PROD" > lib.rs && git add -A && git commit -q -m base && git checkout -q -B feature )
    { printf '%s\n' "$RS_PROD"; printf '\n#[cfg(test)]\nmod tests { fn t() {} }\n'; printf '\xff\xfe\x00'; } > "$d/lib.rs"
    ( cd "$d" && git add -A && git commit -q -m "test(552): binary" )
    _rf_commit "$d" "src/impl.sh" "feat(552): green"
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: binary Rust file -- blocked" 2 "$rc"
    rm -rf "$d"

    # rename of a Rust file together with a test addition
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q main && mkdir -p src && printf '%s\n' "$RS_BASE" > src/old.rs && git add -A && git commit -q -m base && git checkout -q -B feature )
    ( cd "$d" && git mv src/old.rs src/new.rs && printf '#[cfg(test)]\nmod more { fn t() {} }\n' >> src/new.rs && git add -A && git commit -q -m "test(552): rename" )
    _rf_commit "$d" "src/impl.sh" "feat(552): green"
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: renamed Rust file -- blocked" 2 "$rc"
    rm -rf "$d"

    # very large Rust file: analysis is skipped and the commit fails closed
    d="$(mktemp -d)"; _rf_repo "$d"
    python3 -c 'import sys; open(sys.argv[1],"w").write("fn p() {}\n"*120000)' "$d/big.rs"
    ( cd "$d" && git checkout -q main && git add -A && git commit -q -m base && git checkout -q -B feature )
    printf '#[cfg(test)]\nmod tests { fn t() {} }\n' >> "$d/big.rs"
    ( cd "$d" && git add -A && git commit -q -m "test(552): big" )
    _rf_commit "$d" "src/impl.sh" "feat(552): green"
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: very large Rust file -- blocked" 2 "$rc"
    rm -rf "$d"

    # inline test in a source file next to a docs file and a test-named file: passes
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q main && mkdir -p src && printf '%s\n' "$RS_PROD" > src/lib.rs && git add -A && git commit -q -m base && git checkout -q -B feature )
    printf '%s\n\n#[cfg(test)]\nmod tests { fn t() {} }\n' "$RS_PROD" > "$d/src/lib.rs"
    mkdir -p "$d/docs" "$d/tests"; echo d > "$d/docs/n.md"; echo t > "$d/tests/a.rs"
    ( cd "$d" && git add -A && git commit -q -m "test(552): mixed" )
    _rf_commit "$d" "src/impl.sh" "feat(552): green"
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: inline test + docs + test-named file -- passes" 0 "$rc"
    rm -rf "$d"

    # inline test plus an unrelated non-Rust source file: implementation
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q main && mkdir -p src && printf '%s\n' "$RS_PROD" > src/lib.rs && git add -A && git commit -q -m base && git checkout -q -B feature )
    printf '%s\n\n#[cfg(test)]\nmod tests { fn t() {} }\n' "$RS_PROD" > "$d/src/lib.rs"
    echo x > "$d/src/run.sh"
    ( cd "$d" && git add -A && git commit -q -m "test(552): mixed" )
    _rf_commit "$d" "src/impl.sh" "feat(552): green"
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: inline test + non-Rust source file -- blocked" 2 "$rc"
    rm -rf "$d"
}
_rf_special

# --- #552 review round 1: more branch-level cases (F1-F6).
# F2/F3: an attribute that is not an item of a file/mod/impl body is unprovable.
_rf_inline_case block "attribute on a const block inside a fn body" "$RS_PROD" "$RS_PROD

pub fn prod2() { keep(); #[cfg(test)] const { } std::process::exit(7); }"
_rf_inline_case block "attribute on a let statement" "$RS_PROD" "$RS_PROD

pub fn prod2() { #[cfg(test)] let a = launch(a); }"
_rf_inline_case block "attribute on a struct field named union" "$RS_PROD" "$RS_PROD

struct S { #[cfg(test)] union: u8, b: u8 } fn prod2() { evil(); }"
_rf_inline_case block "attribute on a fn parameter named union" "$RS_PROD" "$RS_PROD

fn prod2(#[cfg(test)] union: u8, b: u8) { evil(); }"
_rf_inline_case block "attribute on a tuple struct field" "$RS_PROD" "$RS_PROD

struct S(#[cfg(test)] fn(), u16);"
_rf_inline_case block "attribute on a const generic parameter" "$RS_PROD" "$RS_PROD

fn prod2<#[cfg(test)] const N: usize, T>(x: T) { evil(); }
const Z: u8 = 0;"
_rf_inline_case block "attribute inside stringify!" "$RS_PROD" "$RS_PROD

fn prod2() { stringify!(#[cfg(test)] mod a { evil }); }"
_rf_inline_case block "attribute inside a macro_rules! body" "$RS_PROD" "$RS_PROD

macro_rules! s { () => { #[cfg(test)] pub fn prod3() -> u8 { 1 } } }"
_rf_inline_case block "attribute inside quote!" "$RS_PROD" "$RS_PROD

quote! { #[cfg(test)] mod g { evil } }"
_rf_inline_case block "attribute inside an enum body" "$RS_PROD" "$RS_PROD

enum E { #[cfg(test)] A, B }"
# F6: a nested `mod x;` inside a block pulls in another file.
_rf_inline_case block "nested mod helpers; inside the block" "$RS_PROD" "$RS_PROD

#[cfg(test)]
mod tests {
    mod helpers;
}"
_rf_inline_case block "path-redirected mod inside the block" "$RS_PROD" "$RS_PROD

#[cfg(test)]
mod tests {
    #[path = \"prod.rs\"]
    mod p;
}"
# moved attribute: the item stays, its attribute moves to another item
_rf_inline_case block "attribute moved to the next item" \
"#[cfg(test)]
mod a {}
fn prod() {}" \
"mod a {}
#[cfg(test)]
fn prod() {}"
# nested in impl / mod bodies is fine
_rf_inline_case pass "cfg(test) fn inside a production impl and a nested mod" \
"pub struct S;
impl S { pub fn a(&self) {} }
pub mod m { pub fn b() {} }" \
"pub struct S;
impl S { pub fn a(&self) {}
    #[cfg(test)]
    fn t(&self) {} }
pub mod m { pub fn b() {}
    #[cfg(test)]
    use std::fmt; }"
# F1: an analysis exception must block. A 3000-deep all(..) overflows recursion.
DEEP="$(python3 -c 'print("#[cfg(" + "all("*3000 + "test" + ")"*3000 + ")]\nmod a {}")')"
_rf_inline_case block "analysis exception (deep cfg) with a production change" \
"pub fn safe() {}" "pub fn evil() {}
$DEEP"
_rf_inline_case block "analysis exception (deep cfg), module deleted, production change" \
"pub fn safe() {}
$DEEP" "pub fn evil() {}"

# round 2 (N1-N4) at branch level
_rf_inline_case block "N1: brace macro reaches an inner mod" "$RS_PROD
s! { mod x { } }" "$RS_PROD
s! { mod x { #[cfg(test)] pub fn prod() -> u8 { 1 } } }"
_rf_inline_case block "N1: stringify! with an inner mod" "$RS_PROD
stringify!{ mod a { #[cfg(test)] fn x(){ safe } } }" "$RS_PROD
stringify!{ mod a { #[cfg(test)] fn x(){ evil } } }"
_rf_inline_case block "N1: quote! with an inner impl" "$RS_PROD
quote!{ impl X { #[cfg(test)] fn a(){} } }" "$RS_PROD
quote!{ impl X { #[cfg(test)] fn a(){ evil } } }"
_rf_inline_case block "N1: macro inside a mod" "$RS_PROD
mod m { s!{ impl X { #[cfg(test)] fn p(){} } } }" "$RS_PROD
mod m { s!{ impl X { #[cfg(test)] fn p(){ evil } } } }"
_rf_inline_case block "N2: cfg(test) const generic parameter on a fn" "$RS_PROD
fn gone<#[cfg(test)] const N: usize, T>(x: T) { safe(); }
const Z: u8 = 0;" "$RS_PROD
fn gone<#[cfg(test)] const N: usize, T>(x: T) { evil(); }
const Z: u8 = 1;"
_rf_inline_case block "N2: cfg(test) const generic parameter on an impl" "$RS_PROD
impl<#[cfg(test)] const N: usize, T> X<T> { fn p() { safe(); } }
const Z: u8 = 0;" "$RS_PROD
impl<#[cfg(test)] const N: usize, T> X<T> { fn p() { evil(); } }
const Z: u8 = 1;"
_rf_inline_case block "N3: a && b becomes a & &b beside a new test" "fn p(a: bool, b: bool) -> bool { a && b }" "fn p(a: bool, b: bool) -> bool { a & &b }
$(printf '#[cfg(test)]\nmod t { fn a() {} }')"
_rf_inline_case block "N3: stringify!(a&&b) becomes a & &b" "stringify!(a&&b);" "stringify!(a& &b);
$(printf '#[cfg(test)]\nmod t { fn a() {} }')"
_rf_inline_case block "N4: a shebang line hides a string-swallowing attribute" "#!/x
fn keep(){}" "#!/x #[cfg(test)] const A: &str = \"
fn evil(){ launch(); }
// \";
fn keep(){}"

# round 3: attribute macros see the whole body before inner cfg applies
_rf_inline_case block "R1: attribute macro on a mod" "$RS_PROD
#[strip] mod m { }" "$RS_PROD
#[strip] mod m { #[cfg(test)] fn t(){} }"
_rf_inline_case block "R1: attribute macro on an impl" "$RS_PROD
#[register] impl S { }" "$RS_PROD
#[register] impl S { #[cfg(test)] fn t(){} }"
_rf_inline_case block "R1: cfg_attr on an impl" "$RS_PROD
#[cfg_attr(all(), strip)] impl S { }" "$RS_PROD
#[cfg_attr(all(), strip)] impl S { #[cfg(test)] fn t(){} }"
_rf_inline_case block "R1: path attribute macro on a mod" "$RS_PROD
#[foo::bar(x = 1)] mod m { }" "$RS_PROD
#[foo::bar(x = 1)] mod m { #[cfg(test)] fn t(){} }"
_rf_inline_case pass "R1: inert allow attribute on a mod still passes" "$RS_PROD
#[allow(x)] pub mod m { }" "$RS_PROD
#[allow(x)] pub mod m { #[cfg(test)] fn t(){} }"
BOM="$(printf '\357\273\277')"
_rf_inline_case block "BOM then shebang hides a string-swallowing attribute" "${BOM}#!/x;
fn keep(){}" "${BOM}#!/x; #[cfg(test)] const A: &str = \"
fn evil(){}
// \";
fn keep(){}"

# round 4: lexer desyncs (non-ASCII identifier characters, cr strings, NBSP shebang)
CMB="$(printf '\314\201')"; NBSP="$(printf '\302\240')"
_rf_inline_case block "L1: combining mark before an r-string" "#[cfg(test)] const A: u8 = m!('x${CMB}r\"\\\"\" );
pub fn evil() -> u8 { 41 }
#[cfg(test)] const B: u8 = m!(\" // \"
);" "#[cfg(test)] const A: u8 = m!('x${CMB}r\"\\\"\" );
pub fn evil() -> u8 { 42 }
#[cfg(test)] const B: u8 = m!(\" // \"
);"
_rf_inline_case block "L2: cr#-string hides production code" "#[cfg(test)] const A: u8 = m!(cr#\"\");
pub fn evil() -> u8 { 41 }
#[cfg(test)] const B: u8 = m!(\"\"#);" "#[cfg(test)] const A: u8 = m!(cr#\"\");
pub fn evil() -> u8 { 42 }
#[cfg(test)] const B: u8 = m!(\"\"#);"
_rf_inline_case block "L3: NBSP after a shebang" "#!${NBSP}[]
fn keep(){}" "#!${NBSP}[] #[cfg(test)] const A: &str = \"
fn evil(){}
// \";
fn keep(){}"

# round 5: a literal suffix (an identifier straight after a string or char)
_rf_inline_case block "S1: string suffix r before a quoted string" "#[cfg(test)] const A: u8 = m!(\"\"r\"\\\"\" );
pub fn evil() -> u8 { 41 }
#[cfg(test)] const B: u8 = m!(\" // \"
);
fn keep(){}" "#[cfg(test)] const A: u8 = m!(\"\"r\"\\\"\" );
pub fn evil() -> u8 { 42 }
#[cfg(test)] const B: u8 = m!(\" // \"
);
fn keep(){}"
_rf_inline_case block "S2: char suffix r before a raw string" "#[cfg(test)] const A: u8 = m!('a'r#\"\");
pub fn evil() -> u8 { 41 }
#[cfg(test)] const B: u8 = m!(\"\"#);" "#[cfg(test)] const A: u8 = m!('a'r#\"\");
pub fn evil() -> u8 { 42 }
#[cfg(test)] const B: u8 = m!(\"\"#);"

_rf_special2() {
    local d out rc scr
    # F1: a module that raises, and a module that is missing, both block.
    scr="$(mktemp -d)"; cp -r "$PLUGIN/scripts/." "$scr/"
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q main && printf 'fn p() {}\n' > lib.rs && git add -A && git commit -q -m base && git checkout -q -B feature )
    printf 'fn p() {}\n#[cfg(test)]\nmod tests { fn t() {} }\n' > "$d/lib.rs"
    ( cd "$d" && git add -A && git commit -q -m "test(552): red" )
    _rf_commit "$d" "src/impl.sh" "feat(552): green"
    out="$(bash "$scr/red-first-preflight.sh" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: control copy of the script passes" 0 "$rc"
    printf 'raise RuntimeError("boom")\n' > "$scr/rust_inline_tests.py"
    out="$(bash "$scr/red-first-preflight.sh" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: a raising module blocks" 2 "$rc"
    rm "$scr/rust_inline_tests.py"
    out="$(env -u PYTHONPATH bash "$scr/red-first-preflight.sh" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: a missing module blocks" 2 "$rc"
    # the classifier is isolated (python3 -I): a copy of the module on
    # PYTHONPATH or in the working directory must not stand in for it
    cp_dir="$(mktemp -d)"; cp "$PLUGIN/scripts/rust_inline_tests.py" "$cp_dir/"
    out="$(PYTHONPATH="$cp_dir" bash "$scr/red-first-preflight.sh" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: a missing module blocks even with a copy on PYTHONPATH" 2 "$rc"
    out="$(cd "$cp_dir" && env -u PYTHONPATH bash "$scr/red-first-preflight.sh" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: a missing module blocks even with a copy in the cwd" 2 "$rc"
    # and a hostile stdlib shadow in the cwd must not break a correct run
    printf 'raise RuntimeError("shadowed")\n' > "$cp_dir/re.py"
    out="$(cd "$cp_dir" && env -u PYTHONPATH bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: a hostile re.py in the cwd does not change the verdict" 0 "$rc"
    rm -rf "$cp_dir"
    rm -rf "$scr" "$d"

    # F1: a classifier that cannot start at all (empty answer) blocks. The shim
    # fails only the classifier (python3 reading its script from stdin).
    d="$(mktemp -d)"; _rf_repo "$d"; scr="$(mktemp -d)"
    # shellcheck disable=SC2016  # the shim's $1 must stay literal
    printf '#!/bin/sh\n[ "$1" = "-" ] && exit 1\nexec %s "$@"\n' "$(command -v python3)" > "$scr/python3"; chmod +x "$scr/python3"
    _rf_commit "$d" "src/impl.sh" "feat(552): lonely impl"
    out="$(PATH="$scr:$PATH" bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: a classifier that prints nothing blocks" 2 "$rc"
    rm -rf "$d" "$scr"

    # a branch with its own root commit: --root keeps that commit's files visible
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q --orphan unrelated && mkdir src && echo x > src/evil.sh && git add -A && git commit -q -m "root" )
    out="$(bash "$RFS" --root "$d" --branch unrelated 2>&1)"; rc=$?
    check_rc "red-first #552: an implementation file in a root commit blocks" 2 "$rc"
    rm -rf "$d"

    # inline-only branch, no implementation commit at all: passes as before
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q main && printf 'fn p() {}\n' > lib.rs && git add -A && git commit -q -m base && git checkout -q -B feature )
    printf 'fn p() {}\n#[cfg(test)]\nmod tests { fn t() {} }\n' > "$d/lib.rs"
    ( cd "$d" && git add -A && git commit -q -m "test(552): only tests" )
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: inline-only branch passes" 0 "$rc"
    rm -rf "$d"

    # F4: an evil merge adding src/evil.sh was invisible (empty file list = doc)
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q main && mkdir docs && echo base > docs/n.md && git add -A && git commit -q -m base \
      && git checkout -q -b side && echo side > docs/n.md && git commit -q -am side \
      && git checkout -q -B feature main && echo feat > docs/n.md && git commit -q -am feat \
      && { git merge -q side >/dev/null 2>&1 || true; } && echo merged > docs/n.md && mkdir -p src && echo x > src/evil.sh \
      && git add -A && git commit -q -m merge )
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: a merge that adds an implementation file blocks" 2 "$rc"
    rm -rf "$d"

    # F4: a merge commit carrying only docs is still fine, and a root-free history works
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q main && echo a > a.md && git add -A && git commit -q -m base \
      && git checkout -q -b side && echo s > s.md && git add -A && git commit -q -m side \
      && git checkout -q -B feature main && echo f > f.md && git add -A && git commit -q -m feat && git merge -q --no-edit side )
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: a docs-only merge passes" 0 "$rc"
    rm -rf "$d"

    # F4: renames count as delete + add, both sides classified (an implementation
    # file renamed to a test name is not a red commit)
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q main && mkdir src && printf 'echo hello world\nfoo\nbar\nbaz\n' > src/x.py && git add -A && git commit -q -m base && git checkout -q -B feature \
      && mkdir tests && git mv src/x.py tests/x.py && git commit -q -m "test(552): rename" )
    _rf_commit "$d" "src/impl.sh" "feat(552): green"
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: an impl file renamed to a test name blocks" 2 "$rc"
    rm -rf "$d"

    # F6: a pure rename of a wholly cfg(test) file
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q main && mkdir src && printf '#[cfg(test)]\nmod tests {\n    fn t() {}\n}\n' > src/a.rs && git add -A && git commit -q -m base && git checkout -q -B feature \
      && git mv src/a.rs src/b.rs && git commit -q -m "test(552): rename" )
    _rf_commit "$d" "src/impl.sh" "feat(552): green"
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: a pure rename of a cfg(test) file blocks" 2 "$rc"
    rm -rf "$d"

    # F5: a retargeted symlink named .rs is not source
    d="$(mktemp -d)"; _rf_repo "$d"
    ( cd "$d" && git checkout -q main && mkdir src && ln -s 'a' src/l.rs && git add -A && git commit -q -m base && git checkout -q -B feature \
      && rm src/l.rs && ln -s 'a #[cfg(test)] mod t {}' src/l.rs && git add -A && git commit -q -m "test(552): link" )
    _rf_commit "$d" "src/impl.sh" "feat(552): green"
    out="$(bash "$RFS" --root "$d" --branch feature 2>&1)"; rc=$?
    check_rc "red-first #552: a retargeted .rs symlink blocks" 2 "$rc"
    rm -rf "$d"
}
_rf_special2

# --- #552: direct unit checks of scripts/rust_inline_tests.py (stdlib only).
_rf_unit() {
    PYTHONDONTWRITEBYTECODE=1 python3 -I - "$PLUGIN/scripts" <<'PY'
import os, shutil, subprocess, sys, tempfile, time
sys.path.insert(0, sys.argv[1])
import rust_inline_tests as r
def ok(name, cond):
    print(("ok   " if cond else "FAIL ") + "red-first #552 unit: " + name)
def kinds(src):
    t = r.lex(src)
    return None if t is None else [(k, x) for k, x, _, _ in t]
def one(src, kind):
    return kinds(src) == [(kind, src)]
# lexer
ok("line doc comment", one("/// x", "doc"))
ok("four slashes is a plain comment", one("//// x", "comment"))
ok("inner line doc //! is not attachable", one("//! x", "comment"))
ok("block doc", one("/** x */", "doc"))
ok("/***/ and /**/ are plain comments", one("/**/", "comment") and one("/*** x */", "comment"))
ok("inner block doc /*! is not attachable", one("/*! x */", "comment"))
ok("nested block comment is one token", one("/* a /* b */ c */", "comment"))
ok("closing comment before a nested opener", kinds("/* a */ /* b */") == [("comment", "/* a */"), ("comment", "/* b */")])
ok("unterminated block comment", r.lex("/* x") is None and r.lex("/* /* x */") is None)
ok("string with escaped quote", one('"a\\"b"', "str"))
ok("string ending in escaped backslash", kinds('"a\\\\" x') == [("str", '"a\\\\"'), ("word", "x")])
ok("byte string", one('b"x"', "str"))
ok("c string", one('c"x"', "str"))
ok("raw string", one('r"a\\"', "str"))
ok("raw string with hashes and quotes", one('r##"a"#b"##', "str"))
ok("byte raw string", one('br#"a"#', "str"))
ok("cr raw string is unprovable (edition dependent)", r.lex('cr"a"') is None and r.lex('cr#"a"#') is None)
ok("plain c string stays", one('c"a"', "str"))
ok("unterminated string", r.lex('"abc') is None and r.lex('"abc\\"') is None)
ok("unterminated raw string", r.lex('r#"abc"') is None)
ok("char literal", one("'x'", "char"))
ok("escaped quote char", one("'\\''", "char"))
ok("escaped backslash char", one("'\\\\'", "char"))
ok("unicode escape char", one("'\\u{1F600}'", "char"))
ok("byte char", one("b'x'", "char"))
ok("lifetime", one("'abc", "life"))
ok("lifetime then punct", kinds("<'a>") == [("punct", "<"), ("life", "'a"), ("punct", ">")])
ok("ambiguous quote fails closed", r.lex("' ") is None and r.lex("'") is None and r.lex("''") is None and r.lex("'''") is None and r.lex("'\n'") is None and r.lex("'1") is None)
ok("unterminated escaped char", r.lex("'\\n;") is None)
ok("raw identifier is one word", kinds("r#fn") == [("word", "r#fn")] and kinds("r#_x") == [("word", "r#_x")])
ok("r#\" starts a raw string, not a raw identifier", one('r#"x"#', "str"))
ok("plain word and punct", kinds("a+1") == [("word", "a"), ("punct", "+"), ("word", "1")])
ok("b and c words are not prefixes", kinds("b c") == [("word", "b"), ("word", "c")])
# brackets
ok("mismatched brackets are unprovable", r._split("fn a( ] {}") is None and r._split("fn a() {") is None and r._split("}") is None)
ok("balanced brackets split", r._split("fn a() {}") is not None)
# cfg predicates
cfg = lambda s: r.cfg_is_test(r.lex(s))
ok("cfg(test)", cfg("cfg(test)") is True)
ok("cfg(all(test, unix)) and (unix, test)", cfg("cfg(all(test, unix))") and cfg("cfg(all(unix, test))"))
ok("cfg(all(test,)) trailing comma", cfg("cfg(all(test,))"))
ok("cfg(all(feature = \"x\", test))", cfg('cfg(all(feature = "x", test))'))
ok("cfg(all(any(test), x)) is not test", not cfg("cfg(all(any(test), x))"))
ok("cfg(any(test, x)) and not(test)", not cfg("cfg(any(test, x))") and not cfg("cfg(not(test))"))
ok("cfg(all(not(test), x)) is not test", not cfg("cfg(all(not(test), x))"))
ok("cfg(testing), cfg(test = \"x\"), cfg()", not cfg("cfg(testing)") and not cfg('cfg(test = "x")') and not cfg("cfg()"))
ok("trailing junk after the predicate", not cfg("cfg(test) x") and not cfg("cfg(test, unix)") and not cfg("cfg(test"))
ok("not a cfg at all", not cfg("test") and not cfg("cfg_attr(test, derive(Debug))") and not cfg("derive(Debug)"))
ok("a bare name after test is not test", not cfg('cfg(all(test = "x"))') and not cfg("cfg(all(test x))"))
ok("non-ASCII outside strings and comments is unprovable", r.lex("fn caf\u00e9() {}") is None and r.lex("'x\u0301 y") is None and r.lex("a\u00b7b") is None and r.lex("a\u00a0b") is None and r.lex("a \u2028 b") is None)
ok("a literal suffix is unprovable", all(r.lex(x) is None for x in ['"a"r', "'a'r", 'b"x"y', "b'x'z", 'r"x"_', 'br"x"s', '1"a"b0']))
ok("a literal followed by punctuation or space is fine", all(r.lex(x) is not None for x in ['"a" r', '"a";', "'a'+1", 'b"x")', 'r"x"\n']))
S1 = "#[cfg(test)] const A: u8 = m!(\"\"r\"\\\"\" );\npub fn evil() -> u8 { %d }\n#[cfg(test)] const B: u8 = m!(\" // \"\n);\n"
ok("string suffix does not desync", r.test_only_change(S1 % 41, S1 % 42) is False)
S2 = "#[cfg(test)] const A: u8 = m!('a'r#\"\");\npub fn evil() -> u8 { %d }\n#[cfg(test)] const B: u8 = m!(\"\"#);\n"
ok("char suffix does not desync", r.test_only_change(S2 % 41, S2 % 42) is False)
ok("a non-ASCII lifetime is unprovable", r.lex("fn f<'\u00e9>() {}") is None)
ok("non-ASCII inside strings, chars and comments is fine", r.lex('let s = "caf\u00e9"; let c = \'\u00e9\'; // \u00e9 \n/* \u00e9 */') is not None)
ok("a leading BOM is exempt; a second one is not", r.lex("\ufeffa") is not None and r.lex("\ufeff\ufeffa") is None)
ok("shebang check uses Rust whitespace only", r.lex("#!\u00a0[allow(x)]\nfn a() {}") is None and r.lex("#! \t[allow(x)]\nfn a() {}") is not None)
T0 = "#[cfg(test)] const A: u8 = m!('x\u0301r\"\\\"\" );\npub fn evil() -> u8 { %d }\n#[cfg(test)] const B: u8 = m!(\" // \"\n);\n"
ok("combining mark before r-string does not desync", r.test_only_change(T0 % 41, T0 % 42) is False)
T1 = "#[cfg(test)] const A: u8 = m!(cr#\"\");\npub fn evil() -> u8 { %d }\n#[cfg(test)] const B: u8 = m!(\"\"#);\n"
ok("cr raw string does not hide code", r.test_only_change(T1 % 41, T1 % 42) is False)
ok("NBSP after #! does not pass", r.test_only_change("#!\u00a0[]\nfn a() {}\n", "#!\u00a0[]\nfn a() {}\n#[cfg(test)] mod t {}\n") is False)
ok("BOM then shebang is still a shebang", r.lex("\ufeff#!/x\nfn a() {}") is None and r.lex("\ufeff#![allow(x)]\nfn a() {}") is not None)
# test_only_change: accepted shapes
T = r.test_only_change
P = "fn p() {}\n"
def acc(name, new, old=P): ok("accepts " + name, T(old, new) is True)
def rej(name, new, old=P): ok("rejects " + name, T(old, new) is False)
# round 2 (N1-N4)
rej("attribute under a brace macro via an inner mod", "s! { mod x { #[cfg(test)] pub fn p() -> u8 { 1 } } }\n", "s! { mod x { } }\n")
rej("attribute under a brace macro via an inner impl", "quote! { impl X { #[cfg(test)] fn a() {} } }\n", "quote! { impl X { } }\n")
rej("macro inside a mod, impl inside the macro", "mod m { s! { impl X { #[cfg(test)] fn p() {} } } }\n", "mod m { s! { impl X { } } }\n")
rej("attribute in a const block mod", "const _: () = { mod x { #[cfg(test)] fn a() {} } };\n", "const _: () = { mod x { } };\n")
rej("attribute on a const generic parameter", "fn p<#[cfg(test)] const N: usize, T>(x: T) { evil(); }\nconst Z: u8 = 1;\n", "fn p<#[cfg(test)] const N: usize, T>(x: T) { safe(); }\nconst Z: u8 = 1;\n")
rej("attribute on a const generic of an impl", "impl<#[cfg(test)] const N: usize> X { fn p() { evil(); } }\nconst Z: u8 = 1;\n", "impl<#[cfg(test)] const N: usize> X { fn p() { safe(); } }\nconst Z: u8 = 1;\n")
rej("attribute on a const generic of a struct", "struct S<#[cfg(test)] const M: usize, T>(T);\nfn p() { evil(); }\nconst Y: u8 = 2;\n", "struct S<#[cfg(test)] const M: usize, T>(T);\nfn p() { safe(); }\nconst Y: u8 = 2;\n")
rej("operator spacing: a && b to a & &b", "fn p() { a & &b }\n#[cfg(test)]\nmod t { fn a() {} }\n", "fn p() { a && b }\n")
rej("operator spacing: + + to ++", "fn p() { a ++b }\n#[cfg(test)]\nmod t { fn a() {} }\n", "fn p() { a + +b }\n")
acc("operator spacing unchanged", "fn p() { a && b }\n#[cfg(test)]\nmod t { fn a() {} }\n", "fn p() { a && b }\n")
rej("shebang desync", '#!/x #[cfg(test)] const A: &str = "\nfn evil(){ launch(); }\n// ";\nfn keep(){}\n', "#!/x\nfn keep(){}\n")
ok("shebang followed by an attribute is not a shebang", r.lex("#![allow(x)]\nfn a() {}") is not None and r.lex("#!/bin/x\nfn a() {}") is None)
ok("size cap counts bytes", T("", "#[cfg(test)] mod t { /*" + "\u00e9" * (r.MAX_BYTES // 2 + 1) + "*/ }") is False)
ok("size cap leaves a smaller multibyte file alone", T("", "#[cfg(test)] mod t { /*" + "\u00e9" * 1000 + "*/ fn a() {} }") is True)
ok("shebang with a spaced inner attribute still lexes", r.lex("#! [allow(x)]\nfn a() {}") is not None)
rej("attribute macro on a mod", "#[strip] mod m { #[cfg(test)] fn t() {} }\n", "#[strip] mod m { }\n")
rej("path attribute macro", "#[foo::bar(x = 1)] mod m { #[cfg(test)] fn t() {} }\n", "#[foo::bar(x = 1)] mod m { }\n")
rej("cfg_attr on an impl", "#[cfg_attr(all(), strip)] impl S { #[cfg(test)] fn t() {} }\n", "#[cfg_attr(all(), strip)] impl S { }\n")
rej("a path attribute that starts with an inert name", "#[doc::x] mod m { #[cfg(test)] fn t() {} }\n", "#[doc::x] mod m { }\n")
rej("an attribute whose name merely starts like an inert one", "#[allowed] mod m { #[cfg(test)] fn t() {} }\n", "#[allowed] mod m { }\n")
for nm in ("allow", "warn", "deny", "forbid", "expect", "cfg", "doc", "inline", "must_use"):
    acc("inert attribute " + nm + " on a mod", "#[" + nm + "(x)] mod m { #[cfg(test)] fn t() {} }\n", "#[" + nm + "(x)] mod m { }\n")
acc("inert attribute with = value", '#[doc = "x"] mod m { #[cfg(test)] fn t() {} }\n', '#[doc = "x"] mod m { }\n')
acc("inert attribute without arguments", "#[must_use] impl S { #[cfg(test)] fn t() {} }\n", "#[must_use] impl S { }\n")
acc("const unsafe fn", P + "#[cfg(test)]\nconst unsafe fn a() {}\n")
acc("attribute at the very start of a file", "#[cfg(test)]\nmod t {}\nstruct S(u8)", "struct S(u8)")
acc("attribute after an inner attribute", "#![allow(x)]\n#[cfg(test)]\nmod t {}\n", "#![allow(x)]\n")
acc("spacing between an operator and a word is not compared", "fn p() { a & b; f(x) }\n#[cfg(test)]\nmod t { fn a() {} }\n", "fn p() { a &b; f (x) }\n")
rej("const block (no name) swallowing the next const", P + "#[cfg(test)]\nconst { }\nconst Z: u8 = 1;\n", P + "#[cfg(test)]\nconst { }\nconst Z: u8 = 0;\n")
rej("item running into the end of its list swallowing the next fn", "mod m { #[cfg(test)] fn a() }\nfn b() { evil(); }\n", "mod m { #[cfg(test)] fn a() }\nfn b() { safe(); }\n")
acc("mod", P + "#[cfg(test)]\nmod t { fn a() {} }\n")
acc("pub(crate) fn", P + "#[cfg(test)]\npub(crate) fn a() {}\n")
acc("pub(in path) fn", P + "#[cfg(test)]\npub(in a::b) fn a() {}\n")
acc("const fn / unsafe fn", P + "#[cfg(test)]\nconst fn a() {}\n#[cfg(test)]\nunsafe fn b() {}\n")
rej("async fn and extern fn (not accepted)", P + "#[cfg(test)]\nasync fn c() {}\n#[cfg(test)]\nextern \"C\" fn a() {}\n")
acc("impl", P + "struct S;\n#[cfg(test)]\nimpl S { fn a() {} }\n", P + "struct S;\n")
acc("use", P + "#[cfg(test)]\nuse std::fmt;\n")
acc("const items", P + "#[cfg(test)]\nconst A: S = S { x: [1; 2] };\n#[cfg(test)]\nconst _: () = ();\n")
rej("static (not accepted)", P + "#[cfg(test)]\nstatic B: u8 = 1;\n")
acc("stacked attributes", P + "#[allow(dead_code)]\n#[cfg(test)]\nmod t {}\n")
acc("doc comment above is part of the item", "/// old\n" + P + "/// d\n#[cfg(test)]\nfn a() {}\n", "/// old\n" + P)
acc("edit of the doc comment and body of a test item", P + "/// new\n#[cfg(test)]\nfn a() { x(); }\n", P + "/// old\n#[cfg(test)]\nfn a() {}\n")
acc("fn body with braces, strings, chars", P + '#[cfg(test)]\nfn a() { let s = "}"; let c = \'{\'; let r = r#"}"#; /* } */ }\n')
acc("fn with array-length semicolons", P + "#[cfg(test)]\nfn a(x: [u8; 4]) -> [u8; 2] { [0; 2] }\n")
acc("item in an impl body", "impl S {\n#[cfg(test)]\nfn a() {}\n}\n", "impl S {\n}\n")
acc("item in a mod body", "mod m {\n#[cfg(test)]\nfn a() {}\n}\n", "mod m {\n}\n")
acc("unsafe impl body", "unsafe impl S {\n#[cfg(test)]\nfn a() {}\n}\n", "unsafe impl S {\n}\n")
acc("deleting a whole test item", P, P + "#[cfg(test)]\nmod t { fn a() {} }\n")
acc("test change with unrelated blank-line difference outside", "fn p() {}\n\n\n#[cfg(test)]\nmod t {}\n", "fn p() {}\n#[cfg(test)]\nmod t { fn a() {} }\n")
acc("all(test, unix)", P + "#[cfg(all(test, unix))]\nmod t {}\n")
acc("spaced attribute", P + "#[ cfg( test ) ]\nmod t {}\n")
# rejected shapes
rej("a production change", "fn q() {}\n#[cfg(test)]\nmod t {}\n")
rej("no test change (whitespace only)", P + "#[cfg(test)]\nmod t {}  \n", P + "#[cfg(test)]\nmod t {}\n")
rej("no change at all", P, P)
rej("a plain comment beside the block", P + "// c\n#[cfg(test)]\nmod t {}\n")
rej("an inner //! doc swallowed as the item's doc", "//! new\n#[cfg(test)]\nmod t {}\n", "//! old\n#[cfg(test)]\nmod t { fn a() {} }\n")
rej("attribute dropped", P + "mod t {}\n", P + "#[cfg(test)]\nmod t {}\n")
rej("attribute moved", "mod a {}\n#[cfg(test)]\nfn p() {}\n", "#[cfg(test)]\nmod a {}\nfn p() {}\n")
rej("not(test)", P + "#[cfg(not(test))]\nmod t {}\n")
rej("cfg_attr(test, ..)", P + "#[cfg_attr(test, derive(Debug))]\nstruct S;\n")
rej("inner #![cfg(test)]", "#![cfg(test)]\n" + P)
rej("attribute in a comment / string", P + "// #[cfg(test)]\nmod t {}\n") 
rej("attribute in a string", P + 'const S: &str = "#[cfg(test)] mod t {}";\n')
rej("mod declaration without a body", P + "#[cfg(test)]\nmod t;\n")
rej("nested mod x; in a block", P + "#[cfg(test)]\nmod t { mod helpers; }\n")
rej("struct / enum / trait / type / union items", P + "#[cfg(test)]\nstruct S;\n")
rej("macro invocation item", P + "#[cfg(test)]\nm!(x);\n")
rej("fn without a name", P + "#[cfg(test)]\nfn () {}\n")
rej("fn declaration without a body", P + "#[cfg(test)]\nfn a();\n")
rej("mod without a name", P + "#[cfg(test)]\nmod { }\n")
rej("mod with a block but no name", P + "#[cfg(test)]\nmod { {} }\n")
rej("const without a value", P + "#[cfg(test)]\nconst A: u8;\n")
acc("raw string with attribute text in a test item", P + '#[cfg(test)]\nfn a() { let s = r#"#[cfg(test)] fn b() }"#; }\n')
acc("impl header with brackets, in a production impl", "impl F for [u8; 4] {\n#[cfg(test)]\nfn a() {}\n}\n", "impl F for [u8; 4] {\n}\n")
acc("attributes before a production impl", "#[allow(x)]\n#[warn(y)]\nimpl S {\n#[cfg(test)]\nfn a() {}\n}\n", "#[allow(x)]\n#[warn(y)]\nimpl S {\n}\n")
acc("cfg(test) first in a stacked group", P + "#[cfg(test)]\n#[allow(dead_code)]\nmod t {}\n")
acc("an unrecognised cfg(test) item elsewhere is just residue", "#[cfg(test)]\nstruct S;\n" + P + "#[cfg(test)]\nmod t {}\n", "#[cfg(test)]\nstruct S;\n" + P)
acc("code after a nested test item in the same block", "#[cfg(test)]\nmod t {\n#[cfg(test)]\nfn a() {}\nfn b() { 2; }\n}\n", "#[cfg(test)]\nmod t {\n#[cfg(test)]\nfn a() {}\nfn b() { 1; }\n}\n")
rej("a comment-only change inside a test item", P + "#[cfg(test)]\nmod t { /* b */ }\n", P + "#[cfg(test)]\nmod t { /* a */ }\n")
ok("a non-string argument never raises", r.commit_is_test_only(None, "x", ["a.rs"]) is False)
rej("const block (no name)", P + "fn q() { #[cfg(test)] const { } exit(); }\n")
rej("const without = and ;", P + "#[cfg(test)]\nconst A: u8\n")
rej("item that runs into a closing bracket", "fn q() { #[cfg(test)] fn a() }\n")
rej("attribute in a fn body", "fn q() { #[cfg(test)] fn a() {} }\n", "fn q() { }\n")
rej("attribute on a statement", "fn q() { #[cfg(test)] let a = 1; }\n", "fn q() { }\n")
rej("attribute in a struct body", "struct S { #[cfg(test)] fn: u8 }\n", "struct S { }\n")
rej("attribute in parentheses", "fn q(#[cfg(test)] fn: u8) {}\n", "fn q() {}\n")
rej("attribute in angle brackets", "fn q<#[cfg(test)] const N: usize>() {}\n", "fn q() {}\n")
rej("attribute in a trait body", "trait T { #[cfg(test)] fn a(); }\n", "trait T { }\n")
rej("attribute in a macro invocation", 'fn q() { m!(#[cfg(test)] mod a {}); }\n', "fn q() { }\n")
rej("attribute in a macro_rules body", "macro_rules! m { () => { #[cfg(test)] fn a() {} } }\n", "macro_rules! m { () => { } }\n")
rej("attribute in a macro invocation at file level", "m! { #[cfg(test)] fn a() {} }\n", "m! { }\n")
rej("attribute in a fn-like macro with idents before !", "quote! { #[cfg(test)] mod g {} }\n", "quote! { }\n")
rej("unmatched braces", P + "#[cfg(test)]\nmod t { }\n}\n")
rej("unterminated string", P + '#[cfg(test)]\nmod t { fn a() { "x } }\n')
rej("oversize input", P + "#[cfg(test)]\nmod t {}\n" + " " * r.MAX_BYTES)
rej("production code swallowed by a moved brace", "#[cfg(test)]\nmod t {\nfn p2() {}\n}\n", "#[cfg(test)]\nmod t {\n}\nfn p2() {}\n")
# cost: repeated test items, near the size limit
body = "#[cfg(test)] fn a(){}\n" * (r.MAX_BYTES // 22 - 10)
t0 = time.time(); res = T("", body); dt = time.time() - t0
ok("repeated items near the size limit run fast (%.1fs)" % dt, res is True and dt < 10)
t0 = time.time(); res = T("", "/* a */ " * (r.MAX_BYTES // 8 - 10) + "#[cfg(test)] fn a(){}\n" ); dt = time.time() - t0
ok("many comments run fast (%.1fs)" % dt, dt < 10)
# git layer
def sh(d, *a, **kw):
    return subprocess.run(["git", "-C", d, "-c", "user.name=t", "-c", "user.email=t@t"] + list(a), capture_output=True, text=True, **kw)
def commit(d, msg="c"):
    sh(d, "add", "-A"); sh(d, "commit", "-q", "-m", msg); return sh(d, "rev-parse", "HEAD").stdout.strip()
def put(d, path, data):
    os.makedirs(os.path.dirname(os.path.join(d, path)) or d, exist_ok=True)
    open(os.path.join(d, path), "w").write(data)
TEST = "#[cfg(test)]\nmod t { fn a() {} }\n"
with tempfile.TemporaryDirectory() as d:
    sh(d, "init", "-q", "-b", "main")
    # root commit adding a wholly cfg(test) file
    put(d, "src/a.rs", TEST); root = commit(d)
    ok("root commit with a test-only file", r.commit_is_test_only(d, root, ["src/a.rs"]) is True)
    put(d, "src/p.rs", P); put(d, "src/b.rs", P); c1 = commit(d)
    ok("added production file is not test-only", r.commit_is_test_only(d, c1, ["src/p.rs", "src/b.rs"]) is False)
    put(d, "src/b.rs", P + TEST); c2 = commit(d)
    ok("modified file adding a test item", r.commit_is_test_only(d, c2, ["src/b.rs"]) is True)
    ok("no paths", r.commit_is_test_only(d, c2, []) is False)
    ok("a path the commit did not change", r.commit_is_test_only(d, c2, ["src/p.rs"]) is False)
    ok("a non-.rs path", r.commit_is_test_only(d, c2, ["src/b.py"]) is False)
    ok("an unknown commit", r.commit_is_test_only(d, "0" * 40, ["src/b.rs"]) is False)
    put(d, "src/b.rs", P); os.remove(os.path.join(d, "src/a.rs")); c3 = commit(d)
    ok("deleting a cfg(test) file and a test item", r.commit_is_test_only(d, c3, ["src/a.rs", "src/b.rs"]) is True)
    ok("deleting a production file is not test-only", r.commit_is_test_only(d, sh(d, "rev-parse", "HEAD~2").stdout.strip(), ["src/p.rs"]) is False)
    open(os.path.join(d, "src/p.rs"), "wb").write(P.encode() + TEST.encode() + b"\xff\xfe"); c4 = commit(d)
    ok("non-UTF-8 file", r.commit_is_test_only(d, c4, ["src/p.rs"]) is False)
    put(d, "src/big.rs", "fn p() {}\n" * (r.MAX_BYTES // 10 + 10)); commit(d)
    put(d, "src/big.rs", "fn p() {}\n" * (r.MAX_BYTES // 10 + 10) + TEST); c5 = commit(d)
    ok("oversize file", r.commit_is_test_only(d, c5, ["src/big.rs"]) is False)
    sh(d, "mv", "src/b.rs", "src/c.rs"); c6 = commit(d)
    ok("pure rename", r.commit_is_test_only(d, c6, ["src/b.rs", "src/c.rs"]) is False)
    os.symlink("a", os.path.join(d, "src/l.rs")); commit(d)
    os.remove(os.path.join(d, "src/l.rs")); os.symlink("a " + TEST.replace("\n", " "), os.path.join(d, "src/l.rs")); c7 = commit(d)
    ok("retargeted symlink", r.commit_is_test_only(d, c7, ["src/l.rs"]) is False)
    os.symlink("#[cfg(test)] mod t {}", os.path.join(d, "src/l2.rs")); c8 = commit(d)
    ok("a newly added symlink", r.commit_is_test_only(d, c8, ["src/l2.rs"]) is False)
    put(d, "src/x.txt", TEST); c9 = commit(d)
    ok("a changed path that is not .rs", r.commit_is_test_only(d, c9, ["src/x.txt"]) is False)
    put(d, "src/t2.rs", TEST); c10 = commit(d)
    ok("a test-only file added after the root commit", r.commit_is_test_only(d, c10, ["src/t2.rs"]) is True)
    open(os.path.join(d, "src/bin.rs"), "wb").write(b"\xff\xfe"); commit(d)
    put(d, "src/bin.rs", TEST); c11 = commit(d)
    ok("a file that was not UTF-8 before", r.commit_is_test_only(d, c11, ["src/bin.rs"]) is False)
    put(d, "src/t2.rs", TEST + "#[cfg(test)]\nfn more() {}\n"); shutil.copy(os.path.join(d, "src/t2.rs"), os.path.join(d, "src/t3.rs")); c12 = commit(d)
    ok("a copy of a file", r.commit_is_test_only(d, c12, ["src/t2.rs", "src/t3.rs"]) is False)
    sh(d, "checkout", "-q", "-b", "side"); put(d, "src/s.rs", P + TEST); sh(d, "add", "-A"); commit(d)
    sh(d, "checkout", "-q", "main"); put(d, "src/m.rs", P); commit(d)
    sh(d, "merge", "-q", "--no-edit", "side"); mg = sh(d, "rev-parse", "HEAD").stdout.strip()
    ok("merge commit", r.commit_is_test_only(d, mg, ["src/s.rs"]) is False)
PY
}
# A crash of the unit script (a traceback, a nonzero exit) is itself a failure.
unit_out="$(_rf_unit 2>&1)"; unit_rc=$?
while IFS= read -r line; do
    echo "$line"
    [[ "$line" == FAIL* ]] && fails=$((fails+1))
done <<< "$unit_out"
if [[ "$unit_rc" -ne 0 || "$unit_out" == *Traceback* ]]; then
    echo "FAIL red-first #552 unit: the unit script crashed (exit $unit_rc)"
    fails=$((fails+1))
fi
