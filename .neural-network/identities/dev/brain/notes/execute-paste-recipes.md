---
tags: [tests, cli, recipes]
paths: ["plugins/spec-workflow/scripts/**", "plugins/spec-workflow/tests/**"]
strength: 1
source: "#65 retro"
graduated: false
created: 2026-07-08
---

A "paste this" recipe can be text-match green while completely unusable — paste-position bugs (global vs subcommand flags, arg order, real-shell quoting) are invisible to substring checks. Test recipes by BUILDING the exact documented paste template into a real command file and EXECUTING it, asserting on git/system state. Fixture quirk to remember: config.py resolves project.yaml OVER project.json silently — remove the yaml before writing a json override, or it's ignored without warning.

Related: [[circular-fixture-detector]] [[fake-cli-exit-code-is-contract]]
