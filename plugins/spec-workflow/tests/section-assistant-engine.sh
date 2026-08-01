#!/usr/bin/env bash
# section-assistant-engine.sh -- AST-010: assistant engine package skeleton +
# route table + lifecycle wiring (SPEC-ASSISTANT.md §5a, issue #308). Sourced
# by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant engine (AST-010: route table + worker lifecycle, SPEC-ASSISTANT.md §5a) =="

AE_SCRIPTS="$PLUGIN/scripts"
NV="$PLUGIN/scripts/neural-view.py"

# ae_repo <dir> <name> -- a marker'd repo with a structurally valid, enabled
# assistant: section (mirrors section-assistant-default.sh's ad_repo).
ae_repo() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude"
    printf '%s\n' '# neural-network' >"$dir/.claude/.neural-network"
    printf '%s\n' \
        'schemaVersion: 2' \
        'assistant:' \
        '    version: 1' \
        '    enabled: true' \
        "    names: [$main]" \
        '    systemPrompt: |' \
        "        You are $main." \
        '    llm:' \
        '        provider: openai' \
        '        model: gpt-5.6-sol' \
        '    capabilities:' \
        '        codex:' \
        '            enabled: true' \
        '            provisioning:' \
        '                bin: codex' \
        >"$dir/.claude/project.yaml"
}

# --------------------------------------------------------------- unit: no server
echo "-- unit: route dispatch + worker registry (no server) --"
_ae_unit_state="$(mktemp -d)"
_ae_unit_repo_a="$(mktemp -d)"
_ae_unit_repo_b="$(mktemp -d)"
ae_repo "$_ae_unit_repo_a" jarvis
mkdir -p "$_ae_unit_repo_b/.claude"
printf '%s\n' '# neural-network' >"$_ae_unit_repo_b/.claude/.neural-network"   # marker, no assistant: section -- not a candidate

unit_out="$(SCRIPTS_DIR="$AE_SCRIPTS" REPO_A="$_ae_unit_repo_a" REPO_B="$_ae_unit_repo_b" STATE="$_ae_unit_state" python3 - <<'PY'
import os, sys, threading
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

baseline = {t.ident for t in threading.enumerate()}

# review r2 regression: repos_holder is a MUTABLE list the getter reads live
# (mirrors neural-view.py, where rescan_loop reassigns the module-level
# REPOS after boot) -- starts with only the non-candidate repo so the
# effect of a later mutation on /assistant/status is unambiguous.
repos_holder = [("b", os.environ["REPO_B"])]
e = engine.AssistantEngine(lambda: repos_holder, os.environ["STATE"])

# unmatched route -> None (caller 404s)
print("UNMATCHED", e.handle("GET", "/assistant/nope") is None)

# start() launches exactly the 4 mandated subsystem workers
e.start()
names = sorted(n for n, _, _ in e.workers)
print("WORKER_NAMES", names)
after_start = {t.ident for t in threading.enumerate()} - baseline
print("THREADS_AFTER_START", len(after_start))

status_code, payload, ctype = e.handle("GET", "/assistant/status")
print("STATUS_CODE", status_code)
print("CTYPE", ctype)
print("ENGINE_FIELD", payload["engine"])
print("SELECTED", payload["selected"])
print("ASSISTANTS_BEFORE", payload["assistants"])
print("WORKERS_ALIVE", all(w["alive"] for w in payload["workers"]))
print("WORKERS_COUNT", len(payload["workers"]))

# review r2 regression: mutate the SAME list object the getter closes over
# (no engine reconstruction) -- the engine must read the live list, not a
# constructor-time snapshot.
repos_holder.append(("a", os.environ["REPO_A"]))
_, payload2, _ = e.handle("GET", "/assistant/status")
print("ASSISTANTS_AFTER", payload2["assistants"])

# idempotence: start() again must not spawn duplicate workers
e.start()
print("WORKER_COUNT_AFTER_RESTART", len(e.workers))

e.stop()
print("THREADS_AFTER_STOP", len({t.ident for t in threading.enumerate()} - baseline))
print("ALL_JOINED", all(not t.is_alive() for _, t, _ in e.workers if t is not None) if e.workers else True)

