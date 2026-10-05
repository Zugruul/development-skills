---
tags: [review, tooling, shell, evidence]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: 480
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

When a Bash grep/rg over a large file or suite log returns suspiciously few matches, do not conclude "no matches": shell-level output-rewriting hooks (token-saving proxies like rtk) can silently truncate what the tool call sees, appending only a small "+N more" marker that is easy to miss. Redirect the command's output to a file and Read the file directly before treating absence of matches as evidence. Cost seen live: nearly concluded a full-suite run skipped entire sections when the output was merely truncated.

Related: [[reproduce-before-verdict]]
