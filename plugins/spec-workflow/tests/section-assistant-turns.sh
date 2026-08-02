#!/usr/bin/env bash
# section-assistant-turns.sh -- AST-013: turn pipeline -- context builder +
# budgets + recall injection (SPEC-ASSISTANT.md Sec8.2, Sec8.3, Sec9.1,
# issue #311). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant turn pipeline (AST-013: context builder + budgets + recall injection, SPEC-ASSISTANT.md Sec8.2/Sec8.3/Sec9.1) =="

AT_SCRIPTS="$PLUGIN/scripts"

# ------------------------------------------------------- (1) basic compose: ordering + shapes
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import sys
from assistant import turns

persona_cfg = {
    "systemPrompt": "You are Jarvis, terse and helpful.",
    "names": ["Jarvis", "J"],
    "llm": {"provider": "claude", "model": "claude-fable-5"},
}

def roster_provider():
    return [{"name": "search", "one-liner": "web search", "available": True}]

def recall_fn(message):
    return {"blocks": ["### note-one  [strength 2]\nbody text"], "seeds": 1, "injected": 1, "links_fired": []}

session_state = {"summary": "prior recap", "turns": [{"role": "user", "text": "hi"}, {"role": "assistant", "text": "hello"}]}

result = turns.compose_context(persona_cfg, roster_provider, recall_fn, session_state, "what's the weather?")

ctx = result["context_for_adapter"]
sys_text = ctx["system"]
print("HAS_KEYS", sorted(result.keys()) == ["budget_report", "chips", "context_for_adapter"])
print("INPUT_IS_RAW", ctx["input"] == "what's the weather?")
print("MODEL_PASSED", ctx.get("model") == "claude-fable-5")
print("PERSONA_BEFORE_ROSTER", sys_text.find("Jarvis, terse") < sys_text.find("search"))
print("ROSTER_BEFORE_SUMMARY", sys_text.find("search") < sys_text.find("prior recap"))
print("SUMMARY_BEFORE_NOTES", sys_text.find("prior recap") < sys_text.find("note-one"))
print("NOTES_BEFORE_TURNS", sys_text.find("note-one") < sys_text.find("hello"))
print("NAMES_ALIAS_PRESENT", "J" in sys_text)
print("CHIPS", result["chips"])
print("BUDGET_TOTAL_CAP", result["budget_report"]["total_cap"])
print("NOT_OVER_BUDGET", result["budget_report"]["over_budget"] is False)
PY
)"
check "compose: returns exactly the three documented top-level keys" "HAS_KEYS True" "$out"
check "compose: input carries the RAW user message verbatim" "INPUT_IS_RAW True" "$out"
check "compose: model passed through from persona_cfg.llm.model" "MODEL_PASSED True" "$out"
check "compose: persona precedes roster in system text" "PERSONA_BEFORE_ROSTER True" "$out"
check "compose: roster precedes rolling summary in system text" "ROSTER_BEFORE_SUMMARY True" "$out"
check "compose: rolling summary precedes recalled notes in system text (AST-032 note-wins ordering)" "SUMMARY_BEFORE_NOTES True" "$out"
check "compose: recalled notes precede last-N turns in system text" "NOTES_BEFORE_TURNS True" "$out"
check "compose: name alias rendered into system text" "NAMES_ALIAS_PRESENT True" "$out"
check "compose: chips derived from recall blocks" "'slug': 'note-one', 'strength': 2" "$out"
check "compose: budget_report.total_cap is the documented ~6k token budget" "BUDGET_TOTAL_CAP 6000" "$out"
check "compose: small inputs never trip over_budget" "NOT_OVER_BUDGET True" "$out"

# ------------------------------------------------------- (2) empty roster placeholder + missing recall
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

persona_cfg = {"systemPrompt": "P", "names": ["Solo"]}
result = turns.compose_context(persona_cfg, None, None, {}, "hello")
print("PLACEHOLDER_NOTE", "AST-061" in result["context_for_adapter"]["system"])
print("NO_MODEL_KEY", "model" not in result["context_for_adapter"])
print("EMPTY_CHIPS", result["chips"] == [])
PY
)"
check "compose: default roster provider renders a documented placeholder" "PLACEHOLDER_NOTE True" "$out"
check "compose: model key omitted when persona_cfg has no llm.model" "NO_MODEL_KEY True" "$out"
check "compose: no recall_fn -> empty chips, no crash" "EMPTY_CHIPS True" "$out"

# ------------------------------------------------------- (3) raw message reaches recall_fn untransformed
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

seen = []
def recall_fn(message):
    seen.append(message)
    return {"blocks": [], "seeds": 0, "injected": 0, "links_fired": []}

raw = "  Weird Casing AND trailing spaces   "
turns.compose_context({}, None, recall_fn, {}, raw)
print("RAW_MATCH", seen == [raw])
PY
)"
check "compose: recall_fn receives the message byte-identical (no lower/strip)" "RAW_MATCH True" "$out"

# ------------------------------------------------------- (4) budget: per-component caps hold under oversized inputs
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

persona_cfg = {"systemPrompt": "P" * 100000, "names": ["N" * 100000]}

def roster_provider():
    return [{"name": "cap%d" % i, "one-liner": "x" * 500, "available": True} for i in range(50)]

def recall_fn(message):
    return {"blocks": ["### note-%d  [strength 1]\n%s" % (i, "y" * 2000) for i in range(20)],
            "seeds": 20, "injected": 20, "links_fired": []}

session_state = {
    "summary": "S" * 100000,
    "turns": [{"role": "user", "text": "T" * 2000} for _ in range(6)],
}

result = turns.compose_context(persona_cfg, roster_provider, recall_fn, session_state, "short msg")
comp = result["budget_report"]["components"]
ok = True
for name in ("persona", "roster", "notes", "summary", "turns"):
    if comp[name]["tokens"] > comp[name]["cap"]:
        ok = False
        print("OVER", name, comp[name])
print("ALL_COMPONENTS_WITHIN_CAP", ok)
print("ALL_CLIPPED", sorted(result["budget_report"]["clipped_components"]))
print("USER_MSG_NEVER_CLIPPED", comp["user_message"]["clipped"] is False)
print("USER_MSG_UNCAPPED", comp["user_message"]["cap"] is None)
PY
)"
check "budget: every oversized component stays within its own cap" "ALL_COMPONENTS_WITHIN_CAP True" "$out"
check "budget: all five itemized components report clipped=True" "ALL_CLIPPED ['notes', 'persona', 'roster', 'summary', 'turns']" "$out"
check "budget: user_message component is never clipped" "USER_MSG_NEVER_CLIPPED True" "$out"
check "budget: user_message component has no cap (documented exception)" "USER_MSG_UNCAPPED True" "$out"

# ------------------------------------------------------- (5) user message survives verbatim even when huge
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

huge = "U" * 50000
result = turns.compose_context({}, None, None, {}, huge)
print("VERBATIM", result["context_for_adapter"]["input"] == huge)
print("OVER_BUDGET_TRUE", result["budget_report"]["over_budget"] is True)
PY
)"
check "budget: a huge user message is never truncated" "VERBATIM True" "$out"
check "budget: a huge user message honestly reports over_budget" "OVER_BUDGET_TRUE True" "$out"

# ------------------------------------------------------- (6) clip precedence: notes rank-order prefix
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

# notes cap is 1500 tokens = 6000 chars. Blocks are ~2924 chars each
# (header + 2900-char body); two fit under the "\n\n"-joined 6000-char cap
# (2924+2+2924=5850), a third does not (+2+2924=8776).
def recall_fn(message):
    return {"blocks": ["### first  [strength 3]\n" + "a" * 2900,
                        "### second  [strength 2]\n" + "b" * 2900,
                        "### third  [strength 1]\n" + "c" * 2900],
            "seeds": 3, "injected": 3, "links_fired": []}

result = turns.compose_context({}, None, recall_fn, {}, "q")
sys_text = result["context_for_adapter"]["system"]
print("FIRST_IN", "first" in sys_text)
print("SECOND_IN", "second" in sys_text)
print("THIRD_OUT", "third" not in sys_text)
print("CHIPS_INCLUDE_ALL_THREE", [c["slug"] for c in result["chips"]] == ["first", "second", "third"])
PY
)"
check "clip precedence: notes -- higher-rank blocks kept" "FIRST_IN True" "$out"
check "clip precedence: notes -- second block still fits" "SECOND_IN True" "$out"
check "clip precedence: notes -- lowest-rank block dropped once cap exceeded" "THIRD_OUT True" "$out"
check "clip precedence: chips reflect ALL recalled notes (pre-budget-clip transparency)" "CHIPS_INCLUDE_ALL_THREE True" "$out"

