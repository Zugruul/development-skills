#!/usr/bin/env bash
# section-capability-enablement.sh -- AST-065: enablement gating end to end
# (SPEC-ASSISTANT.md Sec11.2, Sec17.2, issue #340, docs/design/ast-E6.md).
# Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# New section rather than folding into section-capability-roster.sh or
# section-capability-provisioning.sh: this task's scope spans BOTH the
# already-landed index/roster half (audited, re-confirmed end-to-end here
# under this issue) AND the two genuinely new halves this task adds
# (execution-time refusal, provisioning-override merge) -- kept isolated
# for a reviewable diff, mirroring section-capability-invoke-mcp.sh's
# precedent. Flagged per house practice.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant.capability_index enablement gating (AST-065: SPEC-ASSISTANT.md Sec11.2/Sec17.2) =="

CE_SCRIPTS="$PLUGIN/scripts"
CE_ARGVECHO_BIN="$FIX/stub-argv-echo"
CE_MCP_BIN="$FIX/stub-mcp-server"
CE_PROVCHECK_BIN="$FIX/stub-provisioning-check"

# ce_run <python-body-file> -- scripts/ on PYTHONPATH, no stub PATH (most
# cases here are pure-library, no subprocess).
ce_run() {
    local body="$1"
    PYTHONPATH="$CE_SCRIPTS" python3 "$body"
}

CE_TMPPY="$(mktemp -d)"

# ------------------------------------------------------------------------
echo "-- unit: is_enabled -- the exact Sec11.2 rule, extracted and shared --"
cat >"$CE_TMPPY/is_enabled.py" <<'PYEOF'
from assistant import capability_index as ci

cases = [
    ("enabled_true", {"capabilities": {"x": {"enabled": True}}}, True),
    ("enabled_false", {"capabilities": {"x": {"enabled": False}}}, False),
    ("unconfigured", {"capabilities": {}}, False),
    ("no_capabilities_key", {}, False),
    ("none_cfg", None, False),
    ("entry_not_dict", {"capabilities": {"x": "yes"}}, False),
    ("enabled_truthy_nonbool", {"capabilities": {"x": {"enabled": 1}}}, False),
    ("enabled_string_true", {"capabilities": {"x": {"enabled": "true"}}}, False),
    ("capabilities_not_dict", {"capabilities": ["x"]}, False),
]
for label, cfg, expected in cases:
    got = ci.is_enabled("x", cfg)
    print(f"{label}: {got == expected}")
PYEOF
out="$(ce_run "$CE_TMPPY/is_enabled.py" 2>&1)"
check "is_enabled: enabled: true reads enabled" "enabled_true: True" "$out"
check "is_enabled: enabled: false reads disabled" "enabled_false: True" "$out"
check "is_enabled: unconfigured capability reads disabled (default-deny)" "unconfigured: True" "$out"
check "is_enabled: no capabilities key at all reads disabled" "no_capabilities_key: True" "$out"
check "is_enabled: assistant_cfg=None reads disabled, never crashes" "none_cfg: True" "$out"
check "is_enabled: a non-mapping entry reads disabled" "entry_not_dict: True" "$out"
check "is_enabled: a truthy non-bool enabled (1) reads disabled -- must be literally True" \
    "enabled_truthy_nonbool: True" "$out"
check "is_enabled: the string 'true' reads disabled -- must be the bool True" "enabled_string_true: True" "$out"
check "is_enabled: capabilities itself not a mapping reads disabled, never crashes" \
    "capabilities_not_dict: True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_capability -- a DISABLED capability is refused before anything spawns (Sec17.2) --"
CE_CALL_LOG="$(mktemp -u)"
cat >"$CE_TMPPY/disabled_refused.py" <<'PYEOF'
import collections
from assistant import capability_index as ci

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[], invoke={"exec": ["argvecho", "--x=1"]})
cfg = {"capabilities": {"weather": {"enabled": False}}}

try:
    ci.invoke_capability("weather", cap, {}, cfg)
    print("RAISED", False)
except ci.CapabilityDisabledError as e:
    msg = str(e)
    print("RAISED", True)
    print("NAMES_CAPABILITY", "weather" in msg)
    print("MENTIONS_DISABLED", "disabled" in msg.lower())
