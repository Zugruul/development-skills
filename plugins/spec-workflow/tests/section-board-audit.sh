#!/usr/bin/env bash
# section-board-audit.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# Covers issue #76's `board.sh audit`: reconciles board reality vs the repo —
# open PRs missing a board-issue reference, branches matching
# project.branchPattern with no In-progress item, In-progress items with no
# matching branch, and (work.type: local only) recently-merged main commits
# whose subject lacks a #N reference, excluding the recognized orchestrator
# process-commit classes (retro(, spec(, feedback(, config:) -- which are
# still enumerated (counted), never silently hidden. Fake gh understands
# `project item-list` and `pr list` only.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== board.sh audit (#76) =="

_asetup() { # -> sets AQ (fixture repo dir) and FGH (fake-gh dir on PATH)
    AQ="$(mktemp -d)"
    ( cd "$AQ" && git init -q . && git commit -q --allow-empty -m "init #0" && git branch -m main )
    mkdir -p "$AQ/.claude"
    cp "$FIX/valid.project.yaml" "$AQ/.claude/project.yaml"
    FGH="$(mktemp -d)"
    cat >"$FGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
# Defaults are assigned via a plain if (not ${VAR:-default}) because the
# JSON defaults contain unescaped "}" -- bash's ${VAR:-...} brace matching
# doesn't parse those correctly and silently corrupts the output.
items_json="${FAKE_GH_ITEMS_JSON:-}"
[[ -z "$items_json" ]] && items_json='{"items":[]}'
prs_json="${FAKE_GH_PRS_JSON:-}"
[[ -z "$prs_json" ]] && prs_json='[]'
case "$1 $2" in
    "project item-list")
        printf '%s' "$items_json"
        ;;
    "pr list")
        printf '%s' "$prs_json"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
    chmod +x "$FGH/gh"
}

audit() { (cd "$AQ" && PATH="$FGH:$PATH" bash "$PLUGIN/scripts/board.sh" audit 2>&1; echo "rc=$?"); }

# --- (a) clean: no open PRs, one In-progress item with a matching local branch ---
_asetup
( cd "$AQ" && git branch fx/10-widget )
export FAKE_GH_ITEMS_JSON='{"items":[{"status":"In progress","content":{"number":10}}]}'
export FAKE_GH_PRS_JSON='[]'
out="$(audit)"
check "(a) clean report" "AUDIT: clean" "$out"
check "(a) exit 0" "rc=0" "$out"
unset FAKE_GH_ITEMS_JSON FAKE_GH_PRS_JSON
rm -rf "$AQ" "$FGH"

# --- (b) open PR without a board-issue reference in its body -> discrepancy ---
_asetup
( cd "$AQ" && git branch fx/10-widget )
export FAKE_GH_ITEMS_JSON='{"items":[{"status":"In progress","content":{"number":10}}]}'
export FAKE_GH_PRS_JSON='[{"number":5,"body":"just a change, no ticket"}]'
out="$(audit)"
check "(b) flags PR missing a board-issue reference" "DISCREPANCY: open PR" "$out"
check "(b) names the PR number" "#5" "$out"
check "(b) exits 1" "rc=1" "$out"
unset FAKE_GH_ITEMS_JSON FAKE_GH_PRS_JSON
rm -rf "$AQ" "$FGH"

# --- (c) a branchPattern-matching branch with no In-progress item -> discrepancy ---
_asetup
( cd "$AQ" && git branch fx/11-orphan )
export FAKE_GH_ITEMS_JSON='{"items":[]}'
export FAKE_GH_PRS_JSON='[]'
out="$(audit)"
check "(c) flags an orphan branch" "DISCREPANCY: branch" "$out"
check "(c) names the orphan branch" "fx/11-orphan" "$out"
check "(c) exits 1" "rc=1" "$out"
unset FAKE_GH_ITEMS_JSON FAKE_GH_PRS_JSON
rm -rf "$AQ" "$FGH"

