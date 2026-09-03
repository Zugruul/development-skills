---
tags: [testing, architecture, fixtures]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#128 MEM-004 retro"
graduated: false
created: 2026-07-18
---

A test asserting a fact about THIS repo's own live checkout state (e.g. "is this path currently gitignored?") is a DIFFERENT testing category from a fixture-based test asserting a reusable pattern in a temp repo -- keep them in separate files, even when they superficially test "the same kind of thing." Mixing a live-repo-state check into a fixture-based section blurs what's being verified (the general mechanism vs. this one checkout's actual compliance) and makes the fixture file's intent -- reusable pattern-checking, portable across projects -- accidentally location-dependent.

Recurrence (MEM-004): a new test asserting `git check-ignore .claude/feedbacks/feed.yaml` against THIS repo's real `.gitignore` (via `REPO="$(cd "$PLUGIN/../.." && pwd)"`) was deliberately given its own file (section-repo-hygiene.sh) rather than appended to the existing fixture-based section-local-state-manifest.sh, whose tests all run against temp fixture repos.

Related: [[write-fixtures-direct-for-read-path-tests]]
