# peer-review

Independent, cross-vendor code review of the current diff — you pick which provider reviews it
(OpenAI Codex or Claude today, more later), deliberately never letting the orchestrating model
review its own diff, since that shares its own blind spots. Which model is orchestrating the
session never determines the reviewer; `/peer-review` always asks. Reviewing a diff sends it to
that provider's cloud (for OpenAI Codex: via the user-installed `codex` CLI; for Claude: via the
user-installed `claude` CLI).

## Skills

| Skill | Purpose |
|---|---|
| `peer-review` | The user-facing `/peer-review` command. Asks which provider to review with (`providers.sh` + `AskUserQuestion`), then wires `diff-source.sh` + that provider's model-discovery/review scripts together via `provider-dispatch.sh`, states the cloud disclosure plainly, and renders the result. |

## Provider registry (CDX-053)

`scripts/providers.tsv` is the registry of review providers: one line per provider,
tab-separated `id`, `display_name`, `list_models_script`, `run_script` — the last two are
filenames resolved relative to `scripts/`, left empty when that provider's backend isn't built
yet. It is genuinely data: `providers.sh` and `provider-dispatch.sh` contain zero per-provider
branching, so adding a provider is a one-line registry edit, never a code change. `PEER_REVIEW_PROVIDERS_FILE`
overrides the registry path (used by tests to point at fixture registries).

v1 ships two providers, both fully implemented:

| id | display name | status |
|---|---|---|
| `codex` | OpenAI Codex | `list-models.sh` → `run.sh` |
| `claude` | Claude (Anthropic) | `list-claude-models.sh` → `claude-run.sh` (CDX-054) |

A provider registered without a `run_script` (e.g. a future provider added before its backend
lands) shows as `available: false`, and `provider-dispatch.sh` degrades gracefully for it: a
clear "backend not yet available" message and exit 1, never a crash on a missing script.

