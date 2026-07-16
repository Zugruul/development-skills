#!/usr/bin/env bash
# section-local-state-manifest.sh — MEM-010: the canonical local-state manifest
# (scripts/local-state.manifest) and its bash + python parse helpers are the
# single source of truth (SPEC-MEMORY.md §7.1/§7.4/§9.2) for which
# plugin-written runtime paths are gitignored local state vs tracked shared
# memory. Sourced by run-tests.sh (uses $PLUGIN, check*, $fails).
# shellcheck shell=bash
# shellcheck disable=SC2016  # $-expansions inside python/bash -c bodies are intentional
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }

LS_MANIFEST="$PLUGIN/scripts/local-state.manifest"
LS_LIB="$PLUGIN/scripts/lib/local-state.sh"
# The python helper (scripts/lib/local_state.py) is imported by module name via
# sys.path below, not through a path variable.

# Expected policy → ordered paths, straight from SPEC-MEMORY.md §7.1 (+ §9.2
# index folded in as ignore). This test file is the executable spec: the
# manifest and both parsers must agree with these lists exactly.
LS_EXP_IGNORE="$(printf '%s\n' \
    '.claude/CHECKPOINT' \
    '.claude/ITERATIVE_UI_OFF' \
    '.claude/ui-hub/' \
    '.claude/gate-pass' \
    '.claude/telemetry.jsonl' \
    '.claude/lessons.jsonl' \
    '.claude/board-queue.jsonl' \
    '.claude/board-cache.json' \
    '.claude/neural-view/' \
    '.claude/merge-requirements.json' \
    '.claude/.flush*' \
    '.claude/worktrees/' \
    '.claude/identities/*/brain/index.sqlite3')"
LS_EXP_TRACK="$(printf '%s\n' \
    '.claude/feedbacks/' \
    '.claude/identities/' \
    '.claude/brain-events.jsonl' \
    '.claude/.neural-network' \
    '.claude/project.yaml')"

# --- manifest exists ------------------------------------------------------
if [[ -f "$LS_MANIFEST" ]]; then present=yes; else present=no; fi
check "local-state: manifest file exists" "yes" "$present"

# --- bash helper: ignore / track lists (exact, ordered) -------------------
ls_bash_ignore="$(bash -c '. "$1" 2>/dev/null && spec_workflow_local_state_paths ignore' _ "$LS_LIB" 2>/dev/null)"
[[ "$ls_bash_ignore" == "$LS_EXP_IGNORE" ]] && r=EQUAL || r="DIFFER"
check "local-state: bash ignore list matches spec" "EQUAL" "$r"

ls_bash_track="$(bash -c '. "$1" 2>/dev/null && spec_workflow_local_state_paths track' _ "$LS_LIB" 2>/dev/null)"
[[ "$ls_bash_track" == "$LS_EXP_TRACK" ]] && r=EQUAL || r="DIFFER"
check "local-state: bash track list matches spec" "EQUAL" "$r"

# --- bash helper: policy lookup by path -----------------------------------
r="$(bash -c '. "$1" 2>/dev/null && spec_workflow_local_state_policy .claude/CHECKPOINT' _ "$LS_LIB" 2>/dev/null)"
check "local-state: bash policy(.claude/CHECKPOINT)=ignore" "ignore" "$r"
r="$(bash -c '. "$1" 2>/dev/null && spec_workflow_local_state_policy .claude/project.yaml' _ "$LS_LIB" 2>/dev/null)"
check "local-state: bash policy(.claude/project.yaml)=track" "track" "$r"
r="$(bash -c '. "$1" 2>/dev/null && spec_workflow_local_state_policy .claude/identities/*/brain/index.sqlite3' _ "$LS_LIB" 2>/dev/null)"
check "local-state: bash policy(index.sqlite3)=ignore" "ignore" "$r"
bash -c '. "$1" 2>/dev/null && spec_workflow_local_state_policy .claude/does-not-exist' _ "$LS_LIB" >/dev/null 2>&1
check_rc "local-state: bash policy(unknown) exits nonzero" 1 "$?"

# --- python helper: parity with bash --------------------------------------
ls_py_ignore="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import local_state; print("\n".join(local_state.paths("ignore")))' "$PLUGIN/scripts/lib" 2>/dev/null)"
[[ "$ls_py_ignore" == "$LS_EXP_IGNORE" ]] && r=EQUAL || r="DIFFER"
check "local-state: python ignore list matches spec" "EQUAL" "$r"

