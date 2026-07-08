---
tags: [review, security, injection]
paths: ["**"]
strength: 1
source: "#65 review retro"
graduated: false
created: 2026-07-08
---

For injection-safety claims, build your OWN payload in a DIFFERENT shape than the dev's fixture ($(cmd)"; cmd; echo " vs whatever they used) and assert on SIDE EFFECTS (file existence), not on printed text looking escaped — a byte-identical payload only proves their fixture is handled, not the class.

Related: [[drive-real-helper-adversarially]] [[fixture-provenance-check]]
