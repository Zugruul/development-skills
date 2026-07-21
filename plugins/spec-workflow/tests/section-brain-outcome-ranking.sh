#!/usr/bin/env bash
# section-brain-outcome-ranking.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain outcome ranking (GL-003/SPEC-GRAPHIFY §7 R7.4/R7.5/R7.7: outcome multiplier + contested marker) =="

OR_SCRIPTS="$PLUGIN/scripts"

# ---------------------------------------------------------- (1) golden regression
# Frozen corpus, NO outcomes.jsonl at all -- output must stay byte-identical
# to today's (pre-GL-003) recall (G6). The golden file was captured by running
# the unmodified brain.py recall against this exact corpus.
OR_GOLD="$(mktemp -d)"
org() { python3 "$OR_SCRIPTS/brain.py" "$OR_GOLD" "$@"; }
printf 'Golden lesson body for alpha.\n\nRelated: [[gold-beta]]\n' \
    | org mint dev gold-alpha --tags gold --paths "gold/**" --source "PR#1" >/dev/null
printf 'Golden lesson body for beta.\n' \
    | org mint dev gold-beta --tags gold --paths "gold-b/**" --source "PR#2" >/dev/null
out="$(org recall dev --paths "gold/x.sh" --keywords "")"
gold_expected="$(cat "$FIX/outcome-ranking-golden.txt")"
check "golden regression: byte-identical to pre-change recall (no outcomes.jsonl)" "$gold_expected" "$out"
if [[ "$out" == "$gold_expected" ]]; then
    echo "ok   golden regression: exact byte match"
else
    echo "FAIL golden regression: exact byte match — output diverged from committed golden fixture"
    fails=$((fails + 1))
fi
rm -rf "$OR_GOLD"

# --------------------------------------------------------------- (2) twin-note
# Two notes, identical fm/paths/strength, seeded by the SAME glob (so base
# activation ties and slug order alone would rank note-a before note-b).
# note-a earns net-dead_end outcomes, note-b earns net-useful outcomes --
# after weighting, note-b must rank strictly ABOVE note-a despite losing the
# alphabetical tiebreak.
OR_TWIN="$(mktemp -d)"
ort() { python3 "$OR_SCRIPTS/brain.py" "$OR_TWIN" "$@"; }
printf 'Twin lesson body A.\n' | ort mint dev note-a --tags twin --paths "twin/**" --source x >/dev/null
printf 'Twin lesson body B.\n' | ort mint dev note-b --tags twin --paths "twin/**" --source x >/dev/null
ort outcome dev note-a dead_end >/dev/null
ort outcome dev note-a dead_end >/dev/null
ort outcome dev note-b useful >/dev/null
ort outcome dev note-b useful >/dev/null
out="$(ort recall dev --paths "twin/x.sh" --keywords "")"
b_pos="${out%%note-b*}"; a_pos="${out%%note-a*}"
check "twin-note: net-useful note-b appears in output" "note-b" "$out"
check "twin-note: net-dead_end note-a appears in output" "note-a" "$out"
if [[ "${#b_pos}" -lt "${#a_pos}" ]]; then
    echo "ok   twin-note: net-useful note ranks strictly higher than net-dead_end twin"
else
    echo "FAIL twin-note: net-useful note ranks strictly higher than net-dead_end twin"
    fails=$((fails + 1))
fi
rm -rf "$OR_TWIN"

# ------------------------------------------------------ (3) contested marker
# outcomes.jsonl is written directly (not via `brain outcome`, which always
# stamps now()) so ts values are controlled precisely against a hand-built
# retros.log -- the retro-clock window, not wall time (synthetic fixture;
# capture-dont-transcribe).
OR_CON="$(mktemp -d)"
orc() { python3 "$OR_SCRIPTS/brain.py" "$OR_CON" "$@"; }
printf 'Contested lesson body.\n' | orc mint dev conflicted --tags con --paths "con/**" --source x >/dev/null
mkdir -p "$OR_CON/.claude/identities"
cat >"$OR_CON/.claude/identities/retros.log" <<'EOF'
2026-02-01
2026-03-01
2026-04-01
2026-05-01
EOF
# default window N=3 -> cutoff = retros[-3] = 2026-03-01 (last-3-of-4)
OUT_JSONL="$OR_CON/.claude/identities/dev/brain/outcomes.jsonl"
mkdir -p "$(dirname "$OUT_JSONL")"
cat >"$OUT_JSONL" <<'EOF'
{"schemaVersion": 1, "ts": "2026-04-01T00:00:00+00:00", "slug": "conflicted", "outcome": "useful", "task": null, "note": null}
{"schemaVersion": 1, "ts": "2026-04-15T00:00:00+00:00", "slug": "conflicted", "outcome": "corrected", "task": null, "note": "wrong path"}
EOF
out="$(orc recall dev --paths "con/x.sh" --keywords "")"
check "contested: within-window 1x useful + 1x corrected renders the marker" "⚠ contested" "$out"

