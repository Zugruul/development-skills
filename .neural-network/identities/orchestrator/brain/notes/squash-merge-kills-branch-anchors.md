---
tags: [git, registry, provenance]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: #461,#344
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

Under squash-merge delivery, branch commit SHAs never reach main's history — any durable record anchored on one (design-registry applied fields, changelog references, provenance notes) silently breaks git log <anchor>..HEAD semantics later (AST-083 was anchored on orphaned d716c9c and its own apply commit showed up as post-apply drift). Rule: record applied/provenance anchors ONLY as on-main SHAs, which for squash flows means recording AFTER the squash lands (the #344 flow: merge -> design-registry applied <squash-sha> -> board move). Verify anchors with git merge-base --is-ancestor before trusting them.

Related: [[decision-lists-vs-fact-lists]]
