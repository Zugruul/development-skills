---
tags: [javascript, vendoring, templates]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: "#431"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Vendored browser bundles are built for ONE loading mechanism: a classic-script IIFE run via dynamic import() executes in module scope where its top-level var never reaches globalThis — the bundle itself crashes. Load vendored artifacts the way they were built (script tag vs import), and make loader-code stubs reproduce the artifact's REAL contract (global side effect, zero exports), never the loader's assumed shape.

Related: [[stub-failure-semantics]]
