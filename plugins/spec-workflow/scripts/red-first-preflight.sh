#!/usr/bin/env bash
# red-first-preflight.sh -- hook-independent check: "does this branch follow
# the red-first TDD commit-ordering convention (a test-only commit somewhere
# before the first commit that touches implementation files)?" (#235,
# CDX-031 gap #3, SPEC-CODEX-COMPAT.md §9.2 invariant 3).
#
# STRUCTURAL HEURISTIC, NOT A BEHAVIORAL PROOF: this script inspects commit
# ORDERING only -- it does NOT check out any historical commit and run its
# tests, so it cannot prove the test-only commit's tests actually FAILED at
# that point in history. It catches the common failure mode (skipping the
# red step entirely, or committing tests and implementation together in one
# commit) -- not an adversarial one (a test-only commit whose tests already
# trivially pass would satisfy this heuristic while violating the spirit of
# "red-first"). Full historical test execution was explicitly ruled out as
# disproportionate -- see docs/design/cdx-E3.md, "Follow-up: #235".
#
# Usage: red-first-preflight.sh [--root <path>] [--branch <name>]
#   --root   default: git toplevel (or cwd if not in a git repo) -- exists
#            for tests that want to check a fixture repo without cd'ing in.
#   --branch default: current branch (git rev-parse --abbrev-ref HEAD)
#
# Algorithm: `git log --reverse <mainBranch>..<branch>` gives the branch's
# commits unique to it, oldest-to-newest. Each commit's changed files
# (`git show --name-only --format=`) classify the commit as:
#   test-only    every changed path is under a tests/ directory
#   doc-only     every changed path is *.md or under docs/
#   impl-touching  anything else (at least one changed file is neither)
# Find the first impl-touching commit. If none exists, PASS trivially (a
# docs-only or test-only-addition branch has no red-then-green behavior
# change to sequence). Otherwise PASS only if some EARLIER commit is
# test-only; FAIL otherwise, naming the offending commit.
#
# Exit 0, silent stdout: check passes.
# Exit 2, actionable message on stderr: check fails.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=""
BRANCH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "usage: red-first-preflight.sh [--root <path>] [--branch <name>]" >&2; exit 2; }
            ROOT="$2"; shift 2 ;;
        --branch)
            [[ $# -ge 2 ]] || { echo "usage: red-first-preflight.sh [--root <path>] [--branch <name>]" >&2; exit 2; }
            BRANCH="$2"; shift 2 ;;
        *) echo "usage: red-first-preflight.sh [--root <path>] [--branch <name>]" >&2; exit 2 ;;
    esac
done
[[ -n "$ROOT" ]] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[[ -n "$BRANCH" ]] || BRANCH="$(cd "$ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null)"

MAIN="$(python3 "$HERE/config.py" "$ROOT" get project.mainBranch 2>/dev/null)"
if [[ -z "$MAIN" ]]; then
    echo "BLOCKED: red-first preflight could not resolve project.mainBranch from config -- check .claude/project.yaml (or project.json)." >&2
    exit 2
fi

COMMITS="$(cd "$ROOT" && git log --reverse "$MAIN..$BRANCH" --format=%H 2>/dev/null)"
[[ -z "$COMMITS" ]] && exit 0

FIRST_IMPL=""
FOUND_TEST_ONLY_BEFORE=0

while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    files="$(cd "$ROOT" && git show --name-only --format= "$sha" 2>/dev/null)"
    kind="$(python3 - "$files" <<'PY'
import re, sys
files = [f for f in sys.argv[1].splitlines() if f.strip()]
def is_test(p): return re.search(r'(^|/)tests/', p) is not None
def is_doc(p): return p.lower().endswith('.md') or p.startswith('docs/') or '/docs/' in p
if not files:
    print("doc")
elif all(is_test(f) for f in files):
    print("test")
elif all(is_doc(f) for f in files):
    print("doc")
else:
    print("impl")
PY
)"
    if [[ "$kind" == "impl" ]]; then
        FIRST_IMPL="$sha"
        break
    elif [[ "$kind" == "test" ]]; then
        FOUND_TEST_ONLY_BEFORE=1
    fi
done <<< "$COMMITS"

[[ -z "$FIRST_IMPL" ]] && exit 0
[[ "$FOUND_TEST_ONLY_BEFORE" -eq 1 ]] && exit 0

echo "BLOCKED: red-first TDD not followed -- commit $FIRST_IMPL touches implementation files with no earlier test-only commit on this branch. Expected pattern: a commit touching ONLY test files (a red commit) before any commit that touches implementation files. This checks commit ORDERING only, not that the tests actually failed when run." >&2
exit 2
