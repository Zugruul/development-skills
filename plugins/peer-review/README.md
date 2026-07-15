# peer-review

Independent, cross-vendor code review of the current diff via OpenAI's `codex` CLI —
deliberately never Claude reviewing its own diff, since that shares Claude's own blind spots.
Reviewing a diff sends it to OpenAI's cloud via the user-installed `codex` CLI.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/diff-source.sh` | Resolves the diff to review and preflights the `codex` binary. Pure/testable: given repo state + args, prints the diff to stdout, or "nothing to review" + exit 0 on an empty diff (codex is never even checked on that path), or exits 2 with install instructions on stderr if `codex` is missing from `PATH`. |
| `scripts/peer-review.sh` | Takes a diff-text file, embeds it in a prompt, and invokes `codex exec --sandbox read-only --output-schema schema/peer-review-findings.json`. Renders structured findings under "External review — codex", or falls back to codex's raw stdout verbatim on a schema-parse failure. On a codex auth failure, surfaces codex's stderr verbatim and exits nonzero. |

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

### `peer-review.sh` usage

```
peer-review.sh [--label <name>] <diff-text-file>
```

Takes the diff as a file argument (e.g. the output of `diff-source.sh`, redirected to a file)
rather than stdin, so it can be embedded verbatim in the prompt without any streaming/buffering
concerns. Every invocation is hardcoded to `codex exec --sandbox read-only --output-schema
schema/peer-review-findings.json <prompt>` — no argument or environment variable accepted by
this script can change the sandbox mode (SPEC-PEER-REVIEW.md §6.2).

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

Exit codes: `0` on a completed review (structured or raw-fallback); `2` if the diff-text file
is missing, `--label` is given without a value, or `codex` is not on `PATH`; codex's own
nonzero exit code on an auth/invocation failure.

## Tests

```
bash plugins/peer-review/tests/run-tests.sh
```

## Status

Epic 0 (`/peer-review` skill) is in progress. `diff-source.sh` is the diff-resolution +
preflight layer (PRV-001); `peer-review.sh` is the `codex exec` invocation + findings-parsing
layer (PRV-002). The user-facing `/peer-review` skill that wires the two together (argument
parsing, the OpenAI-cloud disclosure) is a follow-up task (PRV-003) not yet built.
