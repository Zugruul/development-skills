#!/usr/bin/env bash
# section-neural-view-lifecycle.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== neural-view (lifecycle + endpoints on a scratch port, legacy single-repo mode) =="
NV="$PLUGIN/scripts/neural-view.py"
_nvroot="$(mktemp -d)"          # brains root (--dir)
_nvstate="$(mktemp -d)"         # server state (pid/port)
_nvscan_empty="$(mktemp -d)"    # empty scan base so real ~/Development repos never leak into these tests
_nvrepo="$(basename "$_nvroot")"
_nvbrain="$_nvroot/.claude/identities/dev/brain"
mkdir -p "$_nvbrain/notes"
cat >"$_nvbrain/notes/cas-retry.md" <<'EOF'
---
tags: [concurrency, cas]
paths: [packages/core]
strength: 4
graduated: false
---
Retry on CAS conflict; the loser reloads and re-applies. See [[idempotency]].
EOF
cat >"$_nvbrain/notes/idempotency.md" <<'EOF'
---
tags: [effects]
strength: 2
graduated: true
---
Deterministic ids make repeats safe.
EOF
printf '%s\n' '{"cas-retry->idempotency":{"weight":0.6,"fires":4,"last":"2026-07-06"}}' >"$_nvbrain/links.json"
printf '%s\n' '{"ts":"2026-07-06T10:00:00Z","role":"dev","event":"seed","note":"cas-retry","activation":0.8}' >"$_nvbrain/.activation.jsonl"

export NEURAL_VIEW_STATE="$_nvstate" NEURAL_VIEW_SCAN="$_nvscan_empty"
lifecycle_start "neural-view starts" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_nvroot"'
out="$(python3 "$NV" status)";                  check "neural-view status running" "RUNNING http://127.0.0.1:$NEURAL_VIEW_PORT" "$out"
check "neural-view status reports repos=1 (legacy single-dir)" "repos=1" "$out"
out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")";  check "graph has repo-qualified node id" "\"id\": \"$_nvrepo/dev/cas-retry\"" "$out"
check "graph node carries repo field" "\"repo\": \"$_nvrepo\"" "$out"
check "graph node carries strength" '"strength": 4' "$out"
check "graph node graduated flag" '"graduated": true' "$out"
check "graph has repo-qualified link edge" "\"source\": \"$_nvrepo/dev/cas-retry\"" "$out"
check "graph edge weight" '"weight": 0.6' "$out"
check "graph lists discovered repos" "\"repos\": [\"$_nvrepo\"]" "$out"
out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/note/$_nvrepo/dev/cas-retry")"
check "note renders fixture body" "the loser reloads" "$out"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/favicon.ico")"
check "favicon route no longer 404s" "200" "$code"
# vendored three.js: served same-origin, allowlisted (no path-derived fs access)
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/vendor/three.module.min.js")"
check "vendor route serves three.module.min.js (200)" "200" "$code"
ctype="$(curl -s -D - -o /dev/null "http://127.0.0.1:$NEURAL_VIEW_PORT/vendor/three.module.min.js" | tr -d '\r' | grep -i '^content-type:')"
check "vendor route content-type is javascript" "javascript" "$ctype"
# three.module.min.js's split-build companion (relatively imported as
# ./three.core.min.js) must also be served same-origin, or the module import
# 404s and the 3D scene never boots.
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/vendor/three.core.min.js")"
check "vendor route serves three.core.min.js (200)" "200" "$code"
ctype="$(curl -s -D - -o /dev/null "http://127.0.0.1:$NEURAL_VIEW_PORT/vendor/three.core.min.js" | tr -d '\r' | grep -i '^content-type:')"
check "vendor route three.core.min.js content-type is javascript" "javascript" "$ctype"
for trav in "/vendor/../scripts/config.py" "/vendor/..%2fscripts%2fconfig.py" "/vendor/../../etc/passwd" "/vendor/not-on-the-allowlist.js"; do
    code="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT$trav")"
    check "vendor route rejects $trav (404)" "404" "$code"
