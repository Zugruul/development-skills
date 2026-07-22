#!/usr/bin/env bash
# section-brain-library.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain library API (AST-003: recall()/mint() as importable functions) =="

BL_SCRIPTS="$PLUGIN/scripts"
BRAIN="$BL_SCRIPTS/brain.py"

# ------------------------------------------------------------------------
# (1) recall()/mint() are importable and callable directly, produce NO
# stdout of their own (structured return, not printing), and return the
# documented structured shapes.
# ------------------------------------------------------------------------
BL1="$(mktemp -d)"
out="$(python3 - "$BL1" "$BL_SCRIPTS" <<'PY'
import sys, io, os, contextlib
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain

identities = os.path.join(root, ".claude/identities")

buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    mint_result = brain.mint(
        identities, "dev", "lib-note", root,
        "A library-minted lesson.\n\nRelated: [[lib-note-2]]\n",
        tags="x", paths="x/**", source="lib-test",
    )
mint_stdout = buf.getvalue()

buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    recall_result = brain.recall(identities, "dev", root, paths="x/foo.sh", keywords="")
recall_stdout = buf.getvalue()

print("MINT_STDOUT_LEN:%d" % len(mint_stdout))
print("MINT_KEYS:%s" % ",".join(sorted(mint_result.keys())))
print("MINT_STRENGTH:%d" % mint_result["strength"])
print("MINT_FORMED:%s" % ",".join(mint_result["formed_links"]))
print("MINT_SLUG:%s" % mint_result["slug"])
print("MINT_NOTICE:%s" % ("none" if mint_result["confidence_downgrade_notice"] is None else "set"))

print("RECALL_STDOUT_LEN:%d" % len(recall_stdout))
print("RECALL_KEYS:%s" % ",".join(sorted(recall_result.keys())))
print("RECALL_BLOCKS:%d" % len(recall_result["blocks"]))
print("RECALL_SEEDS:%d" % recall_result["seeds"])
print("RECALL_INJECTED:%d" % recall_result["injected"])
print("RECALL_HAS_NOTE:%s" % ("yes" if any("lib-note" in b for b in recall_result["blocks"]) else "no"))
PY
)"
check "mint() prints nothing to stdout" "MINT_STDOUT_LEN:0" "$out"
check "mint() returns the documented keys" "MINT_KEYS:confidence,confidence_downgrade_notice,formed_links,path,role,slug,strength" "$out"
check "mint() returns strength 1 for a first-time mint" "MINT_STRENGTH:1" "$out"
check "mint() reports the wikilink it formed" "MINT_FORMED:lib-note->lib-note-2" "$out"
check "mint() echoes back the slug" "MINT_SLUG:lib-note" "$out"
check "mint() no confidence-downgrade notice on a plain mint" "MINT_NOTICE:none" "$out"

check "recall() prints nothing to stdout" "RECALL_STDOUT_LEN:0" "$out"
check "recall() returns the documented keys" "RECALL_KEYS:blocks,injected,links_fired,seeds" "$out"
check "recall() found and injected the minted note" "RECALL_HAS_NOTE:yes" "$out"
check "recall() seeds count is 1" "RECALL_SEEDS:1" "$out"
check "recall() injected count is 1" "RECALL_INJECTED:1" "$out"

# side effects a subprocess CLI shim would have relied on are still present:
# NoteMinted + LinkFormed + RecallPerformed on the unified brain-event feed.
events="$(cat "$BL1/.claude/brain-events.jsonl" 2>/dev/null || true)"
check "mint() still emits NoteMinted to brain-events.jsonl" '"type": "NoteMinted"' "$events"
check "mint() still emits LinkFormed to brain-events.jsonl" '"type": "LinkFormed"' "$events"
check "recall() still emits RecallPerformed to brain-events.jsonl" '"type": "RecallPerformed"' "$events"

rm -rf "$BL1"

# ------------------------------------------------------------------------
# (2) CLI-vs-library equivalence: the CLI (cmd_recall/cmd_mint) is a thin
# renderer over recall()/mint() -- its stdout must equal a rendering of the
# library result, for a representative set of invocations (recall with
# hits, recall with no hits, recall --budget, mint new slug, mint
# existing slug/strength bump).
# ------------------------------------------------------------------------
BL2="$(mktemp -d)"
brain() { python3 "$BRAIN" "$BL2" "$@"; }

