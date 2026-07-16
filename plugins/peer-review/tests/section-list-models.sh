#!/usr/bin/env bash
# section-list-models.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/fails before
# sourcing this file.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/peer-review/tests/run-tests.sh" >&2; exit 2; }
echo "== list-models.sh (PRV-004) =="

SCRIPT="$PLUGIN/scripts/list-models.sh"
NOBIN="/usr/bin:/bin"

# FAKECODEX_DIR: a stub `codex` binary whose `debug models` subcommand
# behavior is driven by $CODEX_DEBUG_MODELS_FIXTURE, so list-models.sh's
# filtering/sorting/fallback logic is tested deterministically and offline
# (no real codex invocation, no network).
FAKECODEX_DIR="$(mktemp -d)"
cat >"$FAKECODEX_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "debug" && "${2:-}" == "models" ]]; then
    case "${CODEX_DEBUG_MODELS_FIXTURE:-normal}" in
        normal)
            cat <<'JSON'
{"models":[
  {"slug":"gpt-5.6-terra","display_name":"GPT-5.6-Terra","description":"Balanced agentic coding model for everyday work.","visibility":"list","supported_in_api":true,"priority":2},
  {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"Latest frontier agentic coding model.","visibility":"list","supported_in_api":true,"priority":1},
  {"slug":"gpt-5.6-luna","display_name":"GPT-5.6-Luna","description":"Fast and affordable agentic coding model.","visibility":"list","supported_in_api":true,"priority":3}
]}
JSON
            exit 0
            ;;
        with-hidden)
            cat <<'JSON'
{"models":[
  {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"Latest frontier agentic coding model.","visibility":"list","supported_in_api":true,"priority":1},
  {"slug":"codex-auto-review","display_name":"Codex Auto Review","description":"Automatic approval review model.","visibility":"hide","supported_in_api":true,"priority":43}
]}
JSON
            exit 0
            ;;
        with-non-api)
            cat <<'JSON'
{"models":[
  {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"Latest frontier agentic coding model.","visibility":"list","supported_in_api":true,"priority":1},
  {"slug":"internal-only","display_name":"Internal Only","description":"Not API-supported.","visibility":"list","supported_in_api":false,"priority":2}
]}
JSON
            exit 0
            ;;
        malformed)
            echo 'this is not { valid json'
            exit 0
            ;;
        missing-description)
            cat <<'JSON'
{"models":[
  {"slug":"gpt-5.6-sol","visibility":"list","supported_in_api":true,"priority":1}
]}
JSON
            exit 0
            ;;
        empty-slug)
            cat <<'JSON'
{"models":[
  {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"real","visibility":"list","supported_in_api":true,"priority":2},
  {"slug":"","display_name":"Bad Entry","description":"empty slug","visibility":"list","supported_in_api":true,"priority":1}
]}
JSON
            exit 0
            ;;
        boolean-priority)
            cat <<'JSON'
{"models":[
  {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"real","visibility":"list","supported_in_api":true,"priority":2},
  {"slug":"bad-entry","display_name":"Bad Entry","description":"malformed priority","visibility":"list","supported_in_api":true,"priority":true}
]}
JSON
            exit 0
            ;;
        empty-eligible)
            cat <<'JSON'
{"models":[
  {"slug":"codex-auto-review","display_name":"Codex Auto Review","description":"hidden","visibility":"hide","supported_in_api":true,"priority":43}
]}
JSON
            exit 0
            ;;
        cli-error)
            echo "fake codex: debug models: internal error" >&2
            exit 1
            ;;
    esac
fi
echo "fake codex: unexpected invocation: $*" >&2
exit 1
EOF
chmod +x "$FAKECODEX_DIR/codex"

# --- normal catalog: eligible models only, sorted by priority ascending, recommended = lowest priority ---
out="$(CODEX_DEBUG_MODELS_FIXTURE=normal PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "normal: exits 0" "rc=0" "$out"
check "normal: recommended is the lowest-priority slug" '"recommended": "gpt-5.6-sol"' "$out"
firstpos=$(grep -bo '"gpt-5.6-sol"' <<<"$out" | head -1 | cut -d: -f1)
secondpos=$(grep -bo '"gpt-5.6-terra"' <<<"$out" | head -1 | cut -d: -f1)
thirdpos=$(grep -bo '"gpt-5.6-luna"' <<<"$out" | head -1 | cut -d: -f1)
if [[ "$firstpos" -lt "$secondpos" && "$secondpos" -lt "$thirdpos" ]]; then sort_rc=0; else sort_rc=1; fi
check_rc "normal: models array sorted by priority ascending (sol before terra before luna)" 0 "$sort_rc"

# --- a visibility:hide entry is excluded ---
out="$(CODEX_DEBUG_MODELS_FIXTURE=with-hidden PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "with-hidden: exits 0" "rc=0" "$out"
check_absent "with-hidden: hidden model excluded from output" "codex-auto-review" "$out"
check "with-hidden: visible model still present" "gpt-5.6-sol" "$out"

# --- a model missing display_name/description is still eligible (only slug+priority+visibility+supported_in_api are required) ---
out="$(CODEX_DEBUG_MODELS_FIXTURE=missing-description PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "missing-description: exits 0 (model still eligible)" "rc=0" "$out"
check "missing-description: recommended is still the slug" '"recommended": "gpt-5.6-sol"' "$out"
check "missing-description: slug present in models array" "gpt-5.6-sol" "$out"

# --- an empty slug is rejected, even though it survives priority 1 (recommended) ---
out="$(CODEX_DEBUG_MODELS_FIXTURE=empty-slug PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "empty-slug: exits 0 (the valid entry is still eligible)" "rc=0" "$out"
check "empty-slug: recommended is the entry with a real slug, not the empty one" '"recommended": "gpt-5.6-sol"' "$out"
check_absent "empty-slug: no empty-string slug entry in the output" '"slug": ""' "$out"

# --- a boolean priority (Python: isinstance(True, int) is True) is rejected, not treated as 0/1 ---
out="$(CODEX_DEBUG_MODELS_FIXTURE=boolean-priority PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "boolean-priority: exits 0 (the valid entry is still eligible)" "rc=0" "$out"
check_absent "boolean-priority: entry with priority:true excluded" "bad-entry" "$out"
check "boolean-priority: recommended is the entry with a real integer priority" '"recommended": "gpt-5.6-sol"' "$out"

# --- a supported_in_api:false entry is excluded ---
out="$(CODEX_DEBUG_MODELS_FIXTURE=with-non-api PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "with-non-api: exits 0" "rc=0" "$out"
check_absent "with-non-api: non-API-supported model excluded" "internal-only" "$out"

# --- malformed JSON from codex debug models -> nonzero exit, fallback signal ---
out="$(CODEX_DEBUG_MODELS_FIXTURE=malformed PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_absent "malformed: does not report success" "rc=0" "$out"

# --- zero models survive the eligibility filter -> nonzero exit ---
out="$(CODEX_DEBUG_MODELS_FIXTURE=empty-eligible PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_absent "empty-eligible: does not report success" "rc=0" "$out"

# --- codex debug models itself exits nonzero -> list-models.sh exits nonzero ---
out="$(CODEX_DEBUG_MODELS_FIXTURE=cli-error PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_absent "cli-error: does not report success" "rc=0" "$out"

# --- codex missing from PATH entirely -> nonzero exit, error mentions codex ---
out="$(PATH="$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_absent "missing codex: does not report success" "rc=0" "$out"
check "missing codex: mentions codex" "codex" "$out"

rm -rf "$FAKECODEX_DIR"
