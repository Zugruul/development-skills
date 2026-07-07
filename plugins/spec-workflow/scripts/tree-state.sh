#!/usr/bin/env bash
# tree-state.sh — print a fingerprint of the working tree (HEAD + uncommitted changes).
# Shared by gate.sh (records it) and guard-board-move.sh (verifies it).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1
python3 <<'PY'
# Hash HEAD + tracked diff (via git, run in-process) plus, for every
# untracked-and-not-.gitignore'd file (git ls-files --others --exclude-standard),
# its path and content. One process handles all untracked files (no fork per
# file); paths and content come through NUL-safe so filenames with spaces/
# newlines can't desync the fingerprint, and a rename (path changes, content
# doesn't) still changes the hash.
import hashlib
import subprocess


def run(args):
    return subprocess.run(args, capture_output=True).stdout


h = hashlib.sha256()
head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True)
h.update(head.stdout if head.returncode == 0 else b"no-head")
# .claude/gate-pass is the fingerprint marker itself: it does not exist yet
# when gate.sh records a pass, but does exist on every check afterward. It is
# excluded from both the porcelain status and the untracked-file listing
# below via an explicit pathspec, independent of .gitignore (a repo that
# doesn't happen to ignore it — or where .claude/ contains another tracked
# file, so it can't collapse to a single "?? .claude/" line — must not have
# the mechanism invalidate its own recorded pass).
h.update(run(["git", "status", "--porcelain", "--", ".", ":(exclude).claude/gate-pass"]))
h.update(run(["git", "diff", "HEAD"]))

listing = run(["git", "ls-files", "-z", "--others", "--exclude-standard"])
paths = sorted(p for p in listing.split(b"\0") if p and p != b".claude/gate-pass")
for p in paths:
    h.update(b"\0PATH\0")
    h.update(p)
    h.update(b"\0CONTENT\0")
    try:
        with open(p, "rb") as f:
            h.update(f.read())
    except OSError:
        h.update(b"MISSING")

print(h.hexdigest())
PY
