---
name: peer-review
description: Independent, cross-vendor code review of the current diff — you pick which provider (OpenAI Codex or Claude today, more later) reviews it, deliberately never the orchestrating model reviewing its own diff. Use for '/peer-review', 'peer review this', 'get a second opinion on this diff', or 'review PR <n>'.
allowed-tools: Bash, AskUserQuestion
---

# Peer review

**Sends your diff to the chosen provider's cloud.** Reviewing shells out to that provider's
review script (for OpenAI Codex: the user-installed `codex` CLI, `codex exec --sandbox
read-only ...`; for Claude: the user-installed `claude` CLI, `claude -p --permission-mode
plan ...`), which transmits the diff text to generate the review. Only run this on a diff you're
comfortable leaving your machine.

**This skill never writes.** Every provider backend runs read-only; nothing here edits a file,
and the resulting findings are shown, never applied.

**Never auto-detected.** Which model is orchestrating this session doesn't determine the
reviewer — always ask. The whole point of `/peer-review` is a genuinely independent second
opinion, which only holds if the reviewer is a different vendor than whoever's orchestrating;
that's on you (or the human) to know and pick correctly, not something to infer from the
environment.

## 1. Pick a provider

```bash
bash "../../scripts/providers.sh"
```
Prints `{"providers":[{"id","display_name","available"}, ...]}` — every registered provider
(`plugins/peer-review/scripts/providers.tsv`; CDX-053, SPEC-PEER-REVIEW.md §6.12). This is a
pure registry read, no CLI call, so it costs nothing to ask first — before even checking
whether there's a diff to review.

`AskUserQuestion` accepts 2–4 options, and the provider registry can grow past 4 entries — so,
same pattern as the model picker in step 3 below:
- **Exactly 1 provider**: skip `AskUserQuestion` entirely (nothing to choose between) — use
  that id directly.
- **2 or more providers**: take at most the first 4 (registry order), one `AskUserQuestion`
  option each (`preview`: `<display_name>`). List every registered provider regardless of its
  `available` value — an unavailable one is still a valid, informative choice (see below).
  Use the human's pick as `<provider_id>` for the rest of this flow.

**If the chosen provider's `available` is `false`** (registered but its backend isn't built
yet — every v1 provider, `codex` and `claude`, is available as of CDX-054; this only matters
for a future provider added before its backend lands): **stop here.** Show a message like
"`<display_name>` backend not yet available." and exit; do not run `diff-source.sh` or any
model-discovery/review script. (`provider-dispatch.sh` below would also refuse and say the same
thing, but there's no reason to even resolve the diff for a provider that can't review it yet.)

**If this script exits nonzero** (registry missing or empty — should not happen with the
shipped registry): stop and show the error; there is nothing to fall back to.

## 2. Check whether there's anything to review first

```bash
bash "../../scripts/diff-source.sh" --preflight-bin <provider_id> [--base <ref> | --staged | --pr <pr-number>]
```
`--preflight-bin <provider_id>` tells `diff-source.sh` which CLI to check for once a real diff
exists — by convention a provider's registry `id` (from step 1) IS its CLI binary name on PATH
(`codex`, `claude`), so pass it straight through with no separate lookup. This makes
diff-resolution itself fully provider-neutral: the diff-resolution logic never branches on which
provider was picked, only which binary it preflights (CDX-054).
- Empty diff: prints "nothing to review" and exits 0 — **stop here.** Show that message and
  exit; do not run model discovery or the review script below. Model discovery is itself an
  external-CLI invocation, and the whole point of the empty-diff short-circuit is that the
  provider's CLI is never touched on a no-op review.
- Provider CLI missing from `PATH` (e.g. `codex` for the Codex provider, `claude` for the Claude
  provider): exits 2 with install instructions — **stop here** and show them to the user
  verbatim; do not proceed to model selection.
- Otherwise: a real diff exists — continue to step 3.

## 3. Pick a model

```bash
bash "../../scripts/provider-dispatch.sh" <provider_id> list-models
```
Dispatches to the chosen provider's model-discovery script (for `codex`: `list-models.sh`).
Prints `{"models":[{"slug","display_name","description"}, ...], "recommended":"<slug>"}` —
every model currently available from that provider, sorted best-first, with `recommended`
naming the top one.

`AskUserQuestion` accepts 2–4 options, and the model catalog can have more than 4 entries — so:
- **Exactly 1 model**: skip `AskUserQuestion` entirely (nothing to choose between) — use that
  slug directly.
- **2 or more models**: take at most the first 4 (already priority-sorted, so this is always
  the best 4), one `AskUserQuestion` option each (`preview`: `<slug> — <description>`), the
  `recommended` entry first and labeled "(Recommended)". Use the human's pick as `<slug>` below.

**If this script exits nonzero** (provider CLI missing, discovery failed, or nothing came
back): skip this step entirely — proceed straight to step 4 with no `--model` flag. Never
block a review on a discovery hiccup.

## 4. Run the review

```bash
bash "../../scripts/provider-dispatch.sh" <provider_id> run -- [--model <slug>] [--base <ref> | --staged | <pr-number>]
```
Dispatches to the chosen provider's review script (for `codex`: `run.sh`; for `claude`:
`claude-run.sh`). Use the same `--base`/`--staged`/`<pr-number>` argument you used in step 2, if
any — the review script re-resolves the diff internally (a second, purely local `git`/`gh` call
that always preflights that same provider's own CLI, per step 2's `--preflight-bin`; it never
touches the provider's CLI for the diff resolution itself), so the diff you already confirmed
non-empty gets reviewed for real.

- `--model <slug>`: use the model chosen in step 3 (or the discovery fallback: omit this flag
  entirely and let the provider use its own default).
- No other arguments (default): reviews `git diff <mainBranch>...HEAD` (`<mainBranch>` from
  `git config peer-review.mainBranch`, else `main`).
- `--base <ref>`: reviews `git diff <ref>...HEAD`.
- `--staged`: reviews staged changes only.
- `<pr-number>` (bare integer): reviews `gh pr diff <pr-number>`.
- Findings render under `## External review — codex` or `## External review — Claude`
  (whichever provider was chosen) — file, line, severity, a one-sentence summary, and the
  concrete failure scenario, plus an overall verdict. Present these as that provider's own
  assessment, labeled as such — never fold them into your own judgment as if you found them.
- A malformed/non-conforming response from the provider's CLI falls back to its raw output
  verbatim under the same heading, still exit 0 (a review happened, just unstructured).
- A provider CLI failure (e.g. not logged in) surfaces its stderr verbatim and exits nonzero —
  relay that message; don't prompt for credentials yourself.

Run the script and show its full output to the user as-is.
