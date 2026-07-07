#!/usr/bin/env bash
# section-neural-view-projects.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
echo "== neural-view /projects (per-repo board state via THIS plugin's board.sh, cached) =="
NVP_REPO="$(mktemp -d)"
mkdir -p "$NVP_REPO/.claude"
cp "$FIX/valid.project.yaml" "$NVP_REPO/.claude/project.yaml"
NVP_NOBOARD="$(mktemp -d)"   # discovered repo, no .claude/project.yaml at all -> must be omitted
NVP_GH="$(mktemp -d)"
_nvpscan_empty="$(mktemp -d)"   # empty scan base -- real ~/Development repos must never leak into these tests
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
            echo "fake gh: item-list boom" >&2
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
rm -rf "$NVP_REPO" "$NVP_NOBOARD" "$NVP_GH" "$_nvpstate" "$_nvpscan_empty" "$LOG1" "$CC1" "$LOG2" "$CC2" "$LOG3" "$CC3" "$LOG5" "$CC5" "$LOG5B" "$CC5B"

