---
name: pr-review-model
description: Shows or changes which models the autonomous PR reviewer may run on (delegation.identities.reviewer.models, used when auto-merge is on). Use when the user wants a stronger/cheaper/larger-context PR reviewer or asks which model reviews PRs. With no argument, ask the user to pick from options.
allowed-tools: Bash, AskUserQuestion
---

# PR reviewer models — show / set

`merge-mode.sh` = `bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-mode.sh"`.

The reviewer identity's `models` are the ALLOWED set the orchestrator picks from per review — a suitable model for the review size (larger context for big diffs, cheaper for small ones), never "always the most powerful". The same reviewer identity serves both the two-pass implement-task review and the auto-merge PR gate. Full model ids only (never shorthand like `sonnet`).

**Invoked with a model argument** (one id or a comma-separated allowed set): `merge-mode.sh model <ids>` and report the output verbatim.

**Invoked with NO argument**: run `merge-mode.sh status` for the current allowed set, then AskUserQuestion (single question, header "PR reviewer", current value noted in the question). Options — no previews (a plain preference):

- **claude-sonnet-5[1m] (Recommended)** — description: "Sonnet 5 with the 1M-token context window: holds the full diff + spec + design doc in one reviewer; the plugin default."
- **claude-sonnet-5** — description: "Standard-context Sonnet: cheaper; fine for small, focused PRs."
- **claude-opus-4-8** — description: "Strongest reviewer judgment; higher cost per round. Standard context — very large diffs may need chunking."
- **claude-haiku-4-5** — description: "Cheapest/fastest; only for mechanical changes — not recommended as a merge gatekeeper."

The user can type any other full model id via Other, or a comma-separated set to allow several (the orchestrator then picks per review). Apply with `merge-mode.sh model <choice>` — this replaces `delegation.identities.reviewer.models` in `.claude/project.yaml`, a versioned project-wide change; remind the user to commit it. If `methodology.autoMerge` is off, note the setting still governs the two-pass review but the PR-gate use only kicks in once auto-merge is on (the `auto-merge` skill toggles it).
