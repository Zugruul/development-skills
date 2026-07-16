# peer-review

Independent, cross-vendor code review of the current diff via OpenAI's `codex` CLI —
deliberately never Claude reviewing its own diff, since that shares Claude's own blind spots.
Reviewing a diff sends it to OpenAI's cloud via the user-installed `codex` CLI.

## Skills

| Skill | Purpose |
|---|---|
| `peer-review` | The user-facing `/peer-review` command. Wires `diff-source.sh` + `peer-review.sh` together via `run.sh`, states the OpenAI-cloud disclosure plainly, and renders the result. |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/diff-source.sh` | Resolves the diff to review and preflights the `codex` binary. Pure/testable: given repo state + args, prints the diff to stdout, or "nothing to review" + exit 0 on an empty diff (codex is never even checked on that path), or exits 2 with install instructions on stderr if `codex` is missing from `PATH`. |
| `scripts/peer-review.sh` | Takes a diff-text file, embeds it in a prompt, and invokes `codex exec --sandbox read-only --output-schema schema/peer-review-findings.json`, optionally with `-m <slug>` if `--model <slug>` is given. Renders structured findings under "External review — codex", or falls back to codex's raw stdout verbatim on a schema-parse failure. On a codex auth failure, surfaces codex's stderr verbatim and exits nonzero. |
| `scripts/list-models.sh` | Discovers codex models available right now (`codex debug models`, filtered to `visibility: list` + `supported_in_api: true`, sorted by `priority` ascending) and emits `{"models": [...], "recommended": "<slug>"}` as JSON. `recommended` is codex's own top-priority model. Exits nonzero (codex missing, discovery failed, or nothing eligible) as a signal to skip model selection entirely, never to block a review. |
| `scripts/run.sh` | The orchestration layer the `peer-review` skill invokes: translates `[--model <slug>] [--base <ref> \| --staged \| <pr-number>]` (any order) into `diff-source.sh`'s flags and `peer-review.sh --model`, and — only when it produced actual diff text rather than the "nothing to review" sentinel — hands that diff to `peer-review.sh` and prints its output. Propagates both scripts' exit codes and stderr verbatim. |

### `diff-source.sh` usage

```
diff-source.sh [--base <ref> | --staged | --pr <n>]
```

- No arguments (default): `git diff <mainBranch>...HEAD`, where `<mainBranch>` comes from
  `git config peer-review.mainBranch` when set, else falls back to `main`.
- `--base <ref>`: `git diff <ref>...HEAD`.
- `--staged`: `git diff --staged`.
- `--pr <n>`: `gh pr diff <n>`.

Exit codes: `0` on a printed diff or an empty-diff "nothing to review"; `2` with an install
message on stderr if `codex` is not on `PATH` (only checked when there is a non-empty diff to
review); `1` on a git/gh failure resolving the diff itself.

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