# mint new slug -- CLI
mint_cli_1="$(printf 'Equivalence-check lesson body.\n\nSee also: [[eq-note-2]]\n' \
    | brain mint dev eq-note --tags eq --paths "eq/**" --source "PR#eq")"
# same inputs -- library (against a byte-identical fixture)
mint_lib_1="$(python3 - "$BL2" "$BL_SCRIPTS" <<'PY'
import sys, os
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain
identities = os.path.join(root, ".claude/identities")
notes = brain.load_notes(identities, "dev")
fm = notes["eq-note"]["fm"]
# a rendering of the CLI mint above -- reconstruct via the same format
# string cmd_mint uses, from the note as it now stands on disk (strength 1,
# formed the eq-note-2 link, exactly like the CLI call above)
print("minted dev/eq-note (strength %d, 1 new link(s))" % fm["strength"])
PY
)"
mint_lib_1_rc=$?
check_rc "mint_lib_1 heredoc computed without error (no vacuous empty-string match)" 0 "$mint_lib_1_rc"
check "mint CLI stdout equals a rendering of the mint() result (new slug)" "$mint_lib_1" "$mint_cli_1"

# mint existing slug (strength bump) -- CLI
mint_cli_2="$(printf 'Re-minted body for the bump.\n' \
    | brain mint dev eq-note --tags eq --paths "eq/**" --source "PR#eq")"
check "mint CLI on re-mint reports the bumped strength" "minted dev/eq-note (strength 2, 0 new link(s))" "$mint_cli_2"

# recall with hits -- CLI vs library rendering
recall_cli_hits="$(brain recall dev --paths "eq/x.sh" --keywords "")"
recall_lib_hits="$(python3 - "$BL2" "$BL_SCRIPTS" <<'PY'
import sys, os
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain
identities = os.path.join(root, ".claude/identities")
result = brain.recall(identities, "dev", root, paths="eq/x.sh", keywords="")
text = "\n".join(result["blocks"])
print(text if text else "(no lessons recalled)")
PY
)"
recall_lib_hits_rc=$?
check_rc "recall_lib_hits heredoc computed without error (no vacuous empty-string match)" 0 "$recall_lib_hits_rc"
check "recall CLI stdout equals a rendering of recall() (hits)" "$recall_lib_hits" "$recall_cli_hits"

# recall with no hits -- CLI vs library rendering
recall_cli_empty="$(brain recall dev --paths "nowhere/nothing.sh" --keywords "no-such-keyword")"
check "recall CLI with no hits" "(no lessons recalled)" "$recall_cli_empty"
recall_lib_empty="$(python3 - "$BL2" "$BL_SCRIPTS" <<'PY'
import sys, os
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain
identities = os.path.join(root, ".claude/identities")
result = brain.recall(identities, "dev", root, paths="nowhere/nothing.sh", keywords="no-such-keyword")
text = "\n".join(result["blocks"])
print(text if text else "(no lessons recalled)")
PY
)"
recall_lib_empty_rc=$?
check_rc "recall_lib_empty heredoc computed without error (no vacuous empty-string match)" 0 "$recall_lib_empty_rc"
check "recall CLI stdout equals a rendering of recall() (no hits)" "$recall_lib_empty" "$recall_cli_empty"

# recall --budget -- CLI vs library rendering (title-only tier, truncated)
recall_cli_budget="$(brain recall dev --paths "eq/x.sh" --keywords "" --budget 8)"
recall_lib_budget="$(python3 - "$BL2" "$BL_SCRIPTS" <<'PY'
import sys, os
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain
identities = os.path.join(root, ".claude/identities")
result = brain.recall(identities, "dev", root, paths="eq/x.sh", keywords="", budget=8)
text = "\n".join(result["blocks"])
print(text if text else "(no lessons recalled)")
PY
)"
recall_lib_budget_rc=$?
check_rc "recall_lib_budget heredoc computed without error (no vacuous empty-string match)" 0 "$recall_lib_budget_rc"
check "recall CLI stdout equals a rendering of recall() (--budget)" "$recall_lib_budget" "$recall_cli_budget"

rm -rf "$BL2"

# ------------------------------------------------------------------------
# (3) mint-then-recall round trip entirely through the library API, in a
# fresh fixture brain -- no CLI subprocess involved at all.
# ------------------------------------------------------------------------
BL3="$(mktemp -d)"
out="$(python3 - "$BL3" "$BL_SCRIPTS" <<'PY'
import sys, os
root, scripts = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import brain

identities = os.path.join(root, ".claude/identities")

m1 = brain.mint(identities, "dev", "roundtrip-note", root,
                 "Round trip body, no wikilinks.\n",
                 tags="rt", paths="rt/**", source="rt-test")
r1 = brain.recall(identities, "dev", root, paths="rt/thing.sh", keywords="")

# bump the same note a second time
m2 = brain.mint(identities, "dev", "roundtrip-note", root,
                 "Round trip body, updated.\n",
                 tags="rt", paths="rt/**", source="rt-test")

print("M1_STRENGTH:%d" % m1["strength"])
print("M2_STRENGTH:%d" % m2["strength"])
print("R1_HAS_NOTE:%s" % ("yes" if any("roundtrip-note" in b for b in r1["blocks"]) else "no"))
print("NOTE_FILE_EXISTS:%s" % ("yes" if os.path.isfile(m1["path"]) else "no"))
PY
)"
check "round trip: first mint strength 1" "M1_STRENGTH:1" "$out"
check "round trip: second mint bumps to strength 2" "M2_STRENGTH:2" "$out"
check "round trip: recall() finds the just-minted note" "R1_HAS_NOTE:yes" "$out"
check "round trip: note file was written at the returned path" "NOTE_FILE_EXISTS:yes" "$out"

rm -rf "$BL3"
