#!/usr/bin/env bash
# section-assistant-isolation.sh -- AST-015: harness-contamination isolation
# test (SPEC-ASSISTANT.md Sec8.4, Sec16, issue #313). Sourced by
# run-tests.sh; do not run standalone.
#
# MERGE-GATING BY CONSTRUCTION: every section run-tests.sh sources is part
# of `bash plugins/spec-workflow/tests/run-tests.sh`, which is the whole of
# `commands.gate` (AGENTS.md), and the gate must be green before any task
# merges -- there is no separate "optional" tier. This section is called out
# by name in SPEC-ASSISTANT.md Sec16 ("The isolation test (Sec8.4) ... is
# merge-gating") only because it is the specific regression net for Sec8.4/
# Sec17.2: any future adapter flag change, turns.py change that starts
# reading a file it shouldn't, or engine change that injects dev-workflow
# instructions into a turn fails THIS section, loudly, on every gate run.
#
# WHAT "effective injected context" means here (SPEC-ASSISTANT.md Sec8.4):
# everything that reaches a provider CLI for one turn --
#   (a) the composed context strings (turns.compose_context's system+input)
#   (b) the argv the adapter builds (recorded by the stub binaries, same
#       mechanism as section-assistant-adapter.sh / section-assistant-claude.sh)
#   (c) the env/home the adapter passes -- for codex, the isolated CODEX_HOME
#       contents (recorded by the stub via CODEX_STUB_HOME_FILE, same
#       mechanism as AST-011's own test); for claude there is no analogous
#       env-home rebuild (claude.py's own docstring documents why: isolation
#       is via --safe-mode/--strict-mcp-config/--tools "" flags plus an
#       isolated cwd, NOT an env-home swap -- see claude.py's "Isolated
#       env-home -- REJECTED for claude" section), so part (c) for claude is
#       "assert the suppression flags are present in recorded argv" instead.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant isolation (AST-015: harness-contamination isolation test, SPEC-ASSISTANT.md Sec8.4/Sec16, MERGE-GATING) =="

AI_SCRIPTS="$PLUGIN/scripts"
AI_STUB_CODEX="$FIX/stub-codex"
AI_STUB_CLAUDE="$FIX/stub-claude"
AI_REPO_ROOT="$(cd "$PLUGIN/../.." && pwd)"

# --- canary set ------------------------------------------------------------
# Fake dev-workflow surface, rich in canary text, planted in a fake "real"
# home the fixture turn is run against -- simulates a machine where this
# repo's own dev-workflow config sits right next to the assistant.
AI_CANARY_CODEX_AGENTS="CANARY-CODEX-HOME-AGENTS-DEV-WORKFLOW-MUST-NEVER-REACH-A-TURN"
AI_CANARY_CLAUDE_MD="CANARY-CLAUDE-MD-GLOBAL-INSTRUCTION-DEV-WORKFLOW-MUST-NEVER-REACH-A-TURN"
AI_CANARY_SKILL="CANARY-DEV-WORKFLOW-SKILL-TEXT"
# Contamination-self-test-only canary (Sec (c) below); never planted in the
# fake dev-workflow surface, only injected directly into a persona
# systemPrompt to prove the detector fires.
AI_CANARY_SELFTEST="CANARY-INJECTED-FOR-SELFTEST-CONTAMINATION"

# This repo's OWN real instruction markers -- verbatim phrases from
# AGENTS.md and skills/build-next/SKILL.md, the two files every dev-workflow
# turn in this repo is steeped in. Chosen because they are (1) multi-word
# and specific enough that an accidental partial match is implausible, (2)
# drawn from exactly the two documents named in the AST-015 brief, and (3)
# provenance-checked below (not just asserted absent from the dump, but
# asserted PRESENT in the named source file right now) so a future edit to
# either file that silently invalidates a marker fails loudly here instead
# of leaving a stale, no-longer-meaningful canary in place.
AI_MARKER_1="You may be the loop itself"
AI_MARKER_1_SRC="$AI_REPO_ROOT/AGENTS.md"
AI_MARKER_2="strict TDD (a failing test commits before the implementation that turns it green)"
AI_MARKER_2_SRC="$AI_REPO_ROOT/AGENTS.md"
AI_MARKER_3="one build iteration"
AI_MARKER_3_SRC="$PLUGIN/skills/build-next/SKILL.md"

