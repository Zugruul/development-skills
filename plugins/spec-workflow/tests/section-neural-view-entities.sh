#!/usr/bin/env bash
# section-neural-view-entities.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope. Covers #163: neural-view build_graph's
# cross-role note-level "entity" edges + the entityEdgeColor config knob.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
NV="$PLUGIN/scripts/neural-view.py"

echo "== neural-view /graph: entity edges derived on the fly from frontmatter (no entity-index.json) =="
_ent1="$(mktemp -d)"
_ent1state="$(mktemp -d)"
_ent1repo="$(basename "$_ent1")"
_ent1dev="$_ent1/.claude/identities/dev/brain/notes"
_ent1rev="$_ent1/.claude/identities/reviewer/brain/notes"
mkdir -p "$_ent1dev" "$_ent1rev"
cat >"$_ent1dev/card-x.md" <<'EOF'
---
tags: [card]
strength: 1
entities: [card:gone-in-a-flash]
---
The card fact.
EOF
cat >"$_ent1rev/ix-x.md" <<'EOF'
---
tags: [ruling]
strength: 1
entities: [card:gone-in-a-flash]
---
A ruling about the card.
EOF
# same-role pair for the SAME entity must never get an edge (never same-role pairs)
cat >"$_ent1dev/card-x-alt.md" <<'EOF'
---
tags: [card]
strength: 1
entities: [card:gone-in-a-flash]
---
Another dev-role note about the same entity.
EOF
_ent1scan="$(mktemp -d)"
export NEURAL_VIEW_STATE="$_ent1state" NEURAL_VIEW_SCAN="$_ent1scan"
lifecycle_start "neural-view starts (entity edges, derive-on-the-fly)" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_ent1"'
out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")"
check "graph node carries its entities list" '"entities": ["card:gone-in-a-flash"]' "$out"
check "graph emits a cross-role entity edge" '"type": "entity"' "$out"
check "entity edge names the entity key" '"entity": "card:gone-in-a-flash"' "$out"
check "entity edge connects dev's note" "\"$_ent1repo/dev/card-x\"" "$out"
check "entity edge connects reviewer's note" "\"$_ent1repo/reviewer/ix-x\"" "$out"
check "entityEdgeColor defaults to gradient when project.yaml is absent" "\"$_ent1repo\": \"gradient\"" "$out"
same_role_edge="$(python3 -c '
import json, sys
g = json.loads(sys.argv[1])
n = sum(1 for e in g["edges"] if e.get("type")=="entity"
        and e["source"].split("/")[1]==e["target"].split("/")[1])
print(n)
' "$out")"
check "no entity edge ever connects two notes in the SAME role" "0" "$same_role_edge"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_ent1" "$_ent1state" "$_ent1scan"

echo "== neural-view /graph: entity edges honor a committed entity-index.json's anchor =="
_ent2="$(mktemp -d)"
_ent2state="$(mktemp -d)"
_ent2repo="$(basename "$_ent2")"
_ent2dev="$_ent2/.claude/identities/dev/brain/notes"
_ent2rev="$_ent2/.claude/identities/reviewer/brain/notes"
_ent2orc="$_ent2/.claude/identities/orchestrator/brain/notes"
mkdir -p "$_ent2dev" "$_ent2rev" "$_ent2orc"
for f in "$_ent2dev/anchor-note.md" "$_ent2rev/member-a.md" "$_ent2orc/member-b.md"; do
    printf -- '---\nstrength: 1\nentities: [card:hub-test]\n---\nbody.\n' >"$f"
done
mkdir -p "$_ent2/.claude/identities"
cat >"$_ent2/.claude/identities/entity-index.json" <<EOF
{
  "generated-by": "brain.py entity-index",
  "entities": {
    "card:hub-test": {
      "anchor": "dev/anchor-note",
      "notes": [["dev", "anchor-note"], ["orchestrator", "member-b"], ["reviewer", "member-a"]]
    }
  }
}
EOF
_ent2scan="$(mktemp -d)"
export NEURAL_VIEW_STATE="$_ent2state" NEURAL_VIEW_SCAN="$_ent2scan"
lifecycle_start "neural-view starts (entity edges, committed index with anchor)" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_ent2"'
out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")"
n_from_anchor="$(python3 -c '
import json, sys
g = json.loads(sys.argv[1])
want = sys.argv[2] + "/dev/anchor-note"
n = sum(1 for e in g["edges"] if e.get("type")=="entity" and e["source"]==want)
print(n)
' "$out" "$_ent2repo")"
check "both entity edges originate FROM the declared anchor note (star topology)" "2" "$n_from_anchor"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_ent2" "$_ent2state" "$_ent2scan"

