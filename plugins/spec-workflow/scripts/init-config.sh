#!/usr/bin/env bash
# init-config.sh — create or update .claude/project.yaml board ids from a live GitHub Project.
# Part of the spec-workflow plugin (used by the setup-project skill).
#
# Usage: init-config.sh <owner> <owner/repo> <project-number>
#
# Fetches the project id and its fields via gh, matches Status/Priority/Estimate by
# name, and writes boards[0] of .claude/project.yaml (schemaVersion 2):
#   - no config yet -> writes a fresh config from the plugin YAML template with real board ids
#   - project.yaml exists -> updates boards[0]'s ids/options in place, preserving the rest
#   - legacy project.json exists -> converts it to project.yaml (content preserved), and asks
#     you to delete the old project.json after review
# Then run: board.sh config   (must print VALID before using the workflow)
set -euo pipefail

OWNER="${1:?usage: init-config.sh <owner> <owner/repo> <project-number>}"
REPO="${2:?usage: init-config.sh <owner> <owner/repo> <project-number>}"
PN="${3:?usage: init-config.sh <owner> <owner/repo> <project-number>}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXISTING="$(PYTHONPATH="$HERE" python3 "$HERE/config.py" "$ROOT" path || true)"
OUT="${PROJECT_CONFIG:-$ROOT/.claude/project.yaml}"
TEMPLATE="$HERE/../templates/project.example.yaml"

_tmpdir="$(mktemp -d)"; trap 'rm -rf "$_tmpdir"' EXIT
gh project view "$PN" --owner "$OWNER" --format json >"$_tmpdir/project.json"
gh project field-list "$PN" --owner "$OWNER" --format json >"$_tmpdir/fields.json"

mkdir -p "$(dirname "$OUT")"
python3 - "$EXISTING" "$OUT" "$TEMPLATE" "$OWNER" "$REPO" "$PN" "$_tmpdir" <<'PY'
import json, os, sys
try:
    import yaml
except ImportError:
    print("PREFLIGHT FAIL: PyYAML required — pip3 install pyyaml"); sys.exit(1)

existing, out, template, owner, repo, pn, tmpdir = sys.argv[1:8]
project = json.load(open(os.path.join(tmpdir, "project.json")))
fields = json.load(open(os.path.join(tmpdir, "fields.json")))["fields"]


def load(path):
    text = open(path).read()
    return (yaml.safe_load(text) or {}) if path.endswith((".yaml", ".yml")) else json.loads(text)


def leading_comments(path):
    if not path.endswith((".yaml", ".yml")):
        return ""
    lead = []
    for line in open(path).read().splitlines(keepends=True):
        if line.strip().startswith("#") or not line.strip():
            lead.append(line)
        else:
            break
    return "".join(lead)


def field(name):
    return next((f for f in fields if f["name"].lower() == name.lower()), None)


status, prio, est = field("Status"), field("Priority"), field("Estimate")
missing = [n for n, f in (("Status", status), ("Priority", prio)) if not f or not f.get("options")]
if missing:
    sys.exit(f"ERROR: single-select field(s) missing or without options: {', '.join(missing)}. "
             "Create them first (see the setup-project skill's github-project-setup reference).")


def options(f):
    out_opts = {}
    for o in f["options"]:
        if o["name"] in out_opts:
            sys.exit(f"ERROR: field '{f['name']}' has duplicate option '{o['name']}' — remove one in the web UI.")
        out_opts[o["name"]] = o["id"]
    return out_opts


fresh = not existing
converting = bool(existing) and existing.endswith(".json") and out.endswith((".yaml", ".yml"))
src = existing or template
cfg = load(src)
out_is_yaml = out.endswith((".yaml", ".yml"))
cfg["schemaVersion"] = 2 if out_is_yaml else cfg.get("schemaVersion", 1)

board = cfg["boards"][0]
board.update({"owner": owner, "repo": repo, "projectNumber": int(pn), "projectId": project["id"]})
board.setdefault("fields", {})
board["fields"]["status"] = {"fieldId": status["id"], "options": options(status)}
board["fields"]["priority"] = {"fieldId": prio["id"], "options": options(prio)}
if est:
    board["fields"]["estimate"] = {"fieldId": est["id"]}
else:
    board["fields"].pop("estimate", None)
board["statusFlow"] = list(board["fields"]["status"]["options"])

head = leading_comments(src) if out_is_yaml else ""
if out_is_yaml and not head.strip():
    head = leading_comments(template)  # carry the schema modeline onto fresh/converted yaml
with open(out, "w") as fh:
    if out_is_yaml:
        fh.write(head)
        yaml.safe_dump(cfg, fh, sort_keys=False, default_flow_style=False, indent=4, allow_unicode=True)
    else:
        json.dump(cfg, fh, indent=4)
        fh.write("\n")

print(("created " if fresh else ("converted -> " if converting else "updated ")) + out)
print(f"  projectId: {project['id']}")
print(f"  statusFlow (from board options, reorder if needed): {board['statusFlow']}")
print(f"  priority options (order = rank, reorder if needed): {list(board['fields']['priority']['options'])}")
if converting:
    print(f"  NOTE: converted legacy {existing} -> {out}. Review it, then DELETE {existing}.")
if fresh:
    print("NEXT: fill in project/specs/commands (template values), then run: board.sh config")
else:
    print("NEXT: run: board.sh config")
PY

# Show how agent identities resolve on this clone (templates come from the config/defaults).
echo "agent identities (customize with the agent-identities skill; identity.sh <role> to inspect):"
bash "$HERE/identity.sh" --check