PYEOF
out="$(PATH="$CE_ARGVECHO_BIN:$PATH" ARGVECHO_CALL_LOG="$CE_CALL_LOG" ce_run "$CE_TMPPY/disabled_refused.py" 2>&1)"
check "invoke_capability: a disabled capability raises CapabilityDisabledError" "RAISED True" "$out"
check "invoke_capability: the error names the capability" "NAMES_CAPABILITY True" "$out"
check "invoke_capability: the error says it's disabled" "MENTIONS_DISABLED True" "$out"
if [[ -f "$CE_CALL_LOG" ]]; then
    echo "FAIL invoke_capability: a disabled capability must never spawn a subprocess (call-log file was created)"
    fails=$((fails + 1))
else
    echo "ok   invoke_capability: a disabled capability never spawns a subprocess (no call-log file created)"
fi
rm -f "$CE_CALL_LOG"

echo "-- unit: invoke_capability -- an UNCONFIGURED capability (never in project.yaml at all) is also refused --"
cat >"$CE_TMPPY/unconfigured_refused.py" <<'PYEOF'
import collections
from assistant import capability_index as ci

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[], invoke={"exec": ["argvecho"]})
cfg = {"capabilities": {}}
try:
    ci.invoke_capability("weather", cap, {}, cfg)
    print("RAISED", False)
except ci.CapabilityDisabledError:
    print("RAISED", True)
PYEOF
out="$(PATH="$CE_ARGVECHO_BIN:$PATH" ce_run "$CE_TMPPY/unconfigured_refused.py" 2>&1)"
check "invoke_capability: an unconfigured capability (default-deny) is refused" "RAISED True" "$out"

# ------------------------------------------------------------------------
echo "-- unit: invoke_capability -- an ENABLED capability with an exec invoke dispatches to adapters.invoke_argv (positive control) --"
cat >"$CE_TMPPY/enabled_exec.py" <<'PYEOF'
import collections
from assistant import capability_index as ci

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"exec": ["argvecho", "--city={city}"], "params": {"city": {"type": "string"}}})
cfg = {"capabilities": {"weather": {"enabled": True}}}

result = ci.invoke_capability("weather", cap, {"city": "Rome"}, cfg)
print("RETURNCODE", result.returncode)
print("ARGV", result.argv)
PYEOF
out="$(PATH="$CE_ARGVECHO_BIN:$PATH" ce_run "$CE_TMPPY/enabled_exec.py" 2>&1)"
check "invoke_capability: enabled + exec invoke actually spawns and succeeds" "RETURNCODE 0" "$out"
check "invoke_capability: dispatches to invoke_argv (argv is the substituted exec array)" \
    "ARGV ['argvecho', '--city=Rome']" "$out"

echo "-- unit: invoke_capability -- an ENABLED capability with an mcp invoke dispatches to adapters.invoke_mcp (positive control) --"
cat >"$CE_TMPPY/enabled_mcp.py" <<'PYEOF'
import collections
from assistant import capability_index as ci

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})
cfg = {"capabilities": {"weather": {"enabled": True}}}

result = ci.invoke_capability("weather", cap, {}, cfg)
print("RESULT", result.result)
PYEOF
out="$(PATH="$CE_MCP_BIN:$PATH" ce_run "$CE_TMPPY/enabled_mcp.py" 2>&1)"
check "invoke_capability: enabled + mcp invoke dispatches to invoke_mcp and succeeds" \
    "RESULT {'echoedTool': 'weather', 'echoedArguments': {}}" "$out"

echo "-- unit: invoke_capability -- a disabled capability with an mcp invoke is ALSO refused before spawning --"
CE_MCP_CALL_LOG="$(mktemp -u)"
cat >"$CE_TMPPY/disabled_mcp.py" <<'PYEOF'
import collections
from assistant import capability_index as ci

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
cap = Capability(version=1, provisioning={}, permissions=[],
                  invoke={"mcp": {"server": ["mcpserver"], "tool": "weather"}})
cfg = {"capabilities": {"weather": {"enabled": False}}}
try:
    ci.invoke_capability("weather", cap, {}, cfg)
    print("RAISED", False)
except ci.CapabilityDisabledError:
    print("RAISED", True)
PYEOF
out="$(PATH="$CE_MCP_BIN:$PATH" MCP_CALL_LOG="$CE_MCP_CALL_LOG" ce_run "$CE_TMPPY/disabled_mcp.py" 2>&1)"
check "invoke_capability: a disabled mcp-flavored capability raises CapabilityDisabledError" "RAISED True" "$out"
if [[ -f "$CE_MCP_CALL_LOG" ]]; then
    echo "FAIL invoke_capability: a disabled mcp capability must never spawn the server (call-log file was created)"
    fails=$((fails + 1))