done
# /file media route (#289): Range support — <video> seeking needs 206 partial
# responses; a 200-everything server makes scrubbing snap back to the played
# position. Also: extension allowlist + traversal guard.
mkdir -p "$_nvbrain/assets"
printf '0123456789abcdef' >"$_nvbrain/assets/clip.mp4"
_fu="http://127.0.0.1:$NEURAL_VIEW_PORT/file/$_nvrepo/dev/assets/clip.mp4"
hdrs="$(curl -s -D - -o /dev/null "$_fu" | tr -d '\r')"
check "file route serves media (200)" "200 OK" "$hdrs"
check "file route advertises Accept-Ranges: bytes" "Accept-Ranges: bytes" "$hdrs"
hdrs="$(curl -s -D - -o /dev/null -H 'Range: bytes=4-7' "$_fu" | tr -d '\r')"
check "file route answers a Range request with 206" "206 Partial Content" "$hdrs"
check "file route 206 carries Content-Range" "Content-Range: bytes 4-7/16" "$hdrs"
body="$(curl -s -H 'Range: bytes=4-7' "$_fu")"
check "file route 206 body is exactly the requested slice" "4567" "$body"
hdrs="$(curl -s -D - -o /dev/null -H 'Range: bytes=999-' "$_fu" | tr -d '\r')"
check "file route unsatisfiable range gets 416" "416" "$hdrs"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/file/$_nvrepo/dev/assets/clip.sh")"
check "file route rejects non-allowlisted extension (404)" "404" "$code"
code="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/file/$_nvrepo/dev/../../../etc/passwd")"
check "file route rejects traversal (404)" "404" "$code"

# finding 2: path traversal via ../ in the slug must not escape notes/ (arbitrary file read)
printf 'TOPSECRET-XYZZY' >"$_nvbrain/SECRET.md"       # a file OUTSIDE notes/, one level up
body="$(curl -s --path-as-is "http://127.0.0.1:$NEURAL_VIEW_PORT/note/$_nvrepo/dev/../SECRET")"
check_absent "note path traversal does not leak an out-of-tree file" "TOPSECRET-XYZZY" "$body"
code="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/note/$_nvrepo/dev/../SECRET")"
check "note path traversal returns 404" "404" "$code"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/note/$_nvrepo/dev/..%2fSECRET")"
check "note dotdot slug (encoded) returns 404" "404" "$code"
python3 "$NV" stop >/dev/null

# findings 1 + 3: offset-cursor /events — completeness from per-brain byte offsets, not sort order.
_nvev="$(mktemp -d)"
_nvevrepo="$(basename "$_nvev")"
for r in dev reviewer orchestrator; do mkdir -p "$_nvev/.claude/identities/$r/brain"; done
lifecycle_start "neural-view starts (events root)" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_nvev"'
evout="$(P="$NEURAL_VIEW_PORT" R="$_nvev" python3 - <<'PY'
import json, os, urllib.request
P, R = os.environ["P"], os.environ["R"]
log = lambda role: os.path.join(R, ".claude/identities", role, "brain", ".activation.jsonl")
def append(role, i, ts):
    with open(log(role), "a") as f:
        f.write(json.dumps({"ts": ts, "role": role, "event": "seed", "note": "n%d" % i, "id": i}) + "\n")
def poll(token):
    url = "http://127.0.0.1:%s/events" % P + (("?since=%s" % token) if token else "")
    return json.load(urllib.request.urlopen(url))