# ------------------------------------------------------- (7) clip precedence: turns oldest-first
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

# turns cap is 2000 tokens = 8000 chars. Six turns of 2000 chars each
# (12000 total) -- oldest ones must drop, newest survive.
session_state = {"turns": [{"role": "user", "text": "MSG%d-%s" % (i, "x" * 1990)} for i in range(6)]}
result = turns.compose_context({}, None, None, session_state, "q")
sys_text = result["context_for_adapter"]["system"]
print("OLDEST_DROPPED", "MSG0-" not in sys_text)
print("NEWEST_KEPT", "MSG5-" in sys_text)
print("CHRONO_ORDER", sys_text.find("MSG4-") < sys_text.find("MSG5-") if "MSG4-" in sys_text else True)
PY
)"
check "clip precedence: turns -- oldest entry dropped" "OLDEST_DROPPED True" "$out"
check "clip precedence: turns -- newest entry kept" "NEWEST_KEPT True" "$out"
check "clip precedence: turns -- surviving entries stay in chronological order" "CHRONO_ORDER True" "$out"

# ------------------------------------------------------- (8) turns window: only last N<=6 considered
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

session_state = {"turns": [{"role": "user", "text": "OLD%d" % i} for i in range(10)]}
result = turns.compose_context({}, None, None, session_state, "q")
sys_text = result["context_for_adapter"]["system"]
print("N6_EXCLUDES_OLD0", "OLD0" not in sys_text)
print("N6_EXCLUDES_OLD3", "OLD3" not in sys_text)
print("N6_INCLUDES_OLD9", "OLD9" in sys_text)
PY
)"
check "turns window: entries before the last N=6 are excluded outright" "N6_EXCLUDES_OLD0 True" "$out"
check "turns window: N=6 boundary excludes the 4th-from-last entry" "N6_EXCLUDES_OLD3 True" "$out"
check "turns window: the very last entry is always included" "N6_INCLUDES_OLD9 True" "$out"

# ------------------------------------------------------- (9) query-embed cache hit/miss counting
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

calls = []
def recall_fn(message):
    calls.append(message)
    return {"blocks": [], "seeds": 0, "injected": 0, "links_fired": []}

cache = turns.QueryEmbedCache()
turns.compose_context({}, None, recall_fn, {}, "same message", cache=cache)
turns.compose_context({}, None, recall_fn, {}, "same message", cache=cache)
turns.compose_context({}, None, recall_fn, {}, "different message", cache=cache)
print("CALL_COUNT", len(calls))

# no cache passed -> fresh ephemeral cache each call -> no cross-call caching
calls2 = []
def recall_fn2(message):
    calls2.append(message)
    return {"blocks": [], "seeds": 0, "injected": 0, "links_fired": []}
turns.compose_context({}, None, recall_fn2, {}, "x")
turns.compose_context({}, None, recall_fn2, {}, "x")
print("NO_CACHE_CALL_COUNT", len(calls2))
PY
)"
check "cache: repeated identical message hits the cache (recall called once, then a distinct miss)" "CALL_COUNT 2" "$out"
check "cache: omitting cache means no cross-call memoization" "NO_CACHE_CALL_COUNT 2" "$out"

# ------------------------------------------------------- (10) TTL expiry via injectable clock
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

calls = []
def recall_fn(message):
    calls.append(message)
    return {"blocks": [], "seeds": 0, "injected": 0, "links_fired": []}

clock = {"t": 0.0}
cache = turns.QueryEmbedCache(ttl_seconds=10, now=lambda: clock["t"])
turns.compose_context({}, None, recall_fn, {}, "m", cache=cache)
clock["t"] = 5.0
turns.compose_context({}, None, recall_fn, {}, "m", cache=cache)  # still within TTL -> hit
clock["t"] = 20.0
turns.compose_context({}, None, recall_fn, {}, "m", cache=cache)  # expired -> miss
print("CALL_COUNT", len(calls))
PY
)"
check "cache: TTL expiry forces a fresh recall after the window elapses" "CALL_COUNT 2" "$out"

# ------------------------------------------------------- (11) run_turn: fake adapter, chips, session round trip
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

persona_cfg = {"systemPrompt": "P", "names": ["N"], "llm": {"provider": "fake", "model": "m1"}}

seen_context = {}
def fake_adapter(context, **kwargs):
    seen_context.update(context)
    return {"text": "echo:" + context["input"], "usage": {"input_tokens": 3}, "timings": {"elapsed_seconds": 0.01}}

def get_adapter(provider):
    assert provider == "fake"
    return fake_adapter

def recall_fn(message):
    return {"blocks": ["### note-x  [strength 5]\nbody"], "seeds": 1, "injected": 1, "links_fired": []}

session_state = {"summary": "", "turns": [], "turn_count": 0}
result = turns.run_turn(persona_cfg, None, recall_fn, session_state, "hello there", get_adapter=get_adapter)

print("HAS_KEYS", sorted(result.keys()) == ["budget_report", "chips", "text", "timings", "updated_session_state", "usage"])
print("TEXT", result["text"])
print("CHIPS_SLUG", result["chips"][0]["slug"])
print("USAGE", result["usage"])
print("SESSION_TURNS_LEN", len(result["updated_session_state"]["turns"]))
print("SESSION_TURN_COUNT", result["updated_session_state"]["turn_count"])
print("SESSION_LAST_USER", result["updated_session_state"]["turns"][-2])
print("SESSION_LAST_ASSISTANT", result["updated_session_state"]["turns"][-1])
print("ADAPTER_SAW_MODEL", seen_context.get("model"))
PY
)"
check "run_turn: returns exactly the documented five keys plus additive budget_report" "HAS_KEYS True" "$out"
check "run_turn: text comes from the adapter's completion" "TEXT echo:hello there" "$out"
check "run_turn: chips surface in the reply payload" "CHIPS_SLUG note-x" "$out"
check "run_turn: usage passed through from the adapter" "USAGE {'input_tokens': 3}" "$out"
check "run_turn: session_state round trip appends both turns" "SESSION_TURNS_LEN 2" "$out"
check "run_turn: session_state turn_count increments by one exchange" "SESSION_TURN_COUNT 1" "$out"
check "run_turn: appended user entry" "SESSION_LAST_USER {'role': 'user', 'text': 'hello there'}" "$out"
check "run_turn: appended assistant entry" "SESSION_LAST_ASSISTANT {'role': 'assistant', 'text': 'echo:hello there'}" "$out"
check "run_turn: adapter receives model from persona_cfg.llm.model" "ADAPTER_SAW_MODEL m1" "$out"

# ------------------------------------------------------- (12) K-turn summary refresh trigger + size cap
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

persona_cfg = {"llm": {"provider": "fake"}}

def fake_adapter(context, **kwargs):
    return {"text": "reply", "usage": None, "timings": {"elapsed_seconds": 0.0}}

def get_adapter(provider):
    return fake_adapter

summarizer_calls = []
def counting_summarizer(old_summary, window, cap_chars):
    summarizer_calls.append((old_summary, len(window), cap_chars))
    return ("REFRESHED-" + str(len(summarizer_calls))) * 5000  # oversized on purpose -> must be capped

session_state = {"summary": "", "turns": [], "turn_count": 0}
for i in range(7):
    result = turns.run_turn(persona_cfg, None, None, session_state, "msg%d" % i,
                             get_adapter=get_adapter, summarizer=counting_summarizer, refresh_every=8)
    session_state = result["updated_session_state"]
    if i < 6:
        print("NO_REFRESH_YET_%d" % i, session_state["summary"] == "")

# 8th call (i=7) crosses the K=8 boundary -> refresh fires
result = turns.run_turn(persona_cfg, None, None, session_state, "msg7",
                         get_adapter=get_adapter, summarizer=counting_summarizer, refresh_every=8)
