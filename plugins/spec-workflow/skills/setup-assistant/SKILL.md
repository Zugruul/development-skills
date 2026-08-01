---
name: setup-assistant
description: Scaffolds a bare-brain assistant repo — marker file, project.yaml assistant section, brain directories, persona AGENTS.md, gitignores — interviews the human to compose a real persona, and edits settings (provider/model/capabilities/persona/machine-local default). Use for '/setup-assistant', 'turn this repo into an assistant', 'set up jarvis', or flipping an assistant's provider/model/capability/persona/default.
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

## Persona interview (scaffold step 2)

A fresh `scaffold` (or any repo whose `assistant.systemPrompt` still equals the bare
default — it starts with `You are <name>, the local assistant for this repository's
zettel brain`) only has a one-line generic prompt. Immediately after a fresh scaffold —
or any time you notice that default is still in place — interview the human about THIS
project's assistant, using the host's structured-input facility (`AskUserQuestion` on
Claude Code), covering:

1. **What the assistant will do for this project / its domain** — what is it actually
   for (this repo's subject matter, the kind of work it'll be asked about)?
2. **Tone / voice** — terse and dry, warm and chatty, formal, something else?
3. **Boundaries** — what must it NEVER do or decide alone (merge a PR, touch prod,
   spend money, etc.)?
4. **2–3 example tasks** it should excel at — concrete, not generic.

Then **compose** a quality persona from the answers:
- State identity ONCE — don't restate it every turn (the default's style rule).
- Keep `systemPrompt` tight: the runtime clips the persona component (systemPrompt plus
  the names line) to 3200 chars by default at compose time (`turns.py`'s persona budget
  is 800 TOKENS, converted at 4 chars/token), so put the fuller prose in `AGENTS.md`'s
  persona block instead of cramming everything into `systemPrompt`.
- Preserve the default's style rules (no self-reintroduction, brevity — replies are
  often spoken aloud via TTS) unless the human explicitly asks for something else.
- Concrete domain vocabulary and boundaries beat generic "you are a helpful assistant"
  filler — the whole point is a persona specific to THIS project.

Write the composed text to a temp file first (never shell-quote a multi-line prompt
inline), then apply it:

```bash
bash "../../scripts/setup-assistant.sh" [--root <path>] set-persona --file <path-to-composed-persona.txt>
# or, piped from stdin:
your-compose-step | bash "../../scripts/setup-assistant.sh" [--root <path>] set-persona --file -
```

This writes the persona into BOTH `assistant.systemPrompt` (via the same
snapshot/validate/revert-on-invalid pattern every other settings verb below uses — an
empty/whitespace-only persona is rejected, file left byte-identical) and a new
marker-delimited persona block in the root `AGENTS.md` (regenerated in place; any
hand-written prose you add around it survives byte-for-byte, same discipline as the
generated skills/output-contract blocks; the block replaces the bare scaffold intro line
in place rather than sitting below it). If the composed text is over the runtime clip
(3200 chars by default) it is still accepted and stored in FULL — never silently
truncated — but a warning names the actual clip so you know the excess only lives in
`AGENTS.md`, not in what the engine actually sends the model. A persona line that happens
to match one of AGENTS.md's own reserved marker comments is rejected outright (it would
corrupt the generated-block scanner).

**Re-running `set-persona` later is the supported way to evolve the persona** — no
separate "edit" verb; compose new text and apply it the same way.

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
