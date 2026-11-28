#!/usr/bin/env bash
# section-ui-hub.sh -- sourced by run-tests.sh; do not run standalone.
# The decision hub: its request handler (driven with raw HTTP on stdin, no
# port), its CLI (ask/answers/status/start/stop) against a stub socat, and its
# state dir in the main checkout when called from a linked worktree.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/ui-design/tests/run-tests.sh" >&2; exit 2; }
echo "== ui-hub (handler on stdin, CLI on a stub socat) =="

HUB="$PLUGIN/scripts/ui-hub.sh"
HANDLER="$PLUGIN/scripts/src/hub-handler.sh"
_hubtmp="$(mktemp -d)"
export UI_HUB_STATE="$_hubtmp/hub"

# req METHOD PATH [BODY] -- one raw HTTP/1.1 request through the handler.
req() {
    local body="${3:-}"
    if [[ -n "$body" ]]; then
        printf '%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
            "$1" "$2" "${#body}" "$body" | UI_HUB_STATE_DIR="$UI_HUB_STATE" bash "$HANDLER"
    else
        printf '%s %s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n' "$1" "$2" | UI_HUB_STATE_DIR="$UI_HUB_STATE" bash "$HANDLER"
    fi
}

# --- CLI without a server -------------------------------------------------
out="$(bash "$HUB" status)"; rc=$?
check "status with no server: STOPPED" "STOPPED" "$out"
check_rc "status with no server exits 1" 1 "$rc"
for d in inbox outbox html archive/asked archive/answers; do
    r=MISSING; [[ -d "$UI_HUB_STATE/$d" ]] && r=PRESENT
    check "state dir has $d/" PRESENT "$r"
done
# --- wait: what every client can run to catch the human's Send ----------------
out="$(bash "$HUB" wait --id w1 --timeout 1 2>&1)"; rc=$?
check_rc "wait with no answer ends at its timeout with exit 5" 5 "$rc"
check "and says it is still waiting" "WAITING w1" "$out"
( sleep 1; echo '{"id":"w1"}' >"$UI_HUB_STATE/outbox/w1.json" ) &
out="$(UI_HUB_WAIT_TICK=0.2 bash "$HUB" wait --id w1 --timeout 20 2>&1)"; rc=$?
wait
check_rc "wait ends with exit 0 when the answer arrives" 0 "$rc"
check "naming the round" "ANSWERED w1" "$out"
check "and leaves the answer for answers --consume" "w1" "$(bash "$HUB" answers --consume --id w1)"
echo '{"id":"w10"}' >"$UI_HUB_STATE/outbox/w10.json"
out="$(bash "$HUB" wait --id w1 --timeout 1 2>&1)"; rc=$?
check_rc "another round's answer does not end it" 5 "$rc"
rm -f "$UI_HUB_STATE/outbox/w10.json"
bash "$HUB" wait --timeout 1 >/dev/null 2>&1; rc=$?
check_rc "wait needs --id" 1 "$rc"
bash "$HUB" wait --id w1 --timeout soon >/dev/null 2>&1; rc=$?
check_rc "and a whole number of seconds" 1 "$rc"

echo '<h1>d</h1>' >"$_hubtmp/d.html"
out="$(bash "$HUB" ask d1 "T" "$_hubtmp/d.html" --blocking)"
check "hub ask" "asked 'd1'" "$out"
check "ask with no server says how to start it" "server STOPPED" "$out"
check "ask copies the page into html/" "<h1>d</h1>" "$(cat "$UI_HUB_STATE/html/d1.html" 2>/dev/null)"
card="$(cat "$UI_HUB_STATE/inbox/d1.json" 2>/dev/null)"
check "ask writes the card id" '"id": "d1"' "$card"
check "ask writes the card title" '"title": "T"' "$card"
check "ask --blocking flags the card" '"blocking": true' "$card"
check "ask stamps the card's creation time" '"created": ' "$card"
out="$(bash "$HUB" ask 2>&1)"; rc=$?
check_rc "ask without arguments exits 1" 1 "$rc"
out="$(bash "$HUB" bogus 2>&1)"; rc=$?
check_rc "an unknown command exits 1" 1 "$rc"
check "an unknown command prints the usage" "ui-hub.sh ask" "$out"

