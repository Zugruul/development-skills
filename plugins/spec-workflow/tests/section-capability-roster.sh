#!/usr/bin/env bash
# section-capability-roster.sh -- AST-061: capability index + bounded,
# relevance-filtered roster (SPEC-ASSISTANT.md §11.3, issue #336,
# docs/design/ast-E6.md). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant.capability_index roster (AST-061: compiled index + bounded relevance-filtered roster, SPEC-ASSISTANT.md §11.3) =="

CR_SCRIPTS="$PLUGIN/scripts"

# cr_skill <skills_root> <name> <version> <description> -- writes a fresh
# `<skills_root>/<name>/` dir with a well-formed capability.yaml (given
# version) and a SKILL.md carrying the given frontmatter description.
cr_skill() {
    local root="$1" name="$2" version="$3" desc="$4"
    local dir="$root/$name"
    mkdir -p "$dir"
    printf '%s\n' \
        "version: $version" \
        "provisioning:" \
        "    check: [\"which\", \"some-bin\"]" \
        "    ttlSeconds: 300" \
        "permissions: []" \
        "invoke:" \
        "    exec: [\"some-bin\"]" \
        >"$dir/capability.yaml"
    printf '%s\n' \
        "---" \
        "name: $name" \
        "description: $desc" \
        "---" \
        "body" \
        >"$dir/SKILL.md"
}

# cr_repo <dir> <main> -- minimal discoverable assistant repo (marker +
# project.yaml), mirroring the house assistant fixture pattern (e.g.
# section-assistant-distill.sh's ad_repo).
cr_repo() {
    local dir="$1" main="$2"; shift 2
    mkdir -p "$dir/.claude"
    printf "%s\n" "# neural-network" >"$dir/.claude/.neural-network"
    {
        printf '%s\n' \
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
            "    capabilities:"
        printf '%s\n' "$@"
    } >"$dir/.claude/project.yaml"
}

# ------------------------------------------------------------------------
echo "-- unit: compile_index -- enabled + version-ok skill compiles with SKILL.md metadata --"
# NOTE (AST-062, issue #337): compile_index's default provisioning_checker is
# now the REAL TTL-cached checker (assistant.provisioning), not the AST-061
# placeholder that always assumed ok -- so this fixture's `check:` argv must
# be something that GENUINELY exits 0 (["true"], present on every POSIX
# system this suite runs on) for PROVISIONED_OK_DEFAULT to still read True.
# The real default's actual pass/fail/missing-binary/timeout behavior is
# pinned in section-capability-provisioning.sh, not here.
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="cr-compile-")
skills_root = os.path.join(root, "skills")
os.makedirs(skills_root, exist_ok=True)

dir_ = os.path.join(skills_root, "render3d")
os.makedirs(dir_, exist_ok=True)
with open(os.path.join(dir_, "capability.yaml"), "w") as fh:
    fh.write("version: 1\nprovisioning:\n    check: [\"true\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"x\"]\n")
with open(os.path.join(dir_, "SKILL.md"), "w") as fh:
    fh.write("---\nname: render3d\ndescription: renders 3D duck models for artifacts\n---\nbody\n")

