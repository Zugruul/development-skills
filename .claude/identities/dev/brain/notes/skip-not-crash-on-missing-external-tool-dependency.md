---
tags: [testing, hermetic, external-dependency]
paths: ["plugins/spec-workflow/tests/section-codex-plugin-json.sh"]
strength: 1
source: "task #175 (CDX-003)"
graduated: false
created: 2026-07-16
---

When a test's assertion depends on a tool that lives outside this repo (an external CLI/script + its own runtime deps), gate the section behind a presence check and emit a visible SKIP when it's missing -- never let a missing-file or missing-import error crash the whole hermetic suite.

Why: #175 (CDX-003)'s new test calls Codex's `validate_plugin.py` under `~/.codex/...`, which itself `import yaml`s. On a machine without that Codex skill installed or without the yaml package, a hard dependency would turn one optional external check into a suite-wide failure -- non-hermetic and flaky by environment, not by actual regression.

How to apply: `[[ -f "$VALIDATOR" ]] && python3 -c 'import yaml' 2>/dev/null` (or equivalent) before running an out-of-tree tool in a section-*.sh test; print a SKIP line rather than silently passing or hard-crashing, so the check still runs (and means something) on machines that have the dependency, while staying green everywhere else. Separately: "passes the validator" and "is honest, non-templated content" are different bars -- a schema validator only catches structural defects (e.g. [TODO:] markers), not generic filler; populate free-text fields from real repo knowledge (README, actual SKILL.md files), not boilerplate.
