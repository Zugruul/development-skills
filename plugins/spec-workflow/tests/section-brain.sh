#!/usr/bin/env bash
# section-brain.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain (per-identity zettel memory) =="
BT="$(mktemp -d)"
BRAIN="$PLUGIN/scripts/brain.py"
brain() { python3 "$BRAIN" "$BT" "$@"; }

# mint two dev notes; A wikilinks to B
printf 'YAML dumps sort keys unless sort_keys=False.\n\nRelated: [[merge-yaml]]\n' \
    | brain mint dev yaml-key-order --tags yaml,config --paths "scripts/**,**/*.yaml" --source "PR#3 review"
printf 'Merging YAML needs a deep merge, not dict.update.\n' \
    | brain mint dev merge-yaml --tags merge --paths "scripts/merge.sh" --source "PR#4"

# direct hit by path glob → full body injected
out="$(brain recall dev --paths "scripts/foo.sh" --keywords "")"
check "recall direct hit body" "sort_keys=False" "$out"
check "recall direct hit title" "yaml-key-order" "$out"

# spreading activation: only A matches by glob, B surfaces via the A->B link
out="$(brain recall dev --paths "docs/only.yaml" --keywords "")"
check "recall seeds A via glob" "yaml-key-order" "$out"
check "recall propagates to linked B" "merge-yaml" "$out"

# keyword seed (tag intersection)
out="$(brain recall dev --paths "" --keywords "merge")"
check "recall keyword seed" "merge-yaml" "$out"

# budget truncation → titles only, no bodies
out="$(brain recall dev --paths "scripts/foo.sh" --keywords "" --budget 8)"
check "budget truncation keeps a title" "yaml-key-order" "$out"
check_absent "budget truncation drops bodies" "sort_keys=False" "$out"

# graduated note is excluded from injection but still bridges links
brain graduate dev yaml-key-order >/dev/null
out="$(brain recall dev --paths "scripts/foo.sh" --keywords "")"
check_absent "graduated note not injected" "sort_keys=False" "$out"
check "graduated note still bridges to B" "merge-yaml" "$out"

# activation log: every line valid JSON with the frozen contract fields
LOG="$BT/.claude/identities/dev/brain/.activation.jsonl"
out="$(python3 - "$LOG" <<'PY'
import json, sys
seen = set()
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    o = json.loads(line)
    for k in ("ts", "role", "event", "note", "activation"):
        assert k in o, (k, o)
    if o["event"] == "hop":
        assert "link" in o and "->" in o["link"], o
    seen.add(o["event"])
print("events:" + ",".join(sorted(seen)))
PY
)"
check "activation log valid json + fields" "events:" "$out"
check "activation log has seed event" "seed" "$out"
check "activation log has hop event" "hop" "$out"
check "activation log has inject event" "inject" "$out"

# directory lists titles + tags, never bodies
brain directory >/dev/null
out="$(cat "$BT/.claude/identities/DIRECTORY.md")"
check "directory lists a slug" "yaml-key-order" "$out"
check "directory lists tags" "merge" "$out"
check_absent "directory omits bodies" "sort_keys=False" "$out"

# consult: prints the owner's body, logs to the OWNER, recurs on 2nd
printf 'Reviewer rule: verify tests exist before approving.\n' \
    | brain mint reviewer verify-tests --tags review --paths "**/*.test.*" --source "PR#5"
out="$(brain consult dev reviewer verify-tests)"
check "consult prints owner body" "verify tests exist" "$out"
check_absent "consult no recurrence first time" "RECURRENCE" "$out"
out="$(brain consult dev reviewer verify-tests)"
check "consult recurrence on 2nd" "RECURRENCE" "$out"
check "consult recurrence names consumer" "dev's brain" "$out"
out="$(cat "$BT/.claude/identities/reviewer/brain/.activation.jsonl")"
check "consult logged to owner brain" '"event": "consult"' "$out"
check "consult log names consumer" '"consumer": "dev"' "$out"

# finding 1 — budget accounting: joined output (incl. separators) never exceeds the char budget.
# Short slugs so several title-only blocks fit and inter-block separators accumulate (the repro).
for i in 1 2 3 4 5 6 7 8; do
    printf 'body line %s\n' "$i" | brain mint dev "b$i" --tags bud --paths "bud/**" --source x >/dev/null
