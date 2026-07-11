#!/usr/bin/env bash
# section-work-mode.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope. Covers #79: work.type (PR-less local delivery)
# + work.sync (board-sync batching policy) — config accessors, validator,
# schema lint, work-mode.sh's should-sync matrix, and skill-doc wiring.

declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== config.py: work.type / work.sync.mode accessors (defaults) =="
WT="$(mktemp -d)"; mkdir -p "$WT/.claude"
cp "$FIX/valid.project.yaml" "$WT/.claude/project.yaml"
wjget() { python3 "$PLUGIN/scripts/config.py" "$WT" get "$1"; }
check "work.type defaults to pr when work absent" "pr" "$(wjget work.type)"
check "work.sync.mode defaults to realtime when work absent" "realtime" "$(wjget work.sync.mode)"
python3 "$PLUGIN/scripts/config.py" "$WT" set work.type '"local"' >/dev/null
check "work.type reads back local" "local" "$(wjget work.type)"
check "work.sync.mode still defaults to realtime (sync absent under local)" "realtime" "$(wjget work.sync.mode)"
python3 "$PLUGIN/scripts/config.py" "$WT" set work.sync.mode '"task-close"' >/dev/null
check "work.sync.mode reads back task-close" "task-close" "$(wjget work.sync.mode)"
rm -rf "$WT"

WN="$(mktemp -d)"  # no config file at all -> pure bash-side defaults via work-mode.sh
check "config.py get work.type with no config file at all is empty (script-side default applies)" "" "$(python3 "$PLUGIN/scripts/config.py" "$WN" get work.type 2>/dev/null || true)"
rm -rf "$WN"

echo "== validate-config: work.type / work.sync =="
VW="$(mktemp -d)"; mkdir -p "$VW/.claude"
cp "$FIX/valid.project.yaml" "$VW/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$VW" set work.type '"local"' >/dev/null
python3 "$PLUGIN/scripts/config.py" "$VW" set work.sync.mode '"task-close"' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$VW/.claude/project.yaml")"
check "valid work.type local + work.sync.mode task-close passes" "VALID: " "$out"

# sync rejected under type: pr (the default)
VP="$(mktemp -d)"; mkdir -p "$VP/.claude"
cp "$FIX/valid.project.yaml" "$VP/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$VP" set work.sync.mode '"manual"' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$VP/.claude/project.yaml" || true)"
check "work.sync under (default) type: pr is rejected" "work.sync is only valid with work.type: local" "$out"
rm -rf "$VP"

# sync rejected under explicit type: pr
VP2="$(mktemp -d)"; mkdir -p "$VP2/.claude"
cp "$FIX/valid.project.yaml" "$VP2/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$VP2" set work.type '"pr"' >/dev/null
python3 "$PLUGIN/scripts/config.py" "$VP2" set work.sync.mode '"realtime"' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$VP2/.claude/project.yaml" || true)"
check "work.sync under explicit type: pr is rejected" "work.sync is only valid with work.type: local" "$out"
rm -rf "$VP2"

# invalid work.type enum
VE="$(mktemp -d)"; mkdir -p "$VE/.claude"
cp "$FIX/valid.project.yaml" "$VE/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$VE" set work.type '"branch"' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$VE/.claude/project.yaml" || true)"
check "work.type invalid enum rejected" "work.type must be 'pr' or 'local'" "$out"
rm -rf "$VE"

# invalid work.sync.mode enum
VM="$(mktemp -d)"; mkdir -p "$VM/.claude"
cp "$FIX/valid.project.yaml" "$VM/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$VM" set work.type '"local"' >/dev/null
python3 "$PLUGIN/scripts/config.py" "$VM" set work.sync.mode '"nightly"' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$VM/.claude/project.yaml" || true)"
check "work.sync.mode invalid enum rejected" "work.sync.mode must be one of realtime, task-close, session-end, manual" "$out"
rm -rf "$VM"

# unknown key under work
VU="$(mktemp -d)"; mkdir -p "$VU/.claude"
cp "$FIX/valid.project.yaml" "$VU/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$VU" set work.type '"local"' >/dev/null
python3 "$PLUGIN/scripts/config.py" "$VU" set work.autoApprove 'true' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$VU/.claude/project.yaml" || true)"
check "unknown key under work rejected" "work.autoApprove: unknown key" "$out"
rm -rf "$VU"

# unknown key under work.sync
VUS="$(mktemp -d)"; mkdir -p "$VUS/.claude"
cp "$FIX/valid.project.yaml" "$VUS/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$VUS" set work.type '"local"' >/dev/null
python3 "$PLUGIN/scripts/config.py" "$VUS" set work.sync.interval '30' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$VUS/.claude/project.yaml" || true)"
check "unknown key under work.sync rejected" "work.sync.interval: unknown key" "$out"
rm -rf "$VUS"

# this repo's own config (work: {type: local, sync: {mode: task-close}}) validates
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$PLUGIN/../../.claude/project.yaml" 2>&1 || true)"
check "this repo's own project.yaml (work: local/task-close) validates" "VALID: " "$out"

