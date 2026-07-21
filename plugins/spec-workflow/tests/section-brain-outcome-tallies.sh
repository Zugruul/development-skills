#!/usr/bin/env bash
# section-brain-outcome-tallies.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain outcome tallies (GL-004/SPEC-GRAPHIFY §7 R7.6: status tallies + prune signal) =="

OT_SCRIPTS="$PLUGIN/scripts"

# ---------------------------------------------- (1) status golden: no outcomes.jsonl at all
# The bullet-line rendering for a role with NO outcomes.jsonl must be byte-identical to
# what cmd_directory already renders for that role today (captured from the UNMODIFIED
# code into fixtures/status-golden-lines.txt -- cmd_status reuses the same per-note line
# renderer as cmd_directory so this is byte-identical by construction, not by luck).
OT_ABSENT="$(mktemp -d)"
ota() { python3 "$OT_SCRIPTS/brain.py" "$OT_ABSENT" "$@"; }
printf 'Tally demo note body.\n' | ota mint dev tally-note --tags demo --paths "demo/**" --source x >/dev/null
printf 'Quiet note, never gets an outcome.\n' | ota mint dev quiet-note --tags demo --paths "demo/**" --source x >/dev/null
out="$(ota status dev)"
bullets="$(grep '^- \*\*' <<<"$out")"
gold="$(cat "$FIX/status-golden-lines.txt")"
if [[ "$bullets" == "$gold" ]]; then
    echo "ok   status (no outcomes.jsonl): bullet lines byte-identical to directory's today-rendering"
else
    echo "FAIL status (no outcomes.jsonl): bullet lines byte-identical to directory's today-rendering"
    fails=$((fails + 1))
fi
rm -rf "$OT_ABSENT"

# --------------------------------------------- (2) status golden: outcomes.jsonl exists but empty tallies
# outcomes.jsonl present (from an outcome recorded against a THIRD note) but the two demo
# notes above have zero outcomes of their own -- their bullet lines must still be
# byte-identical to the golden (G6-style invariant: presence of the file alone must not
# perturb notes it has nothing to say about).
OT_ZERO="$(mktemp -d)"
otz() { python3 "$OT_SCRIPTS/brain.py" "$OT_ZERO" "$@"; }
printf 'Tally demo note body.\n' | otz mint dev tally-note --tags demo --paths "demo/**" --source x >/dev/null
printf 'Quiet note, never gets an outcome.\n' | otz mint dev quiet-note --tags demo --paths "demo/**" --source x >/dev/null
printf 'Unrelated note with its own outcome.\n' | otz mint dev other-note --tags demo --paths "demo/**" --source x >/dev/null
otz outcome dev other-note useful >/dev/null
out="$(otz status dev)"
bullets="$(grep '^- \*\*' <<<"$out" | grep -v 'other-note')"
if [[ "$bullets" == "$gold" ]]; then
    echo "ok   status (outcomes.jsonl exists, zero for these notes): bullet lines still byte-identical"
else
    echo "FAIL status (outcomes.jsonl exists, zero for these notes): bullet lines still byte-identical"
    fails=$((fails + 1))
fi
rm -rf "$OT_ZERO"

# --------------------------------------------------- (3) status shows a tally when outcomes exist
OT_TALLY="$(mktemp -d)"
ott() { python3 "$OT_SCRIPTS/brain.py" "$OT_TALLY" "$@"; }
printf 'Tallied note body.\n' | ott mint dev tallied --tags demo --paths "demo/**" --source x >/dev/null
ott outcome dev tallied useful >/dev/null
ott outcome dev tallied useful >/dev/null
ott outcome dev tallied useful >/dev/null
ott outcome dev tallied dead_end >/dev/null
ott outcome dev tallied corrected --note "wrong path" >/dev/null
out="$(ott status dev)"
check "status: tally shows 3x useful" "3✓" "$out"
check "status: tally shows 1x dead_end" "1✗" "$out"
check "status: tally shows 1x corrected" "1⚠" "$out"
check "status: tallied slug still present" "tallied" "$out"
rm -rf "$OT_TALLY"

