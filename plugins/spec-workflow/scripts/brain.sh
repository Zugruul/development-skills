#!/usr/bin/env bash
# brain.sh — thin wrapper over brain.py (per-identity zettel memory).
# Part of the spec-workflow plugin. Resolves ROOT from git (PROJECT_CONFIG-independent)
# so the engine writes into the consumer repo's .claude/identities/ regardless of cwd.
#
#   brain.sh recall <role> --paths "a/b.sh,c/**" --keywords "yaml,merge" [--budget 600]
#   brain.sh mint <role> <slug> --tags a,b --paths "x/**" --source "..." [--learned-from R --source-note S]  # body on stdin
#   brain.sh directory
#   brain.sh consult <consumer-role> <owner-role> <slug>
#   brain.sh prune <role> [--apply]
#   brain.sh retro-mark
#   brain.sh graduate <role> <slug>
#
# Env: BRAIN_DIR (identities dir override, relative to root; default .claude/identities).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR_ARGS=()
[[ -n "${BRAIN_DIR:-}" ]] && DIR_ARGS=(--dir "$BRAIN_DIR")

# ${DIR_ARGS[@]+...} guard: expanding an empty array as "${DIR_ARGS[@]}" is an
# "unbound variable" error under `set -u` on bash 3.2 (macOS default) — the guard
# yields nothing when the array is unset/empty and the args when it is set.
exec python3 "$HERE/brain.py" "$ROOT" ${DIR_ARGS[@]+"${DIR_ARGS[@]}"} "$@"
