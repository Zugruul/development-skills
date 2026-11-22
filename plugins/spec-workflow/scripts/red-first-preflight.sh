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
# Usage: red-first-preflight.sh [--root <path>] [--branch <name>] [--issue <N>]
#   --issue  the task id an override record is filed under (board.sh passes it; else the branch)
#   --root   default: git toplevel (or cwd if not in a git repo) -- exists
#            for tests that want to check a fixture repo without cd'ing in.
#   --branch default: current branch (git rev-parse --abbrev-ref HEAD)
#
# Algorithm: `git log --topo-order --reverse <branch> --not origin/<mainBranch> <mainBranch>`
# (origin fetched first, #581) gives the branch's commits unique to it, parents before
# children (--topo-order: without it git orders by commit date, and a later-dated merge side
# can list a commit ahead of its own parent, so a test commit hid the impl it sits on). Each commit's changed files
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
ISSUE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "usage: red-first-preflight.sh [--root <path>] [--branch <name>]" >&2; exit 2; }
            ROOT="$2"; shift 2 ;;
        --branch)
            [[ $# -ge 2 ]] || { echo "usage: red-first-preflight.sh [--root <path>] [--branch <name>]" >&2; exit 2; }
            BRANCH="$2"; shift 2 ;;
        --issue)  # #581: the task id an override record is filed under (else the branch)
            [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "usage: red-first-preflight.sh [--root <path>] [--branch <name>] [--issue <N>]" >&2; exit 2; }
            ISSUE="$2"; shift 2 ;;
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

# #581: measure the branch from main AS IT IS UPSTREAM, not from a possibly stale local
# branch. A local main behind origin/main put main's own commits in `<main>..HEAD` and
# blamed one of them. So: fetch origin/<main> first (best effort, bounded; RED_FIRST_NO_FETCH=1
# skips it), then take the commits reachable from the branch but from NEITHER the local main
# NOR origin/main. With no origin remote, or a failed fetch, the refs that exist are used.
BASES=()
if (cd "$ROOT" && git remote get-url origin >/dev/null 2>&1); then
    if [[ "${RED_FIRST_NO_FETCH:-}" != "1" ]]; then
        # Never prompt, never hang: no terminal/ssh/credential-manager prompts, a 10 s ssh
        # connect limit, an http stall limit, and a 30 s overall bound where `timeout` exists.
        # A fetch in the last 120 s is reused (flush replay runs this per queued entry).
        _gitdir="$(cd "$ROOT" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
        _fresh=0
        if [[ -n "$_gitdir" && -f "$_gitdir/FETCH_HEAD" ]]; then
            _age=$(( $(date +%s) - $(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$_gitdir/FETCH_HEAD" 2>/dev/null || echo 0) ))
            [[ $_age -ge 0 && $_age -lt 120 ]] && _fresh=1
        fi
        if [[ $_fresh -eq 0 ]]; then
            _fetch=(git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 fetch -q --no-tags origin "+refs/heads/$MAIN:refs/remotes/origin/$MAIN")
            command -v timeout >/dev/null 2>&1 && _fetch=(timeout 30 "${_fetch[@]}")
            (cd "$ROOT" && GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_ASKPASS=true SSH_ASKPASS=true \
                GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=10" \
                "${_fetch[@]}" </dev/null >/dev/null 2>&1) \
                || echo "NOTE: red-first preflight could not fetch origin/$MAIN; measuring from the refs on hand" >&2
        fi
    fi
    (cd "$ROOT" && git rev-parse -q --verify "refs/remotes/origin/$MAIN^{commit}" >/dev/null 2>&1) \
        && BASES+=("refs/remotes/origin/$MAIN")
fi
(cd "$ROOT" && git rev-parse -q --verify "refs/heads/$MAIN^{commit}" >/dev/null 2>&1) && BASES+=("refs/heads/$MAIN")
[[ ${#BASES[@]} -eq 0 ]] && exit 0  # no main to measure from (as before: nothing to sequence)

COMMITS="$(cd "$ROOT" && git log --topo-order --reverse --format=%H "$BRANCH" --not "${BASES[@]}" 2>/dev/null)"
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

# #581: red can be proved without a separate commit (the test was run against the code with
# the fix reverted, then test and fix were committed together). That is an accepted
# OVERRIDE, never silent: RED_FIRST_OVERRIDE="<how red was proved>" (20+ characters) passes
# only once the reason is recorded in telemetry (kind red-first-override).
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"
_state="$(cd "$ROOT" && spec_workflow_repo_root)"
# An override already recorded for THIS commit is honoured without the env var, so a move
# queued while rate-limited and replayed later by flush is not refused again.
_prior="$(python3 -c 'import json,sys
for line in open(sys.argv[1]):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if r.get("kind") == "red-first-override" and r.get("commit") == sys.argv[2] and str(r.get("reason", "")).strip():
        print(r["reason"]); break' "$_state/.claude/telemetry.jsonl" "$FIRST_IMPL" 2>/dev/null)"
if [[ -z "${RED_FIRST_OVERRIDE:-}" && -n "$_prior" ]]; then
    echo "WARNING: red-first overridden for $BRANCH (commit $FIRST_IMPL) by the recorded override: $_prior" >&2
    exit 0
fi
if [[ -n "${RED_FIRST_OVERRIDE:-}" ]]; then
    if [[ ${#RED_FIRST_OVERRIDE} -lt 20 ]]; then
        echo "BLOCKED: RED_FIRST_OVERRIDE needs a real reason (at least 20 characters) saying how red was proved, e.g. RED_FIRST_OVERRIDE=\"ran tests/x.sh with the fix reverted: 3 failures\"." >&2
        exit 2
    fi
    _rec="$(python3 -c 'import json,sys,datetime
task = int(sys.argv[4]) if sys.argv[4] else sys.argv[1]
print(json.dumps({"kind": "red-first-override", "task": task, "branch": sys.argv[1], "commit": sys.argv[2],
                  "reason": sys.argv[3],
                  "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}))' \
        "$BRANCH" "$FIRST_IMPL" "$RED_FIRST_OVERRIDE" "$ISSUE")"
    if ! PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" python3 "$HERE/telemetry.py" "$_state" record "$_rec" >/dev/null 2>&1; then
        echo "BLOCKED: RED_FIRST_OVERRIDE given but the reason could not be recorded in $_state/.claude/telemetry.jsonl; an override is accepted only once recorded." >&2
        exit 2
    fi
    echo "WARNING: red-first overridden for $BRANCH (commit $FIRST_IMPL): $RED_FIRST_OVERRIDE -- recorded in telemetry." >&2
    exit 0
fi

echo "BLOCKED: red-first TDD not followed -- commit $FIRST_IMPL touches implementation files with no earlier test-only commit on this branch. Expected pattern: a commit touching ONLY test files (a red commit) before any commit that touches implementation files. This checks commit ORDERING only, not that the tests actually failed when run. If you proved red another way (ran the test with the fix reverted, then committed test and fix together), retry with RED_FIRST_OVERRIDE=\"<how red was proved>\" (recorded in telemetry)." >&2
exit 2
