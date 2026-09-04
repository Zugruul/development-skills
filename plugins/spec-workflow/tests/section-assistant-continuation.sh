#!/usr/bin/env bash
# section-assistant-continuation.sh -- AST-033: background continuation for
# inactive assistants (SPEC-ASSISTANT.md Sec9.6, docs/design/ast-E3.md,
# issue #325). Sourced by run-tests.sh; do not run standalone. Contract: the
# runner already defines set -uo pipefail and has sourced _lib.sh (check/
# check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky before sourcing
# this file. This file assumes those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant background continuation (AST-033: Sec9.6, SPEC-ASSISTANT.md) =="

AC_SCRIPTS="$PLUGIN/scripts"

# ac_repo <dir> <main> -- mirrors section-assistant-switch.sh's asw_repo /
# section-assistant-distill.sh's ad_repo fixture pattern.
ac_repo() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude" "$dir/.neural-network"
    printf "%s\n" "# neural-network" >"$dir/.neural-network/marker"
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
        >"$dir/.neural-network/project.yaml"
}

# ------------------------------------------------------------------------
echo "-- integration: an inactive (non-selected) assistants buffered exchanges keep distilling, and its digest picks up the notes minted while it was inactive (Sec9.6 -> Sec7.8 loop) --"
_ac_a="$(mktemp -d)"
_ac_b="$(mktemp -d)"
ac_repo "$_ac_a" jarvis
ac_repo "$_ac_b" friday
_ac_state="$(mktemp -d)"

cont_out="$(SCRIPTS_DIR="$AC_SCRIPTS" MA="$_ac_a" MB="$_ac_b" STATE="$_ac_state" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import adapters, distill, engine
import brain

root_a = os.environ["MA"]
root_b = os.environ["MB"]
state_dir = os.environ["STATE"]
identities_a = os.path.join(root_a, ".neural-network", "identities")

def stub_complete(context, **kwargs):
    return {"text": "reply about rocket telemetry systems", "usage": None, "timings": None}

adapters.register_adapter("openai", stub_complete)

repos = lambda: [("jarvis", root_a), ("friday", root_b)]
e = engine.AssistantEngine(repos, state_dir)
e.start()
workers_before = list(e.workers)

# jarvis is the active/selected assistant to start with.
code, _p, _ = e.handle("POST", "/assistant/select", body={"name": "jarvis"})
print("INITIAL_SELECT_CODE", code)

n = distill.DEFAULT_BATCH_N

# drive N-1 turns against jarvis explicitly (assistant flag, not relying on
# whichever one is currently selected) -- buffers, does not yet cross the
# batch threshold.
for i in range(n - 1):
    status, payload, _ = e.handle(
        "POST", "/assistant/chat",
        body={"message": "tell me about rocket telemetry %d" % i, "assistant": "jarvis"})
    if status != 200:
        print("PRECHAT_FAILED", status, payload)
        break
print("BEFORE_SWITCH_NOTES", len(brain.load_notes(identities_a, "assistant")))

# switch selection AWAY from jarvis to friday -- jarvis stops being the
# selected assistant from this point on (its lastActive is stamped now).
code, switch_payload, _ = e.handle("POST", "/assistant/select", body={"name": "friday"})
print("SWITCH_AWAY_CODE", code)
print("SWITCH_AWAY_SELECTED", switch_payload["selected"])

# brain-events.jsonl timestamps are second-resolution (brain.now_iso), while
# the lastActive stamp just taken carries microseconds -- a real background
# batch naturally spans whole seconds (turns.py plus worker polling), but
# this synthetic drive can complete within the SAME wall-clock second. Cross
# a real second boundary here so the digest strictly-after comparison below
# is deterministic rather than a same-second race.
time.sleep(1.1)

# the Nth turn against jarvis, sent while it is NOT the selected assistant --
# Sec9.6: its distiller keeps running regardless of selection.
status, payload, _ = e.handle(
    "POST", "/assistant/chat",
    body={"message": "tell me about rocket telemetry final", "assistant": "jarvis"})
