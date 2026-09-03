---
tags: [infra, git-config, anomaly]
paths: []
strength: 1
source: "main repo dir, .git/config user.name=T, discovered mid-#171-merge"
graduated: false
created: 2026-07-15
---

During a long autonomous loop, check the repo's own .git/config for an unexplained local user.name/user.email override before assuming git commands will attribute correctly -- I found user.name=T set locally (not by any of my own commits, which always use -c flags) partway through this session, origin unknown. Doesn't break anything if you always use explicit -c/--author flags for role commits, but is worth noticing and flagging rather than silently working around forever.