By convention, a provider's registry `id` doubles as its CLI binary name on PATH (`codex`,
`claude`) — `diff-source.sh`'s `--preflight-bin` (below) is always given that same id, so no
extra registry column is needed to know which binary to preflight for a given provider.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/providers.sh` | Reads `providers.tsv` and emits `{"providers":[{"id","display_name","available"}, ...]}` on stdout — the catalog `AskUserQuestion` builds its provider-picker options from. `available` is `false` when a provider's `run_script` column is empty. |
| `scripts/provider-dispatch.sh` | `provider-dispatch.sh <provider-id> <list-models\|run> [-- <args>]` — looks up `<provider-id>` in the registry and execs its `list_models_script`/`run_script` (by `<stage>`), forwarding args after `--` verbatim. If that column is empty, prints "`<display name>` backend not yet available." and exits 1 instead of executing a missing file. |
| `scripts/diff-source.sh` | Resolves the diff to review and preflights a provider's CLI binary (`--preflight-bin <name>`, default `codex`). Pure/testable, provider-neutral: given repo state + args, prints the diff to stdout, or "nothing to review" + exit 0 on an empty diff (the preflight binary is never even checked on that path), or exits 2 with install instructions on stderr if that binary is missing from `PATH`. |
| `scripts/peer-review.sh` | Takes a diff-text file, embeds it in a prompt, and invokes `codex exec --sandbox read-only --output-schema schema/peer-review-findings.json`, optionally with `-m <slug>` if `--model <slug>` is given. Renders structured findings under "External review — codex", or falls back to codex's raw stdout verbatim on a schema-parse failure. On a codex auth failure, surfaces codex's stderr verbatim and exits nonzero. |
| `scripts/claude-review.sh` | The Claude-backend sibling of `peer-review.sh` (CDX-054). Takes a diff-text file, embeds it in a prompt, and invokes `claude -p --output-format json --json-schema <inline schema content> --permission-mode plan`, optionally with `--model <slug>`. Parses `.structured_output` from claude's JSON envelope against the shared findings schema. Renders under "External review — Claude", or falls back to claude's raw stdout verbatim on a schema-parse failure. On a claude auth/invocation failure (nonzero exit, or `is_error: true` inside the envelope), surfaces claude's stderr and/or the envelope's own `result` explanation verbatim and exits nonzero. |
| `scripts/list-models.sh` | Discovers codex models available right now (`codex debug models`, filtered to `visibility: list` + `supported_in_api: true`, sorted by `priority` ascending) and emits `{"models": [...], "recommended": "<slug>"}` as JSON. `recommended` is codex's own top-priority model. Exits nonzero (codex missing, discovery failed, or nothing eligible) as a signal to skip model selection entirely, never to block a review. |
| `scripts/list-claude-models.sh` | The Claude-backend sibling of `list-models.sh` (CDX-054), same JSON contract. A small **static** catalog of 4 full model ids sourced from `plugins/spec-workflow/skills/pr-review-model/SKILL.md` — no live discovery call exists for Claude. `recommended` is `claude-sonnet-5[1m]`. Never touches the network or requires `claude` on `PATH`. |
| `scripts/run.sh` | The orchestration layer the `peer-review` skill invokes for the codex provider: translates `[--model <slug>] [--base <ref> \| --staged \| <pr-number>]` (any order) into `diff-source.sh`'s flags and `peer-review.sh --model`, and — only when it produced actual diff text rather than the "nothing to review" sentinel — hands that diff to `peer-review.sh` and prints its output. Propagates both scripts' exit codes and stderr verbatim. |
| `scripts/claude-run.sh` | The Claude-backend sibling of `run.sh` (CDX-054), identical wiring, always passing `--preflight-bin claude` to `diff-source.sh` and handing the diff to `claude-review.sh`. Exists as its own script because `claude-review.sh` mirrors `peer-review.sh`'s diff-text-file argument shape, not `run.sh`'s `--base`/`--staged`/`--pr` flag shape, so it can't be wired directly as `providers.tsv`'s `run_script` the way `peer-review.sh` is for codex. |

### `diff-source.sh` usage

```
diff-source.sh [--preflight-bin <name>] [--base <ref> | --staged | --pr <n>]
```

- No arguments (default): `git diff <mainBranch>...HEAD`, where `<mainBranch>` comes from
  `git config peer-review.mainBranch` when set, else falls back to `main`.
- `--preflight-bin <name>`: which CLI binary to check for once a non-empty diff is found
  (default `codex`, preserving pre-CDX-054 behavior). By convention this is the provider's
  registry `id` (`codex`, `claude`) — callers pass it straight through, no separate lookup.
- `--base <ref>`: `git diff <ref>...HEAD`.
- `--staged`: `git diff --staged`.
- `--pr <n>`: `gh pr diff <n>`.

Exit codes: `0` on a printed diff or an empty-diff "nothing to review"; `2` with an install
message on stderr if the preflight binary is not on `PATH` (only checked when there is a
non-empty diff to review); `1` on a git/gh failure resolving the diff itself.

### `list-models.sh` usage

```
list-models.sh
```

No arguments. Runs `codex debug models`, filters to `visibility: "list"` +
`supported_in_api: true`, sorts by `priority` ascending (lower = higher-ranked), and prints
`{"models": [{"slug", "display_name", "description"}, ...], "recommended": "<slug>"}` on
stdout. `recommended` is always the lowest-`priority` eligible model — no other heuristic.

Exit codes: `0` with the JSON payload on stdout; `1` (nothing meaningful on stdout) if `codex`
is missing from `PATH`, `codex debug models` itself fails, its output isn't valid JSON, or zero
models survive the filter. A caller (the `peer-review` skill) should treat a nonzero exit as
"skip model selection" and invoke `peer-review.sh`/`run.sh` with no `--model` flag — never
block a review on a discovery failure.

### `peer-review.sh` usage

```
peer-review.sh [--label <name>] [--model <slug>] <diff-text-file>
```

Takes the diff as a file argument (e.g. the output of `diff-source.sh`, redirected to a file)
rather than stdin, so it can be embedded verbatim in the prompt without any streaming/buffering
concerns. Every invocation is hardcoded to `codex exec --sandbox read-only --output-schema
schema/peer-review-findings.json [-m <slug>] <prompt>` — no argument or environment variable
accepted by this script can change the sandbox mode (SPEC-PEER-REVIEW.md §6.2); `-m <slug>` is
only ever added by `--model <slug>`, and only after `--sandbox read-only` is already fixed.

- On success with schema-conforming JSON: renders findings (file, line, severity, summary,
  failure scenario) and an overall verdict under the heading `## <label>`.
- On success with non-conforming/malformed JSON (a known `--output-schema` rough edge in the
  `codex` CLI): prints a parse-failure note followed by codex's raw stdout verbatim, under the
  same heading. Still exits `0` — a review happened, just unstructured.
- On codex exiting nonzero (e.g. not logged in): prints codex's stderr verbatim to stderr and
  exits with codex's own exit code. Never attempts to parse stdout, never prompts for
  credentials in-conversation.

`<label>` defaults to `External review — codex` and can be overridden with `--label <name>` or
the `PEER_REVIEW_LABEL` environment variable (`--label` wins if both are given). This script has
no notion of agent identities — it just renders under whatever string the caller passes; the
override exists so another part of the repo (e.g. a resolved `peer-reviewer` agent identity) can
supply a more specific label without `peer-review.sh` depending on that identity system.

`--model <slug>` (optional) passes `-m <slug>` through to `codex exec`, selecting which model
reviews the diff; omitted entirely, codex uses its own default. Typically populated from
`list-models.sh`'s `recommended` field or a human's `AskUserQuestion` pick (see the
`peer-review` skill).

