#!/usr/bin/env bash
# section-brain-path.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain path (GL-021/SPEC-GRAPHIFY §9 R9.2: shortest link path) =="

PA_SCRIPTS="$PLUGIN/scripts"

# Helper: write links.json directly with explicit weight values so the BFS
# hop math below is hand-computed against known numbers instead of depending
# on incidental recall/mint side effects.
_pa_write_links() { # root role json-body
    python3 -c '
import json, sys
root, role, body = sys.argv[1], sys.argv[2], sys.argv[3]
path = root + "/.claude/identities/" + role + "/brain/links.json"
open(path, "w", encoding="utf-8").write(body)
' "$1" "$2" "$3"
}

# ------------------------------------------------------ (1) golden 3-hop path
# a -> b -> c -> d is the ONLY route (a straight chain), so the shortest path
# is forced regardless of tie-break rules. Links are undirected for
# pathfinding, so this exercises following the stored a->b/b->c/c->d
# direction forward.
PA_A="$(mktemp -d)"
paa() { python3 "$PA_SCRIPTS/brain.py" "$PA_A" "$@"; }
printf 'Node a.\n' | paa mint dev node-a --tags p --source x >/dev/null
printf 'Node b.\n' | paa mint dev node-b --tags p --source x >/dev/null
printf 'Node c.\n' | paa mint dev node-c --tags p --source x >/dev/null
printf 'Node d.\n' | paa mint dev node-d --tags p --source x >/dev/null
_pa_write_links "$PA_A" dev '{
  "node-a->node-b": {"weight": 0.9, "fires": 0, "last": null},
  "node-b->node-c": {"weight": 0.5, "fires": 0, "last": null},
  "node-c->node-d": {"weight": 0.2, "fires": 0, "last": null}
}'
out="$(paa path dev node-a node-d)"
check "golden: hop 1 (node-a -> node-b, weight 0.9)" "node-a -> node-b  weight 0.9" "$out"
check "golden: hop 2 (node-b -> node-c, weight 0.5)" "node-b -> node-c  weight 0.5" "$out"
check "golden: hop 3 (node-c -> node-d, weight 0.2)" "node-c -> node-d  weight 0.2" "$out"
# fixed order: hop 1 before hop 2 before hop 3
h1_ln=$(grep -n "node-a -> node-b" <<<"$out" | head -1 | cut -d: -f1)
h2_ln=$(grep -n "node-b -> node-c" <<<"$out" | head -1 | cut -d: -f1)
h3_ln=$(grep -n "node-c -> node-d" <<<"$out" | head -1 | cut -d: -f1)
if [[ "$h1_ln" -lt "$h2_ln" && "$h2_ln" -lt "$h3_ln" ]]; then
    echo "ok   golden: hops render in path order"
else
    echo "FAIL golden: hops out of order — h1=$h1_ln h2=$h2_ln h3=$h3_ln"
    fails=$((fails + 1))
fi
rm -rf "$PA_A"

# --------------------------------------------- (2) equal-length tie-break
# hub connects to both branch-x and branch-y (same weight, same hop count to
# target); target is reachable from BOTH at equal length. Sorted-slug
# tie-break must pick branch-x (alphabetically first) deterministically, and
# it must be stable across repeated runs.
PA_B="$(mktemp -d)"
pab() { python3 "$PA_SCRIPTS/brain.py" "$PA_B" "$@"; }
printf 'Hub.\n' | pab mint dev hub --tags p --source x >/dev/null
printf 'Branch x.\n' | pab mint dev branch-x --tags p --source x >/dev/null
printf 'Branch y.\n' | pab mint dev branch-y --tags p --source x >/dev/null
printf 'Target.\n' | pab mint dev target --tags p --source x >/dev/null
_pa_write_links "$PA_B" dev '{
  "hub->branch-y": {"weight": 0.6, "fires": 0, "last": null},
  "hub->branch-x": {"weight": 0.6, "fires": 0, "last": null},
  "branch-x->target": {"weight": 0.4, "fires": 0, "last": null},
  "branch-y->target": {"weight": 0.4, "fires": 0, "last": null}
}'
out1="$(pab path dev hub target)"
out2="$(pab path dev hub target)"
check "tie-break: sorted-slug picks branch-x over branch-y" "hub -> branch-x  weight 0.6" "$out1"
check_absent "tie-break: branch-y NOT on the chosen path" "hub -> branch-y" "$out1"
check "tie-break: stable across repeated runs" "$out1" "$out2"
rm -rf "$PA_B"

