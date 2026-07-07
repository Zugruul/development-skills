---
name: agent-identities
description: Shows or configures the git author identities agent roles (dev/reviewer/orchestrator) commit with — name/email templates resolved per-clone ({name}, {local}+suffix@{domain}). Use when the user asks who agent commits are attributed to, wants to rename an agent, use their own plus-addressed email, or turn attribution off. With no argument, show current resolution and ask what to change.
allowed-tools: Bash, AskUserQuestion, Edit, Read
---

# Agent identities — show / set / disable

`identity.sh` = `bash "${CLAUDE_PLUGIN_ROOT}/scripts/identity.sh"`. Each role lives in `delegation.identities.<role>` of `.claude/project.yaml` (versioned — commit changes) as ONE identity or an ARRAY of them. An identity carries `name`/`email` templates (placeholders resolve per-clone: `{name}` ← `git config user.name`, `{local}`/`{domain}` ← `git config user.email`), an optional `models` allowed set (FULL ids only, e.g. `claude-sonnet-5[1m]`), and optional `covers` path globs (monorepo routing — `identity.sh <role> <path>` returns the covering identity). Defaults are ON: `Dev Agent - {name}` / `{local}+dev_agent@{domain}`, models dev `[claude-sonnet-5]`, reviewer `[claude-sonnet-5, claude-sonnet-5[1m]]` (and orchestrator name/email, no models).

**"show" or a specific ask** — run `identity.sh` (all roles) or `identity.sh <role>` and report the resolved name/email verbatim; a WARN means `git config user.name/email` is unset on this clone.

**On-behalf commits** — when one process records another role's work, `identity.sh on-behalf <author-role> [--committer <role>] [--co <role>]...` prints a ready commit recipe (committer `-c` flags + `--author=` + Co-authored-by trailers) so author/committer/contributors are all credited. When to use it: `${CLAUDE_PLUGIN_ROOT}/skills/build-next/references/auto-review.md` §Commit identities.

**Invoked with NO argument**: run `identity.sh`, show the current resolution, then AskUserQuestion (single question, header "Identities"):

- **Keep defaults** — description: "Per-person plus-addressed attribution, zero config (what you have now unless overridden)."
- **Customize a role** — description: "Change a role's name/email template, its allowed `models`, or (monorepo) split it into an array of per-package identities with `covers` globs." Follow up by asking which role and the change (free text via Other is fine), then edit `delegation.identities.<role>` in `.claude/project.yaml`. For `models`, use full ids only.
- **Disable one role** — description: "Set that role to null — its commits are authored as the human." Preview (YAML):
  ```
  delegation:
      identities:
          dev: null
  → dev-agent commits: Leonardo Marcelino Vieira <leonardo.marcelino@outlook.com>
  → reviewer commits:  Reviewer Agent - Leonardo Marcelino Vieira
                       <leonardo.marcelino+reviewer_agent@outlook.com>
  ```
- **Disable all** — description: "Set `delegation.identities: false` — every agent commit is authored as the human." Preview (YAML):
  ```
  delegation:
      identities: false
  → all commits: Leonardo Marcelino Vieira <leonardo.marcelino@outlook.com>
  ```

Apply config edits directly to `.claude/project.yaml` (keep 4-space indent), re-run `identity.sh` to confirm the resolution, show it to the user, and remind them the change is project-wide and should be committed. Note when relevant: plus-addressed mail (`local+tag@domain`) delivers to the owner's inbox on Outlook/Gmail/Fastmail; GitHub links an avatar only if the resolved email belongs to a GitHub account.
