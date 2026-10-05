---
tags: [debugging, fixtures, subprocess]
paths: ["plugins/spec-workflow/scripts/**", "plugins/spec-workflow/tests/**"]
strength: 1
source: "#70 retro"
graduated: false
created: 2026-07-08
---

Before writing fixtures for a failure mode, run ONE unassumed reproduction through the real pipeline (real script, faked boundary) and look at the actual bytes — the #70 signal (gh's rate-limit text) sat EARLIER in stderr with an uncaught colorized traceback trailing it, so a last-line classifier tested against a synthetic fixture would have passed tests and never fired in production. When a brief's fixture description doesn't match the file, re-derive the mechanism from the real subprocess chain, don't silently correct the reference.

Related: [[trace-state-mutation-not-named-trigger]] [[hermetic-tmpdir-per-guard-case]]