else
    echo "ok   invoke_capability: a disabled mcp capability never spawns the server (no call-log file created)"
fi
rm -f "$CE_MCP_CALL_LOG"

# ------------------------------------------------------------------------
echo "-- unit: _merge_provisioning_override -- field-level merge, malformed keys ignored per-key --"
cat >"$CE_TMPPY/merge.py" <<'PYEOF'
from assistant import capability_index as ci

base = {"check": ["provcheck"], "ttlSeconds": 60}

print("NO_OVERRIDE", ci._merge_provisioning_override(base, None))
print("EMPTY_OVERRIDE", ci._merge_provisioning_override(base, {}))
print("CHECK_OVERRIDE", ci._merge_provisioning_override(base, {"check": ["provcheck", "--v2"]}))
print("TTL_OVERRIDE", ci._merge_provisioning_override(base, {"ttlSeconds": 5}))
print("BOTH_OVERRIDE", ci._merge_provisioning_override(base, {"check": ["x"], "ttlSeconds": 5}))
print("NON_DICT_OVERRIDE", ci._merge_provisioning_override(base, ["not", "a", "dict"]))
print("CHECK_EMPTY_LIST_IGNORED", ci._merge_provisioning_override(base, {"check": []}))
print("CHECK_NON_LIST_IGNORED", ci._merge_provisioning_override(base, {"check": "provcheck"}))
print("CHECK_NON_STRING_ELEMENT_IGNORED", ci._merge_provisioning_override(base, {"check": ["ok", 5]}))
print("TTL_BOOL_IGNORED", ci._merge_provisioning_override(base, {"ttlSeconds": True}))
print("TTL_NON_INT_IGNORED", ci._merge_provisioning_override(base, {"ttlSeconds": "60"}))
print("BASE_UNMUTATED", base)
PYEOF
out="$(ce_run "$CE_TMPPY/merge.py" 2>&1)"
check "_merge_provisioning_override: override=None -> unchanged base" \
    "NO_OVERRIDE {'check': ['provcheck'], 'ttlSeconds': 60}" "$out"
check "_merge_provisioning_override: override={} -> unchanged base" \
    "EMPTY_OVERRIDE {'check': ['provcheck'], 'ttlSeconds': 60}" "$out"
check "_merge_provisioning_override: check override replaces check, ttlSeconds stays the shipped default" \
    "CHECK_OVERRIDE {'check': ['provcheck', '--v2'], 'ttlSeconds': 60}" "$out"
check "_merge_provisioning_override: ttlSeconds override replaces ttlSeconds, check stays the shipped default" \
    "TTL_OVERRIDE {'check': ['provcheck'], 'ttlSeconds': 5}" "$out"
check "_merge_provisioning_override: both keys overridden together" \
    "BOTH_OVERRIDE {'check': ['x'], 'ttlSeconds': 5}" "$out"
check "_merge_provisioning_override: a non-mapping override is ignored wholesale" \
    "NON_DICT_OVERRIDE {'check': ['provcheck'], 'ttlSeconds': 60}" "$out"
check "_merge_provisioning_override: an empty-list check override is ignored, shipped default wins" \
    "CHECK_EMPTY_LIST_IGNORED {'check': ['provcheck'], 'ttlSeconds': 60}" "$out"
check "_merge_provisioning_override: a non-list check override is ignored" \
    "CHECK_NON_LIST_IGNORED {'check': ['provcheck'], 'ttlSeconds': 60}" "$out"
check "_merge_provisioning_override: a check override with a non-string element is ignored" \
    "CHECK_NON_STRING_ELEMENT_IGNORED {'check': ['provcheck'], 'ttlSeconds': 60}" "$out"
check "_merge_provisioning_override: a bool ttlSeconds override is ignored (bool-before-int-guard)" \
    "TTL_BOOL_IGNORED {'check': ['provcheck'], 'ttlSeconds': 60}" "$out"
check "_merge_provisioning_override: a non-int ttlSeconds override is ignored" \
    "TTL_NON_INT_IGNORED {'check': ['provcheck'], 'ttlSeconds': 60}" "$out"
check "_merge_provisioning_override: the base provisioning dict is never mutated in place" \
    "BASE_UNMUTATED {'check': ['provcheck'], 'ttlSeconds': 60}" "$out"

