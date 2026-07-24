#!/usr/bin/env bash
# section-assistant-distill.sh -- AST-030: distiller worker, batched
# mint+bump (SPEC-ASSISTANT.md Sec9.2/Sec9.5, docs/design/ast-E3.md, issue
# #322). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant distiller (AST-030: batched mint+bump, SPEC-ASSISTANT.md Sec9.2/Sec9.5) =="

AD_SCRIPTS="$PLUGIN/scripts"

# ad_repo <dir> <main> -- mirrors the house assistant fixture pattern (e.g.
# section-assistant-switch.sh asw_repo), provider registered locally as a
# stub (below) rather than a real provider CLI.
ad_repo() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude"
    printf "%s\n" "# neural-network" >"$dir/.claude/.neural-network"
    printf "%s\n" \
        "schemaVersion: 2" \
        "assistant:" \
        "    version: 1" \
        "    enabled: true" \
        "    names: [$main]" \
        "    systemPrompt: |" \
        "        You are $main." \
        "    llm:" \
        "        provider: openai" \
        "        model: gpt-5.6-sol" \
        "    capabilities:" \
        "        codex:" \
        "            enabled: true" \
        "            provisioning:" \
        "                bin: codex" \
        >"$dir/.claude/project.yaml"
}

# ------------------------------------------------------------------------
echo "-- unit: process_batch mints deterministic notes + bumps a recalled note --"
unit_out="$(SCRIPTS_DIR="$AD_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import distill
import brain

root = tempfile.mkdtemp(prefix="ad-unit-")
identities = os.path.join(root, ".claude", "identities")
os.makedirs(identities, exist_ok=True)

exchanges = [
    {"user": "how do I configure the widget factory pipeline", "assistant": "use the widget factory config file"}
    for _ in range(8)
]

# same batch content processed twice -> DETERMINISTIC slug (re-mint bumps
# the same note, never a duplicate)
r1 = distill.process_batch(identities, root, exchanges, role="assistant")
r2 = distill.process_batch(identities, root, exchanges, role="assistant")
print("MINT1", r1["minted"])
print("MINT2", r2["minted"])
print("SAME_SLUG", r1["minted"] == r2["minted"] and len(r1["minted"]) == 1)

notes = brain.load_notes(identities, "assistant")
slug = r1["minted"][0]
print("STRENGTH_AFTER_TWO_MINTS", notes[slug]["fm"]["strength"])
print("TAGS_NONEMPTY", bool(notes[slug]["fm"].get("tags")))

# an existing note, recalled by a chip on the exchange -> bump (strength+1)
brain.mint(identities, "assistant", "existing-note", root, "an existing lesson body\n", tags="lessons")
before = brain.load_notes(identities, "assistant")["existing-note"]["fm"]["strength"]
bump_batch = [{"user": "ok", "assistant": "ok", "chips": [{"slug": "existing-note", "strength": before}]}]
r3 = distill.process_batch(identities, root, bump_batch, role="assistant")
after = brain.load_notes(identities, "assistant")["existing-note"]["fm"]["strength"]
print("BUMPED_SLUGS", r3["bumped"])
print("BUMP_STRENGTH_DELTA", after - before)
print("BUMP_NO_MINT", r3["minted"])

# an unknown chip slug (already-pruned note) is skipped, never an error
skip_batch = [{"user": "hi", "assistant": "there", "chips": [{"slug": "no-such-note"}]}]
r4 = distill.process_batch(identities, root, skip_batch, role="assistant")
print("UNKNOWN_CHIP_SKIPPED", r4["bumped"])
PY
)"
check "process_batch: first mint produces exactly one slug" "MINT1 [" "$unit_out"
check "process_batch: re-processing the SAME batch bumps the SAME slug (deterministic, not a new note)" "SAME_SLUG True" "$unit_out"
check "process_batch: second mint of the same batch bumped strength to 2" "STRENGTH_AFTER_TWO_MINTS 2" "$unit_out"
check "process_batch: minted note carries extracted keyword tags" "TAGS_NONEMPTY True" "$unit_out"
check "process_batch: a chip on an exchange bumps the recalled note" "BUMPED_SLUGS ['existing-note']" "$unit_out"
check "process_batch: bump increments strength by exactly 1" "BUMP_STRENGTH_DELTA 1" "$unit_out"
check "process_batch: a bump-only batch mints nothing new (bump text has no qualifying keywords)" "BUMP_NO_MINT []" "$unit_out"
check "process_batch: an unknown chip slug is skipped, not an error" "UNKNOWN_CHIP_SKIPPED []" "$unit_out"

