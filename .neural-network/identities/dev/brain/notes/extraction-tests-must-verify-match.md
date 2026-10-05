---
tags: [testing]
paths: []
strength: 1
source: ""
learned-from: loop-feedback 2026-07-07 task-30
graduated: false
created: 2026-07-07
---

A test that extracts code from a template/file by regex must first assert the extraction matched the expected shape; a silently-empty match turns a security regression test into noise. Related: [[lane-cwd-distrust]].