d0 = poll("")                                   # first poll: end-of-logs, no backlog replay
print("FIRSTPOLL events=%d" % len(d0["events"]))
# round 1 — interleaved, deliberately NON-monotonic ts across brains
append("dev", 1, "2026-07-06T10:00:05Z"); append("orchestrator", 2, "2026-07-06T10:00:01Z"); append("reviewer", 3, "2026-07-06T10:00:09Z")
d1 = poll(d0["cursor"]); ids1 = sorted(e["id"] for e in d1["events"])
# round 2 — the replay trap: events with ts EARLIER than ones already delivered in round 1
append("reviewer", 4, "2026-07-06T10:00:02Z"); append("dev", 5, "2026-07-06T10:00:00Z")
d2 = poll(d1["cursor"]); ids2 = sorted(e["id"] for e in d2["events"])
d3 = poll(d2["cursor"])                          # idle poll: nothing appended
allids = ids1 + ids2
print("ROUND2 ids=%s" % ids2)                    # must be exactly [4, 5] (delivered once, no replay of round 1)
print("DELIVERED ids=%s" % sorted(allids))       # no loss: every appended event arrived
print("DUPS=%d" % (len(allids) - len(set(allids))))  # no duplicate delivery
print("IDLE events=%d bytesRead=%s" % (len(d3["events"]), d3.get("bytesRead")))  # reads ~zero new bytes
print("REPOTAG=%s" % d1["events"][0].get("repo"))  # delivered events are tagged with their repo
PY
)"
check "events first poll skips backlog" "FIRSTPOLL events=0" "$evout"
check "events replay-trap delivers only new (no replay)" "ROUND2 ids=[4, 5]" "$evout"
check "events no loss across interleaved earlier-ts writes" "DELIVERED ids=[1, 2, 3, 4, 5]" "$evout"
check "events no duplicate delivery" "DUPS=0" "$evout"
check "events idle poll reads zero new bytes" "IDLE events=0 bytesRead=0" "$evout"
check "events carry the repo tag (legacy single-dir)" "REPOTAG=$_nvevrepo" "$evout"
# round-2 finding: a token decoding to a NEGATIVE byte offset must not reach an
# un-clamped fh.seek() (OSError → dropped connection). Must return 200 + a batch.
negtok="$(python3 -c "import base64,json; print(base64.urlsafe_b64encode(json.dumps({'$_nvevrepo':{'dev':-999}}).encode()).rstrip(b'=').decode())")"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/events?since=$negtok")"
check "events negative-offset token returns 200 (no dropped connection)" "200" "$code"
body="$(curl -s "http://127.0.0.1:$NEURAL_VIEW_PORT/events?since=$negtok")"
check "events negative-offset token yields a sane batch" '"events"' "$body"
python3 "$NV" stop >/dev/null

_nvempty="$(mktemp -d)"          # a root with no brains at all
lifecycle_start "neural-view starts on empty root" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_nvempty"'
out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")";  check "empty root -> empty nodes" '"nodes": []' "$out"
out="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/")"; check "page still loads on empty root" "200" "$out"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
# _hubtmp: cross-section dependency -- created in section-ui-hub.sh (which
# must run before this file; SECTIONS order in run-tests.sh preserves that)
# and cleaned up here, exactly as in the pre-split monolith. Under a
# single-section --section run (dev#96) ui-hub may not have run, so _hubtmp
# is unset -- ${_hubtmp:-} keeps that a harmless no-op rather than a set -u
# crash (rm of the empty string is a no-op).
# shellcheck disable=SC2154
rm -rf "$_nvroot" "$_nvstate" "$_nvev" "$_nvempty" "$_nvscan_empty" "${_hubtmp:-}"

echo "== neural-view (multi-repo aggregation via .claude/.neural-network marker) =="
_scanbase="$(mktemp -d)"
_scanstate="$(mktemp -d)"
_repoA="$_scanbase/repo-alpha"; _repoB="$_scanbase/repo-beta"; _repoC="$_scanbase/repo-gamma"
mkdir -p "$_repoA/.claude" "$_repoB/.claude" "$_repoC/.claude"
: >"$_repoA/.claude/.neural-network"   # marker + brains
: >"$_repoB/.claude/.neural-network"   # marker, no brains at all
# repoC: NO marker — must be excluded even though it has a brain
_alphabrain="$_repoA/.claude/identities/dev/brain"
mkdir -p "$_alphabrain/notes"
cat >"$_alphabrain/notes/seed-note.md" <<'EOF'
---
strength: 3
---
A note that belongs to repo-alpha only.
EOF
_gammabrain="$_repoC/.claude/identities/dev/brain"
mkdir -p "$_gammabrain/notes"
cat >"$_gammabrain/notes/should-not-appear.md" <<'EOF'
This repo has no marker file and must be excluded from discovery.
EOF
# #75: repo-alpha also grows a non-canonical "ops" role brain, to pin that
# repoRoles is canonical-roles UNION discovered-on-disk roles, not just the
# hardcoded three.
_alphaopsbrain="$_repoA/.claude/identities/ops/brain"
mkdir -p "$_alphaopsbrain/notes"
cat >"$_alphaopsbrain/notes/ops-note.md" <<'EOF'
---
strength: 1
---
A role beyond the canonical three (dev/orchestrator/reviewer).
EOF