# idempotence: stop() again must not raise
e.stop()
print("DOUBLE_STOP_OK", True)
PY
)"
rc=$?
check_rc "engine unit script exits 0" 0 "$rc"
check "engine unit: unmatched route returns None" "UNMATCHED True" "$unit_out"
check "engine unit: worker registry has the four mandated subsystems" \
    "WORKER_NAMES ['distiller', 'index', 'tasks', 'traces']" "$unit_out"
check "engine unit: start() launches exactly 4 live threads" "THREADS_AFTER_START 4" "$unit_out"
check "engine unit: status route returns 200" "STATUS_CODE 200" "$unit_out"
check "engine unit: status content-type is JSON" "CTYPE application/json" "$unit_out"
check "engine unit: status engine field is ok" "ENGINE_FIELD ok" "$unit_out"
check "engine unit: status selected is null (no selection logic in AST-010)" "SELECTED None" "$unit_out"
check "engine unit: status counts zero before the candidate repo is added" "ASSISTANTS_BEFORE 0" "$unit_out"
check "engine unit: status workers all report alive" "WORKERS_ALIVE True" "$unit_out"
check "engine unit: status workers count is 4" "WORKERS_COUNT 4" "$unit_out"
check "engine unit: status reads the LIVE repos list (getter, not a ctor-time snapshot) after mutation" \
    "ASSISTANTS_AFTER 1" "$unit_out"
check "engine unit: start() is idempotent (no duplicate workers)" "WORKER_COUNT_AFTER_RESTART 4" "$unit_out"
check "engine unit: stop() joins every worker (no leaked threads)" "THREADS_AFTER_STOP 0" "$unit_out"
check "engine unit: stop() actually joins each worker thread" "ALL_JOINED True" "$unit_out"
check "engine unit: stop() is idempotent (second call does not raise)" "DOUBLE_STOP_OK True" "$unit_out"
rm -rf "$_ae_unit_state" "$_ae_unit_repo_a" "$_ae_unit_repo_b"

# --------------------------------------------------------------- integration: real server
echo "-- integration: real server on a scratch port --"
_ae_root="$(mktemp -d)"          # scan-fixture repo (--dir)
_ae_state="$(mktemp -d)"         # server state (pid/port)
_ae_scan_empty="$(mktemp -d)"    # empty scan base so real ~/Development repos never leak in
ae_repo "$_ae_root" friday

export NEURAL_VIEW_STATE="$_ae_state" NEURAL_VIEW_SCAN="$_ae_scan_empty"
lifecycle_start "assistant engine: neural-view starts" NEURAL_VIEW_PORT 'python3 "$NV" start --dir "$_ae_root"'

status_body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/status")"
check "assistant/status: engine ok" '"engine": "ok"' "$status_body"
check "assistant/status: 4 workers reported" '"name": "distiller"' "$status_body"
check "assistant/status: traces worker reported" '"name": "traces"' "$status_body"
check "assistant/status: tasks worker reported" '"name": "tasks"' "$status_body"
check "assistant/status: index worker reported" '"name": "index"' "$status_body"
check "assistant/status: workers report alive true" '"alive": true' "$status_body"
check "assistant/status: assistants counts the fixture candidate" '"assistants": 1' "$status_body"
check "assistant/status: selected is null" '"selected": null' "$status_body"

code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/status")"
check "assistant/status: HTTP 200" "200" "$code"

nf_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/no-such-route")"
check "assistant: unmatched /assistant/* route 404s" "404" "$nf_code"

# regression: pre-existing routes must still serve byte-identically
graph_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/graph")"
check "regression: /graph still serves (200)" "200" "$graph_code"
page_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/")"
check "regression: / still serves (200)" "200" "$page_code"

# POST is also mounted for the engine (future turn/selection routes), and
# still 404s for anything not under /assistant/*.
post_code="$(curl -s -o /dev/null -X POST -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/assistant/no-such-route")"
check "assistant: unmatched POST /assistant/* route 404s" "404" "$post_code"
post_other_code="$(curl -s -o /dev/null -X POST -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/not-assistant")"
check "regression: unrelated POST route still 404s (unchanged behavior)" "404" "$post_other_code"

