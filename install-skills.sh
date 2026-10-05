#!/usr/bin/env bash
# install-skills.sh {claude|opencode|codex|all} — client-neutral skill install.
#
# Symlinks every plugins/*/skills/<name>/ (anything carrying a SKILL.md) into
# the target project's per-client skill directory, so all three hosts discover
# the SAME canonical files:
#
#   claude   -> <project>/.claude/skills/      (alternative to the marketplace;
#               use one or the other, not both, to avoid duplicate entries)
#   opencode -> <project>/.opencode/skills/
#   codex    -> <project>/.agents/skills/      (alternative to the .agents
#               marketplace, same either-or rule as claude)
#
# Symlinks, never copies — edits to the canonical skills are live immediately.
# A real (non-symlink) pre-existing skill directory is NEVER overwritten: a
# name collision with a different source first retries as <plugin>-<skill>,
# then refuses loudly. Set DEV_SKILLS_PROJECT_ROOT to install into a project
# other than the current directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${DEV_SKILLS_PROJECT_ROOT:-${LUMA_SKILLS_PROJECT_ROOT:-$PWD}}"

usage() {
  printf 'Usage: %s {claude|opencode|codex|all}\n' "$0" >&2
  printf 'Set DEV_SKILLS_PROJECT_ROOT to install into a different project root.\n' >&2
}

client_dir() {
  case "$1" in
    claude) printf '%s/.claude/skills' "$PROJECT_ROOT" ;;
    opencode) printf '%s/.opencode/skills' "$PROJECT_ROOT" ;;
    codex) printf '%s/.agents/skills' "$PROJECT_ROOT" ;;
    *) usage; exit 2 ;;
  esac
}

install_client() {
  local client="$1"
  local target
  target="$(client_dir "$client")"
  mkdir -p "$target"

  local plugin skill skill_name destination plugin_name existing_link existing_real source_real
  for plugin in "$SCRIPT_DIR"/plugins/*/; do
    [ -d "$plugin/skills" ] || continue
    plugin_name="$(basename "$plugin")"
    for skill in "$plugin/skills"/*/; do
      [ -f "$skill/SKILL.md" ] || continue
      skill_name="$(basename "$skill")"
      destination="$target/$skill_name"
      source_real="$(cd "$skill" && pwd)"

      if [ -e "$destination" ] || [ -L "$destination" ]; then
        existing_link="$(readlink "$destination" 2>/dev/null || true)"
        existing_real=""
        if [ -n "$existing_link" ]; then
          if [ "${existing_link#/}" != "$existing_link" ]; then
            existing_real="$(cd "$existing_link" 2>/dev/null && pwd || true)"
          else
            existing_real="$(cd "$(dirname "$destination")/$existing_link" 2>/dev/null && pwd || true)"
          fi
        fi
        if [ "$existing_real" = "$source_real" ]; then
          continue
        fi
        skill_name="${plugin_name}-${skill_name}"
        destination="$target/$skill_name"
      fi

      if [ -e "$destination" ] || [ -L "$destination" ]; then
        existing_link="$(readlink "$destination" 2>/dev/null || true)"
        existing_real=""
        if [ -n "$existing_link" ]; then
          if [ "${existing_link#/}" != "$existing_link" ]; then
            existing_real="$(cd "$existing_link" 2>/dev/null && pwd || true)"
          else
            existing_real="$(cd "$(dirname "$destination")/$existing_link" 2>/dev/null && pwd || true)"
          fi
        fi
        if [ "$existing_real" = "$source_real" ]; then
          continue
        fi
        printf 'Refusing to overwrite existing skill: %s\n' "$destination" >&2
        exit 1
      fi

      ln -s "$source_real" "$destination"
    done
  done
  printf 'Installed development-skills for %s in %s\n' "$client" "$target"
}

[ "$#" -eq 1 ] || { usage; exit 2; }
case "$1" in
  all)
    install_client claude
    install_client opencode
    install_client codex
    ;;
  claude|opencode|codex) install_client "$1" ;;
  *) usage; exit 2 ;;
esac
