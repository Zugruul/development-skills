---
tags: [testing, ui, verification]
paths: ["**"]
strength: 1
source: "adhoc UI fix session, 2026-07-16"
graduated: false
created: 2026-07-16
---

Verifying a UI/CSS fix against the live rendered page — computed styles, actual served asset order — catches cascade and specificity bugs that look correct in a source diff but lose at runtime to bundler-controlled stylesheet load order. A static side-by-side read of the two files would not have caught this.