session_state = result["updated_session_state"]
print("REFRESH_FIRED", len(summarizer_calls) == 1)
print("TURN_COUNT_AT_REFRESH", session_state["turn_count"])
print("SUMMARY_SIZE_CAPPED", len(session_state["summary"]) <= turns.DEFAULT_COMPONENT_BUDGETS["summary"] * turns.TOKENS_CHARS_PER_TOKEN)
PY
)"
check "summary refresh: no refresh before the Kth turn" "NO_REFRESH_YET_0 True" "$out"
check "summary refresh: still none at turn 6" "NO_REFRESH_YET_5 True" "$out"
check "summary refresh: fires exactly once at the Kth turn" "REFRESH_FIRED True" "$out"
check "summary refresh: turn_count reflects 8 completed exchanges" "TURN_COUNT_AT_REFRESH 8" "$out"
check "summary refresh: refreshed summary is size-capped" "SUMMARY_SIZE_CAPPED True" "$out"

# ------------------------------------------------------- (13) default_summarizer is documented + capped
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

window = [{"role": "user", "text": "hi"}, {"role": "assistant", "text": "hello"}]
result = turns.default_summarizer("prior", window, 20)
print("CAPPED_LEN", len(result) <= 20)
print("STARTS_WITH_PRIOR", result.startswith("prior"))
PY
)"
check "default_summarizer: respects cap_chars" "CAPPED_LEN True" "$out"
check "default_summarizer: extractive -- prior summary text leads" "STARTS_WITH_PRIOR True" "$out"

# ------------------------------------------------------- (13b) AST-032: stale-summary regression fixture --
# a rolling summary asserting X ("deploy target is us-east-1") alongside a
# FRESHER recalled note asserting not-X ("deploy target is eu-west-1"). This
# does not assert anything about model behavior (no model runs here) -- it
# asserts the documented note-wins MECHANISM: the assembled system prompt
# places the note strictly after the summary, so prompt-order recency lets
# the fresher note win over the stale summary blob.
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

session_state = {
    "summary": "Recap: the deploy target is us-east-1.",
    "turns": [],
}

def recall_fn(message):
    return {"blocks": ["### deploy-target-note  [strength 4]\nThe deploy target is now eu-west-1 (updated)."],
            "seeds": 1, "injected": 1, "links_fired": []}

result = turns.compose_context({}, None, recall_fn, session_state, "where do we deploy?")
sys_text = result["context_for_adapter"]["system"]
print("BOTH_PRESENT", "us-east-1" in sys_text and "eu-west-1" in sys_text)
print("NOTE_AFTER_SUMMARY", sys_text.find("us-east-1") < sys_text.find("eu-west-1"))
PY
)"
check "AST-032 regression: stale summary and fresher note both survive budget" "BOTH_PRESENT True" "$out"
check "AST-032 regression: note-wins -- fresher note ordered after the stale summary" "NOTE_AFTER_SUMMARY True" "$out"

# ------------------------------------------------------- (14) integration-ish: real brain.recall against a scaffolded temp brain
AT_ROOT="$(mktemp -d)"
AT_IDENTITIES="$AT_ROOT/.claude/identities"
mkdir -p "$AT_IDENTITIES"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - "$AT_ROOT" "$AT_IDENTITIES" <<'PY'
import sys
root, identities = sys.argv[1], sys.argv[2]
import brain
from assistant import turns

brain.mint(identities, "assistant", "weather-api-note", root,
           "Use the weather.gov API, not a scraped page.\n",
           tags="weather,forecast", paths="")

recall_fn = turns.make_default_recall(identities, root, role="assistant")
result = turns.compose_context({}, None, recall_fn, {}, "weather forecast question")
print("CHIP_SLUGS", [c["slug"] for c in result["chips"]])
print("NOTE_IN_SYSTEM", "weather-api-note" in result["context_for_adapter"]["system"])
PY
)"
check "integration: real brain.recall surfaces the minted note as a chip" "CHIP_SLUGS ['weather-api-note']" "$out"
check "integration: the recalled note text lands in the composed system prompt" "NOTE_IN_SYSTEM True" "$out"
rm -rf "$AT_ROOT"

# ------------------------------------------------------- (15) turns pipeline never touches engine queues
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import inspect
from assistant import turns

import assistant.turns as turns_module
code_only = "\n".join(
    line for line in inspect.getsource(turns_module).splitlines()
    if not line.strip().startswith("#")
)
print("NO_ENGINE_IMPORT", "import engine" not in code_only and "from assistant import engine" not in code_only)
print("NO_QUEUE_TOUCH", "queues[" not in code_only and "import queue" not in code_only)
PY
)"
check "invariant: turns.py never imports engine.py" "NO_ENGINE_IMPORT True" "$out"
check "invariant: turns.py never touches a queues[name] slot (Sec9.5/Sec17.7)" "NO_QUEUE_TOUCH True" "$out"

# --- review r2 finding 1: the DEFAULT budget constants themselves are a
# load-bearing invariant (sum of per-component caps < total, headroom for the
# user message) -- previously every budget test passed explicit overrides, so
# a 10x default blowout kept the suite green. These checks import the real
# constants. ------------------------------------------------------------------
at_r2_out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns
total = turns.TOKEN_BUDGET_TOTAL
caps = dict(turns.DEFAULT_COMPONENT_BUDGETS)
print("TOTAL", total)
print("CAP_SUM", sum(caps.values()))
print("SUM_UNDER_TOTAL", sum(caps.values()) < total)
print("HEADROOM_AT_LEAST_500", total - sum(caps.values()) >= 500)
print("CAP_KEYS", ",".join(sorted(caps)))
PY
)"
at_r2_rc=$?
check_rc "r2: budget-constants probe runs" 0 "$at_r2_rc"
check "r2: total budget is the documented ~6k" "TOTAL 6000" "$at_r2_out"
check "r2: per-component caps sum under the total (headroom invariant)" "SUM_UNDER_TOTAL True" "$at_r2_out"
check "r2: headroom is at least 500 tokens for the user message" "HEADROOM_AT_LEAST_500 True" "$at_r2_out"
check "r2: cap keys are exactly the five documented components" "CAP_KEYS notes,persona,roster,summary,turns" "$at_r2_out"

# --- review r2 finding 2 companion: dense-script (CJK) text must not be
# undercounted at chars/4 -- the estimator charges high codepoints 1 token
# each. 12 CJK chars must estimate >= 12 tokens, not 3. -----------------------
at_r2b_out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns
cjk = "测试" * 6
print("CJK_TOKENS_GE_12", turns.estimate_tokens(cjk) >= 12)
print("ASCII_UNCHANGED", turns.estimate_tokens("abcdefgh") == 2)
PY
)"
check "r2: CJK text charged at least 1 token per char" "CJK_TOKENS_GE_12 True" "$at_r2b_out"
check "r2: ASCII estimation unchanged by the dense-script rule" "ASCII_UNCHANGED True" "$at_r2b_out"

# ------------------------------------------------------------------------
# AST-071 (SPEC-ASSISTANT.md §11.8, docs/design/ast-E6.md sequence 5):
# capability_gap_reply -- off an ALREADY-COMPILED CapabilityIndex (a stub
# index here, no index recompute, §11.3), composes a deterministic
# in-persona refusal when roster_for_turn finds no match, and drafts an
# acquire-offer plan-note PAYLOAD for the caller to hand to the async
# mint queue (turns.py itself never touches a queue -- see the
# NO_QUEUE_TOUCH invariant test above, which re-scans this whole module's
# source and therefore also covers this new function).
#
# ARCHITECTURAL NOTE (review round 1, HIGH #1 -- read before touching these
# fixtures): roster_for_turn returns [] if AND ONLY IF every entry scores
# EXACTLY 0 for the query (it is the max-score entry's own score that gates
# the [] return, and scores are never negative) -- capability_gap_reply
# detects a gap off that EXACT SAME condition, re-using the identical
# `_score` computation via `capability_index.nearest_entries`. Therefore,
# by construction, EVERY gap this function ever detects has `nearest == []`
# and `total_enabled` as the only varying signal: naming a NONZERO-scored
# "nearest ability" in a refusal is unreachable through this public
# function today, even though `nearest_entries`/`_render_capability_gap_refusal`
# both fully implement and are directly unit-tested for that shape (see
# "-- unit: _render_capability_gap_refusal --" below, and
# section-capability-roster.sh's nearest_entries tests). Documented in
# docs/spec-deltas/346.md (also records a round-1 embedding-mode finding);
# a future task that wants named-ability refusals to actually fire needs a
# gap-detection signal weaker than "roster_for_turn returned []".
#
# Round 2 (NEW-2, orchestrator decision): the plan-note MAY-offer is drafted
# UNCONDITIONALLY on every gap now, including a totally empty index -- round
# 1's "only when total_enabled > 0" gate was reverted (the bare-assistant
# case is exactly the one worth parking, not the one to suppress).
# ------------------------------------------------------------------------
echo "-- unit: capability_gap_reply -- a nonempty index with zero relevance signal degrades to the 'none related' shape (no fabricated names), stating enabled AND available counts (round 2, NEW-5) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns
from assistant import capability_index as ci

