#!/usr/bin/env bash
# kb-seed.sh — thin wrapper over kb-seed.py (GL-050 knowledge-graph seeder).
# Mirrors brain.sh's ROOT-resolution pattern so it writes into the consumer
# repo's .claude/identities/ regardless of cwd.
#
#   kb-seed.sh seed [--role knowledge] [--force] [--dry-run]
#
# Env: BRAIN_DIR (identities dir override, relative to root; default .claude/identities).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/spec-workflow/scripts/lib/repo-root.sh
source "$HERE/lib/repo-root.sh"
# #463: PRIMARY repo root -- mirrors brain.sh's rationale: the knowledge
# brain lives once per repo in the main checkout's .claude/identities/.
ROOT="$(spec_workflow_repo_root)" || { echo "ERROR: could not resolve repo root" >&2; exit 1; }
DIR_ARGS=()
[[ -n "${BRAIN_DIR:-}" ]] && DIR_ARGS=(--dir "$BRAIN_DIR")

# ${DIR_ARGS[@]+...} guard: expanding an empty array as "${DIR_ARGS[@]}" is an
# "unbound variable" error under `set -u` on bash 3.2 (macOS default) — the
# guard yields nothing when the array is unset/empty and the args when set.
exec python3 "$HERE/kb-seed.py" "$ROOT" ${DIR_ARGS[@]+"${DIR_ARGS[@]}"} "$@"
