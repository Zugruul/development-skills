#!/usr/bin/env bash
# board.sh — generic GitHub Project board interface, driven by .claude/project.json (schemaVersion 1).
# Part of the spec-workflow plugin. All board reads/writes go through this script so the
# model never has to know field/option ids.
#
#   board.sh next [spec-id]           # prioritized + sequenced pick (guards applied) => PICK: #N
#   board.sh show <issue#>            # issue title + body + ALL comments (human feedback!)
#   board.sh move <issue#> <status>   # set Status (must be a statusFlow name)
#   board.sh prio <issue#> <P0|...>   # set Priority (must be a priority option name)
#   board.sh est  <issue#> <points>   # set Estimate
#   board.sh bug  "<title>" <prio> [<origin-issue#>]   # file a bug into Backlog
#   board.sh list [status]            # tab-separated: status, priority, #, title
#   board.sh comment <issue#> <<'EOF' ... EOF          # reply to humans on the issue (body on stdin)
#   board.sh edit-body <issue#> <file>                 # replace issue body (updated acceptance criteria)
#   board.sh fields                   # discover field + option ids (used by setup-project)
#   board.sh config                   # validate project.json and print a summary
#
# Env: PROJECT_CONFIG (config path override), BOARD (boards[].id override; default = first board).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="${PROJECT_CONFIG:-$ROOT/.claude/project.json}"
[[ -f "$CONFIG" ]] || { echo "ERROR: $CONFIG not found. Run the setup-project skill first." >&2; exit 1; }

# Resolve the active board's ids into shell vars (OWNER REPO PN PID STATUS_FIELD PRIO_FIELD EST_FIELD BUG_LABEL FIRST_STATUS)
eval "$(python3 - "$CONFIG" "${BOARD:-}" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
bid = sys.argv[2]
boards = cfg.get("boards") or sys.exit("ERROR: no boards in project.json")
b = next((x for x in boards if x["id"] == bid), boards[0])
f = b["fields"]
def sh(k, v): print(f'{k}={json.dumps(str(v))}')
sh("OWNER", b["owner"]); sh("REPO", b["repo"]); sh("PN", b["projectNumber"]); sh("PID", b["projectId"])
sh("STATUS_FIELD", f["status"]["fieldId"]); sh("PRIO_FIELD", f["priority"]["fieldId"])
sh("EST_FIELD", f.get("estimate", {}).get("fieldId", ""))
sh("BUG_LABEL", b.get("labels", {}).get("bug", "type:bug"))
sh("FIRST_STATUS", b["statusFlow"][0])
PY
)"

opt_id() { # $1=status|priority  $2=option name (case-insensitive) -> option id
    python3 - "$CONFIG" "${BOARD:-}" "$1" "$2" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1])); bid = sys.argv[2]
b = next((x for x in cfg["boards"] if x["id"] == bid), cfg["boards"][0])
opts = b["fields"][sys.argv[3]]["options"]
q = sys.argv[4].strip().lower()
print(next((v for k, v in opts.items() if k.lower() == q), ""))
PY
}

item_id() { # issue number -> project item id
    gh project item-list "$PN" --owner "$OWNER" --format json --limit 400 \
        -q ".items[] | select(.content.number==$1) | .id"
}

case "${1:-}" in
    next)
        _tmp="$(mktemp)"; trap 'rm -f "$_tmp"' EXIT
        gh project item-list "$PN" --owner "$OWNER" --format json --limit 400 >"$_tmp"
        python3 - "$CONFIG" "${BOARD:-}" "$_tmp" "${2:-}" <<'PY'
import json, re, sys
cfg = json.load(open(sys.argv[1])); bid = sys.argv[2]
data = json.load(open(sys.argv[3])); only_spec = sys.argv[4]
board = next((x for x in cfg["boards"] if x["id"] == bid), cfg["boards"][0])
flow = board["statusFlow"]
prios = list(board["fields"]["priority"]["options"])          # order = rank
specs = [s for s in cfg["specs"] if s["board"] == board["id"] and (not only_spec or s["id"] == only_spec)]

def classify(title):
    """title -> (spec, epic, epic_rank, tasknum) or None for untagged (bugs)."""
    for s in specs:
        m = re.match(re.escape(s["taskPrefix"]) + r"-(\d+)", title)
        if not m: continue
        n = int(m.group(1))
        for rank, e in enumerate(s["epics"]):
            if any(lo <= n <= hi for lo, hi in e["taskRanges"]):
                return s, e, rank, n
        return s, None, len(s["epics"]), n
    return None

def at_least(status, wanted):
    try: return flow.index(status) >= flow.index(wanted)
    except ValueError: return False

# epic completion map: (spec_id, epic_id) -> [statuses of its tasks]
epic_status = {}
for it in data["items"]:
    c = classify(it.get("title") or it.get("content", {}).get("title", ""))
    if c and c[1] is not None:
        epic_status.setdefault((c[0]["id"], c[1]["id"]), []).append(it.get("status") or flow[0])

