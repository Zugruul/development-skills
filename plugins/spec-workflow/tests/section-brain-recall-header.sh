#!/usr/bin/env bash
# section-brain-recall-header.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain recall header (GL-013/SPEC-GRAPHIFY §8 R8.4: confidence + outcome tally header) =="

RH_SCRIPTS="$PLUGIN/scripts"

# ------------------------------------------------- (1) golden header format
# confidence: direct + 3x useful outcomes must render the exact header
# format specified by GL-013: "[direct · 3× useful] <slug>" (full tier).
RH_A="$(mktemp -d)"
rha() { python3 "$RH_SCRIPTS/brain.py" "$RH_A" "$@"; }
printf 'A note with strong direct evidence.\n' \
    | rha mint dev header-note --tags hd --paths "hd/**" --source "PR#1" --confidence direct >/dev/null
rha outcome dev header-note useful >/dev/null
rha outcome dev header-note useful >/dev/null
rha outcome dev header-note useful >/dev/null
out="$(rha recall dev --paths "hd/x.sh" --keywords "")"
check "golden header: direct + 3x useful renders the exact bracket" "[direct · 3× useful] header-note" "$out"
rm -rf "$RH_A"

# --------------------------------------------- (2) zero-signal byte-identical
# A note with no outcomes, default (omitted/inferred) confidence, not stale,
# not contested must render byte-identical to pre-GL-013 output -- no bracket
# at all (G6).
RH_B="$(mktemp -d)"
rhb() { python3 "$RH_SCRIPTS/brain.py" "$RH_B" "$@"; }
printf 'A quiet note with nothing to say yet.\n' \
    | rhb mint dev quiet-note --tags qt --paths "qt/**" --source "PR#2" >/dev/null
out="$(rhb recall dev --paths "qt/x.sh" --keywords "")"
expected="$(printf '### quiet-note  [strength 1]\nA quiet note with nothing to say yet.')"
check "zero-signal note: byte-identical to pre-GL-013 rendering" "$expected" "$out"
if [[ "$out" == "$expected" ]]; then
    echo "ok   zero-signal note: exact byte match"
else
    echo "FAIL zero-signal note: exact byte match — got: $out"
    fails=$((fails + 1))
fi
rm -rf "$RH_B"

# -------------------------------- (3) confidence + tally + contested + stale
# All three signals present must compose into ONE line, fixed order:
# [confidence · tally] slug  [strength N]  <contested>  <stale>
RH_C="$(mktemp -d)"
git -C "$RH_C" init -q
git -C "$RH_C" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
rhc() { python3 "$RH_SCRIPTS/brain.py" "$RH_C" "$@"; }
printf 'Contested and stale but directly evidenced.\n' \
    | rhc mint dev combo-note --tags cb --paths "cb/*.sh" --source "PR#3" --confidence direct >/dev/null
rhc outcome dev combo-note useful >/dev/null
rhc outcome dev combo-note corrected --note "was wrong once" >/dev/null
python3 - "$RH_C" <<'PY'
import os, re, sys
root = sys.argv[1]
p = os.path.join(root, ".claude/identities/dev/brain/notes/combo-note.md")
s = open(p).read()
s = re.sub(r"created: .*", "created: 2020-01-01", s)
s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
open(p, "w").write(s)
PY
mkdir -p "$RH_C/cb"
echo 'echo hi' > "$RH_C/cb/x.sh"
git -C "$RH_C" add cb/x.sh
GIT_AUTHOR_DATE="2020-06-01T00:00:00" GIT_COMMITTER_DATE="2020-06-01T00:00:00" \
    git -C "$RH_C" -c user.email=t@t -c user.name=t commit -q -m "touch cb/x.sh"
out="$(rhc recall dev --paths "cb/x.sh" --keywords "")"
expected_line="[direct · 1× useful] combo-note  [strength 1]  ⚠ contested  ⟳ stale — re-verify"
check "combo: single line, fixed order, all three signals present" "$expected_line" "$out"
rm -rf "$RH_C"