# Schema hover-completeness (description/enumDescriptions/defaults) for the
# WHOLE schema -- including work.* -- is asserted once, generally, by
# section-schema-lint.sh's schema-lint.py walk. Keeping a second, work.*-only
# copy of that check here would just be a duplicate canonical checker (#80).

echo "== work-mode.sh: type / sync-mode =="
WM="$(mktemp -d)"; mkdir -p "$WM/.claude"
cp "$FIX/valid.project.yaml" "$WM/.claude/project.yaml"
wm() { (cd "$WM" && bash "$PLUGIN/scripts/work-mode.sh" "$@"); }
check "work-mode.sh type defaults to pr" "pr" "$(wm type)"
check "work-mode.sh sync-mode defaults to realtime" "realtime" "$(wm sync-mode)"
python3 "$PLUGIN/scripts/config.py" "$WM" set work.type '"local"' >/dev/null
check "work-mode.sh type reflects local" "local" "$(wm type)"

echo "== work-mode.sh: should-sync matrix (4 modes x 5 events, safety valve) =="
# Safety valve: blocked/new-item are ALWAYS 'now', in every mode.
for mode in realtime task-close session-end manual; do
    python3 "$PLUGIN/scripts/config.py" "$WM" set work.sync.mode "\"$mode\"" >/dev/null
    check "should-sync[$mode][blocked] = now (safety valve)" "now" "$(wm should-sync blocked)"
    check "should-sync[$mode][new-item] = now (safety valve)" "now" "$(wm should-sync new-item)"
done

python3 "$PLUGIN/scripts/config.py" "$WM" set work.sync.mode '"realtime"' >/dev/null
check "should-sync[realtime][transition] = now" "now" "$(wm should-sync transition)"
check "should-sync[realtime][task-close] = now" "now" "$(wm should-sync task-close)"
check "should-sync[realtime][session-end] = now" "now" "$(wm should-sync session-end)"

python3 "$PLUGIN/scripts/config.py" "$WM" set work.sync.mode '"task-close"' >/dev/null
check "should-sync[task-close][transition] = defer" "defer" "$(wm should-sync transition)"
check "should-sync[task-close][task-close] = now" "now" "$(wm should-sync task-close)"
check "should-sync[task-close][session-end] = defer" "defer" "$(wm should-sync session-end)"

python3 "$PLUGIN/scripts/config.py" "$WM" set work.sync.mode '"session-end"' >/dev/null
check "should-sync[session-end][transition] = defer" "defer" "$(wm should-sync transition)"
check "should-sync[session-end][task-close] = defer" "defer" "$(wm should-sync task-close)"
check "should-sync[session-end][session-end] = now" "now" "$(wm should-sync session-end)"

python3 "$PLUGIN/scripts/config.py" "$WM" set work.sync.mode '"manual"' >/dev/null
check "should-sync[manual][transition] = defer" "defer" "$(wm should-sync transition)"
check "should-sync[manual][task-close] = defer" "defer" "$(wm should-sync task-close)"
check "should-sync[manual][session-end] = defer" "defer" "$(wm should-sync session-end)"

out="$(wm should-sync bogus-event 2>&1)"; rc=$?
check "should-sync rejects an unknown event" "usage:" "$out"
check_rc "should-sync unknown event exit code" 2 "$rc"
rm -rf "$WM"

WD="$(mktemp -d)"  # no config file at all: pure defaults
wd() { (cd "$WD" && bash "$PLUGIN/scripts/work-mode.sh" "$@"); }
check "work-mode.sh type defaults to pr with no config file" "pr" "$(wd type)"
check "work-mode.sh sync-mode defaults to realtime with no config file" "realtime" "$(wd sync-mode)"
check "work-mode.sh should-sync defaults realtime (transition = now) with no config file" "now" "$(wd should-sync transition)"
rm -rf "$WD"

echo "== skill docs: work.type governs delivery / work.sync governs WHEN (#79) =="
ITSKILL="$(cat "$PLUGIN/skills/implement-task/SKILL.md" 2>/dev/null)"
check "implement-task SKILL.md: work.type governs delivery" "work.type governs delivery" "$ITSKILL"
check "implement-task SKILL.md: local mode approval recorded as an issue comment" "approval recorded as an ISSUE comment" "$ITSKILL"
check "implement-task SKILL.md: local mode squash-merges locally" "squash-merges locally" "$ITSKILL"

BNSKILL2="$(cat "$PLUGIN/skills/build-next/SKILL.md" 2>/dev/null)"
check "build-next SKILL.md: work.type governs delivery" "work.type governs delivery" "$BNSKILL2"
check "build-next SKILL.md: work.sync governs WHEN board mutations happen" "work.sync governs WHEN board mutations happen" "$BNSKILL2"
check "build-next SKILL.md: safety valve named" "SAFETY VALVE" "$BNSKILL2"
check "build-next SKILL.md: autoMerge false + local leaves branch unmerged for the human" "leave the branch unmerged at In review for the human" "$BNSKILL2"

ARBODY2="$(cat "$PLUGIN/skills/build-next/references/auto-review.md" 2>/dev/null)"
check "auto-review.md: local mode board announce carries the merge SHA" "board announce carries the merge SHA" "$ARBODY2"
check "auto-review.md: work-mode.sh names the deferral helper" "work-mode.sh" "$ARBODY2"
