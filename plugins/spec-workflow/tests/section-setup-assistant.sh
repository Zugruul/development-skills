#!/usr/bin/env bash
# section-setup-assistant.sh -- AST-005: /setup-assistant scaffold + settings
# editor (SPEC-ASSISTANT.md §6.4, §6.7, §11.9; §6.3 touchpoint). Sourced by
# run-tests.sh; do not run standalone.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== setup-assistant (AST-005: scaffold + settings editor, SPEC-ASSISTANT.md §6.4/§6.7/§11.9) =="

SA_SCRIPT="$PLUGIN/scripts/setup-assistant.sh"
SA_CONFIG="$PLUGIN/scripts/config.py"
SA_MARKER='# neural-view discovery marker — repos with this file are included in the aggregated neural view'

# sa_get <root> <dot.path> -- prints the resolved assistant.* value via
# config.py's own `get` verb (never re-parses the raw YAML text by hand, so
# these assertions can't be fooled by grep's multi-line -F alternation
# semantics on a pattern containing an embedded newline).
sa_get() { python3 "$SA_CONFIG" "$1" get "$2" 2>/dev/null; }

# --- fresh scaffold ----------------------------------------------------------
sa_d="$(mktemp -d)"
sa_out="$(bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis 2>&1)"
sa_rc=$?
check_rc "scaffold: exits 0 on a fresh repo" 0 "$sa_rc"
check "scaffold: prints changed" "changed" "$sa_out"

[[ -f "$sa_d/.claude/.neural-network" ]] && r=yes || r=no
check "scaffold: creates .claude/.neural-network" "yes" "$r"
sa_marker_content="$(cat "$sa_d/.claude/.neural-network" 2>/dev/null)"
check "scaffold: marker content matches §6.2 shipped marker" "$SA_MARKER" "$sa_marker_content"

[[ -f "$sa_d/.claude/project.yaml" ]] && r=yes || r=no
check "scaffold: creates .claude/project.yaml" "yes" "$r"
sa_yaml="$(cat "$sa_d/.claude/project.yaml" 2>/dev/null)"
check "scaffold: project.yaml has assistant: section" "assistant:" "$sa_yaml"
check "scaffold: names uses --name jarvis" 'names: ["jarvis"]' "$sa_yaml"
check "scaffold: llm.provider defaults to claude" 'provider: "claude"' "$sa_yaml"
check "scaffold: claude-code capability enabled" "claude-code:" "$sa_yaml"

[[ -d "$sa_d/.claude/identities/assistant/brain/notes" ]] && r=yes || r=no
check "scaffold: creates brain notes/ dir" "yes" "$r"

[[ -f "$sa_d/AGENTS.md" ]] && r=yes || r=no
check "scaffold: creates persona AGENTS.md" "yes" "$r"
sa_agents="$(cat "$sa_d/AGENTS.md" 2>/dev/null)"
check "scaffold: AGENTS.md has GENERATED skills marker (start)" \
    "<!-- >>> spec-workflow generated: enabled skills" "$sa_agents"
check "scaffold: AGENTS.md has GENERATED skills marker (end)" \
    "<!-- <<< spec-workflow generated: enabled skills" "$sa_agents"
check "scaffold: AGENTS.md lists the enabled claude-code capability" "- claude-code" "$sa_agents"
check_absent "scaffold: AGENTS.md does not list the disabled codex capability" "- codex" "$sa_agents"

[[ -f "$sa_d/.gitignore" ]] && r=yes || r=no
check "scaffold: writes .gitignore" "yes" "$r"
sa_gi="$(cat "$sa_d/.gitignore" 2>/dev/null)"
check "scaffold: .gitignore ignores .claude/assistant/ local state" ".claude/assistant/" "$sa_gi"
check "scaffold: .gitignore ignores the materialized whisper-sidecar base capability (issue #447, plugin-owned/regenerable)" \
    ".claude/skills/whisper-sidecar/" "$sa_gi"

