---
tags: [review, process, efficiency]
paths: ["**"]
strength: 1
source: "PR#181 CDX-011 retro"
graduated: false
created: 2026-07-19
---

Once a repo has learned a construct-specific bug-class lesson (e.g. "sed range-addresses have GNU/BSD-divergent behavior in this file"), the FAST triage step for any future touch of that area is PRESENCE-DETECTION before correctness-analysis: first grep the diff for whether the risky construct (the specific flag/address form/pattern) appears at all. Zero occurrences closes the check in one command; only a nonzero hit requires the deeper cross-environment verification. This avoids re-deriving portability semantics from scratch on every touch of a file that once had a portability bug, while still catching a genuine reintroduction.

Recurrence (CDX-011, the task right after CDX-010's sed-portability fix): reviewed a diff to the SAME test file that had the GNU/BSD sed bug, braced to scrutinize a sed construct -- found the diff introduced zero new sed/awk/grep constructs at all, just reused existing helper/variable calls. The check resolved in one grep, not a full re-analysis.

Related: [[verify-portability-claims-in-target-environment]]
