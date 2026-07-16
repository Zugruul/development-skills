---
tags: [testing, auth, verification]
paths: ["**"]
strength: 1
source: "adhoc UI fix session, 2026-07-16"
graduated: false
created: 2026-07-16
---

When verifying a running app reachable through multiple origins (a local port and a public tunnel), commit to one origin for the whole verification session — auth callbacks, navigation, generated links all included. Cookies/sessions do not carry across origins, and mixing them burns turns on avoidable auth failures.
