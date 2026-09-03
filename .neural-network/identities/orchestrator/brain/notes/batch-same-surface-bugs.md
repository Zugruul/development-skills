---
tags: [process, batching, review]
paths: ["plugins/spec-workflow/templates"]
strength: 1
source: "retro 379-381"
graduated: false
created: 2026-07-23
---

Several small bugs on the same surface (same one or two files) batch into ONE branch, review, gate, and merge — provided each bug keeps its own red+fix commit pair for attribution and selective revert. The cycle overhead is paid once; traceability survives in the commit granularity and per-issue board closes.
