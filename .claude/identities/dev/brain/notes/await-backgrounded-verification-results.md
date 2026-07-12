---
tags: [gate, delivery]
paths: []
strength: 1
source: "retro"
learned-from: tasks 154/158 close
graduated: false
created: 2026-07-12
---


# Never go idle on a backgrounded verification — wait for it and act

When a gate/test run auto-backgrounds under the harness, ending the turn means
the result is never acted on: the pass sits unrecorded, the branch unpushed,
the PR unopened, until someone nudges. Either wait the run out in-session, or
arm an explicit completion signal and treat the notification as your cue to
finish delivery (record → push → PR → report) in the same wake-up.
