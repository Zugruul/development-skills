#!/usr/bin/env bash
# tree-state.sh — print a fingerprint of the working tree (tracked tree
# content at HEAD, excluding generated/reconciled paths, + uncommitted changes).
# Shared by gate.sh (records it) and guard-board-move.sh (verifies it).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT" || exit 1
python3 <<'PY'
# Hash HEAD's tracked tree content + uncommitted diff (via git, run in-process)
# plus, for every untracked-and-not-.gitignore'd file (git ls-files --others
# --exclude-standard), its path and content. One process handles all untracked
# files (no fork per file); paths and content come through NUL-safe so
# filenames with spaces/newlines can't desync the fingerprint, and a rename
# (path changes, content doesn't) still changes the hash.
import hashlib
import subprocess
import sys


def run(args):
    return subprocess.run(args, capture_output=True).stdout


h = hashlib.sha256()
# #443: hash the TRACKED TREE CONTENT at HEAD (path+blob-sha pairs, via
# `git ls-tree -r`) -- NOT the raw commit SHA -- excluding CHANGELOG.md. CI's
# changelog action (.github/workflows/changelog.yml, "chore(changelog):
# regenerate") pushes a new commit straight to main after every merge whose
# ONLY content change is CHANGELOG.md. A raw-commit-SHA fingerprint treats
# that new commit as "the tree changed" even though the actual code is
# byte-for-byte identical to what the gate already tested -- every merge in
# the loop paid a full gate re-run purely to acknowledge a regenerated doc.
# Hashing tree CONTENT rather than commit identity is also the more honest
# definition for what this fingerprint claims to answer ("does the code on
# disk match what was tested") -- two commits with byte-identical trees
# (modulo the excluded doc) really do describe the same tested code, whatever
# their positions in history.
#
# `git ls-tree` does NOT support `:(exclude)` pathspec magic (unlike
# `status`/`diff` below -- confirmed: it fails with "pathspec magic not
# supported by this command", exit nonzero). Filtering the CHANGELOG.md
# entry out in Python instead of via pathspec is not a style choice, it is
# the only option.
#
# #443 review round 2 (MEDIUM): the ORIGINAL version of this block treated
# ANY `git ls-tree` failure (returncode != 0, for ANY reason) as "no HEAD
# yet" and fell back to a fixed placeholder. The reviewer proved that is
# wrong with a `git` shim on PATH that fails ONLY on `ls-tree` (a real git
# version quirk or transient error would do the same): two DIFFERENT clean
# committed trees produced the IDENTICAL fingerprint, silently. That is the
# exact "stable placeholder masks a real change" failure mode this whole
# mechanism exists to prevent -- worse here because the degradation is
# invisible (no error, a plausible-looking hex digest either way), and
# because `ls-tree` has already broken once on an invocation detail
# (`:(exclude)`) that seemed safe until it was actually run. Fix: detect
# the ONE legitimate reason for "nothing to list" explicitly, via `git
# rev-parse --verify HEAD` (a real, targeted check for "does HEAD resolve
# to a commit at all", not an incidental side effect of some unrelated
# ls-tree failure). Any OTHER ls-tree failure is FATAL: print the error and
# exit nonzero, so tree-state.sh itself fails loudly (no hash printed at
# all) rather than ever risk two different trees hashing the same.
# gate.sh's own caller (see its own comment on the tree-state.sh call)
# checks this exit status and refuses to record a pass rather than write a
# broken/empty marker.
verify = subprocess.run(["git", "rev-parse", "--verify", "-q", "HEAD"], capture_output=True)
if verify.returncode != 0:
    h.update(b"no-head")
else:
    head_tree = subprocess.run(
        ["git", "ls-tree", "-r", "-z", "HEAD", "--"],
        capture_output=True,
    )
    if head_tree.returncode != 0:
        sys.stderr.write(
            "tree-state: git ls-tree failed (rc=%d): %s\n"
            % (head_tree.returncode, head_tree.stderr.decode(errors="replace"))
        )
        sys.exit(1)
    entries = [e for e in head_tree.stdout.split(b"\0") if e]
    kept = [e for e in entries if not e.endswith(b"\tCHANGELOG.md")]
    for e in sorted(kept):
        h.update(e)
        h.update(b"\0")
# .claude/gate-pass is the fingerprint marker itself: it does not exist yet
# when gate.sh records a pass, but does exist on every check afterward. It is
# excluded from both the porcelain status and the untracked-file listing
# below via an explicit pathspec, independent of .gitignore (a repo that
# doesn't happen to ignore it — or where .claude/ contains another tracked
# file, so it can't collapse to a single "?? .claude/" line — must not have
# the mechanism invalidate its own recorded pass).
#
# .claude/telemetry.jsonl gets the same treatment for the same reason: both
# gate.sh and the status-transition command append to it as a side effect (see
# their own comments), and in a repo that doesn't happen to gitignore it, any
# routine status transition (for any task, by any concurrent lane) would
# otherwise touch this shared file and invalidate a still-current, unrelated
# gate pass.
#
# .claude/lessons.jsonl (SW-020, SPEC §8.1) gets the same treatment for the
# same reason: gate.sh appends a red-gate record to it as a side effect of a
# gate run, so in a repo that doesn't happen to gitignore it, a routine gate
# re-run would touch this shared file and invalidate a still-current,
# unrelated gate pass.
#
# .claude/board-cache.json (issue #78) gets the same treatment for the same
# reason: board.sh's move/prio/est/add/adopt/next/list/audit all write it as
# a side effect of the item-id cache, so in a repo that doesn't happen to
# gitignore it, a routine board mutation (for any task, by any concurrent
# lane) would otherwise touch this shared file and invalidate a still-
# current, unrelated gate pass.
#
# CHANGELOG.md is excluded here too (status/diff, not just the HEAD-tree hash
# above) for the same reason as the .claude/ files: a LOCAL, not-yet-committed
# regenerate (someone ran the changelog-generate skill by hand before gating)
# must not invalidate an otherwise-still-current pass either -- consistent
# with the HEAD-tree exclusion rather than only papering over the CI race.
h.update(run([
    "git", "status", "--porcelain", "--", ".",
    ":(exclude).claude/gate-pass", ":(exclude).claude/telemetry.jsonl",
    ":(exclude).claude/lessons.jsonl", ":(exclude).claude/board-cache.json",
    ":(exclude)CHANGELOG.md",
]))
h.update(run(["git", "diff", "HEAD", "--", ".", ":(exclude)CHANGELOG.md"]))

listing = run(["git", "ls-files", "-z", "--others", "--exclude-standard"])
# #443 review round 2 (LOW): CHANGELOG.md was missing from this tuple, so in
# a repo where it is not yet TRACKED at all (e.g. the very first
# changelog-generate run, before anyone has committed it), it shows up as an
# UNTRACKED file -- and creating it invalidated the pass, contradicting the
# whole point of the exclusions above. Same file, same reason, one more path
# through which it can appear.
_EXCLUDED = (b".claude/gate-pass", b".claude/telemetry.jsonl", b".claude/lessons.jsonl",
             b".claude/board-cache.json", b"CHANGELOG.md")
paths = sorted(p for p in listing.split(b"\0") if p and p not in _EXCLUDED)
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
