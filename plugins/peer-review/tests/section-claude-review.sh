#!/usr/bin/env bash
# section-claude-review.sh -- sourced by run-tests.sh; do not run
# standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/fails before
# sourcing this file.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/peer-review/tests/run-tests.sh" >&2; exit 2; }
echo "== claude-review.sh (CDX-054) =="

SCRIPT="$PLUGIN/scripts/claude-review.sh"

# FAKECLAUDE_DIR: a stub `claude` binary whose behavior is driven by
# $CLAUDE_FIXTURE (valid|malformed|authfail|apierror) and which logs every
# argument it was invoked with to $CLAUDE_ARGLOG, so tests can assert on the
# exact invocation (in particular that --permission-mode plan is always
# present, --json-schema receives inline JSON content rather than a file
# path, and the diff text was embedded in the prompt) without ever running a
# real claude binary (no network, deterministic, offline).
FAKECLAUDE_DIR="$(mktemp -d)"
cat >"$FAKECLAUDE_DIR/claude" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
{
    printf 'ARGC=%s\n' "$#"
    for a in "$@"; do printf 'ARG<<<%s>>>\n' "$a"; done
} >>"$CLAUDE_ARGLOG"

case "${CLAUDE_FIXTURE:-valid}" in
    valid)
        cat <<'JSON'
{"type":"result","is_error":false,"structured_output":{"findings":[{"file":"foo.sh","line":12,"severity":"warn","summary":"unquoted variable","failure_scenario":"word-splitting on a path with spaces"}],"verdict":"looks OK with one nit"},"modelUsage":{"claude-sonnet-5[1m]":{}}}
JSON
        exit 0
        ;;
    malformed)
        cat <<'JSON'
{"type":"result","is_error":false,"result":"{}","structured_output":{"not_findings":"oops"},"modelUsage":{}}
JSON
        exit 0
        ;;
    authfail)
        echo "fake claude: Invalid API key. Run 'claude login' to authenticate." >&2
        exit 1
        ;;
    apierror)
        # mirrors a real observed shape: nonzero exit AND is_error:true in
        # the JSON envelope, with the error explanation in .result rather
        # than on stderr at all.
        cat <<'JSON'
{"type":"result","is_error":true,"api_error_status":404,"result":"There's an issue with the selected model. It may not exist or you may not have access to it."}
JSON
        exit 1
        ;;
esac
EOF
chmod +x "$FAKECLAUDE_DIR/claude"

NOBIN="/usr/bin:/bin"

DIFFFILE="$(mktemp)"
cat >"$DIFFFILE" <<'DIFF'
diff --git a/foo.sh b/foo.sh
--- a/foo.sh
+++ b/foo.sh
@@ -10,3 +10,3 @@
-echo $x
+echo "$x"
DIFF

# --- valid schema-conforming .structured_output: rendered findings under the required label ---
ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=valid CLAUDE_ARGLOG="$ARGLOG" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "valid: exits 0" "rc=0" "$out"
check "valid: rendered under required label" "External review — Claude" "$out"
check "valid: finding file shown" "foo.sh" "$out"
check "valid: finding summary shown" "unquoted variable" "$out"
check "valid: finding failure scenario shown" "word-splitting on a path with spaces" "$out"
check "valid: verdict shown" "looks OK with one nit" "$out"
check "valid: invocation used --permission-mode" "--permission-mode" "$(cat "$ARGLOG")"
check "valid: invocation used plan mode" "ARG<<<plan>>>" "$(cat "$ARGLOG")"
# shellcheck disable=SC2016  # intentional: matching a literal $x in the fixture diff, not expanding it
check "valid: diff text embedded in the prompt sent to claude" 'echo "$x"' "$(cat "$ARGLOG")"
check_absent "valid: permission mode is never acceptEdits" "acceptEdits" "$(cat "$ARGLOG")"
check_absent "valid: permission mode is never bypassPermissions" "bypassPermissions" "$(cat "$ARGLOG")"
check_absent "valid: permission mode is never default" "ARG<<<default>>>" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- --json-schema receives inline JSON content, not a file path ---
ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=valid CLAUDE_ARGLOG="$ARGLOG" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "schema: --json-schema flag passed" "--json-schema" "$(cat "$ARGLOG")"
check "schema: schema content (title) passed inline" "peer-review-findings" "$(cat "$ARGLOG")"
check_absent "schema: schema arg is not a bare file path" "ARG<<<$PLUGIN/schema/peer-review-findings.json>>>" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- --output-format json always passed ---
ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=valid CLAUDE_ARGLOG="$ARGLOG" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "output-format: --output-format flag passed" "--output-format" "$(cat "$ARGLOG")"
check "output-format: json value passed" "ARG<<<json>>>" "$(cat "$ARGLOG")"
check "output-format: -p print mode passed" "ARG<<<-p>>>" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- malformed/non-conforming .structured_output: raw output verbatim + parse-failure note, exit 0, no crash ---
ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=malformed CLAUDE_ARGLOG="$ARGLOG" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "malformed: exits 0 (a review happened)" "rc=0" "$out"
check "malformed: notes structured parsing failed" "structured parsing failed" "$out"
check "malformed: raw claude output shown verbatim" "not_findings" "$out"
check "malformed: invocation still used --permission-mode plan" "--permission-mode" "$(cat "$ARGLOG")"
check_absent "malformed: permission mode is never acceptEdits" "acceptEdits" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- auth failure: claude stderr surfaced verbatim, nonzero exit, never prompts for a key ---
ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=authfail CLAUDE_ARGLOG="$ARGLOG" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check_absent "authfail: does not exit 0" "rc=0" "$out"
check "authfail: claude stderr surfaced verbatim" "Invalid API key. Run 'claude login' to authenticate." "$out"
check_absent "authfail: never itself prompts for an API key" "Please enter your API key" "$out"
check "authfail: invocation still used --permission-mode plan" "--permission-mode" "$(cat "$ARGLOG")"
check_absent "authfail: permission mode is never acceptEdits" "acceptEdits" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- API-level error surfaced only inside the JSON envelope (is_error:true, empty real stderr) ---
ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=apierror CLAUDE_ARGLOG="$ARGLOG" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check_absent "apierror: does not exit 0" "rc=0" "$out"
check "apierror: envelope's result message surfaced verbatim" "issue with the selected model" "$out"
rm -f "$ARGLOG"