# ------------------------------------------------------------------------
echo "-- unit: batching triggers at N, never before --"
batch_out="$(SCRIPTS_DIR="$AD_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, time, queue
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import distill
import brain

root = tempfile.mkdtemp(prefix="ad-batchn-")
identities = os.path.join(root, ".claude", "identities")
os.makedirs(identities, exist_ok=True)

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=distill.run_worker, args=(q, stop), kwargs={"batch_n": 3})
t.start()

def item(i):
    return {"root": root, "identities": identities,
            "exchange": {"user": "message number %d about rocket telemetry" % i, "assistant": "ack"}}

q.put(item(0))
q.put(item(1))
time.sleep(0.6)  # generous watchdog -- worker must have drained both by now
print("BEFORE_N", len(brain.load_notes(identities, "assistant")))

q.put(item(2))  # the 3rd item crosses batch_n=3
time.sleep(0.6)
print("AT_N", len(brain.load_notes(identities, "assistant")))

stop.set()
t.join(timeout=3)
print("WORKER_JOINED", not t.is_alive())
PY
)"
check "batching: nothing minted before N exchanges accumulate" "BEFORE_N 0" "$batch_out"
check "batching: exactly one batch-level note minted once N is reached" "AT_N 1" "$batch_out"
check "batching: worker thread joins cleanly after stop()" "WORKER_JOINED True" "$batch_out"

# ------------------------------------------------------------------------
echo "-- unit: per-root isolation -- two repos exchanges never mix into one batch --"
iso_out="$(SCRIPTS_DIR="$AD_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, time, queue
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import distill
import brain

root_a = tempfile.mkdtemp(prefix="ad-iso-a-")
root_b = tempfile.mkdtemp(prefix="ad-iso-b-")
ident_a = os.path.join(root_a, ".claude", "identities")
ident_b = os.path.join(root_b, ".claude", "identities")
os.makedirs(ident_a, exist_ok=True)
os.makedirs(ident_b, exist_ok=True)

q = queue.Queue()
stop = threading.Event()
t = threading.Thread(target=distill.run_worker, args=(q, stop), kwargs={"batch_n": 2})
t.start()

def item(root, identities, i):
    return {"root": root, "identities": identities,
            "exchange": {"user": "message %d about alpha telemetry" % i, "assistant": "ack"}}

# root A reaches N=2 -- root B only ever gets 1 exchange, below threshold
q.put(item(root_a, ident_a, 0))
q.put(item(root_b, ident_b, 0))
q.put(item(root_a, ident_a, 1))
time.sleep(0.6)

stop.set()
t.join(timeout=3)
print("ROOT_A_NOTES", len(brain.load_notes(ident_a, "assistant")))
print("ROOT_B_NOTES", len(brain.load_notes(ident_b, "assistant")))
PY
)"
check "per-root isolation: root A reached its own N=2 and distilled" "ROOT_A_NOTES 1" "$iso_out"
check "per-root isolation: root B never reached N=2 and stayed unbatched (no cross-root mixing)" "ROOT_B_NOTES 0" "$iso_out"

# ------------------------------------------------------------------------
echo "-- unit: a poison batch logs and drops; a subsequent good batch still processes --"
poison_out="$(SCRIPTS_DIR="$AD_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, time, queue, io, contextlib
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import distill
import brain