ls_py_track="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import local_state; print("\n".join(local_state.paths("track")))' "$PLUGIN/scripts/lib" 2>/dev/null)"
[[ "$ls_py_track" == "$LS_EXP_TRACK" ]] && r=EQUAL || r="DIFFER"
check "local-state: python track list matches spec" "EQUAL" "$r"

r="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import local_state; print(local_state.policy_of(".claude/brain-events.jsonl"))' "$PLUGIN/scripts/lib" 2>/dev/null)"
check "local-state: python policy(brain-events.jsonl)=track" "track" "$r"
r="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import local_state; print(local_state.policy_of(".claude/nope") is None)' "$PLUGIN/scripts/lib" 2>/dev/null)"
check "local-state: python policy(unknown) is None" "True" "$r"

# --- no second copy of the path list in skills/ or scripts/ (§7.4) --------
# A duplicated LIST is a re-paste of the manifest, not incidental overlap: flag
# a single line naming 5+ distinct manifest paths (the removed setup-project
# printf had 8), OR a whole file naming 9+ distinct paths (half the manifest —
# a multi-line re-listing). Excluded: the manifest and the two local-state
# helpers. A purpose-specific SUBSET stays under both bars — e.g. tree-state.sh
# curates 4 gate-fingerprint-excluded paths (gate-pass/telemetry/lessons/
# board-cache), a deliberately different set from the gitignore policy, each
# individually commented; coupling it to the manifest would wrongly change what
# the gate fingerprint excludes.
_LS_LINE_MAX=5
_LS_FILE_MAX=9
ls_dup="$(python3 - "$PLUGIN" "$LS_MANIFEST" "$_LS_LINE_MAX" "$_LS_FILE_MAX" <<'PY' 2>/dev/null
import os, sys
plugin, manifest = sys.argv[1], sys.argv[2]
line_max, file_max = int(sys.argv[3]), int(sys.argv[4])
paths = []
with open(manifest) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        _, _, p = line.partition("\t")
        if p:
            paths.append(p)
skip = {os.path.realpath(manifest),
        os.path.realpath(os.path.join(plugin, "scripts/lib/local-state.sh")),
        os.path.realpath(os.path.join(plugin, "scripts/lib/local_state.py"))}
hits = []
for sub in ("skills", "scripts"):
    for root, _dirs, files in os.walk(os.path.join(plugin, sub)):
        for name in files:
            fp = os.path.join(root, name)
            if os.path.realpath(fp) in skip:
                continue
            try:
                with open(fp, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            for i, ln in enumerate(text.splitlines(), 1):
                n = sum(1 for p in paths if p in ln)
                if n >= line_max:
                    hits.append("DUPLICATE-LIST {}:{} ({} paths on one line)".format(
                        os.path.relpath(fp, plugin), i, n))
            distinct = sum(1 for p in paths if p in text)
            if distinct >= file_max:
                hits.append("DUPLICATE-LIST {} ({} distinct paths in file)".format(
                    os.path.relpath(fp, plugin), distinct))
print("\n".join(hits))
PY
)"
check_absent "local-state: no duplicated path list in skills/scripts" "DUPLICATE-LIST" "$ls_dup"

# --- README policy table stays in sync with the manifest ------------------
# The plugin README renders a | policy | `path` | table; it must equal the
# manifest's (policy, path) set exactly, so editing one without the other
# fails here.
ls_sync="$(python3 - "$PLUGIN/README.md" "$LS_MANIFEST" <<'PY' 2>/dev/null
import re, sys
readme, manifest = sys.argv[1], sys.argv[2]
man = set()
with open(manifest) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        pol, _, p = line.partition("\t")
        if p:
            man.add((pol, p))
row = re.compile(r'^\|\s*(ignore|track)\s*\|\s*`([^`]+)`\s*\|')
tbl = set()
with open(readme) as fh:
    for ln in fh:
        m = row.match(ln.strip())
        if m:
            tbl.add((m.group(1), m.group(2)))
if not tbl:
    print("SYNC-FAIL: no policy table found in README")
elif tbl != man:
    for x in sorted(man - tbl):
        print("SYNC-FAIL: in manifest, missing from README: {}".format(x))
    for x in sorted(tbl - man):
        print("SYNC-FAIL: in README, missing from manifest: {}".format(x))
else:
    print("SYNC-OK")
PY
)"
check "local-state: README table in sync with manifest" "SYNC-OK" "$ls_sync"
