---
tags: [bash, heredoc, tests, macos]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #424 + #441 (hit independently by both lanes)"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Under macOS stock bash 3.2, an apostrophe in a comment INSIDE a quoted heredoc body (which should be inert) can break quote tracking and surface as a syntax error dozens of lines away. Team rule: no apostrophes/contractions in comments inside heredoc bodies in this repo's test files. Fast diagnosis: do not trust bash -n's line number; confirm against the last known-good version, then bisect by DELETING candidate lines from a full copy — never by truncating, which fabricates unclosed-heredoc errors that look like confirmation.
