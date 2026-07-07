#!/usr/bin/env bash
# init-config.sh — create or update .claude/project.json board ids from a live GitHub Project.
# Part of the spec-workflow plugin (used by the setup-project skill).
#
# Usage: init-config.sh <owner> <owner/repo> <project-number>
#
# Fetches the project id and its fields via gh, matches Status/Priority/Estimate by
# name, and writes boards[0] of .claude/project.json:
#   - no config yet -> writes a fresh config from the plugin template with real board ids
#     (specs/commands still contain template values to fill in)
#   - config exists -> updates boards[0]'s ids/options in place, preserving everything else
# Then run: board.sh config   (must print VALID before using the workflow)
set -euo pipefail

OWNER="${1:?usage: init-config.sh <owner> <owner/repo> <project-number>}"
REPO="${2:?usage: init-config.sh <owner> <owner/repo> <project-number>}"
PN="${3:?usage: init-config.sh <owner> <owner/repo> <project-number>}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="${PROJECT_CONFIG:-$ROOT/.claude/project.json}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$HERE/../templates/project.example.json"

_tmpdir="$(mktemp -d)"; trap 'rm -rf "$_tmpdir"' EXIT
gh project view "$PN" --owner "$OWNER" --format json >"$_tmpdir/project.json"
gh project field-list "$PN" --owner "$OWNER" --format json >"$_tmpdir/fields.json"

mkdir -p "$(dirname "$CONFIG")"
python3 - "$CONFIG" "$TEMPLATE" "$OWNER" "$REPO" "$PN" "$_tmpdir" <<'PY'
import json, os, sys
cfg_path, template, owner, repo, pn, tmpdir = sys.argv[1:7]
project = json.load(open(os.path.join(tmpdir, "project.json")))
fields = json.load(open(os.path.join(tmpdir, "fields.json")))["fields"]

def field(name):
    return next((f for f in fields if f["name"].lower() == name.lower()), None)

status, prio, est = field("Status"), field("Priority"), field("Estimate")
missing = [n for n, f in (("Status", status), ("Priority", prio)) if not f or not f.get("options")]
if missing:
    sys.exit(f"ERROR: single-select field(s) missing or without options: {', '.join(missing)}. "
             "Create them first (see the setup-project skill's github-project-setup reference).")

def options(f):
    out = {}
    for o in f["options"]:
        if o["name"] in out:
            sys.exit(f"ERROR: field '{f['name']}' has duplicate option '{o['name']}' — remove one in the web UI.")
        out[o["name"]] = o["id"]
    return out

fresh = not os.path.exists(cfg_path)
cfg = json.load(open(template if fresh else cfg_path))
board = cfg["boards"][0]
board.update({
    "owner": owner, "repo": repo, "projectNumber": int(pn), "projectId": project["id"],
})
board["fields"]["status"] = {"fieldId": status["id"], "options": options(status)}
board["fields"]["priority"] = {"fieldId": prio["id"], "options": options(prio)}
if est:
    board["fields"]["estimate"] = {"fieldId": est["id"]}
else:
    board["fields"].pop("estimate", None)
board["statusFlow"] = list(board["fields"]["status"]["options"])

json.dump(cfg, open(cfg_path, "w"), indent=4)
open(cfg_path, "a").write("\n")
print(("created " if fresh else "updated ") + cfg_path)
print(f"  projectId: {project['id']}")
print(f"  statusFlow (from board options, reorder if needed): {board['statusFlow']}")
print(f"  priority options (order = rank, reorder if needed): {list(board['fields']['priority']['options'])}")
if fresh:
    print("NEXT: fill in project/specs/commands (template values), then run: board.sh config")
else:
    print("NEXT: run: board.sh config")
PY

# Show how agent identities resolve on this clone (templates come from the config/defaults).
echo "agent identities (customize with the agent-identities skill; identity.sh <role> to inspect):"
bash "$HERE/identity.sh" --check
