#!/usr/bin/env python3
"""repo_root.py — shared PRIMARY repo-root resolver for the spec-workflow
plugin's stdlib-Python scripts. Python stdlib only.

Mirrors repo-root.sh (see that file for the full problem statement / #463):
`git rev-parse --show-toplevel` returns the CURRENT tree's root, which for a
linked worktree is the worktree's own path, not the main checkout where the
build loop's gitignored `.claude/` local state actually lives.

Precedence:
    1. $SPEC_WORKFLOW_REPO_ROOT, if set — trusted as a path.
    2. `git rev-parse --path-format=absolute --git-common-dir` — the parent
       of that path is the PRIMARY (main-checkout) root, from the main
       checkout or any linked worktree.
    3. `git rev-parse --show-toplevel` — older git, or a layout where
       --git-common-dir fails.
    4. `os.getcwd()` — not a git repo at all.

CANONICALIZATION (macOS pitfall, found live by the ui-hub/design-registry
lane): `--path-format=absolute --git-common-dir` returns the RESOLVED form
(e.g. /private/tmp/... on macOS, where /tmp is itself a symlink), while
`--show-toplevel` and a raw env-var override return the UNRESOLVED form
(/tmp/...). Mixing roots from different code paths breaks relpath/
startswith path math. Every branch below is passed through
os.path.realpath() (safe on a nonexistent path -- it does not raise), so the
result is always in the same physical form regardless of which branch
produced it.

NOT for code that inspects/tests the CURRENT tree (a fingerprint of the
working tree, the actual code under test) — that must keep resolving via
--show-toplevel / cwd-relative git so it describes the tree actually being
worked on, not wherever its local state happens to live.

Library:
    resolve_repo_root() -> str
"""
import os
import subprocess


def _git(args):
    try:
        out = subprocess.run(
            ["git"] + args, capture_output=True, text=True, check=False
        )
    except OSError:
        return ""
    if out.returncode != 0:
        return ""
    return out.stdout.strip()


def resolve_repo_root():
    override = os.environ.get("SPEC_WORKFLOW_REPO_ROOT")
    if override:
        return os.path.realpath(override)

    common_dir = _git(["rev-parse", "--path-format=absolute", "--git-common-dir"])
    if common_dir:
        return os.path.realpath(os.path.dirname(common_dir))

    toplevel = _git(["rev-parse", "--show-toplevel"])
    if toplevel:
        return os.path.realpath(toplevel)

    return os.path.realpath(os.getcwd())


if __name__ == "__main__":
    print(resolve_repo_root())
