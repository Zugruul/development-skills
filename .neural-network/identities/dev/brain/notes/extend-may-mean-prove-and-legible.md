---
tags: [briefs, regex, validation]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#89 retro"
graduated: false
created: 2026-07-08
---

"Extend check X to also cover Y" in a brief can turn out to mean "prove X already covers Y and make the diagnostics legible" — verify with a throwaway run against the current code BEFORE adding logic; an unanchored substring regex often already matches the wider form, and the real gap is only the reported fragment.

Related: [[circular-fixture-detector]]