print("POST_SWITCH_CHAT_STATUS", status)

deadline = time.monotonic() + 5.0
minted = 0
while time.monotonic() < deadline:
    minted = len(brain.load_notes(identities_a, "assistant"))
    if minted >= 1:
        break
    time.sleep(0.2)
print("MINTED_WHILE_INACTIVE", minted)

events_path = os.path.join(root_a, ".neural-network", "brain-events", "test.jsonl")
events_text = open(events_path, encoding="utf-8").read() if os.path.exists(events_path) else ""
print("BRAIN_EVENT_WHILE_INACTIVE", '"type": "NoteMinted"' in events_text)

print("WORKERS_UNCHANGED_THROUGHOUT", e.workers == workers_before)
print("WORKERS_STILL_ALIVE", all(t.is_alive() for _, t, _ in e.workers))

# switch back to jarvis -- its digest must surface the note minted while it
# was inactive (Sec9.6 feeds Sec7.8), sourced from the lastActive stamp
# recorded at the moment it stopped being selected above.
code, back_payload, _ = e.handle("POST", "/assistant/select", body={"name": "jarvis"})
print("SWITCH_BACK_CODE", code)
print("SWITCH_BACK_HAS_DIGEST", "digest" in back_payload)
minted_slugs = set(brain.load_notes(identities_a, "assistant").keys())
digest_slugs = set(nd["slug"] for nd in back_payload.get("digest", {}).get("notesMinted", []))
print("SWITCH_BACK_DIGEST_SLUGS_MATCH_MINTED", digest_slugs == minted_slugs and len(minted_slugs) >= 1)

e.stop()
print("ENGINE_STOPPED_CLEANLY", True)
PY
)"
rc=$?
check_rc "continuation script exits 0" 0 "$rc"
check "initial select of jarvis exits 200" "INITIAL_SELECT_CODE 200" "$cont_out"
check "before the switch, N-1 turns have not yet crossed the batch threshold" "BEFORE_SWITCH_NOTES 0" "$cont_out"
check "switch away from jarvis exits 200" "SWITCH_AWAY_CODE 200" "$cont_out"
check "switch away selects friday" "SWITCH_AWAY_SELECTED friday" "$cont_out"
check "a chat against the now-inactive jarvis still succeeds (chat targets a resolved assistant, not merely the selected one)" "POST_SWITCH_CHAT_STATUS 200" "$cont_out"
check "the Nth turn crosses the threshold and mints, even though jarvis is not selected" "MINTED_WHILE_INACTIVE 1" "$cont_out"
check "the mint while inactive emitted a NoteMinted brain-event (digest source)" "BRAIN_EVENT_WHILE_INACTIVE True" "$cont_out"
check "the worker registry is unchanged across the whole select/chat/select sequence" "WORKERS_UNCHANGED_THROUGHOUT True" "$cont_out"
check "every worker thread stays alive throughout" "WORKERS_STILL_ALIVE True" "$cont_out"
check "switching back to jarvis exits 200" "SWITCH_BACK_CODE 200" "$cont_out"
check "switching back to jarvis carries a digest" "SWITCH_BACK_HAS_DIGEST True" "$cont_out"
check "the digest on switching back includes exactly the note minted while jarvis was inactive" "SWITCH_BACK_DIGEST_SLUGS_MATCH_MINTED True" "$cont_out"
if [[ "$rc" -ne 0 ]]; then echo "$cont_out" >&2; fi
rm -rf "$_ac_a" "$_ac_b" "$_ac_state"

# ------------------------------------------------------------------------
echo "-- grep guard: run_worker buffers per-root, never filters by engine selection state (Sec9.6: no selection/gating hook in the distiller loop) --"
distill_src="$(cat "$AC_SCRIPTS/assistant/distill.py")"
check_absent "distill.py never imports the selection_store (worker has no notion of which assistant is selected)" "selection_store" "$distill_src"
check_absent "distill.py never reads a _selected/_gated field (no per-assistant active-only filtering)" "_selected" "$distill_src"
