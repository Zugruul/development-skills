---
tags: [testing, docs, tdd]
paths: ["**"]
strength: 1
source: "PR#178 CDX-006 retro"
graduated: false
created: 2026-07-18
---

When a test needs to assert that documentation content mirrors a config value, read the config LIVE in the test (e.g. `config.py get <key>`) rather than hardcoding the literal into the test itself. Hardcoding collapses two failure modes into the test's own liability: (a) the doc silently drifts if the config value ever changes and nobody remembers to update the test too, and (b) the hardcoded literal becomes a SECOND source of truth alongside the doc's own prose that can itself go stale. Reading live means the test enforces "doc matches reality," not "doc matches what I typed twice."

Recurrence (CDX-006): a test asserting AGENTS.md quotes the repo's gate command read it live via `config.py get commands.gate` rather than duplicating the literal string -- the assertion can never go stale even if the gate command changes later.

For authoring an orientation/pointer doc specifically: source every claim from a file you can point at (project.yaml's real description, an actual config value, an existing README section) rather than generic boilerplate -- this also makes the corresponding test trivial (substring-check the same fact back out of the doc) and leaves zero risk of the doc asserting something untrue.

Related: [[verify-design-doc-quotes-against-live-file]] [[verify-doc-links-and-quotes-against-live-source]]
