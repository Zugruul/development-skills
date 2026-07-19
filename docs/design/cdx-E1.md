# Design — cdx/E1: Portable interaction & invocation semantics
Grounded in: SPEC-CODEX-COMPAT.md §7.1-§7.3, §4 Glossary (Capability language, Host adapter), §5 Architecture

## CDX-010 — capability-language rewrite: the 9 `AskUserQuestion` skills (§7.1)

**§7.1 exact text**: "WHERE a skill needs structured user input THE SYSTEM SHALL describe it in capability language ('ask through the host's structured-input facility when available; otherwise ask one concise direct question') in the shared `SKILL.md`, with any exact tool call isolated to a `references/host-claude.md` adapter."

**Glossary definitions** (§4): **Capability language** — "skill prose that describes what must happen ('ask the user through the host's structured-input facility') instead of naming an exact host tool (`AskUserQuestion`)." **Host adapter** — "the smallest isolated piece of a skill (a `references/host-<name>.md` doc...) that differs per host; everything else is shared."

**Canonical phrase** (this task establishes it — first host-adapter work in the repo, no prior precedent to match): replace "AskUserQuestion" in shared prose with **"the host's structured-input facility"**, matching §7.1's own worked example verbatim. Where the current text says "AskUserQuestion (header 'X')" write "the host's structured-input facility (header 'X')". Where it says "call AskUserQuestion" write "invoke the host's structured-input facility" or "ask through the host's structured-input facility" (vary naturally per sentence, don't robotically find-replace).

**Inventory — exactly 9 `SKILL.md` files** (confirmed via `grep -rl AskUserQuestion plugins/spec-workflow/skills/*/SKILL.md`): `setup-project`, `auto-merge`, `build-next`, `pr-review-model`, `agent-identities`, `concurrency`, `craft-spec`, `ask-identity`, `create-inbound`.

**`allowed-tools` frontmatter is OUT OF SCOPE** — per §12's own invariant ("`name` and `description` are the only frontmatter fields either host is assumed to enforce; `allowed-tools` remains a Claude-only enhancement, never the cross-host security boundary"), the frontmatter `allowed-tools: ... AskUserQuestion ...` lines (present in `auto-merge`, `pr-review-model`, `agent-identities`, `concurrency`, `ask-identity`) are left UNCHANGED. Only prose BODIES are rewritten, matching the acceptance criterion's own wording ("shared `SKILL.md` bodies").

**Adapter strategy — simple (inline) vs complex (dedicated file)**, per the task's own "only where the skill's complexity warrants a separate file; simple cases may inline a one-line Claude note":
- **Complex → dedicated `references/host-claude.md`**: `craft-spec` (an interview LOOP — "rounds of at most 4 questions using the question bank," plus a separate sign-off loop — enough structure to warrant its own file) and `setup-project` (THREE distinct structured-input moments across different phases — new/existing project choice, merge policy with a follow-up sub-question, feedback opt-in — multi-decision-point complexity).
- **Simple → inline one-line Claude note**, appended near the (now capability-language) mention: `auto-merge`, `build-next`, `pr-review-model`, `agent-identities`, `concurrency`, `ask-identity`, `create-inbound`. Inline note pattern: `(On Claude Code, this is the AskUserQuestion tool.)` — placed once per skill, near its first capability-language mention, not repeated at every occurrence within the same file.

**Constraints to preserve verbatim** (acceptance criterion: "constraints... are preserved"), per skill — from the research inventory:
- `craft-spec`: max 4 questions per interview round; the sign-off loop iterates until approved.
- `auto-merge`: "put the CURRENT state's opposite first" (option-ordering rule, state-dependent) for its first ask; a second, simpler 2-option ask for pre-authorization.
- `ask-identity`: exactly 3 options, exact wording ("It is" / "It is not" / "I'm unsure").
- `create-inbound`: stop/continue semantics — "If the human is absent or does not answer, do NOT create."
- `pr-review-model`: 4 options + a free-text "Other" affordance, no previews.
- `agent-identities`, `concurrency`: 3 options each, current-value-noted framing.
- `setup-project`: 3 distinct asks (new/existing project; merge policy + sub-question; feedback opt-in with a Recommended default).
- `build-next`: the session-consent-gate single-ask (§0 of auto-review.md) AND the separate NEGATIVE operating rule ("does not use [the structured-input facility] unless a hard permission denial or an explicit instruction requires human direction") — both must survive the rewrite, the second one is not a request-input call at all, just a behavioral constraint mentioning the facility by (now capability) name.

