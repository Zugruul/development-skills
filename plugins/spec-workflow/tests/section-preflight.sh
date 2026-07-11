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

