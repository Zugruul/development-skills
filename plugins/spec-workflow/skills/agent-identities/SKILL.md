---
name: agent-identities
description: Shows or configures the git author identities agent roles (dev/reviewer/orchestrator) commit with — name/email templates resolved per-clone ({name}, {local}+suffix@{domain}). Use when the user asks who agent commits are attributed to, wants to rename an agent, use their own plus-addressed email, or turn attribution off. With no argument, show current resolution and ask what to change.
allowed-tools: Bash, AskUserQuestion, Edit, Read
---

# Agent identities — show / set / disable

`identity.sh` = `bash "${CLAUDE_PLUGIN_ROOT}/scripts/identity.sh"`. Templates live in `delegation.identities.<role>` of `.claude/project.json` (versioned — commit changes); placeholders resolve per-clone: `{name}` ← `git config user.name`, `{local}`/`{domain}` ← `git config user.email`. Defaults are ON: `Dev Agent - {name}` / `{local}+dev_agent@{domain}` (and reviewer/orchestrator equivalents).

**"show" or a specific ask** — run `identity.sh` (all roles) or `identity.sh <role>` and report the resolved name/email verbatim; a WARN means `git config user.name/email` is unset on this clone.

**Invoked with NO argument**: run `identity.sh`, show the current resolution, then AskUserQuestion (single question, header "Identities"):

- **Keep defaults** — description: "Per-person plus-addressed attribution, zero config (what you have now unless overridden)."
- **Customize a role** — description: "Change a role's name/email template — e.g. a different suffix, a '{name} · reviewer' style name, or a literal shared bot account." Follow up by asking which role and the new template (free text via Other is fine), then edit `delegation.identities.<role>` in `.claude/project.json`.
- **Disable one role** — description: "Set that role to null — its commits are authored as the human." Preview:
  ```
  "delegation": { "identities": { "dev": null } }
  → dev-agent commits: Leonardo Marcelino Vieira <leonardo.marcelino@outlook.com>
  → reviewer commits:  Reviewer Agent - Leonardo Marcelino Vieira
                       <leonardo.marcelino+reviewer_agent@outlook.com>
  ```
- **Disable all** — description: "Set `delegation.identities: false` — every agent commit is authored as the human." Preview:
  ```
  "delegation": { "identities": false }
  → all commits: Leonardo Marcelino Vieira <leonardo.marcelino@outlook.com>
  ```

Apply config edits directly to `.claude/project.json` (keep 4-space indent), re-run `identity.sh` to confirm the resolution, show it to the user, and remind them the change is project-wide and should be committed. Note when relevant: plus-addressed mail (`local+tag@domain`) delivers to the owner's inbox on Outlook/Gmail/Fastmail; GitHub links an avatar only if the resolved email belongs to a GitHub account.