done
out="$(brain recall dev --paths "bud/x.txt" --keywords "" --budget 5 \
    | python3 -c 'import sys; s=sys.stdin.read().rstrip("\n"); print("WITHIN" if len(s) <= 20 else "OVER:"+str(len(s)))')"
check "budget accounting stays within bound" "WITHIN" "$out"

# finding 2 — consult log lines omit activation; seed/hop/inject carry it
out="$(python3 - "$BT/.claude/identities/dev/brain/.activation.jsonl" "$BT/.claude/identities/reviewer/brain/.activation.jsonl" <<'PY'
import json, sys
ok = True
for path in sys.argv[1:]:
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        o = json.loads(line)
        if o["event"] in ("seed", "hop", "inject"):
            ok = ok and "activation" in o
        if o["event"] == "consult":
            ok = ok and "activation" not in o
            ok = ok and set(o.keys()) == {"ts", "role", "event", "note", "consumer"}
print("FIELD-SETS-OK" if ok else "FIELD-SETS-BAD")
PY
)"
check "consult omits activation; others keep it" "FIELD-SETS-OK" "$out"

# finding 3 — quote-aware frontmatter list parse: a comma-containing tag is not corrupted
printf 'quoted comma tag note.\n' | brain mint dev qtag --tags placeholder --paths "qt/**" --source x >/dev/null
python3 - "$BT" <<'PY'
import os, re, sys
p = os.path.join(sys.argv[1], ".claude/identities/dev/brain/notes/qtag.md")
s = open(p).read()
open(p, "w").write(re.sub(r"tags: .*", 'tags: ["a,b", "c"]', s))
PY
brain directory >/dev/null
out="$(cat "$BT/.claude/identities/DIRECTORY.md")"
check "comma-containing tag survives parse" "a,b" "$out"
check_absent "comma tag not split into fragments" 'b" ' "$out"
# recall still surfaces the note by its intact second tag
out="$(brain recall dev --paths "" --keywords "c")"
check "recall matches note with quoted-comma tag list" "qtag" "$out"

# prune: a never-fired link off an aged note is flagged (isolated pair, never recalled)
printf 'Old stale idea.\n\nRelated: [[stale-dst]]\n' \
    | brain mint dev stale-src --tags stale --paths "nope/**" --source "old"
printf 'Target of the stale link.\n' \
    | brain mint dev stale-dst --tags stale --paths "nope2/**" --source "old"
python3 - "$BT" <<'PY'
import os, re, sys
p = os.path.join(sys.argv[1], ".claude/identities/dev/brain/notes/stale-src.md")
s = open(p).read()
open(p, "w").write(re.sub(r"created: .*", "created: 2020-01-01", s))
PY
brain retro-mark >/dev/null; brain retro-mark >/dev/null; brain retro-mark >/dev/null
out="$(brain prune dev)"
check "prune flags never-fired aged link" "stale-src->stale-dst" "$out"

echo "== brain graduate-check (threshold-based graduation proposals) =="
# seed four notes at controlled strengths/tags, then hand-patch strength/graduated
# (mint always writes strength=1 on first mint; re-mint bumps by 1 each call, so
# patching is far more direct than looping mint calls to reach a target strength).
printf 'Below threshold, unremarkable.\n' | brain mint dev gc-below --tags misc --paths "gc/**" --source x
printf 'At the default threshold, mechanically checkable.\n' | brain mint dev gc-at --tags testing,ci --paths "gc/**" --source x
printf 'Above threshold, a hard rule.\n' | brain mint dev gc-above --tags invariant,contract --paths "gc/**" --source x
printf 'Above threshold but already graduated.\n' | brain mint dev gc-graduated --tags process --paths "gc/**" --source x
python3 - "$BT" <<'PY2'
import os, re, sys
d = os.path.join(sys.argv[1], ".claude/identities/dev/brain/notes")
patch = {"gc-below": (2, False), "gc-at": (3, False), "gc-above": (5, False), "gc-graduated": (5, True)}
for slug, (strength, graduated) in patch.items():
    p = os.path.join(d, slug + ".md")
    s = open(p).read()
    s = re.sub(r"strength: .*", "strength: %d" % strength, s)
    s = re.sub(r"graduated: .*", "graduated: %s" % ("true" if graduated else "false"), s)
    open(p, "w").write(s)
