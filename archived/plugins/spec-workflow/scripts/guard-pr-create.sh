#!/usr/bin/env bash
# guard-pr-create.sh — PreToolUse(Bash) hook: block `gh pr create` unless the
# PR body references a board issue ("Closes #N"/"Fixes #N" or "<slug>#N"),
# with a remediation message telling the agent to file/pick the issue first
# (issue #76 — board-reflects enforcement, PR-creation side). Also warns
# (never blocks) when the current branch doesn't match
# project.branchPattern.
#
# NOT registered in this plugin's hooks.json — unlike guard-board-move.sh
# (which every consumer gets automatically), this guard is opt-in per
# consumer repo. See the plugin README for the PreToolUse snippet to add to
# a repo's own .claude/settings.json.
#
# Parsing discipline (SW-011): the command string is tokenized with Python's
# stdlib shlex and only the real argv of an actual `gh pr create` invocation
# is inspected — a "#76" sitting in an unrelated argument (a --title value,
# a filename) is never substring-matched as if it were the PR body.
# Shell-interpreter wrapping (`bash -c "gh pr create ..."`, `sh -c '...'`, a
# nested `bash -c 'bash -c "..."'`) is unwrapped the same bounded-depth way
# guard-board-move.sh does; an unbalanced-quote command that still mentions
# gh/pr/create fails closed as unparseable, same as guard-board-move.sh.
#
# Two layers of defense against a heredoc BODY (text being WRITTEN to a
# file, e.g. via `cat > f <<EOF`) being mistaken for a real invocation —
# SW-011's exact false-positive class, since shlex has no concept of
# heredocs and flattens the body into the same token stream as everything
# else:
#
# Layer 1 — heredoc-range exclusion (review round 3, BLOCKING; the round-1
# fix below was NOT sufficient on its own). BEFORE tokenization, a
# lightweight quote-aware line scanner finds each unquoted `<<`/`<<-`
# operator, reads its delimiter (bare or quoted — quoting the delimiter
# only disables expansion inside the body, it does not change what counts
# as the matching terminator line), and drops every line from just after
# the operator through the matching terminator line (word-for-word; `<<-`
# strips leading TABS, only tabs, from both body and terminator lines
# before the comparison, per bash). Those dropped lines never reach
# tokenization at all, so nothing inside them — including a literal `&&`/
# `;`/`gh pr create` sitting in the WRITTEN text — can be scanned, matched,
# or flip any tracking state. `<<<` (here-strings, no body lines) is left
# alone. An unterminated heredoc (no matching terminator line found before
# the command ends) fails closed as unparseable — there's no way to know
# where the body actually ends.
#
# Layer 2 — command-start-position tracking (review round 1). Once heredoc
# bodies are gone, `gh pr create` still only counts as an invocation at a
# genuine command-start position — token 0, or the token right after a
# `;`/`&&`/`||`/`|`/`&` operator — so an argument to some OTHER command
# (e.g. `echo gh pr create`) is still never matched. Leading `VAR=value`
# environment assignments and an `env` prefix are treated as still "before
# the command" so a legitimate `env FOO=bar gh pr create ...` is still
# caught.
#
# Known residual gaps (named honestly, not implied to be covered): the
# line scanner is a lightweight quote-tracker, not a full shell parser — a
# `<<` appearing inside a `$(...)`/backtick command substitution is
# scanned the same as top-level text, which is usually harmless (it's
# still inside quotes or its own nested heredoc syntax) but is not
# specially modeled. A heredoc whose delimiter itself is dynamically built
# (unlikely in practice) is not handled differently from a literal one.
#
# Body sourcing: --body/-b's value is used directly. --body-file/-F's value
# is read from disk UNLESS it is `-` (stdin) — that content is invisible to
# a PreToolUse hook, so it fails closed with a message to use a real file
# instead (mirrors the board-comment-bodies-via-file lesson: pass bodies via
# a file, not a heredoc/stdin, so they stay inspectable here). Neither flag
# given (e.g. `--fill`, an interactive prompt) also fails closed — there is
# nothing to check.
#
# --body-file path resolution (review round 1, BLOCKING): a relative path
# resolves against the hook process's ACTUAL cwd (os.getcwd()) — NOT
# unconditionally against the repo root, which produced false
# blocks/allows whenever the session's cwd was a subdirectory. A leading
# `cd <dir>` (or `pushd <dir>`) at a command-start position BEFORE the `gh
# pr create` match, in the SAME command string, is tracked and folded into
# that resolution too. KNOWN RESIDUAL GAP: a `cd` whose target is a shell
# variable/command-substitution (`cd "$DIR"`), or a `cd` that happened in an
# EARLIER, separate Bash tool call whose runtime doesn't carry cwd forward
# to this hook's own process, is not statically resolvable and is left
# untracked (the guard falls back to its best-known cwd rather than
# guessing).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC2016  # this is Python source in single quotes, not a
# shell expansion -- a Python comment inside it mentions "$VAR"-shaped text.
OUT="$(python3 -c '
import json, os, re, shlex, subprocess, sys

