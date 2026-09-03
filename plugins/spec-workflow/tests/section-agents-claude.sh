#!/usr/bin/env bash
# section-agents-claude.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# Asserts the repo-root AGENTS.md/CLAUDE.md pointer pair required by
# SPEC-CODEX-COMPAT.md §6.5 (CDX-006): a canonical AGENTS.md orienting a
# Codex-side agent, and a CLAUDE.md reduced to a one-line pointer at it
# (§15 OQ-2: hand-maintained, no CI generation step this release).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== agents-claude =="

REPO="$(cd "$PLUGIN/../.." && pwd)"
AGENTS_MD="$REPO/AGENTS.md"
CLAUDE_MD="$REPO/CLAUDE.md"

# The gate command is read live from .neural-network/project.yaml (commands.gate)
# rather than hardcoded, so this test can't drift from the real command.
gate_cmd="$(python3 "$PLUGIN/scripts/config.py" "$REPO" get commands.gate 2>/dev/null)"
check "commands.gate resolved from project.yaml" "run-tests.sh" "$gate_cmd"

if [[ ! -f "$AGENTS_MD" ]]; then
    check "AGENTS.md exists at repo root" "EXISTS" "MISSING"
else
    agents_content="$(cat "$AGENTS_MD")"
    check "AGENTS.md exists at repo root" "EXISTS" "EXISTS"
    check "AGENTS.md points at SPEC.md" "SPEC.md" "$agents_content"
    check "AGENTS.md points at SPEC-CODEX-COMPAT.md" "SPEC-CODEX-COMPAT.md" "$agents_content"
    check "AGENTS.md mentions dogfooding" "dogfood" "$(tr '[:upper:]' '[:lower:]' <<<"$agents_content")"
    check "AGENTS.md quotes the gate command verbatim" "$gate_cmd" "$agents_content"
fi

if [[ ! -f "$CLAUDE_MD" ]]; then
    check "CLAUDE.md exists at repo root" "EXISTS" "MISSING"
else
    claude_content="$(cat "$CLAUDE_MD")"
    check "CLAUDE.md exists at repo root" "EXISTS" "EXISTS"
    check "CLAUDE.md points at AGENTS.md" "AGENTS.md" "$claude_content"
    line_count="$(wc -l < "$CLAUDE_MD" | tr -d ' ')"
    check_rc "CLAUDE.md is short (<= 5 lines)" 0 "$([[ "$line_count" -le 5 ]]; echo $?)"
fi