cfg = {"capabilities": {"render3d": {"enabled": True}}}
index = ci.compile_index(skills_root, cfg, embed_fn=lambda texts: None)
print("N_ENTRIES", len(index.entries))
e = index.entries[0]
print("NAME", e.name)
print("ENABLED", e.enabled)
print("ONE_LINER", e.one_liner)
print("KEYWORDS_NONEMPTY", bool(e.keywords))
print("PROVISIONED_OK_DEFAULT", e.provisioned_ok)
print("UNAVAILABLE_REASON_DEFAULT", e.unavailable_reason)
print("EMBEDDING_NONE_WHEN_UNAVAILABLE", e.embedding is None)
PY
)"
check "compile_index: exactly one entry for one enabled/version-ok skill" "N_ENTRIES 1" "$out"
check "compile_index: entry name matches the skill dir" "NAME render3d" "$out"
check "compile_index: entry is enabled" "ENABLED True" "$out"
check "compile_index: one_liner comes from SKILL.md description" "ONE_LINER renders 3D duck models for artifacts" "$out"
check "compile_index: keywords are derived, non-empty" "KEYWORDS_NONEMPTY True" "$out"
check "compile_index: real default checker: a genuinely passing check reports provisioned_ok True" "PROVISIONED_OK_DEFAULT True" "$out"
check "compile_index: real default checker: a genuinely passing check has no reason" "UNAVAILABLE_REASON_DEFAULT None" "$out"
check "compile_index: embedding is None when the embeddings capability is unavailable" "EMBEDDING_NONE_WHEN_UNAVAILABLE True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: compile_index -- a DISABLED skill never enters the index at all --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="cr-disabled-")
skills_root = os.path.join(root, "skills")
for name in ("enabled-one", "disabled-one", "unconfigured-one"):
    d = os.path.join(skills_root, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "capability.yaml"), "w") as fh:
        fh.write("version: 1\nprovisioning:\n    check: [\"which\", \"x\"]\n    ttlSeconds: 60\n"
                  "permissions: []\ninvoke:\n    exec: [\"x\"]\n")

cfg = {"capabilities": {
    "enabled-one": {"enabled": True},
    "disabled-one": {"enabled": False},
    # "unconfigured-one" deliberately absent from capabilities -- default-deny
}}
index = ci.compile_index(skills_root, cfg, embed_fn=lambda texts: None)
print("NAMES", sorted(e.name for e in index.entries))
PY
)"
check "compile_index: disabled skill is absent from the index entirely" "NAMES ['enabled-one']" "$out"
check_absent "compile_index: disabled skill name never appears" "disabled-one" "$out"
check_absent "compile_index: unconfigured skill name never appears" "unconfigured-one" "$out"

# ------------------------------------------------------------------------
echo "-- unit: compile_index -- a version-incompatible skill never enters the index --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="cr-badver-")
skills_root = os.path.join(root, "skills")
d = os.path.join(skills_root, "future-skill")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "capability.yaml"), "w") as fh:
    fh.write("version: 2\nprovisioning:\n    check: [\"which\", \"x\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"x\"]\n")

cfg = {"capabilities": {"future-skill": {"enabled": True}}}
index = ci.compile_index(skills_root, cfg, embed_fn=lambda texts: None)
print("N_ENTRIES", len(index.entries))
PY
)"
check "compile_index: enabled but version-incompatible skill is never added" "N_ENTRIES 0" "$out"

# ------------------------------------------------------------------------
echo "-- unit: compile_index -- injectable provisioning_checker seam (AST-062's later plug point) --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="cr-prov-")
skills_root = os.path.join(root, "skills")
d = os.path.join(skills_root, "flaky-skill")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "capability.yaml"), "w") as fh:
    fh.write("version: 1\nprovisioning:\n    check: [\"which\", \"x\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"x\"]\n")

def checker(name, capability, skill_dir):
    return False, "binary not on PATH"

cfg = {"capabilities": {"flaky-skill": {"enabled": True}}}
index = ci.compile_index(skills_root, cfg, provisioning_checker=checker, embed_fn=lambda texts: None)
print("N_ENTRIES", len(index.entries))
e = index.entries[0]
print("STILL_IN_INDEX_ENABLED_BUT_UNPROVISIONED", e.enabled)
print("PROVISIONED_OK", e.provisioned_ok)
print("UNAVAILABLE_REASON", e.unavailable_reason)
PY
)"
check "compile_index: enabled+version-ok but unprovisioned skill STILL enters the index" "N_ENTRIES 1" "$out"
check "compile_index: unprovisioned entry stays enabled=True (flagged, not hidden)" "STILL_IN_INDEX_ENABLED_BUT_UNPROVISIONED True" "$out"
check "compile_index: injected checker's provisioned_ok is honored" "PROVISIONED_OK False" "$out"
check "compile_index: injected checker's reason is honored" "UNAVAILABLE_REASON binary not on PATH" "$out"

