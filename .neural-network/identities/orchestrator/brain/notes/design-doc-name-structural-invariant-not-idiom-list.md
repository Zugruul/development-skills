---
tags: [design-docs, briefing, checkers]
paths: ["docs/design/**"]
strength: 1
source: "PR#237 feedback item, orchestrator retro"
graduated: false
created: 2026-07-21
---

When writing a design doc for a new pattern-matching guard/checker, specify the underlying STRUCTURAL invariant the match should enforce (e.g. a protected-path literal appearing anywhere in scope) rather than an enumerated list of keyword/verb idioms to catch. An enumerated list is provably incomplete the moment a new idiom appears; a structural signal degrades gracefully. Where a keyword list is unavoidable, say explicitly in the doc that it's a known-incomplete enumeration, not a closed set, so reviewers hunt for missing idioms instead of trusting the shipped list.

Related: [[prefer-structural-signal-over-keyword-gate]]