# --- handler: GET ---------------------------------------------------------
out="$(req GET /)"
check "GET / answers 200" "HTTP/1.0 200 OK" "$out"
check "GET / serves the hub page as html" "Content-Type: text/html; charset=utf-8" "$out"
check "GET / is the decision hub" "Decision hub" "$out"
check "GET /index.html is the hub page too" "Decision hub" "$(req GET /index.html)"
out="$(req GET /api/state)"
check "GET /api/state answers json" "Content-Type: application/json" "$out"
check "hub state has pending" '"id": "d1"' "$out"
check "hub state carries the hub revision" '"hubRev": "' "$out"
check "a pending card carries its page revision" '"rev": ' "$out"
check "a pending card keeps its blocking flag" '"blocking": true' "$out"
out="$(req GET '/decision/d1?rev=1')"
check "GET /decision/<id> serves the asked page" "<h1>d</h1>" "$out"
check "the decision page is html" "Content-Type: text/html; charset=utf-8" "$out"
out="$(req GET /decision/nope)"
check "an unknown decision is 404" "HTTP/1.0 404 Not Found" "$out"
check "an unknown decision says so" "unknown decision" "$out"
out="$(req GET /vendor/axe.min.js)"
check "axe-core is served to the options page" "Content-Type: text/javascript; charset=utf-8" "$out"
check "axe-core is the vendored engine" "axe" "$out"
out="$(req GET /nowhere)"
check "an unknown path is 404" "HTTP/1.0 404 Not Found" "$out"
len="$(req GET /decision/d1 | sed -n 's/^Content-Length: \([0-9]*\).*/\1/p')"
check_rc "Content-Length is the body's byte count" "$(wc -c <"$UI_HUB_STATE/html/d1.html" | tr -d ' ')" "${len:-0}"

# --- handler: POST --------------------------------------------------------
out="$(req POST /api/answer '{"id":"d1","selection":"- Use: Option A"}')"
check "hub answer accepted" '"ok": true' "$out"
r=GONE; [[ -f "$UI_HUB_STATE/inbox/d1.json" ]] && r=STILL
check "an answered card leaves the inbox" GONE "$r"
r=MISSING; [[ -f "$UI_HUB_STATE/archive/asked/d1.json" ]] && r=ARCHIVED
check "an answered card is archived" ARCHIVED "$r"
ans="$(cat "$UI_HUB_STATE/outbox/d1.json" 2>/dev/null)"
check "the answer keeps the card title" '"title": "T"' "$ans"
check "the answer carries the selection" '"selection": "- Use: Option A"' "$ans"
check "the answer is time-stamped" '"answered": ' "$ans"
out="$(req GET /api/state)"
check "an answered card shows under answered" "Use: Option A" "$out"
out="$(bash "$HUB" answers --consume)"
check "hub answer collected" "Use: Option A" "$out"
check_rc "an answer prints on one line" 1 "$(wc -l <<<"$out" | tr -d ' ')"
out="$(bash "$HUB" answers)"
check_absent "hub consume archived it" "d1" "$out"
r=MISSING; [[ -f "$UI_HUB_STATE/archive/answers/d1.json" ]] && r=ARCHIVED
check "a consumed answer lands in archive/answers" ARCHIVED "$r"

out="$(req POST /api/answer '{"id":"d1"')"
check "a malformed answer is 400" "HTTP/1.0 400 Bad Request" "$out"
check "a malformed answer names the expected shape" "expected JSON {id, selection}" "$out"
out="$(req POST /api/answer '{"id":"d1"}')"
check "an answer without a selection is 400" "HTTP/1.0 400 Bad Request" "$out"
out="$(req POST /api/elsewhere '{"id":"d1","selection":"x"}')"
check "POST to another path is 404" "HTTP/1.0 404 Not Found" "$out"

