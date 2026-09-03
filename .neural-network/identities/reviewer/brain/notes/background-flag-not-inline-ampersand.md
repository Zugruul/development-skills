---
tags: [shell, background, verification]
paths: []
strength: 1
source: "Zugruul/development-skills#252"
learned-from: GL-011 review retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

For full-suite verification runs: use the Bash tool's run_in_background flag on the un-piped command (redirect to a log file if size is a concern). Inline 'cmd &' silently dies with no notification, and 'cmd | tail -N' truncates away the FAIL lines exactly when you need attribution, leaving only a misleading summary count.
