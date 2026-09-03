---
tags: [lint, gates, tests]
paths: ["plugins/spec-workflow/scripts/**", "plugins/spec-workflow/tests/**"]
strength: 1
source: "#45 retro"
graduated: false
created: 2026-07-08
---

A linter/gate that scans its own home directory WILL find its own fixture text and its own prose describing the patterns it hunts — treat "this file's source vs its own triggers" as a first-class test case from the start (grep the new file against its new regex before wiring it in), and keep fixture bodies in a subdirectory outside the scan glob. When a scanned pattern has multiple syntactic forms (bash single- vs double-quoted), assume ALL forms exist in a real tree until grepped and proven otherwise.

Related: [[circular-fixture-detector]] [[exclude-before-scan]]