check "provenance: marker 1 is verbatim in AGENTS.md right now" "$AI_MARKER_1" "$(cat "$AI_MARKER_1_SRC" 2>/dev/null)"
check "provenance: marker 2 is verbatim in AGENTS.md right now" "$AI_MARKER_2" "$(cat "$AI_MARKER_2_SRC" 2>/dev/null)"
check "provenance: marker 3 is verbatim in skills/build-next/SKILL.md right now" "$AI_MARKER_3" "$(cat "$AI_MARKER_3_SRC" 2>/dev/null)"

AI_CANARIES=(
    "$AI_CANARY_CODEX_AGENTS"
    "$AI_CANARY_CLAUDE_MD"
    "$AI_CANARY_SKILL"
    "$AI_CANARY_SELFTEST"
    "$AI_MARKER_1"
    "$AI_MARKER_2"
    "$AI_MARKER_3"
)

# iso_assert_clean <label> <dump-text> -- asserts the dump is non-vacuous
# (carries the real persona marker "Aria") AND carries none of the canaries
# above. Reused for both adapters so the two providers are held to the
# identical bar.
iso_assert_clean() {
    local label="$1" text="$2" c
    check "$label: non-vacuous -- dump carries the real persona text" "Aria" "$text"
    for c in "${AI_CANARIES[@]}"; do
        check_absent "$label: dump carries no dev-workflow contamination ($c)" "$c" "$text"
    done
}

# --- fixture assistant repo: a brain with ONLY persona-appropriate notes ---
AI_ROOT="$(mktemp -d)"
AI_IDENTITIES="$AI_ROOT/.claude/identities"
mkdir -p "$AI_IDENTITIES"
AI_TMPPY="$(mktemp -d)"

cat >"$AI_TMPPY/mint.py" <<PYEOF
import sys
root, identities = sys.argv[1], sys.argv[2]
import brain

brain.mint(identities, "assistant", "clean-schedule-note", root,
           "Prefer the shared calendar over ad-hoc emails for scheduling.\n",
           tags="scheduling,calendar", paths="")
print("MINTED")
PYEOF
mint_out="$(PYTHONPATH="$AI_SCRIPTS" python3 "$AI_TMPPY/mint.py" "$AI_ROOT" "$AI_IDENTITIES" 2>&1)"
check "fixture: mints a clean persona-appropriate note into the assistant brain" "MINTED" "$mint_out"

# dump_turn.py <root> <identities> <provider> <dump_file> <contaminate 0|1> --
# drives ONE full turn through turns.run_turn (Sec8.4's exact call shape),
# also calling compose_context directly first (same args) so the composed
# {system, input} strings -- not just run_turn's chips/text -- land in the
# dump. `contaminate=1` appends AI_CANARY_SELFTEST to the persona
# systemPrompt (the contamination-discrimination fixture, part (c) below).
cat >"$AI_TMPPY/dump_turn.py" <<PYEOF
import json
import sys

root, identities, provider, dump_file, contaminate = sys.argv[1:6]

from assistant import turns

persona_cfg = {
    "systemPrompt": (
        "You are Aria, the office scheduling assistant. "
        "Keep replies under two sentences."
    ),
    "names": ["Aria"],
    "llm": {"provider": provider, "model": "test-model-x"},
}
if contaminate == "1":
    persona_cfg["systemPrompt"] += " CANARY-INJECTED-FOR-SELFTEST-CONTAMINATION"

recall_fn = turns.make_default_recall(identities, root, role="assistant")
user_message = "What is on my calendar today?"

composed = turns.compose_context(persona_cfg, None, recall_fn, {}, user_message)
turn_result = turns.run_turn(persona_cfg, None, recall_fn, {}, user_message,
                              adapter_kwargs={"timeout": 10})

