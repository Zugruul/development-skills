#!/usr/bin/env bash
# seed-board.sh — idempotently seed a GitHub Project board from a task file.
# Part of the spec-workflow plugin; config comes from .claude/project.yaml.
#
# Usage: seed-board.sh <tasks-file>
#
# Task file format: one task per line, pipe-separated (blank lines and #-comments ignored):
#   <task-id>|<priority>|<points>|<epic-id>|<title>
#   e.g.  CP-001|P0|5|E0|Repo scaffold: pnpm workspace + tsconfig
# The task-id prefix must match a spec's taskPrefix in project.yaml. The issue body embeds
# the task's FULL backlog block (description, dependencies, acceptance criteria, spec-section
# citations) extracted from that spec's backlogPath, plus an artifacts/references section
# (spec path, per-epic design doc when present, ui-mode note); the backlog stays authoritative
# on drift. If the block can't be found (title-only seeding), the body falls back to the title
# with a warning.
#
# Idempotent: a task whose issue title "<task-id>: <title>" already exists is skipped in
# phase 1, and phase 2 (re)applies Status/Priority/Estimate, so re-running is safe.
# Env: PROJECT_CONFIG, BOARD (same as board.sh).
set -uo pipefail

TASKS_FILE="${1:?usage: seed-board.sh <tasks-file>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
source "$HERE/paginate.sh"  # gh_project_items_json / gh_issues_json (SPEC 7.4: no silent page-1 truncation)
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"
# #463: PRIMARY repo root -- board seeding reads/writes the shared project.yaml.
ROOT="$(spec_workflow_repo_root)" || { echo "ERROR: could not resolve repo root" >&2; exit 1; }
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

spec_meta() { # task-id -> "specPath<TAB>specId" for the matching spec ('' if none)
    python3 - "$CONFIG" "$1" <<'PY'
import sys
import config as C
cfg = C.load_config(path=sys.argv[1], warn=False); tid = sys.argv[2]
for s in cfg["specs"]:
    if tid.startswith(s["taskPrefix"] + "-"):
        print(s["specPath"] + "\t" + s["id"]); sys.exit()
print("")
PY
}

task_block() { # backlog-file task-id -> that task's full markdown block ('' if not found)
    python3 - "$1" "$2" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); tid = sys.argv[2]
if not p.exists():
    print(""); sys.exit()
text = p.read_text(encoding="utf-8")
# Block = from the task's "- **ID**" bullet up to the next task bullet or section header.
m = re.search(
    rf'^- \*\*{re.escape(tid)}\*\*.*?(?=^- \*\*[A-Z][A-Z0-9]*-\d+\*\*|^## |\Z)',
    text, re.M | re.S)
print(m.group(0).rstrip() if m else "")
PY
}

read_tasks() { grep -vE '^\s*(#|$)' "$TASKS_FILE"; }

echo "==> ensuring labels"
bash "$HERE/board.sh" ensure-labels || { echo "ERROR: ensure-labels failed" >&2; exit 1; }
while IFS='|' read -r id prio sp epic title; do
    gh label create "epic:$epic" -R "$REPO" -c "#5319E7" 2>/dev/null || true
done < <(read_tasks)

echo "==> Phase 1: ensure an issue exists for every task"
EXISTING="$(gh_issues_json "$REPO" --state all --json title | python3 -c '
import json, sys
for it in json.load(sys.stdin):
    print(it.get("title") or "")
' || true)"
while IFS='|' read -r id prio sp epic title; do
    full="${id}: ${title}"
    if grep -Fxq "$full" <<<"$EXISTING"; then continue; fi
    bp="$(backlog_path "$id")"
    [[ -z "$bp" ]] && { echo "   !! $id: no spec in project.yaml matches this prefix — skipped"; continue; }
    meta="$(spec_meta "$id")"
    sp_path="${meta%%$'\t'*}"; spec_id="${meta##*$'\t'}"
    block="$(task_block "$ROOT/$bp" "$id")"
    if [[ -z "$block" ]]; then
        echo "   ! $id: task block not found in $bp — issue body falls back to title only"
        block="$title"
    fi
    design_line=""
    design_doc="docs/design/${spec_id}-${epic}.md"
    [[ -n "$spec_id" && -f "$ROOT/$design_doc" ]] && design_line=$'\n'"- Design doc: \`$design_doc\`"
    body=$(cat <<EOF
**Epic:** $epic  ·  **Priority:** $prio  ·  **Story points (Estimate):** $sp

$block

---

**Artifacts & references**
- Spec: \`$sp_path\` (the §s cited above define the requirements this task implements)
- Backlog: \`$bp\` (task \`$id\`) — **authoritative**: if this issue body ever drifts from the backlog/spec, the repo files win$design_line
- UI-affecting tasks: iterative-UI decisions and final screenshots are folded into this issue by \`/refine-task-ui\` (ui-mode); implementation artifacts (PRs, spec deltas) link back here

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
gh_project_items_json "$PN" "$OWNER" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for it in data.get("items", []):
    content = it.get("content") or {}
    title = content.get("title") or it.get("title") or ""
    print("{}\t{}".format(it["id"], title))
' >"$MAP"
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
