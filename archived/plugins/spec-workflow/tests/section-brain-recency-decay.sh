#!/usr/bin/env bash
# section-brain-recency-decay.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain recency decay (GL-010: retro-clock aging on recall's seed activation) =="

RD_SCRIPTS="$PLUGIN/scripts"

# helper: read the LAST logged seed activation for a given note slug out of
# a role's .activation.jsonl (log_event appends -- the file accumulates
# across every recall in the fixture, so "last" is the one from the most
# recent recall call).
_last_seed_activation() { # <activation.jsonl path> <slug>
    python3 - "$1" "$2" <<'PY'
import json, sys
path, slug = sys.argv[1], sys.argv[2]
val = None
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("event") == "seed" and obj.get("note") == slug:
            val = obj["activation"]
print(val)
PY
}

# ------------------------------------------------------------ (1) golden regression
# The EXACT corpus/fixture GL-003 froze for byte-identical recall (fresh
# retros.log, i.e. no retros ever marked): recency decay must add ZERO
# effect here -- missing retros.log means zero decay by construction (AC5),
# so this doubles as GL-010's own byte-identical-to-pre-change golden.
RD_GOLD="$(mktemp -d)"
rdg() { python3 "$RD_SCRIPTS/brain.py" "$RD_GOLD" "$@"; }
printf 'Golden lesson body for alpha.\n\nRelated: [[gold-beta]]\n' \
    | rdg mint dev gold-alpha --tags gold --paths "gold/**" --source "PR#1" >/dev/null
printf 'Golden lesson body for beta.\n' \
    | rdg mint dev gold-beta --tags gold --paths "gold-b/**" --source "PR#2" >/dev/null
out="$(rdg recall dev --paths "gold/x.sh" --keywords "")"
gold_expected="$(cat "$FIX/outcome-ranking-golden.txt")"
if [[ "$out" == "$gold_expected" ]]; then
    echo "ok   golden regression: byte-identical to pre-GL-010 recall (fresh retros.log)"
else
    echo "FAIL golden regression: byte-identical to pre-GL-010 recall (fresh retros.log)"
    fails=$((fails + 1))
fi
rm -rf "$RD_GOLD"

# --------------------------------------------------------------- (2) aging
# Two identical-strength notes seeded by the SAME glob. aaa-old-note was last
# touched 2020-01-01; zzz-fresh-note was last touched AFTER every retro. A
# hand-written retros.log puts exactly 6 retros after aaa-old-note's touch date
# (default grace K=3 -> overshoot 3) and 0 retros after zzz-fresh-note's touch.
RD_AGE="$(mktemp -d)"
rda() { python3 "$RD_SCRIPTS/brain.py" "$RD_AGE" "$@"; }
printf 'Aging lesson body OLD.\n' | rda mint dev aaa-old-note --tags age --paths "age/**" --source x >/dev/null
printf 'Aging lesson body FRESH.\n' | rda mint dev zzz-fresh-note --tags age --paths "age/**" --source x >/dev/null
python3 - "$RD_AGE" <<'PY'
import os, re, sys
root = sys.argv[1]
d = os.path.join(root, ".neural-network/identities/dev/brain/notes")
patches = {"aaa-old-note": "2020-01-01", "zzz-fresh-note": "2020-08-01"}
for slug, date in patches.items():
    p = os.path.join(d, slug + ".md")
    s = open(p).read()
    s = re.sub(r"created: .*", "created: %s" % date, s)
    s = re.sub(r"last-touched: .*", "last-touched: %s" % date, s)
    open(p, "w").write(s)
PY
mkdir -p "$RD_AGE/.neural-network/identities"
cat >"$RD_AGE/.neural-network/identities/retros.log" <<'EOF'
2020-02-01
2020-03-01
2020-04-01
2020-05-01
2020-06-01
2020-07-01
EOF
out="$(rda recall dev --paths "age/x.sh" --keywords "")"
fresh_pos="${out%%zzz-fresh-note*}"; old_pos="${out%%aaa-old-note*}"
check "aging: both notes still appear in output" "aaa-old-note" "$out"
check "aging: fresh note appears" "zzz-fresh-note" "$out"
if [[ "${#fresh_pos}" -lt "${#old_pos}" ]]; then
    echo "ok   aging: untouched-for-K+3-retros note ranks strictly below its just-touched twin"
else
    echo "FAIL aging: untouched-for-K+3-retros note ranks strictly below its just-touched twin"
    fails=$((fails + 1))