# --- no engine code copied into the scaffolded tree (§6.7) --------------------
# Refined (issue #447, deliberate, headlined contract-invariant change --
# not a loosening): §6.7's actual wording is "the assistant repo SHALL
# contain no ENGINE code", not "no .py files" -- the original blanket
# find -name '*.py' check was a sound PROXY for that invariant only
# because, before #447, nothing but engine code was ever .py. #447 ships
# whisper-sidecar (issue #424) as a base capability materialized into
# .claude/skills/whisper-sidecar/, and that capability's own invoke
# script (whisper_sidecar.py) IS legitimately .py -- it is CAPABILITY
# code (§11.1: a skill's own SKILL.md/capability.yaml/invoke script),
# executed exclusively as a sandboxed, argv-isolated, timeout-bounded
# subprocess via adapters.invoke_cli, never imported into or run as part
# of the assistant engine process itself. This is functionally identical
# to a human hand-authoring their own skill directly under
# .claude/skills/ (already implicitly allowed by §11.1, which draws no
# distinction between plugin-sourced and human-authored skill code).
#
# Round-2 correction: the TWO checks below are NOT "stricter than the
# original" -- set-wise they are strictly WEAKER (they exempt .py inside
# .claude/skills/, which the blanket check forbade). That's the intended
# carve-out, not an accident, and claiming otherwise overstated it. The
# true, honest framing: these checks are better ALIGNED with §6.7's own
# wording ("no engine code") than the blanket proxy was -- trading
# accidental over-strictness (the old check also rejected legitimate
# capability code) for accuracy (checking for the actual thing §6.7
# forbids: engine modules, by name, anywhere), while check 2 does add ONE
# genuinely new capability the old check never had: catching an engine
# module NAME leaking INSIDE .claude/skills/, a location the blanket
# check never distinguished at all.
#
# Stronger argument, also worth stating plainly: the materialized
# .claude/skills/whisper-sidecar/ is GITIGNORED (local-state.manifest,
# never committed) -- so the assistant REPOSITORY, i.e. what §6.7/§17.4
# actually govern (committed content), still contains zero .py either
# way. whisper_sidecar.py is regenerable local state materialized by
# `/setup-assistant`, not repo content a human or git ever sees checked
# in -- §6.7's invariant holds at the level it actually operates on.
#   1. No .py file anywhere OUTSIDE .claude/skills/ -- capability code is
#      only ever legitimate INSIDE a skill's own directory.
#   2. No file NAMED after a real engine module (derived from the
#      PLUGIN's own scripts/assistant/*.py listing, never hand-enumerated
#      -- see below) appears ANYWHERE in the tree, INCLUDING inside
#      .claude/skills/.
sa_engine_hits="$(find "$sa_d" -name '*.py' -not -path "$sa_d/.claude/skills/*" 2>/dev/null | wc -l | tr -d ' ')"
check "scaffold: no .py files outside .claude/skills/ (no engine code, §6.7)" "0" "$sa_engine_hits"

# Derived, not hand-maintained (issue #447 round 2): the set of real
# engine module NAMES is a FACT about the plugin's own scripts/assistant/
# directory, so it is read from there directly rather than copy-pasted --
# self-maintaining as the engine grows, never silently drifts out of sync
# the way a hand-enumerated list could. Contrast with BASE_CAPABILITIES in
# setup.py, which SHOULD stay hand-maintained: that list encodes a
# reviewed DECISION (which in-plugin skills get materialized into every
# assistant repo), not a fact derivable from the filesystem.
# bash 3.2 compatible (avoids the bash-4-only array-read builtin -- macOS stock bash).
sa_engine_mods=()
while IFS= read -r sa_mod_line; do
    [[ -n "$sa_mod_line" ]] && sa_engine_mods+=("$sa_mod_line")
done < <(
    # shellcheck disable=SC2011  # engine module filenames are plain ASCII
    # (adapters.py, engine.py, ...) -- no spaces/globs/newlines possible, so
    # ls|xargs is safe here despite the general non-alphanumeric-filename caveat.
    ls "$PLUGIN/scripts/assistant/"*.py 2>/dev/null | xargs -n1 basename
)

# Vacuity guard (round-2 advisory, same absence-proof-needs-positive-control
# class the suite keeps hitting): an empty derived list would make the loop
# below iterate zero times and report "0 hits" -- a green check that tested
# NOTHING, if the glob ever misses (wrong PLUGIN path, scripts/assistant/
# renamed, etc.). Fail loudly and specifically instead of passing vacuously.
if [[ ${#sa_engine_mods[@]} -eq 0 ]]; then
    check "scaffold: engine-module list derivation is non-empty (positive control on the absence-proof below)" \
        "non-empty" "EMPTY -- glob 'scripts/assistant/*.py' matched nothing, check \$PLUGIN"
else
    check "scaffold: engine-module list derivation is non-empty (positive control on the absence-proof below)" \
        "non-empty" "non-empty (${#sa_engine_mods[@]} modules)"
fi

sa_engine_module_hits=0
# "${arr[@]}" on an EMPTY array is an unbound-variable error under `set -u`
# in bash < 4.4 (macOS stock bash 3.2) -- guard the iteration explicitly
# rather than relying on the array expanding to nothing.
if [[ ${#sa_engine_mods[@]} -gt 0 ]]; then
    for sa_mod in "${sa_engine_mods[@]}"; do
        [[ -z "$sa_mod" ]] && continue
        sa_hit="$(find "$sa_d" -name "$sa_mod" 2>/dev/null | wc -l | tr -d ' ')"
        sa_engine_module_hits=$((sa_engine_module_hits + sa_hit))
    done
fi
check "scaffold: no file named after a real assistant engine module appears anywhere, including inside .claude/skills/ (§6.7)" \
    "0" "$sa_engine_module_hits"

# --- base capabilities (issue #447, §11.1) -------------------------------------
[[ -f "$sa_d/.claude/skills/whisper-sidecar/capability.yaml" ]] && r=yes || r=no
check "scaffold: materializes the whisper-sidecar base capability's capability.yaml" "yes" "$r"
[[ -f "$sa_d/.claude/skills/whisper-sidecar/SKILL.md" ]] && r=yes || r=no
check "scaffold: materializes the whisper-sidecar base capability's SKILL.md" "yes" "$r"
[[ -f "$sa_d/.claude/skills/whisper-sidecar/whisper_sidecar.py" ]] && r=yes || r=no
check "scaffold: materializes the whisper-sidecar base capability's whisper_sidecar.py" "yes" "$r"
sa_ws_content="$(cat "$sa_d/.claude/skills/whisper-sidecar/capability.yaml" 2>/dev/null)"
sa_ws_src_content="$(cat "$PLUGIN/skills/whisper-sidecar/capability.yaml" 2>/dev/null)"
check "scaffold: the materialized capability.yaml matches the plugin's shipped source byte-for-byte" \
    "$sa_ws_src_content" "$sa_ws_content"

[[ -x "$sa_d/.claude/skills/whisper-sidecar/whisper_sidecar.py" ]] && r=yes || r=no
check "scaffold: the materialized whisper_sidecar.py keeps its executable bit" "yes" "$r"

sa_ws_cfg="$(sa_get "$sa_d" "assistant.capabilities.whisper-sidecar.enabled")"
check "scaffold: whisper-sidecar is NOT auto-enabled (§11.2 default-deny) -- materializing files never implies enabled: true" \
    "" "$sa_ws_cfg"

# a human-authored skill dir alongside the base capability is left alone
mkdir -p "$sa_d/.claude/skills/my-custom-skill"
printf 'hand-authored, not a base capability\n' >"$sa_d/.claude/skills/my-custom-skill/NOTES.md"
bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis >/dev/null 2>&1
[[ -f "$sa_d/.claude/skills/my-custom-skill/NOTES.md" ]] && r=yes || r=no
check "scaffold: a human-authored skill dir alongside a base capability is left untouched" "yes" "$r"
sa_custom_content="$(cat "$sa_d/.claude/skills/my-custom-skill/NOTES.md" 2>/dev/null)"
check "scaffold: the human-authored skill's content is unchanged" "hand-authored, not a base capability" "$sa_custom_content"

# end-to-end: once a human enables it (setup.py enable-capability, already
# landed), the materialized whisper-sidecar capability is ACTUALLY
# discoverable by the real engine machinery, not just present on disk.
python3 "$PLUGIN/scripts/assistant/setup.py" "$sa_d" enable-capability whisper-sidecar >/dev/null 2>&1
sa_e2e_out="$(PYTHONPATH="$PLUGIN/scripts" python3 - <<PY
import sys
sys.path.insert(0, "$PLUGIN/scripts")
from assistant import capability_index as ci

skills_root = "$sa_d/.claude/skills"
cfg = {"capabilities": {"whisper-sidecar": {"enabled": True}}}
index = ci.compile_index(skills_root, cfg, embed_fn=lambda texts: None)
names = [e.name for e in index.entries]
print("IN_INDEX", "whisper-sidecar" in names)
PY
)"
check "end-to-end (issue #447): the scaffolded whisper-sidecar capability is discoverable by compile_index once enabled" \
    "IN_INDEX True" "$sa_e2e_out"

# --- re-run idempotence: byte-identical tree -----------------------------------
sa_snap="$(mktemp -d)"
cp -R "$sa_d/." "$sa_snap/"
bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis >/dev/null 2>&1
if diff -rq "$sa_snap" "$sa_d" >/dev/null 2>&1; then r=IDENTICAL; else r=DIFFER; fi
check "scaffold: re-run is byte-identical (idempotent)" "IDENTICAL" "$r"
rm -rf "$sa_snap"

# a THIRD run (after the tree already stabilized) reports unchanged
sa_out3="$(bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis 2>&1)"
check "scaffold: stabilized re-run reports unchanged" "unchanged" "$sa_out3"

# --- validate: the scaffolded section is valid by construction ----------------
sa_val="$(bash "$SA_SCRIPT" --root "$sa_d" validate 2>&1)"
check "scaffold: scaffolded assistant: section validates" "VALID" "$sa_val"
rm -rf "$sa_d"

# --- bug #377: scaffold's default model must be provider-conditional -----------
# provider openai with no --model must NOT inherit the claude default model
# (that pair validates cleanly per §6.5 but is unservable on the first live
# turn -- the model string is passed verbatim and only checked provider-side).
sa_openai_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_openai_d" scaffold --name jarvis --provider openai >/dev/null 2>&1
sa_openai_model="$(sa_get "$sa_openai_d" assistant.llm.model)"
check "scaffold: --provider openai with no --model defaults to gpt-5.6-sol (#377)" \
    "gpt-5.6-sol" "$sa_openai_model"
rm -rf "$sa_openai_d"

sa_claude_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_claude_d" scaffold --name jarvis --provider claude >/dev/null 2>&1
sa_claude_model="$(sa_get "$sa_claude_d" assistant.llm.model)"
check "scaffold: --provider claude with no --model still defaults to claude-sonnet-5 (#377)" \
    "claude-sonnet-5" "$sa_claude_model"
rm -rf "$sa_claude_d"

sa_explicit_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_explicit_d" scaffold --name jarvis --provider openai --model something-explicit >/dev/null 2>&1
sa_explicit_model="$(sa_get "$sa_explicit_d" assistant.llm.model)"
check "scaffold: an explicit --model always wins over the provider default (#377)" \
    "something-explicit" "$sa_explicit_model"
rm -rf "$sa_explicit_d"

# --- existing-file preservation: unrelated keys + persona prose survive -------
sa_d="$(mktemp -d)"
mkdir -p "$sa_d/.claude"
# shellcheck disable=SC2016  # literal $schema= text in a fixture file, not an expansion
printf '%s\n' \
    '# yaml-language-server: $schema=https://example.invalid/schema.json' \
    'project:' \
    '    name: myproj' \
    'unrelatedTopLevelKey: keep-me' \
    > "$sa_d/.claude/project.yaml"
printf '%s\n' \
    '# My Custom Persona' \
    '' \
    'Hand-written prose before the block.' \
    '' \
    'More hand-written prose after where the block will land.' \
    > "$sa_d/AGENTS.md"
bash "$SA_SCRIPT" --root "$sa_d" scaffold --name custodian >/dev/null 2>&1
sa_yaml2="$(cat "$sa_d/.claude/project.yaml" 2>/dev/null)"
check "preservation: pre-existing project.yaml key 'project:' survives" "project:" "$sa_yaml2"
check "preservation: pre-existing project.yaml key 'name: myproj' survives" "name: myproj" "$sa_yaml2"
check "preservation: unrelated top-level key survives" "unrelatedTopLevelKey: keep-me" "$sa_yaml2"
check "preservation: assistant: section still added" "assistant:" "$sa_yaml2"
sa_agents2="$(cat "$sa_d/AGENTS.md" 2>/dev/null)"
check "preservation: hand-written prose before the block survives" \
    "Hand-written prose before the block." "$sa_agents2"
check "preservation: hand-written prose after the block survives" \
    "More hand-written prose after where the block will land." "$sa_agents2"
check "preservation: generated block appended for a pre-existing AGENTS.md" \
    "<!-- >>> spec-workflow generated: enabled skills" "$sa_agents2"
rm -rf "$sa_d"

# --- generated-AGENTS.md-section regeneration on capability flips -------------
sa_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis >/dev/null 2>&1
bash "$SA_SCRIPT" --root "$sa_d" enable-capability codex >/dev/null 2>&1
sa_agents3="$(cat "$sa_d/AGENTS.md" 2>/dev/null)"
check "regeneration: newly-enabled capability appears in the generated block" "- codex" "$sa_agents3"
check "regeneration: previously-enabled capability still listed" "- claude-code" "$sa_agents3"
bash "$SA_SCRIPT" --root "$sa_d" disable-capability codex >/dev/null 2>&1
sa_agents4="$(cat "$sa_d/AGENTS.md" 2>/dev/null)"
check_absent "regeneration: disabled capability drops out of the generated block" "- codex" "$sa_agents4"
rm -rf "$sa_d"

# --- gitignore idempotence: re-running scaffold does not duplicate the block --
sa_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_d" scaffold >/dev/null 2>&1
sa_gi_count1="$(grep -c '^\.claude/assistant/$' "$sa_d/.gitignore" 2>/dev/null)"
bash "$SA_SCRIPT" --root "$sa_d" scaffold >/dev/null 2>&1
sa_gi_count2="$(grep -c '^\.claude/assistant/$' "$sa_d/.gitignore" 2>/dev/null)"
check "gitignore: exactly one .claude/assistant/ line after first scaffold" "1" "$sa_gi_count1"
check "gitignore: still exactly one .claude/assistant/ line after re-scaffold" "1" "$sa_gi_count2"
rm -rf "$sa_d"

# --- settings editor: set-model, enable/disable capability ---------------------
sa_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_d" scaffold >/dev/null 2>&1

sa_sm="$(bash "$SA_SCRIPT" --root "$sa_d" set-model gpt-5.6-sol 2>&1)"
sa_sm_rc=$?
check_rc "set-model: accepted (opaque string per §6.5)" 0 "$sa_sm_rc"
check "set-model: OK" "OK" "$sa_sm"
check "set-model: model written verbatim" 'model: "gpt-5.6-sol"' "$(cat "$sa_d/.claude/project.yaml")"

sa_ec="$(bash "$SA_SCRIPT" --root "$sa_d" enable-capability codex 2>&1)"
check_rc "enable-capability: codex accepted (claude-code stays enabled too)" 0 $?
check "enable-capability: OK" "OK" "$sa_ec"
check "enable-capability: codex now enabled" "true" "$(sa_get "$sa_d" assistant.capabilities.codex.enabled)"

sa_dc="$(bash "$SA_SCRIPT" --root "$sa_d" disable-capability claude-code 2>&1)"
check_rc "disable-capability: claude-code rejected (provider claude still needs it)" 1 $?
check "disable-capability: REJECTED (provider still claude -> needs claude-code)" "REJECTED" "$sa_dc"
check "disable-capability: rejection reverts the file (claude-code still enabled)" \
    "true" "$(sa_get "$sa_d" assistant.capabilities.claude-code.enabled)"
rm -rf "$sa_d"

# --- settings editor: §6.5-violating flip is rejected AND reverted ------------
sa_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_d" scaffold >/dev/null 2>&1   # provider=claude, codex disabled
cp "$sa_d/.claude/project.yaml" "$sa_d/before.yaml"

sa_bad="$(bash "$SA_SCRIPT" --root "$sa_d" set-provider openai 2>&1)"
sa_bad_rc=$?
check_rc "§6.5 violation: set-provider openai (codex disabled) is rejected" 1 "$sa_bad_rc"
check "§6.5 violation: REJECTED with the specific message" \
    "requires capabilities.codex.enabled: true" "$sa_bad"
cmp -s "$sa_d/before.yaml" "$sa_d/.claude/project.yaml" && r=SAME || r=DIFF
check "§6.5 violation: project.yaml reverted byte-identical on rejection" "SAME" "$r"

# now the legal path: enable codex first, then the same flip succeeds
bash "$SA_SCRIPT" --root "$sa_d" enable-capability codex >/dev/null 2>&1
sa_ok="$(bash "$SA_SCRIPT" --root "$sa_d" set-provider openai 2>&1)"
check_rc "§6.5: set-provider openai succeeds once codex is enabled" 0 $?
check "§6.5: OK" "OK" "$sa_ok"
sa_val2="$(bash "$SA_SCRIPT" --root "$sa_d" validate 2>&1)"
check "§6.5: post-flip section still validates" "VALID" "$sa_val2"
rm -rf "$sa_d"

# --- machine-local default (§6.3 touchpoint) -----------------------------------
sa_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis >/dev/null 2>&1
sa_def_out="$(bash "$SA_SCRIPT" --root "$sa_d" set-default jarvis 2>&1)"
check_rc "set-default: exits 0" 0 $?
case "$sa_def_out" in
    "$sa_d"/.claude/neural-view/*) r=under-local-state ;;
    *) r="WRONG: $sa_def_out" ;;
esac
check "set-default: writes under .claude/neural-view/ (already-gitignored local state)" \
    "under-local-state" "$r"
[[ -f "$sa_d/.claude/neural-view/assistant-default" ]] && r=yes || r=no
check "set-default: default file exists on disk" "yes" "$r"
sa_def_content="$(cat "$sa_d/.claude/neural-view/assistant-default" 2>/dev/null)"
check "set-default: file content is the assistant name" "jarvis" "$sa_def_content"
# NOT written into any tracked file: project.yaml has no `default` key
check_absent "set-default: never written into project.yaml (§6.3: never a tracked file)" \
    "default:" "$(cat "$sa_d/.claude/project.yaml")"
rm -rf "$sa_d"

# --- SKILL.md is script-driven, not prose-only ---------------------------------
SA_SKILL="$PLUGIN/skills/setup-assistant/SKILL.md"
[[ -f "$SA_SKILL" ]] && r=yes || r=no
check "SKILL.md exists" "yes" "$r"
sa_skill_body="$(cat "$SA_SKILL" 2>/dev/null)"
check "SKILL.md invokes setup-assistant.sh scaffold" "setup-assistant.sh" "$sa_skill_body"
check "SKILL.md documents the settings-editor verbs" "set-provider" "$sa_skill_body"
check "SKILL.md documents set-default (§6.3 touchpoint)" "set-default" "$sa_skill_body"
check "SKILL.md documents the persona interview + set-persona verb (#486)" "set-persona" "$sa_skill_body"

# --- docs: both README skills tables mention the new skill ---------------------
check "root README documents setup-assistant" "setup-assistant" "$(cat "$PLUGIN/../../README.md" 2>/dev/null)"
check "plugin README documents setup-assistant" "setup-assistant" "$(cat "$PLUGIN/README.md" 2>/dev/null)"
check "plugin README documents the set-persona verb (#486)" "set-persona" "$(cat "$PLUGIN/README.md" 2>/dev/null)"

# --- review r2 finding 1: concurrent scaffolds never torn-write project.yaml --
# 12 fully-concurrent `scaffold` runs against the SAME fresh root used to
# reproducibly torn-write project.yaml (13 unprotected read-modify-write
# disk cycles per run) into unparseable content. The fix composes all 13
# leaves into ONE in-memory text and writes it once, atomically, under a
# cross-process lock -- assert the survivor parses AND is a valid
# assistant: section, every time.
sa_d="$(mktemp -d)"
sa_conc_pids=()
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis >/dev/null 2>&1 &
    sa_conc_pids+=("$!")
done
for _p in "${sa_conc_pids[@]}"; do wait "$_p"; done

sa_conc_parse="$(python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8").read())
    print("PARSE_OK" if isinstance(d, dict) and isinstance(d.get("assistant"), dict) else "BAD_SHAPE")
except Exception as e:
    print("PARSE_FAIL", e)
' "$sa_d/.claude/project.yaml" 2>&1)"
check "concurrency: project.yaml parses as a mapping after 12 concurrent scaffolds" \
    "PARSE_OK" "$sa_conc_parse"
sa_conc_validate="$(bash "$SA_SCRIPT" --root "$sa_d" validate 2>&1)"
check "concurrency: assistant: section is still VALID after concurrent scaffolds" \
    "VALID" "$sa_conc_validate"

# Round-2 MINOR 4: pin the atomicity claim ensure_base_capabilities/
# _atomic_write_bytes make (issue #447) against the SAME 12-concurrent
# run above, rather than asserting it only in isolation -- 12 processes
# all racing to write the identical whisper-sidecar bytes is exactly the
# scenario the write-to-temp-then-os.replace discipline exists for.
sa_ws_conc="$(cmp -s "$sa_d/.claude/skills/whisper-sidecar/whisper_sidecar.py" \
    "$PLUGIN/skills/whisper-sidecar/whisper_sidecar.py" && echo SAME || echo DIFFER)"
check "concurrency: whisper_sidecar.py is byte-identical to the plugin source after 12 concurrent scaffolds" \
    "SAME" "$sa_ws_conc"
sa_cy_conc="$(cmp -s "$sa_d/.claude/skills/whisper-sidecar/capability.yaml" \
    "$PLUGIN/skills/whisper-sidecar/capability.yaml" && echo SAME || echo DIFFER)"
check "concurrency: capability.yaml is byte-identical to the plugin source after 12 concurrent scaffolds" \
    "SAME" "$sa_cy_conc"
[[ -x "$sa_d/.claude/skills/whisper-sidecar/whisper_sidecar.py" ]] && r=yes || r=no
check "concurrency: whisper_sidecar.py's executable bit survives 12 concurrent scaffolds" "yes" "$r"
sa_stray_tmp="$(find "$sa_d" -name '.setup-assistant-tmp-*' 2>/dev/null | wc -l | tr -d ' ')"
check "concurrency: zero stray .setup-assistant-tmp-* files left behind after 12 concurrent scaffolds" "0" "$sa_stray_tmp"

rm -rf "$sa_d"

# --- review r2 finding 2: pre-existing non-mapping assistant: is refused,
# file left completely untouched (never a partial/invalid insertion) -------
sa_d="$(mktemp -d)"
mkdir -p "$sa_d/.claude"
printf '%s\n' 'assistant: not-a-mapping' 'other: 1' > "$sa_d/.claude/project.yaml"
cp "$sa_d/.claude/project.yaml" "$sa_d/before.yaml"
sa_bad_scaffold="$(bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis 2>&1)"
sa_bad_scaffold_rc=$?
check_rc "finding 2: scaffold onto a non-mapping assistant: exits nonzero" 1 "$sa_bad_scaffold_rc"
check "finding 2: refusal names the specific problem" \
    "assistant: is a str, not a mapping" "$sa_bad_scaffold"
cmp -s "$sa_d/before.yaml" "$sa_d/.claude/project.yaml" && r=UNTOUCHED || r=CHANGED
check "finding 2: project.yaml is byte-identical (never partially inserted)" \
    "UNTOUCHED" "$r"
rm -rf "$sa_d"

# --- review r2 finding 2: a genuinely malformed (unparseable) project.yaml
# produces a clean CLI error, not a raw Python traceback -----------------------
sa_d="$(mktemp -d)"
mkdir -p "$sa_d/.claude"
printf '%s\n' '[this is a list, not a mapping]' > "$sa_d/.claude/project.yaml"
sa_traceback_out="$(bash "$SA_SCRIPT" --root "$sa_d" validate 2>&1)"
sa_traceback_rc=$?
check_rc "finding 2: malformed project.yaml validate exits nonzero" 1 "$sa_traceback_rc"
check "finding 2: clean PREFLIGHT FAIL message, not a traceback" "PREFLIGHT FAIL" "$sa_traceback_out"
check_absent "finding 2: no raw Python traceback leaks to the user" "Traceback (most recent call last)" "$sa_traceback_out"
rm -rf "$sa_d"

# --- review r3: the `scaffold` verb (not just `validate`) hits the SAME
# unparseable-project.yaml path -- _parse_text's yaml.safe_load was raising
# an uncaught yaml.YAMLError there, past _cli()'s ConfigError catch, on a
# code path `validate` above never exercises (scaffold's own leaf-insertion
# loop is what calls _parse_text repeatedly, before ever reaching apply's
# validate_assistant pass). -------------------------------------------------
sa_d="$(mktemp -d)"
mkdir -p "$sa_d/.claude"
# genuinely UNPARSEABLE yaml (stray colons inside a flow sequence) -- a
# parseable-but-wrong-shape fixture would exercise the non-mapping refusal
# path instead and keep passing even with the yaml.YAMLError wrap reverted.
printf 'assistant: [1,2\n  bad: yaml: ::\n' > "$sa_d/.claude/project.yaml"
cp "$sa_d/.claude/project.yaml" "$sa_d/before.yaml"
sa_r3_out="$(bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis 2>&1)"
sa_r3_rc=$?
check_rc "r3: scaffold on unparseable project.yaml exits nonzero" 1 "$sa_r3_rc"
check "r3: scaffold reports a clean PREFLIGHT FAIL, not a traceback" "PREFLIGHT FAIL" "$sa_r3_out"
check_absent "r3: no raw Python traceback leaks from scaffold" "Traceback (most recent call last)" "$sa_r3_out"
cmp -s "$sa_d/before.yaml" "$sa_d/.claude/project.yaml" && r=UNTOUCHED || r=CHANGED
check "r3: project.yaml is byte-identical (never partially written)" "UNTOUCHED" "$r"
rm -rf "$sa_d"

# --- observation: an orphaned GENERATED-END marker (no matching START) is
# dropped as debris instead of surviving forever in AGENTS.md ------------------
sa_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis >/dev/null 2>&1
printf '%s\n' \
    "# jarvis — assistant persona" "" \
    "Some prose." "" \
    "<!-- <<< spec-workflow generated: enabled skills (SPEC-ASSISTANT.md §11.9) -->" \
    "" "More prose." \
    > "$sa_d/AGENTS.md"
bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis >/dev/null 2>&1
sa_orphan_agents="$(cat "$sa_d/AGENTS.md" 2>/dev/null)"
sa_orphan_count="$(grep -c '^<!-- <<< spec-workflow generated: enabled skills' "$sa_d/AGENTS.md" 2>/dev/null)"
check "orphaned END marker: exactly one END delimiter survives (debris dropped)" "1" "$sa_orphan_count"
check "orphaned END marker: prose before it survives" "Some prose." "$sa_orphan_agents"
check "orphaned END marker: prose after it survives" "More prose." "$sa_orphan_agents"
rm -rf "$sa_d"

# --- development-skills#437 regression: gate.sh exports PYTHONPATH=scripts/
# before invoking setup.py. That puts scripts/ in sys.path at position 1 --
# BEHIND sys.path[0] (scripts/assistant/, setup.py's own dir) -- so a naive
# `if _SCRIPTS_DIR not in sys.path` guard sees it already present and skips
# the insert(0, ...) that's supposed to make scripts/ win. Without that,
# `import config as project_config` resolves scripts/assistant/config.py
# (the engine config module, no ConfigError/dig) instead of the intended
# scripts/config.py shared loader, and every setup.py invocation dies with
# an AttributeError -- this was #412's real root cause, deterministic under
# gate.sh's env and invisible under a plain run-tests.sh run (which never
# sets PYTHONPATH itself). Explicitly set PYTHONPATH here to reproduce
# gate.sh's shadowing env for this one check. ------------------------------
sa_d="$(mktemp -d)"
sa_pp_out="$(PYTHONPATH="$PLUGIN/scripts" bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis 2>&1)"
sa_pp_rc=$?
check_rc "#437: scaffold exits 0 under gate.sh's PYTHONPATH=scripts/ env (scripts/ must still win over scripts/assistant/)" 0 "$sa_pp_rc"
check_absent "#437: no AttributeError from the shadowed engine-config module leaks out" "AttributeError" "$sa_pp_out"
[[ -f "$sa_d/.claude/project.yaml" ]] && r=yes || r=no
check "#437: scaffold under PYTHONPATH=scripts/ still creates .claude/project.yaml" "yes" "$r"
rm -rf "$sa_d"

# --- set-persona (task #486): the /setup-assistant persona interview writes
# a real, interview-composed persona into assistant.systemPrompt AND a new
# marker-delimited persona block in AGENTS.md, instead of the bare one-line
# scaffold default. Same snapshot -> surgical edit -> validate_assistant ->
# revert-on-invalid pattern the other settings verbs (set-provider etc.)
# already use, so a rejected write never touches project.yaml. -----------------
sa_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis >/dev/null 2>&1

# review round 1 finding 1: 800 is turns.py's TOKEN budget, not chars -- the
# real runtime char clip is derived, not hardcoded here or in setup.py.
sa_persona_clip="$(PYTHONPATH="$PLUGIN/scripts" python3 -c 'from assistant import turns; print(turns.persona_char_budget())' 2>/dev/null)"
# Vacuity guard: an empty $sa_persona_clip (import/call failure) would make
# every later `check ... "$sa_persona_clip" ...` below pass VACUOUSLY --
# grep -qF matches an empty needle against anything. Fail loudly instead of
# silently testing nothing, same positive-control discipline as the
# engine-module-list guard earlier in this file.
if [[ -z "$sa_persona_clip" ]]; then
    check "set-persona: derived runtime clip resolves to a non-empty value (positive control)" \
        "non-empty" "EMPTY -- turns.persona_char_budget() import/call failed, check PYTHONPATH/\$PLUGIN/scripts"
else
    check "set-persona: derived runtime clip resolves to a non-empty value (positive control)" \
        "non-empty" "non-empty ($sa_persona_clip)"
fi

sa_persona_file="$(mktemp)"
printf '%s\n' \
    'You are Jarvis, the on-call assistant for the acme-widgets repo.' \
    'Domain: help ship the widget API; tone: terse and a little dry.' \
    'Boundaries: never merge a PR or touch prod config on your own.' \
    'Example tasks: triage a failing test, draft a changelog entry, explain a stack trace.' \
    > "$sa_persona_file"

sa_sp_out="$(bash "$SA_SCRIPT" --root "$sa_d" set-persona --file "$sa_persona_file" 2>&1)"
sa_sp_rc=$?
check_rc "set-persona: exits 0 on a valid persona" 0 "$sa_sp_rc"
check "set-persona: prints OK" "OK" "$sa_sp_out"

sa_sp_sysprompt="$(sa_get "$sa_d" assistant.systemPrompt)"
check "set-persona: assistant.systemPrompt contains the composed persona" \
    "Domain: help ship the widget API" "$sa_sp_sysprompt"

sa_sp_agents="$(cat "$sa_d/AGENTS.md" 2>/dev/null)"
check "set-persona: AGENTS.md gains a persona marker block" \
    "spec-workflow generated: persona" "$sa_sp_agents"
check "set-persona: AGENTS.md's persona block contains the composed text" \
    "Boundaries: never merge a PR or touch prod config on your own." "$sa_sp_agents"

# review round 1 finding 2: the bare scaffold-default intro must not survive
# alongside the real persona (two conflicting identities), and the real
# persona must sit ABOVE the generated skills block, never appended at EOF
# below everything.
check_absent "set-persona: the bare scaffold-default intro sentence is gone from AGENTS.md" \
    "the local assistant for this repository's zettel brain" "$sa_sp_agents"
sa_persona_marker_line="$(grep -n 'spec-workflow generated: persona' "$sa_d/AGENTS.md" | head -1 | cut -d: -f1)"
sa_skills_marker_line="$(grep -n 'spec-workflow generated: enabled skills' "$sa_d/AGENTS.md" | head -1 | cut -d: -f1)"
[[ "$sa_persona_marker_line" -lt "$sa_skills_marker_line" ]] && r=ABOVE || r=BELOW
check "set-persona: the persona block sits above the enabled-skills block" "ABOVE" "$r"

# idempotent re-run: identical persona text a second time -> byte-identical tree
sa_sp_snap="$(mktemp -d)"
cp -R "$sa_d/." "$sa_sp_snap/"
sa_sp_out2="$(bash "$SA_SCRIPT" --root "$sa_d" set-persona --file "$sa_persona_file" 2>&1)"
sa_sp_rc2=$?
check_rc "set-persona: re-running with identical text exits 0" 0 "$sa_sp_rc2"
check "set-persona: re-running with identical text still prints OK" "OK" "$sa_sp_out2"
if diff -rq "$sa_sp_snap" "$sa_d" >/dev/null 2>&1; then r=IDENTICAL; else r=DIFFER; fi
check "set-persona: identical re-run leaves the tree byte-identical (idempotent)" "IDENTICAL" "$r"
rm -rf "$sa_sp_snap"

# custom prose the human hand-added outside the markers survives a re-run
printf '\n\n%s\n' "Hand-written note the human added below the generated blocks." >> "$sa_d/AGENTS.md"
bash "$SA_SCRIPT" --root "$sa_d" set-persona --file "$sa_persona_file" >/dev/null 2>&1
sa_sp_agents3="$(cat "$sa_d/AGENTS.md" 2>/dev/null)"
check "set-persona: hand-written prose outside the markers survives a re-run" \
    "Hand-written note the human added below the generated blocks." "$sa_sp_agents3"

# review round 1 finding 3: persona text containing a line matching one of
# AGENTS.md's own reserved marker lines is rejected outright -- both files
# left byte-identical, never silently corrupting the generated-block
# scanner on a later scaffold/set-persona re-run.
cp "$sa_d/.claude/project.yaml" "$sa_d/before-marker.yaml"
cp "$sa_d/AGENTS.md" "$sa_d/before-marker.md"
sa_marker_file="$(mktemp)"
printf '%s\n%s\n' \
    "A persona with an embedded marker line." \
    "<!-- >>> spec-workflow generated: file output contract -->" \
    > "$sa_marker_file"
sa_sp_marker_out="$(bash "$SA_SCRIPT" --root "$sa_d" set-persona --file "$sa_marker_file" 2>&1)"
sa_sp_marker_rc=$?
check_rc "set-persona: text containing a reserved AGENTS.md marker line is rejected" 1 "$sa_sp_marker_rc"
check "set-persona: marker-conflict rejection prints REJECTED" "REJECTED" "$sa_sp_marker_out"
cmp -s "$sa_d/before-marker.yaml" "$sa_d/.claude/project.yaml" && r=SAME || r=DIFF
check "set-persona: marker-conflict rejection leaves project.yaml byte-identical" "SAME" "$r"
cmp -s "$sa_d/before-marker.md" "$sa_d/AGENTS.md" && r=SAME || r=DIFF
check "set-persona: marker-conflict rejection leaves AGENTS.md byte-identical" "SAME" "$r"
rm -f "$sa_marker_file" "$sa_d/before-marker.yaml" "$sa_d/before-marker.md"

# empty/whitespace-only text is rejected: nonzero exit, project.yaml AND
# AGENTS.md both byte-identical (not just project.yaml)
cp "$sa_d/.claude/project.yaml" "$sa_d/before-persona.yaml"
cp "$sa_d/AGENTS.md" "$sa_d/before-persona.md"
sa_empty_file="$(mktemp)"
printf '   \n\n  \n' > "$sa_empty_file"
sa_sp_empty_out="$(bash "$SA_SCRIPT" --root "$sa_d" set-persona --file "$sa_empty_file" 2>&1)"
sa_sp_empty_rc=$?
check_rc "set-persona: empty/whitespace-only text is rejected" 1 "$sa_sp_empty_rc"
check "set-persona: rejection prints REJECTED with a specific message" "REJECTED" "$sa_sp_empty_out"
cmp -s "$sa_d/before-persona.yaml" "$sa_d/.claude/project.yaml" && r=SAME || r=DIFF
check "set-persona: rejected write leaves project.yaml byte-identical" "SAME" "$r"
cmp -s "$sa_d/before-persona.md" "$sa_d/AGENTS.md" && r=SAME || r=DIFF
check "set-persona: rejected write leaves AGENTS.md byte-identical too" "SAME" "$r"
rm -f "$sa_empty_file" "$sa_d/before-persona.yaml" "$sa_d/before-persona.md"

# text over the DERIVED runtime clip is still accepted in full, with a
# warning naming the actual derived char count (review round 1 finding 1 --
# not a hardcoded, wrong-unit 800)
sa_long_file="$(mktemp)"
python3 -c "print('A persona sentence that repeats itself. ' * 100)" > "$sa_long_file"
sa_sp_long_out="$(bash "$SA_SCRIPT" --root "$sa_d" set-persona --file "$sa_long_file" 2>&1)"
sa_sp_long_rc=$?
check_rc "set-persona: text over the runtime clip is still accepted (never silently rejected)" 0 "$sa_sp_long_rc"
check "set-persona: OK printed for the long persona" "OK" "$sa_sp_long_out"
check "set-persona: the warning names the derived runtime clip" "$sa_persona_clip" "$sa_sp_long_out"
sa_sp_long_stored="$(sa_get "$sa_d" assistant.systemPrompt)"
sa_sp_long_stored_len="${#sa_sp_long_stored}"
[[ "$sa_sp_long_stored_len" -gt "$sa_persona_clip" ]] && r=FULL || r=TRUNCATED
check "set-persona: the full (untruncated) text is what's stored, not silently clipped" "FULL" "$r"
rm -f "$sa_long_file"

# scaffold re-run after set-persona does not overwrite the custom systemPrompt
bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis >/dev/null 2>&1
sa_sp_after_scaffold="$(sa_get "$sa_d" assistant.systemPrompt)"
check "set-persona: a later scaffold re-run does not overwrite the custom systemPrompt" \
    "repeats itself" "$sa_sp_after_scaffold"
rm -rf "$sa_d"

# review round 1 finding 4: a missing/unreadable --file path is a clean
# rejection, not an uncaught FileNotFoundError traceback.
sa_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis >/dev/null 2>&1
sa_sp_missing_out="$(bash "$SA_SCRIPT" --root "$sa_d" set-persona --file "$sa_d/does-not-exist.txt" 2>&1)"
sa_sp_missing_rc=$?
check_rc "set-persona: a missing --file path is rejected cleanly" 1 "$sa_sp_missing_rc"
check "set-persona: missing-file rejection prints REJECTED" "REJECTED" "$sa_sp_missing_out"
check_absent "set-persona: missing-file rejection never leaks a raw Python traceback" \
    "Traceback (most recent call last)" "$sa_sp_missing_out"

# coverage: special characters round-trip intact through project.yaml's
# YAML encoding and config.py's `get` verb -- double quote, backslash,
# colon-space, and unicode are all meaningful in YAML/JSON and easy to mangle
sa_special_file="$(mktemp)"
printf '%s\n' 'Say "hello" then a backslash \ and a colon: value, plus emoji 🤖.' > "$sa_special_file"
bash "$SA_SCRIPT" --root "$sa_d" set-persona --file "$sa_special_file" >/dev/null 2>&1
sa_special_stored="$(sa_get "$sa_d" assistant.systemPrompt)"
check 'set-persona: a double quote round-trips intact' 'Say "hello"' "$sa_special_stored"
check 'set-persona: a backslash round-trips intact' 'backslash \ and' "$sa_special_stored"
check 'set-persona: a colon-space round-trips intact' 'a colon: value' "$sa_special_stored"
check 'set-persona: unicode round-trips intact' 'emoji 🤖' "$sa_special_stored"
rm -f "$sa_special_file"
rm -rf "$sa_d"

# stdin form (--file -) works
sa_d="$(mktemp -d)"
bash "$SA_SCRIPT" --root "$sa_d" scaffold --name jarvis >/dev/null 2>&1
sa_sp_stdin_out="$(printf 'You are Jarvis, from stdin.\n' | bash "$SA_SCRIPT" --root "$sa_d" set-persona --file - 2>&1)"
sa_sp_stdin_rc=$?
check_rc "set-persona: --file - reads from stdin, exits 0" 0 "$sa_sp_stdin_rc"
check "set-persona: --file - prints OK" "OK" "$sa_sp_stdin_out"
check "set-persona: stdin persona text lands in assistant.systemPrompt" \
    "You are Jarvis, from stdin." "$(sa_get "$sa_d" assistant.systemPrompt)"
rm -rf "$sa_d"
rm -f "$sa_persona_file"