export NEURAL_VIEW_STATE="$_scanstate" NEURAL_VIEW_SCAN="$_scanbase"
lifecycle_start "neural-view starts (scan discovery, no --dir)" NEURAL_VIEW_PORT 'python3 "$NV" start'
out="$(python3 "$NV" status)"; check "status reports repos=2 (marker repos only)" "repos=2" "$out"
out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")"
check "graph includes marked repo-alpha node" '"id": "repo-alpha/dev/seed-note"' "$out"
check "graph node tags repo-alpha" '"repo": "repo-alpha"' "$out"
check_absent "graph excludes unmarked repo-gamma note" "should-not-appear" "$out"
check "graph repos list includes repo-alpha" '"repo-alpha"' "$out"
check "graph repos list includes brainless marked repo-beta" '"repo-beta"' "$out"
check_absent "graph repos list excludes unmarked repo-gamma" '"repo-gamma"' "$out"
# #75: repoRoles must list ALL THREE canonical roles for every anchored repo,
# even one with brains for only one role on disk (repo-alpha: dev+ops only) or
# zero brains at all (repo-beta) -- this is what lets the BRAINS panel show
# empty/dimmed brain entries instead of omitting them.
check "graph repoRoles for repo-alpha is canonical roles UNION its on-disk ops role, sorted" '"repo-alpha": ["dev", "ops", "orchestrator", "reviewer"]' "$out"
check "graph repoRoles for repo-beta (marker, zero brains on disk) still lists all three canonical roles" '"repo-beta": ["dev", "orchestrator", "reviewer"]' "$out"
out="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/note/repo-alpha/dev/seed-note")"
check "multi-repo note fetch addresses by repo/role/slug" "belongs to repo-alpha only" "$out"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/note/repo-gamma/dev/should-not-appear")"
check "unmarked repo's note is unreachable (404)" "404" "$code"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_scanbase" "$_scanstate"

if [[ "$(id -u)" != "0" ]]; then   # permission tests are meaningless as root (bypasses all checks)
    echo "== neural-view (scan base with an unreadable child directory) =="
    _permbase="$(mktemp -d)"
    _permstate="$(mktemp -d)"
    _goodrepo="$_permbase/good-repo"; mkdir -p "$_goodrepo/.claude"
    : >"$_goodrepo/.claude/.neural-network"
    _denied="$_permbase/denied-repo"; mkdir -p "$_denied/.claude"
    chmod 000 "$_denied"   # simulates a scan-base child neural-view can't traverse into
    export NEURAL_VIEW_STATE="$_permstate" NEURAL_VIEW_SCAN="$_permbase"
    lifecycle_start "neural-view survives an unreadable scan-base child (starts)" NEURAL_VIEW_PORT 'python3 "$NV" start 2>&1'
    out="$(python3 "$NV" status)"
    check "status still reports the good repo despite the denied one" "repos=1" "$out"
    python3 "$NV" stop >/dev/null 2>&1 || true
    chmod 700 "$_denied"    # restore before cleanup so rm -rf can actually remove it
    unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
    rm -rf "$_permbase" "$_permstate"
fi

echo "== neural-view (start fails to bind: no false RUNNING claim) =="
_bindstate="$(mktemp -d)"
_bindport="$(_rand_port)"
NVBIND_PORT="$_bindport" python3 - <<'PY' &
import os, socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(os.environ["NVBIND_PORT"])))
s.listen(1)
time.sleep(6)
PY
_blocker=$!
sleep 0.3   # let the scratch listener actually bind before racing neural-view for the port
export NEURAL_VIEW_STATE="$_bindstate" NEURAL_VIEW_PORT="$_bindport"
out="$(python3 "$NV" start 2>&1)"; rc=$?
check_absent "start does not claim RUNNING when the port is already taken" "RUNNING" "$out"
check "start's failure message points at server.log" "server.log" "$out"
if [[ $rc -ne 0 ]]; then echo "ok   start exits non-zero when it fails to bind"
else echo "FAIL start exits non-zero when it fails to bind — got rc=0"; fails=$((fails + 1)); fi
kill "$_blocker" 2>/dev/null || true
wait "$_blocker" 2>/dev/null || true
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT
rm -rf "$_bindstate"