fi
ACT_LOG="$RD_AGE/.neural-network/identities/dev/brain/.activation.jsonl"
old_act="$(_last_seed_activation "$ACT_LOG" aaa-old-note)"
fresh_act="$(_last_seed_activation "$ACT_LOG" zzz-fresh-note)"
# base activation (strength 1, no outcomes) is 1.0 * (1 + 1/10) = 1.1;
# aaa-old-note decays by factor(default 0.85)^3 (overshoot 6-3) -> 1.1*0.614125 ~= 0.6755
check "aging: fresh note (0 elapsed retros) keeps undecayed activation" "1.1" "$fresh_act"
check "aging: old note (K+3 elapsed retros) shows decayed activation" "0.6755" "$old_act"
rm -rf "$RD_AGE"

# ---------------------------------------------------- (2b) exactly K retros: no decay yet
RD_ATK="$(mktemp -d)"
rdk() { python3 "$RD_SCRIPTS/brain.py" "$RD_ATK" "$@"; }
printf 'At-K lesson body.\n' | rdk mint dev at-k-note --tags atk --paths "atk/**" --source x >/dev/null
python3 - "$RD_ATK" <<'PY'
import os, re, sys
root = sys.argv[1]
p = os.path.join(root, ".neural-network/identities/dev/brain/notes/at-k-note.md")
s = open(p).read()
s = re.sub(r"created: .*", "created: 2020-01-01", s)
s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
open(p, "w").write(s)
PY
mkdir -p "$RD_ATK/.neural-network/identities"
cat >"$RD_ATK/.neural-network/identities/retros.log" <<'EOF'
2020-02-01
2020-03-01
2020-04-01
EOF
rdk recall dev --paths "atk/x.sh" --keywords "" >/dev/null
at_k_act="$(_last_seed_activation "$RD_ATK/.neural-network/identities/dev/brain/.activation.jsonl" at-k-note)"
check "aging: at exactly K=3 elapsed retros, activation is still undecayed (1.1)" "1.1" "$at_k_act"
rm -rf "$RD_ATK"

# --------------------------------------------------- (3) useful outcome resets decay
# Two identical-strength, identically-aged notes (both K+3 elapsed retros).
# zzz-reset-note additionally gets a `useful` outcome dated AFTER every retro --
# that must reset its touch clock (elapsed back to 0), so it out-ranks its
# equally-old-but-un-reset twin.
RD_RST="$(mktemp -d)"
rdr() { python3 "$RD_SCRIPTS/brain.py" "$RD_RST" "$@"; }
printf 'Reset lesson body A.\n' | rdr mint dev zzz-reset-note --tags rst --paths "rst/**" --source x >/dev/null
printf 'Reset lesson body B.\n' | rdr mint dev aaa-stale-note --tags rst --paths "rst/**" --source x >/dev/null
python3 - "$RD_RST" <<'PY'
import os, re, sys
root = sys.argv[1]
d = os.path.join(root, ".neural-network/identities/dev/brain/notes")
for slug in ("zzz-reset-note", "aaa-stale-note"):
    p = os.path.join(d, slug + ".md")
    s = open(p).read()
    s = re.sub(r"created: .*", "created: 2020-01-01", s)
    s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
    open(p, "w").write(s)
PY
mkdir -p "$RD_RST/.neural-network/identities"
cat >"$RD_RST/.neural-network/identities/retros.log" <<'EOF'
2020-02-01
2020-03-01
2020-04-01
2020-05-01
2020-06-01
2020-07-01
EOF
OUT_JSONL="$RD_RST/.neural-network/identities/dev/brain/outcomes.jsonl"
mkdir -p "$(dirname "$OUT_JSONL")"
cat >"$OUT_JSONL" <<'EOF'
{"schemaVersion": 1, "ts": "2020-08-01T00:00:00+00:00", "slug": "zzz-reset-note", "outcome": "useful", "task": null, "note": null}
EOF
# neutralize GL-003's outcome multiplier (step 0 -> always 1.0) so this test
# isolates the DECAY reset in particular, not the pre-existing useful-outcome
# ranking boost (which the useful outcome would otherwise also trigger,
# since it necessarily falls inside the outcome window whenever it's dated
# after every retro -- verify-fixture-isolates-intended-path).
mkdir -p "$RD_RST/.claude" "$RD_RST/.neural-network"
cat >"$RD_RST/.neural-network/project.yaml" <<'YAML'
schemaVersion: 2
methodology:
    outcomeMultiplierStep: 0
