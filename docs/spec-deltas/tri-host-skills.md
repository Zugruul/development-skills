---
task: 'tri-host-skills'
spec: cdx
sections: ["§1", "§2"]
---

## §1/§2 — THIRD HOST: OpenCode

The dual-host contract (Claude Code + Codex) extends to OpenCode. OpenCode discovers Claude-format skills from `.opencode/skills/<name>/SKILL.md` (and auto-loads `~/.claude/skills` / `~/.agents/skills`); no marketplace surface exists, so the skills-directory install IS the OpenCode path. `install-skills.sh {claude|opencode|codex|all}` at the repo root symlinks every `plugins/*/skills/*` into a target project's per-client skill dirs (collision → `<plugin>-<skill>` fallback name; a real pre-existing dir is never overwritten; `DEV_SKILLS_PROJECT_ROOT` targets another project). The portable SKILL.md contract (G3) is now enforced by `tests/section-host-portability.sh`: frontmatter `name` == directory, lowercase-hyphenated, non-empty `description` — for every skill in every plugin. Codex marketplace coverage extended: `peer-review` gains `.codex-plugin/plugin.json` and an `.agents/plugins/marketplace.json` entry (it predated neither host's wiring). Verified live: `opencode debug skill` run inside an installed project lists every skill.