root = tempfile.mkdtemp(prefix="ad-poison-")
identities = os.path.join(root, ".claude", "identities")
os.makedirs(identities, exist_ok=True)

q = queue.Queue()
stop = threading.Event()
stderr_buf = io.StringIO()

def run():
    with contextlib.redirect_stderr(stderr_buf):
        distill.run_worker(q, stop, batch_n=2)

t = threading.Thread(target=run)
t.start()

# poison item: a non-string "user" field trips _batch_body slicing (an
# int has no .strip()/slicing-into-a-string) once keywords are found --
# raised from inside process_batch, caught by run_worker.
poison = {"root": root, "identities": identities,
          "exchange": {"user": 12345, "assistant": "telemetry rocket alpha words"}}
q.put(poison)
q.put({"root": root, "identities": identities,
       "exchange": {"user": "telemetry rocket alpha words", "assistant": "ack"}})
time.sleep(0.6)
print("NOTES_AFTER_POISON_BATCH", len(brain.load_notes(identities, "assistant")))

# a good batch right after -- worker must still be alive and processing
good = [{"root": root, "identities": identities,
         "exchange": {"user": "second batch about gamma telemetry system", "assistant": "ack"}}
        for _ in range(2)]
for g in good:
    q.put(g)
time.sleep(0.6)
print("WORKER_ALIVE_AFTER_POISON", t.is_alive())
print("NOTES_AFTER_GOOD_BATCH", len(brain.load_notes(identities, "assistant")))

stop.set()
t.join(timeout=3)
print("STDERR_MENTIONS_FAILURE", "distiller worker" in stderr_buf.getvalue())
PY
)"
check "poison batch: the failing batch is dropped, nothing minted from it" "NOTES_AFTER_POISON_BATCH 0" "$poison_out"
check "poison batch: the worker thread survives the exception (park-and-continue)" "WORKER_ALIVE_AFTER_POISON True" "$poison_out"
check "poison batch: a subsequent good batch still processes normally" "NOTES_AFTER_GOOD_BATCH 1" "$poison_out"
check "poison batch: the failure was logged to stderr, not swallowed silently" "STDERR_MENTIONS_FAILURE True" "$poison_out"

# ------------------------------------------------------------------------
echo "-- grep guard: distill.py performs no merge/retire/aggregate (NG3, v1 scope) --"
distill_src="$(cat "$AD_SCRIPTS/assistant/distill.py")"
check_absent "distill.py defines no merge function" "def merge" "$distill_src"
check_absent "distill.py defines no retire function" "def retire" "$distill_src"
check_absent "distill.py defines no aggregate function" "def aggregate" "$distill_src"

# ------------------------------------------------------------------------
echo "-- integration: engine wiring -- _chat enqueues post-turn, real distiller worker drains it --"
_ad_root="$(mktemp -d)"
ad_repo "$_ad_root" jarvis

int_out="$(SCRIPTS_DIR="$AD_SCRIPTS" ROOT="$_ad_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, distill, engine
import brain

root = os.environ["ROOT"]
identities = os.path.join(root, ".claude", "identities")

def stub_complete(context, **kwargs):
    return {"text": "reply about rocket telemetry systems", "usage": None, "timings": None}

adapters.register_adapter("openai", stub_complete)

state_dir = os.path.join(root, ".claude", "assistant-engine-state")
e = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir)
e.start()
try:
    n = distill.DEFAULT_BATCH_N
    for i in range(n):
        status, payload, _ = e.handle("POST", "/assistant/chat", body={"message": "tell me about rocket telemetry %d" % i})
        if status != 200:
            print("CHAT_FAILED", status, payload)
            break
    else:
        # bounded watchdog -- the worker polls every 0.5s (DEFAULT_POLL_TIMEOUT_SECONDS)
        deadline = time.monotonic() + 5.0
        minted = 0
        while time.monotonic() < deadline:
            minted = len(brain.load_notes(identities, "assistant"))
            if minted >= 1:
                break
            time.sleep(0.2)
        print("MINTED_VIA_REAL_ENGINE", minted)

        events_path = os.path.join(root, ".claude", "brain-events.jsonl")
        events_text = open(events_path, encoding="utf-8").read() if os.path.exists(events_path) else ""
        print("BRAIN_EVENT_NOTE_MINTED", '"type": "NoteMinted"' in events_text)
