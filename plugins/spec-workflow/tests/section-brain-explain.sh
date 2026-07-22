#!/usr/bin/env bash
# section-brain-explain.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain explain (GL-020/SPEC-GRAPHIFY §9 R9.1: graph interrogation card) =="

EX_SCRIPTS="$PLUGIN/scripts"

# Helper: write links.json directly with explicit weight/fires/last values so
# the co-activation/link-listing math below is hand-computed against known
# numbers instead of depending on incidental recall/mint side effects.
_ex_write_links() { # root role json-body
    python3 -c '
import json, sys
root, role, body = sys.argv[1], sys.argv[2], sys.argv[3]
path = root + "/.claude/identities/" + role + "/brain/links.json"
open(path, "w", encoding="utf-8").write(body)
' "$1" "$2" "$3"
}

# ------------------------------------------------------ (1) golden card, fixed order
# A single note, no links, no outcomes, no staleness: the card renders body,
# header, community placeholder, an empty links section, and an empty
# co-activated section, in that fixed order.
EX_A="$(mktemp -d)"
exa() { python3 "$EX_SCRIPTS/brain.py" "$EX_A" "$@"; }
printf 'A quiet note explained on its own.\n' \
    | exa mint dev quiet-explain --tags qe --source "PR#1" >/dev/null
out="$(exa explain dev quiet-explain)"
check "golden: title line names role/slug" "# dev/quiet-explain" "$out"
check "golden: header line renders (no signals -> plain slug + strength)" "quiet-explain  [strength 1]" "$out"
check "golden: note body is present in full" "A quiet note explained on its own." "$out"
check "golden: community placeholder seam, literal" "community: (pending GL-030)" "$out"
check "golden: links section header present" "## links" "$out"
check "golden: co-activated section header present" "## co-activated" "$out"
# fixed order: title < header < body < community < links < co-activated
title_ln=$(grep -n "^# dev/quiet-explain$" <<<"$out" | head -1 | cut -d: -f1)
community_ln=$(grep -n "^community: (pending GL-030)$" <<<"$out" | head -1 | cut -d: -f1)
links_ln=$(grep -n "^## links$" <<<"$out" | head -1 | cut -d: -f1)
coact_ln=$(grep -n "^## co-activated$" <<<"$out" | head -1 | cut -d: -f1)
if [[ "$title_ln" -lt "$community_ln" && "$community_ln" -lt "$links_ln" && "$links_ln" -lt "$coact_ln" ]]; then
    echo "ok   golden: sections appear in fixed order (title < community < links < co-activated)"
else
    echo "FAIL golden: sections out of order — title=$title_ln community=$community_ln links=$links_ln coact=$coact_ln"
    fails=$((fails + 1))
fi
rm -rf "$EX_A"

# ------------------------------------------------- (2) links.json byte-identical
# `explain` is read-only: running it must never mutate links.json, even when
# the spread it computes internally crosses real links (recall's spread DOES
# bump fires/last on the same links -- explain must not).
EX_B="$(mktemp -d)"
exb() { python3 "$EX_SCRIPTS/brain.py" "$EX_B" "$@"; }
printf 'Explained note with an outgoing link.\n' | exb mint dev ro-note --tags ro --source x >/dev/null
printf 'A linked neighbor.\n' | exb mint dev ro-neighbor --tags ro --source x >/dev/null
_ex_write_links "$EX_B" dev '{
  "ro-note->ro-neighbor": {"weight": 0.8, "fires": 2, "last": "2024-01-01"}
}'
before_hash="$(shasum -a 256 "$EX_B/.claude/identities/dev/brain/links.json" | cut -d' ' -f1)"
exb explain dev ro-note >/dev/null
after_hash="$(shasum -a 256 "$EX_B/.claude/identities/dev/brain/links.json" | cut -d' ' -f1)"
check "read-only: links.json byte-identical before/after explain" "$before_hash" "$after_hash"
rm -rf "$EX_B"