dump = {
    "system": composed["context_for_adapter"].get("system"),
    "input": composed["context_for_adapter"].get("input"),
    "chips": composed["chips"],
    "run_turn_text": turn_result["text"],
}
with open(dump_file, "w") as fh:
    json.dump(dump, fh)
print("OK", turn_result["text"])
PYEOF

# --- fake dev-workflow surface (planted, never read by any code path here) -
AI_FAKE_CODEX_HOME="$(mktemp -d)"
printf '%s\n' '{"token": "fake-canary-auth-token"}' >"$AI_FAKE_CODEX_HOME/auth.json"
printf '%s\n' "$AI_CANARY_CODEX_AGENTS" >"$AI_FAKE_CODEX_HOME/AGENTS.md"

AI_FAKE_HOME="$(mktemp -d)"
mkdir -p "$AI_FAKE_HOME/.claude/plugins/marketplace/spec-workflow/skills/fake-skill"
printf '%s\n' "$AI_CANARY_CLAUDE_MD" >"$AI_FAKE_HOME/.claude/CLAUDE.md"
printf '%s\n' "$AI_CANARY_SKILL" >"$AI_FAKE_HOME/.claude/plugins/marketplace/spec-workflow/skills/fake-skill/SKILL.md"

# ---------------------------------------------------------- (b1) codex, clean
AI_CODEX_ARGV="$(mktemp)"
AI_CODEX_HOMEFILE="$(mktemp)"
AI_CODEX_DUMP="$(mktemp)"
codex_out="$(PATH="$AI_STUB_CODEX:$PATH" \
    CODEX_STUB_MODE=ok \
    CODEX_STUB_ARGV_FILE="$AI_CODEX_ARGV" \
    CODEX_STUB_HOME_FILE="$AI_CODEX_HOMEFILE" \
    CODEX_HOME="$AI_FAKE_CODEX_HOME" \
    HOME="$AI_FAKE_HOME" \
    PYTHONPATH="$AI_SCRIPTS" \
    python3 "$AI_TMPPY/dump_turn.py" "$AI_ROOT" "$AI_IDENTITIES" codex "$AI_CODEX_DUMP" 0 2>&1)"
check "codex: full turn via turns.run_turn completes ok" "OK Hello from stub" "$codex_out"

AI_CODEX_COMBINED="$(cat "$AI_CODEX_DUMP" "$AI_CODEX_ARGV" "$AI_CODEX_HOMEFILE" 2>/dev/null)"
iso_assert_clean "codex" "$AI_CODEX_COMBINED"

# AST-011 regression guard: the recorded (isolated) CODEX_HOME is NOT the
# fake real one, carries no AGENTS.md, but DOES carry the auth.json copy.
AI_CODEX_HOMEFILE_CONTENTS="$(cat "$AI_CODEX_HOMEFILE" 2>/dev/null)"
check_absent "codex: recorded CODEX_HOME is NOT the fake real CODEX_HOME (AST-011 regression guard)" "CODEX_HOME=$AI_FAKE_CODEX_HOME" "$AI_CODEX_HOMEFILE_CONTENTS"
check "codex: isolated CODEX_HOME carries no AGENTS.md even though the fake real one has one (AST-011 regression guard)" "HAS_AGENTS=False" "$AI_CODEX_HOMEFILE_CONTENTS"
check "codex: isolated CODEX_HOME still carries the auth.json copy (login preserved)" "HAS_AUTH=True" "$AI_CODEX_HOMEFILE_CONTENTS"

# ---------------------------------------------------------- (b2) claude, clean
AI_CLAUDE_ARGV="$(mktemp)"
AI_CLAUDE_DUMP="$(mktemp)"
claude_out="$(PATH="$AI_STUB_CLAUDE:$PATH" \
    CLAUDE_STUB_MODE=ok \
    CLAUDE_STUB_ARGV_FILE="$AI_CLAUDE_ARGV" \
    HOME="$AI_FAKE_HOME" \
    PYTHONPATH="$AI_SCRIPTS" \
    python3 "$AI_TMPPY/dump_turn.py" "$AI_ROOT" "$AI_IDENTITIES" claude "$AI_CLAUDE_DUMP" 0 2>&1)"
