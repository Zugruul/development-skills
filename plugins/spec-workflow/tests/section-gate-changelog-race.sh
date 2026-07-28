#!/usr/bin/env bash
# section-gate-changelog-race.sh -- sourced by run-tests.sh; do not run
# standalone. Contract: the runner already defines set -uo pipefail and has
# sourced _lib.sh (check/check_rc/check_absent/hookjson) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# Covers #443: CI's changelog action (.github/workflows/changelog.yml)
# pushes a "chore(changelog): regenerate" commit to main after every push,
# whose ONLY content change is CHANGELOG.md. Before this fix, tree-state.sh
# hashed the raw `git rev-parse HEAD` sha directly, so that new commit --
# even though the actual code is byte-for-byte identical to what the gate
# already tested -- made every previously-recorded pass look stale, forcing
# a full gate re-run purely to acknowledge a regenerated doc. Same class of
# fix as .claude/{gate-pass,telemetry.jsonl,lessons.jsonl,board-cache.json}
# being excluded from the fingerprint elsewhere (SW-010/SW-020/SW-023
# follow-ups, section-gate-fingerprint.sh/section-gate-lessons.sh) -- but
# CHANGELOG.md is TRACKED and lives in real commit history, so the fix has
# to exclude it from the HEAD-tree-content hash, not just from
# git-status/git-diff of the working tree.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== gate fingerprint: CHANGELOG.md commits do not invalidate a recorded pass (#443) =="

