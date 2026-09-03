---
tags: [concurrency, contracts, mem-031]
paths: ["plugins/spec-workflow/scripts/brain.py", "plugins/spec-workflow/scripts/capability.sh"]
strength: 1
source: "MEM-031 dev retro interview, 2026-07-18"
graduated: false
created: 2026-07-18
---

The embeddings capability's stdin/stdout contract (one text per line in, one JSON vector per line out) doesn't specify how to handle a text with internal newlines on what must be a single stdin line. MEM-031 resolved this by flattening internal newlines to spaces before writing each note body to its stdin line. This was a judgment call made independently of MEM-030 (the capability itself, built on a separate branch) — when MEM-030 merges, confirm its actual embed.py does the same flattening, or the line-count 1:1 contract between the two sides could silently mismatch (N stdin lines written vs a different N implied on the read side).

Related: [[sanity-check-fix-against-broken-code]]