entries = (
    ci.CapabilityIndexEntry(name="weather", one_liner="checks the weather", keywords=["weather", "forecast"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
    ci.CapabilityIndexEntry(name="reminders", one_liner="sets reminders", keywords=["reminder", "schedule"],
                              embedding=None, enabled=True, provisioned_ok=False, unavailable_reason="not provisioned"),
)
index = ci.CapabilityIndex(entries=entries)

gap = turns.capability_gap_reply(index, "please render a 3d model of a duck", embed_fn=lambda texts: None)
print("IS_GAP", gap is not None)
print("NEAREST_EMPTY", gap.nearest == [])
print("TEXT_NEVER_NAMES_WEATHER", "weather" not in gap.text)
print("TEXT_NEVER_NAMES_REMINDERS", "reminders" not in gap.text)
print("TEXT_STATES_ENABLED_COUNT", "2" in gap.text)
print("TEXT_STATES_AVAILABLE_COUNT", "1 available" in gap.text)
print("TEXT_SAYS_NONE_RELATED", "none" in gap.text.lower() and "related" in gap.text.lower())
print("PLAN_NOTE_PRESENT", gap.plan_note is not None)
print("PLAN_NOTE_HAS_EXCERPT", "duck" in (gap.plan_note.get("request_excerpt") or ""))
print("PLAN_NOTE_HAS_TOTAL_ENABLED", gap.plan_note.get("total_enabled") == 2)
PY
)"
check "capability_gap_reply: an unmatched request IS a gap" "IS_GAP True" "$out"
check "capability_gap_reply: nearest is empty -- see the architectural note above" "NEAREST_EMPTY True" "$out"
check "capability_gap_reply: never names an entry that scored zero (review round 1 fix -- inverted from the old alphabetical-dump assertion)" "TEXT_NEVER_NAMES_WEATHER True" "$out"
check "capability_gap_reply: never names the other zero-score entry either" "TEXT_NEVER_NAMES_REMINDERS True" "$out"
check "capability_gap_reply: the THIRD refusal shape states how many abilities are enabled" "TEXT_STATES_ENABLED_COUNT True" "$out"
check "capability_gap_reply: the THIRD refusal shape ALSO states how many are actually available (round 2, NEW-5 -- 1 of the 2 enabled is unprovisioned)" "TEXT_STATES_AVAILABLE_COUNT True" "$out"
check "capability_gap_reply: the THIRD refusal shape says none are related" "TEXT_SAYS_NONE_RELATED True" "$out"
check "capability_gap_reply: a plan note IS drafted when the index has an established capability posture" "PLAN_NOTE_PRESENT True" "$out"
check "capability_gap_reply: plan-note payload carries the request excerpt" "PLAN_NOTE_HAS_EXCERPT True" "$out"
check "capability_gap_reply: plan-note payload carries total_enabled (round 2, HIGH NEW-1 -- so mint_gap_note can branch on it, not on the always-empty nearest)" "PLAN_NOTE_HAS_TOTAL_ENABLED True" "$out"

echo "-- unit: capability_gap_reply -- empty index degrades to an honest 'no abilities enabled' shape (distinct from the 'none related' shape); a plan note IS STILL drafted (round 2, NEW-2: the bare-assistant case is the one most worth parking) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns
from assistant import capability_index as ci

empty_index = ci.CapabilityIndex(entries=())
gap = turns.capability_gap_reply(empty_index, "please render a 3d model of a duck", embed_fn=lambda texts: None)
print("IS_GAP", gap is not None)
print("NEAREST_EMPTY", gap.nearest == [])
print("TEXT_SAYS_NO_ABILITIES", "no" in gap.text.lower() and "abilit" in gap.text.lower())
print("TEXT_NEVER_CLAIMS_A_MATCH", "weather" not in gap.text and "reminders" not in gap.text)
print("TEXT_NOT_THE_NONE_RELATED_SHAPE", "related" not in gap.text.lower())
print("PLAN_NOTE_PRESENT_EVEN_FOR_EMPTY_INDEX", gap.plan_note is not None)
print("PLAN_NOTE_TOTAL_ENABLED_IS_ZERO", gap.plan_note.get("total_enabled") == 0)
PY
)"
check "capability_gap_reply: a completely empty index is still a gap" "IS_GAP True" "$out"
check "capability_gap_reply: nearest is empty (nothing to name)" "NEAREST_EMPTY True" "$out"
check "capability_gap_reply: refusal honestly states no abilities are enabled" "TEXT_SAYS_NO_ABILITIES True" "$out"
check "capability_gap_reply: never fabricates a match against an empty index" "TEXT_NEVER_CLAIMS_A_MATCH True" "$out"
check "capability_gap_reply: the empty-index shape is textually distinct from the 'none related' shape" "TEXT_NOT_THE_NONE_RELATED_SHAPE True" "$out"
check "capability_gap_reply: a plan note IS drafted even for a truly empty index (round 2, NEW-2 -- reverses round 1's fix #6 gate)" "PLAN_NOTE_PRESENT_EVEN_FOR_EMPTY_INDEX True" "$out"
check "capability_gap_reply: that plan note honestly carries total_enabled=0" "PLAN_NOTE_TOTAL_ENABLED_IS_ZERO True" "$out"

echo "-- unit: _render_capability_gap_refusal (direct call -- see the architectural note above for why the named-ability shape is not reachable through capability_gap_reply's public entry point) -- names a nearest ability WITH its unavailable reason (Sec11.4), deleting the branch must fail this suite --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns
from assistant import capability_index as ci

available = ci.CapabilityIndexEntry(name="video-renderer", one_liner="renders video clips", keywords=[],
                                      embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None)
unavailable = ci.CapabilityIndexEntry(name="renderer", one_liner="renders things", keywords=[],
                                        embedding=None, enabled=True, provisioned_ok=False,
                                        unavailable_reason="binary not on PATH")

text = turns._render_capability_gap_refusal([available, unavailable], total_enabled=2, available_count=1)
print("NAMES_AVAILABLE", "video-renderer" in text)
print("NAMES_UNAVAILABLE", "renderer" in text)
print("STATES_REASON", "binary not on PATH" in text)
print("NEVER_PRESENTS_UNAVAILABLE_AS_USABLE", "unavailable" in text.lower())
PY
)"
check "_render_capability_gap_refusal: names an available nearest ability" "NAMES_AVAILABLE True" "$out"
check "_render_capability_gap_refusal: names an unprovisioned nearest ability too (Sec11.4: never hidden)" "NAMES_UNAVAILABLE True" "$out"
check "_render_capability_gap_refusal: states the unavailable reason" "STATES_REASON True" "$out"
check "_render_capability_gap_refusal: marks it unavailable, never presented as usable (Sec11.4)" "NEVER_PRESENTS_UNAVAILABLE_AS_USABLE True" "$out"

echo "-- unit: capability_gap_reply -- a real match (or a genuine ambiguity) is NOT a gap --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns
from assistant import capability_index as ci

