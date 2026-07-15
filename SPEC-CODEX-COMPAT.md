# Dual-host compatibility (Claude Code + Codex) — development spec (v1)

## §1 Overview

`development-skills` publishes two Claude Code plugins (`spec-workflow`, `scaffold-project`) that
were built for, and currently only install on, Claude Code. Codex is now a second real host with
its own plugin manifest, marketplace, skill-validation, and lifecycle surface. This spec governs
making both plugins install and run reliably on both hosts from **one shared engine** — scripts,
schemas, templates, and skill instructions are not forked into two maintained copies; only the
smallest necessary host-specific adapters differ. It consolidates the investigation recorded in
`docs/handoffs/CODEX-COMPATIBILITY-HANDOFF.md` (2026-07-15, local/gitignored) and a follow-up
architecture consultation with Codex itself, both folded in as source material and decisions below.

## §2 Goals

- **G1** — Both plugins install, and Codex discovers every skill, through a documented, validated
  Codex marketplace/plugin flow, without touching Claude's existing install path (§6).
- **G2** — No skill script depends on `CLAUDE_PLUGIN_ROOT` being present; a shared, host-neutral
  resolution mechanism works from a source checkout, an installed/cached plugin copy, and a
  separate consumer repository, including paths containing spaces (§6).
- **G3** — Skill frontmatter and prose are portable: every `SKILL.md` validates against Codex's
  local linter and expresses interactive/delegation behavior in capability language rather than
  hardcoded Claude tool names, with host-specific detail isolated into small adapter docs (§7).
- **G4** — Model/delegation configuration accepts an optional Codex mapping without requiring any
  existing consumer repo's `.claude/project.yaml` to change (§8).
- **G5** — Every safety invariant of the build workflow (truthful board state, human-comment
  steering, TDD, gate-before-review/merge, independent dev/reviewer roles, brain isolation,
  mandatory retro/feedback, checkpoint behavior, lane isolation/WIP limits, bounded auto-merge)
  holds on Codex even where Claude's `SessionStart`/`PreToolUse` hooks have no equivalent (§9).
- **G6** — CI validates both manifest formats and all skills on every push/PR; documentation
  answers install/update/invoke for both hosts plainly, with a per-skill compatibility matrix (§10).
- **G7** — Newly landed skills (starting with the concurrently-developed **compute-registry** and
  **peer-review** initiatives) get checked against this spec's requirements as a standing task, not
  a one-time pass, so compatibility doesn't silently regress as the product grows (§11).

## §3 Non-goals (v1)

- Migrating `.claude/` state to a neutral directory (e.g. `.spec-workflow/`) — `.claude/` stays the
  canonical path for both hosts this release.
- Moving board/GitHub operations behind MCP — local deterministic scripts (`board.sh`, `gate.sh`,
  etc.) remain bundled scripts; MCP is noted as the right long-term standard for structured
  external operations but is out of scope here.
- Exact feature parity for session-metadata-dependent features (`ui-options` Claude Code resume
  links via `CLAUDE_CODE_SESSION_ID`; `neural-view` live-session discovery under `~/.claude/jobs`)
  — these degrade gracefully under Codex (omit cleanly, never fabricate) rather than reaching
  parity.
- Restructuring `delegation.identities.*.models` into a host-keyed map for existing consumer repos
  — the Codex mapping is additive-only.
- Adopting the third-party `skills-ref` validator in CI (not installed/verified locally; a
  documented follow-up, not a requirement).
- Forking any skill, script, schema, or template into separate Claude/Codex copies.

## §4 Glossary

- **Host** — the agent runtime installing/running a plugin: Claude Code or Codex.
- **Host adapter** — the smallest isolated piece of a skill (a `references/host-<name>.md` doc, or
  a manifest file) that differs per host; everything else is shared.
- **Plugin root** — the directory containing a plugin's `scripts/`, `skills/`, `schemas/`, etc.,
  regardless of host or install location.
