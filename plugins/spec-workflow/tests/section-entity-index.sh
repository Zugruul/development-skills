#!/usr/bin/env bash
# section-entity-index.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope. Covers #163: brain.py entity-index — the
# cross-identity correlation index derived purely from note frontmatter.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain.py entity-index (cross-identity correlation index, #163) =="
ET="$(mktemp -d)"
BRAIN="$PLUGIN/scripts/brain.py"
ebrain() { python3 "$BRAIN" "$ET" "$@"; }

# two brains (card-vault-style dev role + judge-style reviewer role) declaring
# the same entity -- entity-index must find the correlation via frontmatter alone.
printf 'The card itself.\n' \
    | ebrain mint dev card-gone-in-a-flash --tags card --paths "cards/**" --source g --entities "card:gone-in-a-flash"
printf 'A ruling that references the card.\n' \
    | ebrain mint reviewer ix-gone-in-a-flash --tags ruling --paths "rulings/**" --source g --entities "card:gone-in-a-flash"
# a note with no entities at all must never appear in the index
printf 'Unrelated note.\n' | ebrain mint dev unrelated --tags misc --paths "x/**" --source g

out="$(ebrain entity-index)"
check "entity-index reports success" "wrote" "$out"
IDX="$ET/.claude/identities/entity-index.json"
idx="$(cat "$IDX")"
check "entity-index.json names its generator" '"generated-by": "brain.py entity-index"' "$idx"
check "entity-index.json has the correlated entity key" '"card:gone-in-a-flash"' "$idx"
check "entity-index.json lists the dev-role note" '["dev", "card-gone-in-a-flash"]' "$idx"
check "entity-index.json lists the reviewer-role note" '["reviewer", "ix-gone-in-a-flash"]' "$idx"
check_absent "entity-index.json omits notes with no entities: field" "unrelated" "$idx"

# determinism: regenerating twice yields byte-identical output (diff-stable)
ebrain entity-index >/dev/null
idx2="$(cat "$IDX")"
check "entity-index regeneration is diff-stable (identical bytes)" "$idx" "$idx2"

# symlinked notes attribute ONLY to their physical home role (never double-counted)
mkdir -p "$ET/.claude/identities/reviewer/brain/notes"
ln -sf "$ET/.claude/identities/dev/brain/notes/card-gone-in-a-flash.md" \
    "$ET/.claude/identities/reviewer/brain/notes/kw-card-gone-in-a-flash.md"
ebrain entity-index >/dev/null
idx3="$(cat "$IDX")"
check_absent "symlinked note is not attributed to the role it's symlinked INTO" "kw-card-gone-in-a-flash" "$idx3"

# an entity with only ONE note anywhere still appears (isolated-neuron case)
printf 'A card nobody else references yet.\n' \
    | ebrain mint dev card-solo --tags card --paths "cards/**" --source g --entities "card:solo-card"
ebrain entity-index >/dev/null
idx4="$(cat "$ET/.claude/identities/entity-index.json")"
check "entity-index includes a single-note entity (isolated neuron)" '"card:solo-card"' "$idx4"

echo "== brain.py entity-index: anchor resolution via methodology.entityKinds =="
mkdir -p "$ET/.claude"
cat > "$ET/.claude/project.yaml" <<'YAML'
schemaVersion: 2
methodology:
    entityKinds:
        card: dev
YAML
ebrain entity-index >/dev/null
idx5="$(cat "$ET/.claude/identities/entity-index.json")"
check "anchor resolves to the sole home-role (dev) note for card:gone-in-a-flash" '"anchor": "dev/card-gone-in-a-flash"' "$idx5"

# ambiguous home role (two dev notes both declare the same entity) -> anchor null
printf 'A second card note about the same entity.\n' \
    | ebrain mint dev card-gone-in-a-flash-alt --tags card --paths "cards/**" --source g --entities "card:gone-in-a-flash"
ebrain entity-index >/dev/null
out6="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["entities"]["card:gone-in-a-flash"]["anchor"])
' "$ET/.claude/identities/entity-index.json")"
check "anchor is null when the home role has more than one declaring note" "None" "$out6"

# an entity kind with no methodology.entityKinds mapping has anchor null
printf 'A note about an unmapped-kind entity.\n' \
    | ebrain mint dev unmapped-kind-note --tags misc --paths "x/**" --source g --entities "widget:no-mapping"
ebrain entity-index >/dev/null
out7="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["entities"]["widget:no-mapping"]["anchor"])
' "$ET/.claude/identities/entity-index.json")"
check "anchor is null for a kind absent from methodology.entityKinds" "None" "$out7"
rm -f "$ET/.claude/project.yaml"

echo "== brain.py entity-index: duplicate entity key within one note's frontmatter is deduped (#163 review, SHOULD-FIX) =="
# --entities "card:x,card:x" must not double-count the SAME (role, slug) pair
# in that entity's notes list -- it would otherwise (a) look like "two notes
# in the home role" and null out an anchor that should resolve, and (b) emit
# a duplicate entity edge downstream in neural-view.
ET2="$(mktemp -d)"
ebrain2() { python3 "$BRAIN" "$ET2" "$@"; }
mkdir -p "$ET2/.claude"
cat > "$ET2/.claude/project.yaml" <<'YAML'
schemaVersion: 2
methodology:
    entityKinds:
        card: dev
YAML
printf 'Declares the same entity key twice in its own frontmatter list.\n' \
    | ebrain2 mint dev dup-card --tags card --paths "cards/**" --source g --entities "card:dup,card:dup"
printf 'A ruling about it.\n' \
    | ebrain2 mint reviewer dup-ruling --tags ruling --paths "rulings/**" --source g --entities "card:dup"
ebrain2 entity-index >/dev/null
dupidx="$(cat "$ET2/.claude/identities/entity-index.json")"
n_dup_notes="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(len(d["entities"]["card:dup"]["notes"]))
' "$ET2/.claude/identities/entity-index.json")"
check "a duplicate entity key within one note's frontmatter contributes exactly ONE notes[] entry, not two" "2" "$n_dup_notes"
check "anchor still resolves despite the duplicate declaration (home role genuinely has exactly one note)" '"anchor": "dev/dup-card"' "$dupidx"
rm -rf "$ET2"

echo "== brain.py entity-index: empty case =="
EEMPTY="$(mktemp -d)"
out="$(python3 "$BRAIN" "$EEMPTY" entity-index)"
check "entity-index on a brainless root still succeeds" "wrote" "$out"
check "entity-index on a brainless root writes an empty entities map" '"entities": {}' \
    "$(cat "$EEMPTY/.claude/identities/entity-index.json")"
rm -rf "$EEMPTY"

rm -rf "$ET"