_ae_pid="$(cat "$_ae_state/pid")"
python3 "$NV" stop >/dev/null
_ae_freed=0
for _ in $(seq 1 30); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$NEURAL_VIEW_PORT") 2>/dev/null; then _ae_freed=1; break; fi
    sleep 0.1
done
if [[ "$_ae_freed" -eq 1 ]]; then echo "ok   assistant engine: SIGTERM stop frees the port cleanly"
else echo "FAIL assistant engine: SIGTERM stop frees the port cleanly — port still held"; fails=$((fails + 1)); fi
if kill -0 "$_ae_pid" 2>/dev/null; then echo "FAIL assistant engine: server process still alive after stop"; fails=$((fails + 1))
else echo "ok   assistant engine: server process no longer alive after stop"; fi

unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_ae_root" "$_ae_state" "$_ae_scan_empty"

echo "-- engine: DISTILLER_QUEUE_MAXSIZE overflow is drop-oldest (issue #389) --"
_ae_dq_state="$(mktemp -d)"
dq_out="$(SCRIPTS_DIR="$AE_SCRIPTS" STATE="$_ae_dq_state" python3 - <<'PY'
import os, sys, queue as queue_module
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

repos = lambda: []
state_dir = os.environ["STATE"]
e = engine.AssistantEngine(repos, state_dir)
# no e.start() -- nothing drains queues["distiller"], so the queue's own
# contents after N _enqueue_distill calls reflect ONLY the overflow policy,
# never a race with a real worker thread.
e.queues["distiller"] = queue_module.Queue(maxsize=5)

for i in range(5):
    e._enqueue_distill("root", "u%d" % i, "a%d" % i, [])
print("FULL_LEN", e.queues["distiller"].qsize())

# 3 more pushes past maxsize=5 -- drop-oldest means u0/u1/u2 are evicted,
# u3..u7 remain (still exactly maxsize items).
for i in range(5, 8):
    e._enqueue_distill("root", "u%d" % i, "a%d" % i, [])

remaining = []
while True:
    try:
        remaining.append(e.queues["distiller"].get_nowait())
    except queue_module.Empty:
        break
users = [item["exchange"]["user"] for item in remaining]
print("OVERFLOW_LEN", len(users))
print("OVERFLOW_USERS", users)

# --- documented race-degrades-to-drop-newest branch (see _enqueue_distill's
# docstring): a raced eviction where another producer's get_nowait/put_nowait
# slips in between this call's own two calls degrades to silently dropping
# THIS item. Deterministically reproduced with a fake queue whose put_nowait
# always raises Full (simulating an already-full queue) and whose get_nowait
# always raises Empty (simulating the raced eviction: something else already
# took the oldest slot) -- so the retry put_nowait also raises Full, and the
# item is dropped without _enqueue_distill raising.
class _AlwaysFullQueue:
    def put_nowait(self, item):
        raise queue_module.Full
    def get_nowait(self):
        raise queue_module.Empty

e.queues["distiller"] = _AlwaysFullQueue()
try:
    e._enqueue_distill("root", "raced-user", "raced-assistant", [])
    print("RACE_RAISED", False)
except Exception:
    print("RACE_RAISED", True)
PY
)"
rc=$?
check_rc "distiller overflow script exits 0" 0 "$rc"
check "queue fills to exactly maxsize before any overflow" "FULL_LEN 5" "$dq_out"
check "overflow keeps exactly maxsize items (drop-oldest, never grows unbounded)" "OVERFLOW_LEN 5" "$dq_out"
check "overflow evicts the oldest and keeps the newest 5" "OVERFLOW_USERS ['u3', 'u4', 'u5', 'u6', 'u7']" "$dq_out"
check "a raced eviction degrades to silently dropping the item, never raises (Sec9.5)" "RACE_RAISED False" "$dq_out"

rm -rf "$_ae_dq_state"

