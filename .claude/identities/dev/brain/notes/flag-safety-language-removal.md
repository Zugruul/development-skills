---
tags: [docs, protocol, review]
paths: ["plugins/spec-workflow/skills/**"]
strength: 1
source: "#85 retro"
graduated: false
created: 2026-07-08
---

Retiring a safety/consent-flavored doc section is ALWAYS worth an explicit flag in the report (what guardrail was removed and why), never a silent judgment call — the reviewer/human must be able to veto that specific removal before it's buried in a large diff. Corollary for doc-contract tests: pinned phrases must fit one physical line — markdown hard-wrapping silently breaks grep -F pins.

Related: [[present-vs-demanding-policy-rules]] [[heredoc-commit-messages]]
