#!/usr/bin/env bash
# section-providers.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/fails before
# sourcing this file.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/peer-review/tests/run-tests.sh" >&2; exit 2; }
echo "== providers.sh (CDX-053) =="

SCRIPT="$PLUGIN/scripts/providers.sh"
FIXDIR="$(mktemp -d)"

# --- default (shipped) registry: both v1 providers present and available (CDX-054 built claude's backend) ---
out="$(bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "default registry: exits 0" "rc=0" "$out"
check "default registry: codex present" '"id": "codex"' "$out"
check "default registry: codex display name" '"display_name": "OpenAI Codex"' "$out"
check "default registry: codex marked available" '"id": "codex", "display_name": "OpenAI Codex", "available": true' "$out"
check "default registry: claude present" '"id": "claude"' "$out"
check "default registry: claude marked available (CDX-054 backend now built)" \
    '"id": "claude", "display_name": "Claude (Anthropic)", "available": true' "$out"

# --- fixture registry: a THIRD provider proves the registry, not this script's logic, drives the list ---
cat >"$FIXDIR/three.tsv" <<'EOF'
codex	OpenAI Codex	list-models.sh	run.sh
claude	Claude (Anthropic)
widget	Widget Reviewer	widget-list.sh	widget-run.sh
EOF
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/three.tsv" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "fixture 3rd provider: exits 0" "rc=0" "$out"
check "fixture 3rd provider: widget present" '"id": "widget"' "$out"
check "fixture 3rd provider: widget display name" '"display_name": "Widget Reviewer"' "$out"
check "fixture 3rd provider: widget marked available (has a run script)" \
    '"id": "widget", "display_name": "Widget Reviewer", "available": true' "$out"

# --- malformed lines: blank id skipped, comment lines skipped, blank lines skipped ---
cat >"$FIXDIR/malformed.tsv" <<'EOF'
# this is a comment line, must be skipped
codex	OpenAI Codex	list-models.sh	run.sh

	Empty Id Entry	x.sh	y.sh
EOF
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/malformed.tsv" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "malformed: exits 0 (valid row still eligible)" "rc=0" "$out"
check_absent "malformed: empty-id entry excluded" "Empty Id Entry" "$out"
check "malformed: codex still present" '"id": "codex"' "$out"

# --- missing display_name defaults to the id ---
cat >"$FIXDIR/nodisplay.tsv" <<'EOF'
bareid
EOF
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/nodisplay.tsv" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "missing display_name: exits 0" "rc=0" "$out"
check "missing display_name: defaults to id" '"id": "bareid", "display_name": "bareid"' "$out"

# --- registry file missing entirely -> nonzero exit, clear error ---
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/does-not-exist.tsv" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_absent "missing registry file: does not report success" "rc=0" "$out"
check "missing registry file: mentions registry" "registry" "$out"

# --- registry with zero valid providers -> nonzero exit ---
cat >"$FIXDIR/empty.tsv" <<'EOF'
# only a comment, no providers
EOF
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/empty.tsv" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_absent "zero providers: does not report success" "rc=0" "$out"

rm -rf "$FIXDIR"
