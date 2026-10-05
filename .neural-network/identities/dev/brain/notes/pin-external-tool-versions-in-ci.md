---
tags: [ci, infra, verification]
paths: [".github/workflows/**"]
strength: 2
source: "PR#190 CDX-040 retro"
graduated: false
created: 2026-07-18
---

Before writing a CI step that downloads/installs an external release artifact (a binary, tarball, etc.), verify the exact asset name and internal path structure LOCALLY first, rather than guessing a plausible URL/path from memory or documentation. Cheap (a couple commands) and turns "should work" into "confirmed to work," catching filename-pattern or path-layout mismatches before a CI round-trip is needed to find them.

Recurrence (CDX-040): confirmed the real release asset name via `gh release view v0.11.0 --repo koalaman/shellcheck --json assets -q ".assets[].name"` (rather than assuming a filename pattern), then actually `curl`+`tar xf` the candidate URL locally to confirm both the URL resolves AND the extracted directory/binary path matches what the install step's `cp` command expects.

Separately: a green local gate does not by itself prove a CI/infra fix works -- it proves the invocation LOGIC is correct, not that every tool the invocation depends on is the SAME VERSION on the CI runner. An unpinned external tool (installed via apt/OS-default rather than a pinned release) is a hole in that equivalence -- pin it, or explicitly flag the residual risk instead of asserting parity.

Related: [[local-gate-green-doesnt-imply-ci-green-for-infra]]