# a clear, unambiguous, above-threshold match -- roster_for_turn returns a
# real list, so this must NOT be treated as a capability gap.
match_entries = (
    ci.CapabilityIndexEntry(name="weather", one_liner="checks the weather", keywords=["weather", "forecast", "rain"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
)
match_index = ci.CapabilityIndex(entries=match_entries)
match_gap = turns.capability_gap_reply(match_index, "weather forecast rain", embed_fn=lambda texts: None)

# a genuine tie -- roster_for_turn returns AskInsteadOfGuess, a DIFFERENT
# (already-handled, AST-061) concern, not the AST-071 capability gap.
tie_entries = (
    ci.CapabilityIndexEntry(name="alpha", one_liner="", keywords=["render", "video", "duck"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
    ci.CapabilityIndexEntry(name="beta", one_liner="", keywords=["render", "video", "duck"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
)
tie_index = ci.CapabilityIndex(entries=tie_entries)
tie_gap = turns.capability_gap_reply(tie_index, "render video duck", embed_fn=lambda texts: None)

print("MATCH_IS_NOT_A_GAP", match_gap is None)
print("TIE_IS_NOT_A_GAP", tie_gap is None)
PY
)"
check "capability_gap_reply: a clear match is not a capability gap" "MATCH_IS_NOT_A_GAP True" "$out"
check "capability_gap_reply: a genuine tie (AskInsteadOfGuess) is not a capability gap either" "TIE_IS_NOT_A_GAP True" "$out"

# ==========================================================================
# #508 (SPEC-ASSISTANT.md Sec9.4/Sec9.5, Sec11.5, Sec11.8, docs/design/
# ast-E6.md sequences 2/3/5, docs/spec-deltas/applied/346.md): request ->
# resolve -> invoke -> (gap) wiring, the pure turns.py half. The model signals
# a capability request with a single fenced "capability" JSON code block per
# reply (never by vibes); parse_capability_directives is the ONLY place
# that syntax is understood, and it never leaks a raw directive block into
# the user-visible text, valid or not.
# ==========================================================================
echo "-- unit: parse_capability_directives -- one valid directive is parsed and stripped from the visible reply --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

# NOTE: the triple-backtick fence is built via chr(96) rather than written
# literally -- a raw literal backtick character inside a heredoc nested in
# a bash $(...) command substitution trips a well-known bash lexer quirk
# (cumulative backtick-parity tracking that ignores heredoc quoting), so
# every fenced-block fixture in this file is built this way.
FENCE = chr(96) * 3
reply = "Sure, let me check.\n" + FENCE + 'capability\n{"name": "weather", "params": {"city": "Rome"}}\n' + FENCE + "\nOne moment."
visible, directives, actionable = turns.parse_capability_directives(reply)
print("VISIBLE_NO_FENCE", (FENCE + "capability") not in visible)
print("VISIBLE_NO_JSON", '"name"' not in visible)
print("VISIBLE_KEEPS_PROSE", "Sure, let me check." in visible and "One moment." in visible)
print("DIRECTIVE_COUNT", len(directives))
print("DIRECTIVE_NAME", directives[0].name)
print("DIRECTIVE_PARAMS", directives[0].params)
PY
)"
check "parse_capability_directives: fenced block removed from visible text" "VISIBLE_NO_FENCE True" "$out"
check "parse_capability_directives: raw JSON never leaks into visible text" "VISIBLE_NO_JSON True" "$out"
check "parse_capability_directives: surrounding prose is preserved" "VISIBLE_KEEPS_PROSE True" "$out"
check "parse_capability_directives: exactly one directive parsed" "DIRECTIVE_COUNT 1" "$out"
check "parse_capability_directives: name extracted" "DIRECTIVE_NAME weather" "$out"
check "parse_capability_directives: params extracted" "DIRECTIVE_PARAMS {'city': 'Rome'}" "$out"

echo "-- unit: parse_capability_directives -- no directive at all -- text unchanged, empty list (flooding-guard precondition) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

reply = "just an ordinary reply, nothing to see here"
visible, directives, actionable = turns.parse_capability_directives(reply)
print("VISIBLE_UNCHANGED", visible == reply)
print("DIRECTIVE_COUNT", len(directives))
PY
)"
check "parse_capability_directives: ordinary text passes through unchanged" "VISIBLE_UNCHANGED True" "$out"
check "parse_capability_directives: no directives found" "DIRECTIVE_COUNT 0" "$out"

echo "-- unit: parse_capability_directives -- malformed JSON / missing name are stripped as errors, never leaked verbatim --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

FENCE = chr(96) * 3
bad_json = FENCE + "capability\n{not json at all\n" + FENCE
visible1, directives1, actionable1 = turns.parse_capability_directives(bad_json)
print("BAD_JSON_STRIPPED", "not json at all" not in visible1)
print("BAD_JSON_IS_ERROR", isinstance(directives1[0], turns.CapabilityDirectiveError))

missing_name = FENCE + 'capability\n{"params": {}}\n' + FENCE
visible2, directives2, actionable2 = turns.parse_capability_directives(missing_name)
print("MISSING_NAME_STRIPPED", "params" not in visible2)
print("MISSING_NAME_IS_ERROR", isinstance(directives2[0], turns.CapabilityDirectiveError))
PY
)"
check "parse_capability_directives: invalid JSON never leaks into the visible reply" "BAD_JSON_STRIPPED True" "$out"
check "parse_capability_directives: invalid JSON is reported as a CapabilityDirectiveError" "BAD_JSON_IS_ERROR True" "$out"
check "parse_capability_directives: a directive missing 'name' never leaks into the visible reply" "MISSING_NAME_STRIPPED True" "$out"
check "parse_capability_directives: a directive missing 'name' is reported as a CapabilityDirectiveError" "MISSING_NAME_IS_ERROR True" "$out"

echo "-- unit: parse_capability_directives -- v1 is ONE per turn: extra directives are still parsed (in order) so the caller can trace+ignore them, never silently dropped or merged --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

FENCE = chr(96) * 3
reply = (FENCE + 'capability\n{"name": "first"}\n' + FENCE + '\n'
         'text between\n'
         + FENCE + 'capability\n{"name": "second"}\n' + FENCE)
visible, directives, actionable = turns.parse_capability_directives(reply)
print("COUNT", len(directives))
print("FIRST_NAME", directives[0].name)
print("SECOND_NAME", directives[1].name)
print("VISIBLE_NO_FENCES", (FENCE + "capability") not in visible)
PY
)"
check "parse_capability_directives: multiple directives are all parsed, in order" "COUNT 2" "$out"
check "parse_capability_directives: first directive name" "FIRST_NAME first" "$out"
check "parse_capability_directives: second directive name (caller decides to ignore it, v1 one-per-turn)" "SECOND_NAME second" "$out"
check "parse_capability_directives: every fenced block is stripped regardless of how many" "VISIBLE_NO_FENCES True" "$out"

echo "-- unit: _render_roster_entries teaches the directive syntax whenever there is a real, named capability to invoke --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

FENCE = chr(96) * 3
with_real = turns._render_roster_entries([{"name": "weather", "one-liner": "checks weather", "available": True}])
print("TEACHES_WHEN_REAL", (FENCE + "capability") in "\n".join(with_real))
print("SHOWS_NAME_PARAMS_SHAPE", '"name"' in "\n".join(with_real) and '"params"' in "\n".join(with_real))

empty = turns._render_roster_entries([])
print("NO_TEACHING_WHEN_EMPTY", (FENCE + "capability") not in "\n".join(empty))

ambiguous_only = turns._render_roster_entries([{"name": "(ambiguous)", "one-liner": "x", "available": False}])
print("NO_TEACHING_WHEN_AMBIGUOUS_ONLY", (FENCE + "capability") not in "\n".join(ambiguous_only))
PY
)"
check "roster teaching: the directive syntax is taught when a real capability is in the roster" "TEACHES_WHEN_REAL True" "$out"
check "roster teaching: the taught syntax shows the name/params shape" "SHOWS_NAME_PARAMS_SHAPE True" "$out"
check "roster teaching: never taught for an empty roster (nothing to invoke)" "NO_TEACHING_WHEN_EMPTY True" "$out"
check "roster teaching: never taught for the ambiguous-only sentinel (Sec11.3 asks-instead-of-guess already covers it)" "NO_TEACHING_WHEN_AMBIGUOUS_ONLY True" "$out"

echo "-- unit: render_capability_result_text -- truncates with an explicit marker, never silently, for both invoke flavors --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
import collections
from assistant import turns

InvokeResult = collections.namedtuple("InvokeResult", ["argv", "returncode", "stdout", "stderr"])
McpInvokeResult = collections.namedtuple(
    "McpInvokeResult", ["argv", "request", "response", "result", "returncode", "stdout", "stderr"])

