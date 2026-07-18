---
tags: [testing, bash, bug]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#214 (CDX-030), live-encountered"
graduated: false
created: 2026-07-18
---

A bare `cd "$DIR"` (not wrapped in a subshell) inside a section-*.sh test fixture leaks the shell's cwd to every section that runs after it — run-tests.sh sources all section-*.sh files into ONE shell process, so cd doesn't scope to the function/block the way it would in a subprocess. If the leaked-into dir then gets `rm -rf`'d (common fixture cleanup), every subsequent section runs from a deleted cwd and fails in confusing, seemingly-unrelated ways (subprocess spawns fail, relative paths break, "getcwd: cannot access parent directories"). Always wrap a fixture's own `cd ... && cmd` in `(...)` or `$(...)` the same way every OTHER line in these files already does — this file's own established convention was the fix.