# ---------------------------------------------------------- (4) prune: dead-end note candidate
OT_PRUNE="$(mktemp -d)"
otp() { python3 "$OT_SCRIPTS/brain.py" "$OT_PRUNE" "$@"; }
printf 'A note that keeps failing in practice.\n' | otp mint dev flaky-lesson --tags demo --paths "demo/**" --source x >/dev/null
otp outcome dev flaky-lesson dead_end >/dev/null
otp outcome dev flaky-lesson dead_end >/dev/null
out="$(otp prune dev)"
check "prune: dead-end note appears as a candidate" "flaky-lesson" "$out"
check "prune: reason names the outcome rule" "dead_end" "$out"

# (4b) same note +1 useful -> no longer a candidate under this rule
otp outcome dev flaky-lesson useful >/dev/null
out2="$(otp prune dev)"
check_absent "prune: adding 1x useful removes the outcome-rule candidacy" "flaky-lesson" "$out2"

# --------------------------------------------------- (5) prune without --apply writes nothing
NOTES_BEFORE="$(command find "$OT_PRUNE/.claude/identities/dev/brain/notes" -type f | sort | xargs -I{} shasum {} 2>/dev/null)"
LINKS_BEFORE="$(cat "$OT_PRUNE/.claude/identities/dev/brain/links.json" 2>/dev/null || true)"
otp prune dev >/dev/null
NOTES_AFTER="$(command find "$OT_PRUNE/.claude/identities/dev/brain/notes" -type f | sort | xargs -I{} shasum {} 2>/dev/null)"
LINKS_AFTER="$(cat "$OT_PRUNE/.claude/identities/dev/brain/links.json" 2>/dev/null || true)"
if [[ "$NOTES_BEFORE" == "$NOTES_AFTER" && "$LINKS_BEFORE" == "$LINKS_AFTER" ]]; then
    echo "ok   prune without --apply: writes nothing (notes + links.json unchanged)"
else
    echo "FAIL prune without --apply: writes nothing (notes + links.json unchanged)"
    fails=$((fails + 1))
fi
rm -rf "$OT_PRUNE"

# --------------------------------------------------------------- (6) K is configurable
OT_CFG="$(mktemp -d)"
otc() { python3 "$OT_SCRIPTS/brain.py" "$OT_CFG" "$@"; }
mkdir -p "$OT_CFG/.claude"
cat >"$OT_CFG/.claude/project.yaml" <<'EOF'
project:
  name: cfg-test
methodology:
  outcomeDeadEndPruneThreshold: 1
EOF
printf 'One strike and out.\n' | otc mint dev one-strike --tags demo --paths "demo/**" --source x >/dev/null
otc outcome dev one-strike dead_end >/dev/null
out="$(otc prune dev)"
check "prune: K=1 flags a single dead_end as a candidate" "one-strike" "$out"
rm -rf "$OT_CFG"

# --------------------------------------------------------- (7) malformed outcomes.jsonl
# status/prune must never crash and must disable outcome features for the run (R7.7),
# reusing _read_outcomes -- not a re-test of its parsing rules, just the integration.
OT_MAL="$(mktemp -d)"
otm() { python3 "$OT_SCRIPTS/brain.py" "$OT_MAL" "$@"; }
printf 'Malformed-tolerant note.\n' | otm mint dev mal-tally --tags demo --paths "demo/**" --source x >/dev/null
MAL_JSONL="$OT_MAL/.claude/identities/dev/brain/outcomes.jsonl"
mkdir -p "$(dirname "$MAL_JSONL")"
printf 'not json\n' >"$MAL_JSONL"

err_status="$(otm status dev 2>&1 >/dev/null)"; rc_status=$?
check_rc "status: malformed outcomes.jsonl exits 0" 0 "$rc_status"
check "status: malformed outcomes.jsonl warns" "malformed" "$err_status"
out_status="$(otm status dev 2>/dev/null)"
check_absent "status: malformed outcomes.jsonl -- no tally rendered" "✓" "$out_status"

err_prune="$(otm prune dev 2>&1 >/dev/null)"; rc_prune=$?
check_rc "prune: malformed outcomes.jsonl exits 0" 0 "$rc_prune"
check "prune: malformed outcomes.jsonl warns" "malformed" "$err_prune"
rm -rf "$OT_MAL"
