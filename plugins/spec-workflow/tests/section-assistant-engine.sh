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

# ==========================================================================
# #508 (SPEC-ASSISTANT.md Sec9.4/Sec9.5, Sec11.5, Sec11.8, docs/design/
# ast-E6.md sequences 2/3/5, docs/spec-deltas/applied/346.md): the LIVE
# request -> resolve -> invoke -> (gap) loop, wired into the real /assistant/
# chat path via a stub "openai" adapter (never a real provider CLI) and the
# repo's stub-argv-echo fixture binary (never a real skill's actual
# command) -- house convention, mirrors every other capability test file.
# ==========================================================================
AE_ARGVECHO_BIN="$FIX/stub-argv-echo"

# ae_capability_repo <dir> <main> -- like ae_repo, but with three real,
# enabled skills exercising the three invocation outcomes #508 must
# distinguish: "weather" (provisioned, invokable, required param), "renderer"
# (enabled but its provisioning check fails -- Sec11.4 unavailable-with-
# reason), and "slow-render" (provisioned, but capability.yaml declares
# longRunning: true -- routes through the task queue instead of an inline
# invocation).
ae_capability_repo() {
    local dir="$1" main="$2"
    ae_repo "$dir" "$main"
    mkdir -p "$dir/.claude/skills/weather"
    printf '%s\n' \
        "version: 1" \
        "provisioning:" \
        "    check: [\"true\"]" \
        "    ttlSeconds: 300" \
        "permissions: []" \
        "invoke:" \
        "    exec: [\"argvecho\", \"--city={city}\"]" \
        "    params:" \
        "        city:" \
        "            type: string" \
        >"$dir/.claude/skills/weather/capability.yaml"
    printf '%s\n' \
        "---" \
        "name: weather" \
        "description: checks the current weather for a named city" \
        "---" \
        "body" \
        >"$dir/.claude/skills/weather/SKILL.md"

    mkdir -p "$dir/.claude/skills/renderer"
    printf '%s\n' \
        "version: 1" \
        "provisioning:" \
        "    check: [\"false\"]" \
        "    ttlSeconds: 300" \
        "permissions: []" \
        "invoke:" \
        "    exec: [\"argvecho\"]" \
        >"$dir/.claude/skills/renderer/capability.yaml"
    printf '%s\n' \
        "---" \
        "name: renderer" \
        "description: renders 3d models" \
        "---" \
        "body" \
        >"$dir/.claude/skills/renderer/SKILL.md"

    mkdir -p "$dir/.claude/skills/slow-render"
    printf '%s\n' \
        "version: 1" \
        "longRunning: true" \
        "provisioning:" \
        "    check: [\"true\"]" \
        "    ttlSeconds: 300" \
        "permissions: []" \
        "invoke:" \
        "    exec: [\"argvecho\"]" \
        >"$dir/.claude/skills/slow-render/capability.yaml"
    printf '%s\n' \
        "---" \
        "name: slow-render" \
        "description: renders a long video in the background" \
        "---" \
        "body" \
        >"$dir/.claude/skills/slow-render/SKILL.md"

    printf '%s\n' \
        "        weather:" \
        "            enabled: true" \
        "        renderer:" \
        "            enabled: true" \
        "        slow-render:" \
        "            enabled: true" \
        >>"$dir/.claude/project.yaml"
}

echo "-- integration: happy-path capability invoke -- directive parsed + stripped from the visible reply, schema-validated argv substitution, result fed back in ONE same-turn follow-up completion, trace events linked by turn/span --"
_ae_cap_root="$(mktemp -d)"
ae_capability_repo "$_ae_cap_root" jarvis

cap_happy_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_cap_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability

# NOTE: every fenced-block fixture in this file is built via chr(96) rather
# than a literal backtick -- a raw literal backtick (or an unpaired
# apostrophe) inside a heredoc nested in a bash $(...) command substitution
# trips a well-known bash lexer quirk (cumulative quote-parity tracking
# that ignores heredoc quoting), so this file avoids both entirely.
FENCE = chr(96) * 3
root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None

calls = []
def stub_complete(context, **kwargs):
    calls.append(context)
    if len(calls) == 1:
        return {"text": "Let me check.\n" + FENCE + 'capability\n{"name": "weather", "params": {"city": "Rome"}}\n' + FENCE,
                "usage": None, "timings": None}
    return {"text": "It is sunny in Rome (per ARGV[0]=--city=Rome).", "usage": None, "timings": None}

adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-happy")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "what is the weather in Rome?"})
    print("STATUS", status)
    print("REPLY_NO_FENCE", (FENCE + "capability") not in payload.get("text", ""))
    print("REPLY_NO_RAW_JSON", '"name": "weather"' not in payload.get("text", ""))
    print("REPLY_IS_FOLLOWUP", payload.get("text") == "It is sunny in Rome (per ARGV[0]=--city=Rome).")
    print("ADAPTER_CALLED_TWICE", len(calls) == 2)
    print("SECOND_CALL_SAW_ARGV", "ARGV[0]=--city=Rome" in calls[1]["input"])

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "skill.invoke" and r.get("status") == "ok" for r in rows):
            break
        time.sleep(0.2)
    request_rows = [r for r in rows if r["kind"] == "skill.request"]
    invoke_rows = [r for r in rows if r["kind"] == "skill.invoke"]
    turn_rows = [r for r in rows if r["kind"] == "turn.start"]
    turn_id = turn_rows[0]["turn_id"] if turn_rows else None

    print("REQUEST_EVENT_EMITTED", len(request_rows) == 1)
    print("REQUEST_EVENT_NAMES_WEATHER", request_rows and request_rows[0]["payload"].get("name") == "weather")
    print("INVOKE_START_AND_OK", sorted(r["status"] for r in invoke_rows) == ["ok", "start"])
    start_span = next((r["span_id"] for r in invoke_rows if r["status"] == "start"), None)
    ok_span = next((r["span_id"] for r in invoke_rows if r["status"] == "ok"), None)
    print("SAME_SPAN_START_AND_OK", start_span is not None and start_span == ok_span)
    print("INVOKE_PARENT_IS_TURN", all(r.get("parent_span_id") == turn_id for r in invoke_rows))
    print("ALL_SKILL_EVENTS_CARRY_TURN_ID", all(r.get("turn_id") == turn_id for r in (request_rows + invoke_rows)))
finally:
    e.stop()
PY
)"
check "cap happy path: chat returns 200" "STATUS 200" "$cap_happy_out"
check "cap happy path: the fenced directive is stripped from the visible reply" "REPLY_NO_FENCE True" "$cap_happy_out"
check "cap happy path: raw directive JSON never leaks into the visible reply" "REPLY_NO_RAW_JSON True" "$cap_happy_out"
check "cap happy path: the FINAL reply is the follow-up completion text" "REPLY_IS_FOLLOWUP True" "$cap_happy_out"
check "cap happy path: the adapter is called exactly twice (first reply + one same-turn follow-up)" "ADAPTER_CALLED_TWICE True" "$cap_happy_out"
check "cap happy path: the follow-up completion input carries the schema-validated, substituted argv result" \
    "SECOND_CALL_SAW_ARGV True" "$cap_happy_out"
check "cap happy path: a skill.request trace event is emitted for the parsed directive" "REQUEST_EVENT_EMITTED True" "$cap_happy_out"
check "cap happy path: the skill.request event names the requested capability" "REQUEST_EVENT_NAMES_WEATHER True" "$cap_happy_out"
check "cap happy path: skill.invoke has both a start and an ok event" "INVOKE_START_AND_OK True" "$cap_happy_out"
check "cap happy path: start and ok share the SAME span_id (one invocation, one span)" "SAME_SPAN_START_AND_OK True" "$cap_happy_out"
check "cap happy path: every skill.invoke event's parent_span_id is the turn's own id (turn linkage)" "INVOKE_PARENT_IS_TURN True" "$cap_happy_out"
check "cap happy path: every skill.* event this turn emitted carries the SAME turn_id" "ALL_SKILL_EVENTS_CARRY_TURN_ID True" "$cap_happy_out"
rm -rf "$_ae_cap_root"

echo "-- integration: unknown-name directive -- the honest, embedding-mode-reachable gap trigger (owner decision 1): an explicit request that fails to resolve IS a gap, with a REAL nearest/requested_name, even though nothing about the raw message alone would have scored zero --"
_ae_unk_root="$(mktemp -d)"
ae_capability_repo "$_ae_unk_root" jarvis

cap_unknown_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_unk_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability
import brain

FENCE = chr(96) * 3
root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None

def stub_complete(context, **kwargs):
    # "weather report" (space-separated, NOT the exact fixture name
    # "weather") is chosen deliberately: it does not resolve by exact
    # name (still a genuine gap), but its extracted keywords ("weather",
    # "report") genuinely overlap the "weather" fixture skill's own
    # one_liner keywords -- so this exercises the NAMED-candidate refusal
    # shape (shape 3) and a real, non-"unspecified" slug, proving owner
    # decision 3's "a real nearest signal now exists" claim concretely.
    return {"text": FENCE + 'capability\n{"name": "weather report", "params": {}}\n' + FENCE,
            "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-unknown")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    turn_id_holder = {}
    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "please tell me the weather report"})
    print("STATUS", status)
    reply = payload.get("text", "")
    print("REPLY_NO_FENCE", (FENCE + "capability") not in reply)
    print("REPLY_IS_REFUSAL", "cannot" in reply.lower() or "do not have" in reply.lower() or "closest" in reply.lower())

    identities = os.path.join(root, ".claude", "identities")
    deadline = time.monotonic() + 5.0
    minted_slugs = []
    while time.monotonic() < deadline:
        minted_slugs = [s for s in brain.load_notes(identities, "assistant") if s.startswith("capability-acquire-plan-")]
        if minted_slugs:
            break
        time.sleep(0.2)
    print("PLAN_NOTE_MINTED", len(minted_slugs) == 1)
    print("SLUG_NOT_UNSPECIFIED", minted_slugs and "unspecified" not in minted_slugs[0])

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "skill.gap" for r in rows):
            break
        time.sleep(0.2)
    gap_rows = [r for r in rows if r["kind"] == "skill.gap"]
    print("GAP_EVENT_EMITTED", len(gap_rows) == 1)
    print("GAP_EVENT_REQUESTED_NAME", gap_rows and gap_rows[0]["payload"].get("requested_name") == "weather report")
    print("NO_SKILL_INVOKE_EVENT", not any(r["kind"] == "skill.invoke" for r in rows))
