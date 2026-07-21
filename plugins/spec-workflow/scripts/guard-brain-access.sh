#!/usr/bin/env bash
# guard-brain-access.sh — PreToolUse(Read,Bash) hook: block direct, raw
# content reads of `.claude/identities/<role>/brain/**` (notes, links.json,
# activation log, consults.json). brains.md's whole memory-isolation design
# rests on subagent briefs simply never mentioning a brain path — this makes
# "brain access only through brain.sh" a technical fact for the one host
# (Claude Code) where a PreToolUse hook can actually intercept it. See
# docs/design/cdx-E3.md, "Follow-up: #237 — gap #5 fix" for the full design
# rationale, including why this is universal (every caller, not just
# subagents) and why it's HOOK-ONLY (no host-neutral choke point exists for
# arbitrary file reads the way board.sh is one for board mutations).
#
# `ROLE.md` and `DIRECTORY.md` are deliberately OUT of scope — they live one
# path segment above brain/ and brains.md requires reading them verbatim.
#
# Grep/Glob and a repo-wide `grep -r`/`find -exec cat` sweep are deliberately
# NOT blocked (see design doc "Explicitly out of scope" #1) — only a
# TARGETED content-dump whose own argv names a brain path is blocked.
#
# Exit 2 = block (stderr goes back to the model); exit 0 = allow. Unlike
# guard-board-move.sh, this hook FAILS OPEN on anything unparseable or
# unrecognized: misclassifying an ordinary Read/Bash call as a brain-content
# dump would break unrelated work far more often than it would catch a real
# bypass (the design doc names this asymmetry explicitly).
set -uo pipefail

RESULT="$(python3 -c '
import json, re, shlex, sys

BRAIN_RE = re.compile(r"(?:^|/)\.claude/identities/[^/]+/brain/")
# Unanchored variant, used ONLY for the SCRIPT_INTERPRETERS branch below: a
# python3/node one-liner is a single shlex token containing the whole source
# string, so a brain path embedded mid-token inside a quoted literal (e.g.
# open('.claude/identities/dev/brain/x.md')) is never preceded by a literal
# "/" the way it would be as its own standalone argv token. BRAIN_RE itself
# stays anchored for Read/DUMP_CMDS, where the path IS its own token and the
# anchor is load-bearing against unrelated paths merely containing the
# substring elsewhere.
BRAIN_RE_UNANCHORED = re.compile(r"\.claude/identities/[^/]+/brain/")
INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh"}
DUMP_CMDS = {"cat", "head", "tail", "less", "more", "sed", "awk", "grep"}
SCRIPT_INTERPRETERS = {"python3", "python", "node"}
OPERATORS = {"&&", "||", ";", "|"}
MAX_DEPTH = 5

def is_c_flag(tok):
    return (
        tok.startswith("-")
        and not tok.startswith("--")
        and len(tok) > 1
        and tok[1:].isalpha()
        and "c" in tok[1:]
    )

def segment(tokens, start):
    j = start
    n = len(tokens)
    while j < n and tokens[j] not in OPERATORS:
        j += 1
    return tokens[start:j], j

def evaluate(command, depth):
    if depth > MAX_DEPTH:
        return "allow"
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        return "allow"

    i, n = 0, len(tokens)
    while i < n:
        base = tokens[i].rsplit("/", 1)[-1]
        if base in INTERPRETERS and i + 2 < n and is_c_flag(tokens[i + 1]):
            if evaluate(tokens[i + 2], depth + 1) == "block":
                return "block"
            i += 3
            continue
        if base in DUMP_CMDS:
            args, nxt = segment(tokens, i + 1)
            if any(BRAIN_RE.search(t) for t in args):
                return "block"
            i = nxt
            continue
        if base in SCRIPT_INTERPRETERS:
            # No "open("/"readFile" literal-substring gate: a bare brain-path
            # literal appearing anywhere in a python3/node one-liner argv is
            # already suspicious enough on its own -- pass-2 review found
            # that gate missed pathlib.Path(...).read_text()/.read_bytes(),
            # an idiomatic dump containing neither literal, and any future
            # dump idiom would face the same gap.
            args, nxt = segment(tokens, i + 1)
            has_brain = any(BRAIN_RE_UNANCHORED.search(t) for t in args)
            if has_brain:
                return "block"
            i = nxt
            continue
        i += 1
    return "allow"

try:
    payload = json.load(sys.stdin)
except Exception:
    payload = {}

tool_name = payload.get("tool_name", "Bash")
tool_input = payload.get("tool_input", {}) or {}

if tool_name == "Read":
    file_path = tool_input.get("file_path", "") or ""
    print("block" if BRAIN_RE.search(file_path) else "allow")
elif tool_name == "Bash":
    print(evaluate(tool_input.get("command", "") or "", 0))
else:
    print("allow")
' 2>/dev/null)" || exit 0

case "$RESULT" in
    block)
        echo "BLOCKED: direct reads of brain content are not allowed — use \`brain.sh recall/mint/consult/...\` instead." >&2
        exit 2
        ;;
    *) exit 0 ;;
esac