# ------------------------------------------------------------------------
# AST-071 (SPEC-ASSISTANT.md §11.8, docs/design/ast-E6.md sequence 5):
# capability-gap flow wiring. `_capability_gap_check` (reusing the already-
# compiled index -- no recompute, §11.3) is a complete, directly-callable
# building block: on a genuine gap it emits a first-class trace event and
# drafts a background, non-blocking plan note, and NEVER touches a reply.
# It is deliberately NOT auto-invoked from every `_chat` call -- see its
# docstring (engine.py) and docs/spec-deltas/346.md for why: doing so was
# tried and reverted after it minted a flood of near-duplicate plan notes
# across an ordinary multi-turn conversation against a skill-less
# assistant (every turn's roster comes back empty, same as this task's own
# gap trigger), breaking section-assistant-distill.sh's real distilled-
# mint count. The tests below exercise the method directly (the shape a
# future explicit invocation-attempt caller would use) and then add a
# regression guard proving ordinary chat still mints nothing extra.
# ------------------------------------------------------------------------
echo "-- engine: _enqueue_gap_note overflow is drop-oldest, never blocks/raises (Sec9.5) --"
_ae_gq_state="$(mktemp -d)"
gq_out="$(SCRIPTS_DIR="$AE_SCRIPTS" STATE="$_ae_gq_state" python3 - <<'PY'
import os, sys, queue as queue_module
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

e = engine.AssistantEngine(lambda: [], os.environ["STATE"])
e.queues["distiller"] = queue_module.Queue(maxsize=3)

for i in range(3):
    e._enqueue_gap_note("root", {"request_excerpt": "req-%d" % i, "nearest": [], "turn_id": "t%d" % i})
print("FULL_LEN", e.queues["distiller"].qsize())

for i in range(3, 5):
    e._enqueue_gap_note("root", {"request_excerpt": "req-%d" % i, "nearest": [], "turn_id": "t%d" % i})

remaining = []
while True:
    try:
        remaining.append(e.queues["distiller"].get_nowait())
    except queue_module.Empty:
        break
turn_ids = [item["gap_note"]["turn_id"] for item in remaining]
print("OVERFLOW_LEN", len(turn_ids))
print("OVERFLOW_TURN_IDS", turn_ids)

class _AlwaysFullQueue:
    def put_nowait(self, item):
        raise queue_module.Full
    def get_nowait(self):
        raise queue_module.Empty

e.queues["distiller"] = _AlwaysFullQueue()
try:
    e._enqueue_gap_note("root", {"request_excerpt": "raced", "nearest": [], "turn_id": "tR"})
    print("RACE_RAISED", False)
except Exception:
    print("RACE_RAISED", True)
PY
)"
check "gap-note queue fills to exactly maxsize before overflow" "FULL_LEN 3" "$gq_out"
check "gap-note overflow keeps exactly maxsize items (drop-oldest)" "OVERFLOW_LEN 3" "$gq_out"
check "gap-note overflow evicts the oldest, keeps the newest" "OVERFLOW_TURN_IDS ['t2', 't3', 't4']" "$gq_out"
check "a raced gap-note eviction degrades to silently dropping the item, never raises" "RACE_RAISED False" "$gq_out"
rm -rf "$_ae_gq_state"

# ae_gap_repo <dir> <main> -- like ae_repo, but with ONE real, enabled,
# provisioned skill installed (an always-succeeding `true` provisioning
# check -- no special binaries needed) so the compiled index is genuinely
# non-empty. Used below to exercise the "total_enabled > 0 but nothing
# matched" branch (review round 1 fix #6: a plan note is only drafted when
# there is an established capability posture to extend -- see
# turns.capability_gap_reply's docstring).
ae_gap_repo() {
    local dir="$1" main="$2"
    ae_repo "$dir" "$main"
    mkdir -p "$dir/.claude/skills/recipe-finder"
    printf '%s\n' \
        "version: 1" \
        "provisioning:" \
        "    check: [\"true\"]" \
        "    ttlSeconds: 300" \
        "permissions: []" \
        "invoke:" \
        "    exec: [\"true\"]" \
        >"$dir/.claude/skills/recipe-finder/capability.yaml"
    printf '%s\n' \
        "---" \
        "name: recipe-finder" \
        "description: finds cooking recipes" \
        "---" \
        "body" \
        >"$dir/.claude/skills/recipe-finder/SKILL.md"
    # append the capability's enablement to the SAME project.yaml ae_repo
    # already wrote (same "capabilities:" mapping key level as "codex:").
    printf '%s\n' \
        "        recipe-finder:" \
        "            enabled: true" \
        >>"$dir/.claude/project.yaml"
}

