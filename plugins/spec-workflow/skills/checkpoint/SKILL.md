---
name: checkpoint
description: Pauses or resumes the autonomous build loop via a local gitignored flag file, at safe task boundaries with a handoff. Use for 'pause the loop', 'stop after this task', 'resume the loop', or holding work before a review/deploy gate.
---

# Checkpoint — pause / resume the build loop

The build loop checks a flag file (config `paths.checkpointFile`, default `.claude/CHECKPOINT`) at the start of every iteration.

## Pause
```bash
FLAG=$(jq -r '.paths.checkpointFile // ".claude/CHECKPOINT"' .claude/project.yaml)
echo "optional reason, used verbatim in the handoff" > "$FLAG"   # or just: touch "$FLAG"
```
At the next iteration boundary the loop must: start no new work; leave any *In progress* task on its branch with the board accurate (never faked forward); write a `handoff` (including the flag file's reason); stop and report.

The loop pauses **between** tasks or once the current task reaches a stable status (*In review* at minimum). If interrupted mid-task, the board still reflects reality and the next resume picks it back up.

## Resume
```bash
rm "$FLAG"
```
Then rerun the loop (`/loop /spec-workflow:build-next`). It re-reads the board, so any top-priority bug filed while paused is picked up first.

## Why a file, not a chat instruction
`/clear` wipes conversation context but not the working tree — behavior is driven by repo state, not memory. Ensure the flag path is in `.gitignore` (local-only; never affects other clones or CI).
