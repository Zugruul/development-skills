---
tags: [review, diagnostics, ux]
paths: []
strength: 1
source: "#199 (sync-configs dry-run wording)"
graduated: false
created: 2026-07-16
---

A dry-run diagnostic message computing a count with an ambiguous unit (e.g. 'N lines' without specifying whether N is a total, added, removed, or diff size) is a real footgun even for a careful reader -- this exact message was already misread once before the fix. When reviewing or writing diagnostic/dry-run output, check that every number's unit is unambiguous from the message text alone, not just from reading the source.
