# peer-review

Independent, cross-vendor code review of the current diff via OpenAI's `codex` CLI —
deliberately never Claude reviewing its own diff, since that shares Claude's own blind spots.
Reviewing a diff sends it to OpenAI's cloud via the user-installed `codex` CLI.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/diff-source.sh` | Resolves the diff to review and preflights the `codex` binary. Pure/testable: given repo state + args, prints the diff to stdout, or "nothing to review" + exit 0 on an empty diff (codex is never even checked on that path), or exits 2 with install instructions on stderr if `codex` is missing from `PATH`. |

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

## Tests

```
bash plugins/peer-review/tests/run-tests.sh
```

## Status

Epic 0 (`/peer-review` skill) is in progress. `diff-source.sh` is the diff-resolution +
preflight layer (PRV-001); the `codex exec` invocation, findings parsing, and the
user-facing `/peer-review` skill are follow-up tasks (PRV-002, PRV-003) not yet built.