finally:
    e.stop()
PY
)"
check "unknown-name directive: chat returns 200 (a refusal reply, never a 5xx)" "STATUS 200" "$cap_unknown_out"
check "unknown-name directive: the raw directive fence never leaks into the refusal" "REPLY_NO_FENCE True" "$cap_unknown_out"
check "unknown-name directive: the reply is an honest, in-persona refusal" "REPLY_IS_REFUSAL True" "$cap_unknown_out"
check "unknown-name directive: an acquire-offer plan note is minted in the background" "PLAN_NOTE_MINTED True" "$cap_unknown_out"
check "unknown-name directive: the slug is no longer stuck at 'unspecified' (owner decision 3 -- a real nearest signal now exists)" \
    "SLUG_NOT_UNSPECIFIED True" "$cap_unknown_out"
check "unknown-name directive: a skill.gap trace event is emitted" "GAP_EVENT_EMITTED True" "$cap_unknown_out"
check "unknown-name directive: the gap event carries the actual requested_name" "GAP_EVENT_REQUESTED_NAME True" "$cap_unknown_out"
check "unknown-name directive: no invocation is ever attempted for an unresolved name" "NO_SKILL_INVOKE_EVENT True" "$cap_unknown_out"
rm -rf "$_ae_unk_root"

echo "-- integration: unprovisioned capability -- a refusal naming the reason (Sec11.4: never present an unavailable ability as usable), never a gap (something WAS found) --"
_ae_unprov_root="$(mktemp -d)"
ae_capability_repo "$_ae_unprov_root" jarvis

cap_unprov_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_unprov_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability

FENCE = chr(96) * 3
root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None

def stub_complete(context, **kwargs):
    return {"text": FENCE + 'capability\n{"name": "renderer", "params": {}}\n' + FENCE, "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-unprov")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "please render a duck"})
    reply = payload.get("text", "")
    print("STATUS", status)
    print("REPLY_NAMES_RENDERER", "renderer" in reply)
    print("REPLY_SAYS_UNAVAILABLE", "not" in reply.lower() and "available" in reply.lower())

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "skill.error" for r in rows):
            break
        time.sleep(0.2)
    err_rows = [r for r in rows if r["kind"] == "skill.error"]
    print("ERROR_EVENT_EMITTED", len(err_rows) == 1)
    print("ERROR_EVENT_REASON", err_rows and err_rows[0]["payload"].get("reason") == "unprovisioned")
    print("NO_GAP_EVENT", not any(r["kind"] == "skill.gap" for r in rows))
    print("NO_SKILL_INVOKE_EVENT", not any(r["kind"] == "skill.invoke" for r in rows))
finally:
    e.stop()
PY
)"
check "unprovisioned: chat returns 200" "STATUS 200" "$cap_unprov_out"
check "unprovisioned: the refusal names the capability" "REPLY_NAMES_RENDERER True" "$cap_unprov_out"
check "unprovisioned: the refusal states it is not available" "REPLY_SAYS_UNAVAILABLE True" "$cap_unprov_out"
check "unprovisioned: a skill.error trace event is emitted" "ERROR_EVENT_EMITTED True" "$cap_unprov_out"
check "unprovisioned: the error event reason is unprovisioned" "ERROR_EVENT_REASON True" "$cap_unprov_out"
check "unprovisioned: never treated as a capability gap (something WAS found)" "NO_GAP_EVENT True" "$cap_unprov_out"
check "unprovisioned: never actually invoked (Sec11.4)" "NO_SKILL_INVOKE_EVENT True" "$cap_unprov_out"
rm -rf "$_ae_unprov_root"

echo "-- integration: invalid params -- a refusal, and the underlying binary is NEVER spawned (validated before any spawn) --"
_ae_badparams_root="$(mktemp -d)"
ae_capability_repo "$_ae_badparams_root" jarvis
CE_CAP_CALL_LOG="$(mktemp -u)"

cap_badparams_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" ARGVECHO_CALL_LOG="$CE_CAP_CALL_LOG" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_badparams_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability

FENCE = chr(96) * 3
root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None

def stub_complete(context, **kwargs):
    # "city" is declared in the weather schema but never supplied -- required.
    return {"text": FENCE + 'capability\n{"name": "weather", "params": {}}\n' + FENCE, "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-badparams")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "what is the weather"})
    reply = payload.get("text", "")
    print("STATUS", status)
    print("REPLY_IS_REFUSAL", "could not" in reply.lower() or "cannot" in reply.lower())

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "skill.error" for r in rows):
            break
        time.sleep(0.2)
    err_rows = [r for r in rows if r["kind"] == "skill.error"]
    print("ERROR_EVENT_EMITTED", len(err_rows) == 1)
    print("ERROR_EVENT_REASON", err_rows and err_rows[0]["payload"].get("reason") == "invalid_params")
finally:
    e.stop()