**Existing test needing rewrite** (not just addition): `plugins/spec-workflow/tests/section-skill-contracts.sh:71` currently asserts the LITERAL string `"does not use AskUserQuestion unless a hard permission denial..."` is present in build-next's body — this exact assertion will start failing once that sentence is rewritten in capability language, by design (that's the whole point of the acceptance criterion: "none of the 9 shared SKILL.md bodies require a tool literally named AskUserQuestion to function"). Update this existing check's expected string to match the new capability-language wording — do not just delete the check, keep the same operating-rule constraint covered.

**New tests**: for the 2 complex skills, assert their new `references/host-claude.md` file exists and contains the preserved constraint (e.g. craft-spec's "4 questions" number, the exact tool name `AskUserQuestion` — the adapter file is exactly where that literal name is SUPPOSED to still live). For all 9 skills' `SKILL.md` bodies, assert the literal string `AskUserQuestion` is ABSENT (this is the core acceptance criterion, directly testable) while the capability-language phrase IS present.

## CDX-011 — plan-mode / no-write phase as capability language (§7.2)

**§7.2 exact text**: "WHERE a skill has a no-write research/design phase (e.g. `craft-spec`'s Phase 1) THE SYSTEM SHALL express it as an explicit behavioral constraint ('no file writes during discovery') rather than solely as a call to a Claude-specific plan-mode tool."

**Inventory — only `craft-spec/SKILL.md` mentions `EnterPlanMode`/`ExitPlanMode`** (confirmed: `grep -rl "EnterPlanMode\|ExitPlanMode" plugins/spec-workflow/skills/` returns exactly one file). Two occurrences:
- Line 17 (Phase 1 — discover): "Enter plan mode (EnterPlanMode) if available: this phase is research + design, no file writes yet." — the behavioral constraint ("no file writes yet") is ALREADY stated in the same sentence, just conjoined with the Claude-specific tool call rather than led by it.
- Line 29 (Phase 4 — review sign-off): "...via plan approval (ExitPlanMode) if in plan mode, else directly." — this is the exit/approval action, already largely capability-language (the actual sign-off ask already uses "the host's structured-input facility" per CDX-010's rewrite) with only the `(ExitPlanMode)` parenthetical needing adapter treatment.

**Rewrite plan**: lead each sentence with the BEHAVIORAL CONSTRAINT ("no file writes during discovery/design" for line 17; "present a summary and get sign-off" for line 29), with the Claude-specific tool name moved into the EXISTING `references/host-claude.md` adapter (already created by CDX-010 for this same skill's structured-input mechanics — this task extends that same file with a new "Phase 1 / no-write phase" section, and a note on Phase 4's approval mechanics) rather than inline in the shared body, since this skill already has a dedicated adapter file and craft-spec was independently classified "complex" enough for one in CDX-010.

**Constraint to preserve**: "no file writes during discovery/design" (Phase 1's substance) must survive as an explicit, host-agnostic, independently-testable behavioral statement — not just implied by a tool-call instruction. craft-spec's actual Claude behavior (entering/exiting plan mode) must be unchanged — the adapter still instructs a Claude-side agent to call `EnterPlanMode`/`ExitPlanMode`.

**New tests**: assert `craft-spec/SKILL.md`'s body states the "no file writes" constraint in prose not gated on a tool name (a `check` for a host-agnostic phrase like "no file writes" or "no-write phase"); assert the body does NOT require the literal strings `EnterPlanMode`/`ExitPlanMode` to understand the instruction (mirror CDX-010's absent-from-body pattern); assert `references/host-claude.md` contains both literal tool names and documents when to call them.

## CDX-012 — delegation-spawn capability language (§7.3)

**§7.3 exact text**: "WHERE a skill delegates bounded work to a subagent THE SYSTEM SHALL describe the delegation in capability language ('delegate to a fresh implementation agent when the host supports delegation') with exact spawn parameters (tool name, `subagent_type`) isolated to a host adapter."

**Inventory — exactly 2 sites repo-wide** (confirmed via `grep -rn "Agent tool\|subagent_type" plugins/spec-workflow/`, the full plugin tree, not just `skills/*/SKILL.md`):
- `implement-task/SKILL.md:25` — dev-agent spawn instruction: "Spawn with the Agent tool, `subagent_type: general-purpose`, `model: <...>`, and `name: dev-<task-id>` (...)".
- `build-next/references/auto-review.md:65` — reviewer-agent spawn instruction: "spawn ONE reviewer agent — Agent tool, `subagent_type: general-purpose`, `model:` a suitable id from the reviewer identity's allowed set (...)".

No other skill or reference file names `Agent tool` or `subagent_type`. `build-next/SKILL.md`'s own body (step 2: "spawn a dev subagent...") already uses host-neutral phrasing with no literal tool name — it needs no rewrite; the acceptance criterion's mention of "build-next" refers to its reference doc, `auto-review.md`, where the actual spawn-parameter prose lives.

**Out of scope (feeds CDX-02x instead)**: model SELECTION (`identity.sh dev`'s allowed-model set, choosing a suitable id) is unchanged — §7.3 only governs the SPAWN mechanism's tool/parameter naming, not which model is picked. `name: dev-<task-id>` / `name: pr-reviewer-<pr-number>` naming conventions are host-neutral already (just a label) and are preserved verbatim.

**Adapter strategy — both sites are simple (exactly one literal mention each)**, matching CDX-010's own classification rule ("simple cases may inline a one-line Claude note"): no new `references/host-claude.md` file for either skill. Instead, inline a one-line Claude note immediately after the (now capability-language) spawn sentence, mirroring CDX-010's exact inline-note pattern:
- `implement-task/SKILL.md:25` — replace "Spawn with the Agent tool, `subagent_type: general-purpose`, `model: <the id you chose from that allowed set>`, and `name: dev-<task-id>` (...)" with "Delegate to a fresh implementation agent when the host supports delegation, with `model: <the id you chose from that allowed set>` and `name: dev-<task-id>` (...)" followed by "(On Claude Code, this is the Agent tool with `subagent_type: general-purpose`.)".
- `build-next/references/auto-review.md:65` — replace "spawn ONE reviewer agent — Agent tool, `subagent_type: general-purpose`, `model:` a suitable id from the reviewer identity's allowed set (...)" with "delegate to ONE fresh reviewer agent when the host supports delegation, with `model:` a suitable id from the reviewer identity's allowed set (...)" followed by the same inline Claude note.

**Constraints to preserve verbatim**: `implement-task`'s naming rule (`dev-<task-id>`, role-prefix first, re-brief appends a letter, never a bare counter) and its "one agent = one task" rule; `auto-review.md`'s naming rule (`pr-reviewer-<pr-number>`) and "keep this SAME agent for every round... via SendMessage" continuity rule (`SendMessage` itself is out of scope for this task — §7.3 governs the SPAWN action only, not the follow-up dialogue mechanism; a future task may extend capability language to it).

**New tests**: extend `section-capability-language.sh` with a CDX-012 block mirroring the existing simple-skill pattern — for each of the 2 files, assert the capability-language phrase ("delegate to a fresh implementation agent when the host supports delegation" / "delegate to ONE fresh reviewer agent when the host supports delegation") is present, `Agent tool`/`subagent_type` appears exactly once each (the inline Claude note), the inline-note text itself is present, and every preserved constraint (naming rules, one-agent-per-task, SendMessage continuity) survives verbatim.

## Out of scope for CDX-010
CDX-011 (plan-mode/no-write phase capability language, §7.2) and CDX-012 (delegation-spawn capability language, §7.3) — separate, later tasks in this same epic, sharing the "capability language" pattern this task establishes but touching different Claude-specific mechanisms (`EnterPlanMode`/`ExitPlanMode`, `Agent`/`subagent_type`).
`allowed-tools` frontmatter changes — explicitly out of scope per §12's invariant, see above.
`build-next/references/auto-review.md` and `craft-spec/references/spec-guide.md` — these ALSO mention `AskUserQuestion` but are supporting reference docs, not the "9 shared SKILL.md bodies" the acceptance criterion names; leave them as-is for this task (a future task may extend the pattern to reference docs, but the backlog item's own acceptance text scopes to the 9 SKILL.md files specifically).
