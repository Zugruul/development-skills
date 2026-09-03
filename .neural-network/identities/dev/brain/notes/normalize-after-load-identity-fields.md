---
tags: [yaml, serialization, identity]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#63 retro"
graduated: false
created: 2026-07-08
---

A field that is (a) round-tripped through a loosely-typed format (YAML/JSON) and (b) used as an identity/lookup key must be normalized IMMEDIATELY after load — before any comparison or re-dump — never at the comparison site, and never by fighting the parser. YAML 1.1 implicit resolvers re-type timestamp/int/bool/null-shaped strings. When one boundary gets the fix (emit), audit every OTHER read site of the same field (route) — the bug is symmetric.

Related: [[bool-excluded-before-int]] [[rehearse-migration-on-real-copy]]