# ------------------------------------------------------------------------
echo "-- unit: compile_index -- an ENABLED capability's project.yaml provisioning override reaches the checker (localizes defaults) --"
cat >"$CE_TMPPY/compile_override.py" <<'PYEOF'
import os, sys, tempfile
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="ce-override-")
skills_root = os.path.join(root, "skills")
d = os.path.join(skills_root, "weather")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "capability.yaml"), "w") as fh:
    fh.write("version: 1\nprovisioning:\n    check: [\"provcheck\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"provcheck\"]\n")

seen = []
def spy_checker(name, capability, skill_dir):
    seen.append((name, capability.provisioning))
    return True, None

cfg = {"capabilities": {"weather": {
    "enabled": True,
    "provisioning": {"check": ["provcheck", "--localized"], "ttlSeconds": 5},
}}}
ci.compile_index(skills_root, cfg, provisioning_checker=spy_checker, embed_fn=lambda texts: None)
print("N_CALLS", len(seen))
print("SEEN_PROVISIONING", seen[0][1] if seen else None)
PYEOF
out="$(ce_run "$CE_TMPPY/compile_override.py" 2>&1)"
check "compile_index: the provisioning checker is called exactly once" "N_CALLS 1" "$out"
check "compile_index: the checker receives the OVERRIDDEN check argv, not the skill's shipped default" \
    "SEEN_PROVISIONING {'check': ['provcheck', '--localized'], 'ttlSeconds': 5}" "$out"

echo "-- unit: compile_index -- an ENABLED capability with NO override still gets the skill's shipped defaults verbatim --"
cat >"$CE_TMPPY/compile_no_override.py" <<'PYEOF'
import os, sys, tempfile
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="ce-no-override-")
skills_root = os.path.join(root, "skills")
d = os.path.join(skills_root, "weather")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "capability.yaml"), "w") as fh:
    fh.write("version: 1\nprovisioning:\n    check: [\"provcheck\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"provcheck\"]\n")

seen = []
def spy_checker(name, capability, skill_dir):
    seen.append(capability.provisioning)
    return True, None

cfg = {"capabilities": {"weather": {"enabled": True}}}
ci.compile_index(skills_root, cfg, provisioning_checker=spy_checker, embed_fn=lambda texts: None)
print("SEEN_PROVISIONING", seen[0] if seen else None)
PYEOF
out="$(ce_run "$CE_TMPPY/compile_no_override.py" 2>&1)"
check "compile_index: with no override, the checker receives the skill's shipped defaults verbatim" \
    "SEEN_PROVISIONING {'check': ['provcheck'], 'ttlSeconds': 60}" "$out"

echo "-- unit: compile_index -- a DISABLED capability's provisioning override is never even read (still invisible, Sec11.2) --"
CE_DISABLED_CALL_LOG="$(mktemp -u)"
cat >"$CE_TMPPY/compile_disabled_override.py" <<'PYEOF'
import os, sys, tempfile
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="ce-disabled-override-")
skills_root = os.path.join(root, "skills")
d = os.path.join(skills_root, "weather")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "capability.yaml"), "w") as fh:
    fh.write("version: 1\nprovisioning:\n    check: [\"provcheck\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"provcheck\"]\n")

def spy_checker(name, capability, skill_dir):
    raise AssertionError("provisioning_checker must never be called for a disabled capability")

cfg = {"capabilities": {"weather": {
    "enabled": False,
    "provisioning": {"check": ["provcheck", "--localized"], "ttlSeconds": 5},
}}}
index = ci.compile_index(skills_root, cfg, provisioning_checker=spy_checker, embed_fn=lambda texts: None)
print("N_ENTRIES", len(index.entries))
print("NO_CRASH", True)
PYEOF
out="$(PATH="$CE_PROVCHECK_BIN:$PATH" PROVCHECK_CALL_LOG="$CE_DISABLED_CALL_LOG" ce_run "$CE_TMPPY/compile_disabled_override.py" 2>&1)"
check "compile_index: a disabled capability's override never triggers a checker call (index compile doesn't crash either)" \
    "NO_CRASH True" "$out"
check "compile_index: a disabled capability still yields zero index entries" "N_ENTRIES 0" "$out"

echo "-- unit: compile_index (end-to-end, real checker) -- a provisioning override actually changes real check behavior --"
out="$(SCRIPTS_DIR="$CE_SCRIPTS" PATH="$CE_PROVCHECK_BIN:$PATH" PROVCHECK_MODE=ok python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import capability_index as ci

