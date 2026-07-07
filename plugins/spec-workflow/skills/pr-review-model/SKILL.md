---
name: pr-review-model
description: Shows or changes which model the autonomous PR reviewer uses (delegation.prReviewModel, used when auto-merge is on). Use when the user wants a stronger/cheaper/larger-context PR reviewer or asks which model reviews PRs. With no argument, ask the user to pick from options.
allowed-tools: Bash, AskUserQuestion
---

# PR reviewer model — show / set

`merge-mode.sh` = `bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-mode.sh"`.

**Invoked with a model argument**: `merge-mode.sh model <model>` and report the output verbatim.

**Invoked with NO argument**: run `merge-mode.sh status` for the current value, then AskUserQuestion (single question, header "PR reviewer", current value noted in the question). Options — no previews (a plain preference):

- **claude-sonnet-5[1m] (Recommended)** — description: "Sonnet 5 with the 1M-token context window: holds the full diff + spec + design doc in one reviewer; the plugin default."
- **opus** — description: "Strongest reviewer judgment; higher cost per round. Standard context — very large diffs may need chunking."
- **sonnet** — description: "Standard-context Sonnet: cheaper; fine for small, focused PRs."
- **haiku** — description: "Cheapest/fastest; only for mechanical changes — not recommended as a merge gatekeeper."

The user can type any other model id via Other (pass it through verbatim). Apply with `merge-mode.sh model <choice>` — this edits `delegation.prReviewModel` in `.claude/project.json`, a versioned project-wide change; remind the user to commit it. If `methodology.autoMerge` is off, note the setting only takes effect once auto-merge is on (the `auto-merge` skill toggles it).
