#!/usr/bin/env python3
"""diff-symbols.py -- map a unified diff's hunks to their enclosing symbols.

Issue #86: a reviewer's recurring chore is "does this diff touch only
functions X and Y" -- today that's manual line-range grepping against the
diff. This script reads a unified diff (git diff output) on stdin, or runs
`git diff <range>` itself via --range A..B, and for every hunk resolves the
changed line(s) to their enclosing definition in the NEW file version:

    - python (.py): def/class via `ast`, nested as "Class.method"
    - bash (.sh/.bash): `name() {` / `function name {` (brace-matched)
    - everything else: nearest preceding markdown heading for .md files,
      "(file-level)" otherwise (module/top-level changes, or a symbol kind
      this tool doesn't parse)

A deleted file's hunks map to "(deleted)". Output is `path<TAB>symbol`
lines, deduped and sorted; --json prints the same pairs as a JSON array of
{"path": ..., "symbol": ...} objects.

In stdin mode, the NEW file content is read straight off disk (relative to
the repo root) -- this matches piping an uncommitted `git diff`. In --range
mode, content is read via `git show <B>:<path>` so it reflects the diff's
own endpoint regardless of what's checked out.
"""
import argparse
import ast
import json
import os
import re
import subprocess
import sys

HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def die(msg):
    print(f"diff-symbols: error: {msg}", file=sys.stderr)
    sys.exit(1)


def strip_prefix(path):
    if path.startswith("a/") or path.startswith("b/"):
        return path[2:]
    return path


class FileDiff:
    def __init__(self):
        self.old_path = None
        self.new_path = None
        self.deleted = False
        self.candidates = []  # new-file line numbers touched by this diff


def parse_diff(text):
    """Parse unified-diff text into a list of FileDiff. Dies with a clear
    error on structurally malformed input (hunk header that doesn't parse,
    or a hunk appearing before any file header)."""
    if not text.strip():
        return []

    lines = text.split("\n")
    n = len(lines)
    files = []
    cur = None
    saw_file_header = False
    i = 0
    while i < n:
        line = lines[i]
        if line.startswith("diff --git "):
            cur = FileDiff()
            files.append(cur)
            saw_file_header = True
            i += 1
            continue
        if line.startswith("--- "):
            path = line[4:].split("\t", 1)[0]
            if cur is None:
                cur = FileDiff()
                files.append(cur)
            if path != "/dev/null":
                cur.old_path = strip_prefix(path)
            saw_file_header = True
            i += 1
            continue
        if line.startswith("+++ "):
            path = line[4:].split("\t", 1)[0]
            if cur is None:
                die(f"malformed diff: '+++' header without a preceding file header: {line!r}")
            if path == "/dev/null":
                cur.deleted = True
            else:
                cur.new_path = strip_prefix(path)
            saw_file_header = True
            i += 1
            continue
        if line.startswith("@@"):
            m = HUNK_RE.match(line)
            if not m:
                die(f"malformed diff: unparsable hunk header: {line!r}")
            if cur is None or (cur.new_path is None and not cur.deleted):
                die(f"malformed diff: hunk header appears before any file header: {line!r}")
            newstart = int(m.group(3))
            new_line = newstart
            i += 1
            candidates = []
            while i < n:
                bl = lines[i]
                if bl.startswith("@@") or bl.startswith("diff --git ") or bl.startswith("--- ") or bl.startswith("+++ "):
                    break
                if bl.startswith("+"):
                    candidates.append(("add", new_line))
                    new_line += 1
                elif bl.startswith("-"):
                    # new_line is the position of the next SURVIVING line
                    # (a deletion never advances it) -- for a symbol match
                    # that's the line right after the deleted one, which is
                    # the wrong anchor when the deletion was the function's
                    # own trailing line. resolve_deletion() below prefers
                    # new_line-1 (the last surviving line BEFORE the
                    # deletion) and only falls back to new_line.
                    candidates.append(("del", new_line))
                elif bl.startswith(" ") or bl == "":
                    new_line += 1
                elif bl.startswith("\\"):
                    pass  # "\ No newline at end of file"
                else:
                    die(f"malformed diff: unexpected line inside hunk body: {bl!r}")
                i += 1
            if not candidates:
                candidates = [("add", max(newstart, 1))]
            cur.candidates.extend(candidates)
            continue
        i += 1

    if not saw_file_header:
        die("malformed diff: no 'diff --git'/'---'/'+++' file header found")
    return files


def find_repo_root():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except Exception:
        return os.getcwd()


def run_git_diff(range_spec, repo_root):
    a, sep, b = range_spec.partition("..")
    if not sep or not a or not b:
        die(f"malformed --range value (expected A..B): {range_spec!r}")
    try:
        out = subprocess.run(
            ["git", "diff", range_spec],
            capture_output=True, text=True, check=True, cwd=repo_root,
        )
    except subprocess.CalledProcessError as e:
        die(f"git diff {range_spec} failed: {e.stderr.strip()}")
    return out.stdout, b


_content_cache = {}


