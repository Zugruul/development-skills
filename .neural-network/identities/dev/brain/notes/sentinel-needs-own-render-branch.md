---
tags: [python, rendering, edge-cases]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#404 review round 1"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

When a degenerate branch produces a sentinel value (e.g. 'unversioned'), never let it flow through the normal-case template (f"v{version}") — name the sentinel as a constant and give it its own render branch, with its own fixture. Evidence: changelog.py emitted '## vunversioned' for no-plugin.json histories until review; the docstring described the branch but no test exercised it.

Related: [[pin-order-not-just-presence]]
