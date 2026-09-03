---
tags: [review, tests, bash, vacuous]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #303 review r1"
graduated: false
created: 2026-07-22
---

check()-style helpers doing grep -qF -- "$expected" <<<"$actual" pass VACUOUSLY when expected is an empty computed capture (grep -F '' matches anything) — a crashed heredoc whose stdout came back '' turns every dependent equivalence check green. When auditing a test section, flag any check whose expected side is a captured computation without an accompanying rc/sentinel assertion; when writing findings, prove the vacuous pass by simulating the crash. Caught live: 4 CLI-vs-library checks reported ok while the library was raising AttributeError.

Related: [[mutation-check-assertions]] [[import-and-probe-python-library]]
