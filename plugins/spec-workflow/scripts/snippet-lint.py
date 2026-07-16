#!/usr/bin/env python3
"""snippet-lint.py — version-floor lint for inline interpreter snippets.

Generalizes the old section-syntax.sh check (one f-string regex) into two
gate-wide floors, over every `scripts/*.sh` and `tests/*.sh` file:

  1. PYTHON FLOOR (3.9) — every inline python3 snippet is parsed with
     `ast.parse(src, feature_version=(3, 9))`. py_compile (see
     section-syntax.sh) only ever sees standalone .py files; it never looks
     inside a shell script's inline snippets, so this is the only static
     check that can see this class of bug before it hits an old interpreter.
     Covers:
       - `python3 -c '...'`  (bash single-quoted -- no interpolation possible)
       - `python3 -c "..."`  (bash double-quoted -- CAN interpolate $vars)
       - `python3 [-m MOD] [-] <<[-]DELIM ... DELIM`     (unquoted heredoc --
         CAN interpolate)
       - `python3 [-m MOD] [-] <<[-]'DELIM'/"DELIM" ... DELIM` (quoted
         heredoc, either quote char -- literal, no interpolation; `<<-`
         additionally strips each line's leading tabs, per POSIX)

     `-m MOD` CAVEAT (a real, reproduced false-positive risk, not just a
     theoretical one -- deliberately accepted, not silently narrowed away):
     `python3 -m MODULE <<...` hands the heredoc to MODULE's own stdin,
     which is not always python source at all -- e.g. `python3 -m json.tool
     <<EOF` feeds JSON to the tool, never executes it as python. This script
     still treats every `-m MOD` heredoc as a python-source candidate for
     lint coverage (there are zero such heredocs in this repo today, and a
     real one that DOES read source from stdin, e.g. a profiler/debugger
     invoked with an explicit `-` script argument, needs the same floor
     check as any other snippet). A future `-m MOD` heredoc whose module
     consumes genuinely non-python stdin data (unlike JSON, whose literal
     grammar happens to be a syntactic subset of Python's -- even bare
     `true`/`null` parse as valid, if meaningless, python identifiers) WILL
     produce a spurious floor finding here. That's an accepted, LOUD
     false-positive (never silent): fix it by exempting that one heredoc
     explicitly when it happens, not by narrowing this regex pre-emptively.
     There is deliberately no `bash4-ok`-style marker for this path -- it's
     a python-floor finding, not a bash-floor one, and the fix is to
     exclude the specific call, not to suppress the message.

     A double-quoted `-c` argument or an unquoted heredoc can embed real bash
     interpolation ($var, ${var}, $(...), `...`) that this script can't
     evaluate without a live shell. Best-effort: each interpolation site is
     replaced with a syntactically-neutral placeholder token before parsing
     (see NEUTRALIZE_PLACEHOLDER below) -- this is sound for the common case
     (interpolation sits inside an already-valid python string/expression)
     but is NOT a real bash parser, so a construct it can't safely bound
     (unterminated string/heredoc, unbalanced $(...)/${...}) is reported as
     an explicit UNSCANNED finding rather than silently skipped or fed
     to ast.parse as probably-garbled text.

     EMPIRICAL CAVEAT (verified on CPython 3.13, not assumed): feature_version
     rejects GRAMMAR additions -- match statements (<3.10), except* (<3.11),
     PEP 695 type-parameter syntax and the `type` statement (<3.12) -- but it
     does NOT reject the PEP 701 tokenizer relaxation that lets an f-string
     nest its own quote char in a `{}` expression, e.g. f"{d["id"]}"
     (3.12+-only; SyntaxError on the stock python3 shipped with macOS <= 14,
     Ubuntu <= 22.04, Debian 11/12, RHEL 8/9). Confirmed directly:
     `ast.parse('x = f"{d["id"]}"\\n', feature_version=(3, 9))` parses
     without error -- that's a lexer change feature_version's compatibility
     shim doesn't model, not a grammar production it can flag. So the regex
     this script inherits from the old check (NESTED_QUOTE_FSTRING_RE below)
     remains the ONLY layer that catches that one pattern; feature_version
     covers every other version-gated construct. Never requires an old
     interpreter to be installed -- both layers are static.

  2. BASH FLOOR (3.2) — every .sh file itself is scanned for bash-4+
     constructs: mapfile/readarray, `declare -A`, `${var,,}`/`${var^^}` case
     conversion, `${var:off:-len}` negative-length substrings, and `&>>`.
     A same-line `# bash4-ok: <reason>` marker comment suppresses one finding
     when the construct is unavoidable (grep -n 'bash4-ok:' to audit them) --
     the reason after the colon must be non-empty (non-whitespace) text, or
     the marker is not honored: a bare `# bash4-ok:` with nothing after it
     documents nothing and is treated as absent.

Scope: markdown-embedded snippets in skills/ were surveyed (SW-045) and found
to only ever invoke standalone .py scripts (e.g. `python3
"../../scripts/foo.py"`, a path relative to the skill's own root per
SPEC-CODEX-COMPAT §6.7), never inline bodies -- py_compile already covers
those files, so markdown extraction is not implemented (no inline snippet
exists there to miss).

Usage: snippet-lint.py <plugin-dir>
Exit 0, no output, when clean. Otherwise one `path:line: message` finding per
line on stdout, and exit 1.
"""
import ast
import glob
import os
import re
import sys

