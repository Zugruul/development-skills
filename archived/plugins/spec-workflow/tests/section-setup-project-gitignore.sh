#!/usr/bin/env bash
# section-setup-project-gitignore.sh — MEM-012: setup-project's Phase 5
# gitignore step calls scripts/gitignore-sync.sh (the managed-block writer,
# MEM-011) instead of a raw `>> .gitignore` append, so re-running setup on an
# already-configured repo is idempotent and warns instead of clobbering a
# conflicting track-path rule (SPEC-MEMORY.md §7.2/§7.4). Sourced by
# run-tests.sh (uses $PLUGIN, check*, $fails).
# shellcheck shell=bash
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== setup-project-gitignore =="

SPG_SKILL="$PLUGIN/skills/setup-project/SKILL.md"
SPG_README="$PLUGIN/README.md"
SPG_SCRIPT="$PLUGIN/scripts/gitignore-sync.sh"
SPG_LIB="$PLUGIN/scripts/lib/local-state.sh"
SPG_START="# >>> spec-workflow managed"

# --- SKILL.md: Phase 5 calls gitignore-sync.sh, the raw append is gone ------
spg_phase5="$(awk '/^## Phase 5/{f=1} /^## Phase 6/{f=0} f' "$SPG_SKILL")"
check "setup-project SKILL.md Phase 5 calls gitignore-sync.sh" "gitignore-sync.sh" "$spg_phase5"
check_absent "setup-project SKILL.md Phase 5 no longer raw-appends to .gitignore" \
    ">> .gitignore" "$spg_phase5"

# --- README.md documents the script (docs[] in sync, per project.yaml) -----
check "plugin README documents gitignore-sync.sh" "gitignore-sync.sh" "$(cat "$SPG_README" 2>/dev/null)"

# --- consumer-repo fixture: run the script the way SKILL.md now prescribes -
SPG_EXP_IGNORE="$(bash -c '. "$1" 2>/dev/null && spec_workflow_local_state_paths ignore' _ "$SPG_LIB" 2>/dev/null)"

spg_d="$(mktemp -d)"
# a pre-existing consumer repo already has some of its own ignore rules
printf '%s\n' "node_modules/" "dist/" > "$spg_d/.gitignore"
(cd "$spg_d" && bash "$SPG_SCRIPT" .gitignore) >/dev/null 2>&1
spg_content="$(cat "$spg_d/.gitignore" 2>/dev/null)"
check "setup-project fixture: managed block written" "$SPG_START" "$spg_content"
check "setup-project fixture: user rule preserved" "node_modules/" "$spg_content"
spg_body="$(awk -v s="$SPG_START" -v e="# <<< spec-workflow managed" '$0==s{f=1;next} $0==e{f=0} f' "$spg_d/.gitignore" 2>/dev/null)"
[[ "$spg_body" == "$SPG_EXP_IGNORE" ]] && r=EQUAL || r=DIFFER
check "setup-project fixture: block body equals manifest ignore list" "EQUAL" "$r"

# re-running setup-project on an already-configured repo must be a no-op
cp "$spg_d/.gitignore" "$spg_d/after1"
(cd "$spg_d" && bash "$SPG_SCRIPT" .gitignore) >/dev/null 2>&1
cmp -s "$spg_d/after1" "$spg_d/.gitignore" && r=SAME || r=DIFF
check "setup-project fixture: re-running setup is idempotent" "SAME" "$r"
rm -rf "$spg_d"
