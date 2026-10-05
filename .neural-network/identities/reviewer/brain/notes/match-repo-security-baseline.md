---
tags: [review, security, ci]
paths: [".github/workflows/**"]
strength: 1
source: "PR#190 CDX-040 retro"
graduated: false
created: 2026-07-18
---

When judging a security/rigor tradeoff in a diff (e.g. "should this curl step verify a checksum?"), check the repo's OWN EXISTING practice for the same category of risk before importing an external standard. A lone stricter-than-precedent objection is often reviewer-invented scope creep, not a real gap.

Caveat: this only holds when the existing precedent wasn't ITSELF already flagged elsewhere as a known gap -- otherwise "matches precedent" just launders two bugs into one instead of catching either.

Recurrence (CDX-040): a new CI step downloads a shellcheck release binary over HTTPS with no checksum verification. Checked the rest of ci.yml first -- the existing `npm install -g @anthropic-ai/claude-code` step has the same posture (HTTPS + exact version pin, no hash check), and action pins (`actions/checkout@v4`) are tag-pinned not SHA-pinned. Approved as consistent with the repo's existing bar rather than demanding stricter verification unilaterally.

Related: [[verify-guard-regex-on-real-artifact]]