PY
)"
check "invalid params: chat returns 200 (a refusal reply)" "STATUS 200" "$cap_badparams_out"
check "invalid params: the reply is a refusal, never a fabricated result" "REPLY_IS_REFUSAL True" "$cap_badparams_out"
check "invalid params: a skill.error trace event is emitted with reason invalid_params" "ERROR_EVENT_EMITTED True" "$cap_badparams_out"
check "invalid params: the error event reason is invalid_params" "ERROR_EVENT_REASON True" "$cap_badparams_out"
if [[ -f "$CE_CAP_CALL_LOG" ]]; then
    echo "FAIL invalid params: the underlying binary must NEVER be spawned when params are invalid (call-log file was created)"
    fails=$((fails + 1))
else
    echo "ok   invalid params: the underlying binary was never spawned (no call-log file created)"
fi
rm -f "$CE_CAP_CALL_LOG"
rm -rf "$_ae_badparams_root"

echo "-- integration: a second directive (in the same-turn follow-up reply) is IGNORED and traced -- v1 is at most ONE invocation per turn, no chains --"
_ae_second_root="$(mktemp -d)"
ae_capability_repo "$_ae_second_root" jarvis

cap_second_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_second_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability

FENCE = chr(96) * 3
root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None

calls = []
def stub_complete(context, **kwargs):
    calls.append(context)
    if len(calls) == 1:
        return {"text": FENCE + 'capability\n{"name": "weather", "params": {"city": "Rome"}}\n' + FENCE,
                "usage": None, "timings": None}
    # the FOLLOW-UP reply itself also tries to invoke a capability -- v1
    # never honors a second one in the same turn. The fence starts its OWN
    # line (round-1 review finding 3: the opening fence is anchored to
    # line start) -- a mid-sentence mention is a DIFFERENT scenario
    # (never even recognized as a fence at all, tested separately).
    return {"text": "Also, here is another one:\n" + FENCE
                     + 'capability\n{"name": "weather", "params": {"city": "Paris"}}\n' + FENCE
                     + "\nthere you go.",
            "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-second")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "weather in Rome then Paris"})
    reply = payload.get("text", "")
    print("STATUS", status)
    print("ADAPTER_CALLED_TWICE", len(calls) == 2)
    print("REPLY_NO_FENCE", (FENCE + "capability") not in reply)
    print("REPLY_KEEPS_SURROUNDING_TEXT", "Also," in reply and "there you go." in reply)

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if len([r for r in rows if r["kind"] == "skill.request"]) >= 2:
            break
        time.sleep(0.2)
    invoke_rows = [r for r in rows if r["kind"] == "skill.invoke" and r.get("status") == "start"]
    request_rows = [r for r in rows if r["kind"] == "skill.request"]
    ignored_rows = [r for r in request_rows if r.get("status") == "ignored"]
    print("EXACTLY_ONE_INVOKE_START", len(invoke_rows) == 1)
    print("SECOND_DIRECTIVE_TRACED_AS_IGNORED", len(ignored_rows) == 1)
    print("IGNORED_NAMES_PARIS_CALL", ignored_rows and ignored_rows[0]["payload"].get("params", {}).get("city") == "Paris")
finally:
    e.stop()
PY
)"
check "second directive: chat returns 200" "STATUS 200" "$cap_second_out"
check "second directive: the adapter is still called exactly twice (one invocation, one follow-up)" "ADAPTER_CALLED_TWICE True" "$cap_second_out"
check "second directive: the ignored directive fence never leaks into the final reply" "REPLY_NO_FENCE True" "$cap_second_out"
check "second directive: surrounding prose from the follow-up reply is preserved" "REPLY_KEEPS_SURROUNDING_TEXT True" "$cap_second_out"
check "second directive: exactly one skill.invoke start ever fires (v1: one invocation per turn)" "EXACTLY_ONE_INVOKE_START True" "$cap_second_out"
check "second directive: the extra directive is traced as ignored, never silently dropped" "SECOND_DIRECTIVE_TRACED_AS_IGNORED True" "$cap_second_out"
check "second directive: the ignored trace event names what was actually ignored" "IGNORED_NAMES_PARIS_CALL True" "$cap_second_out"
rm -rf "$_ae_second_root"

echo "-- integration: longRunning capability -- queued via tasks.enqueue, reply says queued, NO inline spawn (Sec9.4 sequence 3) --"
_ae_slow_root="$(mktemp -d)"
ae_capability_repo "$_ae_slow_root" jarvis
CE_SLOW_CALL_LOG="$(mktemp -u)"

cap_slow_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" ARGVECHO_CALL_LOG="$CE_SLOW_CALL_LOG" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_slow_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, tasks

FENCE = chr(96) * 3
root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None

def stub_complete(context, **kwargs):
    return {"text": FENCE + 'capability\n{"name": "slow-render", "params": {}}\n' + FENCE, "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-slow")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "please render a long video"})
    reply = payload.get("text", "")
    print("STATUS", status)
    print("REPLY_SAYS_QUEUED", "queue" in reply.lower() or "background" in reply.lower())
    print("REPLY_NO_FENCE", (FENCE + "capability") not in reply)

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = tasks.list_tasks(root)
        if any(r["kind"] == capability_index.KIND for r in rows):
            break
        time.sleep(0.2)
    slow_rows = [r for r in rows if r["kind"] == capability_index.KIND]
    print("TASK_ROW_EXISTS", len(slow_rows) == 1)
    print("TASK_KIND_IS_CAPABILITY_INVOKE", slow_rows and slow_rows[0]["kind"] == "capability-invoke")