echo "-- integration: _capability_gap_check (called directly -- see its docstring for why it is NOT auto-wired into _chat) emits skill.gap (turn_id-linked) and drafts a plan note in the background when the index has an established posture, without touching project.yaml --"
_ae_gap_root="$(mktemp -d)"
ae_gap_repo "$_ae_gap_root" jarvis
_ae_gap_project_yaml="$_ae_gap_root/.claude/project.yaml"
_ae_gap_before_hash="$(shasum -a 256 "$_ae_gap_project_yaml" | awk '{print $1}')"

gap_engine_out="$(SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_gap_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index, engine, observability
import brain

root = os.environ["ROOT"]

# Force the deterministic keyword-overlap fallback (never a real embedding)
# for BOTH the index compile and the per-turn query, keeping this test
# environment-independent -- see docs/spec-deltas/346.md (§2, round 2
# NEW-3) for why a real embeddings capability would make this test flaky.
capability_index._default_embed_fn = lambda texts: None

state_dir = os.path.join(root, ".claude", "assistant-engine-state-gap")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    # wait for the real index worker to compile at least once (installs
    # recipe-finder) before calling _capability_gap_check --
    # capability_index_for degrades to an empty index until it has.
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if len(e.capability_index_for(root).entries) > 0:
            break
        time.sleep(0.1)

    # a query with ZERO keyword overlap against "recipe-finder" -- an
    # established capability posture exists (total_enabled=1), but
    # nothing matched THIS request.
    turn_id = "turn-gap-1"
    e._capability_gap_check(root, turn_id, "please book a flight to mars")

    identities = os.path.join(root, ".claude", "identities")
    deadline = time.monotonic() + 5.0
    minted_slugs = []
    while time.monotonic() < deadline:
        notes = brain.load_notes(identities, "assistant")
        minted_slugs = [s for s in notes if s.startswith("capability-acquire-plan-")]
        if minted_slugs:
            break
        time.sleep(0.2)
    print("PLAN_NOTE_MINTED_IN_BACKGROUND", len(minted_slugs) == 1)

    rows = []
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "skill.gap" for r in rows):
            break
        time.sleep(0.2)
    gap_rows = [r for r in rows if r["kind"] == "skill.gap"]
    print("GAP_EVENT_EMITTED", len(gap_rows) == 1)
    print("GAP_EVENT_HAS_TURN_ID", bool(gap_rows) and gap_rows[0].get("turn_id") == turn_id)
    print("GAP_EVENT_KIND_IN_SKILL_NAMESPACE", bool(gap_rows) and gap_rows[0]["kind"].startswith("skill."))
finally:
    e.stop()
PY
)"
check "gap check: an acquire-offer plan note is minted in the background" "PLAN_NOTE_MINTED_IN_BACKGROUND True" "$gap_engine_out"
check "gap check: a skill.gap trace event is emitted (§10.1 namespace, review round 1 fix #4)" "GAP_EVENT_EMITTED True" "$gap_engine_out"
check "gap check: the gap event carries the caller's turn_id (turn linkage)" "GAP_EVENT_HAS_TURN_ID True" "$gap_engine_out"
check "gap check: the event kind lives inside the enumerated skill.* namespace" "GAP_EVENT_KIND_IN_SKILL_NAMESPACE True" "$gap_engine_out"

_ae_gap_after_hash="$(shasum -a 256 "$_ae_gap_project_yaml" | awk '{print $1}')"
check "gap check: project.yaml is byte-identical after the whole flow (never mutated)" \
    "$_ae_gap_before_hash" "$_ae_gap_after_hash"
