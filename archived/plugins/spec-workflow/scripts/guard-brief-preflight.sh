#!/usr/bin/env bash
# guard-brief-preflight.sh — PreToolUse(Agent|Task) hook (#573): block the
# spawn of a `dev-*` / `reviewer-*` / `pr-reviewer-*` subagent whose brief lacks the required
# `## TODO UPKEEP` section (naming a task id), by running brief-preflight.sh.
#
# The agent name is tool_input.name when present, else the first word of
# tool_input.description (orchestrators write "dev-571 task-state move"). The
# brief is tool_input.prompt. Active only when the repo has spec-workflow
# config (.neural-network/project.yaml). Blocks with the documented
# PreToolUse JSON decision (permissionDecision "deny"), exit 0. FAILS OPEN on
# anything unexpected (bad JSON, no python3, odd shapes) with one stderr note:
# a broken guard must never block unrelated tools. No network call.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"

allow() { [[ -z "${1:-}" ]] || echo "guard-brief-preflight: $1; allowing." >&2; exit 0; }

command -v python3 >/dev/null 2>&1 || allow "python3 not found"

ROOT="$(spec_workflow_repo_root 2>/dev/null)" || allow "repo root not resolved"
[[ -f "$ROOT/.neural-network/project.yaml" ]] || exit 0

TMP="$(mktemp -d 2>/dev/null)" || allow "no temp dir"
trap 'rm -rf "$TMP"' EXIT

# Writes the agent name to $TMP/name and the brief to $TMP/brief; prints SKIP
# when this is not a dev/reviewer spawn, BAD on unusable input.
STATE="$(python3 -c '
import json, re, sys
tmp = sys.argv[1]
try:
    data = json.load(sys.stdin)
    if data.get("tool_name") not in ("Agent", "Task"):
        print("SKIP"); sys.exit(0)
    ti = data.get("tool_input")
    if not isinstance(ti, dict):
        print("SKIP"); sys.exit(0)
    name = ti.get("name")
    if not isinstance(name, str) or not name.strip():
        words = (ti.get("description") or "").split() if isinstance(ti.get("description"), str) else []
        name = words[0] if words else ""
    name = name.strip()
    if not re.match(r"(?i)(dev|reviewer|pr-reviewer)-", name):
        print("SKIP"); sys.exit(0)
    prompt = ti.get("prompt")
    prompt = prompt if isinstance(prompt, str) else ""
    open(tmp + "/name", "w").write(name)
    open(tmp + "/brief", "w").write(prompt)
    print("CHECK")
except Exception:
    print("BAD")
' "$TMP" 2>/dev/null)" || STATE="BAD"

case "$STATE" in
    SKIP) exit 0 ;;
    CHECK) ;;
    *) allow "could not read the hook input" ;;
esac

MSG="$(bash "$HERE/brief-preflight.sh" "$(cat "$TMP/name")" < "$TMP/brief" 2>&1 >/dev/null)"
rc=$?
[[ $rc -ne 0 ]] || exit 0
[[ $rc -eq 1 ]] || allow "brief-preflight.sh failed unexpectedly (exit $rc)"

python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": sys.argv[1]}}, indent=2))
' "$MSG" 2>/dev/null || allow "could not encode the block decision"
exit 0
