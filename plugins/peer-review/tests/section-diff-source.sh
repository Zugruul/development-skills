#!/usr/bin/env bash
# section-diff-source.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/fails before
# sourcing this file.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/peer-review/tests/run-tests.sh" >&2; exit 2; }
echo "== diff-source.sh (PRV-001) =="

SCRIPT="$PLUGIN/scripts/diff-source.sh"

# NOBIN excludes any real `codex` install (e.g. homebrew/npm paths) so
# "codex present/missing" behavior is deterministic regardless of the host.
NOBIN="/usr/bin:/bin"

# FAKECODEX: a stub `codex` binary on PATH -- diff-source.sh only ever
# probes for its presence (command -v), never executes it, so an empty
# stub is sufficient.
FAKECODEX="$(mktemp -d)"
cat >"$FAKECODEX/codex" <<'EOF'
#!/usr/bin/env bash
echo "fake codex: should never be invoked by diff-source.sh" >&2
exit 1
EOF
chmod +x "$FAKECODEX/codex"

mkrepo() { # builds a fixture git repo with a main branch + a feature branch ahead of it; prints its path
    local d
    d="$(mktemp -d)"
    git -C "$d" -c init.defaultBranch=main init -q
    git -C "$d" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -q --allow-empty -m "initial on main"
    git -C "$d" -c user.name=t -c user.email=t@t.t checkout -q -b feature
    echo "feature line" >"$d/feature.txt"
    git -C "$d" add feature.txt
    git -C "$d" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -q -m "add feature.txt"
    printf '%s\n' "$d"
}

# --- default source: git diff <mainBranch>...HEAD, mainBranch falls back to "main" ---
D1="$(mkrepo)"
out="$(cd "$D1" && PATH="$FAKECODEX:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "default source: exits 0" "rc=0" "$out"
check "default source: diff contains the feature-branch change" "feature.txt" "$out"
check "default source: diff shows the added line" "+feature line" "$out"
rm -rf "$D1"

# --- mainBranch fallback: repo has no override config -> uses literal "main" ---
D2="$(mkrepo)"
git -C "$D2" -c user.name=t -c user.email=t@t.t checkout -q -b trunk main
echo "trunk-only line" >"$D2/trunk.txt"
git -C "$D2" add trunk.txt
git -C "$D2" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -q -m "trunk-only commit"
git -C "$D2" -c user.name=t -c user.email=t@t.t checkout -q feature
out="$(cd "$D2" && PATH="$FAKECODEX:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "mainBranch fallback: default source diffs against 'main', not 'trunk'" "feature.txt" "$out"
check_absent "mainBranch fallback: trunk-only content absent when falling back to main" "trunk-only line" "$out"
rm -rf "$D2"

# --- mainBranch from repo config: git config peer-review.mainBranch overrides the fallback ---
# feature2 branches off trunk (which itself branched off main with its own
# commit), so the triple-dot merge-base differs between "main" and "trunk"
# and the two configs are distinguishable in the resulting diff.
D3="$(mktemp -d)"
git -C "$D3" -c init.defaultBranch=main init -q
git -C "$D3" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -q --allow-empty -m "initial on main"
git -C "$D3" -c user.name=t -c user.email=t@t.t checkout -q -b trunk
echo "trunk-only line" >"$D3/trunk.txt"
git -C "$D3" add trunk.txt
git -C "$D3" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -q -m "trunk-only commit"
git -C "$D3" -c user.name=t -c user.email=t@t.t checkout -q -b feature2
echo "feature2 line" >"$D3/feature2.txt"
git -C "$D3" add feature2.txt
git -C "$D3" -c user.name=t -c user.email=t@t.t -c commit.gpgsign=false commit -q -m "add feature2.txt"
git -C "$D3" config peer-review.mainBranch trunk
out="$(cd "$D3" && PATH="$FAKECODEX:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "mainBranch config: exits 0" "rc=0" "$out"
check "mainBranch config: diff computed against configured mainBranch (trunk)" "feature2.txt" "$out"
check_absent "mainBranch config: trunk's own commit not included (merge-base is trunk, not main)" "trunk-only line" "$out"
rm -rf "$D3"

# --- --base <ref> ---
D4="$(mkrepo)"
git -C "$D4" -c user.name=t -c user.email=t@t.t branch -q other-base main
out="$(cd "$D4" && PATH="$FAKECODEX:$NOBIN" bash "$SCRIPT" --base other-base 2>&1; echo "rc=$?")"
check "--base: exits 0" "rc=0" "$out"
check "--base: diff computed against the given ref" "feature.txt" "$out"
rm -rf "$D4"

# --- --staged ---
D5="$(mkrepo)"
echo "staged content" >"$D5/staged.txt"
git -C "$D5" add staged.txt
out="$(cd "$D5" && PATH="$FAKECODEX:$NOBIN" bash "$SCRIPT" --staged 2>&1; echo "rc=$?")"
check "--staged: exits 0" "rc=0" "$out"
check "--staged: diff shows the staged file" "staged.txt" "$out"
check "--staged: diff shows the staged content" "+staged content" "$out"
rm -rf "$D5"

# --- --pr <n>, via fake gh harness ---
D6="$(mkrepo)"
FAKEGH="$(mktemp -d)"
cat >"$FAKEGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
if [[ "$1 $2" == "pr diff" ]]; then
    cat <<'DIFF'
diff --git a/pr-file.txt b/pr-file.txt
new file mode 100644
--- /dev/null
+++ b/pr-file.txt
@@ -0,0 +1 @@
+pr content from gh
DIFF
    exit 0
fi
echo "fake gh: unexpected: $*" >&2
exit 1
FAKE
chmod +x "$FAKEGH/gh"
out="$(cd "$D6" && PATH="$FAKEGH:$FAKECODEX:$NOBIN" bash "$SCRIPT" --pr 42 2>&1; echo "rc=$?")"
check "--pr: exits 0" "rc=0" "$out"
check "--pr: diff comes from gh pr diff" "pr-file.txt" "$out"
check "--pr: diff content from gh pr diff" "pr content from gh" "$out"
rm -rf "$D6" "$FAKEGH"

# --- empty diff: "nothing to review", exit 0, codex never invoked (not even preflighted) ---
D7="$(mkrepo)"
git -C "$D7" -c user.name=t -c user.email=t@t.t checkout -q main
# no codex anywhere on PATH -- if diff-source.sh preflighted codex on this
# (empty-diff) path it would fail; it must not even look.
out="$(cd "$D7" && PATH="$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "empty diff: exits 0" "rc=0" "$out"
check "empty diff: reports nothing to review" "nothing to review" "$out"
rm -rf "$D7"

# --- missing codex on PATH (non-empty diff) -> nonzero exit + install instructions ---
D8="$(mkrepo)"
out="$(cd "$D8" && PATH="$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_absent "missing codex: nonzero exit (not rc=0)" "rc=0" "$out"
check "missing codex: mentions codex" "codex" "$out"
check "missing codex: prints install instructions" "Install the codex CLI" "$out"
rm -rf "$D8"

rm -rf "$FAKECODEX"