# ------------------------------------------------------ (3) disconnected pair
PA_C="$(mktemp -d)"
pac() { python3 "$PA_SCRIPTS/brain.py" "$PA_C" "$@"; }
printf 'Island one.\n' | pac mint dev island-one --tags p --source x >/dev/null
printf 'Island two.\n' | pac mint dev island-two --tags p --source x >/dev/null
PA_C_OUT="$(mktemp)"
pac path dev island-one island-two >"$PA_C_OUT" 2>&1
rc_disc=$?
check_rc "disconnected: exit 0 (absence is an answer, not an error)" 0 "$rc_disc"
check "disconnected: prints 'no path'" "no path" "$(cat "$PA_C_OUT")"
rm -f "$PA_C_OUT"
rm -rf "$PA_C"

# ---------------------------------------------- (4) links.json byte-identical
# path is read-only: running it must never mutate links.json (mirrors
# explain's read-only discipline).
PA_D="$(mktemp -d)"
pad() { python3 "$PA_SCRIPTS/brain.py" "$PA_D" "$@"; }
printf 'RO note one.\n' | pad mint dev ro-one --tags p --source x >/dev/null
printf 'RO note two.\n' | pad mint dev ro-two --tags p --source x >/dev/null
_pa_write_links "$PA_D" dev '{
  "ro-one->ro-two": {"weight": 0.7, "fires": 3, "last": "2024-01-01"}
}'
before_hash="$(shasum -a 256 "$PA_D/.claude/identities/dev/brain/links.json" | cut -d' ' -f1)"
pad path dev ro-one ro-two >/dev/null
after_hash="$(shasum -a 256 "$PA_D/.claude/identities/dev/brain/links.json" | cut -d' ' -f1)"
check "read-only: links.json byte-identical before/after path" "$before_hash" "$after_hash"
rm -rf "$PA_D"

# ------------------------------------- (5) unknown role / unknown slug / A->A
PA_E="$(mktemp -d)"
pae() { python3 "$PA_SCRIPTS/brain.py" "$PA_E" "$@"; }
printf 'Real note.\n' | pae mint dev real-note --tags p --source x >/dev/null
PA_E_SLUG_OUT="$(mktemp)"
PA_E_ROLE_OUT="$(mktemp)"
pae path dev real-note nonexistent-slug >"$PA_E_SLUG_OUT" 2>&1
rc_slug=$?
check_rc "unknown slug: non-zero exit" 1 "$rc_slug"
check "unknown slug: error names the missing note" "no such note: dev/nonexistent-slug" "$(cat "$PA_E_SLUG_OUT")"
pae path nosuchrole real-note real-note >"$PA_E_ROLE_OUT" 2>&1
rc_role=$?
check_rc "unknown role: non-zero exit" 1 "$rc_role"
check "unknown role: error names the missing role" "unknown role: nosuchrole" "$(cat "$PA_E_ROLE_OUT")"
out_self="$(pae path dev real-note real-note)"
check "A->A: prints the single slug" "real-note" "$out_self"
check_rc "A->A: exit 0" 0 "0"
rm -f "$PA_E_SLUG_OUT" "$PA_E_ROLE_OUT"
rm -rf "$PA_E"

# ----------------------------------------------- (6) undirected pathfinding
# Links are stored directionally (mint-order artifact) but pathfinding
# treats them as undirected: node-p -> node-q is the only stored edge, but a
# query from node-q to node-p must still find it by walking the edge
# backwards.
PA_F="$(mktemp -d)"
paf() { python3 "$PA_SCRIPTS/brain.py" "$PA_F" "$@"; }
printf 'Node p.\n' | paf mint dev node-p --tags p --source x >/dev/null
printf 'Node q.\n' | paf mint dev node-q --tags p --source x >/dev/null
_pa_write_links "$PA_F" dev '{
  "node-p->node-q": {"weight": 0.55, "fires": 0, "last": null}
}'
out="$(paf path dev node-q node-p)"
check "undirected: reverse-direction query finds the stored forward link" "node-q -> node-p  weight 0.55" "$out"
rm -rf "$PA_F"
