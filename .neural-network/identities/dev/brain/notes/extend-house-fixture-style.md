---
tags: [tests, config, style, fixtures]
paths: ["plugins/spec-workflow/tests/**", "plugins/spec-workflow/scripts/config.py"]
strength: 1
source: "PR-close #301 dev interview"
graduated: false
created: 2026-07-22
---

When a task extends an EXISTING validated surface (config.py/validate-config), extend the house fixture pattern — one shared broken.project.yaml fixture, many check "broken: <field>" "<exact error substring>" lines in section-config.sh — and match the existing error-string phrasing byte-for-byte. Never invent parallel fixtures or a slightly different message style; grep the FAIL strings first.

Related: [[test-section-shell-plumbing-risk]]
