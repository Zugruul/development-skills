---
tags: [debugging, shell, tests]
paths: ["**"]
strength: 2
source: "#98 retro — recurrence (>/dev/null in a test discarded the assertion surface)"
graduated: false
created: 2026-07-08
---

`2>/dev/null` (and `>/dev/null` in TESTS) discards the evidence that distinguishes failure classes — the #98 lie survived untested because the suite's own `stop >/dev/null` threw away the very output nobody ever asserted. Grep for /dev/null redirects FIRST when a report says "silently did the wrong thing"; in tests, redirecting a command's output to /dev/null is a declaration that its message is untested.

Related: [[circular-fixture-detector]] [[trace-state-mutation-not-named-trigger]]
