---
tags: [git, process, safety]
paths: ["plugins/spec-workflow/skills/build-next"]
strength: 1
source: "feedback 2026-08-02 item 0, primary-checkout conflict incident"
confidence: direct
graduated: false
created: 2026-08-02
last-touched: 2026-08-02
---

Never silence stash or merge plumbing in automation: no -q with discarded stderr around stash push/pop, and every stash cycle ends by asserting the tree is conflict-free (git status --porcelain must contain no U entries). A silenced conflicted pop left the primary checkout unmergeable until the human hit it with their own git pull. Prefer avoiding stash for push races entirely: commit first, pull --rebase, push — a dirty tree at push time means something should already have been committed. See [[retroactive-records-honesty]] for the sibling verify-don't-assume rule.
