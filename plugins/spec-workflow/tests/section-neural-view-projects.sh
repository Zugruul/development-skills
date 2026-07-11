#!/usr/bin/env bash
# section-neural-view-projects.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== neural-view /projects (per-repo board state via THIS plugin's board.sh, cached) =="
NVP_REPO="$(mktemp -d)"
mkdir -p "$NVP_REPO/.claude"
cp "$FIX/valid.project.yaml" "$NVP_REPO/.claude/project.yaml"
NVP_NOBOARD="$(mktemp -d)"   # discovered repo, no .claude/project.yaml at all -> must be omitted
NVP_GH="$(mktemp -d)"
_nvpscan_empty="$(mktemp -d)"   # empty scan base -- real ~/Development repos must never leak into these tests
export GH_FAILURES="$FIX/gh-failures"  # sourced by the fake gh script below (issue #91)
cat >"$NVP_GH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
    "project item-list")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "$*" >>"$FAKE_GH_LOG"
        if [[ -n "${FAKE_GH_CALLCOUNT:-}" ]]; then
            n=$(( $(cat "$FAKE_GH_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
            echo "$n" >"$FAKE_GH_CALLCOUNT"
        fi
        if [[ "${FAKE_GH_FAIL:-0}" == "1" ]]; then
            # structural placeholder, not a captured gh error: this models "any
            # plain gh failure" to exercise the classifier's generic
            # last-meaningful-line fallback, independent of any specific real
            # gh error string -- there's nothing to source from the corpus.
            echo "fake gh: item-list boom" >&2
            exit 1
        fi
        if [[ "${FAKE_GH_RATELIMIT_FAIL:-0}" == "1" ]]; then
            awk 'f{print} /^$/{f=1}' "$GH_FAILURES/rate-limit-honest-user-id.txt" >&2
            exit 1
        fi
        if [[ "${FAKE_GH_HANG:-0}" == "1" ]]; then
            sleep "${FAKE_GH_HANG_SECS:-3}"
        fi
        items='[
  {"id":"ITEM_1","content":{"number":1,"title":"Add widget"},"title":"Add widget","status":"In progress","priority":"P0"},
  {"id":"ITEM_2","content":{"number":2,"title":"Fix bug"},"title":"Fix bug","status":"In review","priority":"P1"},
  {"id":"ITEM_3","content":{"number":3,"title":"Idea"},"title":"Idea","status":"Backlog","priority":"P2"}
]'
        if [[ -n "${FAKE_GH_XSS_TITLE:-}" ]]; then
            extra="$(python3 -c 'import json,sys; print(json.dumps({"id":"ITEM_9","content":{"number":9,"title":sys.argv[1]},"title":sys.argv[1],"status":"In progress","priority":"P0"}))' "${FAKE_GH_XSS_TITLE}")"
            items="$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); a.append(json.loads(sys.argv[2])); print(json.dumps(a))' "$items" "$extra")"
        fi
        python3 -c 'import json,sys; print(json.dumps({"items": json.loads(sys.argv[1])}))' "$items"
        ;;
    "api rate_limit")
        # board.sh's board-queue.sh asks this REST endpoint for the authoritative
        # reset time (works even when GraphQL itself is what's exhausted). NORESET
        # simulates that endpoint being unavailable too, so board.sh falls back to
        # "unknown" -- which the classifier below renders as "(resets soon)".
        if [[ "${FAKE_GH_RATELIMIT_NORESET:-0}" == "1" ]]; then
            echo "fake gh: api rate_limit unavailable" >&2
            exit 1
        fi
        epoch="$(python3 -c 'import calendar, datetime, sys
print(calendar.timegm(datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").timetuple()))' "${FAKE_GH_RATELIMIT_RESET:-2026-07-08T04:11:00Z}")"
        echo "{\"rate\":{\"limit\":5000,\"remaining\":0,\"reset\":$epoch}}"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$NVP_GH/gh"
NV="$PLUGIN/scripts/neural-view.py"
_nvpstate="$(mktemp -d)"

# scenario 1: happy path + within-TTL caching (call-count observed via shim log)
LOG1="$(mktemp)"; CC1="$(mktemp)"
export NEURAL_VIEW_STATE="$_nvpstate" NEURAL_VIEW_PROJECTS_TTL=100 NEURAL_VIEW_SCAN="$_nvpscan_empty"
lifecycle_start "neural-view starts (projects fixture)" NEURAL_VIEW_PORT 'PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG1" FAKE_GH_CALLCOUNT="$CC1" python3 "$NV" start --dir "$NVP_REPO"'
body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/projects")"
_nvprepo="$(basename "$NVP_REPO")"
check "projects: repo key present" "\"$_nvprepo\"" "$body"
check "projects: ok true" '"ok": true' "$body"
check "projects: status counts" '"In progress": 1' "$body"
check "projects: in-progress titles" '"Add widget"' "$body"
check "projects: in-review titles" '"Fix bug"' "$body"
curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/projects" >/dev/null    # second call, well within TTL
n1="$(cat "$CC1")"
check "projects: second call within TTL does not re-invoke board.sh" "1" "$n1"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_PROJECTS_TTL

# scenario 2: TTL expiry -> a call after the TTL DOES re-invoke
LOG2="$(mktemp)"; CC2="$(mktemp)"
export NEURAL_VIEW_PROJECTS_TTL=1 NEURAL_VIEW_SCAN="$_nvpscan_empty"
lifecycle_start "neural-view starts (TTL-expiry scenario)" NEURAL_VIEW_PORT 'PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG2" FAKE_GH_CALLCOUNT="$CC2" python3 "$NV" start --dir "$NVP_REPO"'
curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/projects" >/dev/null
sleep 1.3
curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/projects" >/dev/null
n2="$(cat "$CC2")"
if [[ "$n2" -ge 2 ]]; then echo "ok   projects: a call after TTL expiry re-invokes board.sh"
else echo "FAIL projects: expected >=2 board.sh invocations after TTL expiry, got $n2"; fails=$((fails + 1)); fi
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_PROJECTS_TTL

# scenario 3: gh/network failure degrades gracefully (ok:false, no crash)
LOG3="$(mktemp)"; CC3="$(mktemp)"
lifecycle_start "neural-view starts (failure scenario)" NEURAL_VIEW_PORT 'PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG3" FAKE_GH_CALLCOUNT="$CC3" FAKE_GH_FAIL=1 python3 "$NV" start --dir "$NVP_REPO"'
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/projects")"
check "projects: failure still returns 200 (degraded, not a crash)" "200" "$code"
body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/projects")"
check "projects: gh failure reported as ok:false" '"ok": false' "$body"
check "projects: gh failure carries an error message" '"error"' "$body"
python3 "$NV" stop >/dev/null

# scenario 3b: a plain (non-rate-limit) gh failure. board.sh's `list` gates on gh's
# own exit code (SPEC #77) before it ever reaches `json.load`, so this no longer
# raises a Python traceback -- board.sh reports the honest gh error directly, and
# the classifier's fallback (last non-blank, ANSI-stripped line) renders it as-is.
LOG3B="$(mktemp)"; CC3B="$(mktemp)"
lifecycle_start "neural-view starts (plain gh-failure scenario)" NEURAL_VIEW_PORT 'PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG3B" FAKE_GH_CALLCOUNT="$CC3B" FAKE_GH_FAIL=1 FORCE_COLOR=1 python3 "$NV" start --dir "$NVP_REPO"'
body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/projects")"
check "projects: plain gh-failure reported as ok:false" '"ok": false' "$body"
check "projects: plain gh-failure keeps the last meaningful line, no traceback" 'board unavailable: fake gh: item-list boom' "$body"
check_absent "projects: plain gh-failure error contains no raw ESC byte" $'\x1b[' "$body"
check_absent "projects: plain gh-failure error contains no literal SGR code" '[1;35m' "$body"
check_absent "projects: plain gh-failure never leaks a JSONDecodeError traceback" 'JSONDecodeError' "$body"
python3 "$NV" stop >/dev/null

# scenario 3b': regression fixture for the classifier's ANSI-stripping/last-line
# fallback against a REAL colorized Python 3.13 JSONDecodeError traceback (issue
# #91) -- the exact bytes board.sh's OLD ungated pipe (pre-#77) used to leak into
# the HUD (see tests/fixtures/gh-failures/jsondecodeerror-ansi-traceback-py313.txt
# for full provenance). #77 removed the code path that reproduces this live, so
# this calls the classifier directly rather than driving it through board.sh --
# kept as regression insurance for the ANSI-stripping logic itself.
_gh_failures_corpus="$FIX/gh-failures"
_classified="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("neural_view", sys.argv[2])
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)
raw = open(sys.argv[1]).read()
payload = raw.split("\n\n", 1)[1]
print(nv._classify_board_failure(payload))
' "$_gh_failures_corpus/jsondecodeerror-ansi-traceback-py313.txt" "$NV")"
check "projects: classifier renders the real py3.13 ANSI JSONDecodeError traceback (no leaked ESC bytes)" 'board unavailable: json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)' "$_classified"
check_absent "projects: classified real traceback contains no raw ESC byte" $'\x1b[' "$_classified"

# scenario 3c/3d: a rate-limit failure gets board.sh's own "RATE-LIMITED until
# <reset>" line (board.sh asks `gh api rate_limit` for the authoritative reset
# time -- SPEC #77), which the classifier renders as a friendly, specific message.
LOG3C="$(mktemp)"; CC3C="$(mktemp)"
lifecycle_start "neural-view starts (rate-limit scenario, with reset time)" NEURAL_VIEW_PORT 'PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG3C" FAKE_GH_CALLCOUNT="$CC3C" FAKE_GH_RATELIMIT_FAIL=1 FAKE_GH_RATELIMIT_RESET="2026-07-08T04:11:00Z" FORCE_COLOR=1 python3 "$NV" start --dir "$NVP_REPO"'
body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/projects")"
check "projects: rate-limit failure reported as ok:false" '"ok": false' "$body"
check "projects: rate-limit failure names GitHub API rate limit" 'board unavailable: GitHub API rate limit' "$body"
check "projects: rate-limit failure includes the reset time" '04:11' "$body"
check_absent "projects: rate-limit failure does not leak the trailing traceback" 'JSONDecodeError' "$body"
python3 "$NV" stop >/dev/null

# scenario 3d: a rate-limit failure with no reset time in the text still gets
# the friendly message, with a graceful fallback instead of a missing/blank time.
LOG3D="$(mktemp)"; CC3D="$(mktemp)"
lifecycle_start "neural-view starts (rate-limit scenario, no reset time)" NEURAL_VIEW_PORT 'PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG3D" FAKE_GH_CALLCOUNT="$CC3D" FAKE_GH_RATELIMIT_FAIL=1 FAKE_GH_RATELIMIT_NORESET=1 FORCE_COLOR=1 python3 "$NV" start --dir "$NVP_REPO"'
body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/projects")"
check "projects: rate-limit failure (no reset time) reported as ok:false" '"ok": false' "$body"
check "projects: rate-limit failure (no reset time) falls back gracefully" 'board unavailable: GitHub API rate limit (resets soon)' "$body"
python3 "$NV" stop >/dev/null

# scenario 4: a discovered repo with no .claude/project.yaml is omitted entirely
lifecycle_start "neural-view starts (no-board repo)" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$NVP_NOBOARD"'
body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/projects")"
check "projects: repo without project.yaml is omitted" "{}" "$body"
python3 "$NV" stop >/dev/null

# scenario 5b: a board task title carrying an XSS payload (attacker-controlled --
# anyone who can title a GitHub issue) is passed through /projects RAW, unescaped.
# The server is not the defense here; this pins that fact down so the client-side
# escapeHtml() (checked above, in the template-contract block) stays the only guard.
LOG5B="$(mktemp)"; CC5B="$(mktemp)"
# shellcheck disable=SC2034  # consumed via eval inside the lifecycle_start command-string below
XSS_TITLE='Fix bug" onmouseover="alert(document.cookie)<script>alert(1)</script>'
lifecycle_start "neural-view starts (XSS-title fixture)" NEURAL_VIEW_PORT 'PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG5B" FAKE_GH_CALLCOUNT="$CC5B" FAKE_GH_XSS_TITLE="$XSS_TITLE" python3 "$NV" start --dir "$NVP_REPO"'
body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/projects")"
check "projects: server passes an attacker-controlled title through unescaped (client must escape it)" 'onmouseover=' "$body"
check "projects: server does not strip/encode the embedded <script> tag either" '<script>alert(1)</script>' "$body"
python3 "$NV" stop >/dev/null

# scenario 5: a hanging board.sh call never blocks another route (/graph)
LOG5="$(mktemp)"; CC5="$(mktemp)"
lifecycle_start "neural-view starts (hang scenario)" NEURAL_VIEW_PORT 'PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG5" FAKE_GH_CALLCOUNT="$CC5" FAKE_GH_HANG=1 FAKE_GH_HANG_SECS=4 python3 "$NV" start --dir "$NVP_REPO"'
curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/projects" >/tmp/nv-hang-out.$$ &
_hangpid=$!
sleep 0.5   # let the hanging /projects request actually start (past the fake gh's sleep having begun)
t0=$(date +%s)
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")"
t1=$(date +%s)
check "projects: sibling route (/graph) still responds while board.sh hangs" "200" "$code"
elapsed=$(( t1 - t0 ))
if [[ "$elapsed" -le 2 ]]; then echo "ok   projects: /graph was not blocked by the hanging board.sh call (${elapsed}s)"
else echo "FAIL projects: /graph took ${elapsed}s while board.sh hung -- looks blocked"; fails=$((fails + 1)); fi
wait "$_hangpid" 2>/dev/null || true
rm -f /tmp/nv-hang-out.$$
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$NVP_REPO" "$NVP_NOBOARD" "$NVP_GH" "$_nvpstate" "$_nvpscan_empty" "$LOG1" "$CC1" "$LOG2" "$CC2" "$LOG3" "$CC3" "$LOG3B" "$CC3B" "$LOG3C" "$CC3C" "$LOG3D" "$CC3D" "$LOG5" "$CC5" "$LOG5B" "$CC5B"

