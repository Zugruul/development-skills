---
tags: [testing, schema]
paths: ["plugins/spec-workflow/schemas/*.json", "plugins/spec-workflow/scripts/validate-config.py"]
strength: 1
source: "PR#228 (CDX-020, #185) -- section-config.sh validates this repo's own live project.yaml directly"
graduated: false
created: 2026-07-19
---

When a schema/config change claims "additive, existing configs still validate unmodified," prove it against the REAL live config file (this repo's own .claude/project.yaml, read at test time), not a copied/hardcoded fixture that could silently drift out of sync with the actual file over time. A copied fixture only proves the fixture stays valid, not that the real file does.

Related: [[old-path-repo-wide-sweep]]
