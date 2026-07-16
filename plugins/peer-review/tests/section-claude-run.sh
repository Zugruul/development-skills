#!/usr/bin/env bash
# section-claude-run.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/fails before
# sourcing this file.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/peer-review/tests/run-tests.sh" >&2; exit 2; }
echo "== claude-run.sh (CDX-054) =="

SCRIPT="$PLUGIN/scripts/claude-run.sh"

# claude-run.sh's own job is pure wiring, mirroring run.sh's for the codex
# provider: translate its args into diff-source.sh's flags (always adding
# --preflight-bin claude), decide whether to invoke claude-review.sh based
# on diff-source.sh's output, and propagate exit codes -- not re-derive
# diff-source.sh/claude-review.sh's own tested behavior. Both stubbed here.
STUBDIR="$(mktemp -d)"
DSLOG="$(mktemp)"
CRLOG="$(mktemp)"

cat >"$STUBDIR/diff-source.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
{ printf 'ARGC=%s\n' "$#"; for a in "$@"; do printf 'ARG<<<%s>>>\n' "$a"; done; } >>"$DSLOG"
case "${DS_FIXTURE:-diff}" in
    diff)
        printf 'diff --git a/foo.sh b/foo.sh\n+echo hi\n'
        exit 0
        ;;
    nothing)
        echo "nothing to review"
        exit 0
        ;;
    installerr)
        echo "ERROR: claude not found on PATH." >&2
        echo "Install the claude CLI and ensure it is on PATH, then retry." >&2
        exit 2
        ;;
    giterr)
        echo "ERROR: git diff against 'main' failed: fatal: bad revision" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$STUBDIR/diff-source.sh"

cat >"$STUBDIR/claude-review.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
{
    printf 'ARGC=%s\n' "$#"
    for a in "$@"; do printf 'ARG<<<%s>>>\n' "$a"; done
    last="${*: -1}"
    printf 'DIFFCONTENT<<<%s>>>\n' "$(cat "$last")"
} >>"$CRLOG"
case "${CR_FIXTURE:-ok}" in
    ok)
        echo "## External review — Claude"
        echo "No findings."
        exit 0
        ;;
    fail)
        echo "fake claude-review.sh: claude auth error" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$STUBDIR/claude-review.sh"

reset_logs() { : >"$DSLOG"; : >"$CRLOG"; }

# --- no args: diff-source.sh always receives --preflight-bin claude ---
reset_logs
out="$(DS_FIXTURE=diff CR_FIXTURE=ok DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "no-args: exits 0" "rc=0" "$out"
check "no-args: shows claude-review.sh's rendered output" "No findings." "$out"
check "no-args: diff-source.sh received --preflight-bin" "ARG<<<--preflight-bin>>>" "$(cat "$DSLOG")"
check "no-args: diff-source.sh received claude as the preflight bin" "ARG<<<claude>>>" "$(cat "$DSLOG")"
check "no-args: claude-review.sh received the diff text from diff-source.sh" "echo hi" "$(cat "$CRLOG")"

# --- --base <ref>: forwarded to diff-source.sh alongside --preflight-bin claude ---
reset_logs
out="$(DS_FIXTURE=diff CR_FIXTURE=ok DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --base develop 2>&1; echo "rc=$?")"
check "--base: exits 0" "rc=0" "$out"
check "--base: diff-source.sh received --preflight-bin claude" "ARG<<<claude>>>" "$(cat "$DSLOG")"
check "--base: diff-source.sh received --base" "ARG<<<--base>>>" "$(cat "$DSLOG")"
check "--base: diff-source.sh received the ref" "ARG<<<develop>>>" "$(cat "$DSLOG")"

# --- --staged ---
reset_logs
out="$(DS_FIXTURE=diff CR_FIXTURE=ok DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --staged 2>&1; echo "rc=$?")"
check "--staged: exits 0" "rc=0" "$out"
check "--staged: diff-source.sh received --staged" "ARG<<<--staged>>>" "$(cat "$DSLOG")"

