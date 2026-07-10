---
tags: [deep-links, claude-cli, neural-view, tooling]
paths: ["plugins/spec-workflow/templates/neural-view.html", "plugins/spec-workflow/scripts/neural-view.py"]
strength: 2
source: "neural-view Talk panel, confirmed via user manual testing"
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
- CONFIRMED (manual test, not just theory): the harness only recognizes a
  slash command on the FIRST line of a multi-line pre-filled prompt. Putting
  `/rename <name>` first and the real instruction second silently eats the
  instruction — only the rename fires. Put the real command/instruction
  FIRST, and `/rename <name>` LAST on its own trailing line — the session
  still picks it up and renames itself after acting on the first line, but
  now the actual task isn't lost. `/rename` is a real built-in slash command
  (Claude Code v2.1.205+).
- Registration is per-machine and automatic on first `claude` run; a link
  does nothing on a machine that has never run `claude` interactively.
- GitHub-rendered markdown strips `claude-cli://` links to plain text — only
  matters for links embedded in README/issues/PRs, not the neural-view HUD.

Implemented in neural-view's "Talk" panel (left BRAINS bar → per-repo-header
✎ for "ask the whole brain", per-identity-row ✎ for one role): picks a
repo + optional identity, composes `/ask-identity <role> <question>` (or
`/ask-brain <question>`) FIRST, `/rename <project> <slug>` LAST, shows the
literal composed text before sending. `cwd` per repo comes from GET
/graph's `roots` field (server already knows each repo's absolute root —
no need to resolve `repo=owner/name`). ask-identity/ask-brain are read-only
brain consults (see those skills), not build-loop iterations.