# ------------------------------------------------------ (3) unknown slug / unknown role
EX_C="$(mktemp -d)"
exc() { python3 "$EX_SCRIPTS/brain.py" "$EX_C" "$@"; }
printf 'Real note.\n' | exc mint dev real-note --tags r --source x >/dev/null
EX_C_SLUG_OUT="$(mktemp)"
EX_C_ROLE_OUT="$(mktemp)"
exc explain dev nonexistent-slug >"$EX_C_SLUG_OUT" 2>&1
rc_slug=$?
check_rc "unknown slug: non-zero exit" 1 "$rc_slug"
check "unknown slug: error names the missing note" "no such note: dev/nonexistent-slug" "$(cat "$EX_C_SLUG_OUT")"
exc explain nosuchrole real-note >"$EX_C_ROLE_OUT" 2>&1
rc_role=$?
check_rc "unknown role: non-zero exit" 1 "$rc_role"
check "unknown role: error names the missing role" "unknown role: nosuchrole" "$(cat "$EX_C_ROLE_OUT")"
rm -f "$EX_C_SLUG_OUT" "$EX_C_ROLE_OUT"
rm -rf "$EX_C"

# ------------------------------------------------- (4) co-activated matches hand-computed spread
# hub -> a (weight 0.9), hub -> b (weight 0.3); a has no further outgoing
# links so the spread stops there in hop 2. HOP_DECAY=0.5 (brain.py
# constant), so hop-1 activations are exactly:
#   a: 1.0 * 0.5 * 0.9 = 0.4500
#   b: 1.0 * 0.5 * 0.3 = 0.1500
# ranked strongest-first, a before b.
EX_D="$(mktemp -d)"
exd() { python3 "$EX_SCRIPTS/brain.py" "$EX_D" "$@"; }
printf 'Hub note.\n' | exd mint dev hub --tags h --source x >/dev/null
printf 'Neighbor a.\n' | exd mint dev neighbor-a --tags h --source x >/dev/null
printf 'Neighbor b.\n' | exd mint dev neighbor-b --tags h --source x >/dev/null
_ex_write_links "$EX_D" dev '{
  "hub->neighbor-a": {"weight": 0.9, "fires": 0, "last": null},
  "hub->neighbor-b": {"weight": 0.3, "fires": 0, "last": null}
}'
out="$(exd explain dev hub)"
coact_block="$(sed -n '/^## co-activated$/,$p' <<<"$out")"
check "co-activated: neighbor-a at hand-computed activation 0.4500" "neighbor-a  0.4500" "$coact_block"
check "co-activated: neighbor-b at hand-computed activation 0.1500" "neighbor-b  0.1500" "$coact_block"
# strongest-first ordering
a_ln=$(grep -n "neighbor-a  0.4500" <<<"$coact_block" | head -1 | cut -d: -f1)
b_ln=$(grep -n "neighbor-b  0.1500" <<<"$coact_block" | head -1 | cut -d: -f1)
if [[ "$a_ln" -lt "$b_ln" ]]; then
    echo "ok   co-activated: strongest-first ordering (neighbor-a before neighbor-b)"
else
    echo "FAIL co-activated: expected neighbor-a before neighbor-b — got a=$a_ln b=$b_ln"
    fails=$((fails + 1))
fi
# the hub itself must not appear in its own co-activated list
check_absent "co-activated: seed note excluded from its own list" "hub  1.0000" "$coact_block"
rm -rf "$EX_D"