# --- (d) an In-progress item with no matching local branch -> discrepancy ---
_asetup
export FAKE_GH_ITEMS_JSON='{"items":[{"status":"In progress","content":{"number":12}}]}'
export FAKE_GH_PRS_JSON='[]'
out="$(audit)"
check "(d) flags an In-progress item with no branch" "DISCREPANCY: In-progress board item" "$out"
check "(d) names the issue number" "#12" "$out"
check "(d) exits 1" "rc=1" "$out"
unset FAKE_GH_ITEMS_JSON FAKE_GH_PRS_JSON
rm -rf "$AQ" "$FGH"

# --- (e) work.type: local -- merged-main commit-subject scan, process classes exempt but enumerated ---
_asetup
python3 "$PLUGIN/scripts/config.py" "$AQ" set work.type '"local"' >/dev/null
( cd "$AQ" &&
    git commit -q --allow-empty -m "retro(#1): mint a note" &&
    git commit -q --allow-empty -m "spec(sw-1): fold delta" &&
    git commit -q --allow-empty -m "feedback(#1 iteration): triage" &&
    git commit -q --allow-empty -m "config: bump something" &&
    git commit -q --allow-empty -m "feat(sw-42): add a feature #42" &&
    git commit -q --allow-empty -m "fix a bug with no ticket ref" )
export FAKE_GH_ITEMS_JSON='{"items":[]}'
export FAKE_GH_PRS_JSON='[]'
out="$(audit)"
check "(e) flags the unreferenced commit subject" "DISCREPANCY: merged main commit" "$out"
check "(e) names the offending commit subject" "fix a bug with no ticket ref" "$out"
check_absent "(e) the #N-referenced commit is not flagged" "add a feature #42" "$(grep DISCREPANCY <<<"$out")"
check "(e) enumerates the retro( process class" "retro( (1)" "$out"
check "(e) enumerates the spec( process class" "spec( (1)" "$out"
check "(e) enumerates the feedback( process class" "feedback( (1)" "$out"
check "(e) enumerates the config: process class" "config: (1)" "$out"
check "(e) review round 1: states the commit-scan window unconditionally" "commit scan window: last 200 commits" "$out"
check "(e) exits 1" "rc=1" "$out"
unset FAKE_GH_ITEMS_JSON FAKE_GH_PRS_JSON
rm -rf "$AQ" "$FGH"

# --- (f) work.type: local, all commits clean -> no commit-subject discrepancy ---
_asetup
python3 "$PLUGIN/scripts/config.py" "$AQ" set work.type '"local"' >/dev/null
( cd "$AQ" && git commit -q --allow-empty -m "feat(sw-42): add a feature #42" )
export FAKE_GH_ITEMS_JSON='{"items":[]}'
export FAKE_GH_PRS_JSON='[]'
out="$(audit)"
check "(f) clean local-mode commit history reports clean" "AUDIT: clean" "$out"
check "(f) review round 1: scan-window note printed even when clean (never silent about the cap)" "commit scan window: last 200 commits" "$out"
check "(f) exits 0" "rc=0" "$out"
unset FAKE_GH_ITEMS_JSON FAKE_GH_PRS_JSON
rm -rf "$AQ" "$FGH"

# --- (g) work.type: pr (default) never runs the commit-subject scan ---
_asetup
( cd "$AQ" && git branch fx/10-widget && git commit -q --allow-empty -m "some commit with no ref at all" )
export FAKE_GH_ITEMS_JSON='{"items":[{"status":"In progress","content":{"number":10}}]}'
export FAKE_GH_PRS_JSON='[]'
out="$(audit)"
check "(g) pr-mode: no commit-subject discrepancy" "AUDIT: clean" "$out"
check_absent "(g) pr-mode: no scan-window note (commit scan doesn't run outside work.type: local)" "commit scan window" "$out"
check "(g) exits 0" "rc=0" "$out"
unset FAKE_GH_ITEMS_JSON FAKE_GH_PRS_JSON
rm -rf "$AQ" "$FGH"
