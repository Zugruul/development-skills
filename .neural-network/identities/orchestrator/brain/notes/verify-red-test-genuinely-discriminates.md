---
tags: [tdd, testing, process]
paths: []
strength: 1
source: "#197 -- own mistake, caught before it shipped"
graduated: false
created: 2026-07-16
---

A test that 'passes' against a known-buggy implementation might be passing by COINCIDENCE (e.g. the test's own fixture data happened to align with the bug's accidental behavior), not because the fix is correct. When writing a red-first test for a subtle selection/ordering bug, verify the test genuinely FAILS against the actual pre-fix code by running it there directly -- don't just trust 'I wrote a test, it should be red' without checking. Caught myself doing exactly this on #197's first attempt (test passed against the buggy code because my own fixture version numbers happened to sort the same way as mtime would have ordered them).
