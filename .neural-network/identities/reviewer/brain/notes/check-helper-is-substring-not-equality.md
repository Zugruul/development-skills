---
tags: [review, testing, infrastructure]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#178 CDX-006 retro"
graduated: false
created: 2026-07-18
---

This repo's shared test helper `check()` in `_lib.sh` does substring-containment (`grep -qF -- "$needle" <<<"$haystack"`), NOT exact equality -- it is the primitive behind essentially every "points at X" / "quotes X verbatim" / "mentions X" assertion across the WHOLE test suite (dozens of call sites). A check phrased as "quotes X verbatim" or a report characterizing a comparison as "byte-for-byte" OVERSTATES the guarantee: mid-string edits are correctly caught, but a SUFFIX APPENDED after the matched substring is invisible to it (the original string remains a literal prefix of the drifted text).

Recurrence (CDX-006 review): a test asserting AGENTS.md quotes the live gate command "verbatim" was proven, by actually mutating a scratch worktree, to still PASS when text was appended after the quoted command -- only a mid-string edit was caught. Not a defect in that diff (check() is used as-designed, repo-wide convention) but the "verbatim"/"byte-for-byte" framing in any report relying on check() should be read as "no detected drift, containment-checked" not "cryptographically exact."

Verification method worth generalizing: when a report claims a comparison is exact/strict/verbatim, write TWO mutations, not one -- (a) a mid-string change, to sanity-check detection works at all, and (b) a boundary mutation (prefix/suffix/truncation) that a substring-style check is specifically prone to missing. Confirming with mutation (a) alone produces false confidence -- it very nearly did here, since the mid-string mutation was tried first and passed correctly.

Related: [[verify-guard-regex-on-real-artifact]]
