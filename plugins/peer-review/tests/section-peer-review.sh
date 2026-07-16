#!/usr/bin/env bash
# section-peer-review.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/fails before
# sourcing this file.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/peer-review/tests/run-tests.sh" >&2; exit 2; }
echo "== peer-review.sh (PRV-002) =="

SCRIPT="$PLUGIN/scripts/peer-review.sh"

# FAKECODEX_DIR: a stub `codex` binary on PATH whose behavior is driven by
# $CODEX_FIXTURE (valid|malformed|authfail) and which logs every argument it
# was invoked with to $CODEX_ARGLOG, so tests can assert on the exact
# invocation (in particular that --sandbox read-only is always present and
# that the diff text was embedded in the prompt) without ever running a real
# codex binary (no network, deterministic, offline).
FAKECODEX_DIR="$(mktemp -d)"
cat >"$FAKECODEX_DIR/codex" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
{
    printf 'ARGC=%s\n' "$#"
    for a in "$@"; do printf 'ARG<<<%s>>>\n' "$a"; done
} >>"$CODEX_ARGLOG"

case "${CODEX_FIXTURE:-valid}" in
    valid)
        cat <<'JSON'
{"findings":[{"file":"foo.sh","line":12,"severity":"warn","summary":"unquoted variable","failure_scenario":"word-splitting on a path with spaces"}],"verdict":"looks OK with one nit"}
JSON
        exit 0
        ;;
    malformed)
        echo 'this is not { valid json at all'
        exit 0
        ;;
    authfail)
        echo "fake codex: auth error: not logged in, run 'codex login'" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$FAKECODEX_DIR/codex"

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

# --- valid JSON matching the schema: rendered findings under the required label ---
ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=valid CODEX_ARGLOG="$ARGLOG" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "valid: exits 0" "rc=0" "$out"
check "valid: rendered under required label" "External review — codex" "$out"
check "valid: finding file shown" "foo.sh" "$out"
check "valid: finding summary shown" "unquoted variable" "$out"
check "valid: finding failure scenario shown" "word-splitting on a path with spaces" "$out"
check "valid: verdict shown" "looks OK with one nit" "$out"
check "valid: invocation used --sandbox read-only" "read-only" "$(cat "$ARGLOG")"
check "valid: invocation used --sandbox read-only (flag itself)" "--sandbox" "$(cat "$ARGLOG")"
# shellcheck disable=SC2016  # intentional: matching a literal $x in the fixture diff, not expanding it
check "valid: diff text embedded in the prompt sent to codex" 'echo "$x"' "$(cat "$ARGLOG")"
check_absent "valid: sandbox is never workspace-write" "workspace-write" "$(cat "$ARGLOG")"
check_absent "valid: sandbox is never danger-full-access" "danger-full-access" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- malformed JSON: raw output verbatim + parse-failure note, exit 0, no crash ---
ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=malformed CODEX_ARGLOG="$ARGLOG" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "malformed: exits 0 (a review happened)" "rc=0" "$out"
check "malformed: notes structured parsing failed" "structured parsing failed" "$out"
check "malformed: raw codex output shown verbatim" "this is not { valid json at all" "$out"
check "malformed: invocation still used --sandbox read-only" "--sandbox" "$(cat "$ARGLOG")"
check "malformed: invocation still used read-only" "read-only" "$(cat "$ARGLOG")"
check_absent "malformed: sandbox is never workspace-write" "workspace-write" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- auth failure: codex stderr surfaced verbatim, nonzero exit, never prompts for a key ---
ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=authfail CODEX_ARGLOG="$ARGLOG" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check_absent "authfail: does not exit 0" "rc=0" "$out"
check "authfail: codex stderr surfaced verbatim" "fake codex: auth error: not logged in, run 'codex login'" "$out"
check_absent "authfail: never prompts for an API key" "API key" "$out"
check_absent "authfail: never prompts for an API key (alt phrasing)" "api key" "$out"
check "authfail: invocation still used --sandbox read-only" "--sandbox" "$(cat "$ARGLOG")"
check_absent "authfail: sandbox is never workspace-write" "workspace-write" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- --output-schema is always passed and points at the shipped schema file ---
ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=valid CODEX_ARGLOG="$ARGLOG" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "schema: --output-schema flag passed" "--output-schema" "$(cat "$ARGLOG")"
check "schema: schema file path passed" "peer-review-findings.json" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- label override: default, --label flag, PEER_REVIEW_LABEL env var, and flag-wins-over-env ---
ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=valid CODEX_ARGLOG="$ARGLOG" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "label default: uses the default label" "External review — codex" "$out"
rm -f "$ARGLOG"

ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=valid CODEX_ARGLOG="$ARGLOG" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" --label "External review — Peer Reviewer (codex)" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "label --label flag: uses the given label" "External review — Peer Reviewer (codex)" "$out"
rm -f "$ARGLOG"

ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=valid CODEX_ARGLOG="$ARGLOG" PEER_REVIEW_LABEL="External review — Peer Reviewer (codex)" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "label PEER_REVIEW_LABEL env: uses the env label" "External review — Peer Reviewer (codex)" "$out"
rm -f "$ARGLOG"

ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=valid CODEX_ARGLOG="$ARGLOG" PEER_REVIEW_LABEL="External review — from env" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" --label "External review — from flag" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "label both set: --label flag wins over PEER_REVIEW_LABEL" "External review — from flag" "$out"
check_absent "label both set: env label not used" "External review — from env" "$out"
rm -f "$ARGLOG"

