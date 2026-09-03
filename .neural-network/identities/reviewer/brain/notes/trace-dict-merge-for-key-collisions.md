---
tags: [review, schema]
paths: ["**"]
strength: 1
source: "PR#231 (MEM-022, #135) review round 1 -- caught feedback.py's payload ts silently clobbering emit_event's baseline ts via event.update(obj)"
graduated: false
created: 2026-07-19
---

When a diff adds a payload dict that gets merged into a shared record via dict.update() or equivalent (e.g. event = {...baseline...}; event.update(caller_payload)), check whether any of the caller's new keys collide with the baseline's own field names -- a same-named key silently overwrites the baseline value with no error, and this is easy to miss when only reading the caller's own code (the collision only becomes visible by reading BOTH the baseline-setter and the caller together).

Related: [[verify-backcompat-claims-algebraically]]
