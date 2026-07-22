---
name: setup-assistant
description: Scaffolds a bare-brain assistant repo (marker, project.yaml assistant section, brain dirs, persona AGENTS.md, gitignores) and edits its settings (provider/model/capabilities/machine-local default). Use for '/setup-assistant', 'turn this repo into an assistant', 'set up jarvis', or flipping an assistant's provider/model/capability/default.
---

# Set up (or edit) a persistent assistant repo

Goal: after this skill, the target repo is an **assistant repo** (SPEC-ASSISTANT.md
§4/§6.4) — a `.claude/.neural-network` marker, a `.claude/project.yaml` with a valid
`assistant:` section, empty brain dirs at `.claude/identities/assistant/brain/notes/`, a
persona `AGENTS.md` at the repo root, and `.claude/assistant/` (session/traces/tasks/
artifacts) gitignored. The assistant repo carries **no engine code** (§6.7) — this skill
never copies any; the engine lives in this plugin's neural-view server.

Scripts decide, you obey: every mutation below goes through
`scripts/setup-assistant.sh` (a thin bash wrapper) → `scripts/assistant/setup.py` (the
logic: nested-dict scaffolding, surgical YAML edits via `config.py`, §6.5 validation via
`scripts/assistant/config.py`'s `validate_assistant`). Never hand-edit the `assistant:`
section or `AGENTS.md`'s generated block directly — always go through the script so
re-runs stay idempotent and invalid flips get rejected instead of silently landing.

## Scaffold (create or re-run)

```bash
bash "../../scripts/setup-assistant.sh" [--root <path>] scaffold [--name NAME] [--provider openai|claude] [--model MODEL]
```

`--root` defaults to the git toplevel (else cwd). Idempotent and safe to re-run at any
time — it never overwrites a value that's already there:
- Creates `.claude/.neural-network` if absent (leaves an existing one untouched).
- Inserts every **missing** leaf of the default `assistant:` section into
  `.claude/project.yaml` (creating the file if absent); any key you already set —
  including an explicit `false`/`0`/empty-string value — is left alone. Unrelated
  top-level keys and comments elsewhere in the file are never touched.
- Creates `.claude/identities/assistant/brain/notes/` (empty; `brain.py mint` fills it
  once the assistant starts learning).
- Writes (or updates in place) a persona `AGENTS.md` at the repo root. It always contains
  a GENERATED, marker-delimited "enabled skills" section (§11.9 — codex has no native
  skills dir, so this is how a codex-backed assistant sees its roster); re-running
  regenerates ONLY that block's contents (from the current `assistant.capabilities.*
  .enabled: true` set) — any prose you add around it survives byte-for-byte.
- Syncs `.claude/assistant/` (and the rest of the plugin's `ignore`-policy paths) into
  the target repo's `.gitignore` via `gitignore-sync.sh`'s managed block.

Defaults if you don't override them: `names: [assistant]`, `llm: {provider: claude,
model: claude-sonnet-5}`, `capabilities.claude-code.enabled: true` (matches the
`claude` provider), `capabilities.codex.enabled: false`, both observability backends on
with SPEC-ASSISTANT.md §10.3's defaults (30 days / 500MB retention).

## Settings editor (flip provider/model/capability, set the machine-local default)

Every mutating verb below snapshots `project.yaml`, applies the one-key edit, then
re-validates the WHOLE `assistant:` section with `validate_assistant`
(SPEC-ASSISTANT.md §6.5) — an invalid result (e.g. flipping the provider to `openai`
while `capabilities.codex.enabled` is still `false`) is **rejected and reverted**, file
byte-identical to before, with the specific error printed. Never leaves a broken config.

```bash
bash "../../scripts/setup-assistant.sh" [--root <path>] set-provider <openai|claude>
bash "../../scripts/setup-assistant.sh" [--root <path>] set-model <model-string>   # passed verbatim to the adapter, §6.5
bash "../../scripts/setup-assistant.sh" [--root <path>] enable-capability <name>
bash "../../scripts/setup-assistant.sh" [--root <path>] disable-capability <name>
bash "../../scripts/setup-assistant.sh" [--root <path>] validate                  # prints VALID or the error list
```

Enabling a provider's required capability (openai↔codex, claude↔claude-code) BEFORE
flipping the provider avoids the rejection round-trip.

### Machine-local default (§6.3 touchpoint — AST-007 owns the full store)

```bash
bash "../../scripts/setup-assistant.sh" [--root <path>] set-default <name>
```

Writes the chosen assistant name into neural-view's own local-state dir
(`.claude/neural-view/assistant-default`, already gitignored) — **never** into a tracked
file, per §6.3 ("the machine-local default assistant lives in neural-view's LOCAL
state"). This is a bare setter only: ambiguity resolution and the "no default among
discovered assistants" error listing are AST-007's scope, not this skill's.

## After setup

The scaffolded `assistant:` section always validates (`setup-assistant.sh validate` ->
`VALID`) by construction. Installing capabilities beyond the two base ones
(`codex`/`claude-code`), discovery/selection UX, and preflight (bin resolution + auth
checks, §6.6) are separate concerns — see AST-006 and later assistant tasks.
