#!/usr/bin/env bash
# section-brain-shrink-guard.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain shrink guard (#249, SPEC-GRAPHIFY §13: refuse disproportionate removals) =="

SG_BRAIN="$PLUGIN/scripts/brain.py"

# --------------------------------------------------------- fixture: over-threshold
# 10 links total; 6 point at missing targets (candidates, target missing), 4 point
# at a real note with fires>0 (kept). 6/10 = 60% > default 30%, and 6 > the
# absolute floor (5), so the guard must engage.
SG1="$(mktemp -d)"
sg1() { python3 "$SG_BRAIN" "$SG1" "$@"; }
printf 'real note body.\n' | sg1 mint dev real --tags r --paths "r/**" --source x >/dev/null
python3 - "$SG1" <<'PY'
import json, os, sys
root = sys.argv[1]
p = os.path.join(root, ".claude/identities/dev/brain/links.json")
links = {}
for i in range(1, 7):
    links["orphan%d->missing%d" % (i, i)] = {"fires": 0}
for i in range(1, 5):
    links["keep%d->real" % i] = {"fires": 1}
json.dump(links, open(p, "w"), indent=2, sort_keys=True)
PY
SG1_LINKS="$SG1/.claude/identities/dev/brain/links.json"
SG1_SNAPSHOT="$SG1/links.snapshot.json"
cp "$SG1_LINKS" "$SG1_SNAPSHOT"
: >"$SG1/.claude/brain-events.jsonl"

out="$(sg1 prune dev --apply; echo "rc=$?")"
check "over-threshold: refuses (non-zero exit)" "rc=1" "$out"
check "over-threshold: refusal names the count/total/pct" "6/10 link(s) (60%" "$out"
check "over-threshold: refusal names the threshold/floor" "30% threshold, floor 5" "$out"
check "over-threshold: refusal shows a sample candidate key" "orphan1->missing1" "$out"
check "over-threshold: refusal offers the --force escape hatch" "Re-run with --force" "$out"
# strict byte-for-byte comparison against a pre-run snapshot COPY (not a
# captured variable -- bash command substitution strips trailing newlines,
# which would silently swallow a truncation/rewrite that happens to keep
# every line grep -F would check for). cmp catches ANY difference, including
# a trailing-newline change from an accidental re-write.
if cmp -s "$SG1_SNAPSHOT" "$SG1_LINKS"; then
    echo "ok   over-threshold: links.json byte-identical after refusal (cmp)"
else
    echo "FAIL over-threshold: links.json byte-identical after refusal (cmp) — files differ"
    fails=$((fails + 1))
fi
out="$(python3 - "$SG1/.claude/brain-events.jsonl" <<'PY'
import json, sys
n = 0
if __import__("os").path.isfile(sys.argv[1]):
    for line in open(sys.argv[1]):
        line = line.strip()
        if not line:
            continue
        if json.loads(line).get("type") == "LinkPruned":
            n += 1
print("LinkPruned=%d" % n)
PY
)"
check "over-threshold: no LinkPruned events emitted on refusal" "LinkPruned=0" "$out"

# --------------------------------------------------------------- --force overrides
out="$(sg1 prune dev --apply --force; echo "rc=$?")"
check "force: proceeds (exit 0)" "rc=0" "$out"
check "force: loud override summary" "SHRINK GUARD OVERRIDDEN (--force): removing 6/10 link(s) (60%" "$out"
check "force: loud summary shows a sample candidate key" "orphan1->missing1" "$out"
out="$(cat "$SG1/.claude/identities/dev/brain/links.json")"
check_absent "force: candidate link actually removed" "orphan1->missing1" "$out"
check "force: kept links survive" "keep1->real" "$out"
out="$(python3 - "$SG1/.claude/brain-events.jsonl" <<'PY'
import json, sys
n = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    if json.loads(line).get("type") == "LinkPruned":
        n += 1
print("LinkPruned=%d" % n)
PY
)"
check "force: LinkPruned still emitted once per removed link" "LinkPruned=6" "$out"
rm -rf "$SG1"