# ------------------------------------------------------------------------
echo "-- unit: roster_for_turn -- deterministic ranking + top-N HARD cap (N+3 skills => exactly N) --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

vocab = ["k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7"]
query = ci.Query(keywords=vocab, embedding=None)

# entry i keeps the first (8 - i) vocab words -> strictly decreasing,
# non-tied Jaccard scores against the full-vocab query (i=0 keeps all 8 ->
# score 1.0; i=7 keeps 1 -> score 1/8).
entries = []
for i in range(8):
    kept = vocab[: 8 - i]
    entries.append(ci.CapabilityIndexEntry(
        name="skill-%d" % i, one_liner="", keywords=kept, embedding=None,
        enabled=True, provisioned_ok=True, unavailable_reason=None,
    ))
index = ci.CapabilityIndex(entries=tuple(entries))

roster = ci.roster_for_turn(index, query, 5)
print("IS_LIST", isinstance(roster, list))
print("COUNT", len(roster))
print("NAMES", [e.name for e in roster])
PY
)"
check "roster_for_turn: returns a plain list (not the ask sentinel) for a clear ranking" "IS_LIST True" "$out"
check "roster_for_turn: top-N hard cap -- exactly N returned from N+3 candidates" "COUNT 5" "$out"
check "roster_for_turn: deterministic ranking -- highest-overlap skills first, in order" \
    "NAMES ['skill-0', 'skill-1', 'skill-2', 'skill-3', 'skill-4']" "$out"

# ------------------------------------------------------------------------
echo "-- unit: roster_for_turn -- a TIE at the top yields the ask-instead-of-guess sentinel --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

