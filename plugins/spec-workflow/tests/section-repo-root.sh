#!/usr/bin/env bash
# section-repo-root.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/hookjson) and set HERE/PLUGIN/FIX/
# fails/flaky before sourcing this file. This file assumes those are already
# in scope.
#
# Covers #463: `git rev-parse --show-toplevel`, used everywhere before this
# fix, returns a LINKED WORKTREE's own path, not the main checkout -- so any
# script resolving its root that way, invoked with a worktree cwd, silently
# read/wrote the wrong (usually nonexistent) `.claude/` local-state
# directory instead of the main checkout's. This is the exact scenario
# nothing else in the suite covers: every probe below is run with a real
# `git worktree add` fixture and an explicit worktree cwd.
# shellcheck disable=SC2016  # the bash -c '...' probe bodies below are single-quoted on
# purpose -- they're expanded inside the spawned bash -c, not at this call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== shared repo-root resolver (#463) =="

RR_SH="$PLUGIN/scripts/lib/repo-root.sh"
RR_PY_DIR="$PLUGIN/scripts/lib"

_rr_realdir() { ( cd -P "$1" 2>/dev/null && pwd -P ); }

# --- fixture: a real repo with ONE linked worktree --------------------------
# The project config (.claude/project.json, needed by gate.sh/board.sh
# below) is committed to main BEFORE any worktree is created: a linked
# worktree only sees what its own branch's history has, never a main
# checkout's uncommitted/untracked working-tree files -- so config for the
# gate.sh/board.sh integration probes further down must be in place and
# committed up front, not added to $RR_MAIN afterward.
RR_MAIN="$(_rr_realdir "$(mktemp -d)")"
git -C "$RR_MAIN" init -q
git -C "$RR_MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$RR_MAIN/.claude"
echo primary-marker > "$RR_MAIN/.claude/marker-from-main"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$RR_MAIN/.claude/project.json"
git -C "$RR_MAIN" add .claude/project.json
git -C "$RR_MAIN" -c user.email=t@t -c user.name=t commit -q -m "add project config"

RR_WT_PARENT="$(_rr_realdir "$(mktemp -d)")"
RR_WT="$RR_WT_PARENT/linked-worktree"
git -C "$RR_MAIN" worktree add -q -b rr-wt-branch "$RR_WT"

# --- 1. bash resolver: cwd = the linked worktree, resolves to main ----------
out="$(cd "$RR_WT" && env -u SPEC_WORKFLOW_REPO_ROOT bash -c '
    source "$1"
    spec_workflow_repo_root
' _ "$RR_SH" 2>&1)"
check "bash: worktree cwd resolves to the main checkout" "$RR_MAIN" "$out"
check_absent "bash: worktree cwd does NOT resolve to the worktree's own path" "$RR_WT" "$out"

# --- 2. python resolver: same scenario --------------------------------------
out="$(cd "$RR_WT" && env -u SPEC_WORKFLOW_REPO_ROOT python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from repo_root import resolve_repo_root
print(resolve_repo_root())
' "$RR_PY_DIR" 2>&1)"
check "python: worktree cwd resolves to the main checkout" "$RR_MAIN" "$out"
check_absent "python: worktree cwd does NOT resolve to the worktree's own path" "$RR_WT" "$out"

# --- 3. resolution from the main checkout itself is unaffected --------------
out="$(cd "$RR_MAIN" && env -u SPEC_WORKFLOW_REPO_ROOT bash -c '
    source "$1"; spec_workflow_repo_root
' _ "$RR_SH" 2>&1)"
check "bash: main-checkout cwd resolves to itself" "$RR_MAIN" "$out"

# --- 4. $SPEC_WORKFLOW_REPO_ROOT override wins outright ---------------------
out="$(cd "$RR_WT" && SPEC_WORKFLOW_REPO_ROOT=/some/override/path bash -c '
    source "$1"; spec_workflow_repo_root
' _ "$RR_SH" 2>&1)"
check "bash: SPEC_WORKFLOW_REPO_ROOT override is honored verbatim" "/some/override/path" "$out"

# --- 5. non-git directory falls back to pwd ---------------------------------
RR_NONGIT="$(_rr_realdir "$(mktemp -d)")"
out="$(cd "$RR_NONGIT" && env -u SPEC_WORKFLOW_REPO_ROOT bash -c '
    source "$1"; spec_workflow_repo_root
' _ "$RR_SH" 2>&1)"
check "bash: non-git dir falls back to pwd" "$RR_NONGIT" "$out"

