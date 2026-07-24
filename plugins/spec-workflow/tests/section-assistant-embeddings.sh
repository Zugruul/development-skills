#!/usr/bin/env bash
# section-assistant-embeddings.sh -- AST-018: embeddings-on-by-default recall
# wiring + index refresh hook (SPEC-ASSISTANT.md Sec9.1, Sec9.3, issue #316).
# Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant embeddings recall (AST-018: embeddings-on-by-default + refresh hook, SPEC-ASSISTANT.md Sec9.1/Sec9.3) =="

AE_SCRIPTS="$PLUGIN/scripts"

# House stub embedder pattern (section-brain-hybrid-recall.sh): a fixed small
# vocabulary maps words to one-hot-ish direction components so cosine
# similarity genuinely discriminates by shared vocabulary. Vocabulary is
# trip-planning flavored to match this fixture's vague-topic query.
AESTUB_DIR="$(mktemp -d)"
AESTUB="$AESTUB_DIR/.fake-embed-ae.py"
cat >"$AESTUB" <<'PY'
import json, sys

VOCAB = {"trip": 0, "itinerary": 1, "flights": 2, "vacation": 3}

def vec(text):
    v = [0.0, 0.0, 0.0, 0.0]
    for w in text.lower().split():
        w = w.strip(".,!?")
        if w in VOCAB:
            v[VOCAB[w]] += 1.0
    return v

for line in sys.stdin:
    print(json.dumps(vec(line.rstrip("\n"))))
PY
AESTUB_CMD="python3 $AESTUB"

# ---- test 1/2: vague-topic query (Sec9.1 AC pair) --------------------------
# "that trip planning thing" shares no vocabulary with the note's tags
# (tags="logistics") so lexical-only seeding (paths/tags intersection) MISSES
# it; the note body ("Book your flights, check the itinerary, and plan the
# trip.") shares the word "trip" with the query under the stub's deterministic
# vector scheme, so embeddings-on-by-default recall (make_default_recall
# reaching brain.recall's hybrid path whenever index.sqlite3 exists) HITS it.
AE1="$(mktemp -d)"
AE1_IDENTITIES="$AE1/.claude/identities"
mkdir -p "$AE1_IDENTITIES"
out="$(PYTHONPATH="$AE_SCRIPTS" BRAIN_EMBED_CMD="$AESTUB_CMD" python3 - "$AE1" "$AE1_IDENTITIES" <<'PY'
import sys
root, identities = sys.argv[1], sys.argv[2]
import brain
from assistant import turns

brain.mint(identities, "assistant", "trip-note", root,
           "Book your flights, check the itinerary, and plan the trip.\n",
           tags="logistics", paths="")

recall_fn = turns.make_default_recall(identities, root, role="assistant")

# (a) no index.sqlite3 sidecar exists yet -> lexical-only path, vague query misses
lex_result = recall_fn("that trip planning thing")
print("LEX_MISS", "trip-note" not in "\n".join(lex_result["blocks"]))

# (b) build the embeddings index, then recall through the SAME
# embeddings-on-by-default closure (no separate opt-in required)
brain.refresh_index(identities, "assistant")
hybrid_result = recall_fn("that trip planning thing")
print("HYBRID_HIT", "trip-note" in "\n".join(hybrid_result["blocks"]))
PY
)"
check "vague-topic query: lexical-only recall misses the semantically-related note" "LEX_MISS True" "$out"
check "vague-topic query: embeddings-on-by-default recall (make_default_recall) surfaces it" "HYBRID_HIT True" "$out"
rm -rf "$AE1"

# ---- test 3: mint -> refresh hook -> recallable within one batch cycle (Sec9.3 AC) ----
# A brand-new note minted AFTER the index already exists is invisible to the
# hybrid path until the index is refreshed; calling the refresh hook once
# (the "one batch cycle" the distiller's future worker loop will perform)
# makes it recallable immediately, with no rebuild/restart of anything else.
AE2="$(mktemp -d)"
AE2_IDENTITIES="$AE2/.claude/identities"
mkdir -p "$AE2_IDENTITIES"
out="$(PYTHONPATH="$AE_SCRIPTS" BRAIN_EMBED_CMD="$AESTUB_CMD" python3 - "$AE2" "$AE2_IDENTITIES" <<'PY'
import sys
root, identities = sys.argv[1], sys.argv[2]
import brain
from assistant import turns, distill

brain.mint(identities, "assistant", "trip-note", root,
           "Book your flights, check the itinerary, and plan the trip.\n",
           tags="logistics", paths="")
brain.refresh_index(identities, "assistant")

recall_fn = turns.make_default_recall(identities, root, role="assistant")

