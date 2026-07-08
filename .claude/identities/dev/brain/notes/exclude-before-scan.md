---
tags: [parsing, security, shell]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#76 retro (3 rounds)"
graduated: false
created: 2026-07-08
---

Structure-collapsing input classes (heredoc bodies, command substitutions, quoted strings) must be EXCLUDED or specially modeled BEFORE a general-purpose token scan runs — in the input's own lexical order — never patched into the scan's state machine: position tracking is a property of the token stream, and content that shouldn't be in the stream defeats it from inside. Write coverage comments literally true, not aspirationally ("handles heredocs" ≠ "handles heredocs without operator-shaped text"). When embedding language A's source in language B's string literal, treat B's delimiter characters as forbidden in A and syntax-check (bash -n) before running.

Related: [[circular-fixture-detector]] [[heredoc-commit-messages]]
