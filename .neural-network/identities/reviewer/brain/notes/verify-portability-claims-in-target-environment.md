---
tags: [review, portability, ci, verification]
paths: ["**"]
strength: 1
source: "PR#180 CDX-010 post-merge retro"
graduated: false
created: 2026-07-19
---

A local "I ran the tests and they passed" claim is scoped to the ONE shell/tool runtime present in that sandbox -- it is not a portability claim, no matter how thorough the surrounding review was. Shell portability bugs (BSD vs GNU sed/awk/grep flag and regex-range semantics, coreutils vs BSD userland differences) are invisible to ANY review that only executes locally, because the bug lives in the divergence between environments, not in the code's logic as read.

When a fix's (or a finding's) claim IS explicitly "tool/environment X behaves differently from environment Y" -- narrower than the general "verify against the real artifact" habit, which assumes one environment is sufficient -- verifying only in your own single environment cannot structurally confirm OR disprove the claim. Spin up the SPECIFIC other environment and reproduce both the failure (old code) and the pass (new code) there. Cheap in practice: a stock `docker run ubuntu`/`alpine` container is enough for most GNU/BSD userland claims -- no special setup needed if docker is already available.

Recurrence (CDX-010): a sed range-address (`1,/^---$/d`) worked perfectly on BSD/macOS sed (every local run, both first-round reviews, all green) but produced empty output on GNU sed (the actual CI runner) -- invisible until the real CI run failed post-merge. The follow-up fix was verified by actually reproducing the OLD bug on real GNU sed 4.9 in an Ubuntu container, then confirming the NEW awk+tail version passes there too -- proving the fix, not just reading it.

Related: [[verify-guard-regex-on-real-artifact]] [[local-gate-green-doesnt-imply-ci-green-for-infra]]
