#!/usr/bin/env bash
# section-gitignore-sync.sh — MEM-011: scripts/gitignore-sync.sh writes the
# manifest's `ignore`-policy paths into a target .gitignore as a managed block
# (SPEC-MEMORY.md §7.2/§7.2.1), replacing only the block, appending if absent,
# never touching lines outside the markers, warning when a `track` path is
# ignored by a non-managed rule, and supporting --dry-run. Sourced by
# run-tests.sh (uses $PLUGIN, check*, $fails).
# shellcheck shell=bash
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== gitignore-sync =="

GS_SCRIPT="$PLUGIN/scripts/gitignore-sync.sh"
GS_LIB="$PLUGIN/scripts/lib/local-state.sh"
GS_START="# >>> spec-workflow managed"
GS_END="# <<< spec-workflow managed"

# The block's body is exactly the manifest's ignore list, in manifest order —
# derived from the lib so this test tracks the single source of truth.
GS_EXP_IGNORE="$(bash -c '. "$1" 2>/dev/null && spec_workflow_local_state_paths ignore' _ "$GS_LIB" 2>/dev/null)"

# --- forward-looking fix from MEM-010's reviewer: sourcing local-state.sh must
# NOT leak nounset/pipefail into the caller (gitignore-sync.sh is the first real
# sourcing caller). `set +o` prints "set +o nounset" when OFF, "set -o nounset"
# when ON; we start with both OFF and assert they stay OFF after the source.
gs_opts="$(bash -c 'set +u +o pipefail 2>/dev/null; . "$1" >/dev/null 2>&1; set +o' _ "$GS_LIB" 2>/dev/null)"
grep -q "set +o nounset" <<<"$gs_opts" && r=OFF || r=ON
check "gitignore-sync: sourcing local-state does not leak nounset" "OFF" "$r"
grep -q "set +o pipefail" <<<"$gs_opts" && r=OFF || r=ON
check "gitignore-sync: sourcing local-state does not leak pipefail" "OFF" "$r"

# --- 1. fresh repo (no .gitignore) — creates one with just the block ---------
gs_d="$(mktemp -d)"; gs_gi="$gs_d/.gitignore"
bash "$GS_SCRIPT" "$gs_gi" >/dev/null 2>&1
[[ -f "$gs_gi" ]] && r=yes || r=no
check "gitignore-sync: fresh repo creates .gitignore" "yes" "$r"
gs_content="$(cat "$gs_gi" 2>/dev/null)"
check "gitignore-sync: fresh has start marker" "$GS_START" "$gs_content"
check "gitignore-sync: fresh has end marker" "$GS_END" "$gs_content"
check "gitignore-sync: fresh has an ignore path" ".claude/CHECKPOINT" "$gs_content"
check "gitignore-sync: fresh first line is start marker" "$GS_START" "$(head -1 "$gs_gi" 2>/dev/null)"
# body equals the manifest ignore list exactly (block interior, marker-stripped)
gs_body="$(awk -v s="$GS_START" -v e="$GS_END" '$0==s{f=1;next} $0==e{f=0} f' "$gs_gi" 2>/dev/null)"
[[ "$gs_body" == "$GS_EXP_IGNORE" ]] && r=EQUAL || r=DIFFER
check "gitignore-sync: fresh block body equals manifest ignore list" "EQUAL" "$r"
# a clean run (no track path ignored) emits no warning
gs_warn="$(bash "$GS_SCRIPT" "$gs_d/second.gitignore" 2>&1 >/dev/null)"
check_absent "gitignore-sync: clean run emits no WARNING" "WARNING" "$gs_warn"
rm -rf "$gs_d"

# --- 2. existing .gitignore WITHOUT block — append, preserve content --------
gs_d="$(mktemp -d)"; gs_gi="$gs_d/.gitignore"
printf '%s\n' "node_modules/" "*.log" "dist/" > "$gs_gi"
cp "$gs_gi" "$gs_d/orig"
bash "$GS_SCRIPT" "$gs_gi" >/dev/null 2>&1
gs_content="$(cat "$gs_gi" 2>/dev/null)"
check "gitignore-sync: append preserves user line node_modules" "node_modules/" "$gs_content"
check "gitignore-sync: append preserves user line *.log" "*.log" "$gs_content"
check "gitignore-sync: append adds the managed block" "$GS_START" "$gs_content"
# the original content is a byte-identical prefix of the result
awk -v s="$GS_START" '$0==s{exit} {print}' "$gs_gi" > "$gs_d/prefix.out"
cmp -s "$gs_d/orig" "$gs_d/prefix.out" && r=SAME || r=DIFF
check "gitignore-sync: append leaves original content byte-identical prefix" "SAME" "$r"
rm -rf "$gs_d"

