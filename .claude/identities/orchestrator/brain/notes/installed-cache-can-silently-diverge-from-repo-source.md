---
tags: [infra, plugin-cache, dogfooding, bug]
paths: []
strength: 1
source: "#171 QA -- false negative on peer-reviewer role resolution, root-caused to stale ~/.claude/plugins/cache copy, filed as #197"
graduated: false
created: 2026-07-15
---

This repo dogfoods itself via an installed plugin cache (~/.claude/plugins/cache/...) that is a SEPARATE copy from the repo's own source tree and does NOT auto-refresh on merge to main. When calling board.sh/gate.sh/identity.sh etc. during an autonomous loop, verify the cache matches current HEAD (diff the script or check for a refresh mechanism) before trusting its behavior against just-merged config/code changes -- a stale cache silently ran old logic against new repo state and produced a false 'unknown role' QA failure for #171. Prefer calling scripts from the repo's own plugins/<name>/scripts/ path directly during dogfooding sessions in this specific repo.
