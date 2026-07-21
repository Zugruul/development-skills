#!/usr/bin/env bash
# section-brain-confidence.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain confidence frontmatter (GL-012: direct|inferred, default inferred) =="

CF_SCRIPTS="$PLUGIN/scripts"

_note_path() { # <root> <role> <slug>
    printf '%s\n' "$1/.claude/identities/$2/brain/notes/$3.md"
}

# ------------------------------------------------------ (1) explicit direct persists
CF1="$(mktemp -d)"
cf1() { python3 "$CF_SCRIPTS/brain.py" "$CF1" "$@"; }
printf 'Single concrete incident lesson.\n' \
    | cf1 mint dev direct-note --tags x --paths "x/**" --source "PR#1" --confidence direct >/dev/null
out="$(cat "$(_note_path "$CF1" dev direct-note)")"
check "explicit --confidence direct persists confidence: direct" "confidence: direct" "$out"

# omitting the flag writes NO confidence key
printf 'Cross-item generalization lesson.\n' \
    | cf1 mint dev inferred-note --tags x --paths "x/**" --source "PR#2" >/dev/null
out="$(cat "$(_note_path "$CF1" dev inferred-note)")"
check_absent "omitting --confidence writes no confidence key" "confidence:" "$out"

# ------------------------------------------------------ (2) existing corpus loads as inferred
CF2="$(mktemp -d)"
cf2() { python3 "$CF_SCRIPTS/brain.py" "$CF2" "$@"; }
printf 'Legacy note minted before GL-012 existed.\n' \
    | cf2 mint dev legacy-note --tags legacy --paths "legacy/**" --source "PR#3" >/dev/null
# simulate a pre-GL-012 note on disk: strip any confidence key entirely (there
# shouldn't be one from the mint above, but be explicit about the fixture's shape)
LEGACY_PATH="$(_note_path "$CF2" dev legacy-note)"
python3 - "$LEGACY_PATH" <<'PY'
import sys
p = sys.argv[1]
lines = [l for l in open(p, encoding="utf-8").read().split("\n") if not l.startswith("confidence:")]
open(p, "w", encoding="utf-8").write("\n".join(lines))
PY
# load_notes must parse the legacy (no-confidence) note with zero warnings and
# read confidence as absent (== inferred semantics per AC1/AC2)
out="$(python3 - "$CF2" <<PY
import sys, os
sys.path.insert(0, "$CF_SCRIPTS")
import brain
notes = brain.load_notes(os.path.join("$CF2", ".claude/identities"), "dev")
fm = notes["legacy-note"]["fm"]
print("confidence-absent" if "confidence" not in fm else "confidence-present:" + str(fm["confidence"]))
PY
)"
check "existing corpus note (no confidence field) loads as absent/inferred" "confidence-absent" "$out"
recall_out="$(cf2 recall dev --paths "legacy/x.sh" --keywords "" 2>&1)"
check_absent "recall over legacy corpus emits no warning" "warning" "$recall_out"

# ------------------------------------------------------ (3) upgrade / no-silent-downgrade
CF3="$(mktemp -d)"
cf3() { python3 "$CF_SCRIPTS/brain.py" "$CF3" "$@"; }
printf 'Started as a generalization.\n' \
    | cf3 mint dev evolving-note --tags x --paths "x/**" --source "PR#4" >/dev/null
out="$(cat "$(_note_path "$CF3" dev evolving-note)")"
check_absent "fresh mint without flag: no confidence key" "confidence:" "$out"

# re-mint with --confidence direct upgrades (evidence arrived)
printf 'Now backed by a single concrete incident.\n' \
    | cf3 mint dev evolving-note --tags x --paths "x/**" --source "PR#4" --confidence direct >/dev/null
out="$(cat "$(_note_path "$CF3" dev evolving-note)")"
check "re-mint with --confidence direct upgrades" "confidence: direct" "$out"

# re-mint WITHOUT the flag keeps direct (never silently downgrades)
printf 'Re-minted again, flag omitted this time.\n' \
    | cf3 mint dev evolving-note --tags x --paths "x/**" --source "PR#4" >/dev/null
out="$(cat "$(_note_path "$CF3" dev evolving-note)")"
check "re-mint omitting flag on a direct note keeps direct" "confidence: direct" "$out"

# re-mint with explicit --confidence inferred performs the downgrade AND
# notices -- on stderr, consistent with every other warning/notice in
# brain.py (all go through sys.stderr.write), never on stdout.
mint_stdout="$(printf 'Explicit downgrade requested.\n' \
    | cf3 mint dev evolving-note --tags x --paths "x/**" --source "PR#4" --confidence inferred 2>"$CF3/stderr.log")"
mint_stderr="$(cat "$CF3/stderr.log")"
check "explicit downgrade prints a notice on stderr" "notice" "$mint_stderr"
check_absent "explicit downgrade notice is not on stdout" "notice" "$mint_stdout"
out="$(cat "$(_note_path "$CF3" dev evolving-note)")"
check_absent "explicit downgrade removes confidence: direct" "confidence: direct" "$out"

# ------------------------------------------------------ (4) invalid value rejected
CF4="$(mktemp -d)"
cf4() { python3 "$CF_SCRIPTS/brain.py" "$CF4" "$@"; }
bad_out="$(printf 'Should never be written.\n' \
    | cf4 mint dev bad-note --tags x --paths "x/**" --source "PR#5" --confidence maybe 2>&1)"
bad_rc=$?
check_rc "invalid --confidence value exits non-zero" 1 "$( [[ $bad_rc -ne 0 ]] && echo 1 || echo 0 )"
check "invalid --confidence error lists 'direct'" "direct" "$bad_out"
check "invalid --confidence error lists 'inferred'" "inferred" "$bad_out"
BAD_PATH="$CF4/.claude/identities/dev/brain/notes/bad-note.md"
if [[ ! -f "$BAD_PATH" ]]; then
    echo "ok   invalid --confidence: note file not created"
else
    echo "FAIL invalid --confidence: note file not created"
    fails=$((fails + 1))
fi

rm -rf "$CF1" "$CF2" "$CF3" "$CF4"

# ------------------------------------------------------ (5) docs routing rule present
for f in "$PLUGIN/skills/retrospective/SKILL.md" "$PLUGIN/skills/feedback/SKILL.md"; do
    doc="$(cat "$f")"
    check "docs routing rule present in $(basename "$(dirname "$f")")/SKILL.md" "confidence" "$doc"
done
