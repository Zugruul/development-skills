---
name: peer-review
description: Independent, cross-vendor code review of the current diff via OpenAI's codex CLI — deliberately never Claude reviewing its own diff. Use for '/peer-review', 'peer review this', 'get a second opinion on this diff', or 'review PR <n>'.
allowed-tools: Bash
---

# Peer review

**Sends your diff to OpenAI's cloud.** Reviewing invokes the user-installed `codex` CLI
(`codex exec --sandbox read-only ...`), which transmits the diff text to OpenAI to generate the
review. Only run this on a diff you're comfortable leaving your machine.

**This skill never writes.** `codex` always runs `--sandbox read-only`; nothing here edits a
file, and the resulting findings are shown, never applied.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run.sh" [--base <ref> | --staged | <pr-number>]
```

- No arguments (default): reviews `git diff <mainBranch>...HEAD` (`<mainBranch>` from `git
  config peer-review.mainBranch`, else `main`).
- `--base <ref>`: reviews `git diff <ref>...HEAD`.
- `--staged`: reviews staged changes only.
- `<pr-number>` (bare integer): reviews `gh pr diff <pr-number>`.
- Empty diff: prints "nothing to review" and exits 0 — `codex` is never invoked.
- `codex` missing from `PATH`: exits 2 with install instructions; show them to the user verbatim.
- Findings render under `## External review — codex` — file, line, severity, a one-sentence
  summary, and the concrete failure scenario, plus an overall verdict. Present these as codex's
  own assessment, labeled as such — never fold them into your own judgment as if you found them.
- A malformed/non-conforming `codex` response falls back to its raw output verbatim under the
  same heading, still exit 0 (a review happened, just unstructured).
- A `codex` failure (e.g. not logged in) surfaces its stderr verbatim and exits nonzero — relay
  that message; don't prompt for credentials yourself.

Run the script and show its full output to the user as-is.
