---
name: checkpoint
description: Pauses or resumes the autonomous build loop by writing or clearing a local gitignored flag file, always at a safe task boundary and with a handoff written first. Use for 'pause the loop', 'stop after this task', 'resume the loop', or holding work before a review/deploy gate.
---

# Checkpoint — pause / resume the build loop

The build loop checks `paths.checkpointFile` (default `.claude/CHECKPOINT`). Relative paths belong to the primary checkout, so all linked worktrees share the same pause state. Absolute paths remain absolute.

## Pause
Resolve companion paths relative to this skill, then use the shared configuration loader (YAML and legacy JSON both work). This prints the validated effective path without changing state:

```bash
FLAG=$(PYTHONPATH="../../scripts" python3 -c 'from checkpoint import checkpoint_path; print(checkpoint_path())') || exit 1
mkdir -p "$(dirname "$FLAG")"
printf '%s\n' "optional reason, used verbatim in the handoff" > "$FLAG"
```
An empty flag also pauses. At the next safe boundary, start no new work, keep the board accurate, write a `handoff` (including the flag contents when readable), and stop. An existing task may finish to a stable status (*In review* at minimum); if interrupted earlier, leave its real status and branch intact for resumption.

`bash "../../scripts/checkpoint-preflight.sh" [--root DIR]` is a read-only check: absent means silent success; present, invalid configuration or uninspectable state means an actionable nonzero refusal. `--root` overrides root discovery; otherwise the shared resolver honors `SPEC_WORKFLOW_REPO_ROOT`. Configuration honors `PROJECT_CONFIG` and the shared loader's effective-config rules. Bundled board commands also pass `--board ID --status STATUS` to classify mutation admission; without `--status`, the check guards selection.

## Enforcement
`board.sh next` checks before network reads or queue replay; direct `next.py` also checks and emits neither PICK nor RESUME while paused. Every mutation to the active board's normalized work status (`statusFlow[1]`, or the sole status in a single-status flow) checks before comments markers, API mutation, new queue append or transition telemetry. Repeat requests are refused too. The check honors BOARD selection and the existing first-board fallback for unknown ids; unusable board/status-flow structure fails closed. These configurable checkpoint rules do not change the existing comment/review/closure guards. Queued starts are retained while paused and can be retried after removing the flag. Other transitions keep their existing guards, and the gate remains usable so existing work can reach a safe boundary. General preflight and session-start report the configured state without changing their advisory/bootstrap exit contracts.

This guards bundled workflow selection and start commands. It cannot prevent arbitrary edits, raw git/gh commands, or a flag appearing after a check; there is no shared atomic admission lock. The file is local to this clone, not an OS-wide pause or distributed lock.

## Resume
Resolve `FLAG` again with the command above if resuming in a new shell, then:

```bash
rm -- "$FLAG"
```
Rerun the loop (`/loop /spec-workflow:build-next`) or retry `board.sh flush` for retained operations. The loop re-reads the board so new priorities are considered. Removing the flag does not bypass other guards.

## Why a file
`/clear` wipes conversation context but not repository state. Keep the configured flag path in `.gitignore`; custom paths need their own ignore entry.
