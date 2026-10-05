---
tags: [testing, dogfooding, rendering]
paths: []
strength: 1
source: "retro 2026-07-22 (code-span bug found via demo note)"
graduated: false
created: 2026-07-22
---

After shipping a rendering/parsing feature, immediately author a real artifact that exercises every supported input — INCLUDING documentation-style literal examples of the syntax itself. A demo note whose backtick-quoted syntax examples came alive as broken embeds exposed a tokenizer that ignored code spans; the demo doubled as the regression fixture. Docs-of-the-feature are adversarial inputs to the feature.