# =============================================================================
# Canonicalization (macOS pitfall found live by the ui-hub/design-registry
# lane): `--path-format=absolute --git-common-dir` returns the RESOLVED
# (physical) form, while `--show-toplevel` and a raw env-var override return
# the UNRESOLVED (logical) form -- e.g. /tmp/... vs /private/tmp/... on
# macOS, where /tmp is itself a symlink. Force the mismatch deterministically
# on ANY platform (not relying on incidental /tmp symlinking) via an
# explicit symlink, so every code path the resolver can take is proven to
# return the SAME physical form.
# =============================================================================
RR_SYMBASE="$(_rr_realdir "$(mktemp -d)")"
mkdir -p "$RR_SYMBASE/real"
ln -s "$RR_SYMBASE/real" "$RR_SYMBASE/link"
RR_VIA_LINK="$RR_SYMBASE/link"
RR_VIA_REAL_CANON="$(_rr_realdir "$RR_SYMBASE/real")"

# --- 6. $SPEC_WORKFLOW_REPO_ROOT override is canonicalized (bash + python) --
out="$(SPEC_WORKFLOW_REPO_ROOT="$RR_VIA_LINK" bash -c '
    source "$1"; spec_workflow_repo_root
' _ "$RR_SH" 2>&1)"
check "bash: symlinked override resolves to its physical form" "$RR_VIA_REAL_CANON" "$out"
check_absent "bash: symlinked override result does not keep the /link component" "/link" "$out"

out="$(SPEC_WORKFLOW_REPO_ROOT="$RR_VIA_LINK" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from repo_root import resolve_repo_root
print(resolve_repo_root())
' "$RR_PY_DIR" 2>&1)"
check "python: symlinked override resolves to its physical form" "$RR_VIA_REAL_CANON" "$out"
check_absent "python: symlinked override result does not keep the /link component" "/link" "$out"

# --- 7. a repo accessed THROUGH the symlink still resolves to the SAME
# physical root as accessing it directly -- proving the git-common-dir
# branch and a symlink-crossing cwd never disagree with each other. -------
git -C "$RR_SYMBASE/real" init -q
git -C "$RR_SYMBASE/real" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

out_direct="$(cd "$RR_SYMBASE/real" && env -u SPEC_WORKFLOW_REPO_ROOT bash -c '
    source "$1"; spec_workflow_repo_root
' _ "$RR_SH" 2>&1)"
out_via_link="$(cd "$RR_VIA_LINK" && env -u SPEC_WORKFLOW_REPO_ROOT bash -c '
    source "$1"; spec_workflow_repo_root
' _ "$RR_SH" 2>&1)"
if [[ "$out_direct" == "$out_via_link" ]]; then
    echo "ok   bash: resolving via the symlinked path matches resolving directly (byte-identical)"
else
    echo "FAIL bash: resolving via the symlinked path matches resolving directly -- direct='$out_direct' via-link='$out_via_link'"
    fails=$((fails + 1))
fi
check "bash: symlink-crossing resolution matches the physical root" "$RR_VIA_REAL_CANON" "$out_via_link"

rm -rf "$RR_SYMBASE"

# =============================================================================
# Integration: gate.sh / gate-preflight.sh / guard-board-move.sh, invoked
# with a worktree cwd, must find and correctly validate a pass gate.sh
# recorded FROM that same worktree -- reproducing the reported live bug
# ("no recorded gate pass" even though the gate is green and recorded).
# (.claude/project.json was already committed to $RR_MAIN above, before the
# worktrees were created, so both $RR_WT and $RR_WT2 see it via git history.)
# =============================================================================

# gate.sh run FROM the worktree.
out="$(cd "$RR_WT" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "gate.sh from a worktree: pass recorded" "GATE PASS recorded" "$out"

# The marker must land in the MAIN checkout's .claude/, not the worktree's
# own (nonexistent, gitignored) .claude/.
if [[ -f "$RR_MAIN/.claude/gate-pass" ]]; then
    echo "ok   gate.sh from a worktree: marker written to the main checkout's .claude/gate-pass"
else
    echo "FAIL gate.sh from a worktree: marker written to the main checkout's .claude/gate-pass"
    fails=$((fails + 1))
fi
if [[ -f "$RR_WT/.claude/gate-pass" ]]; then
    echo "FAIL gate.sh from a worktree: must NOT also write a marker under the worktree's own .claude/"
    fails=$((fails + 1))
else
    echo "ok   gate.sh from a worktree: no stray marker under the worktree's own .claude/"
fi

