#!/usr/bin/env bash
# section-provider-dispatch.sh -- sourced by run-tests.sh; do not run
# standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/fails before
# sourcing this file.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/peer-review/tests/run-tests.sh" >&2; exit 2; }
echo "== provider-dispatch.sh (CDX-053) =="

SCRIPT="$PLUGIN/scripts/provider-dispatch.sh"
FIXDIR="$(mktemp -d)"
LOG="$(mktemp)"

# A self-contained fixture registry + stub scripts, all living together in
# FIXDIR -- provider-dispatch.sh resolves each script relative to the
# registry file's own directory, so a fixture never has to touch the real
# scripts/ directory.
cat >"$FIXDIR/providers.tsv" <<'EOF'
codex	OpenAI Codex	list-models.sh	run.sh
claude	Claude (Anthropic)
widget	Widget Reviewer	widget-list.sh	widget-run.sh
EOF

cat >"$FIXDIR/widget-list.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
{ printf 'ARGC=%s\n' "\$#"; for a in "\$@"; do printf 'ARG<<<%s>>>\n' "\$a"; done; } >>"$LOG"
echo '{"models":[{"slug":"widget-1","display_name":"Widget One","description":""}],"recommended":"widget-1"}'
EOF
chmod +x "$FIXDIR/widget-list.sh"

cat >"$FIXDIR/widget-run.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
{ printf 'RUN ARGC=%s\n' "\$#"; for a in "\$@"; do printf 'RUN ARG<<<%s>>>\n' "\$a"; done; } >>"$LOG"
echo "widget review ran"
EOF
chmod +x "$FIXDIR/widget-run.sh"

reset_log() { : >"$LOG"; }

# --- a fixture 3rd provider with real scripts dispatches with ZERO changes to this script ---
reset_log
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/providers.tsv" bash "$SCRIPT" widget list-models 2>&1; echo "rc=$?")"
check "widget list-models: exits 0" "rc=0" "$out"
check "widget list-models: invoked the fixture's own script" "widget-1" "$out"

reset_log
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/providers.tsv" bash "$SCRIPT" widget run -- --model widget-1 --staged 2>&1; echo "rc=$?")"
check "widget run: exits 0" "rc=0" "$out"
check "widget run: ran the fixture review" "widget review ran" "$out"
check "widget run: forwarded --model" "RUN ARG<<<--model>>>" "$(cat "$LOG")"
check "widget run: forwarded the slug" "RUN ARG<<<widget-1>>>" "$(cat "$LOG")"
check "widget run: forwarded --staged" "RUN ARG<<<--staged>>>" "$(cat "$LOG")"

# --- claude: registered but not yet implemented (empty run_script) -> graceful message, exit 1 ---
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/providers.tsv" bash "$SCRIPT" claude run 2>&1; echo "rc=$?")"
check_rc "claude run: exits 1 (not a crash)" 1 "${out##*rc=}"
check "claude run: names the provider's display name" "Claude (Anthropic)" "$out"
check "claude run: says not yet available" "not yet available" "$out"

out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/providers.tsv" bash "$SCRIPT" claude list-models 2>&1; echo "rc=$?")"
check_rc "claude list-models: exits 1 (not a crash)" 1 "${out##*rc=}"
check "claude list-models: says not yet available" "not yet available" "$out"

# --- an EMPTY MIDDLE column (list_models_script empty, run_script present)
# must not misparse. Bash's `IFS=$'\t' read` collapses adjacent tabs (tab is
# "IFS whitespace" even when it's the only char in IFS), which would shift
# run_script's value into the list_script slot -- this row is exactly the
# shape the registry's own header comment documents as valid ("leave a
# script column empty if that provider's backend isn't implemented yet").
cat >"$FIXDIR/gap.tsv" <<EOF
gapproto	Gap Provider		gap-run.sh
EOF
cat >"$FIXDIR/gap-run.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "gap review ran"
EOF
chmod +x "$FIXDIR/gap-run.sh"
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/gap.tsv" bash "$SCRIPT" gapproto run 2>&1; echo "rc=$?")"
check "empty middle column: run stage uses run_script (not the empty list_script slot)" "gap review ran" "$out"
check_rc "empty middle column: run stage exits 0" 0 "${out##*rc=}"
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/gap.tsv" bash "$SCRIPT" gapproto list-models 2>&1; echo "rc=$?")"
check_rc "empty middle column: list-models stage exits 1 (list_script genuinely empty)" 1 "${out##*rc=}"
check "empty middle column: list-models stage reports not yet available, doesn't wrongly exec gap-run.sh" "not yet available" "$out"

# --- unknown provider id -> exit 2, clear error ---
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/providers.tsv" bash "$SCRIPT" nonexistent run 2>&1; echo "rc=$?")"
check_rc "unknown provider: exit 2" 2 "${out##*rc=}"
check "unknown provider: error names it" "nonexistent" "$out"

# --- bad stage argument -> exit 2, usage ---
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/providers.tsv" bash "$SCRIPT" codex bogus-stage 2>&1; echo "rc=$?")"
check_rc "bad stage: exit 2" 2 "${out##*rc=}"

# --- missing args -> exit 2, usage ---
out="$(bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_rc "no args: exit 2" 2 "${out##*rc=}"
out="$(bash "$SCRIPT" codex 2>&1; echo "rc=$?")"
check_rc "missing stage: exit 2" 2 "${out##*rc=}"

# --- registry file missing entirely -> nonzero exit, clear error ---
out="$(PEER_REVIEW_PROVIDERS_FILE="$FIXDIR/does-not-exist.tsv" bash "$SCRIPT" codex run 2>&1; echo "rc=$?")"
check_absent "missing registry: does not report success" "rc=0" "$out"
check "missing registry: mentions registry" "registry" "$out"

# --- the real, shipped registry: codex resolves to the real list-models.sh
# (no PATH codex -> its own "codex not found" error surfaces), proving the
# default (non-fixture) wiring reaches the actual PRV-004 script unchanged.
out="$(PATH="/usr/bin:/bin" bash "$SCRIPT" codex list-models 2>&1; echo "rc=$?")"
check_absent "real registry codex: does not report success without codex on PATH" "rc=0" "$out"
check "real registry codex: surfaces list-models.sh's own error" "codex not found" "$out"

rm -f "$LOG"
rm -rf "$FIXDIR"
