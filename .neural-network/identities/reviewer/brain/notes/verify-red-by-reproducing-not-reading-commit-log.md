---
tags: [review, tdd, verification]
paths: []
strength: 1
source: "task #175 (CDX-003) review"
graduated: false
created: 2026-07-16
---

Don't trust a subagent's self-report of 'red' or 'gate green' — reproduce it yourself before approving. For a TDD-discipline check specifically, temporarily move the delivered artifact aside, re-run just the new test section, and confirm it genuinely fails for the stated reason before restoring.

Why: in #175 (CDX-003)'s review, the dev agent's commit message claimed the test was red before the manifests existed; verifying this by hand (stash the two new .codex-plugin/plugin.json files, re-run the section, observe the real 'missing plugin.json' failure, then restore) is what makes 'TDD was followed' a checked fact rather than an assumed one from the commit log.

How to apply: for any review where TDD-first is a claimed acceptance criterion, don't stop at reading the red-commit diff -- actually reproduce the red state against the current tree (git stash / mv the new file(s) aside / checkout the pre-fix commit) and re-run the specific test, then restore cleanly before reporting.