def blocked(spec, epic):
    if epic is None: return None
    for g in epic.get("blockedBy", []):
        sts = epic_status.get((spec["id"], g["epic"]), [])
        if not sts or not all(at_least(st, g["untilStatus"]) for st in sts):
            return f'epic {g["epic"]} not fully {g["untilStatus"]}'
    return None

rows, held = [], []
for it in data["items"]:
    if it.get("status") != flow[0]: continue                  # Backlog only
    title = it.get("title") or it.get("content", {}).get("title", "")
    num = it.get("content", {}).get("number")
    pr = prios.index(it["priority"]) if it.get("priority") in prios else len(prios)
    c = classify(title)
    if c is None:                                             # untagged (bugs): priority decides, near front
        rows.append((pr, -1, 0, num, title)); continue
    spec, epic, erank, n = c
    why = blocked(spec, epic)
    if why: held.append((num, title, why)); continue
    rows.append((pr, erank, n, num, title))
rows.sort()
if not rows:
    print("(backlog empty" + (" or fully blocked)" if held else ")"))
else:
    print("Next candidates (prioritized + sequenced):")
    for pr, _, _, num, title in rows[:5]:
        p = prios[pr] if pr < len(prios) else "P?"
        print(f"  #{num}  [{p}]  {title}")
    print(f"\n=> PICK: #{rows[0][3]}  {rows[0][4]}")
for num, title, why in held[:5]:
    print(f"  BLOCKED #{num} {title}  ({why})")
PY
        ;;
    show)
        # --json avoids gh's default field set, which queries the deprecated
        # Projects-classic `projectCards` GraphQL field and errors on repos
        # that have classic projects disabled.
        gh issue view "$2" -R "$REPO" \
            --json number,title,state,body,comments \
            -q '"#\(.number) [\(.state)] \(.title)\n\n\(.body)\n" + (if (.comments | length) > 0 then "\n--- comments ---\n" + ([.comments[] | "[\(.author.login) @ \(.createdAt)]\n\(.body)\n"] | join("\n")) else "\n(no comments)" end)'
        ;;
    move)
        id="$(item_id "$2")"; opt="$(opt_id status "$3")"
        [[ -z "$id" || -z "$opt" ]] && { echo "ERROR: bad issue# or status '$3' (must match statusFlow)" >&2; exit 1; }
        gh project item-edit --id "$id" --project-id "$PID" --field-id "$STATUS_FIELD" --single-select-option-id "$opt" >/dev/null &&
            echo "moved #$2 -> $3"
        ;;
    prio)
        id="$(item_id "$2")"; opt="$(opt_id priority "$3")"
        [[ -z "$id" || -z "$opt" ]] && { echo "ERROR: bad issue# or priority '$3'" >&2; exit 1; }
        gh project item-edit --id "$id" --project-id "$PID" --field-id "$PRIO_FIELD" --single-select-option-id "$opt" >/dev/null &&
            echo "prio #$2 -> $3"
        ;;
    est)
        [[ -z "$EST_FIELD" ]] && { echo "ERROR: no estimate field configured" >&2; exit 1; }
        id="$(item_id "$2")"
        gh project item-edit --id "$id" --project-id "$PID" --field-id "$EST_FIELD" --number "$3" >/dev/null &&
            echo "est #$2 -> $3"
        ;;
    bug)
        title="$2"; prio="${3:-}"; link="${4:-}"
        [[ -z "$prio" ]] && prio="$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));b=c["boards"][0];print(list(b["fields"]["priority"]["options"])[0])' "$CONFIG")"
        body="Bug found after a task reached a released status; filed as new work (never reopen shipped tasks)."
        [[ -n "$link" ]] && body="$body Originating task: #$link."
        url=$(gh issue create -R "$REPO" --title "BUG: $title" --body "$body" --label "$BUG_LABEL")
        num=$(basename "$url")
        sleep 1
        "$0" move "$num" "$FIRST_STATUS"; "$0" prio "$num" "$prio"
        echo "filed bug #$num [$prio]"
        ;;
    list)
        gh project item-list "$PN" --owner "$OWNER" --format json --limit 400 \
            -q ".items[] | select((\"${2:-}\"==\"\") or (.status==\"${2:-}\")) | \"\(.status // \"-\")\t\(.priority // \"-\")\t#\(.content.number)\t\(.title // .content.title)\""
        ;;
    comment)
        gh issue comment "$2" -R "$REPO" --body-file - && echo "commented on #$2"
        ;;
    edit-body)
        gh issue edit "$2" -R "$REPO" --body-file "$3" && echo "updated body of #$2"
        ;;
    fields)
        gh project field-list "$PN" --owner "$OWNER" --format json |
            python3 -c '
import json, sys
for f in json.load(sys.stdin)["fields"]:
    print(f'"'"'{f["id"]}  {f["name"]}  ({f["type"]})'"'"')
    for o in f.get("options", []): print(f'"'"'    {o["id"]}  {o["name"]}'"'"')'
        ;;
    config)
        exec python3 "$(dirname "$0")/validate-config.py" "$CONFIG"
        ;;
    *)
        echo "usage: board.sh {next|show|move|prio|est|bug|list|comment|edit-body|fields|config} ..." >&2
        exit 1
        ;;
esac
