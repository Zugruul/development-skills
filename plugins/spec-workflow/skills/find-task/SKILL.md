---
name: find-task
description: Ranked search of existing board issues (open + closed) by title/body similarity. Use for the /find-task <query> command, checking whether work already exists before filing something new, or "has this been reported before".
allowed-tools: Bash
---

# Find existing tasks

**Bare invocation** (no query given): ask the user for the search query and stop -- do not guess one.

**With a query**, pipe live board data through similar.py (the scoring engine; it never calls gh itself -- board.sh is the only board access):
```bash
ROOT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp)"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" issues > "$TMP" || { echo "board.sh issues failed"; rm -f "$TMP"; exit 1; }
SIMILAR_ISSUES_FILE="$TMP" python3 "${CLAUDE_PLUGIN_ROOT}/scripts/similar.py" "$ROOT" "<query>"
rm -f "$TMP"
```
Always invoke similar.py with python3, never bash -- it is a stdlib Python script, not a shell script, and bash on it dies parsing the module docstring.

Output is one line per match, ranked: `<tier>\t<score>\t#<number>\t<status>\t<title>`. Print the top 8 as a readable table (rank, `#number`, status, score, tier, title), each with its issue URL -- `https://github.com/<repo>/issues/<number>`, where `<repo>` is `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/config.py" "$ROOT" get boards.0.repo`. No matches at all: say so plainly, do not fabricate results.

## Rules
- Read-only, always -- find-task never creates, comments on, or repositions anything on the board.
- This is the search step create-inbound runs before deciding whether to create a new issue or point at an existing one.
