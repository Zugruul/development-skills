#!/usr/bin/env bash
# section-run.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/fails before
# sourcing this file.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/peer-review/tests/run-tests.sh" >&2; exit 2; }
echo "== run.sh (PRV-003) =="

SCRIPT="$PLUGIN/scripts/run.sh"

# run.sh's own job is pure wiring: translate its args into diff-source.sh's
# flags, decide whether to invoke peer-review.sh based on diff-source.sh's
# output, and propagate exit codes -- not re-derive diff-source.sh/
# peer-review.sh's own tested behavior. So both are stubbed here, logging
# their invocation to a file the checks assert against.
STUBDIR="$(mktemp -d)"
DSLOG="$(mktemp)"
PRLOG="$(mktemp)"

# stub diff-source.sh: echoes its own argv to $DSLOG, then behaves per
# $DS_FIXTURE (diff|nothing|installerr|giterr).
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
        echo "ERROR: codex not found on PATH." >&2
        echo "Install the codex CLI (https://github.com/openai/codex) and ensure it is on PATH, then retry." >&2
        exit 2
        ;;
    giterr)
        echo "ERROR: git diff against 'main' failed: fatal: bad revision" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$STUBDIR/diff-source.sh"

# stub peer-review.sh: echoes its own argv AND the contents of the diff-text
# file it was handed to $PRLOG, then behaves per $PR_FIXTURE (ok|fail).
cat >"$STUBDIR/peer-review.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
{
    printf 'ARGC=%s\n' "$#"
    for a in "$@"; do printf 'ARG<<<%s>>>\n' "$a"; done
    last="${*: -1}"
    printf 'DIFFCONTENT<<<%s>>>\n' "$(cat "$last")"
} >>"$PRLOG"
case "${PR_FIXTURE:-ok}" in
    ok)
        echo "## External review — codex"
        echo "No findings."
        exit 0
        ;;
    fail)
        echo "fake peer-review.sh: codex auth error" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$STUBDIR/peer-review.sh"

reset_logs() { : >"$DSLOG"; : >"$PRLOG"; }

# --- no args: default source, diff present -> diff-source then peer-review, diff handed through ---
reset_logs
out="$(DS_FIXTURE=diff PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "no-args: exits 0" "rc=0" "$out"
check "no-args: shows peer-review.sh's rendered output" "No findings." "$out"
check "no-args: diff-source.sh invoked with no extra args" "ARGC=0" "$(cat "$DSLOG")"
check "no-args: peer-review.sh received the diff text from diff-source.sh" "echo hi" "$(cat "$PRLOG")"

# --- --base <ref>: forwarded verbatim to diff-source.sh ---
reset_logs
out="$(DS_FIXTURE=diff PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --base develop 2>&1; echo "rc=$?")"
check "--base: exits 0" "rc=0" "$out"
check "--base: diff-source.sh received --base" "ARG<<<--base>>>" "$(cat "$DSLOG")"
check "--base: diff-source.sh received the ref" "ARG<<<develop>>>" "$(cat "$DSLOG")"

# --- --staged: forwarded verbatim to diff-source.sh ---
reset_logs
out="$(DS_FIXTURE=diff PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --staged 2>&1; echo "rc=$?")"
check "--staged: exits 0" "rc=0" "$out"
check "--staged: diff-source.sh received --staged" "ARG<<<--staged>>>" "$(cat "$DSLOG")"

# --- bare PR number: translated to diff-source.sh's --pr <n> ---
reset_logs
out="$(DS_FIXTURE=diff PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 42 2>&1; echo "rc=$?")"
check "PR number: exits 0" "rc=0" "$out"
check "PR number: diff-source.sh received --pr" "ARG<<<--pr>>>" "$(cat "$DSLOG")"
check "PR number: diff-source.sh received the number" "ARG<<<42>>>" "$(cat "$DSLOG")"

# --- nothing to review: peer-review.sh is never invoked ---
reset_logs
out="$(DS_FIXTURE=nothing PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "nothing to review: exits 0" "rc=0" "$out"
check "nothing to review: reports nothing to review" "nothing to review" "$out"
check_absent "nothing to review: peer-review.sh never invoked" "ARGC" "$(cat "$PRLOG")"

