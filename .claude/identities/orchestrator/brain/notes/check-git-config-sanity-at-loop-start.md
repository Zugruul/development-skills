---
tags: [infra, git-config, identity]
paths: []
strength: 1
source: "stray user.name=T override, found and fixed mid-loop before #169's briefing"
graduated: false
created: 2026-07-15
---

A local .git/config user.name/email override in the ORCHESTRATOR's own working directory silently corrupts every subsequent identity.sh {name}-template resolution for the rest of the session (e.g. 'Dev Agent - T' instead of the real name) -- even though explicit -c flags on individual commits stay correct, any DISPLAY-only use of identity.sh's resolved name (reports, briefs, dry-run output) inherits the bad value. Check git config user.name/email sanity at session start of a long autonomous loop, not just when a commit's actual attribution looks wrong.
