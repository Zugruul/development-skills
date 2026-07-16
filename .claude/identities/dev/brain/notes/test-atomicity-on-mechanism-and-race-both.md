---
tags: [concurrency, testing, python]
paths: []
strength: 1
source: "task #133 (MEM-020)"
graduated: false
created: 2026-07-16
---

Test an OS-level atomicity claim at its own level, on both axes -- the mechanism and the race -- because output alone catches neither.

Why: #133 (MEM-020) built a 'single atomic append' guarantee (emit_event writing one JSON line under concurrent callers). (1) The mechanism: assert the implementation genuinely makes ONE os.write() syscall (patch/count it) -- a buffered file object or a stray second write silently breaks atomicity while still producing correct-looking output in a quiet single-writer test. (2) The race: drive it with N real OS subprocesses, never threads -- the GIL serializes Python-level writes and would make a genuinely non-atomic implementation pass green anyway.

How to apply: when a task's acceptance criterion is an atomicity/concurrency guarantee, don't stop at 'the output looks right' -- write one test that inspects the mechanism (syscall count/type) and a separate stress test that drives real concurrent OS processes against the shared resource.