# --- --model <slug>: passed through to claude, --permission-mode plan still unconditional ---
ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=valid CLAUDE_ARGLOG="$ARGLOG" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" --model claude-opus-4-8 "$DIFFFILE" 2>&1; echo "rc=$?")"
check "--model: exits 0" "rc=0" "$out"
check "--model: --model flag passed to claude" "--model" "$(cat "$ARGLOG")"
check "--model: chosen slug passed to claude" "ARG<<<claude-opus-4-8>>>" "$(cat "$ARGLOG")"
check "--model: invocation still used --permission-mode plan" "--permission-mode" "$(cat "$ARGLOG")"
check_absent "--model: permission mode is never acceptEdits" "acceptEdits" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- no --model: no --model flag passed (preserves claude's own default) ---
ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=valid CLAUDE_ARGLOG="$ARGLOG" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "no --model: exits 0" "rc=0" "$out"
check_absent "no --model: no --model flag passed to claude" "ARG<<<--model>>>" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- label override: default, --label flag, CLAUDE_REVIEW_LABEL env var, and flag-wins-over-env ---
ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=valid CLAUDE_ARGLOG="$ARGLOG" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "label default: uses the default label" "External review — Claude" "$out"
rm -f "$ARGLOG"

ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=valid CLAUDE_ARGLOG="$ARGLOG" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" --label "External review — Peer Reviewer (claude)" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "label --label flag: uses the given label" "External review — Peer Reviewer (claude)" "$out"
rm -f "$ARGLOG"

ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=valid CLAUDE_ARGLOG="$ARGLOG" CLAUDE_REVIEW_LABEL="External review — Peer Reviewer (claude)" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "label CLAUDE_REVIEW_LABEL env: uses the env label" "External review — Peer Reviewer (claude)" "$out"
rm -f "$ARGLOG"

ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=valid CLAUDE_ARGLOG="$ARGLOG" CLAUDE_REVIEW_LABEL="External review — from env" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" --label "External review — from flag" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "label both set: --label flag wins over CLAUDE_REVIEW_LABEL" "External review — from flag" "$out"
check_absent "label both set: env label not used" "External review — from env" "$out"
rm -f "$ARGLOG"

# --- label override also applies to the raw-fallback rendering path (malformed structured_output) ---
ARGLOG="$(mktemp)"
out="$(CLAUDE_FIXTURE=malformed CLAUDE_ARGLOG="$ARGLOG" PATH="$FAKECLAUDE_DIR:$NOBIN" bash "$SCRIPT" --label "External review — Peer Reviewer (claude)" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "label on raw fallback: overridden label used" "External review — Peer Reviewer (claude)" "$out"
rm -f "$ARGLOG"

# --- --model missing its argument -> usage error, exit 2 ---
out="$(bash "$SCRIPT" --model 2>&1; echo "rc=$?")"
check "--model missing arg: exits 2" "rc=2" "$out"
check "--model missing arg: usage error shown" "requires a" "$out"

# --- --model swallowing a following flag as its value -> usage error, exit 2 ---
out="$(bash "$SCRIPT" --model --label custom "$DIFFFILE" 2>&1; echo "rc=$?")"
check "--model followed by --label: exits 2" "rc=2" "$out"
check "--model followed by --label: usage error shown" "requires a" "$out"

# --- claude missing from PATH -> exit 2, install instructions, no invocation attempted ---
out="$(PATH="$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check_absent "missing claude: does not exit 0" "rc=0" "$out"
check "missing claude: mentions claude" "claude" "$out"

rm -f "$DIFFFILE"
rm -rf "$FAKECLAUDE_DIR"
