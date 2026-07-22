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

# --- no engine code copied into the scaffolded tree (§6.7) --------------------
sa_engine_hits="$(find "$sa_d" -name '*.py' 2>/dev/null | wc -l | tr -d ' ')"
check "scaffold: no .py engine files copied into the assistant repo (§6.7)" "0" "$sa_engine_hits"

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

# --- docs: both README skills tables mention the new skill ---------------------
check "root README documents setup-assistant" "setup-assistant" "$(cat "$PLUGIN/../../README.md" 2>/dev/null)"
check "plugin README documents setup-assistant" "setup-assistant" "$(cat "$PLUGIN/README.md" 2>/dev/null)"

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
