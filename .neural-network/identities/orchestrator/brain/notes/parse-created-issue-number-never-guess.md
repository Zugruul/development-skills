---
tags: [board, process]
paths: []
strength: 1
source: "retro 2026-07-22 (mis-moved an unrelated backlog bug)"
graduated: false
created: 2026-07-22
---

A follow-up mutation on a just-created board item must use the number PARSED from the creation command's output ("filed inbound #N"), never an assumed next-number — concurrent filings make the guess wrong, and a wrong guess silently mutates an unrelated issue (it moved a foreign Backlog bug to In progress before being caught). Same rule for any create-then-act pair: thread the created id through, don't reconstruct it.