# keep: partial feedback goes to the agent, the card stays pending.
bash "$HUB" ask d2 "Two" "$_hubtmp/d.html" >/dev/null
out="$(req POST /api/answer '{"id":"d2","selection":"### A11y fixes requested","keep":true}')"
check "a kept answer is accepted" '"kept": true' "$out"
r=STILL; [[ -f "$UI_HUB_STATE/inbox/d2.json" ]] || r=GONE
check "a kept answer leaves the card pending" STILL "$r"
kept="$(cd "$UI_HUB_STATE/outbox" && ls d2.fix-*.json 2>/dev/null)"
check "a kept answer is filed as <id>.fix-<time>.json" "d2.fix-" "$kept"

# answers --id matches the id and its kept fixes, never a longer id.
bash "$HUB" ask d20 "Twenty" "$_hubtmp/d.html" >/dev/null
req POST /api/answer '{"id":"d20","selection":"- Use: Option B"}' >/dev/null
out="$(bash "$HUB" answers --id d2)"
check "answers --id includes the id's kept fix" "A11y fixes requested" "$out"
check_absent "answers --id never matches a longer id" "Option B" "$out"
out="$(bash "$HUB" answers --consume --id d2)"
out="$(bash "$HUB" answers)"
check "a scoped consume leaves other cards' answers" "Option B" "$out"
check_absent "a scoped consume took its own answer" "A11y fixes requested" "$out"

# --- lifecycle on the stub socat -----------------------------------------
export STUB_SOCAT_DIR="$_hubtmp/socat"; mkdir -p "$STUB_SOCAT_DIR"
_oldpath="$PATH"
export PATH="$FIX/stub-socat:$PATH"
port=$((20000 + RANDOM % 20000))
out="$(bash "$HUB" start --port "$port")"; rc=$?
check "hub starts" "RUNNING http://127.0.0.1:$port" "$out"
check_rc "start exits 0" 0 "$rc"
# the stub is a bash script: give it time to record and "bind" under load
for _ in $(seq 1 50); do [[ -d "$STUB_SOCAT_DIR/held-$port" ]] && break; sleep 0.1; done
args="$(cat "$STUB_SOCAT_DIR/args" 2>/dev/null)"
check "the listener binds 127.0.0.1 only" "TCP-LISTEN:$port,bind=127.0.0.1" "$args"
check "the listener forks one handler per connection" ",fork" "$args"
check "each connection runs the handler" "SYSTEM:" "$args"
out="$(bash "$HUB" status)"
check "status reports the running hub" "RUNNING http://127.0.0.1:$port pending=" "$out"
out="$(bash "$HUB" start --port "$port")"
check "start is idempotent" "RUNNING http://127.0.0.1:$port" "$out"
out="$(bash "$HUB" ask d3 "Three" "$_hubtmp/d.html")"
check "ask names the running hub" "hub: http://127.0.0.1:$port" "$out"

# #55: start must fail loudly when its port is held by someone else.
out="$(UI_HUB_STATE="$_hubtmp/other" bash "$HUB" start --port "$port" 2>&1)"; rc=$?
check_rc "hub start reports failure on an already-bound port" 1 "$rc"
check "the failure names the port" "FAILED to start on port $port" "$out"
r=NONE; [[ -s "$_hubtmp/other/pid" ]] && r=WRITTEN
check "a failed start writes no pid file" NONE "$r"

out="$(bash "$HUB" stop)"; check "hub stop confirms exit (normal path)" "stopped" "$out"
out="$(bash "$HUB" status)"; check "hub status shows STOPPED after confirmed exit" "STOPPED" "$out"
out="$(bash "$HUB" stop)"; check "stop with nothing running" "not running" "$out"

# The port defaults to $UI_HUB_PORT, then 4747.
port2=$((20000 + RANDOM % 20000)); [[ "$port2" == "$port" ]] && port2=$((port + 1))
out="$(UI_HUB_PORT="$port2" bash "$HUB" start)"
check "start honours UI_HUB_PORT" "RUNNING http://127.0.0.1:$port2" "$out"
bash "$HUB" stop >/dev/null

