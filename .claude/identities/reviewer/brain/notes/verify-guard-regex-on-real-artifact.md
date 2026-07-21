---
tags: [review, verification, fixtures]
paths: ["**"]
strength: 4
source: "PR#190 CDX-040 retro (scope broadened from MEM-031)"
graduated: true
created: 2026-07-07
---

A test guard built on a regex/extraction can silently no-op against the real artifact it claims to cover (minified syntax, wrong anchors, empty match). Before crediting the guard as coverage, run its exact extraction against the actual file and confirm the matched content's length/shape -- an empty or truncated match means the test passes vacuously.

Recurrence (MEM-031 review): a TSV-row assertion (`check_absent ... $'alpha\t\t' "$tbl"`) targeted the wrong COLUMN -- it could only ever match an empty content_hash, never an empty vector, so it passed even against completely broken vector storage.

Recurrence 2, broadened scope (CDX-040 review): the same failure family applies to a claim about a DOWNLOADED external artifact, not just a repo file -- a commit message asserted a release tarball's internal path (`shellcheck-v0.11.0/shellcheck`) without the reviewer downloading and extracting it. "Sounds plausible" and "verified correct" look identical in review text unless you actually fetch and inspect the real artifact. Applies to any claim about a file/path/structure the reviewer hasn't personally opened -- repo file, generated output, or third-party download alike.

Related: [[recompute-hashes-never-eyeball]] [[red-commit-worktree-verify]] [[match-repo-security-baseline]]
