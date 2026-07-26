---
tags: [css, templates, ux]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: "#430 review round 1"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Absolutely-positioned hover overlays layered over INTERACTIVE native elements (audio/video controls, inputs) must be pointer-events:none with only their action buttons pointer-events:auto, and the hover trigger must live on the container (the zone can't :hover once it's none). An opacity-0 overlay is still a hit target: #430's audio hover-zone silently blinded the scrubber/volume across 60% of the block.

Related: [[normalize-line-endings-at-split]]