finally:
    e.stop()
PY
)"
check "longRunning: chat returns 200" "STATUS 200" "$cap_slow_out"
check "longRunning: the reply tells the user the work is queued/backgrounded" "REPLY_SAYS_QUEUED True" "$cap_slow_out"
check "longRunning: no directive fence leaks into the queued-notice reply" "REPLY_NO_FENCE True" "$cap_slow_out"
check "longRunning: a task row is created for the capability invocation" "TASK_ROW_EXISTS True" "$cap_slow_out"
check "longRunning: the task kind is the capability-invoke kind" "TASK_KIND_IS_CAPABILITY_INVOKE True" "$cap_slow_out"
rm -f "$CE_SLOW_CALL_LOG"
rm -rf "$_ae_slow_root"

echo "-- integration: NO directive at all -- zero capability machinery invoked (flooding-guard pinned: same discipline #346 established for _capability_gap_check, extended to the whole #508 loop) --"
_ae_plain_root="$(mktemp -d)"
ae_capability_repo "$_ae_plain_root" jarvis

cap_plain_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_plain_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability

root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None

def stub_complete(context, **kwargs):
    return {"text": "just an ordinary reply about the weather, no action taken", "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-plain")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "what is the weather like today"})
    print("STATUS", status)
    print("REPLY_UNCHANGED", payload.get("text") == "just an ordinary reply about the weather, no action taken")

    time.sleep(1.0)  # let any (undesired) background machinery have a chance to fire
    rows = observability.query(root)
    print("NO_SKILL_REQUEST", not any(r["kind"] == "skill.request" for r in rows))
    print("NO_SKILL_INVOKE", not any(r["kind"] == "skill.invoke" for r in rows))
    print("NO_SKILL_GAP", not any(r["kind"] == "skill.gap" for r in rows))
    print("NO_SKILL_ERROR", not any(r["kind"] == "skill.error" for r in rows))
finally:
    e.stop()
PY
)"
check "no directive: chat returns 200" "STATUS 200" "$cap_plain_out"
check "no directive: the ordinary reply is returned completely unchanged" "REPLY_UNCHANGED True" "$cap_plain_out"
check "no directive: zero skill.request events (flooding guard)" "NO_SKILL_REQUEST True" "$cap_plain_out"
check "no directive: zero skill.invoke events" "NO_SKILL_INVOKE True" "$cap_plain_out"
check "no directive: zero skill.gap events" "NO_SKILL_GAP True" "$cap_plain_out"
check "no directive: zero skill.error events" "NO_SKILL_ERROR True" "$cap_plain_out"
rm -rf "$_ae_plain_root"

echo "-- integration: timeout -- a capability invocation that hangs past the bounded timeout surfaces skill.error and a graceful reply, never an unhandled exception or an indefinite hang --"
_ae_timeout_root="$(mktemp -d)"
ae_capability_repo "$_ae_timeout_root" jarvis

cap_timeout_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" ARGVECHO_MODE=hang ARGVECHO_HANG_SECONDS=30 SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_timeout_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability

FENCE = chr(96) * 3
root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None
# monkeypatch the bounded timeout down so this test does not actually wait
# 30s -- same house pattern as monkeypatching turns.capability_gap_reply
# above, applied to a module-level constant instead of a function.
engine.CAPABILITY_INVOKE_TIMEOUT_SECONDS = 0.5

def stub_complete(context, **kwargs):
    return {"text": FENCE + 'capability\n{"name": "weather", "params": {"city": "Rome"}}\n' + FENCE, "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-timeout")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    start = time.monotonic()
    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "what is the weather"})
    elapsed = time.monotonic() - start
    reply = payload.get("text", "")
    print("STATUS", status)
    print("BOUNDED_TIME", elapsed < 10.0)
    print("REPLY_IS_GRACEFUL", "too long" in reply.lower() or "timed out" in reply.lower() or "stopped waiting" in reply.lower())

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "skill.error" for r in rows):
            break
        time.sleep(0.2)
    err_rows = [r for r in rows if r["kind"] == "skill.error"]
    print("ERROR_EVENT_EMITTED", len(err_rows) == 1)
    print("ERROR_EVENT_STATUS_TIMEOUT", err_rows and err_rows[0].get("status") == "timeout")
finally:
    e.stop()
    engine.CAPABILITY_INVOKE_TIMEOUT_SECONDS = 30
PY
)"
check "timeout: chat still returns 200 (a graceful reply, never a raw 5xx)" "STATUS 200" "$cap_timeout_out"
check "timeout: the request completes in bounded time (the mandatory timeout was actually honored)" "BOUNDED_TIME True" "$cap_timeout_out"
check "timeout: the reply is a graceful, in-persona timeout notice" "REPLY_IS_GRACEFUL True" "$cap_timeout_out"
check "timeout: a skill.error trace event is emitted" "ERROR_EVENT_EMITTED True" "$cap_timeout_out"
check "timeout: the error event status is timeout" "ERROR_EVENT_STATUS_TIMEOUT True" "$cap_timeout_out"
rm -rf "$_ae_timeout_root"