# mint a SECOND note after the index already exists -- not yet indexed
brain.mint(identities, "assistant", "vacation-note", root,
           "Vacation checklist: passport, itinerary, flights booked.\n",
           tags="logistics-2", paths="")
before = recall_fn("that vacation planning thing")
print("BEFORE_REFRESH_MISS", "vacation-note" not in "\n".join(before["blocks"]))

# the E3 distiller seam: mint -> refresh_after_mint -> recallable
distill.refresh_after_mint(identities, root, role="assistant")
after = recall_fn("that vacation planning thing")
print("AFTER_REFRESH_HIT", "vacation-note" in "\n".join(after["blocks"]))
PY
)"
check "refresh hook: newly minted note is invisible to hybrid recall before refresh" "BEFORE_REFRESH_MISS True" "$out"
check "refresh hook: distill.refresh_after_mint makes it recallable within one batch cycle" "AFTER_REFRESH_HIT True" "$out"
rm -rf "$AE2"

# ---- test 4: refresh_index is a thin extraction of cmd_index's own logic ----
# (importable library entry point, same shape as brain.recall/brain.mint's
# own CLI-vs-library extraction pattern, AST-003).
AE3="$(mktemp -d)"
AE3_IDENTITIES="$AE3/.claude/identities"
mkdir -p "$AE3_IDENTITIES"
out="$(PYTHONPATH="$AE_SCRIPTS" BRAIN_EMBED_CMD="$AESTUB_CMD" python3 - "$AE3" "$AE3_IDENTITIES" <<'PY'
import sys
root, identities = sys.argv[1], sys.argv[2]
import brain

brain.mint(identities, "assistant", "trip-note", root,
           "Book your flights, check the itinerary, and plan the trip.\n",
           tags="logistics", paths="")
result = brain.refresh_index(identities, "assistant")
print("RETURNS_DICT", isinstance(result, dict))
print("UPDATED_COUNT", result.get("updated"))
db_path = brain.index_db_path(identities, "assistant")
import os
print("DB_EXISTS", os.path.exists(db_path))
PY
)"
check "refresh_index: returns a structured result dict" "RETURNS_DICT True" "$out"
check "refresh_index: reports one note updated" "UPDATED_COUNT 1" "$out"
check "refresh_index: builds the same index.sqlite3 sidecar cmd_index would" "DB_EXISTS True" "$out"
rm -rf "$AE3"

# ---- test 5: degradation -- capability unavailable never crashes recall ----
# (invariant: embeddings-on-by-default degrades to lexical-only, silently,
# whenever the embeddings capability itself is unavailable -- distinct from
# "no index built yet", this is "index build was attempted but the
# capability failed", exercised by simply never wiring BRAIN_EMBED_CMD).
AE4="$(mktemp -d)"
AE4_IDENTITIES="$AE4/.claude/identities"
mkdir -p "$AE4_IDENTITIES"
# CAPABILITY_HOME pinned to an empty dir: "unavailable" must hold even on a
# machine where the real embeddings capability IS installed (MEM-030 slow
# tests legitimately install it into ~/.claude/capabilities).
AE4_NOCAP="$AE4/no-capabilities"
mkdir -p "$AE4_NOCAP"
out="$(CAPABILITY_HOME="$AE4_NOCAP" PYTHONPATH="$AE_SCRIPTS" python3 - "$AE4" "$AE4_IDENTITIES" <<'PY'
import sys
root, identities = sys.argv[1], sys.argv[2]
import brain
from assistant import turns, distill

brain.mint(identities, "assistant", "kw-note", root,
           "Plain keyword note.\n", tags="widget", paths="")

# refresh_index / refresh_after_mint with no embeddings capability wired at
# all -- must not raise, must not crash the process
result = brain.refresh_index(identities, "assistant")
print("REFRESH_NO_CRASH", isinstance(result, dict))
print("CAPABILITY_UNAVAILABLE", result.get("capability_available") is False)

distill.refresh_after_mint(identities, root, role="assistant")
print("HOOK_NO_CRASH", True)

recall_fn = turns.make_default_recall(identities, root, role="assistant")
lex_result = recall_fn("widget")
print("LEXICAL_STILL_WORKS", "kw-note" in "\n".join(lex_result["blocks"]))
PY
)"
rc=$?
check_rc "degradation: no capability wired never crashes the process" 0 "$rc"
check "degradation: refresh_index returns a result without raising" "REFRESH_NO_CRASH True" "$out"
check "degradation: capability_available reported False (attempted, failed)" "CAPABILITY_UNAVAILABLE True" "$out"
check "degradation: refresh_after_mint hook never crashes either" "HOOK_NO_CRASH True" "$out"
check "degradation: lexical recall still works with no embeddings capability" "LEXICAL_STILL_WORKS True" "$out"
rm -rf "$AE4"

rm -rf "$AESTUB_DIR"
