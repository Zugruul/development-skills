#!/usr/bin/env bash
# kb-seed.sh — thin wrapper over kb-seed.py (GL-050 knowledge-graph seeder).
# Mirrors brain.sh's ROOT-resolution pattern so it writes into the consumer
# repo's .claude/identities/ regardless of cwd.
#
#   kb-seed.sh seed [--role knowledge] [--force] [--dry-run]
#
# Env: BRAIN_DIR (identities dir override, relative to root; default .claude/identities).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR_ARGS=()
[[ -n "${BRAIN_DIR:-}" ]] && DIR_ARGS=(--dir "$BRAIN_DIR")

# ${DIR_ARGS[@]+...} guard: expanding an empty array as "${DIR_ARGS[@]}" is an
# "unbound variable" error under `set -u` on bash 3.2 (macOS default) — the
# guard yields nothing when the array is unset/empty and the args when set.
exec python3 "$HERE/kb-seed.py" "$ROOT" ${DIR_ARGS[@]+"${DIR_ARGS[@]}"} "$@"
