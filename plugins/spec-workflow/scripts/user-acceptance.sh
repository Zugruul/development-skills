#!/usr/bin/env bash
# user-acceptance.sh — record that the human accepted a task without a
# reviewer APPROVE (#562). Called by `board.sh move N QA --accepted-by-user`
# BEFORE the two-pass review guard runs, so the same move passes.
#
# Usage: user-acceptance.sh --task N --status <target> --quote "<words>" --repo OWNER/REPO [--root DIR]
# Order: validate (nonblank quote, QA target) -> telemetry `user-acceptance`
# event FIRST (local, cheap; the durable evidence) -> ONE REST issue comment
# (`gh api -X POST repos/<repo>/issues/<N>/comments`, no GraphQL).
# Idempotent: if the task's latest relevant event is already a still-valid
# acceptance, both are skipped (a retry after a failed move only needs the move). A comment failure (rate
# limit or other) warns on stderr and exits 0: board trouble never stops work.
# Refusals (exit 2) record nothing and make no gh call.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"
USAGE="usage: user-acceptance.sh --task N --status S --quote Q --repo OWNER/REPO [--root DIR]"
TASK="" STATUS="" QUOTE="" ROOT="" REPO="" HAVE_QUOTE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --task) TASK="${2-}"; shift 2 || break ;;
        --status) STATUS="${2-}"; shift 2 || break ;;
        --quote) QUOTE="${2-}"; HAVE_QUOTE=1; shift 2 || break ;;
        --repo) REPO="${2-}"; shift 2 || break ;;
        --root) ROOT="${2-}"; shift 2 || break ;;
        *) echo "$USAGE" >&2; exit 2 ;;
    esac
done
[[ -n "$TASK" && -n "$REPO" ]] || { echo "$USAGE" >&2; exit 2; }
if [[ "$HAVE_QUOTE" -ne 1 || -z "${QUOTE//[[:space:]]/}" ]]; then
    echo "REFUSED: --accepted-by-user needs the user's actual words as a nonblank quote." >&2
    exit 2
fi
norm="$(python3 -c 'import re,sys; print(re.sub(r"\s+"," ",sys.argv[1].strip()).lower())' "$STATUS")"
if [[ "$norm" != "qa" ]]; then
    echo "REFUSED: --accepted-by-user is only valid when moving to QA (got '$STATUS')." >&2
    exit 2
fi
[[ -n "$ROOT" ]] || ROOT="$(spec_workflow_repo_root)" || { echo "ERROR: could not resolve repo root" >&2; exit 2; }

_pending_round() {
    python3 - "$ROOT/.claude/telemetry.jsonl" "$TASK" <<'PY'
import json, sys
pending = []
for line in open(sys.argv[1]).read().splitlines():
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if not isinstance(r, dict) or str(r.get("task")) != sys.argv[2]:
        continue
    if r.get("kind") == "review-round-start":
        pending.append(r.get("round"))
    elif r.get("kind") == "review-round" and "pass" not in r and r.get("round") in pending:
        pending.remove(r.get("round"))
print(",".join(str(p) for p in pending))
PY
}

# An acceptance that still counts (recorded after the task's last review-round
# line, no round pending) is enough: a retry only needs the move. Otherwise
# record a fresh one. Order is file position, never timestamps.
if python3 - "$ROOT/.claude/telemetry.jsonl" "$TASK" <<'PY'
import json, sys
try:
    lines = open(sys.argv[1]).read().splitlines()
except OSError:
    sys.exit(1)
accepted, pending = False, set()
for line in lines:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if not isinstance(r, dict) or str(r.get("task")) != sys.argv[2]:
        continue
    k = r.get("kind")
    if k == "user-acceptance":
        accepted = True
    elif k in ("review-round", "review-round-start"):
        accepted = False
        if k == "review-round-start":
            pending.add(r.get("round"))
        elif "pass" not in r:
            pending.discard(r.get("round"))
if pending:
    sys.exit(3)
sys.exit(0 if accepted else 1)
PY
then
    echo "user acceptance for #$TASK already recorded and still current; skipping event and comment"
    exit 0
else
    _rc=$?
    if [[ "$_rc" -eq 3 ]]; then
        echo "REFUSED: a review round is pending for #$TASK (round $(_pending_round)); record its verdict (review-round.sh / telemetry.py record) before accepting. Nothing recorded." >&2
        exit 2
    fi
fi

EVENT="$(python3 -c 'import json,sys,datetime
print(json.dumps({"kind":"user-acceptance","task":sys.argv[1],"quote":sys.argv[2],
 "ts":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}))' "$TASK" "$QUOTE")"
python3 "$HERE/telemetry.py" "$ROOT" record "$EVENT" >/dev/null || exit 1

BODYF="$(mktemp)" || { echo "WARN: could not create a temp file for the acceptance comment on #$TASK (the telemetry event holds the quote)" >&2; exit 0; }
trap 'rm -f "$BODYF"' EXIT
{
    printf 'Accepted by the user without a reviewer APPROVE (task #%s).\n\nUser'"'"'s words:\n\n' "$TASK"
    printf '%s\n' "$QUOTE" | sed 's/^/> /'
} >"$BODYF"
if ! err="$(gh api -X POST "repos/$REPO/issues/$TASK/comments" -F "body=@$BODYF" 2>&1 >/dev/null)"; then
    echo "WARN: could not post the acceptance comment on #$TASK (the telemetry event holds the quote): $err" >&2
    exit 0
fi
echo "recorded user acceptance for #$TASK"
