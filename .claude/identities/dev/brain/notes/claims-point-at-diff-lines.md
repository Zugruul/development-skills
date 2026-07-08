---
tags: [reports, honesty]
paths: ["**"]
strength: 1
source: "#45 retro (report-vs-code mismatch caught in review)"
graduated: false
created: 2026-07-08
---

Never write "documented"/"verified" in a report unless you can point at the exact diff line while writing the sentence — a scratch-terminal check is an empirical observation, not a claim about the code. Phrase honestly: "verified empirically, not yet written into the file" — or write it into the file first.

Related: [[flag-safety-language-removal]] [[fake-cli-exit-code-is-contract]]
