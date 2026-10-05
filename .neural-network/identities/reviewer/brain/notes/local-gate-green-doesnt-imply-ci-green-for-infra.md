---
tags: [review, ci, infra, verification]
paths: [".github/workflows/**"]
strength: 2
source: "PR#190 CDX-040 retro"
graduated: false
created: 2026-07-18
---

For CI/infra diffs specifically, "local gate green" is a weaker claim than for application code, because tool VERSIONS running locally and on the CI runner can silently diverge even when the invocation/logic is byte-identical -- a green local run only proves the invocation syntax and section-selection logic are correct, it says nothing about environment-specific behavior of an unpinned external tool.

Recurrence (CDX-040): a shellcheck `-x` scope fix passed identically on a local machine (shellcheck 0.11.0) and looked complete, but ubuntu-latest's older apt-provided shellcheck still false-flagged SC2218 on a redeclared-but-identical function -- invisible from reading the diff or the design doc, only surfaced by actually pushing and watching the real CI run.

How to apply: when reviewing (or implementing) a CI/infra change, add an explicit check -- "does this diff depend on any tool whose version isn't pinned identically in both environments (local + CI)?" -- separate from spec compliance. If yes, either pin the version explicitly or treat "local gate green" as provisional until the actual CI run is observed green.

Related: [[pin-external-tool-versions-in-ci]]
