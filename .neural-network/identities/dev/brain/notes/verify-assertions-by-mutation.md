---
tags: [testing, mutation, assertions, quality]
paths: []
strength: 1
source: "task-524"
confidence: direct
graduated: false
created: 2026-08-02
last-touched: 2026-08-02
---

# Prove an assertion by breaking the code it covers

An assertion that has never failed is a guess. The cheap proof is mutation:
deliberately break the behavior the test claims to cover, confirm the suite goes
red, then restore.

This is not theoretical. A reviewer demonstrated several load-bearing
assertions surviving deliberate mutation — the security-critical quoting step
was replaced with a no-op and the suite stayed green, because the assertions
were satisfied by a validation rule that ran earlier and by a log that
accumulated across the whole file.

Do it for every assertion that guards something expensive to get wrong:
security boundaries, ordering guarantees, "this thing is actually invoked".
Anything that survives its own mutation is decoration and should be rewritten
or deleted.

Cheap recipe: copy the file, apply the break, run the section, restore, and
record the failure count in the commit message so the proof outlives the
session. Related: [[bash-test-sections-shared-state]],
[[hermetic-fake-cannot-prove-execution]].