finally:
    e.stop()
    print("ENGINE_STOPPED_CLEANLY", True)
PY
)"
check "engine wiring: N turns through the real engine trigger a real distilled mint" "MINTED_VIA_REAL_ENGINE 1" "$int_out"
check "engine wiring: the distilled mint emitted a NoteMinted brain-event (AST-024 digest source)" "BRAIN_EVENT_NOTE_MINTED True" "$int_out"
check "engine wiring: engine.stop() still joins the (now real) distiller worker cleanly" "ENGINE_STOPPED_CLEANLY True" "$int_out"
if [[ "$int_out" != *"MINTED_VIA_REAL_ENGINE 1"* ]]; then echo "$int_out" >&2; fi
rm -rf "$_ad_root"

# ------------------------------------------------------------------------
echo "-- integration: turns never block on the distiller (bounded latency under a large backlog) --"
_adl_root="$(mktemp -d)"
ad_repo "$_adl_root" jarvis

latency_out="$(SCRIPTS_DIR="$AD_SCRIPTS" ROOT="$_adl_root" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, engine

root = os.environ["ROOT"]

def stub_complete(context, **kwargs):
    return {"text": "reply", "usage": None, "timings": None}

adapters.register_adapter("openai", stub_complete)

def timed_chat_calls(e, count):
    t0 = time.monotonic()
    for i in range(count):
        status, _payload, _ct = e.handle("POST", "/assistant/chat", body={"message": "hello %d" % i})
        if status != 200:
            return None
    return time.monotonic() - t0

state_dir_baseline = os.path.join(root, ".claude", "assistant-engine-state-baseline")
e_baseline = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir_baseline)
e_baseline.start()
baseline_elapsed = timed_chat_calls(e_baseline, 10)
e_baseline.stop()

state_dir_loaded = os.path.join(root, ".claude", "assistant-engine-state-loaded")
e_loaded = engine.AssistantEngine(lambda: [("jarvis", root)], state_dir_loaded)
e_loaded.start()
# stuff a large synthetic backlog DIRECTLY onto the distiller queue -- the
# worker will be busy chewing through it via process_batch real brain.mint
# I/O (same identities dir the chat turns below also write session state
# under) while the request thread below runs turns concurrently.
identities = os.path.join(root, ".claude", "identities")
backlog_q = e_loaded.queues["distiller"]
for i in range(500):
    try:
        backlog_q.put_nowait({
            "root": root, "identities": identities,
            "exchange": {"user": "backlog exchange %d about telemetry rocket alpha gamma" % i, "assistant": "ack"},
        })
    except Exception:
        break

loaded_elapsed = timed_chat_calls(e_loaded, 10)
e_loaded.stop()

print("BASELINE_ELAPSED", baseline_elapsed)
print("LOADED_ELAPSED", loaded_elapsed)
# generous bound: ordering assertion, not a perf benchmark (design doc
# own framing) -- turns must complete quickly even with the worker
# actively distilling a large backlog, not merely "eventually".
print("LOADED_UNDER_BOUND", loaded_elapsed is not None and loaded_elapsed < 10.0)
print("LOADED_NOT_WORSE_THAN_10X_BASELINE",
      loaded_elapsed is not None and baseline_elapsed is not None
      and loaded_elapsed < max(baseline_elapsed * 10.0, 5.0))
PY
)"
check "latency: 10 turns complete quickly even while the distiller chews a 500-item backlog" "LOADED_UNDER_BOUND True" "$latency_out"
check "latency: loaded-worker latency stays within a generous multiple of the idle baseline" "LOADED_NOT_WORSE_THAN_10X_BASELINE True" "$latency_out"
rm -rf "$_adl_root"