rm -rf "$_ae_gap_root"

echo "-- unit: _capability_gap_check -- an exception is never raised into the caller; an error trace event is emitted instead (review round 1 fix #5, §10.6) --"
_ae_gaperr_state="$(mktemp -d)"
_ae_gaperr_root="$(mktemp -d)"
gaperr_out="$(SCRIPTS_DIR="$AE_SCRIPTS" STATE="$_ae_gaperr_state" ROOT="$_ae_gaperr_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine, observability, turns

# a REAL, writable root (never a fake path) -- the traces WRITER thread
# needs somewhere real to create <root>/.claude/assistant/traces.sqlite;
# a nonexistent root would break trace persistence itself, not just the
# synthetic error this test injects.
root = os.environ["ROOT"]
state_dir = os.environ["STATE"]
e = engine.AssistantEngine(lambda: [], state_dir)
e.start()

def boom(index, message, **kwargs):
    raise RuntimeError("synthetic gap-detection failure")

original = turns.capability_gap_reply
turns.capability_gap_reply = boom
try:
    turn_id = "turn-err-1"
    try:
        e._capability_gap_check(root, turn_id, "anything")
        print("RAISED", False)
    except Exception:
        print("RAISED", True)

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"].startswith("skill.gap") and r.get("status") == "error" for r in rows):
            break
        time.sleep(0.2)
    err_rows = [r for r in rows if r["kind"].startswith("skill.gap") and r.get("status") == "error"]
    print("ERROR_EVENT_EMITTED", len(err_rows) == 1)
    print("ERROR_EVENT_HAS_TURN_ID", bool(err_rows) and err_rows[0].get("turn_id") == turn_id)
    print("ERROR_EVENT_NAMES_THE_ERROR", bool(err_rows)
          and "synthetic gap-detection failure" in str(err_rows[0].get("payload") or {}))
finally:
    turns.capability_gap_reply = original
    e.stop()
PY
)"
check "gap check: an internal exception never raises into the caller" "RAISED False" "$gaperr_out"
check "gap check: an error trace event is emitted instead (§10.6)" "ERROR_EVENT_EMITTED True" "$gaperr_out"
check "gap check: the error event carries the turn_id" "ERROR_EVENT_HAS_TURN_ID True" "$gaperr_out"
check "gap check: the error event names the actual error" "ERROR_EVENT_NAMES_THE_ERROR True" "$gaperr_out"
rm -rf "$_ae_gaperr_state" "$_ae_gaperr_root"

echo "-- regression guard: _chat does NOT auto-invoke the capability-gap flow -- ordinary chat on a skill-less assistant mints ONLY the real distiller-batch note, never a flood of gap notes --"
_ae_nogap_root="$(mktemp -d)"
ae_repo "$_ae_nogap_root" jarvis

nogap_out="$(SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_nogap_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, distill, engine
import brain

root = os.environ["ROOT"]
identities = os.path.join(root, ".claude", "identities")

def stub_complete(context, **kwargs):
    return {"text": "a completely ordinary reply", "usage": None, "timings": None}

adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-nogap")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    n = distill.DEFAULT_BATCH_N
    for i in range(n):
        status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "ordinary message %d" % i})
        if status != 200:
            print("CHAT_FAILED", status, payload)
            break
    else:
        deadline = time.monotonic() + 5.0
        minted = 0
        while time.monotonic() < deadline:
            minted = len(brain.load_notes(identities, "assistant"))
            if minted >= 1:
                break
            time.sleep(0.2)
        print("MINTED_COUNT", minted)
        gap_slugs = [s for s in brain.load_notes(identities, "assistant")
                     if s.startswith("capability-acquire-plan-")]
        print("NO_GAP_NOTES", gap_slugs == [])
finally:
    e.stop()
PY
)"
check "regression guard: ordinary chat mints exactly one note (the real distilled batch), never a flood" "MINTED_COUNT 1" "$nogap_out"
check "regression guard: ordinary chat never drafts a capability-acquire-plan note on its own" "NO_GAP_NOTES True" "$nogap_out"
rm -rf "$_ae_nogap_root"