echo "== neural-view /graph: a committed entity-index.json that is STALE relative to notes on disk (#163 review, BLOCKING) =="
# Reproduces the reviewer's report: entity-index.json is generated, THEN a new
# correlated note pair is minted -- the design doc (§3.3) promises the view
# "never requires a regen"; a committed-but-stale index must not hide a
# correlation the notes on disk already declare. card:gone-in-a-flash is
# fully represented in the committed index (so committed anchors still win
# where both know an entity); card:new-after-index exists ONLY on disk, minted
# after the index file was written, and must still surface as a live edge.
_ent4="$(mktemp -d)"
_ent4state="$(mktemp -d)"
_ent4repo="$(basename "$_ent4")"
_ent4dev="$_ent4/.claude/identities/dev/brain/notes"
_ent4rev="$_ent4/.claude/identities/reviewer/brain/notes"
mkdir -p "$_ent4dev" "$_ent4rev" "$_ent4/.claude/identities"
cat >"$_ent4dev/known-card.md" <<'EOF'
---
strength: 1
entities: [card:gone-in-a-flash]
---
Known at index-generation time.
EOF
cat >"$_ent4rev/known-ruling.md" <<'EOF'
---
strength: 1
entities: [card:gone-in-a-flash]
---
Known at index-generation time.
EOF
# The committed index reflects ONLY the two notes above -- it predates the
# "new-after-index" notes minted next, exactly like a stale committed file.
cat >"$_ent4/.claude/identities/entity-index.json" <<EOF
{
  "generated-by": "brain.py entity-index",
  "entities": {
    "card:gone-in-a-flash": {
      "anchor": null,
      "notes": [["dev", "known-card"], ["reviewer", "known-ruling"]]
    }
  }
}
EOF
# Minted AFTER the index file above -- the index has no idea these exist.
cat >"$_ent4dev/new-card.md" <<'EOF'
---
strength: 1
entities: [card:new-after-index]
---
Minted after the entity-index.json regen -- must still surface live.
EOF
cat >"$_ent4rev/new-ruling.md" <<'EOF'
---
strength: 1
entities: [card:new-after-index]
---
Minted after the entity-index.json regen -- must still surface live.
EOF
_ent4scan="$(mktemp -d)"
export NEURAL_VIEW_STATE="$_ent4state" NEURAL_VIEW_SCAN="$_ent4scan"
lifecycle_start "neural-view starts (stale committed entity-index.json)" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_ent4"'
out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")"
check "a correlation known ONLY to the committed index still surfaces" '"entity": "card:gone-in-a-flash"' "$out"
check "a correlation minted AFTER the committed index was generated still surfaces (union, not index-only)" '"entity": "card:new-after-index"' "$out"
check "the post-index note pair is actually connected by that edge" "\"$_ent4repo/dev/new-card\"" "$out"
check "the post-index note pair is actually connected by that edge (target)" "\"$_ent4repo/reviewer/new-ruling\"" "$out"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_ent4" "$_ent4state" "$_ent4scan"

echo "== neural-view /graph: duplicate entity keys within one note's frontmatter are deduped (#163 review, SHOULD-FIX) =="
# --entities "card:x,card:x" (or a hand-edited duplicate) must not double the
# note in that entity's notes list -- it would (a) miscount a home role as
# having "more than one" declaring note (breaking anchor resolution) and
# (b) emit the same entity edge twice (visibly brighter under additive
# blending, wasted buffer slots).
_ent5="$(mktemp -d)"
_ent5state="$(mktemp -d)"
_ent5repo="$(basename "$_ent5")"
_ent5dev="$_ent5/.claude/identities/dev/brain/notes"
_ent5rev="$_ent5/.claude/identities/reviewer/brain/notes"
mkdir -p "$_ent5dev" "$_ent5rev"
cat >"$_ent5dev/dup-card.md" <<'EOF'
---
strength: 1
entities: [card:dup, card:dup]
---
Declares the same entity key twice in its own frontmatter list.
EOF
cat >"$_ent5rev/dup-ruling.md" <<'EOF'
---
strength: 1
entities: [card:dup]
---
Normal single declaration.
EOF
_ent5scan="$(mktemp -d)"
export NEURAL_VIEW_STATE="$_ent5state" NEURAL_VIEW_SCAN="$_ent5scan"
lifecycle_start "neural-view starts (duplicate entity key, derive-on-the-fly)" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_ent5"'
out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")"
n_dup_edges="$(python3 -c '
import json, sys
g = json.loads(sys.argv[1])
print(sum(1 for e in g["edges"] if e.get("type")=="entity" and e.get("entity")=="card:dup"))
' "$out")"
check "a note declaring the same entity key twice yields exactly ONE edge to the correlated note, not two" "1" "$n_dup_edges"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_ent5" "$_ent5state" "$_ent5scan"

echo "== neural-view /graph: neuralView.entityEdgeColor override is passed through per-repo =="
_ent3="$(mktemp -d)"
_ent3state="$(mktemp -d)"
_ent3repo="$(basename "$_ent3")"
mkdir -p "$_ent3/.claude"
cat >"$_ent3/.claude/project.yaml" <<'YAML'
schemaVersion: 2
project:
    name: ent3/fixture
    mainBranch: main
    branchPattern: "<prefix>-<id>-<slug>"
boards: []
specs: []
commands:
    gate: "true"
neuralView:
    entityEdgeColor: "#ff00aa"
YAML
mkdir -p "$_ent3/.claude/identities/dev/brain/notes"
_ent3scan="$(mktemp -d)"
export NEURAL_VIEW_STATE="$_ent3state" NEURAL_VIEW_SCAN="$_ent3scan"
lifecycle_start "neural-view starts (entityEdgeColor override)" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_ent3"'
out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")"
check "entityEdgeColor override reaches the /graph payload" "\"$_ent3repo\": \"#ff00aa\"" "$out"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_ent3" "$_ent3state" "$_ent3scan"