# ------------------------------------------------------------ fixture: small-brain floor
# 3 links total; 2 candidates (target missing) = 66% over the fraction, but only 2
# items removed, at/under the absolute floor (5) -- guard must NOT engage.
SG2="$(mktemp -d)"
sg2() { python3 "$SG_BRAIN" "$SG2" "$@"; }
printf 'real note body.\n' | sg2 mint dev real --tags r --paths "r/**" --source x >/dev/null
python3 - "$SG2" <<'PY'
import json, os, sys
root = sys.argv[1]
p = os.path.join(root, ".claude/identities/dev/brain/links.json")
links = {
    "orphan1->missing1": {"fires": 0},
    "orphan2->missing2": {"fires": 0},
    "keep1->real": {"fires": 1},
}
json.dump(links, open(p, "w"), indent=2, sort_keys=True)
PY
out="$(sg2 prune dev --apply; echo "rc=$?")"
check "small-brain floor: passes without --force (exit 0)" "rc=0" "$out"
check "small-brain floor: removal message unchanged" "removed 2 link(s)" "$out"
out="$(cat "$SG2/.claude/identities/dev/brain/links.json")"
check_absent "small-brain floor: candidate link removed" "orphan1->missing1" "$out"
check "small-brain floor: kept link survives" "keep1->real" "$out"
rm -rf "$SG2"

# --------------------------------------------------------- config: shrinkGuardFraction
# same shape as SG1 (6/10 = 60%) but methodology.shrinkGuardFraction raised to 0.9,
# so 60% is now under threshold and prune --apply must succeed without --force.
SG3="$(mktemp -d)"
sg3() { python3 "$SG_BRAIN" "$SG3" "$@"; }
mkdir -p "$SG3/.claude"
cat >"$SG3/.claude/project.yaml" <<'YAML'
schemaVersion: 2
methodology:
    shrinkGuardFraction: 0.9
YAML
printf 'real note body.\n' | sg3 mint dev real --tags r --paths "r/**" --source x >/dev/null
python3 - "$SG3" <<'PY'
import json, os, sys
root = sys.argv[1]
p = os.path.join(root, ".claude/identities/dev/brain/links.json")
links = {}
for i in range(1, 7):
    links["orphan%d->missing%d" % (i, i)] = {"fires": 0}
for i in range(1, 5):
    links["keep%d->real" % i] = {"fires": 1}
json.dump(links, open(p, "w"), indent=2, sort_keys=True)
PY
out="$(sg3 prune dev --apply; echo "rc=$?")"
check "configured fraction: raised threshold lets it proceed without --force" "rc=0" "$out"
check "configured fraction: removal message unchanged" "removed 6 link(s)" "$out"
rm -rf "$SG3"

# --------------------------------------------------------- fixture: threshold boundary
# 20 links total; 6 candidates (target missing) = exactly 30% (the default fraction),
# and 6 > the absolute floor (5). remove/total == fraction pins the "<=" semantics --
# AT the threshold proceeds without --force, only strictly OVER it must refuse.
SG5="$(mktemp -d)"
sg5() { python3 "$SG_BRAIN" "$SG5" "$@"; }
printf 'real note body.\n' | sg5 mint dev real --tags r --paths "r/**" --source x >/dev/null
python3 - "$SG5" <<'PY'
import json, os, sys
root = sys.argv[1]
p = os.path.join(root, ".claude/identities/dev/brain/links.json")
links = {}
for i in range(1, 7):
    links["orphan%d->missing%d" % (i, i)] = {"fires": 0}
for i in range(1, 15):
    links["keep%d->real" % i] = {"fires": 1}
json.dump(links, open(p, "w"), indent=2, sort_keys=True)
PY
out="$(sg5 prune dev --apply; echo "rc=$?")"
check "threshold boundary: exactly at 30% proceeds without --force (exit 0)" "rc=0" "$out"
check "threshold boundary: removal message unchanged" "removed 6 link(s)" "$out"
rm -rf "$SG5"

# ------------------------------------------------------ existing behavior untouched
# below-threshold prune (2 candidates, well under floor) still runs exactly as today.
SG4="$(mktemp -d)"
sg4() { python3 "$SG_BRAIN" "$SG4" "$@"; }
printf 'src body\n\nrel: [[ghost-one]] and [[ghost-two]]\n' \
    | sg4 mint dev src --tags s --paths "s/**" >/dev/null
out="$(sg4 prune dev --apply; echo "rc=$?")"
check "below-threshold: unchanged exit code" "rc=0" "$out"
check "below-threshold: unchanged removal message" "removed 2 link(s)" "$out"
rm -rf "$SG4"
