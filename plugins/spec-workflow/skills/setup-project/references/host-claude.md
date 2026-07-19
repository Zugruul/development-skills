# Claude Code adapter — setup-project

This skill's shared `SKILL.md` describes its three structured-input moments
in capability language ("ask through the host's structured-input
facility"). On Claude Code, that facility is the `AskUserQuestion` tool.
Other hosts follow the shared body's capability-language instructions
directly and can ignore this file.

## Phase 3 — Board
Call `AskUserQuestion` (header "Board") with two options:
- **Use an existing Project (Recommended when any exist)** — offer the
  discovered Projects as options (title + number).
- **Create a new Project** — the only path that runs `gh project create`.

## Phase 4 — Merging
Call `AskUserQuestion` (header "Merging") with two options: a human
approves/merges every PR (default), or the loop reviews and merges
autonomously. If the user picks autonomous, follow up with a second
`AskUserQuestion` call for `methodology.mergeMethod`, offering **squash
(Recommended)**, **merge**, and **rebase** as options — this is a
sub-question of the Merging ask, not a separate top-level moment.

## Phase 4 — Feedback
Call `AskUserQuestion` (header "Feedback") with two options: **Enable
(Recommended)** — preview the `methodology.feedback: true` YAML block being
written — or **Don't enable**.