- **Capability language** — skill prose that describes what must happen ("ask the user through the
  host's structured-input facility") instead of naming an exact host tool (`AskUserQuestion`).
- **Portable skill contract** — the [Agent Skills specification](https://agentskills.io/specification)
  subset (`name` + `description` frontmatter, relative resource references) both hosts consume.
- **Enforcement parity** — a safety invariant holding under Codex by deterministic script/preflight
  means, even where Claude enforces it via a lifecycle hook Codex doesn't have.

## §5 Architecture

Additive host metadata around the existing shared core:

```text
development-skills/
├── .claude-plugin/marketplace.json        (unchanged)
├── .agents/plugins/marketplace.json       (new: Codex marketplace)
├── AGENTS.md                              (new: canonical agent instructions)
├── CLAUDE.md                              (new: one-line pointer to AGENTS.md)
├── plugins/
│   ├── spec-workflow/
│   │   ├── .claude-plugin/plugin.json     (unchanged)
│   │   ├── .codex-plugin/plugin.json      (new)
│   │   ├── scripts/lib/plugin-root.sh     (new: shared resolver, sourced by every script)
│   │   ├── scripts/lib/plugin_root.py     (new: Python equivalent)
│   │   ├── hooks/, schemas/, scripts/, skills/, templates/, tests/   (unchanged locations)
│   │   └── skills/<name>/references/{host-claude.md,host-codex.md}  (new, where needed)
│   └── scaffold-project/  (same additive shape: .codex-plugin/plugin.json only — no hooks/scripts
│       of its own to touch)
└── .github/workflows/ci.yml               (extended: Codex validation jobs alongside Claude's)
```

Ownership boundary (per the Codex architecture consultation): Agent Skills spec → shared workflow
prose; shell/Python/JSON Schema → shared deterministic engine (unchanged); Claude manifest/hooks →
Claude adapter; Codex manifest → Codex adapter. Plugin-root resolution is a precedence chain, not a
single variable:

```text
SPEC_WORKFLOW_PLUGIN_ROOT (explicit override)
        ↓
CLAUDE_PLUGIN_ROOT (Claude fast path, unchanged)
        ↓
script-relative discovery (BASH_SOURCE[0] / __file__ based, walks up to the plugin root)
        ↓
clear, actionable error
```

The plugin root is recognized by a fixed sentinel, not a fixed depth: the nearest ancestor
directory (starting from the resolver script's own physical location) containing either
`.claude-plugin/plugin.json` or `.codex-plugin/plugin.json`. If an explicit override
(`SPEC_WORKFLOW_PLUGIN_ROOT` or `CLAUDE_PLUGIN_ROOT`) is set but does not point to a directory
containing one of those sentinels, resolution SHALL fail loudly with an actionable error rather
than silently falling through to script-relative discovery — a stale/misconfigured override must
never be masked.

## §6 Codex packaging & plugin-root resolution (E0)

- **§6.1** WHEN Codex's plugin validator (`~/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py`
  or equivalent) is run against either plugin THE SYSTEM SHALL pass, via a `.codex-plugin/plugin.json`
  that includes real `name`, `version`, `description`, `author.name`, and required `interface` fields,
  with no unsupported fields (e.g. no inline `hooks` object).
- **§6.2** THE SYSTEM SHALL provide a Codex marketplace manifest (`.agents/plugins/marketplace.json`)
  listing both plugins with `policy.installation`, `policy.authentication`, and `category` set per
  plugin entry, without modifying or replacing `.claude-plugin/marketplace.json`.
- **§6.3** WHEN any shared script needs its plugin root THE SYSTEM SHALL resolve it via the §5
  precedence chain (`scripts/lib/plugin-root.sh` / `plugin_root.py`), never via the current working
  directory, and THE SYSTEM SHALL resolve correctly when the plugin path contains spaces.
- **§6.4** IF an explicit override (`SPEC_WORKFLOW_PLUGIN_ROOT` or `CLAUDE_PLUGIN_ROOT`) is set but
  does not point to a directory containing a `.claude-plugin/plugin.json` or
  `.codex-plugin/plugin.json` sentinel THEN THE SYSTEM SHALL fail with an actionable error, never
  silently fall through to script-relative discovery.
- **§6.5** THE SYSTEM SHALL provide a canonical `AGENTS.md` at the repository root consumed by
  Codex, with root `CLAUDE.md` reduced to a one-line pointer to it (§15 OQ-2 governs whether either
  is hand-maintained or generated).
- **§6.6** WHEN Codex's skill linter (`quick_validate.py`) is run against every `SKILL.md` THE
  SYSTEM SHALL report zero failures — the five angle-bracket descriptions (`ask-brain`,
  `ask-identity`, `changelog-generate`, `create-inbound`, `find-task`) SHALL be rewritten to remain
  equally precise about triggering without literal `<`/`>` characters.
- **§6.7** WHERE a `SKILL.md`'s prose references a companion script or reference file THE SYSTEM
  SHALL use a path relative to that skill's own root, never an absolute `${CLAUDE_PLUGIN_ROOT}/...`
  interpolation in the visible instructions.

## §7 Portable interaction & invocation semantics (E1)

- **§7.1** WHERE a skill needs structured user input THE SYSTEM SHALL describe it in capability
  language ("ask through the host's structured-input facility when available; otherwise ask one
  concise direct question") in the shared `SKILL.md`, with any exact tool call isolated to a
  `references/host-claude.md` adapter.
- **§7.2** WHERE a skill has a no-write research/design phase (e.g. `craft-spec`'s Phase 1) THE
  SYSTEM SHALL express it as an explicit behavioral constraint ("no file writes during discovery")
  rather than solely as a call to a Claude-specific plan-mode tool.
- **§7.3** WHERE a skill delegates bounded work to a subagent THE SYSTEM SHALL describe the
  delegation in capability language ("delegate to a fresh implementation agent when the host
  supports delegation") with exact spawn parameters (tool name, `subagent_type`) isolated to a host
  adapter.
- **§7.4** THE SYSTEM SHALL NOT reference an `ARGUMENTS:`-style variable in shared skill prose as if
  it were guaranteed to be populated; any such prose SHALL treat skill arguments as the remainder of
  the user's request text.
- **§7.5** WHEN a skill's pre-start step is currently expressed as Claude command-substitution
  prose (e.g. `!`-prefixed shell) THE SYSTEM SHALL convert it into an explicit first workflow step
  usable by either host.
- **§7.6** WHEN `CLAUDE_CODE_SESSION_ID` is unset THE SYSTEM SHALL render `ui-options` decision
  pages with the resume link omitted, never fabricated. WHEN Claude job metadata under
  `~/.claude/jobs` is absent THE SYSTEM SHALL render `neural-view` without live-session data rather
  than erroring, and SHALL label session counts by host once both are surfaced.

## §8 Host-aware delegation & model resolution (E2)

- **§8.1** THE SYSTEM SHALL accept an optional `models.codex.capability` field
  (`fast`|`balanced`|`deep-review`|`large-context`) alongside each identity's existing Claude
  `models` list in `delegation.identities.<role>`, read only by the Codex adapter; omitting it
  SHALL NOT change Claude behavior or require any existing consumer repo to update its config.
- **§8.2** WHEN `implement-task`/`build-next` brief a dev or reviewer agent under Codex THE SYSTEM
  SHALL select a model via the resolved identity's `models.codex.capability` (falling back to a
  host-chosen default if unset) and SHALL NOT reference a Claude-only model id (e.g.
  `claude-sonnet-5[1m]`) in a Codex-run brief.
- **§8.3** THE SYSTEM SHALL preserve, under both hosts: `covers`-glob identity routing, one-agent-
  per-task, independent developer/reviewer roles, role-prefixed agent naming
  (`dev-<task-id>`/`reviewer-<task-id>`), and per-commit author/committer attribution.

## §9 Build-loop & enforcement parity (E3)

- **§9.1** WHERE Claude's `PreToolUse` hook is unavailable (Codex has no equivalent lifecycle
  event) THE SYSTEM SHALL still block a status move to *In review* without a gate pass recorded
  for the current tree fingerprint, via a deterministic preflight check invoked as an explicit
  workflow step rather than an intercepted tool call.
- **§9.2** THE SYSTEM SHALL preserve, under both hosts, without weakening: truthful board-status
  transitions, human-issue-comment steering read before implementation, red-first TDD, independent
  two-pass review, identity-brain isolation (orchestrator-mediated only), mandatory retro/feedback
  at PR close, checkpoint behavior (no new task starts while paused), isolated concurrency lanes
  respecting `methodology.maxInProgress`, and bounded auto-merge review rounds.
- **§9.3** THE SYSTEM SHALL keep Claude's `SessionStart`/`PreToolUse` hooks (`hooks/hooks.json`)
  unchanged and functioning as defense in depth; correctness SHALL NOT depend exclusively on them
  firing.

## §10 CI, documentation & compatibility matrix (E4)

- **§10.1** THE SYSTEM SHALL run, in CI, both the existing Claude manifest validation and a new
  Codex plugin/skill validation job, on every push to `main` and every pull request.
- **§10.2** THE SYSTEM SHALL document, in the root and plugin READMEs: install and update
  instructions for both hosts (verified against the actual installed CLIs, not merely written),
  how to invoke a skill on each, required permissions/authentication, how model choices are
  configured per host (§8.1), why shared state stays under `.claude/`, which features have full
  parity, and which are intentionally degraded under which host.
- **§10.3** THE SYSTEM SHALL maintain a compatibility matrix (one row per skill or meaningful skill
  group) stating Claude support, Codex support, and any known limitation.

## §11 Compatibility sweep for new/in-flight work (E5)

Note: §10.1's CI job already covers the automatable portion of this sweep (§6.6's skill-linter
pass) for any new `SKILL.md` going forward. This epic's scope is specifically the non-CI-able
review — §7-§9 (interaction semantics, delegation config, enforcement parity) — which requires
human/agent judgment, not a lint pass.

- **§11.1** WHEN the **compute-registry** work (tracked from issue #166) reaches a mergeable skill
  THE SYSTEM SHALL be reviewed against §7-§9 of this spec and the result (compliant, or specific
  gaps) SHALL be recorded as new row(s) in the §10.3 compatibility matrix.
- **§11.2** WHEN the **peer-review** work (tracked from issues #167/#168) reaches a mergeable skill
  THE SYSTEM SHALL be reviewed against §7-§9 of this spec and the result recorded the same way as
  §11.1.
- **§11.3** THE SYSTEM SHALL treat this review as a standing checklist item for any future new
  skill or plugin, not a one-time pass limited to §11.1-§11.2 — any gap found (at any time) SHALL
  be filed as its own follow-up board task rather than silently deferred or fixed inline.

## §12 Invariants

- One shared script/schema/template/test engine; no skill, script, or schema is forked into
  separate per-host copies.
- `name` and `description` are the only frontmatter fields either host is assumed to enforce;
  `allowed-tools` remains a Claude-only enhancement, never the cross-host security boundary.
- Plugin-root resolution never reads the current working directory.
- Critical safety enforcement (gate-before-review, checkpoint, truthful board state) is
  implemented in deterministic scripts/preflight checks, with hooks as defense in depth only —
  never the sole enforcement mechanism.
- Existing `.claude/project.yaml` consumers on schemaVersion 2 remain valid with zero required
  changes; any new field is additive and optional.
- Claude Code's existing installation, manifests, hooks, and slash-command invocation remain
  unchanged and functioning throughout.
- No unrelated pre-existing working-tree changes are reverted, overwritten, staged, or committed by
  this work.
- Degraded features are documented explicitly; none are silently faked or hidden.

## §13 Non-functional

- Codex skill/plugin validation and the existing Claude manifest validation both complete within
  the existing CI time budget (no material CI slowdown from adding a second host's checks).
- Plugin-root resolution adds no detectable latency to script startup (a few `dirname`/`pwd -P`
  calls; no network, no subprocess spawning beyond what already exists).

## §14 Testing strategy

Merge gate (unchanged core + additions): `plugins/*/tests/run-tests.sh`, `shellcheck -x` over all
shell, `claude plugin validate` for Claude manifests — plus new coverage: Codex plugin/skill
validation for both plugins, plugin-root resolution tested from (a) the source checkout, (b) a
simulated installed/cached copy, (c) a separate temporary consumer repository, (d) a path
containing spaces, and a regression test proving a status move to *In review* is blocked without a
recorded gate pass even when hook-based interception is simulated as absent. Additional required
coverage: legacy Claude-only `delegation.identities.*.models` configuration (no `models.codex`
field) normalizes and falls back to a safe host-chosen default rather than erroring; `ui-options`
and `neural-view` degrade per §7.6 with the relevant environment/metadata absent; and, as the E0
exit condition, a real Codex install of a plugin from the configured marketplace with a
script-backed skill (`changelog-generate` once merged, or another read-only script-backed skill)
run successfully from a separate consumer repository — not merely simulated path resolution.

## §15 Open questions

| id | question | owner | default if unanswered | status |
|---|---|---|---|---|
| OQ-1 | Exact Codex marketplace `category` values per plugin? | dev agent (E0 task) | `Productivity` for both, matching the plugin-creator sample | open |
| OQ-2 | Should `AGENTS.md`/`CLAUDE.md` be hand-maintained or generated from one source in CI? | user | hand-maintained `AGENTS.md` canonical + one-line `CLAUDE.md` pointer (no CI generation step this release) | open |
| OQ-3 | Priority/story-point values for the E0-E5 backlog tasks? | user (or default if unanswered) | P0 for E0 (nothing else is Codex-installable without it), P1 for E1-E4, P2 for the E5 sweep | **decided**: defaults as stated, to be applied when `docs/BACKLOG-CODEX-COMPAT.md` is drafted |