YAML
out="$(rdr recall dev --paths "rst/x.sh" --keywords "")"
reset_pos="${out%%zzz-reset-note*}"; stale_pos="${out%%aaa-stale-note*}"
if [[ "${#reset_pos}" -lt "${#stale_pos}" ]]; then
    echo "ok   useful-outcome reset: note with a within-window useful outcome outranks its equally-aged twin"
else
    echo "FAIL useful-outcome reset: note with a within-window useful outcome outranks its equally-aged twin"
    fails=$((fails + 1))
fi
rm -rf "$RD_RST"

# ------------------------------------------------------ (4) top-1 stability (locked)
# A frozen two-note corpus, recently touched (elapsed <= K under the default
# config) -- the pre-GL-010 top-1 note for this query must stay top-1.
RD_TOP="$(mktemp -d)"
rdt() { python3 "$RD_SCRIPTS/brain.py" "$RD_TOP" "$@"; }
printf 'Top note body -- higher strength.\n' | rdt mint dev top-note --tags topq --paths "topq/**" --source x >/dev/null
printf 'Top note body -- higher strength.\n' | rdt mint dev top-note --tags topq --paths "topq/**" --source x >/dev/null
printf 'Second note body.\n' | rdt mint dev second-note --tags topq --paths "topq/**" --source x >/dev/null
rdt retro-mark >/dev/null
out="$(rdt recall dev --paths "topq/x.sh" --keywords "")"
top_first="$(grep -m1 -oE 'top-note|second-note' <<<"$out")"
check "top-1 stability: top-note (higher strength) ranks first under default recency-decay config" "top-note" "$top_first"
rm -rf "$RD_TOP"

# --------------------------------------------------- (5) missing/empty retros.log
RD_MISS="$(mktemp -d)"
rdm() { python3 "$RD_SCRIPTS/brain.py" "$RD_MISS" "$@"; }
printf 'Missing-log lesson body.\n' | rdm mint dev miss-note --tags miss --paths "miss/**" --source x >/dev/null
python3 - "$RD_MISS" <<'PY'
import os, re, sys
root = sys.argv[1]
p = os.path.join(root, ".neural-network/identities/dev/brain/notes/miss-note.md")
s = open(p).read()
s = re.sub(r"created: .*", "created: 2020-01-01", s)
s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
open(p, "w").write(s)
PY
err="$(rdm recall dev --paths "miss/x.sh" --keywords "" 2>&1 >/dev/null)"
if [[ -z "$err" ]]; then
    echo "ok   missing retros.log: no warnings printed"
else
    echo "FAIL missing retros.log: no warnings printed — got: $err"
    fails=$((fails + 1))
fi
rdm recall dev --paths "miss/x.sh" --keywords "" >/dev/null 2>&1
miss_act="$(_last_seed_activation "$RD_MISS/.neural-network/identities/dev/brain/.activation.jsonl" miss-note)"
check "missing retros.log: zero decay even though the note is ancient (activation 1.1)" "1.1" "$miss_act"
rm -rf "$RD_MISS"

# empty retros.log file (present but zero lines) behaves the same as absent
RD_EMPTY="$(mktemp -d)"
rde() { python3 "$RD_SCRIPTS/brain.py" "$RD_EMPTY" "$@"; }
printf 'Empty-log lesson body.\n' | rde mint dev empty-note --tags emp --paths "emp/**" --source x >/dev/null
python3 - "$RD_EMPTY" <<'PY'
import os, re, sys
root = sys.argv[1]
p = os.path.join(root, ".neural-network/identities/dev/brain/notes/empty-note.md")
s = open(p).read()
s = re.sub(r"created: .*", "created: 2020-01-01", s)
s = re.sub(r"last-touched: .*", "last-touched: 2020-01-01", s)
open(p, "w").write(s)
PY
mkdir -p "$RD_EMPTY/.neural-network/identities"
: >"$RD_EMPTY/.neural-network/identities/retros.log"
err="$(rde recall dev --paths "emp/x.sh" --keywords "" 2>&1 >/dev/null)"
if [[ -z "$err" ]]; then
    echo "ok   empty retros.log: no warnings printed"
else
    echo "FAIL empty retros.log: no warnings printed — got: $err"
    fails=$((fails + 1))
fi
rde recall dev --paths "emp/x.sh" --keywords "" >/dev/null 2>&1
empty_act="$(_last_seed_activation "$RD_EMPTY/.neural-network/identities/dev/brain/.activation.jsonl" empty-note)"
check "empty retros.log: zero decay even though the note is ancient (activation 1.1)" "1.1" "$empty_act"
rm -rf "$RD_EMPTY"