# same history, but BOTH outcomes predate the window cutoff (2026-03-01)
cat >"$OUT_JSONL" <<'EOF'
{"schemaVersion": 1, "ts": "2026-01-05T00:00:00+00:00", "slug": "conflicted", "outcome": "useful", "task": null, "note": null}
{"schemaVersion": 1, "ts": "2026-01-10T00:00:00+00:00", "slug": "conflicted", "outcome": "corrected", "task": null, "note": "wrong path"}
EOF
out="$(orc recall dev --paths "con/x.sh" --keywords "")"
check_absent "contested: same history OUTSIDE the window renders no marker" "⚠ contested" "$out"
rm -rf "$OR_CON"

# ---------------------------------------------------------- (4) malformed file
# One bad JSON line + one line with an unknown outcome value -> exactly one
# warning, ranking IDENTICAL to a no-outcomes baseline, exit 0.
OR_MAL="$(mktemp -d)"
orm() { python3 "$OR_SCRIPTS/brain.py" "$OR_MAL" "$@"; }
printf 'Malformed-file lesson body.\n' | orm mint dev mal-note --tags mal --paths "mal/**" --source x >/dev/null
MAL_JSONL="$OR_MAL/.claude/identities/dev/brain/outcomes.jsonl"
mkdir -p "$(dirname "$MAL_JSONL")"
cat >"$MAL_JSONL" <<'EOF'
this is not json at all
{"schemaVersion": 1, "ts": "2026-04-01T00:00:00+00:00", "slug": "mal-note", "outcome": "not_a_real_outcome", "task": null, "note": null}
EOF

OR_BASE="$(mktemp -d)"
orb() { python3 "$OR_SCRIPTS/brain.py" "$OR_BASE" "$@"; }
printf 'Malformed-file lesson body.\n' | orb mint dev mal-note --tags mal --paths "mal/**" --source x >/dev/null

err="$(orm recall dev --paths "mal/x.sh" --keywords "" 2>&1 >/dev/null)"; rc=$?
check_rc "malformed outcomes: exit 0" 0 "$rc"
warn_count="$(grep -c "malformed" <<<"$err")"
check "malformed outcomes: exactly one warning" "1" "$warn_count"
out_mal="$(orm recall dev --paths "mal/x.sh" --keywords "" 2>/dev/null)"
out_base="$(orb recall dev --paths "mal/x.sh" --keywords "" 2>/dev/null)"
if [[ "$out_mal" == "$out_base" ]]; then
    echo "ok   malformed outcomes: ranking identical to no-outcomes baseline"
else
    echo "FAIL malformed outcomes: ranking identical to no-outcomes baseline"
    fails=$((fails + 1))
fi
rm -rf "$OR_MAL" "$OR_BASE"

# ------------------------------------------------------------- (5) determinism
OR_DET="$(mktemp -d)"
ord() { python3 "$OR_SCRIPTS/brain.py" "$OR_DET" "$@"; }
printf 'Determinism lesson body.\n' | ord mint dev det-note --tags det --paths "det/**" --source x >/dev/null
ord outcome dev det-note useful >/dev/null
ord outcome dev det-note useful >/dev/null
run1="$(ord recall dev --paths "det/x.sh" --keywords "")"
run2="$(ord recall dev --paths "det/x.sh" --keywords "")"
if [[ "$run1" == "$run2" ]]; then
    echo "ok   determinism: identical inputs produce identical output across runs"
else
    echo "FAIL determinism: identical inputs produce identical output across runs"
    fails=$((fails + 1))
fi
rm -rf "$OR_DET"

# --------------------------------------------------------------- (6) latency
# 200-note fixture; outcome parsing must add <200ms vs a no-outcomes baseline
# of the SAME corpus (outcomes are parsed once per invocation, per §14).
OR_LAT="$(mktemp -d)"
orl() { python3 "$OR_SCRIPTS/brain.py" "$OR_LAT" "$@"; }
for i in $(seq 1 200); do
    printf 'body %s\n' "$i" | orl mint dev "lat-$i" --tags lat --paths "lat/**" --source x >/dev/null
done
t0=$(python3 -c 'import time; print(time.time())')
orl recall dev --paths "lat/x.sh" --keywords "" >/dev/null
t1=$(python3 -c 'import time; print(time.time())')
for i in $(seq 1 40); do
    orl outcome dev "lat-$i" useful >/dev/null
done
t2=$(python3 -c 'import time; print(time.time())')
orl recall dev --paths "lat/x.sh" --keywords "" >/dev/null
t3=$(python3 -c 'import time; print(time.time())')
delta_ms="$(python3 -c "print(int((($t3 - $t2) - ($t1 - $t0)) * 1000))")"
if [[ "$delta_ms" -lt 200 ]]; then
    echo "ok   latency: outcome weighting adds <200ms on a 200-note fixture (${delta_ms}ms)"
else
    echo "FAIL latency: outcome weighting adds <200ms on a 200-note fixture (${delta_ms}ms)"
    fails=$((fails + 1))
fi
rm -rf "$OR_LAT"
