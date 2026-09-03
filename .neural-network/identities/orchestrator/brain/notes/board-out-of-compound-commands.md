---
tags: [tooling]
paths: []
strength: 1
source: ""
learned-from: loop-feedback task-16
graduated: false
created: 2026-07-07
---

Keep board-script invocations out of compound commands that also contain heredocs or nested quoting — the fail-closed status-move guard cannot safely parse them and blocks (correctly, fail-closed). Run each board-script call as its own simple statement; write feedback/heredoc content with the Write tool, not inline in the same command as a board-script call. Related: [[lane-cwd-distrust]].