huge = InvokeResult(argv=["x"], returncode=0, stdout="A" * 10000, stderr="")
text, truncated = turns.render_capability_result_text(huge, cap_chars=200)
print("ARGV_TRUNCATED", truncated)
print("ARGV_LEN_CAPPED", len(text) <= 200)
print("ARGV_HAS_MARKER", "truncat" in text.lower())

small = InvokeResult(argv=["x"], returncode=0, stdout="hello", stderr="")
text2, truncated2 = turns.render_capability_result_text(small, cap_chars=200)
print("ARGV_SMALL_NOT_TRUNCATED", truncated2 is False)
print("ARGV_SMALL_HAS_STDOUT", "hello" in text2)

mcp = McpInvokeResult(argv=["x"], request={}, response={}, result={"data": "B" * 10000},
                       returncode=0, stdout="", stderr="")
text3, truncated3 = turns.render_capability_result_text(mcp, cap_chars=200)
print("MCP_TRUNCATED", truncated3)
print("MCP_LEN_CAPPED", len(text3) <= 200)
PY
)"
check "render_capability_result_text: a huge argv result is truncated" "ARGV_TRUNCATED True" "$out"
check "render_capability_result_text: truncated argv text respects the cap" "ARGV_LEN_CAPPED True" "$out"
check "render_capability_result_text: truncation carries an explicit marker, never silent" "ARGV_HAS_MARKER True" "$out"
check "render_capability_result_text: a small result is never truncated" "ARGV_SMALL_NOT_TRUNCATED True" "$out"
check "render_capability_result_text: a small argv result includes its stdout" "ARGV_SMALL_HAS_STDOUT True" "$out"
check "render_capability_result_text: a huge MCP result is also truncated" "MCP_TRUNCATED True" "$out"
check "render_capability_result_text: truncated MCP text respects the cap" "MCP_LEN_CAPPED True" "$out"

echo "-- unit: render_capability_result_followup -- reuses the SAME system prompt (no second recall/compose), embeds the result, preserves model --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

original = {"system": "PERSONA+ROSTER+NOTES", "input": "book me a flight", "model": "gpt-5.6-sol"}
followup = turns.render_capability_result_followup(original, "weather", "sunny, 22C")
print("SYSTEM_UNCHANGED", followup["system"] == original["system"])
print("MODEL_PRESERVED", followup.get("model") == "gpt-5.6-sol")
print("INPUT_HAS_ORIGINAL_MESSAGE", "book me a flight" in followup["input"])
print("INPUT_HAS_CAPABILITY_NAME", "weather" in followup["input"])
print("INPUT_HAS_RESULT", "sunny, 22C" in followup["input"])
PY
)"
check "render_capability_result_followup: system prompt is reused verbatim (no second compose/recall)" "SYSTEM_UNCHANGED True" "$out"
check "render_capability_result_followup: adapter-relevant keys (model) survive" "MODEL_PRESERVED True" "$out"
check "render_capability_result_followup: the follow-up input still carries the original user message" "INPUT_HAS_ORIGINAL_MESSAGE True" "$out"
check "render_capability_result_followup: names which capability produced the result" "INPUT_HAS_CAPABILITY_NAME True" "$out"
check "render_capability_result_followup: embeds the actual result text" "INPUT_HAS_RESULT True" "$out"

echo "-- unit: capability_gap_reply(requested_name=...) -- the REAL gap trigger (docs/spec-deltas/applied/346.md owner decision 1): fires on an explicit unresolved request, independent of the roster_for_turn score gates --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns
from assistant import capability_index as ci