# --------------------------------- (5) links section: weight/fires/last, sorted
EX_E="$(mktemp -d)"
exe_() { python3 "$EX_SCRIPTS/brain.py" "$EX_E" "$@"; }
printf 'Center note.\n' | exe_ mint dev center --tags c --source x >/dev/null
printf 'Out target a.\n' | exe_ mint dev out-a --tags c --source x >/dev/null
printf 'Out target b.\n' | exe_ mint dev out-b --tags c --source x >/dev/null
printf 'In source x.\n' | exe_ mint dev in-x --tags c --source x >/dev/null
printf 'In source y.\n' | exe_ mint dev in-y --tags c --source x >/dev/null
_ex_write_links "$EX_E" dev '{
  "center->out-a": {"weight": 0.9, "fires": 3, "last": "2024-01-01"},
  "center->out-b": {"weight": 0.3, "fires": 0, "last": null},
  "in-x->center": {"weight": 0.7, "fires": 5, "last": "2024-02-02"},
  "in-y->center": {"weight": 0.7, "fires": 1, "last": null}
}'
out="$(exe_ explain dev center)"
links_block="$(sed -n '/^## links$/,/^## co-activated$/p' <<<"$out")"
check "links: outbound entry has weight/fires/last" "out out-a  weight 0.9  fires 3  last 2024-01-01" "$links_block"
check "links: outbound entry with no last renders 'never'" "out out-b  weight 0.3  fires 0  last never" "$links_block"
check "links: inbound entry has weight/fires/last" "in  in-x  weight 0.7  fires 5  last 2024-02-02" "$links_block"
check "links: inbound entry with no last renders 'never'" "in  in-y  weight 0.7  fires 1  last never" "$links_block"
# sorted by weight desc then slug: out-a (0.9) before out-b (0.3); in-x before
# in-y (tie at weight 0.7, slug tie-break)
outa_ln=$(grep -n "out out-a" <<<"$links_block" | head -1 | cut -d: -f1)
outb_ln=$(grep -n "out out-b" <<<"$links_block" | head -1 | cut -d: -f1)
inx_ln=$(grep -n "in  in-x" <<<"$links_block" | head -1 | cut -d: -f1)
iny_ln=$(grep -n "in  in-y" <<<"$links_block" | head -1 | cut -d: -f1)
if [[ "$outa_ln" -lt "$outb_ln" && "$inx_ln" -lt "$iny_ln" ]]; then
    echo "ok   links: sorted by weight desc then slug asc"
else
    echo "FAIL links: sort order wrong — out-a=$outa_ln out-b=$outb_ln in-x=$inx_ln in-y=$iny_ln"
    fails=$((fails + 1))
fi
rm -rf "$EX_E"

# ------------------------------------------- (6) shared header formatter with recall
# GL-013's header formatter must be reused verbatim -- the confidence/tally/
# contested/stale markers on the SAME note must render byte-identically in
# `recall`'s full-tier block and `explain`'s card header line. Mirrors
# section-brain-recall-header.sh's combo-note fixture (direct confidence,
# 1x useful + 1x corrected -> contested, plus a stale path).
EX_F="$(mktemp -d)"
git -C "$EX_F" init -q
git -C "$EX_F" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
exf() { python3 "$EX_SCRIPTS/brain.py" "$EX_F" "$@"; }
printf 'Contested and stale but directly evidenced (explain twin).\n' \
    | exf mint dev shared-header-note --tags sh --paths "sh/*.sh" --source "PR#3" --confidence direct >/dev/null
exf outcome dev shared-header-note useful >/dev/null
exf outcome dev shared-header-note corrected --note "was wrong once" >/dev/null
python3 - "$EX_F" <<'PY'
import os, re, sys
root = sys.argv[1]
p = os.path.join(root, ".claude/identities/dev/brain/notes/shared-header-note.md")
s = open(p).read()
s = re.sub(r"created: .*", "created: 2020-01-01", s)
s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
open(p, "w").write(s)
PY
mkdir -p "$EX_F/sh"
echo 'echo hi' > "$EX_F/sh/x.sh"
git -C "$EX_F" add sh/x.sh
GIT_AUTHOR_DATE="2020-06-01T00:00:00" GIT_COMMITTER_DATE="2020-06-01T00:00:00" \
    git -C "$EX_F" -c user.email=t@t -c user.name=t commit -q -m "touch sh/x.sh"
recall_out="$(exf recall dev --paths "sh/x.sh" --keywords "")"
recall_header="$(sed -n '1p' <<<"$recall_out" | sed 's/^### //')"
explain_out="$(exf explain dev shared-header-note)"
explain_header="$(sed -n '3p' <<<"$explain_out")"
check "shared formatter: explain's header line equals recall's header line verbatim" \
    "$recall_header" "$explain_header"
check "shared formatter: golden bracket present in both" \
    "[direct · 1× useful] shared-header-note  [strength 1]  ⚠ contested  ⟳ stale — re-verify" "$explain_header"
rm -rf "$EX_F"
