---
tags: [review, security, templates]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: "#410 review round 1"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Fix injection at the rendering SINK, not per-caller: when a template helper interpolates text into innerHTML, escape inside the helper (chipHtml wrapping escapeHtml(text)) so every current and future caller is covered by construction — the #410 fix at the sink also closed the pre-existing CHIP_BRANCH exposure for free.

Related: [[probe-spec-silent-input-categories]]
