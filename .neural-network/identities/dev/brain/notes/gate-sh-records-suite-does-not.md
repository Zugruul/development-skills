---
tags: [gate, process, verification]
paths: ["plugins/spec-workflow/scripts/gate.sh"]
strength: 1
source: "retro 2026-07-21 GL-006/276 closes"
graduated: false
created: 2026-07-21
---

Only `gate.sh` records the pass the In-review move-guard requires — running the suite components (run-tests.sh + shellcheck + validate) proves green but records NOTHING, and the move guard will rightly block. Two dev agents in one session hit this. Run `gate.sh` itself via nohup+log, then confirm BOTH the "GATE PASS recorded" log line AND the worktree's .claude/gate-pass file exist before claiming the gate.

Related: [[gate-runs-outlive-agent-turns]]