root = tempfile.mkdtemp(prefix="ce-real-override-")
skills_root = os.path.join(root, "skills")
d = os.path.join(skills_root, "weather")
os.makedirs(d, exist_ok=True)
with open(os.path.join(d, "capability.yaml"), "w") as fh:
    # Shipped default check genuinely PASSES (PROVCHECK_MODE=ok on PATH).
    fh.write("version: 1\nprovisioning:\n    check: [\"provcheck\"]\n    ttlSeconds: 60\n"
              "permissions: []\ninvoke:\n    exec: [\"provcheck\"]\n")

cfg = {"capabilities": {"weather": {
    "enabled": True,
    # Override points at a binary that does not exist -- if the override
    # is genuinely wired into the real checker, this capability must come
    # back UNPROVISIONED despite the shipped default being a pass.
    "provisioning": {"check": ["definitely-not-a-real-binary-for-override-test"]},
}}}
index = ci.compile_index(skills_root, cfg, embed_fn=lambda texts: None)
e = index.entries[0]
print("PROVISIONED_OK", e.provisioned_ok)
print("REASON_NAMES_OVERRIDE_BINARY", "definitely-not-a-real-binary-for-override-test" in (e.unavailable_reason or ""))
PY
)"
check "compile_index (real checker): the override actually changes real behavior -- the shipped default would have passed" \
    "PROVISIONED_OK False" "$out"
check "compile_index (real checker): the failure reason names the OVERRIDE binary, not the shipped default" \
    "REASON_NAMES_OVERRIDE_BINARY True" "$out"

# ------------------------------------------------------------------------
echo "-- end-to-end audit: index -> roster -> rendered prompt -- a disabled skill is absent from ALL THREE, even against a strongly-matching query (Sec11.2) --"
cat >"$CE_TMPPY/e2e_absence.py" <<'PYEOF'
import os, sys, tempfile
from assistant import capability_index as ci
from assistant import turns

root = tempfile.mkdtemp(prefix="ce-e2e-")
skills_root = os.path.join(root, "skills")

def write_skill(name, desc):
    d = os.path.join(skills_root, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "capability.yaml"), "w") as fh:
        fh.write("version: 1\nprovisioning:\n    check: [\"true\"]\n    ttlSeconds: 60\n"
                  "permissions: []\ninvoke:\n    exec: [\"x\"]\n")
    with open(os.path.join(d, "SKILL.md"), "w") as fh:
        fh.write(f"---\nname: {name}\ndescription: {desc}\n---\nbody\n")

# BOTH skills carry the SAME strongly-matching description/keywords, so
# any absence of the disabled one is provably due to enablement gating,
# never low relevance.
write_skill("weather-enabled", "forecast rainfall temperature lookup service")
write_skill("weather-disabled", "forecast rainfall temperature lookup service")

cfg = {"capabilities": {
    "weather-enabled": {"enabled": True},
    "weather-disabled": {"enabled": False},
}}
index = ci.compile_index(skills_root, cfg, embed_fn=lambda texts: None)
print("INDEX_NAMES", sorted(e.name for e in index.entries))

query = ci.embed_query("forecast rainfall temperature lookup service", embed_fn=lambda texts: None)
roster = ci.roster_for_turn(index, query, 5)
print("ROSTER_IS_LIST", isinstance(roster, list))
print("ROSTER_NAMES", sorted(e.name for e in roster))

# Mirror engine.py's _roster_provider_for's exact CapabilityIndexEntry ->
# dict mapping so this exercises the SAME shape turns._render_roster_entries
# renders in production.
roster_dicts = [
    {"name": e.name, "one-liner": e.one_liner, "available": e.provisioned_ok, "reason": e.unavailable_reason}
    for e in roster
]
rendered = "\n".join(turns._render_roster_entries(roster_dicts))
print("PROMPT_HAS_ENABLED_NAME", "weather-enabled" in rendered)
print("PROMPT_HAS_DISABLED_NAME", "weather-disabled" in rendered)
PYEOF
out="$(ce_run "$CE_TMPPY/e2e_absence.py" 2>&1)"
check "end-to-end: index -- only the enabled skill compiles" "INDEX_NAMES ['weather-enabled']" "$out"
check "end-to-end: roster -- a plain list (unambiguous, only one real candidate)" "ROSTER_IS_LIST True" "$out"
check "end-to-end: roster -- only the enabled skill is ever a candidate" "ROSTER_NAMES ['weather-enabled']" "$out"
check "end-to-end: rendered prompt -- the enabled skill's name IS present" "PROMPT_HAS_ENABLED_NAME True" "$out"
check "end-to-end: rendered prompt -- the disabled skill's name is NEVER present, despite matching just as strongly" \
    "PROMPT_HAS_DISABLED_NAME False" "$out"
