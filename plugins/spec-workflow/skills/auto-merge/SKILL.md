---
name: auto-merge
description: Checks, enables, or disables auto-merge mode (an agent reviews, approves, and merges PRs instead of a human). Use with 'status' (default), 'on', or 'off' — when the user asks whether auto-merge is active, wants the loop to merge without them, or wants human approval back. With no argument, ask the user what to do.
allowed-tools: Bash, AskUserQuestion
---

# Auto-merge mode — status / on / off

`merge-mode.sh` = `bash "../../scripts/merge-mode.sh"`.

**Invoked with an argument** (`status` / `on` / `off`): run it directly and report the output verbatim.

**Invoked with NO argument**: first run `merge-mode.sh status`, then use AskUserQuestion (single question, header "Auto-merge") with the current state noted in the question. Options — put the CURRENT state's opposite first:

- **Turn ON** — description: "The build loop reviews, approves, and merges its own PRs (independent reviewer agent on a suitable model from `delegation.identities.reviewer.models`, ≤3 fix rounds). You steer via issue comments only." Preview:
  ```
  gate green ─→ In review ─→ reviewer agent (allowed models, e.g. claude-sonnet-5[1m])
                               │ REQUEST_CHANGES ⇄ dev agent (≤3 rounds)
                               ▼ APPROVE
                             gh pr merge ─→ QA  + announce to team
  ```
- **Turn OFF** — description: "Every PR waits at *In review* for a human to approve and merge; the loop picks up after your merge." Preview:
  ```
  gate green ─→ In review ─→ ⏸ waits for YOU (review, approve, merge)
                               ▼ (after your merge, next iteration)
                             fold spec delta ─→ QA
  ```
- **Just show status** — description: "No change; report the current configuration."

Apply the choice with `merge-mode.sh on|off` (or nothing). This edits `methodology.autoMerge` in `.claude/project.yaml` — a **versioned, project-wide** change (every clone obeys it); remind the user to commit it.

After turning **on**:
- Check the status line for `reviewerTokenEnv`: if unset, warn that approvals will be review comments only — branch protection that *requires* an approving review needs a second account's token (`delegation.reviewerTokenEnv`). Offer the `pr-review-model` skill if they also want to pick the reviewer model.
- Run `merge-mode.sh preauth`. If it reports `preauth: ok`, nothing else to do. If it reports `preauth: missing <rules>`, the harness's permission classifier will deny the loop's own `gh pr merge`/`gh pr review` calls every time (a per-PR human round-trip) unless pre-authorized — use AskUserQuestion (header "Pre-authorize merges?") to offer adding the rules now: preview `merge-mode.sh preauth-snippet` verbatim, options **Add these permission rules** (merge the printed block into `.claude/settings.json`'s `permissions.allow`, don't clobber other entries, remind the user to commit it) or **Skip** (each merge will ask first instead — see auto-review.md §3).

Protocol details: `../../skills/build-next/references/auto-review.md`.
