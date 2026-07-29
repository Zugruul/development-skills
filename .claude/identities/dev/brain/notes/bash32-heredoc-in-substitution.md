---
tags: [bash, tests, portability]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: ""
confidence: direct
learned-from: 479
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

Avoid nesting a heredoc directly inside a $(...) command substitution in this repo's bash-3.2-compatible test files: one live case broke bash 3.2's parser with apostrophes in the heredoc body (exact trigger condition unverified — an independent repro attempt failed, so treat the mechanism as unconfirmed). Either way, the established safe convention exists and costs nothing: write the heredoc to a standalone temp file (section-assistant-adapter.sh's pattern) and execute that file separately.
