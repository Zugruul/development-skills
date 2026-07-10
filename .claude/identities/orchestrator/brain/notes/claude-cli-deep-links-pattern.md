---
tags: [deep-links, claude-cli, neural-view, tooling]
paths: ["plugins/spec-workflow/templates/neural-view.html", "plugins/spec-workflow/scripts/neural-view.py"]
strength: 1
source: "neural-view Talk panel (event-sorc/monorepo session)"
graduated: false
created: 2026-07-10
---

Claude Code deep links (`claude-cli://open`, docs: code.claude.com/en/deep-links)
launch a NEW terminal session locally, pre-filled but never auto-sent — the
user still presses Enter. Build one as:

  claude-cli://open?cwd=<abs-path-percent-encoded>&q=<prompt-percent-encoded>

- `cwd` (absolute local path) beats `repo` (owner/name slug) whenever you
  already know the path — `repo` only resolves if `claude` was run there
  before and is unreliable across machines/worktrees. `cwd` takes precedence
  if both given.
- Percent-encode with `encodeURIComponent` per param (not URLSearchParams —
  form-encoding turns spaces into `+`, which a `claude-cli://` handler may
  not form-decode back). Use `%0A`/`\n` for multi-line prompts. `q` caps at
  5000 chars.
- To give the new session a short name instead of an auto-generated one,
  prefix the prompt with a `/rename <name>` line (e.g. `/rename event-sorc
  build-loop`) before the actual task text, joined by `\n`. `/rename` is a
  real built-in slash command (Claude Code v2.1.205+); unverified whether it
  still fires correctly when it's the first line of a longer multi-line
  prompt vs. the entire input — worth confirming once someone actually
  clicks a generated link.
- Registration is per-machine and automatic on first `claude` run; a link
  does nothing on a machine that has never run `claude` interactively.
- GitHub-rendered markdown strips `claude-cli://` links to plain text — only
  matters for links embedded in README/issues/PRs, not the neural-view HUD.

Implemented in neural-view's "Talk" panel (left BRAINS bar → ✎ talk): picks
a repo, composes `/rename <project> <slug>` + prompt, shows the literal
composed text before sending so you can catch a mis-parsed rename. `cwd` per
repo comes from GET /graph's new `roots` field (server already knows each
repo's absolute root — no need to resolve `repo=owner/name`).
