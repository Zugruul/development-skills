---
tags: [tooling, scripts]
paths: ["scripts/*.py"]
strength: 1
source: "feedback #131 -- telemetry.py run with bash by mistake"
graduated: false
created: 2026-07-19
---

scripts/telemetry.py (and any other python3-shebang script in scripts/) must be invoked as `python3 <path> ...`, never `bash <path> ...` -- running a python file under bash produces a wall of `command not found`/`syntax error` noise that reads like a tool bug, not an invocation mistake. The workflow mixes bash and python scripts heavily (board.sh/gate.sh are bash; telemetry.py/brain.py/feedback.py are python) so this is an easy copy-paste trap.

Related: [[sanity-check-computed-paths-with-ls]]
