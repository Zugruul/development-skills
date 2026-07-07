#!/usr/bin/env bash
# seed-board.sh — idempotently seed a GitHub Project board from a task file.
# Part of the spec-workflow plugin; config comes from .claude/project.yaml.
#
# Usage: seed-board.sh <tasks-file>
#
# Task file format: one task per line, pipe-separated (blank lines and #-comments ignored):
#   <task-id>|<priority>|<points>|<epic-id>|<title>
#   e.g.  CP-001|P0|5|E0|Repo scaffold: pnpm workspace + tsconfig
# The task-id prefix must match a spec's taskPrefix in project.yaml; the issue body links to
# that spec's backlogPath for full acceptance criteria.
#
# Idempotent: a task whose issue title "<task-id>: <title>" already exists is skipped in
# phase 1, and phase 2 (re)applies Status/Priority/Estimate, so re-running is safe.
# Env: PROJECT_CONFIG, BOARD (same as board.sh).
set -uo pipefail

TASKS_FILE="${1:?usage: seed-board.sh <tasks-file>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$(python3 "$HERE/config.py" "$ROOT" path)"
[[ -n "$CONFIG" && -f "$CONFIG" ]] || { echo "ERROR: no .claude/project.yaml (or legacy .json) — run the setup-project skill first" >&2; exit 1; }

eval "$(python3 - "$CONFIG" "${BOARD:-}" <<'PY'
import json, sys
import config as C
cfg = C.load_config(path=sys.argv[1], warn=False); bid = sys.argv[2]
b = next((x for x in cfg["boards"] if x["id"] == bid), cfg["boards"][0])
def sh(k, v): print(f'{k}={json.dumps(str(v))}')
sh("OWNER", b["owner"]); sh("REPO", b["repo"]); sh("PN", b["projectNumber"]); sh("PID", b["projectId"])
sh("STATUS_FIELD", b["fields"]["status"]["fieldId"])
sh("STATUS_FIRST_ID", list(b["fields"]["status"]["options"].values())[0])
sh("PRIO_FIELD", b["fields"]["priority"]["fieldId"])
sh("EST_FIELD", b["fields"].get("estimate", {}).get("fieldId", ""))
sh("FEATURE_LABEL", b.get("labels", {}).get("feature", "type:feature"))
sh("BUG_LABEL", b.get("labels", {}).get("bug", "type:bug"))
sh("GATE_CMD", cfg["commands"]["gate"])
PY
)"

prio_id() { python3 - "$CONFIG" "${BOARD:-}" "$1" <<'PY'
import sys
import config as C
cfg = C.load_config(path=sys.argv[1], warn=False); bid = sys.argv[2]
b = next((x for x in cfg["boards"] if x["id"] == bid), cfg["boards"][0])
print(b["fields"]["priority"]["options"].get(sys.argv[3], ""))
PY
}

backlog_path() { # task-id -> that spec's backlogPath (or specPath)
    python3 - "$CONFIG" "$1" <<'PY'
import sys
import config as C
cfg = C.load_config(path=sys.argv[1], warn=False); tid = sys.argv[2]
for s in cfg["specs"]:
    if tid.startswith(s["taskPrefix"] + "-"):
        print(s.get("backlogPath") or s["specPath"]); sys.exit()
print("")
PY
}

read_tasks() { grep -vE '^\s*(#|$)' "$TASKS_FILE"; }

echo "==> ensuring labels"
gh label create "$FEATURE_LABEL" -R "$REPO" -c "#1D76DB" 2>/dev/null || true
gh label create "$BUG_LABEL" -R "$REPO" -c "#D73A4A" 2>/dev/null || true
while IFS='|' read -r id prio sp epic title; do
    gh label create "epic:$epic" -R "$REPO" -c "#5319E7" 2>/dev/null || true
done < <(read_tasks)

echo "==> Phase 1: ensure an issue exists for every task"
EXISTING="$(gh issue list -R "$REPO" --state all --limit 500 --json title -q '.[].title' || true)"
while IFS='|' read -r id prio sp epic title; do
    full="${id}: ${title}"
    if grep -Fxq "$full" <<<"$EXISTING"; then continue; fi
    bp="$(backlog_path "$id")"
    [[ -z "$bp" ]] && { echo "   !! $id: no spec in project.yaml matches this prefix — skipped"; continue; }
    body=$(cat <<EOF
**Epic:** $epic  ·  **Priority:** $prio  ·  **Story points (Estimate):** $sp

$title

Full acceptance criteria + Definition of Done: see \`$bp\` (task \`$id\`) and the referenced spec sections.

- [ ] Tests written first (TDD red -> green -> refactor)
- [ ] \`$GATE_CMD\` green
EOF
)
    echo "   create: $full"
    gh issue create -R "$REPO" --title "$full" --body "$body" \
        --label "$FEATURE_LABEL" --label "epic:$epic" >/dev/null
    sleep 0.3
done < <(read_tasks)

echo "==> Phase 2: set Status/Priority/Estimate on every task's project item"
MAP="$(mktemp)"; trap 'rm -f "$MAP"' EXIT
gh project item-list "$PN" --owner "$OWNER" --limit 500 --format json \
    -q '.items[] | [.id, (.content.title // .title)] | @tsv' >"$MAP"
while IFS='|' read -r id prio sp epic title; do
    full="${id}: ${title}"
    itemid="$(awk -F'\t' -v t="$full" '$2==t{print $1; exit}' "$MAP")"
    if [[ -z "$itemid" ]]; then
        url=$(gh issue list -R "$REPO" --search "$id in:title" --state all --json url -q '.[0].url')
        itemid=$(gh project item-add "$PN" --owner "$OWNER" --url "$url" --format json -q '.id' 2>/dev/null || true)
    fi
    if [[ -z "$itemid" ]]; then echo "   !! no project item for $full"; continue; fi
    gh project item-edit --id "$itemid" --project-id "$PID" --field-id "$STATUS_FIELD" --single-select-option-id "$STATUS_FIRST_ID" >/dev/null 2>&1 || echo "   ! status $full"
    gh project item-edit --id "$itemid" --project-id "$PID" --field-id "$PRIO_FIELD" --single-select-option-id "$(prio_id "$prio")" >/dev/null 2>&1 || echo "   ! prio $full"
    [[ -n "$EST_FIELD" ]] && { gh project item-edit --id "$itemid" --project-id "$PID" --field-id "$EST_FIELD" --number "$sp" >/dev/null 2>&1 || echo "   ! est $full"; }
    echo "   set: $full  [$prio, ${sp}sp]"
    sleep 0.25
done < <(read_tasks)
echo "==> done"