# --- bare PR number: translated to diff-source.sh's --pr <n> ---
reset_logs
out="$(DS_FIXTURE=diff CR_FIXTURE=ok DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 42 2>&1; echo "rc=$?")"
check "PR number: exits 0" "rc=0" "$out"
check "PR number: diff-source.sh received --pr" "ARG<<<--pr>>>" "$(cat "$DSLOG")"
check "PR number: diff-source.sh received the number" "ARG<<<42>>>" "$(cat "$DSLOG")"

# --- nothing to review: claude-review.sh is never invoked ---
reset_logs
out="$(DS_FIXTURE=nothing CR_FIXTURE=ok DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "nothing to review: exits 0" "rc=0" "$out"
check "nothing to review: reports nothing to review" "nothing to review" "$out"
check_absent "nothing to review: claude-review.sh never invoked" "ARGC" "$(cat "$CRLOG")"

# --- diff-source.sh install error (exit 2): propagated, claude-review.sh never invoked ---
reset_logs
out="$(DS_FIXTURE=installerr CR_FIXTURE=ok DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_rc "diff-source install error: exit code propagated as 2" 2 "${out##*rc=}"
check "diff-source install error: install message surfaced" "Install the claude CLI" "$out"
check_absent "diff-source install error: claude-review.sh never invoked" "ARGC" "$(cat "$CRLOG")"

# --- diff-source.sh git error (exit 1): propagated, claude-review.sh never invoked ---
reset_logs
out="$(DS_FIXTURE=giterr CR_FIXTURE=ok DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_rc "diff-source git error: exit code propagated as 1" 1 "${out##*rc=}"
check "diff-source git error: error surfaced" "bad revision" "$out"
check_absent "diff-source git error: claude-review.sh never invoked" "ARGC" "$(cat "$CRLOG")"

# --- claude-review.sh failure (e.g. claude auth): propagated verbatim ---
reset_logs
out="$(DS_FIXTURE=diff CR_FIXTURE=fail DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_rc "claude-review failure: exit code propagated as 1" 1 "${out##*rc=}"
check "claude-review failure: claude auth error surfaced" "fake claude-review.sh: claude auth error" "$out"

# --- --staged and a PR number together: usage error, exit 2 ---
reset_logs
out="$(DS_FIXTURE=diff CR_FIXTURE=ok DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --staged 42 2>&1; echo "rc=$?")"
check_rc "conflicting args: exit code 2" 2 "${out##*rc=}"
check_absent "conflicting args: diff-source.sh never invoked" "ARGC" "$(cat "$DSLOG")"

# --- --model <slug> alone: forwarded to claude-review.sh, diff-source.sh unaffected beyond --preflight-bin ---
reset_logs
out="$(DS_FIXTURE=diff CR_FIXTURE=ok DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --model claude-opus-4-8 2>&1; echo "rc=$?")"
check "--model alone: exits 0" "rc=0" "$out"
check "--model alone: diff-source.sh received only --preflight-bin claude" "ARGC=2" "$(cat "$DSLOG")"
check "--model alone: claude-review.sh received --model" "ARG<<<--model>>>" "$(cat "$CRLOG")"
check "--model alone: claude-review.sh received the slug" "ARG<<<claude-opus-4-8>>>" "$(cat "$CRLOG")"

# --- no --model: claude-review.sh receives no --model flag (preserves default behavior) ---
reset_logs
out="$(DS_FIXTURE=diff CR_FIXTURE=ok DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "no --model: exits 0" "rc=0" "$out"
check_absent "no --model: claude-review.sh receives no --model flag" "ARG<<<--model>>>" "$(cat "$CRLOG")"

# --- --model missing its argument -> usage error, exit 2 ---
reset_logs
out="$(DS_FIXTURE=diff CR_FIXTURE=ok DSLOG="$DSLOG" CRLOG="$CRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --model 2>&1; echo "rc=$?")"
check_rc "--model missing arg: exit code 2" 2 "${out##*rc=}"
check_absent "--model missing arg: diff-source.sh never invoked" "ARGC" "$(cat "$DSLOG")"

rm -f "$DSLOG" "$CRLOG"
rm -rf "$STUBDIR"