entries = (
    ci.CapabilityIndexEntry(name="weather", one_liner="checks the weather forecast", keywords=["weather", "forecast"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
)
index = ci.CapabilityIndex(entries=entries)

# The raw user_message DOES relate to "weather" (roster_for_turn would find
# a real match for it) -- yet the model explicitly requested a DIFFERENT,
# unresolvable name ("book-flight"). The #508 gap trigger must still fire:
# an explicit request that fails to resolve IS the gap, regardless of what
# the ambient message would have scored on its own (this is the fix for
# the embedding-mode inertness finding from #346 -- score==0 is NOT the signal
# here, resolution failure is).
gap = turns.capability_gap_reply(index, "what is the weather like, also please book a flight",
                                  requested_name="book-flight", embed_fn=lambda texts: None)
print("IS_GAP", gap is not None)
lowered = gap.text.lower()
print("REQUEST_TEXT_MENTIONS_UNRESOLVED",
      "cannot" in lowered or "do not have" in lowered or "closest" in lowered
      or "related" in lowered or "not enabled" in lowered)

# a requested_name that DOES resolve is never a gap, regardless of the
# roster_for_turn outcome for the raw message.
resolved_gap = turns.capability_gap_reply(index, "anything", requested_name="weather", embed_fn=lambda texts: None)
print("RESOLVED_NAME_NOT_A_GAP", resolved_gap is None)

# case-insensitive resolution.
resolved_gap_ci = turns.capability_gap_reply(index, "anything", requested_name="WEATHER", embed_fn=lambda texts: None)
print("RESOLVED_NAME_CASE_INSENSITIVE_NOT_A_GAP", resolved_gap_ci is None)
PY
)"
check "capability_gap_reply(requested_name=...): an explicit unresolved request IS a gap" "IS_GAP True" "$out"
check "capability_gap_reply(requested_name=...): the refusal is honest about not having/resolving it" "REQUEST_TEXT_MENTIONS_UNRESOLVED True" "$out"
check "capability_gap_reply(requested_name=...): a name that DOES resolve is never a gap" "RESOLVED_NAME_NOT_A_GAP True" "$out"
check "capability_gap_reply(requested_name=...): resolution is case-insensitive" "RESOLVED_NAME_CASE_INSENSITIVE_NOT_A_GAP True" "$out"

echo "-- unit: capability_gap_reply(requested_name=...) -- nearest is scored off the REQUESTED name, so a real nearest signal exists (owner decision 3: slugs become meaningful once a real nearest signal exists) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns
from assistant import capability_index as ci

# NOTE: capability_index._extract_keywords treats a hyphenated word as ONE
# token (its word regex allows hyphens mid-token), so the query
# "book-flight" extracts the single keyword "book-flight" -- not "book"
# and "flight" separately. The entry below includes that exact compound
# token among its own keywords (alongside its split-word siblings) so the
# Jaccard keyword-overlap fallback (embed_fn=None below) has a genuine,
# deterministic, nonzero signal to find -- this is what "a real nearest
# signal now exists" concretely looks like on the keyword-overlap path.
entries = (
    ci.CapabilityIndexEntry(name="flight-tracker", one_liner="tracks flight status and books flights",
                              keywords=["flight", "book", "tracker", "status", "book-flight"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
    ci.CapabilityIndexEntry(name="weather", one_liner="checks the weather", keywords=["weather", "forecast"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
)
index = ci.CapabilityIndex(entries=entries)

gap = turns.capability_gap_reply(index, "please book-flight to mars", requested_name="book-flight",
                                  embed_fn=lambda texts: None)
print("IS_GAP", gap is not None)
print("NEAREST_NAMES_REAL_CANDIDATE", any(e.name == "flight-tracker" for e in gap.nearest))
print("PLAN_NOTE_NEAREST_NOT_ALWAYS_EMPTY", gap.plan_note.get("nearest") != [])
PY
)"
check "capability_gap_reply(requested_name=...): still a gap even with a plausible sibling capability nearby" "IS_GAP True" "$out"
check "capability_gap_reply(requested_name=...): nearest now names a REAL, keyword-related candidate (unlike the score==0 path)" "NEAREST_NAMES_REAL_CANDIDATE True" "$out"
check "capability_gap_reply(requested_name=...): the plan-note payload nearest field is no longer provably always empty" "PLAN_NOTE_NEAREST_NOT_ALWAYS_EMPTY True" "$out"

echo "-- unit: run_turn(on_reply=...) -- the hook can replace the reply text with a same-turn follow-up completion; session state advances with the FINAL text, not the first --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

persona_cfg = {"llm": {"provider": "fake"}}
calls = []

def fake_adapter(context, **kwargs):
    calls.append(context["input"])
    return {"text": "first-reply-with-directive", "usage": {"n": len(calls)}, "timings": None}

def get_adapter(provider):
    return fake_adapter

seen_hook_args = {}
def on_reply(first_text, context_for_adapter, complete_fn, adapter_kwargs):
    seen_hook_args["first_text"] = first_text
    seen_hook_args["has_system"] = "system" in context_for_adapter
    followup = complete_fn({"system": context_for_adapter["system"], "input": "followup-input"},
                            **(adapter_kwargs or {}))
    return {"text": "FINAL:" + followup["text"]}

session_state = {"summary": "", "turns": [], "turn_count": 0}
result = turns.run_turn(persona_cfg, None, None, session_state, "hello",
                         get_adapter=get_adapter, on_reply=on_reply)

print("HOOK_SAW_FIRST_TEXT", seen_hook_args["first_text"] == "first-reply-with-directive")
print("HOOK_SAW_CONTEXT", seen_hook_args["has_system"])
print("FINAL_TEXT", result["text"])
print("ADAPTER_CALLED_TWICE", len(calls) == 2)
print("SECOND_CALL_INPUT", calls[1])
print("SESSION_LAST_ASSISTANT", result["updated_session_state"]["turns"][-1])

# on_reply returning None leaves the first completion text untouched.
def on_reply_noop(first_text, context_for_adapter, complete_fn, adapter_kwargs):
    return None

session_state2 = {"summary": "", "turns": [], "turn_count": 0}
calls.clear()
result2 = turns.run_turn(persona_cfg, None, None, session_state2, "hi",
                          get_adapter=get_adapter, on_reply=on_reply_noop)
print("NOOP_TEXT_UNCHANGED", result2["text"] == "first-reply-with-directive")
print("NOOP_ADAPTER_CALLED_ONCE", len(calls) == 1)
PY
)"
check "run_turn(on_reply): the hook receives the first completion text" "HOOK_SAW_FIRST_TEXT True" "$out"
check "run_turn(on_reply): the hook receives the composed context (system prompt) for reuse" "HOOK_SAW_CONTEXT True" "$out"
check "run_turn(on_reply): the returned hook text becomes the turn final text" "FINAL_TEXT FINAL:first-reply-with-directive" "$out"
check "run_turn(on_reply): a hook that calls complete_fn again drives a real second adapter call" "ADAPTER_CALLED_TWICE True" "$out"
check "run_turn(on_reply): the second call receives whatever input the hook built" "SECOND_CALL_INPUT followup-input" "$out"
check "run_turn(on_reply): the session_state assistant entry reflects the FINAL text, not the first completion" \
    "SESSION_LAST_ASSISTANT {'role': 'assistant', 'text': 'FINAL:first-reply-with-directive'}" "$out"
check "run_turn(on_reply): returning None leaves the original completion text untouched" "NOOP_TEXT_UNCHANGED True" "$out"
check "run_turn(on_reply): a no-op hook never triggers a second adapter call" "NOOP_ADAPTER_CALLED_ONCE True" "$out"

# ==========================================================================
# #508 ROUND-1 REVIEW fixes (pinning tests, written and verified RED against
# the pre-fix code before the fixes landed): case-varied/dangling fences
# (finding 2), the "teach-then-quote" trailing-element policy + line-
# anchored fence matching (finding 3), and usage aggregation across a
# same-turn follow-up completion (finding 7, LOW).
# ==========================================================================
echo "-- round-1 review: parse_capability_directives now returns a 3-tuple (visible, directives, actionable) -- the trailing-element policy needs the extra field --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

FENCE = chr(96) * 3
reply = FENCE + 'capability\n{"name": "weather", "params": {}}\n' + FENCE
visible, directives, actionable = turns.parse_capability_directives(reply)
print("RETURNS_3TUPLE", True)
print("ACTIONABLE_IS_THE_DIRECTIVE", actionable is directives[0])
PY
)"
check "round-1 review: parse_capability_directives returns a 3-tuple without raising" "RETURNS_3TUPLE True" "$out"
check "round-1 review: a single, trailing, valid directive is actionable" "ACTIONABLE_IS_THE_DIRECTIVE True" "$out"

echo "-- round-1 review finding 2: a case-varied fence language tag (mixed-case or upper-case capability) is still recognized as a real directive --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

FENCE = chr(96) * 3
mixed_case = FENCE + 'Capability\n{"name": "weather", "params": {}}\n' + FENCE
visible, directives, actionable = turns.parse_capability_directives(mixed_case)
print("MIXED_CASE_PARSED", len(directives) == 1 and isinstance(directives[0], turns.CapabilityDirective))
print("MIXED_CASE_STRIPPED", (FENCE + "Capability") not in visible)

upper_case = FENCE + 'CAPABILITY\n{"name": "weather", "params": {}}\n' + FENCE
visible2, directives2, actionable2 = turns.parse_capability_directives(upper_case)
print("UPPER_CASE_PARSED", len(directives2) == 1 and isinstance(directives2[0], turns.CapabilityDirective))
PY
)"
check "round-1 review finding 2: Capability (mixed case) is recognized" "MIXED_CASE_PARSED True" "$out"
check "round-1 review finding 2: the mixed-case fence is stripped from the visible reply" "MIXED_CASE_STRIPPED True" "$out"
check "round-1 review finding 2: CAPABILITY (upper case) is recognized" "UPPER_CASE_PARSED True" "$out"

echo "-- round-1 review finding 2: an UNTERMINATED fence (no closing marker -- e.g. a reply truncated mid-JSON) never leaks raw directive text, and is reported as an error --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

FENCE = chr(96) * 3
truncated = "Let me check.\n" + FENCE + 'capability\n{"name": "weather", "para'
visible, directives, actionable = turns.parse_capability_directives(truncated)
print("NO_FENCE_LEAK", (FENCE + "capability") not in visible)
print("NO_RAW_JSON_LEAK", '"name": "weather"' not in visible)
print("KEEPS_LEADING_PROSE", "Let me check." in visible)
print("REPORTED_AS_ERROR", len(directives) == 1 and isinstance(directives[0], turns.CapabilityDirectiveError))
print("ACTIONABLE_IS_NONE", actionable is None)
PY
)"
check "round-1 review finding 2: an unterminated fence never leaks the raw fence marker" "NO_FENCE_LEAK True" "$out"
check "round-1 review finding 2: an unterminated fence never leaks the raw JSON body" "NO_RAW_JSON_LEAK True" "$out"
check "round-1 review finding 2: leading prose before the dangling fence survives" "KEEPS_LEADING_PROSE True" "$out"
check "round-1 review finding 2: an unterminated fence is reported as a CapabilityDirectiveError" "REPORTED_AS_ERROR True" "$out"
check "round-1 review finding 2: an unterminated fence is never actionable" "ACTIONABLE_IS_NONE True" "$out"

echo "-- round-1 review finding 3: teach-then-quote -- a directive followed by MORE PROSE (an example inside an explanation) is found but never actionable --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

FENCE = chr(96) * 3
reply = ("Here is how you would ask for it:\n" + FENCE + 'capability\n{"name": "weather", "params": {}}\n'
         + FENCE + "\nBut I cannot actually run this for you right now.")
visible, directives, actionable = turns.parse_capability_directives(reply)
print("DIRECTIVE_STILL_FOUND", len(directives) == 1 and isinstance(directives[0], turns.CapabilityDirective))
print("NOT_ACTIONABLE", actionable is None)
print("FENCE_STRIPPED", (FENCE + "capability") not in visible)
print("LEADING_PROSE_KEPT", "Here is how you would ask for it:" in visible)
print("TRAILING_PROSE_KEPT", "But I cannot actually run this for you right now." in visible)
PY
)"
check "round-1 review finding 3: a directive followed by more prose is still parsed (for tracing)" "DIRECTIVE_STILL_FOUND True" "$out"
check "round-1 review finding 3: it is NEVER actionable when more prose follows it (teach-then-quote)" "NOT_ACTIONABLE True" "$out"
check "round-1 review finding 3: the fence itself is still stripped from the visible reply" "FENCE_STRIPPED True" "$out"
check "round-1 review finding 3: prose BEFORE the fence survives" "LEADING_PROSE_KEPT True" "$out"
check "round-1 review finding 3: prose AFTER the fence survives" "TRAILING_PROSE_KEPT True" "$out"

echo "-- round-1 review finding 3: a fence mentioned MID-LINE (not at line start) is never matched at all -- anchored to line start (re.MULTILINE ^) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