# gate-preflight.sh, invoked with the SAME worktree cwd, must find it and
# validate clean (exit 0, silent).
out="$(cd "$RR_WT" && bash "$PLUGIN/scripts/gate-preflight.sh" 2>&1)"; rc=$?
check_rc "gate-preflight.sh from the same worktree: exit 0" 0 "$rc"
if [[ -z "$out" ]]; then
    echo "ok   gate-preflight.sh from the same worktree: silent stdout"
else
    echo "FAIL gate-preflight.sh from the same worktree: silent stdout (got: $out)"
    fails=$((fails + 1))
fi

# guard-board-move.sh (the actual PreToolUse hook path), invoked with the
# worktree cwd, must ALLOW the move to "In review" -- this is the literal
# reported failure mode.
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$RR_WT" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "guard-board-move.sh from a worktree with a fresh pass: allowed (rc=0)" "rc=0" "$out"
check_absent "guard-board-move.sh from a worktree with a fresh pass: no BLOCKED" "BLOCKED" "$out"

# --- a SECOND, never-gated worktree must still be correctly blocked --------
# (proves the fix ties the pass to the TREE that was tested, not just "a
# pass exists somewhere under the primary root").
RR_WT2_PARENT="$(_rr_realdir "$(mktemp -d)")"
RR_WT2="$RR_WT2_PARENT/linked-worktree-2"
git -C "$RR_MAIN" worktree add -q -b rr-wt2-branch "$RR_WT2"
echo "untested change" > "$RR_WT2/untested.txt"
git -C "$RR_WT2" add untested.txt

out="$(cd "$RR_WT2" && bash "$PLUGIN/scripts/gate-preflight.sh" 2>&1)"; rc=$?
check_rc "gate-preflight.sh from an UNGATED sibling worktree: exit 2 (blocked)" 2 "$rc"
check "gate-preflight.sh from an UNGATED sibling worktree: BLOCKED (stale/mismatched fingerprint)" "BLOCKED" "$out"

out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$RR_WT2" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "guard-board-move.sh from an UNGATED sibling worktree: blocked (rc=2)" "rc=2" "$out"

# --- board.sh, invoked with a worktree cwd, writes shared board state into
# the MAIN checkout, not the worktree ------------------------------------
RR_GH="$(mktemp -d)"
cat >"$RR_GH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
    "project item-list") echo '{"items":[{"id":"ITEM_7","content":{"number":7}}]}' ;;
    "project item-edit") echo "edited" ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$RR_GH/gh"
out="$(cd "$RR_WT" && PATH="$RR_GH:$PATH" bash "$PLUGIN/scripts/board.sh" prio 7 P1 2>&1)"
if [[ -f "$RR_MAIN/.claude/board-cache.json" ]]; then
    echo "ok   board.sh from a worktree: board-cache.json written to the main checkout"
else
    echo "FAIL board.sh from a worktree: board-cache.json written to the main checkout (out: $out)"
    fails=$((fails + 1))
fi
if [[ -f "$RR_WT/.claude/board-cache.json" ]]; then
    echo "FAIL board.sh from a worktree: must NOT also write board-cache.json under the worktree's own .claude/"
    fails=$((fails + 1))
else
    echo "ok   board.sh from a worktree: no stray board-cache.json under the worktree's own .claude/"
fi

# --- ui-hub.py, invoked with a worktree cwd and NO $UI_HUB_STATE override,
# writes its state dir into the MAIN checkout, not the worktree -- the
# reported live instance: a design page asked from inside a worktree landed
# in THAT worktree, invisible to the main checkout / design registry. --------
out="$(cd "$RR_WT" && env -u UI_HUB_STATE python3 "$PLUGIN/scripts/ui-hub.py" status 2>&1)"
if [[ -d "$RR_MAIN/.claude/ui-hub" ]]; then
    echo "ok   ui-hub.py from a worktree: state dir created in the main checkout"
else
    echo "FAIL ui-hub.py from a worktree: state dir created in the main checkout (out: $out)"
    fails=$((fails + 1))
fi
if [[ -d "$RR_WT/.claude/ui-hub" ]]; then
    echo "FAIL ui-hub.py from a worktree: must NOT also create a state dir under the worktree's own .claude/"
    fails=$((fails + 1))
else
    echo "ok   ui-hub.py from a worktree: no stray state dir under the worktree's own .claude/"
fi