echo "== neural-view (stale/zombie port lifecycle, sw-067) =="
# (a) an UNRELATED process (not neural-view.py) holds the port; no pidfile
# was ever written into this state dir. status must say STALE (never a bare
# STOPPED) and name the real PID; start must refuse to claim success and
# explain the same diagnosis; stop --force must REFUSE to kill it because
# its cmdline doesn't look like neural-view.py.
_zstate="$(mktemp -d)"
_zport="$(_rand_port)"
NVBIND_PORT="$_zport" python3 - <<'PY' &
import os, socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(os.environ["NVBIND_PORT"])))
s.listen(1)
time.sleep(8)
PY
_zblocker=$!
sleep 0.3
export NEURAL_VIEW_STATE="$_zstate" NEURAL_VIEW_PORT="$_zport"
out="$(python3 "$NV" status)"; rc=$?
check_absent "unrelated port-holder: status is never a bare STOPPED" "STOPPED" "$out"
check "unrelated port-holder: status reports STALE" "STALE" "$out"
check "unrelated port-holder: status names the real PID" "$_zblocker" "$out"
check_rc "unrelated port-holder: status exits non-zero" 1 "$rc"
out="$(python3 "$NV" start 2>&1)"; rc=$?
check_absent "unrelated port-holder: start does not claim RUNNING" "RUNNING" "$out"
check "unrelated port-holder: start's diagnosis names the real PID" "$_zblocker" "$out"
check "unrelated port-holder: start still points at server.log" "server.log" "$out"
check_rc "unrelated port-holder: start exits non-zero" 1 "$rc"
out="$(python3 "$NV" stop --force 2>&1)"
check "unrelated port-holder: stop --force refuses to kill it" "refus" "$out"
if kill -0 "$_zblocker" 2>/dev/null; then echo "ok   unrelated port-holder: stop --force left the foreign process alive"
else echo "FAIL unrelated port-holder: stop --force left the foreign process alive — it got killed"; fails=$((fails + 1)); fi
kill "$_zblocker" 2>/dev/null || true
wait "$_zblocker" 2>/dev/null || true
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT
rm -rf "$_zstate"

# (b) a REAL neural-view is running, then its pidfile is deleted (the actual
# incident: a lost pidfile makes a live server look STOPPED). status must
# name the same PID as STALE; stop --force must kill it and free the port.
_zroot2="$(mktemp -d)"
_zstate2="$(mktemp -d)"
export NEURAL_VIEW_STATE="$_zstate2"
lifecycle_start "lost-pidfile: neural-view starts" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_zroot2"'
_zrealpid="$(cat "$_zstate2/pid")"
rm -f "$_zstate2/pid"                      # simulate the lost/stale pidfile
out="$(python3 "$NV" status)"; rc="$?"
check_absent "lost-pidfile: status is never a bare STOPPED" "STOPPED" "$out"
check "lost-pidfile: status reports STALE" "STALE" "$out"
check "lost-pidfile: status names the real server's PID" "$_zrealpid" "$out"
check_rc "lost-pidfile: status exits non-zero" 1 "$rc"
python3 "$NV" stop --force >/dev/null 2>&1
_freed=0
for _ in $(seq 1 30); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$NEURAL_VIEW_PORT") 2>/dev/null; then _freed=1; break; fi
    sleep 0.1
done
if [[ "$_freed" -eq 1 ]]; then echo "ok   lost-pidfile: stop --force kills the zombie and frees the port"
else echo "FAIL lost-pidfile: stop --force kills the zombie and frees the port — port still held"; fails=$((fails + 1)); fi
if kill -0 "$_zrealpid" 2>/dev/null; then echo "FAIL lost-pidfile: zombie process still alive after stop --force"; fails=$((fails + 1))
else echo "ok   lost-pidfile: zombie process no longer alive after stop --force"; fi
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT
rm -rf "$_zroot2" "$_zstate2"

