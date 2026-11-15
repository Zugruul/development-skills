#!/usr/bin/env bash
# brief-preflight.sh — check a subagent brief before it is delegated (#573).
#
# Usage: brief-preflight.sh <agent-name>      (brief on stdin)
#        brief-preflight.sh --agent <name>
#
# A dev or reviewer brief (agent name `dev-*` / `reviewer-*` / `pr-reviewer-*`, case-insensitive)
# MUST carry a `## TODO UPKEEP` section that names a task id ("Task id N; your
# role is <role>."), because that section is how the agent learns to keep the
# task-state record current. Missing section and/or missing task id: one
# refusal on stderr listing every problem plus the block to paste, exit 1. Any other agent, or a brief that passes:
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

# Every rule is checked in ONE pass and every failure is reported in ONE refusal,
# followed by the complete block to paste, filled in where it can be: the role
# comes from the agent name (dev-* -> dev, reviewer-* / pr-reviewer-* ->
# reviewer); the task id from the brief ("Task id X" anywhere, else "issue #N"),
# else from a numeric agent name (dev-571, reviewer-571-spec), else it stays N.
# The block is the same text implement-task/SKILL.md shows (a test pins it).

case "$lower" in
    dev-*) ROLE="dev" ;;
    *) ROLE="reviewer" ;;
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
HAS_SECTION=1
[[ $rc -eq 0 ]] || HAS_SECTION=0

PROBLEMS=()
if [[ $HAS_SECTION -eq 0 ]]; then
    PROBLEMS+=("the brief lacks the '## TODO UPKEEP (required)' section.")
fi
if ! printf '%s\n' "$SECTION" | grep -Eiq '(^|[^[:alnum:]_])task[[:space:]]+id[[:space:]:#]*[A-Za-z0-9_-]+'; then
    PROBLEMS+=("the TODO UPKEEP section does not name a task id (its first line must read 'Task id N; your role is <role>.').")
fi
[[ ${#PROBLEMS[@]} -eq 0 ]] && exit 0

# Best-effort task id for the block (never a reason to pass).
ID="$(printf '%s\n' "$BRIEF" | grep -Eio '(^|[^[:alnum:]_])task[[:space:]]+id[[:space:]:#]*[0-9]+' | head -1 | grep -Eo '[0-9]+$')"
[[ -n "$ID" ]] || ID="$(printf '%s\n' "$BRIEF" | grep -Eio 'issue[[:space:]]+#[0-9]+' | head -1 | grep -Eo '[0-9]+$')"
[[ -n "$ID" ]] || ID="$(printf '%s' "$lower" | sed -nE 's/^(pr-reviewer|reviewer|dev)-([0-9]+)([^0-9].*)?$/\2/p')"
FILLED=1
[[ -n "$ID" ]] || { ID="N"; FILLED=0; }

{
    n=${#PROBLEMS[@]}
    if [[ $n -eq 1 ]]; then
        echo "brief-preflight: $AGENT brief refused, 1 problem:"
    else
        echo "brief-preflight: $AGENT brief refused, $n problems:"
    fi
    i=1
    for p in "${PROBLEMS[@]}"; do echo "  $i. $p"; i=$((i + 1)); done
    if [[ $HAS_SECTION -eq 1 ]]; then
        echo "Replace the brief's TODO UPKEEP section with this block, then spawn again:"
    else
        echo "Paste this block into the brief as its own section, then spawn again:"
    fi
    [[ $FILLED -eq 1 ]] || echo "(no task id found in the brief: replace N with the issue number the task-state record uses)"
    echo
    cat <<BLOCK
## TODO UPKEEP (required)
Task id $ID; your role is $ROLE. The human watches this record live. Run \`bash <resolved-plugin-root>/scripts/task-state.sh show --id $ID\` first, since others may have changed it.
- Completion: tick a TODO when it is really finished, one at a time, not in a batch at the end: \`task-state.sh todo --id $ID --done <number> --agent $ROLE\`.
- Start: mark a TODO with \`task-state.sh todo --id $ID --start <number> --agent $ROLE\` when you begin it, and do not leave it set after you stop (done, undo and drop clear it). Several agents may each have one active.
- Scope change: add new work with \`task-state.sh todo --id $ID --add "<text>" --agent $ROLE\`; when work leaves scope, \`task-state.sh todo --id $ID --drop <number> --agent $ROLE\`. Do this when the change happens, including when an issue comment or review changes scope.
- Order: insert new work where it really happens with \`task-state.sh todo --id $ID --add "<text>" --before <number> --agent $ROLE\`, normally before the gate, review and merge items it must precede, never at the end by default. \`task-state.sh todo --id $ID --move <number> --before <number> --agent $ROLE\` fixes an item already in the wrong place. Numbers never change, so \`--done 5\` always means the same TODO. If you re-gate after a fix, the gate item stays after the fix.
- Regression or rework: when a check fails or a finding sends the work back to an earlier step, reopen every TODO that is no longer true with \`task-state.sh todo --id $ID --undo <number> --agent $ROLE\`, before starting the fix. Example: a failed review reopens "implementation" and "gate green". Re-tick only after the redo is finished.
- Reviewers record findings: a finding that needs a fix is added as a TODO or reopens one.
- Always pass \`--agent $ROLE\` and task id $ID.
BLOCK
} >&2
exit 1
