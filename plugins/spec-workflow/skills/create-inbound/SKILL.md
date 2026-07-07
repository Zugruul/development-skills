---
name: create-inbound
description: Search-first capture of ad-hoc ideas/bugs/requests onto the board, gated by duplicate detection. Use for the /create-inbound <description> command, filing a new task without leaving the session, or "add this to the backlog".
allowed-tools: Bash
---

# Create inbound task

**Bare invocation** (no description given): ask the user for the description and stop -- do not guess one.

**With a description**, run the dedup search first -- the same wiring find-task uses (board.sh is the only board access; similar.py never calls gh itself):
```bash
ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp)"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" issues > "$TMP" || { echo "board.sh issues failed"; rm -f "$TMP"; exit 1; }
SIMILAR_ISSUES_FILE="$TMP" python3 "${CLAUDE_PLUGIN_ROOT}/scripts/similar.py" "$ROOT" "<description>"
rm -f "$TMP"
```
Always invoke similar.py with python3, never bash -- it is a stdlib Python script, not a shell script.

Present the ranked candidates (rank, `#number`, status, score, tier, title, issue URL -- same table shape as find-task), then branch on the TOP match's tier:

## high -- do NOT create a new issue
Default: comment the description onto the existing issue instead (`board.sh comment <issue#>`), and tell the user which issue absorbed it. Creating a new issue anyway requires the human explicitly overriding this default -- ask via AskUserQuestion before creating.

## medium -- ask the human (OQ-4)
Present the candidate(s) and ask the human, via AskUserQuestion, whether this is the same work or genuinely new. If the human is absent or does not answer, do NOT create -- print the ranked candidates and the pending description, and stop.

## low or no match -- create
Ask for a priority if not given (default P2), then create it as inbound work:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" add --type inbound "<title>" "<prio>"
```
This labels the issue `inbound`, adds it to the board, and sets Backlog + priority. Report the new issue's URL (`https://github.com/<repo>/issues/<number>`) and that `find-task`/`next-task` can now see and pick it up from Backlog.

## Rules
- Never create without running the dedup search first.
- board.sh is the only board access -- never call `gh project`/`gh issue` directly.
- This skill only creates or comments; it never moves, re-prioritizes, or closes existing issues.
