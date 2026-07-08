---
tags: [api, validation, policy]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#85 retro"
graduated: false
created: 2026-07-08
---

When probing an external policy API (branch protection, rulesets, permissions), a rule/setting being PRESENT is not the rule DEMANDING anything — schemas carry permissive-but-present states (pull_request rule with required_approving_review_count: 0). Write the present-with-no-op-configuration test FIRST, alongside absent and fully-enforcing.

Related: [[bool-excluded-before-int]] [[circular-fixture-detector]]
