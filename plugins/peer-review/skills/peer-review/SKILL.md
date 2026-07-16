---
name: peer-review
description: Independent, cross-vendor code review of the current diff via OpenAI's codex CLI — deliberately never Claude reviewing its own diff. Use for '/peer-review', 'peer review this', 'get a second opinion on this diff', or 'review PR <n>'.
allowed-tools: Bash, AskUserQuestion
---

# Peer review

**Sends your diff to OpenAI's cloud.** Reviewing invokes the user-installed `codex` CLI
(`codex exec --sandbox read-only ...`), which transmits the diff text to OpenAI to generate the
review. Only run this on a diff you're comfortable leaving your machine.

**This skill never writes.** `codex` always runs `--sandbox read-only`; nothing here edits a
file, and the resulting findings are shown, never applied.

## 1. Check whether there's anything to review first

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/diff-source.sh" [--base <ref> | --staged | --pr <pr-number>]
```
- Empty diff: prints "nothing to review" and exits 0 — **stop here.** Show that message and
  exit; do not run `list-models.sh` or `run.sh` below. Model discovery is a `codex` CLI
  invocation too, and the whole point of the empty-diff short-circuit is that `codex` is never
  touched on a no-op review.
- `codex` missing from `PATH`: exits 2 with install instructions — **stop here** and show them
  to the user verbatim; do not proceed to model selection.
- Otherwise: a real diff exists — continue to step 2.

## 2. Pick a model

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/list-models.sh"
```
Prints `{"models":[{"slug","display_name","description"}, ...], "recommended":"<slug>"}` —
every codex model currently available, sorted best-first, with `recommended` naming the top
one.

`AskUserQuestion` accepts 2–4 options, and the model catalog can have more than 4 entries — so:
- **Exactly 1 model**: skip `AskUserQuestion` entirely (nothing to choose between) — use that
  slug directly.
- **2 or more models**: take at most the first 4 (already priority-sorted, so this is always
  the best 4), one `AskUserQuestion` option each (`preview`: `<slug> — <description>`), the
  `recommended` entry first and labeled "(Recommended)". Use the human's pick as `<slug>` below.

**If this script exits nonzero** (codex missing, discovery failed, or nothing came back):
skip this step entirely — proceed straight to step 3 with no `--model` flag. Never block a
review on a discovery hiccup.

## 3. Run the review

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run.sh" [--model <slug>] [--base <ref> | --staged | <pr-number>]
```
Use the same `--base`/`--staged`/`<pr-number>` argument you used in step 1, if any — `run.sh`
re-resolves the diff internally (a second, purely local `git`/`gh` call; it never touches
`codex` for this), so the diff you already confirmed non-empty gets reviewed for real.

- `--model <slug>`: use the model chosen in step 2 (or the discovery fallback: omit this flag
  entirely and let codex use its own default).
- No other arguments (default): reviews `git diff <mainBranch>...HEAD` (`<mainBranch>` from
  `git config peer-review.mainBranch`, else `main`).
- `--base <ref>`: reviews `git diff <ref>...HEAD`.
- `--staged`: reviews staged changes only.
- `<pr-number>` (bare integer): reviews `gh pr diff <pr-number>`.
- Findings render under `## External review — codex` — file, line, severity, a one-sentence
  summary, and the concrete failure scenario, plus an overall verdict. Present these as codex's
  own assessment, labeled as such — never fold them into your own judgment as if you found them.
- A malformed/non-conforming `codex` response falls back to its raw output verbatim under the
  same heading, still exit 0 (a review happened, just unstructured).
- A `codex` failure (e.g. not logged in) surfaces its stderr verbatim and exits nonzero — relay
  that message; don't prompt for credentials yourself.

Run the script and show its full output to the user as-is.