query = ci.Query(keywords=["render", "video", "duck"], embedding=None)
entries = (
    ci.CapabilityIndexEntry(name="alpha-render", one_liner="", keywords=["render", "video", "duck"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
    ci.CapabilityIndexEntry(name="beta-render", one_liner="", keywords=["render", "video", "duck"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
    ci.CapabilityIndexEntry(name="gamma-unrelated", one_liner="", keywords=["cooking", "pasta"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
)
index = ci.CapabilityIndex(entries=entries)
result = ci.roster_for_turn(index, query, 5)
print("IS_ASK", isinstance(result, ci.AskInsteadOfGuess))
print("REASON_MENTIONS_TIE", "tie" in result.reason.lower())
print("REASON_NAMES_BOTH", "alpha-render" in result.reason and "beta-render" in result.reason)
PY
)"
check "roster_for_turn: a genuine tie at the top returns AskInsteadOfGuess" "IS_ASK True" "$out"
check "roster_for_turn: tie sentinel's reason names it a tie" "REASON_MENTIONS_TIE True" "$out"
check "roster_for_turn: tie sentinel's reason names both tied candidates" "REASON_NAMES_BOTH True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: roster_for_turn -- LOW CONFIDENCE (nonzero but weak top score, no tie) yields the ask sentinel --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

# top match shares exactly 1 of 6 query keywords with a big union -> a weak
# Jaccard score, clearly below LOW_CONFIDENCE_THRESHOLD; the runner-up
# shares nothing, so this is NOT a tie -- purely a low-confidence single winner.
query = ci.Query(keywords=["a", "b", "c", "d", "e", "f"], embedding=None)
entries = (
    ci.CapabilityIndexEntry(name="weak-match", one_liner="", keywords=["a", "x", "y", "z", "w"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
    ci.CapabilityIndexEntry(name="no-match", one_liner="", keywords=["m", "n", "o"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
)
index = ci.CapabilityIndex(entries=entries)
result = ci.roster_for_turn(index, query, 5)
print("IS_ASK", isinstance(result, ci.AskInsteadOfGuess))
print("REASON_MENTIONS_LOW_CONFIDENCE", "low confidence" in result.reason.lower())
print("SCORE_BELOW_THRESHOLD", ci.LOW_CONFIDENCE_THRESHOLD > 0.0)
PY
)"
check "roster_for_turn: a weak nonzero top score (no tie) is low-confidence -> ask" "IS_ASK True" "$out"
check "roster_for_turn: low-confidence sentinel's reason says so" "REASON_MENTIONS_LOW_CONFIDENCE True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: roster_for_turn -- zero relevance (no candidates at all) is an EMPTY roster, not ask --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

query = ci.Query(keywords=["completely", "unrelated", "chitchat"], embedding=None)
entries = (
    ci.CapabilityIndexEntry(name="render3d", one_liner="", keywords=["render", "duck", "video"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
)
index = ci.CapabilityIndex(entries=entries)
result = ci.roster_for_turn(index, query, 5)
print("RESULT", result)
print("IS_EMPTY_LIST", result == [])
PY
)"
check "roster_for_turn: no relevant candidate at all -> empty roster (not ambiguous)" "IS_EMPTY_LIST True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: roster_for_turn -- keyword-overlap fallback used whenever either side lacks an embedding --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

# entry HAS an embedding, query does NOT -- fallback must still engage
# (never crash on the mismatched pair), scoring by keyword overlap alone.
query = ci.Query(keywords=["render", "duck"], embedding=None)
entry = ci.CapabilityIndexEntry(name="render3d", one_liner="", keywords=["render", "duck", "video"],
                                  embedding=[1.0, 0.0, 0.0], enabled=True, provisioned_ok=True,
                                  unavailable_reason=None)
index = ci.CapabilityIndex(entries=(entry,))
result = ci.roster_for_turn(index, query, 5)
print("IS_LIST", isinstance(result, list))
print("NAMES", [e.name for e in result] if isinstance(result, list) else None)
PY
)"
check "roster_for_turn: keyword fallback engages when only one side has an embedding" "IS_LIST True" "$out"
check "roster_for_turn: keyword fallback still ranks the genuinely overlapping entry in" "NAMES ['render3d']" "$out"

# ------------------------------------------------------------------------
echo "-- unit: roster_for_turn -- embedding path (cosine) is used when BOTH sides have one --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

# query vector points exactly at "aligned", orthogonal to "opposite" and
# to keyword-only reasoning: their KEYWORD sets are made IDENTICAL on
# purpose so only the embedding path can tell them apart.
query = ci.Query(keywords=["shared", "words"], embedding=[1.0, 0.0])
aligned = ci.CapabilityIndexEntry(name="aligned", one_liner="", keywords=["shared", "words"],
                                    embedding=[1.0, 0.0], enabled=True, provisioned_ok=True,
                                    unavailable_reason=None)
orthogonal = ci.CapabilityIndexEntry(name="orthogonal", one_liner="", keywords=["shared", "words"],
                                       embedding=[0.0, 1.0], enabled=True, provisioned_ok=True,
                                       unavailable_reason=None)
index = ci.CapabilityIndex(entries=(aligned, orthogonal))
result = ci.roster_for_turn(index, query, 5)
print("NAMES", [e.name for e in result] if isinstance(result, list) else ("ASK", result.reason))
PY
)"
check "roster_for_turn: embedding path ranks the cosine-aligned entry ahead of the orthogonal one" \
    "NAMES ['aligned', 'orthogonal']" "$out"

# ------------------------------------------------------------------------
echo "-- unit: roster_for_turn does not compile -- pure read of an already-compiled index, no filesystem/compile access --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

def _poison(*a, **k):
    raise AssertionError("roster_for_turn must never call compile_index")

ci_compile_index_orig = ci.compile_index
ci.compile_index = _poison
try:
    query = ci.Query(keywords=["render", "duck"], embedding=None)
    entry = ci.CapabilityIndexEntry(name="render3d", one_liner="", keywords=["render", "duck"],
                                      embedding=None, enabled=True, provisioned_ok=True,
                                      unavailable_reason=None)
    index = ci.CapabilityIndex(entries=(entry,))
    for _ in range(50):
        ci.roster_for_turn(index, query, 5)
    print("NO_COMPILE_CALLED", True)
finally:
    ci.compile_index = ci_compile_index_orig
PY
)"
check "roster_for_turn: never triggers compile_index, even across many calls (per-turn cheapness)" "NO_COMPILE_CALLED True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: run_worker -- compiles on start (immediately, without any prior signature) --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="cr-worker-start-")
skills_root = os.path.join(root, ".claude", "skills")
os.makedirs(os.path.join(skills_root, "echo-skill"), exist_ok=True)
with open(os.path.join(skills_root, "echo-skill", "capability.yaml"), "w") as fh:
    fh.write("version: 1\nprovisioning:\n    check: [\"which\", \"x\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"x\"]\n")

os.makedirs(os.path.join(root, ".claude"), exist_ok=True)
with open(os.path.join(root, ".claude", ".neural-network"), "w") as fh:
    fh.write("# neural-network\n")
with open(os.path.join(root, ".claude", "project.yaml"), "w") as fh:
    fh.write(
        "schemaVersion: 2\n"
        "assistant:\n"
        "    version: 1\n"
        "    enabled: true\n"
        "    names: [Echo]\n"
        "    systemPrompt: |\n"
        "        You are Echo.\n"
        "    llm:\n"
        "        provider: openai\n"
        "        model: gpt-5.6-sol\n"
        "    capabilities:\n"
        "        codex:\n"
        "            enabled: true\n"
        "        echo-skill:\n"
        "            enabled: true\n"
    )

calls = []
lock = threading.Lock()
def on_compile(root_, index):
    with lock:
        calls.append((root_, index))

stop = threading.Event()
t = threading.Thread(target=ci.run_worker,
                      args=(lambda: [("echo", root)], stop),
                      kwargs={"on_compile": on_compile, "poll_interval": 0.05,
                              "embed_fn": lambda texts: None})
t.start()
time.sleep(0.3)  # generous watchdog -- worker must have compiled at least once by now
stop.set()
t.join(timeout=3)

with lock:
    n = len(calls)
    names = sorted(e.name for e in calls[0][1].entries) if calls else []
print("COMPILED_AT_LEAST_ONCE", n >= 1)
print("NAMES", names)
print("WORKER_JOINED", not t.is_alive())
PY
)"
check "run_worker: compiles the index on start, without waiting for a change" "COMPILED_AT_LEAST_ONCE True" "$out"
check "run_worker: start-time compile carries the enabled skill" "NAMES ['echo-skill']" "$out"
check "run_worker: worker thread joins cleanly after stop()" "WORKER_JOINED True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: run_worker -- recompiles on a config CHANGE (never per-turn, never on an unchanged poll) --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys, tempfile, threading, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="cr-worker-change-")
skills_root = os.path.join(root, ".claude", "skills")
os.makedirs(os.path.join(skills_root, "echo-skill"), exist_ok=True)
with open(os.path.join(skills_root, "echo-skill", "capability.yaml"), "w") as fh:
    fh.write("version: 1\nprovisioning:\n    check: [\"which\", \"x\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"x\"]\n")

os.makedirs(os.path.join(root, ".claude"), exist_ok=True)
with open(os.path.join(root, ".claude", ".neural-network"), "w") as fh:
    fh.write("# neural-network\n")

def write_cfg(enabled):
    with open(os.path.join(root, ".claude", "project.yaml"), "w") as fh:
        fh.write(
            "schemaVersion: 2\n"
            "assistant:\n"
            "    version: 1\n"
            "    enabled: true\n"
            "    names: [Echo]\n"
            "    systemPrompt: |\n"
            "        You are Echo.\n"
            "    llm:\n"
            "        provider: openai\n"
            "        model: gpt-5.6-sol\n"
            "    capabilities:\n"
            "        codex:\n"
            "            enabled: true\n"
            "        echo-skill:\n"
            "            enabled: %s\n" % ("true" if enabled else "false")
        )

write_cfg(True)

calls = []
lock = threading.Lock()
def on_compile(root_, index):
    with lock:
        calls.append(sorted(e.name for e in index.entries))

stop = threading.Event()
t = threading.Thread(target=ci.run_worker,
                      args=(lambda: [("echo", root)], stop),
                      kwargs={"on_compile": on_compile, "poll_interval": 0.05,
                              "embed_fn": lambda texts: None})
t.start()
time.sleep(0.2)
with lock:
    n_before = len(calls)

# several polls pass with NOTHING changed -- must not recompile again
time.sleep(0.3)
with lock:
    n_unchanged = len(calls)

# now flip enabled -> false: a real config CHANGE, must trigger exactly one more compile
write_cfg(False)
time.sleep(0.3)
with lock:
    n_after_change = len(calls)
    last = calls[-1]

stop.set()
t.join(timeout=3)

print("N_BEFORE", n_before)
print("NO_RECOMPILE_WHILE_UNCHANGED", n_unchanged == n_before)
print("RECOMPILED_AFTER_CHANGE", n_after_change > n_unchanged)
print("LAST_REFLECTS_DISABLED_SKILL", last == [])
PY
)"
check "run_worker: at least one start-time compile happened" "N_BEFORE 1" "$out"
check "run_worker: no recompile fires while nothing changed between polls" "NO_RECOMPILE_WHILE_UNCHANGED True" "$out"
check "run_worker: a real config change (enabled flips) triggers exactly one more recompile" "RECOMPILED_AFTER_CHANGE True" "$out"
check "run_worker: the recompiled index reflects the newly-disabled skill's absence" "LAST_REFLECTS_DISABLED_SKILL True" "$out"

# ------------------------------------------------------------------------
# AST-071 (SPEC-ASSISTANT.md §11.8, docs/design/ast-E6.md sequence 5):
# nearest_entries -- the DISPLAY-ONLY sibling of roster_for_turn, used by
# turns.capability_gap_reply to name "nearest enabled abilities" in an
# in-persona refusal even when NOTHING scored well enough for
# roster_for_turn to trust as an actual match (which returns [] in that
# case). Deterministic ranking off the already-compiled index -- never a
# fresh LLM guess.
# ------------------------------------------------------------------------
echo "-- unit: nearest_entries -- ranks by ACTUAL relevance (differing nonzero scores), never an alphabetical dump of zero-score entries (review round 1, HIGH #1) --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

# a query with GENUINE, DIFFERING partial overlap against two entries, and
# ZERO overlap against a third -- proves nearest_entries (a) ranks by real
# relevance, highest first, and (b) EXCLUDES the zero-score entry rather
# than including it just to pad out the count (the round-1 finding: a
# prior version sorted by (-score, name) without filtering, so two
# zero-score entries came back in plain alphabetical order -- indistinguishable
# from a real ranking).
query = ci.Query(keywords=["render", "duck", "video", "clip"], embedding=None)
entries = (
    ci.CapabilityIndexEntry(name="video-renderer", one_liner="renders video clips",
                              keywords=["render", "duck", "video", "clip"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
    ci.CapabilityIndexEntry(name="photo-editor", one_liner="edits photos", keywords=["render", "photo"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
    ci.CapabilityIndexEntry(name="cooking-helper", one_liner="suggests recipes", keywords=["pasta", "recipe"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
)
index = ci.CapabilityIndex(entries=entries)

nearest = ci.nearest_entries(index, query, 3)
print("NEAREST_COUNT", len(nearest))
print("NEAREST_NAMES_IN_ORDER", [e.name for e in nearest])
print("ZERO_SCORE_ENTRY_EXCLUDED", "cooking-helper" not in [e.name for e in nearest])
PY
)"
check "nearest_entries: excludes the zero-score entry (never pads with irrelevant candidates)" "NEAREST_COUNT 2" "$out"
check "nearest_entries: highest-relevance entry ranked first" "NEAREST_NAMES_IN_ORDER ['video-renderer', 'photo-editor']" "$out"
check "nearest_entries: a genuinely unrelated entry never appears" "ZERO_SCORE_ENTRY_EXCLUDED True" "$out"

echo "-- unit: nearest_entries -- a nonEMPTY index with NO relevance signal at all still returns [], never an alphabetical fallback --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

# every entry scores EXACTLY 0 against this query (this is also the only
# way roster_for_turn itself can ever return [] -- see turns.py
# capability_gap_reply docstring for the proof this is the SAME condition).
query = ci.Query(keywords=["duck", "render", "video"], embedding=None)
entries = (
    ci.CapabilityIndexEntry(name="weather", one_liner="checks the weather", keywords=["weather", "forecast"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
    ci.CapabilityIndexEntry(name="reminders", one_liner="sets reminders", keywords=["reminder", "schedule"],
                              embedding=None, enabled=True, provisioned_ok=True, unavailable_reason=None),
)
index = ci.CapabilityIndex(entries=entries)

roster = ci.roster_for_turn(index, query, 5)
nearest = ci.nearest_entries(index, query, 2)
print("ROSTER_EMPTY", roster == [])
print("NEAREST_EMPTY_TOO", nearest == [])
PY
)"
check "nearest_entries: sanity -- roster_for_turn also returns [] for this zero-relevance query" "ROSTER_EMPTY True" "$out"
check "nearest_entries: an index with entries but zero relevance returns [], never a fabricated ranking" "NEAREST_EMPTY_TOO True" "$out"

echo "-- unit: nearest_entries -- HARD top-N cap, deterministic (-score, name) ordering (fixture already uses genuinely differing nonzero scores -- unaffected by the zero-score filter) --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

vocab = ["k0", "k1", "k2", "k3", "k4", "k5"]
query = ci.Query(keywords=vocab, embedding=None)
entries = []
for i in range(6):
    kept = vocab[: 6 - i]  # strictly decreasing overlap -> strictly decreasing score
    entries.append(ci.CapabilityIndexEntry(
        name="skill-%d" % i, one_liner="", keywords=kept, embedding=None,
        enabled=True, provisioned_ok=True, unavailable_reason=None,
    ))
index = ci.CapabilityIndex(entries=tuple(entries))

top2 = ci.nearest_entries(index, query, 2)
print("TOP2_COUNT", len(top2))
print("TOP2_NAMES", [e.name for e in top2])
PY
)"
check "nearest_entries: hard top-N cap -- exactly N from more candidates" "TOP2_COUNT 2" "$out"
check "nearest_entries: highest-overlap entries first, deterministic order" "TOP2_NAMES ['skill-0', 'skill-1']" "$out"

echo "-- unit: nearest_entries -- degrades to [] for a genuinely empty index (Sec17: never a crash) --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

empty_index = ci.CapabilityIndex(entries=())
query = ci.Query(keywords=["anything"], embedding=None)
print("EMPTY_RESULT", ci.nearest_entries(empty_index, query, 3))
PY
)"
check "nearest_entries: empty index -> [] (no crash, no fabricated candidate)" "EMPTY_RESULT []" "$out"

echo "-- unit: nearest_entries -- includes enabled-but-unprovisioned entries (Sec11.4: named, never hidden) --"
out="$(SCRIPTS_DIR="$CR_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

query = ci.Query(keywords=["render"], embedding=None)
entries = (
    ci.CapabilityIndexEntry(name="renderer", one_liner="renders things", keywords=["render"],
                              embedding=None, enabled=True, provisioned_ok=False,
                              unavailable_reason="binary not on PATH"),
)
index = ci.CapabilityIndex(entries=entries)
nearest = ci.nearest_entries(index, query, 3)
print("COUNT", len(nearest))
print("NAME", nearest[0].name if nearest else None)
print("REASON", nearest[0].unavailable_reason if nearest else None)
PY
)"
check "nearest_entries: an unprovisioned-but-enabled entry is still returned" "COUNT 1" "$out"
check "nearest_entries: its unavailable reason travels with it" "REASON binary not on PATH" "$out"
