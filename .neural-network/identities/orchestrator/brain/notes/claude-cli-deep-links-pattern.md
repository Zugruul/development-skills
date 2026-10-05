---
tags: [deep-links, claude-cli, neural-view, tooling, plugins]
paths: ["plugins/spec-workflow/templates/neural-view.html", "plugins/spec-workflow/scripts/neural-view.py", "plugins/spec-workflow/skills/ask-identity", "plugins/spec-workflow/skills/ask-brain"]
strength: 3
source: "neural-view Talk panel, confirmed via user manual testing (Unknown command: /ask-identity)"
graduated: true
created: 2026-07-10
---

Claude Code deep links (`claude-cli://open`, docs: code.claude.com/en/deep-links)
launch a NEW terminal session locally, pre-filled but never auto-sent — the
user still presses Enter. Build one as:

  claude-cli://open?cwd=<abs-path-percent-encoded>&q=<prompt-percent-encoded>

- `cwd` (absolute local path) beats `repo` (owner/name slug) whenever you
  already know the path. `cwd` takes precedence if both given.
- Percent-encode with `encodeURIComponent` per param, not URLSearchParams.
  Use `%0A`/`\n` for multi-line prompts. `q` caps at 5000 chars.
- CONFIRMED: the harness only recognizes a slash command on the FIRST line
  of a multi-line pre-filled prompt. Put the real command/instruction FIRST
  and `/rename <name>` LAST on its own trailing line.
- CONFIRMED (2nd bug, same feature): a plugin skill is ALWAYS namespaced as
  `/plugin-name:skill-name`, never bare — `/ask-identity` 404s as "Unknown
  command" even when the skill file exists and the plugin is current. Must
  match the plugin's `.claude-plugin/plugin.json` `name` field (here:
  `spec-workflow`, so `/spec-workflow:ask-identity`). Easy to miss because
  writing/testing a SKILL.md never surfaces the prefix — it only bites once
  something else (a deep link, a doc, a script) hardcodes the bare name.
- A THIRD gotcha, deployment not code: installed plugins are pinned to a
  specific version/commit in `~/.claude/plugins/installed_plugins.json` —
  `installedAt`/`lastUpdated`/`gitCommitSha` frozen at install time. Editing
  or merging skill files upstream does nothing for an already-installed repo
  until the user explicitly updates that plugin; "reload skills/plugins"
  alone does not re-fetch from the marketplace source, it just re-reads
  what's already cached locally.
- Registration is per-machine and automatic on first `claude` run; a link
  does nothing on a machine that has never run `claude` interactively.
- GitHub-rendered markdown strips `claude-cli://` links to plain text.

Implemented in neural-view's "Talk" panel (left BRAINS bar → per-repo-header
✎ for "ask the whole brain", per-identity-row ✎ for one role): picks a
repo + optional identity, composes `/spec-workflow:ask-identity <role>
<question>` (or `/spec-workflow:ask-brain <question>`) FIRST, `/rename
<project> <slug>` LAST. `cwd` per repo comes from GET /graph's `roots`
field. ask-identity/ask-brain are read-only brain consults (see those
skills), not build-loop iterations.