# shellcheck-visible in spirit only (this is python): kept verbatim from the
# check this script folds in (section-syntax.sh), including its comment --
# see the module docstring's EMPIRICAL CAVEAT for why this regex layer stays.
NESTED_QUOTE_FSTRING_RE = re.compile(r'f"[^"{}]*\{[^{}]*"[^{}]*\}')

C_SNIPPET_RE = re.compile(r"python3\s+-c\s+(['\"])")
HEREDOC_START_RE = re.compile(
    r"python3(?:\s+-m\s+\S+)?\s*(?:-\s*)?<<(-?)[ \t]*(?:(['\"])([A-Za-z_]\w*)\2|([A-Za-z_]\w*))"
)

BASH4_CHECKS = [
    (re.compile(r"\bmapfile\b"), "mapfile (bash 4+)"),
    (re.compile(r"\breadarray\b"), "readarray (bash 4+)"),
    (re.compile(r"\bdeclare\s+-A\b"), "declare -A associative array (bash 4+)"),
    (re.compile(r"\$\{\w+([,^])\1?[^}]*\}"), "${var,,}/${var^^} case conversion (bash 4+)"),
    (re.compile(r"\$\{\w+:[^:{}]*:-"), "${var:offset:-length} negative-length substring (bash 4.2+)"),
    (re.compile(r"&>>"), "&>> combined stdout+stderr append (bash 4+)"),
]

MARKER = "bash4-ok:"

# Placeholder substituted for one bash interpolation site ($var, ${var},
# $(...), `...`) when neutralizing a double-quoted -c argument or an
# unquoted heredoc body before ast.parse. A bare digit is syntactically
# valid virtually anywhere a bash interpolation site can legally appear in
# an already-valid shell string (inside a quoted python string literal, as
# a standalone argument, as part of an f-string/format expression) without
# accidentally closing or reopening any python quoting of its own.
NEUTRALIZE_PLACEHOLDER = "0"

_IDENT_RE = re.compile(r"[A-Za-z_]\w*")


def _skip_balanced(text, i, open_ch, close_ch):
    """`i` points at `open_ch`. Returns index just past the matching
    `close_ch` (naive depth counting -- no quote-awareness inside), or -1 if
    the text ends before the nesting closes."""
    depth = 0
    n = len(text)
    while i < n:
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def _consume_dollar(text, i):
    """`i` points just past an unescaped `$`. Returns the index just past the
    whole interpolation construct ($var / ${...} / $(...)), or `i` itself if
    nothing recognizable follows (a literal `$`), or -1 if a `${`/`$(` never
    finds its matching close (malformed -- caller must treat as unscannable)."""
    n = len(text)
    if i < n and text[i] == "(":
        return _skip_balanced(text, i, "(", ")")
    if i < n and text[i] == "{":
        return _skip_balanced(text, i, "{", "}")
    m = _IDENT_RE.match(text, i)
    if m:
        return m.end()
    return i


