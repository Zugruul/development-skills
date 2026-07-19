---
tags: [review, docs, verification]
paths: ["**"]
strength: 1
source: "PR#178 CDX-006 retro"
graduated: false
created: 2026-07-18
---

For a pointer/orientation doc (AGENTS.md-style, README cross-refs, onboarding docs), always (a) confirm every markdown link target actually exists on disk -- a broken link in an orientation doc silently strands the reader; (b) diff every verbatim-quoted artifact (a command, a config value, a code snippet) BYTE-FOR-BYTE against its live source rather than eyeballing for plausibility -- re-derive the value independently (e.g. `config.py get <key>`) rather than trusting the doc's prose.

Also worth standardizing as a review's FIRST move on a docs-only diff: check `git diff --stat` against the design doc's explicit "out of scope" list before reading content in depth -- cheap, catches scope creep immediately, before investing time in prose review.

Recurrence (CDX-006 review): verified every AGENTS.md link target (SPEC.md, SPEC-CODEX-COMPAT.md, docs/BACKLOG-CODEX-COMPAT.md, .claude/project.yaml, README.md) resolves to a real file; independently re-derived the quoted gate command via `config.py get commands.gate` rather than trusting the doc's prose, confirming no drift.

Related: [[verify-guard-regex-on-real-artifact]] [[confirm-named-scope-exclusions-respected]]