# #98: stop is truthful against a process that ignores SIGTERM.
_ignoretmp="$(mktemp -d)/hub"; mkdir -p "$_ignoretmp"
bash -c 'trap "" TERM; echo $$ >"$1/pid"; echo 1 >"$1/port"; for _ in $(seq 1 300); do sleep 0.1; done' _ "$_ignoretmp" &
_ignore_pid=$!
for _ in $(seq 1 30); do [[ -s "$_ignoretmp/pid" ]] && break; sleep 0.1; done
out="$(UI_HUB_STATE="$_ignoretmp" bash "$HUB" stop 2>&1)"; rc=$?
check "hub stop is truthful when target ignores SIGTERM" "still running after SIGTERM" "$out"
check_rc "hub stop exits non-zero when target survives SIGTERM" 1 "$rc"
kill -9 "$_ignore_pid" 2>/dev/null
wait "$_ignore_pid" 2>/dev/null

# Without socat, start says what is missing.
out="$(UI_HUB_SOCAT=/nonexistent/socat bash "$HUB" start --port "$port" 2>&1)"; rc=$?
check_rc "start without socat exits 1" 1 "$rc"
check "start without socat names it" "socat" "$out"

# End to end through the listener's SYSTEM command, from a plugin path with
# a space in it: the handler must still run and answer.
_spaced="$_hubtmp/with space"; mkdir -p "$_spaced"; cp -R "$PLUGIN" "$_spaced/ui-design"
printf 'GET /api/state HTTP/1.1\r\nHost: x\r\n\r\n' >"$_hubtmp/req"
out="$(STUB_SOCAT_REQUEST="$_hubtmp/req" bash "$_spaced/ui-design/scripts/ui-hub.sh" start --port "$port")"
check "start from a path with a space" "RUNNING" "$out"
for _ in $(seq 1 30); do [[ -s "$STUB_SOCAT_DIR/response" ]] && break; sleep 0.1; done
check "the listener's command runs the handler (path with a space)" '"hubRev": "' "$(cat "$STUB_SOCAT_DIR/response" 2>/dev/null)"
bash "$_spaced/ui-design/scripts/ui-hub.sh" stop >/dev/null
export PATH="$_oldpath"
unset STUB_SOCAT_DIR

# --- state dir from a linked worktree (#463) ------------------------------
# With no $UI_HUB_STATE, cards asked from two worktrees land in the MAIN
# checkout's .claude/ui-hub, never in a worktree's own .claude/.
_rr="$_hubtmp/rr"; git_repo "$_rr/main"
(cd "$_rr/main" && git worktree add -q "$_rr/wt-a" -b wt-a && git worktree add -q "$_rr/wt-b" -b wt-b) >/dev/null 2>&1
echo '<p>a</p>' >"$_rr/wt-a/card-a.html"; echo '<p>b</p>' >"$_rr/wt-b/card-b.html"
out="$(cd "$_rr/wt-a" && env -u UI_HUB_STATE bash "$HUB" ask card-a "Card A" "$_rr/wt-a/card-a.html" 2>&1)"
check "ask from worktree A: card accepted" "asked 'card-a'" "$out"
out="$(cd "$_rr/wt-b" && env -u UI_HUB_STATE bash "$HUB" ask card-b "Card B" "$_rr/wt-b/card-b.html" 2>&1)"
check "ask from sibling worktree B: card accepted" "asked 'card-b'" "$out"
r=SPLIT; [[ -f "$_rr/main/.claude/ui-hub/inbox/card-a.json" && -f "$_rr/main/.claude/ui-hub/inbox/card-b.json" ]] && r=SHARED
check "cards from two worktrees land in the main checkout's inbox" SHARED "$r"
r=CLEAN; [[ -d "$_rr/wt-a/.claude/ui-hub" || -d "$_rr/wt-b/.claude/ui-hub" ]] && r=SILOED
check "no state dir under a worktree's own .claude/" CLEAN "$r"

unset UI_HUB_STATE
rm -rf "$_hubtmp"
