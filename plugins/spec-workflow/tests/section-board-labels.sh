#!/usr/bin/env bash
# section-board-labels.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== board.sh ensure-labels (fake gh: label-list read failure must surface) =="
# Regression for #50: ensure-labels read existing labels with
#   _EXISTING_LABELS="$(gh label list ... 2>/dev/null || true)"
# The `2>/dev/null || true` swallowed any failure of the LIST query, leaving
# _EXISTING_LABELS empty and forcing rc=0. A transient list failure (rate
# limit, auth, 404) was thus invisible: the step then treated the repo as
# having zero labels and blindly attempted `gh label create` for every one --
# either lying "created label" or (when they already exist) misdirecting the
# user with a downstream "could not create label" that hid the real cause.
# The list read must be checked: a failed read fails the step, loudly.

LBG="$(mktemp -d)"; mkdir -p "$LBG/.claude"
cp "$FIX/valid.project.yaml" "$LBG/.claude/project.yaml"
LGH="$(mktemp -d)"
cat >"$LGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
    "label list")
        # a real gh label list can fail transiently (rate limit / auth / 404);
        # emit a non-empty stderr and a non-zero rc, like real gh does.
        echo "fake gh: label list boom" >&2
        exit 1
        ;;
    "label create")
        # creation itself would succeed here -- proving the step must NOT get
        # this far once it cannot even read the existing labels.
        : ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$LGH/gh"

out="$(cd "$LBG" && PATH="$LGH:$PATH" bash "$PLUGIN/scripts/board.sh" ensure-labels 2>&1; echo "rc=$?")"

check "ensure-labels: a failed label-list read is surfaced, not swallowed" "could not list existing labels" "$out"
check "ensure-labels: a failed label-list read exits nonzero" "rc=1" "$out"
check_absent "ensure-labels: does not claim to create labels it never verified" "created label" "$out"

rm -rf "$LBG" "$LGH"