# ==========================================================================
# #508 ROUND-1 REVIEW fixes -- engine-level pinning tests, written and
# verified RED against the pre-fix code before the fixes landed.
# ==========================================================================
echo "-- round-1 review, HIGH finding 1: a queued (longRunning) capability gets its OWN, more generous timeout -- it must survive outliving the INLINE bound, and only be bound by the TASK bound --"
_ae_tasktimeout_root="$(mktemp -d)"
ae_capability_repo "$_ae_tasktimeout_root" jarvis

cap_tasktimeout_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" ARGVECHO_MODE=hang ARGVECHO_HANG_SECONDS=2 SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_tasktimeout_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, tasks

root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None
FENCE = chr(96) * 3
# the INLINE bound is far too short to survive the fixture 2s hang; the
# TASK bound is generous enough to survive it -- if the queued path were
# still (incorrectly) using the inline bound, the task would come back
# failed/timed-out instead of completed.
engine.CAPABILITY_INVOKE_TIMEOUT_SECONDS = 0.3
engine.CAPABILITY_TASK_TIMEOUT_SECONDS = 10

def stub_complete(context, **kwargs):
    return {"text": FENCE + 'capability\n{"name": "slow-render", "params": {}}\n' + FENCE,
            "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-tasktimeout")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "please render a long video"})
    print("STATUS", status)

    deadline = time.monotonic() + 8.0
    rows = []
    while time.monotonic() < deadline:
        rows = tasks.list_tasks(root)
        matching = [r for r in rows if r["kind"] == capability_index.KIND]
        if matching and matching[0]["state"] in ("completed", "failed"):
            break
        time.sleep(0.2)
    matching = [r for r in rows if r["kind"] == capability_index.KIND]
    print("TASK_STATE", matching[0]["state"] if matching else None)
finally:
    e.stop()
    engine.CAPABILITY_INVOKE_TIMEOUT_SECONDS = 30
    engine.CAPABILITY_TASK_TIMEOUT_SECONDS = 300
PY
)"
check "task timeout: chat returns 200 (queued immediately)" "STATUS 200" "$cap_tasktimeout_out"
check "task timeout: the queued task OUTLIVES the inline bound and completes under the task bound -- never killed by the wrong timeout" \
    "TASK_STATE completed" "$cap_tasktimeout_out"
rm -rf "$_ae_tasktimeout_root"

echo "-- round-1 review finding 4: a failed same-turn follow-up completion degrades to a result-bearing reply -- the capability ALREADY ran, so this must be a 200 with the exchange appended, never a 502 that discards the outcome and invites a duplicate retry --"
_ae_followupfail_root="$(mktemp -d)"
ae_capability_repo "$_ae_followupfail_root" jarvis

cap_followupfail_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_followupfail_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability

root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None
FENCE = chr(96) * 3

calls = []
def stub_complete(context, **kwargs):
    calls.append(context)
    if len(calls) == 1:
        return {"text": FENCE + 'capability\n{"name": "weather", "params": {"city": "Rome"}}\n' + FENCE,
                "usage": None, "timings": None}
    raise adapters.NonzeroExit("provider CLI exited nonzero on the follow-up call")
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-followupfail")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "what is the weather in Rome?"})
    reply = payload.get("text", "")
    print("STATUS", status)
    print("REPLY_NOT_EMPTY", bool(reply.strip()))
    print("REPLY_MENTIONS_CAPABILITY", "weather" in reply.lower())
    print("REPLY_HAS_RESULT", "ARGV[0]=--city=Rome" in reply)

    history_status, history_payload, _ = e.handle("GET", "/assistant/history", {"n": ["5"]})
    exchanges = history_payload.get("exchanges") or history_payload.get("history") or []
    print("EXCHANGE_APPENDED", len(exchanges) >= 1)

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "skill.error" and r.get("payload", {}).get("reason") == "followup_failed" for r in rows):
            break
        time.sleep(0.2)
    followup_err_rows = [r for r in rows if r["kind"] == "skill.error"
                          and r.get("payload", {}).get("reason") == "followup_failed"]
    print("FOLLOWUP_ERROR_TRACED", len(followup_err_rows) == 1)
finally:
    e.stop()
PY
)"
check "follow-up failure: chat returns 200, never a 502 that discards the executed capability" "STATUS 200" "$cap_followupfail_out"
check "follow-up failure: the reply is not empty" "REPLY_NOT_EMPTY True" "$cap_followupfail_out"
check "follow-up failure: the reply names the capability that actually ran" "REPLY_MENTIONS_CAPABILITY True" "$cap_followupfail_out"
check "follow-up failure: the reply carries the ACTUAL result, not a generic error" "REPLY_HAS_RESULT True" "$cap_followupfail_out"
check "follow-up failure: an exchange IS appended (never silently dropped)" "EXCHANGE_APPENDED True" "$cap_followupfail_out"
check "follow-up failure: traced as skill.error with reason followup_failed" "FOLLOWUP_ERROR_TRACED True" "$cap_followupfail_out"
rm -rf "$_ae_followupfail_root"

echo "-- round-1 review finding 5: a follow-up reply that is nothing but a (never-honored) directive strips down to empty -- must fall back to the same result-bearing template, never an empty 200 --"
_ae_emptyfollowup_root="$(mktemp -d)"
ae_capability_repo "$_ae_emptyfollowup_root" jarvis

