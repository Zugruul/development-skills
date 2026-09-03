---
tags: [testing, tdd, diagnostics]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#180 CDX-010 retro"
graduated: false
created: 2026-07-19
---

When writing a test helper that does STRING SURGERY (extracting/stripping/transforming text) whose output feeds many DOWNSTREAM assertions, write a paired "sanity check against a real file" FIRST, immediately after the helper: assert the raw input still has the thing being stripped, assert the stripped output does NOT have it, assert the stripped output STILL HAS some known-real content that should survive. This self-check cannot catch every bug (e.g. an environment-specific one your own sandbox can't reproduce -- see [[verify-portability-claims-in-target-environment]]) but it makes root-causing an eventual failure IMMEDIATE from the log alone: a single FAIL line naming the exact missing expected content on a self-check assertion tells a reader "the extraction function is broken" in one line, rather than leaving them to infer that from 30+ unrelated-looking downstream failures.

Recurrence (CDX-010): `stripfm()` had a 3-assertion self-check (raw file has frontmatter marker / stripped file lacks it / stripped file still has its real heading) before 30+ downstream constraint-preservation checks depended on it. When stripfm() broke on GNU sed in CI, the self-check's own middle assertion ("stripped ... body still has its heading -- got: <empty>") let the root cause be diagnosed from the CI log in under a minute, rather than needing to reproduce the whole failure locally first.

Related: [[verify-guard-regex-on-real-artifact]]
