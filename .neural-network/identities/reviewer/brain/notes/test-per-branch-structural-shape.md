---
tags: [review, regex, testing]
paths: ["plugins/spec-workflow/scripts/*.sh"]
strength: 1
source: "PR#237 pass-1 review finding"
graduated: false
created: 2026-07-21
---

For a checker whose core mechanism is one regex/pattern applied at multiple call sites with different structural shapes (bare argv token vs. a substring embedded mid-token inside a larger string), an anchor or precondition correct for one call site can silently fail at another. Test at least one adversarial input per branch whose surrounding text differs from how the shipped fixtures constructed it (quoted/embedded vs. bare token) -- an anchor that holds at token boundaries often silently fails mid-string.

Related: [[enumerate-sibling-gates-after-a-fix]]