cap_emptyfollowup_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_emptyfollowup_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine

root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None
FENCE = chr(96) * 3

calls = []
def stub_complete(context, **kwargs):
    calls.append(context)
    if len(calls) == 1:
        return {"text": FENCE + 'capability\n{"name": "weather", "params": {"city": "Rome"}}\n' + FENCE,
                "usage": None, "timings": None}
    # the follow-up reply is ITSELF nothing but another (never-honored)
    # directive -- nothing left once it is stripped.
    return {"text": FENCE + 'capability\n{"name": "weather", "params": {"city": "Paris"}}\n' + FENCE,
            "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-emptyfollowup")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "what is the weather in Rome?"})
    reply = payload.get("text", "")
    print("STATUS", status)
    print("REPLY_NOT_EMPTY", bool(reply.strip()))
    print("REPLY_NO_FENCE", (FENCE + "capability") not in reply)
finally:
    e.stop()
PY
)"
check "empty follow-up: chat returns 200" "STATUS 200" "$cap_emptyfollowup_out"
check "empty follow-up: the reply is never empty -- falls back to a result-bearing template" "REPLY_NOT_EMPTY True" "$cap_emptyfollowup_out"
check "empty follow-up: no raw directive fence leaks into the fallback either" "REPLY_NO_FENCE True" "$cap_emptyfollowup_out"
rm -rf "$_ae_emptyfollowup_root"

echo "-- round-1 review finding 6a (mutation guard): TWO directives in the FIRST completion -- the FIRST is invoked, the SECOND is only traced ignored (kills the directives[-1] mutant) --"
_ae_twoinone_root="$(mktemp -d)"
ae_capability_repo "$_ae_twoinone_root" jarvis

cap_twoinone_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_twoinone_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability

root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None
FENCE = chr(96) * 3

calls = []
def stub_complete(context, **kwargs):
    calls.append(context)
    if len(calls) == 1:
        return {"text": (FENCE + 'capability\n{"name": "weather", "params": {"city": "Rome"}}\n' + FENCE
                          + "\n" + FENCE + 'capability\n{"name": "weather", "params": {"city": "Paris"}}\n' + FENCE),
                "usage": None, "timings": None}
    # the follow-up reply is ordinary prose -- no directive of its own, so
    # this test isolates the two-in-ONE-completion behavior cleanly.
    return {"text": "done.", "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-twoinone")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "weather in Rome then Paris"})
    print("STATUS", status)

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "skill.invoke" and r.get("status") == "ok" for r in rows):
            break
        time.sleep(0.2)
    request_rows = [r for r in rows if r["kind"] == "skill.request"]
    invoke_starts = [r for r in rows if r["kind"] == "skill.invoke" and r.get("status") == "start"]
    parsed_rows = [r for r in request_rows if r.get("status") == "parsed"]
    ignored_rows = [r for r in request_rows if r.get("status") == "ignored"]
    print("EXACTLY_ONE_INVOKE", len(invoke_starts) == 1)
    print("PARSED_IS_ROME", len(parsed_rows) == 1 and parsed_rows[0]["payload"].get("params", {}).get("city") == "Rome")
    print("IGNORED_IS_PARIS", len(ignored_rows) == 1 and ignored_rows[0]["payload"].get("params", {}).get("city") == "Paris")
finally:
    e.stop()
PY
)"
check "two-in-one (mutation guard): chat returns 200" "STATUS 200" "$cap_twoinone_out"
check "two-in-one (mutation guard): exactly one invocation ever fires" "EXACTLY_ONE_INVOKE True" "$cap_twoinone_out"
check "two-in-one (mutation guard): the FIRST directive (Rome) is the one traced parsed/invoked" "PARSED_IS_ROME True" "$cap_twoinone_out"
check "two-in-one (mutation guard, kills the directives[-1] mutant): the SECOND (Paris) is only traced ignored, never invoked" "IGNORED_IS_PARIS True" "$cap_twoinone_out"
rm -rf "$_ae_twoinone_root"

echo "-- round-1 review finding 6b (mutation guard): a malformed FIRST directive -> invalid_directive trace + a graceful reply, never a raw exception (kills the dropped-short-circuit mutant) --"
_ae_malformedfirst_root="$(mktemp -d)"
ae_capability_repo "$_ae_malformedfirst_root" jarvis

cap_malformedfirst_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_malformedfirst_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability

root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None
FENCE = chr(96) * 3

def stub_complete(context, **kwargs):
    return {"text": FENCE + "capability\nthis is not valid json at all\n" + FENCE,
            "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-malformedfirst")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "please do the thing"})
    reply = payload.get("text", "")
    print("STATUS", status)
    print("REPLY_NOT_EMPTY", bool(reply.strip()))
    print("REPLY_NO_RAW_JSON", "not valid json at all" not in reply)

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "skill.error" for r in rows):
            break
        time.sleep(0.2)
    err_rows = [r for r in rows if r["kind"] == "skill.error"]
    print("ERROR_EVENT_EMITTED", len(err_rows) == 1)
    print("ERROR_REASON_INVALID_DIRECTIVE", err_rows and err_rows[0]["payload"].get("reason") == "invalid_directive")
finally:
    e.stop()
