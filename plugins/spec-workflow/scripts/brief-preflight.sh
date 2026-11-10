#!/usr/bin/env bash
# brief-preflight.sh — check a subagent brief before it is delegated (#573).
#
# Usage: brief-preflight.sh <agent-name>      (brief on stdin)
#        brief-preflight.sh --agent <name>
#
# A dev or reviewer brief (agent name `dev-*` / `reviewer-*` / `pr-reviewer-*`, case-insensitive)
# MUST carry a `## TODO UPKEEP` section that names a task id ("Task id N; your
# role is <role>."), because that section is how the agent learns to keep the
# task-state record current. Missing section or missing task id: ONE line on
# stderr naming the problem, exit 1. Any other agent, or a brief that passes:
# exit 0. No network, no board, no config read. The Claude Code hook
# guard-brief-preflight.sh runs this; Codex users run it by hand before
# delegating (SPEC-CODEX-COMPAT §9 parity).
set -uo pipefail

AGENT=""
if [[ "${1:-}" == "--agent" ]]; then
    AGENT="${2:-}"
else
    AGENT="${1:-}"
fi
BRIEF="$(cat)"

lower="$(printf '%s' "$AGENT" | tr '[:upper:]' '[:lower:]')"
case "$lower" in
    dev-* | reviewer-* | pr-reviewer-*) ;;
    *) exit 0 ;;
esac

# The section runs from the `## TODO UPKEEP` heading to the next heading of
# level 1 or 2 (or the end of the brief). Fenced code blocks (``` or ~~~) are
# skipped for heading and section-end matches, so an example inside a fence
# is not the section.
SECTION="$(printf '%s\n' "$BRIEF" | awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; if (on) print; next }
    fence { if (on) print; next }
    tolower($0) ~ /^##[ \t]+todo[ \t]+upkeep([ \t(]|$)/ { on = 1; found = 1; next }
    on && /^##?[ \t]/ { on = 0 }
    on { print }
    END { if (!found) exit 3 }
')"
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "brief-preflight: $AGENT brief lacks the '## TODO UPKEEP (required)' section; paste it from skills/implement-task/SKILL.md and spawn again." >&2
    exit 1
fi

if ! printf '%s\n' "$SECTION" | grep -Eiq '(^|[^[:alnum:]_])task[[:space:]]+id[[:space:]:#]*[A-Za-z0-9_-]+'; then
    echo "brief-preflight: $AGENT brief's TODO UPKEEP section does not name a task id; write 'Task id N; your role is <role>.' and spawn again." >&2
    exit 1
fi
exit 0
