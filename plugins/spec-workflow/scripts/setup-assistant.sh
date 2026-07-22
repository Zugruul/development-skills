#!/usr/bin/env bash
# setup-assistant.sh — scaffold + settings editor for the `assistant:` repo
# (SPEC-ASSISTANT.md §6.4, §6.7, §11.9; touchpoint §6.3). Thin bash wrapper:
# all structural logic lives in scripts/assistant/setup.py (nested dict
# building, YAML surgical edits via config.py, validate_assistant gating);
# this script resolves --root, dispatches the verb, and — only for the
# `scaffold` verb — syncs the target repo's .gitignore via gitignore-sync.sh
# (the manifest already carries `.claude/assistant/`, so no new gitignore
# logic is needed here).
#
# Usage:
#   setup-assistant.sh [--root DIR] [scaffold] [--name NAME] [--provider P] [--model M]
#   setup-assistant.sh [--root DIR] set-provider <openai|claude>
#   setup-assistant.sh [--root DIR] set-model <model-string>
#   setup-assistant.sh [--root DIR] enable-capability <name>
#   setup-assistant.sh [--root DIR] disable-capability <name>
#   setup-assistant.sh [--root DIR] set-default <name>
#   setup-assistant.sh [--root DIR] validate
#
# bash 3.2-compatible (no bash-4-only constructs).
set -uo pipefail

SA_HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

sa_usage() {
    cat <<EOF
usage: setup-assistant.sh [--root DIR] [scaffold [--name NAME] [--provider P] [--model M]]
       setup-assistant.sh [--root DIR] set-provider <openai|claude>
       setup-assistant.sh [--root DIR] set-model <model-string>
       setup-assistant.sh [--root DIR] enable-capability <name>
       setup-assistant.sh [--root DIR] disable-capability <name>
       setup-assistant.sh [--root DIR] set-default <name>
       setup-assistant.sh [--root DIR] validate
  No verb given -> scaffold. --root defaults to the git toplevel, else cwd.
EOF
}

sa_root=""
sa_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            shift
            [ $# -gt 0 ] || { echo "setup-assistant: --root requires a value" >&2; exit 2; }
            sa_root="$1" ;;
        -h|--help) sa_usage; exit 0 ;;
        *) sa_args+=("$1") ;;
    esac
    shift
done

[ -n "$sa_root" ] || sa_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

sa_verb="scaffold"
if [ "${#sa_args[@]}" -gt 0 ]; then
    sa_verb="${sa_args[0]}"
    sa_args=("${sa_args[@]:1}")
fi

case "$sa_verb" in
    scaffold)
        if [ "${#sa_args[@]}" -gt 0 ]; then
            python3 "$SA_HERE/assistant/setup.py" "$sa_root" scaffold "${sa_args[@]}" || exit 1
        else
            python3 "$SA_HERE/assistant/setup.py" "$sa_root" scaffold || exit 1
        fi
        bash "$SA_HERE/gitignore-sync.sh" "$sa_root/.gitignore" || exit 1
        echo "setup-assistant: scaffold complete at $sa_root"
        ;;
    set-provider|set-model|enable-capability|disable-capability|set-default|validate)
        if [ "${#sa_args[@]}" -gt 0 ]; then
            python3 "$SA_HERE/assistant/setup.py" "$sa_root" "$sa_verb" "${sa_args[@]}"
        else
            python3 "$SA_HERE/assistant/setup.py" "$sa_root" "$sa_verb"
        fi
        ;;
    *)
        echo "setup-assistant: unknown verb: $sa_verb" >&2
        sa_usage >&2
        exit 2
        ;;
esac