PY
)"
check "malformed first directive (mutation guard): chat returns 200, never a raw exception" "STATUS 200" "$cap_malformedfirst_out"
check "malformed first directive: the reply is graceful, never empty" "REPLY_NOT_EMPTY True" "$cap_malformedfirst_out"
check "malformed first directive: the raw malformed body never leaks into the reply" "REPLY_NO_RAW_JSON True" "$cap_malformedfirst_out"
check "malformed first directive: a skill.error event is emitted" "ERROR_EVENT_EMITTED True" "$cap_malformedfirst_out"
check "malformed first directive (mutation guard): its reason is invalid_directive" "ERROR_REASON_INVALID_DIRECTIVE True" "$cap_malformedfirst_out"
rm -rf "$_ae_malformedfirst_root"

echo "-- round-1 review finding 8: an unexpected internal exception anywhere in the capability hook degrades to a traced error + plain reply, never a dropped connection with no turn.end --"
_ae_hookbug_root="$(mktemp -d)"
ae_capability_repo "$_ae_hookbug_root" jarvis

cap_hookbug_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_hookbug_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability

root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None
FENCE = chr(96) * 3

def stub_complete(context, **kwargs):
    return {"text": FENCE + 'capability\n{"name": "weather", "params": {"city": "Rome"}}\n' + FENCE,
            "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

def boom(index, name):
    raise RuntimeError("synthetic internal bug inside the capability hook")

original_resolve = capability_index.resolve_by_name
capability_index.resolve_by_name = boom

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-hookbug")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "what is the weather"})
    reply = payload.get("text", "")
    print("STATUS", status)
    print("REPLY_NOT_EMPTY", bool(reply.strip()))

    deadline = time.monotonic() + 5.0
    rows = []
    while time.monotonic() < deadline:
        rows = observability.query(root)
        if any(r["kind"] == "turn.end" for r in rows):
            break
        time.sleep(0.2)
    err_rows = [r for r in rows if r["kind"] == "skill.error"
                and r.get("payload", {}).get("reason") == "internal_exception"]
    turn_end_rows = [r for r in rows if r["kind"] == "turn.end"]
    print("INTERNAL_ERROR_TRACED", len(err_rows) == 1)
    print("TURN_END_STILL_EMITTED", len(turn_end_rows) == 1)
finally:
    capability_index.resolve_by_name = original_resolve
    e.stop()
PY
)"
check "outer hook guard: chat still returns 200, never crashes the request" "STATUS 200" "$cap_hookbug_out"
check "outer hook guard: the reply is graceful, never empty" "REPLY_NOT_EMPTY True" "$cap_hookbug_out"
check "outer hook guard: an internal_exception skill.error event is emitted" "INTERNAL_ERROR_TRACED True" "$cap_hookbug_out"
check "outer hook guard: turn.end still fires -- never a dropped connection with no terminal trace" "TURN_END_STILL_EMITTED True" "$cap_hookbug_out"
rm -rf "$_ae_hookbug_root"

echo "-- round-1 review finding 3 (engine-level, matches the live reproduction from review): teach-then-quote through the real chat path -- a directive DEMONSTRATED mid-explanation, with more prose after it, must never actually invoke anything --"
_ae_teachquote_root="$(mktemp -d)"
ae_capability_repo "$_ae_teachquote_root" jarvis

cap_teachquote_out="$(PATH="$AE_ARGVECHO_BIN:$PATH" SCRIPTS_DIR="$AE_SCRIPTS" ROOT="$_ae_teachquote_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, capability_index, engine, observability

root = os.environ["ROOT"]
capability_index._default_embed_fn = lambda texts: None
FENCE = chr(96) * 3

def stub_complete(context, **kwargs):
    return {"text": ("Here is how you would ask for it:\n" + FENCE
                      + 'capability\n{"name": "weather", "params": {"city": "Rome"}}\n' + FENCE
                      + "\nBut I do not actually have live weather data, so I cannot run this for you."),
            "usage": None, "timings": None}
adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state-cap-teachquote")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline and len(e.capability_index_for(root).entries) < 3:
        time.sleep(0.1)

    status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "how would I check the weather?"})
    reply = payload.get("text", "")
    print("STATUS", status)
    print("REPLY_NO_FENCE", (FENCE + "capability") not in reply)
    print("REPLY_KEEPS_EXPLANATION", "Here is how you would ask for it:" in reply
          and "cannot run this for you" in reply)

    time.sleep(1.0)  # give any (undesired) invocation a chance to fire
    rows = observability.query(root)
    print("NO_SKILL_INVOKE", not any(r["kind"] == "skill.invoke" for r in rows))
finally:
    e.stop()
PY
)"
check "teach-then-quote (engine-level, live-reproduced by review): chat returns 200" "STATUS 200" "$cap_teachquote_out"
check "teach-then-quote: the fence is stripped from the reply" "REPLY_NO_FENCE True" "$cap_teachquote_out"
check "teach-then-quote: the surrounding explanation survives intact" "REPLY_KEEPS_EXPLANATION True" "$cap_teachquote_out"
check "teach-then-quote: NOTHING is ever actually invoked -- a demonstrated example must never fire" "NO_SKILL_INVOKE True" "$cap_teachquote_out"
rm -rf "$_ae_teachquote_root"