Exit codes: `0` on a completed review (structured or raw-fallback); `2` if the diff-text file
is missing, `--label`/`--model` is given without a value, or `codex` is not on `PATH`; codex's
own nonzero exit code on an auth/invocation failure.

### `list-claude-models.sh` usage

```
list-claude-models.sh
```

No arguments, no network call, no dependency on `claude` being installed. Prints a static
`{"models": [{"slug", "display_name", "description"}, ...], "recommended": "<slug>"}` catalog of
4 full Claude model ids (never a bare alias like `haiku` — see `claude-review.sh`'s own
`--model` findings below), sourced from `plugins/spec-workflow/skills/pr-review-model/SKILL.md`.
`recommended` is always `claude-sonnet-5[1m]`.

Exit codes: `0` always (a static list has no failure mode).

### `claude-review.sh` usage

```
claude-review.sh [--label <name>] [--model <slug>] <diff-text-file>
```

Same argument shape as `peer-review.sh`. Every invocation is hardcoded to `claude -p
--output-format json --json-schema <schema/peer-review-findings.json's contents> [--model
<slug>] --permission-mode plan <prompt>` — no argument or environment variable accepted by this
script can change `--permission-mode` away from `plan` (the read-only equivalent of codex's
`--sandbox read-only`); `--model <slug>` is only ever added by `--model`, and only after
`--permission-mode plan` is already fixed.

Two things differ from codex's `--output-schema`: `--json-schema` takes the schema's **inline
JSON content**, not a file path; and `--output-format json`'s stdout is a larger envelope
(session metadata, cost, usage, ...) with the actual findings nested at `.structured_output`,
not the bare top-level JSON.

- On success with a schema-conforming `.structured_output`: renders findings (file, line,
  severity, summary, failure scenario) and an overall verdict under the heading `## <label>`.
- On success with a non-conforming/missing `.structured_output`: prints a parse-failure note
  followed by claude's raw stdout verbatim, under the same heading. Still exits `0` — a review
  happened, just unstructured.
- On claude exiting nonzero, or an `is_error: true` inside the envelope even if the process
  happened to exit `0`: prints claude's stderr verbatim (when non-empty) and, when present, the
  envelope's own `.result` explanation (the only place an API-level error like an unrecognized
  model id surfaces — real stderr can be empty in that case) to stderr, and exits nonzero. Never
  attempts to parse stdout as findings, never prompts for credentials in-conversation.

`<label>` defaults to `External review — Claude` and can be overridden with `--label <name>` or
the `CLAUDE_REVIEW_LABEL` environment variable (`--label` wins if both are given) — its own env
var, separate from `peer-review.sh`'s `PEER_REVIEW_LABEL`, so the two providers don't share one
label.

`--model <slug>` (optional) passes `--model <slug>` through to `claude -p`, selecting which
model reviews the diff; omitted entirely, claude uses its own default. Manual verification found
this reliably selects the requested model when given a **full model id** (e.g.
`claude-opus-4-8` — confirmed via `modelUsage` in the response envelope); a bare alias (e.g.
`haiku`) was observed to silently fall back to a different model instead, so
`list-claude-models.sh`'s catalog is full ids only.

Exit codes: `0` on a completed review (structured or raw-fallback); `2` if the diff-text file
or schema file is missing, `--label`/`--model` is given without a value, or `claude` is not on
`PATH`; claude's own nonzero exit code (or `1`, if claude exited `0` but its envelope reported
`is_error: true`) on an auth/invocation failure.

## Tests

```
bash plugins/peer-review/tests/run-tests.sh
```

## Status

Epic 0 (`/peer-review` skill) is complete. `diff-source.sh` is the diff-resolution + preflight
layer (PRV-001); `peer-review.sh` is the `codex exec` invocation + findings-parsing layer
(PRV-002); `run.sh` + `skills/peer-review/SKILL.md` are the user-facing `/peer-review` command
(PRV-003) that wires the two together, states the OpenAI-cloud disclosure, and renders the
result. `list-models.sh` + the `--model` flag on `peer-review.sh`/`run.sh` (PRV-004) add
interactive model selection: the skill discovers available models, presents them via
`AskUserQuestion` recommending codex's own top-priority pick, and threads the choice through.
`providers.sh` + `provider-dispatch.sh` (CDX-053) add a provider-selection step *before* model
selection: the skill now always asks which provider reviews the diff, via a data-only registry
extensible without touching any script's branching logic. The Codex path is unchanged and still
reachable end-to-end through the new step. `claude-review.sh` + `list-claude-models.sh` +
`claude-run.sh` (CDX-054) build the Claude provider's backend, flipping `claude` from
`available: false` to `true` in the registry; `diff-source.sh` gained a `--preflight-bin`
argument (generalized rather than forked into a second diff-resolution script) so the diff step
is fully provider-neutral. Both providers are now complete, symmetric implementations.