# --- diff-source.sh install error (exit 2): propagated, peer-review.sh never invoked ---
reset_logs
out="$(DS_FIXTURE=installerr PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_rc "diff-source install error: exit code propagated as 2" 2 "${out##*rc=}"
check "diff-source install error: install message surfaced" "Install the codex CLI" "$out"
check_absent "diff-source install error: peer-review.sh never invoked" "ARGC" "$(cat "$PRLOG")"

# --- diff-source.sh git error (exit 1): propagated, peer-review.sh never invoked ---
reset_logs
out="$(DS_FIXTURE=giterr PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_rc "diff-source git error: exit code propagated as 1" 1 "${out##*rc=}"
check "diff-source git error: error surfaced" "bad revision" "$out"
check_absent "diff-source git error: peer-review.sh never invoked" "ARGC" "$(cat "$PRLOG")"

# --- peer-review.sh failure (e.g. codex auth): propagated verbatim ---
reset_logs
out="$(DS_FIXTURE=diff PR_FIXTURE=fail DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_rc "peer-review failure: exit code propagated as 1" 1 "${out##*rc=}"
check "peer-review failure: codex auth error surfaced" "fake peer-review.sh: codex auth error" "$out"

# --- --staged and a PR number together: usage error, exit 2 ---
reset_logs
out="$(DS_FIXTURE=diff PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --staged 42 2>&1; echo "rc=$?")"
check_rc "conflicting args: exit code 2" 2 "${out##*rc=}"
check_absent "conflicting args: diff-source.sh never invoked" "ARGC" "$(cat "$DSLOG")"

# --- --model <slug> alone: forwarded to peer-review.sh, diff-source.sh unaffected ---
reset_logs
out="$(DS_FIXTURE=diff PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --model gpt-5.6-terra 2>&1; echo "rc=$?")"
check "--model alone: exits 0" "rc=0" "$out"
check "--model alone: diff-source.sh received no extra args" "ARGC=0" "$(cat "$DSLOG")"
check "--model alone: peer-review.sh received --model" "ARG<<<--model>>>" "$(cat "$PRLOG")"
check "--model alone: peer-review.sh received the slug" "ARG<<<gpt-5.6-terra>>>" "$(cat "$PRLOG")"

# --- --model combined with --staged, model before the diff-source flag ---
reset_logs
out="$(DS_FIXTURE=diff PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --model gpt-5.6-sol --staged 2>&1; echo "rc=$?")"
check "--model + --staged: exits 0" "rc=0" "$out"
check "--model + --staged: diff-source.sh received --staged" "ARG<<<--staged>>>" "$(cat "$DSLOG")"
check "--model + --staged: peer-review.sh received the slug" "ARG<<<gpt-5.6-sol>>>" "$(cat "$PRLOG")"

# --- --model combined with a bare PR number, model after (order-independent) ---
reset_logs
out="$(DS_FIXTURE=diff PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 42 --model gpt-5.6-luna 2>&1; echo "rc=$?")"
check "PR + --model (order-independent): exits 0" "rc=0" "$out"
check "PR + --model: diff-source.sh received --pr 42" "ARG<<<42>>>" "$(cat "$DSLOG")"
check "PR + --model: peer-review.sh received the slug" "ARG<<<gpt-5.6-luna>>>" "$(cat "$PRLOG")"

# --- no --model: peer-review.sh receives no --model flag (preserves default behavior) ---
reset_logs
out="$(DS_FIXTURE=diff PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "no --model: exits 0" "rc=0" "$out"
check_absent "no --model: peer-review.sh receives no --model flag" "ARG<<<--model>>>" "$(cat "$PRLOG")"

# --- nothing to review: --model given, but peer-review.sh still never invoked ---
reset_logs
out="$(DS_FIXTURE=nothing PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --model gpt-5.6-sol 2>&1; echo "rc=$?")"
check "nothing to review + --model: exits 0" "rc=0" "$out"
check_absent "nothing to review + --model: peer-review.sh never invoked" "ARGC" "$(cat "$PRLOG")"

# --- --model missing its argument -> usage error, exit 2 ---
reset_logs
out="$(DS_FIXTURE=diff PR_FIXTURE=ok DSLOG="$DSLOG" PRLOG="$PRLOG" PEER_REVIEW_STUBS="$STUBDIR" bash "$SCRIPT" --model 2>&1; echo "rc=$?")"
check_rc "--model missing arg: exit code 2" 2 "${out##*rc=}"
check_absent "--model missing arg: diff-source.sh never invoked" "ARGC" "$(cat "$DSLOG")"

rm -f "$DSLOG" "$PRLOG"
rm -rf "$STUBDIR"
