#!/usr/bin/env bash
# section-preflight.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== preflight =="
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
( cd "$T" && git init -q . )
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh" --spec)"
check "no config -> setup-project" "PREFLIGHT FAIL: no .claude/project.yaml" "$out"
mkdir -p "$T/.claude" && cp "$FIX/valid.project.json" "$T/.claude/project.json"
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh" --spec)"
check "missing spec file -> craft-spec" "spec file(s) missing: SPEC.md" "$out"
touch "$T/SPEC.md"
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh" --spec)"
check "config + spec ok" "preflight ok: config + 1 spec(s) present" "$out"
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh")"
check "config-only ok" "preflight ok: config present" "$out"

# development-skills#197: preflight.sh warns (non-blocking) when this repo's
# own plugins/spec-workflow/scripts/ source diverges from an installed
# marketplace cache copy of the same plugin -- a real bug (a merged
# identity_lib.py change silently invisible via the cache path) this repo
# hit once already. SPEC_WORKFLOW_CACHE_SEARCH_BASE overrides the real
# ~/.claude/plugins/cache search root so this is hermetic/portable, not
# dependent on the actual test machine's installed plugins.
_sc_repo="$(mktemp -d)"
( cd "$_sc_repo" && git init -q . )
mkdir -p "$_sc_repo/.claude" && cp "$FIX/valid.project.json" "$_sc_repo/.claude/project.json"
touch "$_sc_repo/SPEC.md"
mkdir -p "$_sc_repo/plugins/spec-workflow/scripts"
printf 'identity content v1\n' >"$_sc_repo/plugins/spec-workflow/scripts/identity_lib.py"
printf 'identity.sh content\n' >"$_sc_repo/plugins/spec-workflow/scripts/identity.sh"
printf 'board content\n' >"$_sc_repo/plugins/spec-workflow/scripts/board.sh"
printf 'config content\n' >"$_sc_repo/plugins/spec-workflow/scripts/config.py"

# (a) diverged cache -> one clear warning naming the diverged file(s)
_sc_cachebase="$(mktemp -d)"
_sc_cachedir="$_sc_cachebase/some-marketplace/spec-workflow/0.25.0/scripts"
mkdir -p "$_sc_cachedir"
printf 'identity content v1\n' >"$_sc_cachedir/identity_lib.py"
printf 'identity.sh content\n' >"$_sc_cachedir/identity.sh"
printf 'DIFFERENT board content\n' >"$_sc_cachedir/board.sh"
printf 'config content\n' >"$_sc_cachedir/config.py"
out="$(cd "$_sc_repo" && SPEC_WORKFLOW_CACHE_SEARCH_BASE="$_sc_cachebase" bash "$PLUGIN/scripts/preflight.sh")"
check "diverged cache: warns" "PLUGIN CACHE WARN" "$out"
check "diverged cache: names the diverged file" "board.sh" "$out"
check_absent "diverged cache: does not misname an identical file" "identity_lib.py differ" "$out"

# (b) identical cache -> no warning
_sc_cachebase2="$(mktemp -d)"
_sc_cachedir2="$_sc_cachebase2/some-marketplace/spec-workflow/0.25.0/scripts"
mkdir -p "$_sc_cachedir2"
cp "$_sc_repo/plugins/spec-workflow/scripts/"*.py "$_sc_repo/plugins/spec-workflow/scripts/"*.sh "$_sc_cachedir2/"
out="$(cd "$_sc_repo" && SPEC_WORKFLOW_CACHE_SEARCH_BASE="$_sc_cachebase2" bash "$PLUGIN/scripts/preflight.sh")"
check_absent "identical cache: no warning" "PLUGIN CACHE WARN" "$out"

# (c) no cache found at all -> silent no-op, no crash
_sc_emptybase="$(mktemp -d)"
out="$(cd "$_sc_repo" && SPEC_WORKFLOW_CACHE_SEARCH_BASE="$_sc_emptybase" bash "$PLUGIN/scripts/preflight.sh")"
check_absent "no cache found: no warning" "PLUGIN CACHE WARN" "$out"
check "no cache found: preflight still reports ok" "preflight ok" "$out"

# (d) no local plugin source (a consumer repo, not this plugin's own source) -> silent no-op
_sc_consumer="$(mktemp -d)"
( cd "$_sc_consumer" && git init -q . )
mkdir -p "$_sc_consumer/.claude" && cp "$FIX/valid.project.json" "$_sc_consumer/.claude/project.json"
touch "$_sc_consumer/SPEC.md"
out="$(cd "$_sc_consumer" && SPEC_WORKFLOW_CACHE_SEARCH_BASE="$_sc_cachebase" bash "$PLUGIN/scripts/preflight.sh")"
check_absent "no local plugin source: no warning" "PLUGIN CACHE WARN" "$out"

rm -rf "$_sc_repo" "$_sc_cachebase" "$_sc_cachebase2" "$_sc_emptybase" "$_sc_consumer"

