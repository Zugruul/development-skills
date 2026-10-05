---
tags: [review, registries, design]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #447"
confidence: direct
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

Before recommending anything about a hardcoded list, ask what KIND it is. A DECISION list (which skills ship everywhere) should resist automation — adding an entry ought to cost a human a thought; deriving it turns policy change into an emergent side effect. A FACT list (which engine modules exist) should resist hand-maintenance — the world already determines membership, typing it introduces error and silent decay. Each kind predicts its failure mode: derived-decision fails as silent scope creep, enumerated-fact as silent coverage decay — both invisible in a green suite.