check "claude: full turn via turns.run_turn completes ok" "OK Hello from stub" "$claude_out"

AI_CLAUDE_COMBINED="$(cat "$AI_CLAUDE_DUMP" "$AI_CLAUDE_ARGV" 2>/dev/null)"
iso_assert_clean "claude" "$AI_CLAUDE_COMBINED"

# AST-012 regression guard: claude has no env-home isolation mechanism (see
# claude.py's own docstring) -- its isolation is entirely argv flags plus an
# isolated cwd, so the part-(c) check for claude is flag-presence in the
# recorded argv, not an env-home dump.
AI_CLAUDE_ARGV_CONTENTS="$(cat "$AI_CLAUDE_ARGV" 2>/dev/null)"
check "claude: --safe-mode is pinned in recorded argv (AST-012 regression guard -- no CLAUDE.md/skills/plugins/hooks/MCP ingestion)" "--safe-mode" "$AI_CLAUDE_ARGV_CONTENTS"
check "claude: --strict-mcp-config is pinned in recorded argv (AST-012 regression guard -- no plugin/skill MCP surface)" "--strict-mcp-config" "$AI_CLAUDE_ARGV_CONTENTS"
check "claude: --tools is pinned in recorded argv (AST-012 regression guard -- harness tool use disabled)" "--tools" "$AI_CLAUDE_ARGV_CONTENTS"
check "claude: --permission-mode plan is pinned in recorded argv" "plan" "$AI_CLAUDE_ARGV_CONTENTS"
check "claude: --no-session-persistence is pinned in recorded argv" "--no-session-persistence" "$AI_CLAUDE_ARGV_CONTENTS"

# ---------------------------------------------------------- (c) contamination-discrimination self-test
# A deliberately-contaminated variant (a canary injected straight into
# persona.systemPrompt) MUST make the canary-absence assertion fail --
# proven here by running the identical grep -qF primitive check_absent uses
# against the contaminated dump and asserting it FINDS the canary. A
# canary-absence test that can never fire is worse than no test at all.
AI_CONTAM_ARGV="$(mktemp)"
AI_CONTAM_DUMP="$(mktemp)"
contam_out="$(PATH="$AI_STUB_CODEX:$PATH" \
    CODEX_STUB_MODE=ok \
    CODEX_STUB_ARGV_FILE="$AI_CONTAM_ARGV" \
    CODEX_HOME="$AI_FAKE_CODEX_HOME" \
    HOME="$AI_FAKE_HOME" \
    PYTHONPATH="$AI_SCRIPTS" \
    python3 "$AI_TMPPY/dump_turn.py" "$AI_ROOT" "$AI_IDENTITIES" codex "$AI_CONTAM_DUMP" 1 2>&1)"
check "contamination fixture: completes ok (systemPrompt deliberately carries a canary)" "OK Hello from stub" "$contam_out"

AI_CONTAM_COMBINED="$(cat "$AI_CONTAM_DUMP" "$AI_CONTAM_ARGV" 2>/dev/null)"
iso_grep_found() { grep -qF -- "$1" <<<"$2"; }
if iso_grep_found "$AI_CANARY_SELFTEST" "$AI_CONTAM_COMBINED"; then
    echo "ok   self-test: canary-absence detector (grep -qF, the exact primitive check_absent uses above) correctly FIRES on a deliberately injected canary -- the codex/claude assertions above are not vacuously passing"
else
    echo "FAIL self-test: canary-absence detector did NOT fire on a deliberately injected canary -- every check_absent assertion above is unproven"
    fails=$((fails + 1))
fi

rm -rf "$AI_ROOT" "$AI_TMPPY" "$AI_FAKE_CODEX_HOME" "$AI_FAKE_HOME" \
    "$AI_CODEX_ARGV" "$AI_CODEX_HOMEFILE" "$AI_CODEX_DUMP" \
    "$AI_CLAUDE_ARGV" "$AI_CLAUDE_DUMP" \
    "$AI_CONTAM_ARGV" "$AI_CONTAM_DUMP"
