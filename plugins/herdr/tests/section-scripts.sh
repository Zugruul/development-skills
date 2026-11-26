#!/usr/bin/env bash
# section-scripts.sh -- sourced by run-tests.sh; do not run standalone.
# The three herdr scripts against the stub herdr: check (inside Herdr, Codex fallback),
# start (retry on a busy pane, name rules, blocked startup) and listen.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr/tests/run-tests.sh" >&2; exit 2; }

CT_TMP="$(mktemp -d)"
SC="$PLUGIN/scripts"
run() { local s="$1"; shift; env -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID PATH="$FIX/stub-herdr:$PATH" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_STUB_DIR="$CT_TMP" HERDR_CTL_INTERVAL=0.05 bash "$SC/$s.sh" "$@"; }
codex_run() { local s="$1"; shift; env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID PATH="$FIX/stub-herdr:$PATH" HERDR_ENV=0 CODEX_SESSION_ID=codex-test HERDR_STUB_DIR="$CT_TMP" HERDR_CTL_INTERVAL=0.05 bash "$SC/$s.sh" "$@"; }
ct_state() { printf '%s' "$1" >"$CT_TMP/state.json"; : >"$CT_TMP/calls.log"; }
ct_calls() { grep -c -- "$1" "$CT_TMP/calls.log" || true; }
ct_agent() { # name status [extra json fields]
    printf '"%s":{"name":"%s","pane_id":"w1:p%s","tab_id":"w1:t1","workspace_id":"w1","agent":"claude","agent_status":"%s","state_change_seq":1,"cwd":"/w"%s}' "$1" "$1" "$1" "$2" "${3:-}"
}

echo "== scripts: check =="
out="$(HERDR_ENV=0 env -u CODEX_SESSION_ID PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$CT_TMP" bash "$SC/check.sh" 2>&1)"; rc=$?
check_rc "check outside Herdr exits 2" 2 "$rc"
check "check outside Herdr says why" "not running inside a Herdr pane" "$out"
out="$(HERDR_ENV=0 env -u CODEX_SESSION_ID PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$CT_TMP" bash "$SC/listen.sh" dev 2>&1)"; rc=$?
check_rc "every script refuses outside Herdr" 2 "$rc"
out="$(PATH="/usr/bin:/bin" HERDR_ENV=1 bash "$SC/check.sh" 2>&1)"; rc=$?
check_rc "check without herdr on PATH exits 2" 2 "$rc"
ct_state "{\"agents\":{$(ct_agent dev idle)}}"
out="$(run check 2>&1)"; rc=$?
check_rc "check inside Herdr succeeds" 0 "$rc"
check "check prints the version and pane" "HERDR OK version=0.0.0-stub" "$out"
CT_CWD="$(pwd -P)"
ct_state "{\"agents\":{\"codex\":{\"name\":\"codex-herdr-fix\",\"pane_id\":\"w1:p1\",\"tab_id\":\"w1:t1\",\"workspace_id\":\"w1\",\"agent\":\"codex\",\"agent_status\":\"blocked\",\"cwd\":\"$CT_CWD\",\"foreground_cwd\":\"$CT_CWD\"}}}"
out="$(codex_run check 2>&1)"; rc=$?
check_rc "Codex session with a matching live agent is accepted" 0 "$rc"
check "Codex attachment uses the matched pane" "pane=w1:p1" "$out"
ct_state "{\"agents\":{\"codex\":{\"agent\":\"codex\",\"cwd\":\"$CT_CWD\"}}}"
out="$(codex_run check 2>&1)"; rc=$?
check_rc "Codex session without a safe foreground match is refused" 2 "$rc"
check "Codex refusal explains the missing unique match" "no unique live Herdr Codex agent matches" "$out"

echo "== scripts: start =="
ct_state '{"busy":3}'
out="$(run start --name dev --kind claude --pane w1:p2 2>&1)"; rc=$?
check_rc "start retries while the pane is busy, then succeeds" 0 "$rc"
check "start reports the agent ready" "AGENT READY name=dev pane=w1:p2" "$out"
check "start needed four attempts" "attempts=4" "$out"
ct_state '{"busy":99}'
out="$(run start --name dev --kind claude --pane w1:p2 --timeout 1 2>&1)"; rc=$?
check_rc "start gives up on a pane that never frees" 1 "$rc"
check "start names the herdr error" "agent_pane_busy" "$out"
ct_state '{"start":"not_ready"}'
out="$(run start --name dev --kind claude --pane w1:p2 2>&1)"; rc=$?
check_rc "agent blocked at startup exits 3" 3 "$rc"
check "blocked startup shows the dialog" "Do you trust this folder?" "$out"
check "blocked startup reads the visible screen" "SCREEN[visible]" "$out"
check "blocked startup hands the answer to the user" "do not answer it yourself" "$out"
check_rc "blocked startup is not retried" 1 "$(ct_calls 'agent start')"
ct_state "{\"agents\":{$(ct_agent dev idle)}}"
out="$(run start --name dev --kind claude --pane w1:p2 2>&1)"; rc=$?
check_rc "start refuses a name already in use" 6 "$rc"
check "start says the name is taken" "NAME TAKEN" "$out"
check_rc "a refused name never reaches herdr agent start" 0 "$(ct_calls 'agent start')"
for bad in Dev 1dev "dev agent" dev.x "$(printf 'a%.0s' $(seq 33))"; do
    out="$(run start --name "$bad" --kind claude --pane w1:p2 2>&1)"; rc=$?
    check_rc "invalid name '$bad' is refused" 6 "$rc"
done
ct_state '{}'
out="$(run start --name "$(printf 'a%.0s' $(seq 32))" --kind claude --pane w1:p2 2>&1)"; rc=$?
check_rc "32-character name is accepted" 0 "$rc"
ct_state '{}'
run start --name dev --kind codex --pane w1:p2 -- --model x >/dev/null 2>&1
check "native agent arguments go after --" "agent start dev --kind codex --pane w1:p2 -- --model x" "$(cat "$CT_TMP/calls.log")"
ct_state '{}'
run start --name dev --kind codex --pane w1:p2 >/dev/null 2>&1
check_absent "no -- when there are no agent arguments" "w1:p2 --" "$(cat "$CT_TMP/calls.log")"

echo "== scripts: listen =="
ct_state "{\"agents\":{$(ct_agent dev working ',"script":["working","working","blocked"],"screen":"Proceed? y/n"'),$(ct_agent rev working)}}"
out="$(run listen dev rev --timeout 20 2>&1)"; rc=$?
check_rc "listen returns when an agent blocks" 0 "$rc"
check "listen names the blocked agent, pane and tab" "EVENT target=dev name=dev pane=w1:pdev tab=w1:t1 status=blocked" "$out"
check "listen shows the question" "Proceed? y/n" "$out"
check "listen says who is still working" "STILL WORKING: rev=working" "$out"
ct_state "{\"agents\":{$(ct_agent dev working)}}"
out="$(run listen dev --timeout 1 2>&1)"; rc=$?
check_rc "listen timeout is not an error" 0 "$rc"
check "listen timeout forbids resending" "never resend a prompt because of a timeout" "$out"
ct_state "{\"agents\":{$(ct_agent dev "done")}}"
check "listen reports a finished agent" "status=done" "$(run listen dev --timeout 1 2>&1)"
check "--only-blocked ignores a finished agent" "LISTEN TIMEOUT" "$(run listen dev --only-blocked --timeout 1 2>&1)"
ct_state '{}'
check "listen reports an agent that is gone" "status=gone" "$(run listen dev --timeout 1 2>&1)"
rm -rf "$CT_TMP"
