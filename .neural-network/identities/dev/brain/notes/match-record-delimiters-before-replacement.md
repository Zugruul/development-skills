---
tags: [parsing, preservation, tests]
paths: ["**/gitignore-sync.sh", "**/*sync*.py", "**/*sync*.sh"]
strength: 1
source: "Task #274 independent review and runtime audit"
confidence: direct
graduated: false
created: 2026-10-19
last-touched: 2026-10-19
---

## Match the file format
A byte-preserving rewrite must recognize the format's actual record separators. For LF-delimited files, broad splitlines() and rstrip(CR/LF) can turn user data into control markers.

## Verify the boundary
- Probe embedded bare CR, repeated CR terminators, valid LF/CRLF, and missing final newlines.
- Assert exact target bytes on refusal as well as the diagnostic and exit status.
- Keep malformed-marker refusal and owned-temp cleanup in the same regression.

Related: [[boundary-test-needs-exact-value-plus-absence-check]] [[capture-dont-transcribe]]