HERE = sys.argv[1]
INTERPRETERS = {"bash", "sh", "zsh", "dash", "ksh"}
DIR_COMMANDS = {"cd", "pushd"}
NEW_COMMAND_OPERATORS = {";", "&&", "||", "|", "&", "(", "{"}
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
MAX_DEPTH = 5
CLOSE_RE = re.compile(r"(?i)\b(close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#\d+")
QUALIFIED_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*#\d+")
SUBSTITUTION_RE = re.compile(r"\$\(|`")


def is_c_flag(tok):
    return (
        tok.startswith("-")
        and not tok.startswith("--")
        and len(tok) > 1
        and tok[1:].isalpha()
        and "c" in tok[1:]
    )


def find_flag(args, long_names, short_names):
    i, n = 0, len(args)
    while i < n:
        tok = args[i]
        for ln in long_names:
            if tok == "--" + ln:
                return args[i + 1] if i + 1 < n else None
            if tok.startswith("--" + ln + "="):
                return tok.split("=", 1)[1]
        for sn in short_names:
            if tok == "-" + sn:
                return args[i + 1] if i + 1 < n else None
        i += 1
    return None


def resolve_dir(base, target):
    # "cd" with no arg, a flag, or an unexpandable $VAR target -- leave the
    # accumulated cwd unchanged rather than guess (documented residual gap).
    if not target or target.startswith("-") or "$" in target or "`" in target:
        return base
    return target if os.path.isabs(target) else os.path.normpath(os.path.join(base, target))


def find_heredoc_ops(line):
    """Scan one line for unquoted `<<`/`<<-` heredoc operators (quote-aware,
    not a full shell parser -- see the header comment residual-gaps note).
    Returns a list of (dash, delimiter) tuples in left-to-right order.
    `<<<` here-strings (no body lines) are deliberately not returned.
    """
    ops = []
    i, n = 0, len(line)
    in_squote = in_dquote = False
    while i < n:
        c = line[i]
        if in_squote:
            # No escaping inside single quotes (POSIX) -- only a matching
            # quote character closes it.
            if c == "\x27":
                in_squote = False
            i += 1
            continue
        if in_dquote:
            if c == "\\" and i + 1 < n:
                i += 2
                continue
            if c == "\"":
                in_dquote = False
            i += 1
            continue
        if c == "\x27":
            in_squote = True
            i += 1
            continue
        if c == "\"":
            in_dquote = True
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if c == "<" and i + 1 < n and line[i + 1] == "<":
            j = i + 2
            dash = ""
            if j < n and line[j] == "-":
                dash = "-"
                j += 1
            if j < n and line[j] == "<":
                # <<< here-string -- no body lines to exclude.
                i = j + 1
                continue
            while j < n and line[j] in " \t":
                j += 1
            term = ""
            if j < n and line[j] in "\x27\"":
                q = line[j]
                j += 1
                start = j
                while j < n and line[j] != q:
                    j += 1
                term = line[start:j]
                if j < n:
                    j += 1
            else:
                start = j
                while j < n and (line[j].isalnum() or line[j] == "_"):
                    j += 1
                term = line[start:j]
            if term:
                ops.append((dash, term))
            i = j
            continue
        i += 1
    return ops


def strip_heredoc_bodies(command):
    """Drop every heredoc body (through its matching terminator line) from
    `command` BEFORE tokenization, so nothing inside a body -- a literal
    "&&", "gh pr create", etc. -- can ever be scanned. Returns None if a
    heredoc is left unterminated (fails closed; there is no way to know
    where the body actually ends).
    """
    lines = command.split("\n")
    out = []
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        out.append(line)
        for dash, term in find_heredoc_ops(line):
            i += 1
            terminated = False
            while i < n:
                body_line = lines[i]
                check = body_line.lstrip("\t") if dash else body_line
                if check == term:
                    terminated = True
                    break
                i += 1
            if not terminated:
                return None
        i += 1
    return "\n".join(out)


