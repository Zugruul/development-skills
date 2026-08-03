---
tags: [testing, hermetic, doubles, shell, integration]
paths: []
strength: 1
source: "task-524"
confidence: direct
graduated: false
created: 2026-08-02
last-touched: 2026-08-02
---

# A fake that records a command can never prove the command works

Hermetic test doubles that capture arguments and pattern-match them prove one
thing only: the text looks right. They cannot prove the text DOES anything,
because nothing ever interprets it.

That gap hides an entire class of bug. A path fix once wrapped a value that had
to remain expandable by the receiving interpreter; every assertion still saw
the expected characters and passed, while in reality no dispatched work could
start at all.

Rule: whenever a layer builds a string that some OTHER interpreter will
execute — a shell, a query engine, a template renderer — at least one test must
RENDER the real artifact and EXECUTE it in a sandbox (a scratch HOME, a temp
database, a throwaway directory) and assert on the effect, not the text.

Keep the recording double for breadth; add one executing test for truth.
Related: [[verify-assertions-by-mutation]].