def _neutralize_interpolation(text, i, out):
    """Handles one `$...`/`` `...` `` construct starting at `text[i]` (which
    must be '$' or '`'), appending either the placeholder or the literal
    char to `out`. Returns the index to resume scanning from, or -1 if the
    construct is malformed (unterminated)."""
    ch = text[i]
    if ch == "$":
        j = _consume_dollar(text, i + 1)
        if j == -1:
            return -1
        if j > i + 1:
            out.append(NEUTRALIZE_PLACEHOLDER)
        else:
            out.append(ch)
        return j
    # backtick command substitution
    j = text.find("`", i + 1)
    if j == -1:
        return -1
    out.append(NEUTRALIZE_PLACEHOLDER)
    return j + 1


def _read_bash_single_quoted(text, start):
    """`start` is just past the opening bash `'`. Bash single-quoted strings
    cannot contain a literal `'` at all -- the standard idiom for embedding
    one mid-string is to close, emit a double-quoted `'`, and reopen:
    `'"'"'`. That idiom must be collapsed to a literal `'` in the returned
    body (else a snippet using it, e.g. an f-string with an inner quote,
    falsely looks truncated); a bare `'` with no idiom match is the real
    terminator. Returns (body, index-just-past-closing-quote), or
    (body, -1) if never terminated. No interpolation is possible inside a
    single-quoted bash string, so nothing is neutralized here.
    """
    out = []
    i, n = start, len(text)
    while i < n:
        ch = text[i]
        if ch == "'":
            if text[i:i + 5] == "'\"'\"'":
                out.append("'")
                i += 5
                continue
            return "".join(out), i + 1
        out.append(ch)
        i += 1
    return "".join(out), -1


def _read_bash_double_quoted(text, start):
    """`start` is just past the opening bash `"`. Handles backslash escapes
    (`\\"`, `\\\\`, `\\$`, `` \\` `` unescape to the literal char; any other
    backslash is literal) and neutralizes unescaped `$`/`` ` `` interpolation
    sites. Returns (neutralized_body, index-past-closing-quote), or
    (partial_body, -1) if the string or an interpolation construct inside it
    is never terminated.
    """
    out = []
    i, n = start, len(text)
    while i < n:
        ch = text[i]
        if ch == "\\" and i + 1 < n and text[i + 1] in ('"', "\\", "$", "`"):
            out.append(text[i + 1])
            i += 2
            continue
        if ch == '"':
            return "".join(out), i + 1
        if ch in ("$", "`"):
            j = _neutralize_interpolation(text, i, out)
            if j == -1:
                return "".join(out), -1
            i = j
            continue
        out.append(ch)
        i += 1
    return "".join(out), -1


def _neutralize_unquoted_heredoc_body(body):
    """A heredoc with an UNQUOTED delimiter undergoes the same parameter/
    command-substitution + backslash processing as a double-quoted string,
    except `\\"` is not special (no enclosing quote to escape) and a
    trailing backslash-newline is a line continuation (removed, matching
    bash's own heredoc behavior). Returns (neutralized_body, ok) -- ok is
    False if an interpolation construct never closes (malformed input;
    caller reports UNSCANNED rather than trusting the partial result).
    """
    out = []
    i, n = 0, len(body)
    while i < n:
        ch = body[i]
        if ch == "\\" and i + 1 < n and body[i + 1] == "\n":
            i += 2
            continue
        if ch == "\\" and i + 1 < n and body[i + 1] in ("\\", "$", "`"):
            out.append(body[i + 1])
            i += 2
            continue
        if ch in ("$", "`"):
            j = _neutralize_interpolation(body, i, out)
            if j == -1:
                return "".join(out), False
            i = j
            continue
        out.append(ch)
        i += 1
    return "".join(out), True