FENCE = chr(96) * 3
reply = "You could phrase it like this: " + FENCE + 'capability\n{"name": "weather", "params": {}}\n' + FENCE
visible, directives, actionable = turns.parse_capability_directives(reply)
print("MID_LINE_FENCE_NEVER_MATCHED", directives == [])
print("ACTIONABLE_NONE", actionable is None)
PY
)"
check "round-1 review finding 3: a fence embedded mid-line is never recognized as a directive at all" "MID_LINE_FENCE_NEVER_MATCHED True" "$out"
check "round-1 review finding 3: never actionable for a mid-line mention" "ACTIONABLE_NONE True" "$out"

echo "-- round-1 review finding 3: multiple TRAILING directives (nothing but whitespace between/after) -- the FIRST one is actionable, later ones are not (still parsed, for tracing) --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

FENCE = chr(96) * 3
reply = (FENCE + 'capability\n{"name": "first"}\n' + FENCE + "\n"
         + FENCE + 'capability\n{"name": "second"}\n' + FENCE)
visible, directives, actionable = turns.parse_capability_directives(reply)
print("COUNT", len(directives))
print("ACTIONABLE_IS_FIRST", actionable is not None and actionable.name == "first")
print("ACTIONABLE_IS_NOT_LAST", actionable is not directives[-1])
PY
)"
check "round-1 review finding 3: both trailing directives are still parsed" "COUNT 2" "$out"
check "round-1 review finding 3 (mutation guard): the FIRST directive is the actionable one" "ACTIONABLE_IS_FIRST True" "$out"
check "round-1 review finding 3 (mutation guard, kills the directives[-1] mutant): the LAST one is never the actionable one" "ACTIONABLE_IS_NOT_LAST True" "$out"

echo "-- round-1 review finding 5 support: render_capability_completed_fallback exists and states the capability + its result plainly --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

text = turns.render_capability_completed_fallback("weather", "sunny, 22C")
print("NAMES_CAPABILITY", "weather" in text)
print("HAS_RESULT", "sunny, 22C" in text)
PY
)"
check "render_capability_completed_fallback: names the capability" "NAMES_CAPABILITY True" "$out"
check "render_capability_completed_fallback: includes the actual result" "HAS_RESULT True" "$out"

echo "-- round-1 review finding 7 (LOW): run_turn aggregates usage across the first completion AND a hook-driven follow-up completion, never discards the first --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

persona_cfg = {"llm": {"provider": "fake"}}
calls = []

def fake_adapter(context, **kwargs):
    calls.append(context)
    if len(calls) == 1:
        return {"text": "first", "usage": {"input_tokens": 10, "output_tokens": 5}, "timings": None}
    return {"text": "FINAL", "usage": {"input_tokens": 7, "output_tokens": 3}, "timings": None}

def get_adapter(provider):
    return fake_adapter

def on_reply(first_text, context_for_adapter, complete_fn, adapter_kwargs):
    followup = complete_fn({"system": context_for_adapter["system"], "input": "x"}, **(adapter_kwargs or {}))
    return {"text": followup["text"], "usage": followup.get("usage")}

session_state = {"summary": "", "turns": [], "turn_count": 0}
result = turns.run_turn(persona_cfg, None, None, session_state, "hello",
                         get_adapter=get_adapter, on_reply=on_reply)
usage = result["usage"] or {}
print("USAGE", usage)
print("INPUT_TOKENS_SUMMED", usage.get("input_tokens") == 17)
print("OUTPUT_TOKENS_SUMMED", usage.get("output_tokens") == 8)

# a hook that supplies NO usage at all (e.g. a refusal, no second completion
# ever ran) must leave the first completion own usage COMPLETELY untouched.
def on_reply_noop(first_text, context_for_adapter, complete_fn, adapter_kwargs):
    return {"text": "refused"}

calls.clear()
session_state2 = {"summary": "", "turns": [], "turn_count": 0}
result2 = turns.run_turn(persona_cfg, None, None, session_state2, "hello",
                          get_adapter=get_adapter, on_reply=on_reply_noop)
print("NOOP_USAGE_UNCHANGED", result2["usage"] == {"input_tokens": 10, "output_tokens": 5})
PY
)"
check "round-1 review finding 7: run_turn returns SOME usage dict, not empty" "USAGE {'input_tokens': 17, 'output_tokens': 8}" "$out"
check "round-1 review finding 7: input_tokens across both completions are SUMMED, not overwritten" "INPUT_TOKENS_SUMMED True" "$out"
check "round-1 review finding 7: output_tokens across both completions are SUMMED, not overwritten" "OUTPUT_TOKENS_SUMMED True" "$out"
check "round-1 review finding 7: a hook that supplies no usage at all leaves the first completion usage untouched" "NOOP_USAGE_UNCHANGED True" "$out"

# ==========================================================================
# #508 ROUND-2 REVIEW fixes (pinning tests, written and verified RED against
# the pre-fix code before the fixes landed): the trailing-element rule must
# actually be TAUGHT (NEW-MEDIUM), not just enforced silently, and the
# dangling-fence detector must not false-positive on an unrelated language
# tag that merely starts with "capability" (NEW-LOW).
# ==========================================================================
echo "-- round-2 review, NEW-MEDIUM: the roster teaching text states the trailing rule -- explanation BEFORE the block, never after -- so the model does not silently no-op while telling the user an action is underway --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

joined = "\n".join(turns._CAPABILITY_DIRECTIVE_TEACHING_LINES).lower()
print("STATES_LAST_OR_TRAILING", "last thing" in joined or "trailing" in joined)
print("STATES_BEFORE_NOT_AFTER", "before" in joined and "after" in joined)
PY
)"
check "round-2 review NEW-MEDIUM: the teaching text states the block must be last/trailing" "STATES_LAST_OR_TRAILING True" "$out"
check "round-2 review NEW-MEDIUM: the teaching text distinguishes explanation-before from explanation-after" "STATES_BEFORE_NOT_AFTER True" "$out"

echo "-- round-2 review, NEW-LOW: an UNRELATED, well-formed fenced block whose language tag merely STARTS WITH capability (e.g. capability-notes) must never be treated as a dangling directive -- real trailing content must survive intact --"
out="$(PYTHONPATH="$AT_SCRIPTS" python3 - <<'PY'
from assistant import turns

FENCE = chr(96) * 3
reply = ("Please read this:\n" + FENCE + "capability-notes\n"
         "Some real content that absolutely must survive this parse.\n" + FENCE
         + "\nThanks for reading!")
visible, directives, actionable = turns.parse_capability_directives(reply)
print("REAL_CONTENT_SURVIVES", "Some real content that absolutely must survive this parse." in visible)
print("TRAILING_TEXT_SURVIVES", "Thanks for reading!" in visible)
print("NO_SPURIOUS_ERROR", directives == [])
print("FENCE_TAG_ITSELF_SURVIVES", "capability-notes" in visible)

# capability.md (a different separator) must be equally unaffected.
reply2 = FENCE + "capability.md\nreal content here too\n" + FENCE + "\nmore text after"
visible2, directives2, actionable2 = turns.parse_capability_directives(reply2)
print("DOT_VARIANT_CONTENT_SURVIVES", "real content here too" in visible2 and "more text after" in visible2)
print("DOT_VARIANT_NO_SPURIOUS_ERROR", directives2 == [])
PY
)"
check "round-2 review NEW-LOW: real content inside an unrelated capability-notes block survives" "REAL_CONTENT_SURVIVES True" "$out"
check "round-2 review NEW-LOW: real trailing text after the unrelated block survives" "TRAILING_TEXT_SURVIVES True" "$out"
check "round-2 review NEW-LOW: no spurious CapabilityDirectiveError is reported for it" "NO_SPURIOUS_ERROR True" "$out"
check "round-2 review NEW-LOW: the unrelated fence own tag is never stripped" "FENCE_TAG_ITSELF_SURVIVES True" "$out"
check "round-2 review NEW-LOW: the capability.md variant is equally unaffected" "DOT_VARIANT_CONTENT_SURVIVES True" "$out"
check "round-2 review NEW-LOW: the capability.md variant reports no spurious error either" "DOT_VARIANT_NO_SPURIOUS_ERROR True" "$out"
