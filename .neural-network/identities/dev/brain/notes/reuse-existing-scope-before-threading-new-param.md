---
tags: [design, bash, testing]
paths: []
strength: 1
source: "task #134 (MEM-021)"
graduated: false
created: 2026-07-16
---

Before threading a new dependency through every function signature, check whether the value is already reachable on an object you're already passed -- and when a test captures a subprocess's output for assertions, make stderr capture explicit and correct, since a silently-uncaptured stderr is a false-green waiting to happen.

Why: #134 (MEM-021) needed emit_event's root parameter in 5 command functions; argparse had already populated args.root on the args object every cmd_* already receives, so wiring needed zero signature changes -- no refactor required. Separately, the byte-identity test's `2>&1` was dangling on its own line after a heredoc terminator (shellcheck SC2188), so stderr was never actually joined to the captured $out -- a genuine Python traceback could have slipped past the assertion silently. Shellcheck in the gate caught it, not the test's own logic.

How to apply: before adding a parameter to thread a new dependency through a call chain, check the objects already in scope (args, config, self) for whether it's already there. When capturing a subprocess's combined output for an assertion, verify `2>&1` is actually attached to the invocation, not floating after a heredoc/subshell terminator where it becomes a no-op redirection.