def extract_c_snippets(text):
    """Yield (start_line, body_or_None, unscanned_reason_or_None) for every
    `python3 -c '...'` / `python3 -c "..."` argument."""
    for m in C_SNIPPET_RE.finditer(text):
        quote = m.group(1)
        line_no = text.count("\n", 0, m.start()) + 1
        if quote == "'":
            body, end = _read_bash_single_quoted(text, m.end())
        else:
            body, end = _read_bash_double_quoted(text, m.end())
        if end == -1:
            yield (line_no, None, "python3 -c argument never terminates (unbalanced quote/interpolation)")
            continue
        yield (line_no, body, None)


def extract_heredoc_snippets(text):
    """Yield (start_line, body_or_None, unscanned_reason_or_None) for every
    python heredoc -- quoted delimiter (either ' or ", literal body, `<<-`
    strips each line's leading tabs) or unquoted delimiter (body undergoes
    bash interpolation, neutralized before parsing)."""
    for m in HEREDOC_START_RE.finditer(text):
        dash, quote, delim_q, delim_u = m.groups()
        delim = delim_q or delim_u
        quoted = quote is not None
        start_line = text.count("\n", 0, m.start()) + 1
        body_start = text.find("\n", m.end())
        if body_start == -1:
            yield (start_line, None, "python3 heredoc opener has no body (no closing newline)")
            continue
        body_start += 1
        end_pattern = r"^[\t]*" + re.escape(delim) + r"[ \t]*$" if dash else r"^" + re.escape(delim) + r"[ \t]*$"
        end_m = re.compile(end_pattern, re.MULTILINE).search(text, body_start)
        if not end_m:
            yield (start_line, None, "python3 heredoc <<{}{!r} is never closed".format(dash, delim))
            continue
        body = text[body_start:end_m.start()]
        if dash:
            body = "\n".join(line.lstrip("\t") for line in body.split("\n"))
        if quoted:
            yield (start_line, body, None)
            continue
        neutralized, ok = _neutralize_unquoted_heredoc_body(body)
        if not ok:
            yield (start_line, None, "python3 heredoc <<{}{} has an unterminated interpolation construct".format(dash, delim))
            continue
        yield (start_line, neutralized, None)


def check_python_snippet(body):
    """Return a list of finding strings (no line prefix) for one snippet body."""
    findings = []
    try:
        ast.parse(body, feature_version=(3, 9))
    except SyntaxError as e:
        findings.append(
            "python floor (3.9): {} (snippet line {})".format(e.msg, e.lineno or 1)
        )
    if NESTED_QUOTE_FSTRING_RE.search(body):
        findings.append(
            "f-string nests its own quote char in a {} expression -- 3.12+-only "
            "(PEP 701), not caught by feature_version"
        )
    return findings


def _has_valid_marker(line):
    idx = line.find(MARKER)
    if idx == -1:
        return False
    return bool(line[idx + len(MARKER):].strip())


def check_bash_floor(path, text):
    findings = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if _has_valid_marker(line):
            continue
        for pattern, label in BASH4_CHECKS:
            if pattern.search(line):
                findings.append("{}:{}: bash floor (3.2): {}".format(path, lineno, label))
    return findings


def lint_file(path):
    findings = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()

    for start_line, body, reason in extract_c_snippets(text):
        if reason is not None:
            findings.append("{}:{}: UNSCANNED: {}".format(path, start_line, reason))
            continue
        for msg in check_python_snippet(body):
            findings.append("{}:{}: {}".format(path, start_line, msg))
    for start_line, body, reason in extract_heredoc_snippets(text):
        if reason is not None:
            findings.append("{}:{}: UNSCANNED: {}".format(path, start_line, reason))
            continue
        for msg in check_python_snippet(body):
            findings.append("{}:{}: {}".format(path, start_line, msg))

    findings.extend(check_bash_floor(path, text))
    return findings


def main(argv):
    if len(argv) != 2:
        print("usage: snippet-lint.py <plugin-dir>", file=sys.stderr)
        return 2
    plugin_dir = argv[1]
    paths = sorted(
        glob.glob(os.path.join(plugin_dir, "scripts", "*.sh"))
        + glob.glob(os.path.join(plugin_dir, "tests", "*.sh"))
    )
    findings = []
    for path in paths:
        findings.extend(lint_file(path))
    for f in findings:
        print(f)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