def evaluate(command, depth, cwd):
    """Returns (kind, args, cwd-at-the-matched-invocation).

    `gh pr create` only counts as a real invocation at a genuine
    command-start position (token 0, or right after a `;`/`&&`/`||`/`|`/`&`
    operator) -- an argument to some other command (e.g. `cat`) sits at a
    non-command-start position and is never matched. Heredoc bodies are
    excluded from the scan entirely (see strip_heredoc_bodies) BEFORE this
    position tracking runs, so text sitting inside one -- including a
    literal operator character -- can never influence it either way.
    """
    if depth > MAX_DEPTH:
        return ("unparseable", None, cwd)
    stripped = strip_heredoc_bodies(command)
    if stripped is None:
        return ("unparseable", None, cwd)
    try:
        tokens = shlex.split(stripped, posix=True)
    except ValueError:
        if "gh" in stripped and "pr" in stripped and "create" in stripped:
            return ("unparseable", None, cwd)
        return ("allow", None, cwd)
    i, n = 0, len(tokens)
    at_start = True
    while i < n:
        tok = tokens[i]
        if tok in NEW_COMMAND_OPERATORS:
            at_start = True
            i += 1
            continue
        if not at_start:
            i += 1
            continue
        if ASSIGNMENT_RE.match(tok):
            # VAR=value prefix -- still before the actual command word.
            i += 1
            continue
        base = tok.rsplit("/", 1)[-1]
        if base == "env":
            # passthrough: keep scanning for the real command word after it.
            i += 1
            continue
        if base in DIR_COMMANDS:
            cwd = resolve_dir(cwd, tokens[i + 1]) if i + 1 < n else cwd
            at_start = False
            i += 1
            continue
        if base in INTERPRETERS and i + 2 < n and is_c_flag(tokens[i + 1]):
            result, args, inner_cwd = evaluate(tokens[i + 2], depth + 1, cwd)
            if result != "allow":
                return (result, args, inner_cwd)
            i += 3
            at_start = False
            continue
        if base == "gh" and i + 2 < n and tokens[i + 1] == "pr" and tokens[i + 2] == "create":
            return ("pr-create", tokens[i + 3:], cwd)
        at_start = False
        i += 1
    return ("allow", None, cwd)


try:
    command = json.load(sys.stdin).get("tool_input", {}).get("command", "")
except Exception:
    command = ""

kind, args, invocation_cwd = evaluate(command, 0, os.getcwd())

if kind == "allow":
    print("ALLOW")
    sys.exit(0)

if kind == "unparseable":
    print("BLOCK")
    print("could not safely parse this \x27gh pr create\x27 invocation to verify a board-issue reference. Simplify it (avoid nesting inside quotes/heredocs) and retry with --body/--body-file referencing the issue.")
    sys.exit(0)

body = find_flag(args, ["body"], ["b"])
body_file = find_flag(args, ["body-file"], ["F"])

body_text = None
problem = None
if body is not None:
    body_text = body
elif body_file is not None:
    if body_file == "-":
        problem = "PR body is piped via stdin (--body-file -), which this guard cannot inspect. Pass the body via a real file (--body-file <path>) so it can reference the board issue."
    else:
        path = body_file if os.path.isabs(body_file) else os.path.join(invocation_cwd, body_file)
        try:
            with open(path) as fh:
                body_text = fh.read()
        except OSError:
            problem = "could not read the referenced --body-file \x27" + body_file + "\x27 to verify a board-issue reference. Pass a real, readable file."
else:
    problem = "gh pr create has no --body/--body-file. Pass a PR body referencing the board issue (e.g. \x27Closes #76\x27 or \x27<slug>#76\x27) -- get the number with `board.sh ensure-issue --title \"<title>\" [--for-branch <branch>]` first."

if problem is None and body_text is not None:
    if not (CLOSE_RE.search(body_text) or QUALIFIED_RE.search(body_text)):
        if SUBSTITUTION_RE.search(body_text):
            problem = "cannot verify body (command substitution) -- pass a literal --body, or a --body-file whose contents already include the reference."
        else:
            problem = "PR body does not reference a board issue (need \x27Closes #N\x27 / \x27Fixes #N\x27 or \x27<slug>#N\x27). Get the issue number first with `board.sh ensure-issue --title \"<title>\" [--for-branch <branch>]` (it reuses a linked issue or files an inbound one), then put `Closes #N` in --body."

if problem is not None:
    print("BLOCK")
    print(problem)
    sys.exit(0)

print("ALLOW")

try:
    sys.path.insert(0, HERE)
    import config as C
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or os.getcwd()
    cfg = C.load_config(root=root, warn=False)
    pattern = ((cfg or {}).get("project") or {}).get("branchPattern")
    if pattern:
        branch = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=root, capture_output=True, text=True).stdout.strip()
        regex = re.escape(pattern).replace("<id>", r"\d+").replace("<slug>", r"[A-Za-z0-9._-]+")
        if branch and not re.fullmatch(regex, branch):
            print("WARN:current branch \x27" + branch + "\x27 does not match project.branchPattern (\x27" + pattern + "\x27).")
except Exception:
    pass
' "$HERE" <<< "$(cat)")" || exit 0

FIRST_LINE="$(head -n1 <<<"$OUT")"
REST="$(tail -n +2 <<<"$OUT")"

case "$FIRST_LINE" in
    ALLOW)
        case "$REST" in
            WARN:*) echo "${REST#WARN:}" >&2 ;;
        esac
        exit 0
        ;;
    BLOCK)
        echo "BLOCKED: $REST" >&2
        exit 2
        ;;
    *)
        exit 0
        ;;
esac