# ------------------------------------------- (4) header counts against budget
# A note whose PLAIN header ("### slug  [strength N]\n<body>", 77 chars for
# this fixture) fits a tight budget, but whose signal-bearing header
# ("### [direct · 1× useful] slug  [strength N]\n<body>", 98 chars) does NOT
# -- the extra bracket must count against the budget math (issue's "budget
# math: headers count against the budget x CHARS_PER_TOKEN cap"), so recall
# must downgrade to the one-liner tier at the tight budget and render full
# (with header) once the budget is loosened past 98 chars. Both numbers
# below were computed directly from this fixture's slug/strength/body via
# brain._format_header_line (not guessed), then rounded up to whole
# --budget tokens (CHARS_PER_TOKEN=4): 80 chars (budget 20) sits inside
# [77, 98) -- too tight for the header, plenty for the plain form; 100 chars
# (budget 25) clears 98.
RH_D="$(mktemp -d)"
rhd() { python3 "$RH_SCRIPTS/brain.py" "$RH_D" "$@"; }
printf 'Short lesson body for the budget boundary test.\n' \
    | rhd mint dev budget-note --tags bg --paths "bg/**" --source x --confidence direct >/dev/null
rhd outcome dev budget-note useful >/dev/null
out_tight="$(rhd recall dev --paths "bg/x.sh" --keywords "" --budget 20)"
check_absent "budget boundary: tight budget (80 chars) can't fit the signal-bearing header -- downgrades to one-liner" \
    "[direct · 1× useful] budget-note" "$out_tight"
check "budget boundary: tight budget still renders the one-liner tier" "tags: [bg]" "$out_tight"
out_loose="$(rhd recall dev --paths "bg/x.sh" --keywords "" --budget 25)"
check "budget boundary: looser budget (100 chars) clears the header -- renders full tier with header" \
    "[direct · 1× useful] budget-note  [strength 1]" "$out_loose"
rm -rf "$RH_D"

# ------------------------------------------- (5) tier-downgrade tests unmoved
# The existing budget/tier-downgrade suites (section-brain.sh,
# section-brain-shrink-guard.sh) exercise notes with no confidence/outcome
# signal, so header composition must not change their boundaries -- covered
# by those files staying green, not re-tested here.

# ---------------------------------------------- (6) formatter helper unit tests
# _format_header_line is the reusable composition helper (GL-020 dependency):
# order is [confidence · tally] slug  [strength N]  <contested>  <stale>,
# each part omitted independently when it has nothing to say.
helper_out="$(python3 - "$RH_SCRIPTS" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import brain

cases = [
    ("inferred", 0, False, False),
    ("direct", 0, False, False),
    ("inferred", 3, False, False),
    ("direct", 3, False, False),
    ("direct", 3, True, False),
    ("direct", 3, True, True),
]
for confidence, useful, contested, stale in cases:
    print(brain._format_header_line("slug", 2, confidence, useful, contested, stale))
PY
)"
check "helper: inferred/0/not contested/not stale -> unchanged suffix, no bracket" \
    "slug  [strength 2]" "$(sed -n '1p' <<<"$helper_out")"
check "helper: direct/0 -> bracket with confidence only" \
    "[direct] slug  [strength 2]" "$(sed -n '2p' <<<"$helper_out")"
check "helper: inferred/3 useful -> bracket with tally only" \
    "[3× useful] slug  [strength 2]" "$(sed -n '3p' <<<"$helper_out")"
check "helper: direct/3 useful -> bracket combines both, separated by middle dot" \
    "[direct · 3× useful] slug  [strength 2]" "$(sed -n '4p' <<<"$helper_out")"
check "helper: contested flag appends after strength" \
    "[direct · 3× useful] slug  [strength 2]  ⚠ contested" "$(sed -n '5p' <<<"$helper_out")"
check "helper: stale flag appends last, after contested" \
    "[direct · 3× useful] slug  [strength 2]  ⚠ contested  ⟳ stale — re-verify" "$(sed -n '6p' <<<"$helper_out")"
