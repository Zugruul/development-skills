---
tags: [vendor, tests, gate, assets]
paths: ["plugins/spec-workflow/templates/vendor/**", "plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#61 (#60) retro"
graduated: false
created: 2026-07-07
---

When guarding a vendored library build, grep the vendored artifact itself for its own relative import statements and assert each target is vendored on disk AND allowlisted — never hardcode a fixed file list. A self-discovering guard survives the NEXT re-vendor (e.g. three.js r167 split module/core) instead of needing a manual update every time.

Related: [[red-static-vs-wiring-checks]]
