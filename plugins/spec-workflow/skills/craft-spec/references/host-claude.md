# Claude Code adapter — craft-spec

This skill's shared `SKILL.md` describes its two interview loops in
capability language ("ask through the host's structured-input facility").
On Claude Code, that facility is the `AskUserQuestion` tool. This file is
the Claude-specific mechanics; other hosts follow the shared body's
capability-language instruction directly and can ignore this file.

## Phase 1 — discovery interview
Call `AskUserQuestion` in rounds of at most 4 questions per call, using the
question bank in `references/spec-guide.md`. Offer concrete options per
question (the user can always pick "Other" for free text); state your own
inferences as a pre-selected default to confirm rather than an open
question. Stop calling `AskUserQuestion` once new answers stop changing the
design — 2-4 rounds is typical.

## Phase 4 — review sign-off
Call `AskUserQuestion` to resolve each open question left after the
self-review checklist, and again to get explicit sign-off on scope and
epic order. Re-call it after every revision until the user's answer is an
unambiguous approval — this is an iterate-until-approved loop, not a
single ask.
