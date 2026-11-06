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
# (`git diff-tree -r --root --cc --name-only`: merge commits stay visible, and a
# rename is a delete plus an add, so BOTH paths are classified) classify the
# commit as:
#   test-only    every changed path is under a test/, tests/, Tests/ or __tests__/
#                directory, or is a *.test.* / *.spec.* file, or follows the
#                pytest/Go/Ruby suffix convention (*_test.py|go|rb, test_*.py),
#                or is a Rust test by name (*_tests.rs, *_test.rs, *_bench.rs,
#                anything under benches/; the underscore is the name boundary,
#                so attest.rs, benches.rs, testbench.rs stay implementation)
#                (test files colocated beside sources are standard in JS/TS
#                repos), or -- when the name rules leave only .rs files (#552)
#                -- every change in those Rust files sits inside `#[cfg(test)]`
#                items, decided by scripts/rust_inline_tests.py by comparing
#                each file before and after: code outside the items must be
#                identical and the items must change. An item is a `mod`,
#                `fn`, `impl`, `use` or `const` with a well-formed
#                shape, at the start of an item in the file or in a `mod`/`impl`
#                body whose every enclosing bracket is also such a body (never
#                in a fn body, parentheses, angle brackets, a struct, enum or
#                trait body, a const block or a macro, however deeply a `mod`
#                is nested in one; the mod/impl may carry only inert attributes:
#                allow, warn, deny, forbid, expect, cfg, doc, inline, must_use,
#                since an attribute macro or cfg_attr sees the whole body); `cfg(test)` and
#                `cfg(all(.., test, ..))` only. It fails closed, so these stay
#                impl: `not`/`any`/`cfg_attr`, a deleted or moved attribute,
#                an edit beside the block, an attribute in a comment or string,
#                unmatched braces or any unreadable text, operators respaced
#                (`&&` to `& &`), a non-attribute `#!` first line, non-ASCII outside
#                strings and comments, `cr` raw strings, literal suffixes (`""r`), `mod x;` in an item,
#                binary, symlink, submodule or oversize (512 KiB) files,
#                renames or copies, merge commits, and any analysis error. A
#                classifier that crashes or prints nothing also reads as impl.
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
    echo "BLOCKED: red-first preflight could not resolve project.mainBranch from config -- check .neural-network/project.yaml (or project.json)." >&2
    exit 2
fi

COMMITS="$(cd "$ROOT" && git log --reverse "$MAIN..$BRANCH" --format=%H 2>/dev/null)"
[[ -z "$COMMITS" ]] && exit 0

FIRST_IMPL=""
FOUND_TEST_ONLY_BEFORE=0

while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    # diff-tree never detects renames on its own, so a rename is a delete plus
    # an add and BOTH paths are classified (a moved source file cannot hide its
    # deleted half). --cc keeps merge commits visible: git show listed them too.
    files="$(cd "$ROOT" && git diff-tree -r --root --no-commit-id --cc --name-only "$sha" 2>/dev/null)"
    kind="$(python3 -I - "$files" "$HERE" "$ROOT" "$sha" <<'PY'
import re, sys
files = [f for f in sys.argv[1].splitlines() if f.strip()]
def is_test(p): return (re.search(r'(^|/)(test|tests|Tests|__tests__)/', p) is not None
                        or re.search(r'\.(test|spec)\.[A-Za-z]+$', p) is not None
                        or re.search(r'_test\.(py|go|rb)$', p) is not None
                        or re.search(r'(^|/)test_[^/]+\.py$', p) is not None
                        or re.search(r'_(tests?|bench)\.rs$', p) is not None
                        or re.search(r'(^|/)benches/', p) is not None)
def is_doc(p): return p.lower().endswith('.md') or p.startswith('docs/') or '/docs/' in p
rest = [f for f in files if not (is_test(f) or is_doc(f))]
inline = False
if rest and all(f.endswith('.rs') for f in rest):
    # name rules did not decide; only now read the Rust files (#552): a commit
    # whose every change sits inside `#[cfg(test)]` items counts as test code.
    # A missing or broken module raises here, prints nothing, and the shell
    # below reads that as implementation.
    sys.path.insert(0, sys.argv[2])
    import rust_inline_tests
    inline = rust_inline_tests.commit_is_test_only(sys.argv[3], sys.argv[4], rest)
if not files:
    print("doc")
elif inline or (all(is_test(f) or is_doc(f) for f in files) and any(is_test(f) for f in files)):
    # tests, optionally alongside docs: still a RED commit. Docs are not
    # implementation (a docs-only commit is already accepted on its own), so a
    # red suite committed together with its design doc must not be misread as
    # implementation and fail a branch that did follow red-first.
    print("test")
elif all(is_doc(f) for f in files):
    print("doc")
else:
    print("impl")
PY
)"
    # Fail closed: anything but a clean "test" or "doc" answer (empty output
    # from a crashed or unlaunchable classifier, say) counts as implementation.
    if [[ "$kind" != "test" && "$kind" != "doc" ]]; then
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