PY2

# default threshold (3, no project.yaml present yet): at/above-threshold, non-graduated only
out="$(brain graduate-check dev)"
check "graduate-check lists at-threshold note" "gc-at" "$out"
check "graduate-check lists above-threshold note" "gc-above" "$out"
check_absent "graduate-check excludes below-threshold note" "gc-below" "$out"
check_absent "graduate-check excludes already-graduated note" "gc-graduated" "$out"
check "graduate-check proposes test-or-lint for testing/ci tags" "test-or-lint" "$out"
check "graduate-check proposes an invariant entry for contract/invariant tags" "specs[].invariants entry" "$out"

# read-only: strength/graduated on disk are unchanged after graduate-check runs
before="$(grep -E 'strength:|graduated:' "$BT/.claude/identities/dev/brain/notes/gc-at.md")"
brain graduate-check dev >/dev/null
after="$(grep -E 'strength:|graduated:' "$BT/.claude/identities/dev/brain/notes/gc-at.md")"
check "graduate-check is read-only (frontmatter unchanged)" "$before" "$after"

# empty case: a threshold nothing clears exits 0 with a clean message
out="$(brain graduate-check dev --threshold 100; echo "rc=$?")"
check "graduate-check empty case message" "no notes at/above threshold 100 for dev" "$out"
check "graduate-check empty case exits 0" "rc=0" "$out"

# threshold configurable via project.yaml (methodology.graduationThreshold): cutoff shifts
mkdir -p "$BT/.claude"
cat > "$BT/.claude/project.yaml" <<'YAML'
schemaVersion: 2
methodology:
    graduationThreshold: 2
YAML
out="$(brain graduate-check dev)"
check "custom threshold (2) picks up the below-default note" "gc-below" "$out"

# --threshold CLI flag overrides the configured value
out="$(brain graduate-check dev --threshold 4)"
check_absent "CLI --threshold overrides config (gc-at strength 3 excluded at threshold 4)" "gc-at" "$out"
check "CLI --threshold overrides config (gc-above strength 5 still included)" "gc-above" "$out"
rm -f "$BT/.claude/project.yaml"

rm -rf "$BT"

echo "== brain.sh wrapper (flag-less default path, set -u) =="
# Regression: brain.sh WITHOUT --dir/BRAIN_DIR must not die on empty-array expansion under set -u.
# Runs via the wrapper (ROOT from git rev-parse), the path the brain.py tests above never exercise.
BW="$(mktemp -d)"
( cd "$BW" && git init -q . )
out="$(cd "$BW" && printf 'wrapper lesson body.\n' | bash "$PLUGIN/scripts/brain.sh" mint dev wrapper-note --tags w --paths "x/**" --source "test" 2>&1; echo "rc=$?")"
check "brain.sh mint (no --dir) succeeds" "minted dev/wrapper-note" "$out"
check_absent "brain.sh flag-less: no unbound-variable error" "unbound variable" "$out"
check "brain.sh mint (no --dir) exits 0" "rc=0" "$out"
out="$(cd "$BW" && bash "$PLUGIN/scripts/brain.sh" directory 2>&1; echo "rc=$?")"
check "brain.sh directory (no --dir) exits 0" "rc=0" "$out"
check "brain.sh wrote into default .claude/identities" "wrapper-note" "$(cat "$BW/.claude/identities/DIRECTORY.md" 2>/dev/null)"
# BRAIN_DIR override path still works
out="$(cd "$BW" && printf 'override body.\n' | BRAIN_DIR=".claude/custom" bash "$PLUGIN/scripts/brain.sh" mint dev ov-note --tags o --paths "y/**" --source "test" 2>&1; echo "rc=$?")"
check "brain.sh BRAIN_DIR override succeeds" "rc=0" "$out"
out="$([[ -f "$BW/.claude/custom/dev/brain/notes/ov-note.md" ]] && echo FOUND || echo MISSING)"
check "brain.sh BRAIN_DIR override targets custom dir" "FOUND" "$out"
rm -rf "$BW"