# --- label override also applies to the raw-fallback rendering path (malformed JSON) ---
ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=malformed CODEX_ARGLOG="$ARGLOG" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" --label "External review — Peer Reviewer (codex)" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "label on raw fallback: overridden label used" "External review — Peer Reviewer (codex)" "$out"
rm -f "$ARGLOG"

# --- --model: no --model given -> no -m flag passed (preserves default codex-chosen model) ---
ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=valid CODEX_ARGLOG="$ARGLOG" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "no --model: exits 0" "rc=0" "$out"
check_absent "no --model: no -m flag passed to codex" "ARG<<<-m>>>" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- --model <slug>: -m <slug> passed to codex, --sandbox read-only still unconditional ---
ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=valid CODEX_ARGLOG="$ARGLOG" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" --model gpt-5.6-terra "$DIFFFILE" 2>&1; echo "rc=$?")"
check "--model: exits 0" "rc=0" "$out"
check "--model: -m flag passed to codex" "ARG<<<-m>>>" "$(cat "$ARGLOG")"
check "--model: chosen slug passed to codex" "ARG<<<gpt-5.6-terra>>>" "$(cat "$ARGLOG")"
check "--model: invocation still used --sandbox read-only" "--sandbox" "$(cat "$ARGLOG")"
check "--model: invocation still used read-only" "read-only" "$(cat "$ARGLOG")"
check_absent "--model: sandbox is never workspace-write" "workspace-write" "$(cat "$ARGLOG")"
check_absent "--model: sandbox is never danger-full-access" "danger-full-access" "$(cat "$ARGLOG")"
rm -f "$ARGLOG"

# --- --model combined with --label: both apply independently ---
ARGLOG="$(mktemp)"
out="$(CODEX_FIXTURE=valid CODEX_ARGLOG="$ARGLOG" PATH="$FAKECODEX_DIR:$NOBIN" bash "$SCRIPT" --model gpt-5.6-luna --label "External review — Peer Reviewer (codex)" "$DIFFFILE" 2>&1; echo "rc=$?")"
check "--model + --label: exits 0" "rc=0" "$out"
check "--model + --label: model slug passed to codex" "ARG<<<gpt-5.6-luna>>>" "$(cat "$ARGLOG")"
check "--model + --label: label applied" "External review — Peer Reviewer (codex)" "$out"
rm -f "$ARGLOG"

# --- --model missing its argument -> usage error, exit 2 ---
out="$(bash "$SCRIPT" --model 2>&1; echo "rc=$?")"
check "--model missing arg: exits 2" "rc=2" "$out"
check "--model missing arg: usage error shown" "requires a" "$out"

# --- --model swallowing a following flag as its value -> usage error, exit 2 ---
out="$(bash "$SCRIPT" --model --label custom "$DIFFFILE" 2>&1; echo "rc=$?")"
check "--model followed by --label: exits 2" "rc=2" "$out"
check "--model followed by --label: usage error shown" "requires a" "$out"

rm -f "$DIFFFILE"
rm -rf "$FAKECODEX_DIR"