GCR_T="$(mktemp -d)"
( cd "$GCR_T" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$GCR_T/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$GCR_T/.claude/project.json"
( cd "$GCR_T" && git add .claude/project.json && git commit -q -m "add config" )
echo "old changelog" > "$GCR_T/CHANGELOG.md"
( cd "$GCR_T" && git add CHANGELOG.md && git commit -q -m "seed changelog" )

out="$(cd "$GCR_T" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "changelog-race: gate pass recorded" "GATE PASS recorded" "$out"

# --- the CI incident itself: a commit whose ONLY content change is
# CHANGELOG.md, authored as github-actions[bot] would, lands on top of the
# tested tree. The recorded pass must still be valid. --------------------
echo "regenerated changelog v2" > "$GCR_T/CHANGELOG.md"
( cd "$GCR_T" && git add CHANGELOG.md &&
  git -c user.name="github-actions[bot]" -c user.email="github-actions[bot]@users.noreply.github.com" \
      commit -q -m "chore(changelog): regenerate" )
out="$(cd "$GCR_T" && bash "$PLUGIN/scripts/gate-preflight.sh" 2>&1)"; rc=$?
check_rc "changelog-only commit: pass still valid (exit 0)" 0 "$rc"
if [[ -z "$out" ]]; then
    echo "ok   changelog-only commit: silent stdout"
else
    echo "FAIL changelog-only commit: silent stdout (got: $out)"
    fails=$((fails + 1))
fi
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$GCR_T" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "changelog-only commit: move to In review still allowed via the hook path" "rc=0" "$out"
check_absent "changelog-only commit: never reports the tree as changed" "tree changed" "$out"

# --- regression: a REAL code commit (not CHANGELOG.md) after the pass MUST
# still invalidate it -- the fix must not blind the fingerprint to actual
# code changes, only to the generated doc. ---------------------------------
echo "echo real code change" > "$GCR_T/real-code.sh"
( cd "$GCR_T" && git add real-code.sh && git commit -q -m "add real code" )
out="$(cd "$GCR_T" && bash "$PLUGIN/scripts/gate-preflight.sh" 2>&1)"; rc=$?
check_rc "real code commit after the pass: exit 2 (stale)" 2 "$rc"
check "real code commit after the pass: reported as a tree change" "tree changed since the last recorded gate pass" "$out"

# --- a fresh pass on the new tree (including the real code + regenerated
# changelog) works normally, then a SECOND changelog-only commit on top of
# THAT still does not invalidate it either -- proves this is not a one-shot
# fluke tied to the very first pass. ----------------------------------------
out="$(cd "$GCR_T" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "changelog-race: second gate pass recorded" "GATE PASS recorded" "$out"
echo "regenerated changelog v3" > "$GCR_T/CHANGELOG.md"
( cd "$GCR_T" && git add CHANGELOG.md &&
  git -c user.name="github-actions[bot]" -c user.email="github-actions[bot]@users.noreply.github.com" \
      commit -q -m "chore(changelog): regenerate" )
out="$(cd "$GCR_T" && bash "$PLUGIN/scripts/gate-preflight.sh" 2>&1)"; rc=$?
check_rc "second changelog-only commit: still valid (exit 0)" 0 "$rc"

# --- a LOCAL, not-yet-committed CHANGELOG.md-only edit (someone ran the
# changelog-generate skill by hand before gating) must not invalidate the
# pass either -- consistent with the committed case above. -----------------
echo "local dirty regenerate" > "$GCR_T/CHANGELOG.md"
out="$(cd "$GCR_T" && bash "$PLUGIN/scripts/gate-preflight.sh" 2>&1)"; rc=$?
check_rc "uncommitted CHANGELOG.md-only edit: still valid (exit 0)" 0 "$rc"
( cd "$GCR_T" && git checkout -- CHANGELOG.md )

# --- regression: an uncommitted CHANGELOG.md edit ALONGSIDE a real
# uncommitted code edit must still invalidate the pass -- the real change
# is what matters, not merely "CHANGELOG.md happened to also be touched". --
echo "local dirty regenerate 2" > "$GCR_T/CHANGELOG.md"
echo "echo more real code" >> "$GCR_T/real-code.sh"
out="$(cd "$GCR_T" && bash "$PLUGIN/scripts/gate-preflight.sh" 2>&1)"; rc=$?
check_rc "uncommitted CHANGELOG.md + real code edit together: exit 2 (stale)" 2 "$rc"
( cd "$GCR_T" && git checkout -- CHANGELOG.md real-code.sh )

rm -rf "$GCR_T"

# =============================================================================
# Round-2 review (REQUEST_CHANGES): two gaps in the fingerprint fix itself.
# =============================================================================

# --- LOW: CHANGELOG.md was missing from the untracked-file _EXCLUDED tuple,
# so in a repo where it is not yet TRACKED at all (the very first
# changelog-generate run, before anyone commits it), CREATING it showed up
# as a new untracked file and invalidated the pass -- contradicting the
# whole point of the tracked-CHANGELOG.md exclusions above. -----------------
GCR_UT="$(mktemp -d)"
( cd "$GCR_UT" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$GCR_UT/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$GCR_UT/.claude/project.json"
( cd "$GCR_UT" && git add .claude/project.json && git commit -q -m "add config" )
out="$(cd "$GCR_UT" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "untracked-CHANGELOG: gate pass recorded" "GATE PASS recorded" "$out"
echo "brand new changelog, never committed" > "$GCR_UT/CHANGELOG.md"
out="$(cd "$GCR_UT" && bash "$PLUGIN/scripts/gate-preflight.sh" 2>&1)"; rc=$?
check_rc "untracked-CHANGELOG.md creation: pass still valid (exit 0)" 0 "$rc"
rm -rf "$GCR_UT"

# --- MEDIUM: `git ls-tree` failing for ANY reason other than "no HEAD yet"
# must be FATAL (tree-state.sh exits nonzero, prints nothing), never a
# silent degrade to a stable placeholder that makes two DIFFERENT trees
# fingerprint identically. Proven with a `git` shim on PATH that fails ONLY
# on `ls-tree` (a real git version quirk or transient error would look the
# same to this script). ------------------------------------------------------
GCR_REAL_GIT="$(command -v git)"
GCR_SHIMDIR="$(mktemp -d)"
cat > "$GCR_SHIMDIR/git" <<SHIMEOF
#!/usr/bin/env bash
if [ "\$1" = "ls-tree" ]; then
    echo "shim: ls-tree deliberately fails" >&2
    exit 1
fi
exec "$GCR_REAL_GIT" "\$@"
SHIMEOF
chmod +x "$GCR_SHIMDIR/git"

GCR_M="$(mktemp -d)"
( cd "$GCR_M" && git init -q . )
echo one > "$GCR_M/a.txt"
( cd "$GCR_M" && git add a.txt && git -c user.email=t@t -c user.name=t commit -q -m one )
out_a="$(cd "$GCR_M" && PATH="$GCR_SHIMDIR:$PATH" bash "$PLUGIN/scripts/tree-state.sh" 2>/dev/null)"; rc_a=$?
check_rc "ls-tree failure: tree-state.sh exits nonzero (tree A)" 1 "$rc_a"
if [[ -z "$out_a" ]]; then
    echo "ok   ls-tree failure: no hash printed on stdout (tree A)"
else
    echo "FAIL ls-tree failure: no hash printed on stdout (tree A) (got: $out_a)"
    fails=$((fails + 1))
fi

echo two > "$GCR_M/b.txt"
( cd "$GCR_M" && git add b.txt && git -c user.email=t@t -c user.name=t commit -q -m two )
out_b="$(cd "$GCR_M" && PATH="$GCR_SHIMDIR:$PATH" bash "$PLUGIN/scripts/tree-state.sh" 2>/dev/null)"; rc_b=$?
check_rc "ls-tree failure: tree-state.sh exits nonzero (tree B, different tree)" 1 "$rc_b"
if [[ -z "$out_b" ]]; then
    echo "ok   ls-tree failure: no hash printed on stdout (tree B)"
else
    echo "FAIL ls-tree failure: no hash printed on stdout (tree B) (got: $out_b)"
    fails=$((fails + 1))
fi
# The dangerous outcome (proven live by the reviewer against the pre-fix
# code) was two DIFFERENT trees producing the SAME NON-EMPTY, plausible-
# looking hash. Both being empty (asserted above, on both sides) is the
# correct fail-loud outcome, not a repeat of that bug -- so this only
# fails if BOTH sides somehow still printed the SAME non-empty value.
if [[ -n "$out_a" && "$out_a" == "$out_b" ]]; then
    echo "FAIL ls-tree failure: two DIFFERENT trees must not degrade to the SAME non-empty stable value"
    fails=$((fails + 1))
else
    echo "ok   ls-tree failure: two different trees never produce a matching non-empty value"
fi

# gate.sh itself must refuse to record a pass when tree-state.sh fails --
# no marker written, no false "GATE PASS recorded" claim, nonzero exit.
mkdir -p "$GCR_M/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$GCR_M/.claude/project.json"
( cd "$GCR_M" && git add .claude/project.json && git -c user.email=t@t -c user.name=t commit -q -m "add config" )
out="$(cd "$GCR_M" && PATH="$GCR_SHIMDIR:$PATH" bash "$PLUGIN/scripts/gate.sh" 2>&1)"; rc=$?
check_absent "ls-tree failure: gate.sh never falsely claims a pass was recorded" "GATE PASS recorded" "$out"
if [[ "$rc" -ne 0 ]]; then
    echo "ok   ls-tree failure: gate.sh exits nonzero instead of passing blind"
else
    echo "FAIL ls-tree failure: gate.sh exits nonzero instead of passing blind (got rc=0)"
    fails=$((fails + 1))
fi
if [[ -f "$GCR_M/.claude/gate-pass" ]]; then
    echo "FAIL ls-tree failure: no marker file must be left behind"
    fails=$((fails + 1))
else
    echo "ok   ls-tree failure: no marker file left behind"
fi
rm -rf "$GCR_M" "$GCR_SHIMDIR"

# --- regression: a repo with NO CHANGELOG.md at all (most fixtures in this
# suite) behaves exactly as before -- the exclusion is a no-op when there is
# nothing to exclude, not a special case that requires the file to exist. --
GCR_NOLOG="$(mktemp -d)"
( cd "$GCR_NOLOG" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$GCR_NOLOG/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$GCR_NOLOG/.claude/project.json"
( cd "$GCR_NOLOG" && git add .claude/project.json && git commit -q -m "add config" )
out="$(cd "$GCR_NOLOG" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "no-CHANGELOG.md repo: gate pass recorded" "GATE PASS recorded" "$out"
out="$(cd "$GCR_NOLOG" && bash "$PLUGIN/scripts/gate-preflight.sh" 2>&1)"; rc=$?
check_rc "no-CHANGELOG.md repo: pass valid immediately after (exit 0)" 0 "$rc"
echo "echo x" > "$GCR_NOLOG/f.sh"
( cd "$GCR_NOLOG" && git add f.sh && git commit -q -m "add f" )
out="$(cd "$GCR_NOLOG" && bash "$PLUGIN/scripts/gate-preflight.sh" 2>&1)"; rc=$?
check_rc "no-CHANGELOG.md repo: a real change still invalidates (exit 2)" 2 "$rc"
rm -rf "$GCR_NOLOG"
