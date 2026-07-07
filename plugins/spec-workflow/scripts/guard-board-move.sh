#!/usr/bin/env bash
# guard-board-move.sh — PreToolUse(Bash) hook: block `board.sh move <n> "In review"`
# unless gate.sh recorded a pass for the CURRENT tree state. Exit 2 = block (stderr
# goes back to the model); exit 0 = allow. Must stay fast — it runs on every Bash call.
#
# Parsing: the command string is tokenized with Python's stdlib shlex, then every
# `board.sh` argv token is located and its real argv[1] (subcommand) and argv[3]
# (target status) are read at their actual positions. Only an actual `move`
# invocation whose target status is the review-gate status can block; a status
# name appearing anywhere else — comment bodies, gh issue text, heredocs, other
# arguments — never trips the guard, and non-`move` subcommands always pass.
# Compound commands (`A && B`) are handled naturally: shlex still tokenizes the
# whole line, so the board.sh segment's argv is found regardless of what's
# before or after it.
#
# Shell-interpreter wrapping (`bash -c "board.sh move ..."`, `sh -c '...'`,
# an `env`-prefixed variant, or nested `bash -c 'bash -c "..."'`) would hide
# the real argv inside a single opaque token if we only scanned once — that
# was a silent gate bypass. So when a bash/sh/zsh/dash/ksh token is followed
# by a `-c`-ish flag (including combined clusters like `-lc`), the next token
# is treated as an inner command line and re-tokenized recursively (bounded
# depth; deeper nesting fails closed as unparseable, same as a raw unbalanced
# quote would).
#
# Fail-closed exception: if shlex can't tokenize a command/sub-command (e.g. an
# unbalanced quote) AND the raw text still contains both "board.sh" and "move",
# we can't prove it's safe, so we block with a distinct message rather than
# risk letting a real move through unparsed.
set -uo pipefail

RESULT="$(python3 -c '
import json, re, shlex, sys

REVIEW_STATUS = "in review"
INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh"}
MAX_DEPTH = 5

def norm(s):
    return re.sub(r"\s+", " ", s.strip().lower())

def is_c_flag(tok):
    return (
        tok.startswith("-")
        and not tok.startswith("--")
        and len(tok) > 1
        and tok[1:].isalpha()
        and "c" in tok[1:]
    )

def evaluate(command, depth):
    if depth > MAX_DEPTH:
        return "unparseable"
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        if "board.sh" in command and "move" in command:
            return "unparseable"
        return "allow"

    i, n = 0, len(tokens)
    while i < n:
        base = tokens[i].rsplit("/", 1)[-1]
        if base in INTERPRETERS and i + 2 < n and is_c_flag(tokens[i + 1]):
            result = evaluate(tokens[i + 2], depth + 1)
            if result != "allow":
                return result
            i += 3
            continue
        if base == "board.sh" and i + 3 < n:
            subcmd, status = tokens[i + 1], tokens[i + 3]
            if subcmd == "move" and norm(status) == REVIEW_STATUS:
                return "review-move"
        i += 1
    return "allow"

try:
    command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
except Exception:
    command = ""

print(evaluate(command, 0))
' 2>/dev/null)" || exit 0

case "$RESULT" in
    allow) exit 0 ;;
    unparseable)
        echo "BLOCKED: could not safely parse this command to confirm it isn't a move to 'In review'. Simplify it (avoid nesting board.sh inside quotes/heredocs) and retry." >&2
        exit 2
        ;;
esac

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
MARKER="$ROOT/.claude/gate-pass"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "$MARKER" ]]; then
    echo "BLOCKED: no recorded gate pass. Run \`bash \"$HERE/gate.sh\"\` to green (it records the pass), then retry the move to 'In review'." >&2
    exit 2
fi
if [[ "$(cat "$MARKER")" != "$(bash "$HERE/tree-state.sh")" ]]; then
    echo "BLOCKED: the tree changed since the last recorded gate pass. Re-run \`bash \"$HERE/gate.sh\"\`, then retry the move to 'In review'." >&2
    exit 2
fi
exit 0
