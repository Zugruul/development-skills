---
tags: [frontend, threejs, hit-testing]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: "#72 retro"
graduated: false
created: 2026-07-08
---

three.js raycasting dispatches on the OBJECT CLASS (Mesh vs Line/LineSegments vs Sprite vs Points), never the material — wireframe:true changes rendering only, so a wireframe Mesh still raycasts as a filled triangulated volume. When hit area must match rendered edges, swap the class (LineSegments + EdgesGeometry) before writing distance-to-edge math. For non-nearest-wins priority between target kinds, raycast per-kind groups in priority order (first group with a hit wins) — never sort tricks in one flat call.

Related: [[anonymous-listener-slice-eval]]
