---
tags: [orchestration, subagents, protocol]
paths: []
strength: 1
source: "Zugruul/development-skills#252"
learned-from: GL-011 retro (rev-252 stall)
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

Subagent idle notifications don't distinguish 'working' from 'wedged'. Protocol: on first unexplained idle, send a status check-in; on a second silent idle past a hard deadline (~10 min), spawn a replacement with the same brief plus an explicit 'report your record before going idle' instruction. Verify the stalled agent left the tree clean before the replacement starts.
