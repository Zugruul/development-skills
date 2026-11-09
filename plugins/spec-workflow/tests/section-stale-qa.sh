#!/usr/bin/env bash
# section-stale-qa.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced _lib.sh
# (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails before sourcing.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== stale QA report (#567): next reads local data only =="

_sq_out="$(python3 "$HERE/test_stale_qa.py" 2>&1)"; _sq_rc=$?
[[ "$_sq_rc" -eq 0 ]] || echo "$_sq_out"
check_rc "next reports stale QA from local telemetry (#567)" 0 "$_sq_rc"

# --- API budget: `next` makes EXACTLY the same gh calls with or without a QA item ---
_sq_run() { # <item-status> <telemetry-line-or-empty> -> sets SQ_OUT, SQ_CALLS
    local d g cc
    d="$(mktemp -d)"; mkdir -p "$d/.claude" "$d/.neural-network"
    cp "$FIX/valid.project.yaml" "$d/.neural-network/project.yaml"
    [[ -n "$2" ]] && printf '%s\n' "$2" >"$d/.claude/telemetry.jsonl"
    g="$(mktemp -d)"; cc="$(mktemp)"; : >"$cc"
    cat >"$g/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >>"$FAKE_GH_LOG"
n=$(( $(cat "$FAKE_GH_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FAKE_GH_CALLCOUNT"
case "$1 $2" in
    "api graphql") exec python3 "$GH_GQL_ADAPTER" "$0" "$@" ;;
    "project item-list")
        echo "{\"items\":[{\"id\":\"ITEM_777\",\"content\":{\"number\":777},\"title\":\"FX-001: t\",\"status\":\"$FAKE_GH_ITEM_STATUS\"}]}" ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
    chmod +x "$g/gh"
    SQ_OUT="$(cd "$d" && PATH="$g:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_CALLCOUNT="$cc" FAKE_GH_ITEM_STATUS="$1" \
        SPEC_WORKFLOW_REPO_ROOT="$d" bash "$PLUGIN/scripts/board.sh" next 2>&1)"
    SQ_CALLS="$(cat "$cc")"
    rm -rf "$d" "$g" "$cc"
}
_sq_old="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ)"
_sq_run Backlog ""
_sq_base="$SQ_CALLS"
_sq_run QA "{\"kind\":\"transition\",\"task\":\"777\",\"from\":\"In review\",\"to\":\"QA\",\"ts\":\"$_sq_old\"}"
check "board.sh next prints the stale QA line" "STALE QA: #777 in QA for 3d" "$SQ_OUT"
check_rc "stale-QA next makes exactly the same gh calls as a plain next" "$_sq_base" "$SQ_CALLS"
_sq_run QA ""
check "board.sh next: unknown age line without a record" "STALE QA: 1 item with age unknown: #777" "$SQ_OUT"
check_rc "age-unknown next makes exactly the same gh calls as a plain next" "$_sq_base" "$SQ_CALLS"

# --- config surface: schema + validator ---
check "schema declares methodology.qaStaleHours" '"qaStaleHours"' "$(cat "$PLUGIN/schemas/project-config.schema.json")"
for _sq_bad in 0 -1 abc true 1.5; do
    _sq_d="$(mktemp -d)"
    sed "/^    maxInProgress: 1/a\\
    qaStaleHours: $_sq_bad" "$FIX/valid.project.yaml" >"$_sq_d/p.yaml"
    out="$(python3 "$PLUGIN/scripts/validate-config.py" "$_sq_d/p.yaml" || true)"
    check "qaStaleHours: $_sq_bad rejected" "methodology.qaStaleHours: must be" "$out"
    rm -rf "$_sq_d"
done
_sq_d="$(mktemp -d)"
sed "/^    maxInProgress: 1/a\\
    qaStaleHours: 36" "$FIX/valid.project.yaml" >"$_sq_d/p.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$_sq_d/p.yaml" 2>&1; echo "rc=$?")"
check "qaStaleHours: 36 accepted" "rc=0" "$out"
rm -rf "$_sq_d"

# --- skills and docs ---
_sq_bn="$(cat "$PLUGIN/skills/build-next/SKILL.md")"
_sq_it="$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "build-next: QA -> Ready after validation" "QA -> Ready" "$_sq_bn"
check "build-next: records why validation cannot run" "gh api -X POST" "$_sq_bn"
check "build-next: card stays in QA when blocked" "stays in QA" "$_sq_bn"
check "build-next: refused move never stops the loop" "refused or failed" "$_sq_bn"
_sq_step="$(grep -E '^[0-9]+\. \*\*Validate' <<<"$_sq_bn")"
check "build-next: validation is its own numbered loop step" "9. **Validate" "$_sq_step"
check "build-next: closure step renumbered after validation" "10. **Record closure evidence" "$_sq_bn"
check "build-next: mentions the stale QA line" "STALE QA" "$_sq_bn"
check "implement-task: close section moves QA to Ready after validation" "QA -> Ready" "$_sq_it"
check "implement-task: stale QA line documented" "STALE QA" "$_sq_it"
_sq_rd="$(cat "$PLUGIN/README.md")"
check "README documents qaStaleHours" "qaStaleHours" "$_sq_rd"
check "README documents the 5-line cap" "+N more" "$_sq_rd"
check "README documents QA status by flow position" "fourth entry of statusFlow" "$_sq_rd"
check "README documents board-wide scope under next <spec-id>" "board-wide" "$_sq_rd"
_sq_para="$(awk -v RS= '/Completion evidence attests/' "$PLUGIN/skills/implement-task/SKILL.md")"
check "implement-task: completion-evidence sentence stays inside the closure paragraph" 'closure-preflight.sh" --task N' "$_sq_para"
_sq_dl="$(cat "$PLUGIN/../../docs/spec-deltas/567.md")"
check "spec delta targets §7.3 next.py" "## §7.3 next.py" "$_sq_dl"
check "spec delta targets §8.2 retro enforcement" "## §8.2 retro enforcement" "$_sq_dl"
check_absent "spec delta no longer uses §7.1" "§7.1" "$_sq_dl"
check_absent "spec delta blocks are ADDED, never MODIFIED (MODIFIED would replace existing rules)" "— MODIFIED" "$_sq_dl"
check "spec delta §7.3 block is ADDED" "## §7.3 next.py — ADDED" "$_sq_dl"
check "spec delta §8.2 block is ADDED" "## §8.2 retro enforcement — ADDED" "$_sq_dl"
_sq_s10="$(awk '/^10\. \*\*Record closure/{f=1} f&&/^## /{exit} f{print}' "$PLUGIN/skills/build-next/SKILL.md")"
_sq_s9="$(grep -E '^9\. \*\*Validate' "$PLUGIN/skills/build-next/SKILL.md")"
check "build-next step 10 carries the refused-move rule" "A refused or failed move is reported and the loop continues" "$_sq_s10"
check_absent "build-next step 9 no longer carries the refused-move rule" "A refused or failed move" "$_sq_s9"
check "build-next step 10 covers a QA-blocked step 9" "stays in QA with the recorded reason" "$_sq_s10"
_sq_ce="$(grep -c '^Completion evidence attests' "$PLUGIN/skills/implement-task/SKILL.md")"
check_rc "implement-task: completion-evidence sentence appears exactly once" 1 "$_sq_ce"
