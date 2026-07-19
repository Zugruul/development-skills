---
tags: [review, verification, data]
paths: ["**"]
strength: 1
source: "PR#128 MEM-004 retro"
graduated: false
created: 2026-07-18
---

When reviewing a large committed data file (hundreds+ lines, appended by a known-good writer, e.g. an accumulated log/archive), verify structure at the BOUNDARIES, not the middle: read the FIRST record in full (schema/keys present and sane) and the LAST record in full (nothing truncated, file ends cleanly), then grep the whole file for specific patterns that would indicate a leak or corruption (tokens, PII, secrets, malformed markers) -- rather than reading every line. Full read is warranted for code; for large structured data from a known-good writer, head+tail+targeted-grep scales and catches what actually matters (truncation, garbage, leaked data) without the cost.

Recurrence (MEM-004 review): spot-checked a ~2095-line committed archive YAML this way -- both reviewers independently converged on head+tail+parse rather than a full read, and one additionally ran a full `yaml.safe_load_all` parse (cheap, definitive truncation/corruption check) rather than eyeballing.

Related: [[verify-guard-regex-on-real-artifact]]