def get_content(path, ref, repo_root):
    key = (path, ref)
    if key in _content_cache:
        return _content_cache[key]
    text = None
    if ref is None:
        full = os.path.join(repo_root, path)
        try:
            with open(full, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            text = None
    else:
        out = subprocess.run(
            ["git", "show", f"{ref}:{path}"],
            capture_output=True, text=True, cwd=repo_root,
        )
        if out.returncode == 0:
            text = out.stdout
    result = (text, text.split("\n") if text is not None else None)
    _content_cache[key] = result
    return result


def resolve_python(source, line_no):
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return "(file-level)"
    best = ["(file-level)"]

    def walk(node, prefix):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                start = child.lineno
                decorators = getattr(child, "decorator_list", None)
                if decorators:
                    # ast anchors lineno at the `def`/`class` line, not the
                    # decorator(s) above it -- a decorator-argument-only
                    # edit would otherwise fall outside [start, end].
                    start = min(start, min(d.lineno for d in decorators))
                end = getattr(child, "end_lineno", start)
                if start <= line_no <= end:
                    qualname = f"{prefix}.{child.name}" if prefix else child.name
                    best[0] = qualname
                    walk(child, qualname)
                    continue
            walk(child, prefix)

    walk(tree, "")
    return best[0]


BASH_FUNC_RES = (
    re.compile(r"^\s*(?:function\s+)?([A-Za-z_]\w*)\s*\(\)\s*\{"),
    re.compile(r"^\s*function\s+([A-Za-z_]\w*)\s*\{"),
)


def bash_func_name(line):
    for rx in BASH_FUNC_RES:
        m = rx.match(line)
        if m:
            return m.group(1)
    return None


def brace_delta(line):
    """Net {/} count for one line, ignoring braces inside quotes/comments --
    a lightweight per-line quote tracker (round-1 review finding: a naive
    .count("{") - .count("}") lets an unbalanced brace INSIDE A STRING (e.g.
    a message like "opening brace: {") extend a function's perceived range
    past the next function's declaration, misattributing edits in it)."""
    delta = 0
    quote = None
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if quote:
            if c == "\\" and i + 1 < n:
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            continue
        if c == "#":
            break
        if c == "{":
            delta += 1
        elif c == "}":
            delta -= 1
        i += 1
    return delta


def resolve_bash(lines, line_no):
    funcs = []
    n = len(lines)
    i = 0
    while i < n:
        name = bash_func_name(lines[i])
        if name:
            start = i + 1  # 1-indexed
            depth = brace_delta(lines[i])
            j = i + 1
            while j < n and depth > 0:
                depth += brace_delta(lines[j])
                j += 1
            end = j if depth <= 0 else n
            funcs.append((start, end, name))
            i = end
            continue
        i += 1

    best = "(file-level)"
    best_size = None
    for start, end, name in funcs:
        if start <= line_no <= end:
            size = end - start
            if best_size is None or size < best_size:
                best = name
                best_size = size
    return best


HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")


def resolve_markdown(lines, line_no):
    idx = min(line_no, len(lines)) - 1
    while idx >= 0:
        m = HEADING_RE.match(lines[idx])
        if m:
            return m.group(2).strip()
        idx -= 1
    return "(file-level)"


def resolve_symbol(path, line_no, content):
    text, lines = content
    if text is None:
        return "(file-level)"
    ext = os.path.splitext(path)[1]
    if ext == ".py":
        return resolve_python(text, line_no)
    if ext in (".sh", ".bash"):
        return resolve_bash(lines, line_no)
    if ext in (".md", ".markdown"):
        return resolve_markdown(lines, line_no)
    return "(file-level)"


def resolve_candidate(path, kind, line_no, content):
    if kind == "del" and line_no > 1:
        # A deletion doesn't exist in the new file -- new_line is the next
        # SURVIVING line, which is the wrong anchor when the deleted content
        # was a function's own trailing line (that next line is often
        # module-scope). Prefer the last surviving line BEFORE the deletion;
        # only fall back to the "after" line if that resolves to nothing.
        before = resolve_symbol(path, line_no - 1, content)
        if before != "(file-level)":
            return before
    return resolve_symbol(path, line_no, content)


def main():
    parser = argparse.ArgumentParser(description="Map diff hunks to their enclosing symbols.")
    parser.add_argument("--range", metavar="A..B", help="run `git diff A..B` instead of reading stdin")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of tab-separated lines")
    args = parser.parse_args()

    repo_root = find_repo_root()

    if args.range:
        text, ref = run_git_diff(args.range, repo_root)
    else:
        ref = None
        text = sys.stdin.read()

    files = parse_diff(text)

    results = set()
    for f in files:
        if f.deleted:
            path = f.old_path or f.new_path
            if path:
                results.add((path, "(deleted)"))
            continue
        if not f.new_path:
            continue
        content = get_content(f.new_path, ref, repo_root)
        for kind, line_no in f.candidates:
            sym = resolve_candidate(f.new_path, kind, line_no, content)
            results.add((f.new_path, sym))

    ordered = sorted(results)
    if args.json:
        print(json.dumps([{"path": p, "symbol": s} for p, s in ordered], indent=2))
    else:
        for p, s in ordered:
            print(f"{p}\t{s}")


if __name__ == "__main__":
    main()
