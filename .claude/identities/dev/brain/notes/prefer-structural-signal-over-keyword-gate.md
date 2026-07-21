---
tags: [security, hooks, parsing]
paths: ["plugins/spec-workflow/scripts/*.sh"]
strength: 1
source: "PR#237 pass-2 review finding, dev retro"
graduated: false
created: 2026-07-21
---

For a hook/checker whose job is detecting a content-dump/read operation, prefer the broadest structurally-sufficient signal (a protected-path literal appearing anywhere in argv) over a narrow dump-verb keyword gate (open(/readFile/...). A keyword substring gate just enumerates an infinite list of idioms one at a time -- pathlib.Path(...).read_text() is one of many that slip past open(/readFile. Before calling test coverage complete, spend two minutes listing sibling idioms for the same operation (3+ ways to read a file in the target language) and test at least one not already in the design doc's list.

Related: [[audit-new-path-parity-before-writing]]