# A real card, asked (no server needed -- `ask` just writes files) from
# worktree A, must be VISIBLE (same inbox dir, filesystem-level -- what the
# hub server and any other consumer actually reads) to a genuinely separate
# ui-hub.py invocation made with worktree B's cwd, not just "the directory
# exists somewhere". This is the design-registry lane's exact failure mode:
# a page asked from one worktree was invisible to everything else.
echo '<h1>card from worktree A</h1>' > "$RR_WT/card-a.html"
out="$(cd "$RR_WT" && env -u UI_HUB_STATE python3 "$PLUGIN/scripts/ui-hub.py" ask card-a "Card A" "$RR_WT/card-a.html" 2>&1)"
check "ui-hub.py ask from worktree A: card accepted" "asked 'card-a'" "$out"

echo '<h1>card from worktree B</h1>' > "$RR_WT2/card-b.html"
out="$(cd "$RR_WT2" && env -u UI_HUB_STATE python3 "$PLUGIN/scripts/ui-hub.py" ask card-b "Card B" "$RR_WT2/card-b.html" 2>&1)"
check "ui-hub.py ask from sibling worktree B: card accepted" "asked 'card-b'" "$out"

if [[ -f "$RR_MAIN/.claude/ui-hub/inbox/card-a.json" && -f "$RR_MAIN/.claude/ui-hub/inbox/card-b.json" ]]; then
    echo "ok   ui-hub.py: cards asked from TWO DIFFERENT worktrees both land in the SAME primary-root inbox (cross-worktree visibility)"
else
    echo "FAIL ui-hub.py: cards asked from TWO DIFFERENT worktrees both land in the SAME primary-root inbox (cross-worktree visibility)"
    fails=$((fails + 1))
fi
if [[ -f "$RR_WT/.claude/ui-hub/inbox/card-a.json" || -f "$RR_WT2/.claude/ui-hub/inbox/card-b.json" ]]; then
    echo "FAIL ui-hub.py: no card must be siloed under either worktree's own .claude/ui-hub/"
    fails=$((fails + 1))
else
    echo "ok   ui-hub.py: no card siloed under either worktree's own .claude/ui-hub/"
fi

# --- neural-view.py, invoked with a worktree cwd and NO $NEURAL_VIEW_STATE
# override, writes its state dir (pid/port/repos.json, and the assistant
# machine-local default it stores on default_store's behalf) into the MAIN
# checkout, not the worktree -- same silent-invisibility bug class as
# ui-hub.py above, exercised via `assistant default NAME`, which writes
# through default_store.write_default(state_dir=str(S)) with no server
# needed. ------------------------------------------------------------------
out="$(cd "$RR_WT" && env -u NEURAL_VIEW_STATE python3 "$PLUGIN/scripts/neural-view.py" assistant default rr-nv-assistant 2>&1)"
if [[ -f "$RR_MAIN/.claude/neural-view/assistant-default" ]]; then
    echo "ok   neural-view.py from a worktree: assistant-default written to the main checkout"
else
    echo "FAIL neural-view.py from a worktree: assistant-default written to the main checkout (out: $out)"
    fails=$((fails + 1))
fi
if [[ -f "$RR_WT/.claude/neural-view/assistant-default" ]]; then
    echo "FAIL neural-view.py from a worktree: must NOT also write assistant-default under the worktree's own .claude/"
    fails=$((fails + 1))
else
    echo "ok   neural-view.py from a worktree: no stray assistant-default under the worktree's own .claude/"
fi

# --- assistant/default_store.py's own bare CLI (no --state-dir, no
# $NEURAL_VIEW_STATE), invoked with a worktree cwd, must resolve the SAME
# primary-root state dir neural-view.py's `S` resolves to -- it is
# documented to mirror neural-view.py's state_dir() exactly. -----------------
out="$(cd "$RR_WT" && env -u NEURAL_VIEW_STATE python3 "$PLUGIN/scripts/assistant/default_store.py" write-default rr-cli-assistant 2>&1)"
check "default_store.py CLI from a worktree: writes under the main checkout's .claude/neural-view" "$RR_MAIN/.claude/neural-view/assistant-default" "$out"
if [[ -f "$RR_WT/.claude/neural-view/assistant-default" ]]; then
    echo "FAIL default_store.py CLI from a worktree: must NOT also write under the worktree's own .claude/"
    fails=$((fails + 1))
else
    echo "ok   default_store.py CLI from a worktree: no stray assistant-default under the worktree's own .claude/"
fi

git -C "$RR_MAIN" worktree remove -f "$RR_WT" >/dev/null 2>&1 || true
git -C "$RR_MAIN" worktree remove -f "$RR_WT2" >/dev/null 2>&1 || true
rm -rf "$RR_MAIN" "$RR_WT_PARENT" "$RR_WT2_PARENT" "$RR_NONGIT" "$RR_GH"
