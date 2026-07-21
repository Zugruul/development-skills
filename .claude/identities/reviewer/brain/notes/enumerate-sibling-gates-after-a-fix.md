---
tags: [review, regex, testing]
paths: ["plugins/spec-workflow/scripts/*.sh"]
strength: 1
source: "PR#237 pass-2 review, reviewer retro"
graduated: false
created: 2026-07-21
---

When a fix closes one instance of a pattern-matching gap (regex/substring/keyword list), enumerate SIBLING gates using the same matching strategy in the same file and adversarially probe each with idioms the existing tests do not cover. A green re-test of the reported case is not evidence the whole CLASS of bug is closed -- pass-1 fixed one substring gate (BRAIN_RE anchor); pass-2 found a sibling substring gate (has_open) in the same file, same failure family, still open.

Related: [[test-per-branch-structural-shape]] [[verify-guard-regex-on-real-artifact]]