# --- 3 & 4. stale block — replace only, user lines above/below byte-identical -
gs_d="$(mktemp -d)"; gs_gi="$gs_d/.gitignore"
{
    printf '%s\n' "# my header" "keepme/" "*.tmp"
    printf '%s\n' "$GS_START" ".claude/OBSOLETE-STALE" "$GS_END"
    printf '%s\n' "trailer-dir/" "# footer line"
} > "$gs_gi"
printf '%s\n' "# my header" "keepme/" "*.tmp" > "$gs_d/above.golden"
printf '%s\n' "trailer-dir/" "# footer line" > "$gs_d/below.golden"
bash "$GS_SCRIPT" "$gs_gi" >/dev/null 2>&1
awk -v s="$GS_START" '$0==s{exit} {print}' "$gs_gi" > "$gs_d/above.out"
awk -v e="$GS_END" 'f{print} $0==e{f=1}' "$gs_gi" > "$gs_d/below.out"
cmp -s "$gs_d/above.golden" "$gs_d/above.out" && r=SAME || r=DIFF
check "gitignore-sync: lines above block preserved byte-identically" "SAME" "$r"
cmp -s "$gs_d/below.golden" "$gs_d/below.out" && r=SAME || r=DIFF
check "gitignore-sync: lines below block preserved byte-identically" "SAME" "$r"
gs_content="$(cat "$gs_gi" 2>/dev/null)"
check_absent "gitignore-sync: stale block content removed" ".claude/OBSOLETE-STALE" "$gs_content"
check "gitignore-sync: fresh ignore path written into block" ".claude/CHECKPOINT" "$gs_content"
gs_body="$(awk -v s="$GS_START" -v e="$GS_END" '$0==s{f=1;next} $0==e{f=0} f' "$gs_gi" 2>/dev/null)"
[[ "$gs_body" == "$GS_EXP_IGNORE" ]] && r=EQUAL || r=DIFFER
check "gitignore-sync: replaced block body equals manifest ignore list" "EQUAL" "$r"
rm -rf "$gs_d"

# --- 5. track-path warning fires on this repo's feedbacks rule ---------------
gs_d="$(mktemp -d)"; gs_gi="$gs_d/.gitignore"
printf '%s\n' ".claude/feedbacks/" > "$gs_gi"
gs_warn="$(bash "$GS_SCRIPT" "$gs_gi" 2>&1 >/dev/null)"
check "gitignore-sync: track warning names the feedbacks path" ".claude/feedbacks/" "$gs_warn"
check "gitignore-sync: track warning is flagged WARNING" "WARNING" "$gs_warn"
# the block is still written normally despite the warning (rc 0, not an error)
bash "$GS_SCRIPT" "$gs_gi" >/dev/null 2>&1
check_rc "gitignore-sync: warning does not fail the run" 0 "$?"
check "gitignore-sync: block still written alongside warning" "$GS_START" "$(cat "$gs_gi" 2>/dev/null)"
rm -rf "$gs_d"

# --- 6. --dry-run makes zero writes -----------------------------------------
gs_d="$(mktemp -d)"; gs_gi="$gs_d/.gitignore"
printf '%s\n' "keepme/" > "$gs_gi"
gs_h1="$(cksum < "$gs_gi")"
gs_out="$(bash "$GS_SCRIPT" --dry-run "$gs_gi" 2>/dev/null)"
gs_h2="$(cksum < "$gs_gi")"
[[ "$gs_h1" == "$gs_h2" ]] && r=UNCHANGED || r=CHANGED
check "gitignore-sync: --dry-run writes nothing to the file" "UNCHANGED" "$r"
check "gitignore-sync: --dry-run prints the would-be block" "$GS_START" "$gs_out"
# dry-run on a fresh (missing) target also writes nothing
gs_out="$(bash "$GS_SCRIPT" --dry-run "$gs_d/nope.gitignore" 2>/dev/null)"
[[ -e "$gs_d/nope.gitignore" ]] && r=CREATED || r=ABSENT
check "gitignore-sync: --dry-run does not create a missing target" "ABSENT" "$r"
rm -rf "$gs_d"

# --- 7. idempotent second run -----------------------------------------------
gs_d="$(mktemp -d)"; gs_gi="$gs_d/.gitignore"
printf '%s\n' "keepme/" "# tail comment" > "$gs_gi"
bash "$GS_SCRIPT" "$gs_gi" >/dev/null 2>&1
cp "$gs_gi" "$gs_d/after1"
bash "$GS_SCRIPT" "$gs_gi" >/dev/null 2>&1
cmp -s "$gs_d/after1" "$gs_gi" && r=SAME || r=DIFF
check "gitignore-sync: second run is byte-identical (idempotent)" "SAME" "$r"
rm -rf "$gs_d"

# --- 8. self-check: THIS repo's own root .gitignore has zero drift from
# local-state.manifest (issue #468). The real bug behind that issue was never
# a wrong manifest entry -- gitignore-sync.sh only ever runs once, during a
# NEW repo's setup-project bootstrap (or a target repo's setup-assistant/
# sync-configs pass); nothing re-syncs an ALREADY-bootstrapped repo's
# .gitignore when local-state.manifest later gains new ignore entries, so
# this repo's own committed .gitignore silently fell behind its own
# manifest (missing .claude/assistant/, .claude/skills/whisper-sidecar/,
# .claude/merge-dance.lock/ at the time of discovery). This check is the
# fix for "tomorrow": since it runs in the SAME plugin-tests CI step every
# manifest/gitignore change already goes through, any future manifest
# addition landed without a paired .gitignore sync now fails CI here
# instead of drifting silently again.
GS_REPO_ROOT="$(cd "$PLUGIN/../.." && pwd)"
gs_self_diff="$(bash "$GS_SCRIPT" --dry-run "$GS_REPO_ROOT/.gitignore" 2>&1)"
[[ -z "$gs_self_diff" ]] && r=CLEAN || r=DRIFTED
check "gitignore-sync: this repo's own root .gitignore has zero drift from local-state.manifest" "CLEAN" "$r"
