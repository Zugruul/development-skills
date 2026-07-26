#!/usr/bin/env bash
# section-config.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== config.py (shared loader) =="
CT="$(mktemp -d)"; mkdir -p "$CT/.claude"
cp "$FIX/valid.project.yaml" "$CT/.claude/project.yaml"
check "yaml dot-path get" "fixture-project" "$(python3 "$PLUGIN/scripts/config.py" "$CT" get project.name)"
check "yaml nested get" "true" "$(python3 "$PLUGIN/scripts/config.py" "$CT" get commands.gate)"
check "path verb resolves yaml" "project.yaml" "$(python3 "$PLUGIN/scripts/config.py" "$CT" path)"
check "json verb emits normalized" '"schemaVersion"' "$(python3 "$PLUGIN/scripts/config.py" "$CT" json)"
check "v2 dev array models get" "claude-haiku-4-5" "$(python3 "$PLUGIN/scripts/config.py" "$CT" get delegation.identities.dev.1.models.1)"
cp "$FIX/valid.project.json" "$CT/.claude/project.json"
check "yaml preferred over json" "project.yaml" "$(python3 "$PLUGIN/scripts/config.py" "$CT" path)"
rm -rf "$CT"
CJ="$(mktemp -d)"; mkdir -p "$CJ/.claude"
cp "$FIX/valid.project.json" "$CJ/.claude/project.json"
check "legacy json deprecation warning" "DEPRECATION" "$(python3 "$PLUGIN/scripts/config.py" "$CJ" json 2>&1 >/dev/null)"
check "legacy path resolves json" "project.json" "$(python3 "$PLUGIN/scripts/config.py" "$CJ" path 2>/dev/null)"
check "legacy devModel -> dev.models[0]" "sonnet" "$(python3 "$PLUGIN/scripts/config.py" "$CJ" get delegation.identities.dev.models.0 2>/dev/null)"
check "legacy reviewModel -> reviewer.models[0]" "sonnet" "$(python3 "$PLUGIN/scripts/config.py" "$CJ" get delegation.identities.reviewer.models.0 2>/dev/null)"
check "PROJECT_CONFIG override" "fixture-project" "$(PROJECT_CONFIG="$FIX/valid.project.yaml" python3 "$PLUGIN/scripts/config.py" "$CJ" get project.name)"
rm -rf "$CJ"

echo "== validate-config =="
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/valid.project.yaml")"
check "valid yaml passes" "VALID: " "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/broken.project.yaml" || true)"
check "broken yaml: schemaVersion 2" "schemaVersion must be 2" "$out"
check "broken yaml: statusFlow option" "'Done' has no matching status option id" "$out"
check "broken yaml: empty priority options" "priority.options is empty" "$out"
check "broken yaml: unknown board ref" "does not match any boards[].id" "$out"
check "broken yaml: unknown blockedBy epic" "unknown epic 'EZ'" "$out"
check "broken yaml: maxInProgress <= 0 rejected" "methodology.maxInProgress: must be >= 1 (got -3)" "$out"
check "broken yaml: graduationThreshold non-integer rejected" "methodology.graduationThreshold: must be an integer >= 1 (got 'many')" "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/shorthand.project.yaml" || true)"
check "v2 shorthand dev model rejected" "'sonnet'" "$out"
check "v2 shorthand reviewer model rejected" "'opus'" "$out"
check "shorthand error names full nomenclature" "full model-id" "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/valid.project.json")"
check "legacy json still VALID" "VALID: " "$out"
check "legacy json deprecation noted" "legacy" "$out"
check "legacy json shorthand allowed (devModel=sonnet)" "VALID: " "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/broken.project.json" || true)"
check "broken: schemaVersion" "schemaVersion must be 1" "$out"
check "broken: statusFlow option" "'Done' has no matching status option id" "$out"
check "broken: empty priority options" "priority.options is empty" "$out"
check "broken: bad taskPrefix" "must be alphanumeric starting with a letter" "$out"
check "broken: unknown board ref" "does not match any boards[].id" "$out"
check "broken: overlapping ranges" "overlaps epic" "$out"
check "broken: unknown blockedBy epic" "unknown epic 'EZ'" "$out"
check "broken: bad untilStatus" "not in statusFlow" "$out"
check "broken: missing gate" "missing required key 'gate'" "$out"
check "broken: maxInProgress non-integer rejected" "methodology.maxInProgress: must be an integer >= 1 (got 'two')" "$out"
check "broken: graduationThreshold <= 0 rejected" "methodology.graduationThreshold: must be >= 1 (got 0)" "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/bounds-bool.project.yaml" || true)"
check "maxInProgress bool rejected (not a valid integer)" "methodology.maxInProgress: must be an integer >= 1 (got True)" "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/bounds-float.project.yaml" || true)"
check "graduationThreshold float rejected (not a valid integer)" "methodology.graduationThreshold: must be an integer >= 1 (got 3.0)" "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$PLUGIN/templates/project.example.yaml" || true)"
check "template rejected (placeholders)" "template placeholder" "$out"

echo "== validate-config: methodology.entityKinds / neuralView.entityEdgeColor (#163) =="
check "valid yaml (no entityKinds/neuralView keys) still passes -- additive-only" "VALID: " \
    "$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/valid.project.yaml")"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/entity-kinds-bad.project.yaml" || true)"
check "entityKinds must be an object mapping kind -> role string" "methodology.entityKinds" "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/entity-edge-color-bad.project.yaml" || true)"
check "neuralView.entityEdgeColor must be a string" "neuralView.entityEdgeColor" "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/entity-kinds-good.project.yaml")"
check "entityKinds + entityEdgeColor together still validate" "VALID: " "$out"

echo "== validate-config: methodology.recencyDecayGraceRetros / recencyDecayFactor (GL-010) =="
RDC="$(mktemp -d)"
sed '/^    maxInProgress: 1/a\
    recencyDecayGraceRetros: -1
' "$FIX/valid.project.yaml" > "$RDC/negative-grace.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$RDC/negative-grace.project.yaml" || true)"
check "negative recencyDecayGraceRetros rejected" "methodology.recencyDecayGraceRetros: must be >= 0 (got -1)" "$out"

sed '/^    maxInProgress: 1/a\
    recencyDecayFactor: 1.5
' "$FIX/valid.project.yaml" > "$RDC/over-factor.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$RDC/over-factor.project.yaml" || true)"
check "recencyDecayFactor > 1 rejected" "methodology.recencyDecayFactor: must be in (0, 1] (got 1.5)" "$out"

sed '/^    maxInProgress: 1/a\
    recencyDecayFactor: 0
' "$FIX/valid.project.yaml" > "$RDC/zero-factor.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$RDC/zero-factor.project.yaml" || true)"
check "recencyDecayFactor == 0 rejected (must be > 0)" "methodology.recencyDecayFactor: must be in (0, 1] (got 0)" "$out"

sed '/^    maxInProgress: 1/a\
    recencyDecayGraceRetros: 5\
    recencyDecayFactor: 0.9
' "$FIX/valid.project.yaml" > "$RDC/valid-decay.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$RDC/valid-decay.project.yaml")"
check "valid recencyDecayGraceRetros/recencyDecayFactor pass" "VALID: " "$out"
rm -rf "$RDC"

echo "== validate-config: models.codex.capability (additive, CDX-020, #185) =="
check "this repo's own .claude/project.yaml (flat models arrays) still validates unmodified -- additivity proof" "VALID: " \
    "$(python3 "$PLUGIN/scripts/validate-config.py" "$PLUGIN/../../.claude/project.yaml")"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/codex-capability-good.project.yaml")"
check "models object form {claude, codex.capability: balanced} is VALID" "VALID: " "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/codex-capability-bad.project.yaml" || true)"
check "unrecognized models.codex.capability is INVALID" "INVALID" "$out"
check "unrecognized capability error names the offending value" "'super-fast'" "$out"

echo "== validate-config: assistant: section schema (AST-002, SPEC-ASSISTANT.md §6/§6.1/§6.5) =="

AC_SCRIPTS="$PLUGIN/scripts"

ac_py() { # $1: python3 -c snippet body (assistant.config importable, `a` is the assistant dict from sys.argv[1] JSON); $2..: sys.argv[1:]
    local script="$1"; shift
    PLUGIN_SCRIPTS="$AC_SCRIPTS" python3 -c '
import json, os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
from assistant import config as AC
a = json.loads(sys.argv[1])
'"$script" "$@"
}

AC_VALID_JSON='{"version": 1, "enabled": true, "names": ["jarvis", "j"], "systemPrompt": "You are Jarvis.", "llm": {"provider": "openai", "model": "gpt-5.6-sol"}, "capabilities": {"codex": {"enabled": true}, "claude-code": {"enabled": false}}, "observability": {"metrics": {"prometheus": {"enabled": true, "host": "127.0.0.1", "port": 9464}}, "traces": {"sqlite": {"enabled": true, "retainDays": 30, "maxMB": 500}}}}'

out="$(ac_py '
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "valid full section -> no errors" "[]" "$out"

out="$(ac_py '
a["enabled"] = False
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "enabled: false is still schema-valid (not itself an error)" "[]" "$out"

out="$(ac_py '
del a["names"]
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "names missing" "assistant: missing required key 'names'" "$out"

out="$(ac_py '
a["names"] = []
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "names empty list" "assistant.names: must be a non-empty list" "$out"

out="$(ac_py '
a["names"] = "jarvis"
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "names non-list" "assistant.names: expected list, got str" "$out"

out="$(ac_py '
a["names"] = ["", "j"]
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "names first element empty" "assistant.names: first entry (the main name) must be a non-empty string" "$out"

out="$(ac_py '
a["names"] = ["jarvis", ""]
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "names non-first element empty" "assistant.names[1]: must be a non-empty string" "$out"

out="$(ac_py '
del a["systemPrompt"]
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "systemPrompt missing" "assistant: missing required key 'systemPrompt'" "$out"

out="$(ac_py '
a["systemPrompt"] = 123
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "systemPrompt non-string" "assistant.systemPrompt: expected str, got int" "$out"

out="$(ac_py '
del a["llm"]
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "llm missing" "assistant: missing required key 'llm'" "$out"

out="$(ac_py '
a["llm"]["provider"] = "anthropic-raw"
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "llm.provider unknown value" "assistant.llm.provider: 'anthropic-raw' is not a recognized provider (valid: claude, openai)" "$out"

out="$(ac_py '
del a["llm"]["model"]
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "llm.model missing" "assistant.llm: missing required key 'model'" "$out"

out="$(ac_py '
a["capabilities"]["codex"]["enabled"] = False
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "provider openai requires codex enabled (disabled)" "assistant.llm.provider: 'openai' requires capabilities.codex.enabled: true" "$out"

out="$(ac_py '
del a["capabilities"]
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "provider openai requires codex enabled (capabilities absent)" "assistant.llm.provider: 'openai' requires capabilities.codex.enabled: true" "$out"

out="$(ac_py '
a["llm"]["provider"] = "claude"
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "provider claude requires claude-code enabled (disabled)" "assistant.llm.provider: 'claude' requires capabilities.claude-code.enabled: true" "$out"

out="$(ac_py '
a["capabilities"] = []
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "capabilities non-map" "assistant.capabilities: must be a mapping" "$out"

out="$(ac_py '
del a["capabilities"]["codex"]["enabled"]
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "capabilities entry missing enabled" "assistant.capabilities.codex: missing required key 'enabled'" "$out"

out="$(ac_py '
a["observability"]["traces"]["sqlite"]["retainDays"] = "thirty"
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "observability retention wrong type" "assistant.observability.traces.sqlite.retainDays: must be an integer >= 0 (0 = unlimited) (got 'thirty')" "$out"

out="$(ac_py '
a["observability"]["traces"]["sqlite"]["maxMB"] = -5
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "observability retention negative" "assistant.observability.traces.sqlite.maxMB: must be >= 0 (0 = unlimited) (got -5)" "$out"

out="$(ac_py '
a["observability"]["traces"]["sqlite"]["retainDays"] = 0
a["observability"]["traces"]["sqlite"]["maxMB"] = 0
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "observability retention 0 is valid (unlimited)" "[]" "$out"

out="$(ac_py '
a["version"] = "1"
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "version non-int" "assistant.version: must be an integer (got '1')" "$out"

out="$(ac_py '
a["foo"] = 1
print(AC.validate_assistant(a))
' "$AC_VALID_JSON")"
check "unknown top-level key rejected" "assistant.foo: unknown key" "$out"

echo "== validate-config: assistant: section wiring (AST-002) =="
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/valid.project.yaml")"
check "assistant section absent -- no-op, additive-only (regression)" "VALID: " "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/assistant-good.project.yaml")"
check "assistant: full valid section end-to-end" "VALID: " "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/assistant-bad.project.yaml" || true)"
check "assistant: provider/capability violation surfaces through validate-config" "INVALID" "$out"
check "assistant: error is path-precise" "assistant.llm.provider: 'openai' requires capabilities.codex.enabled: true" "$out"

echo "== validate-config: commit.convention / commit.systemPrompt (#418) =="
check "valid yaml (no commit key) still passes -- additive-only" "VALID: " \
    "$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/valid.project.yaml")"

CMT="$(mktemp -d)"
cat "$FIX/valid.project.yaml" > "$CMT/preset-plus-prompt.project.yaml"
{
    printf 'commit:\n'
    printf '    convention: gitmoji\n'
    printf '    systemPrompt: "Short scannable bullets."\n'
} >> "$CMT/preset-plus-prompt.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$CMT/preset-plus-prompt.project.yaml")"
check "commit: recognized preset (gitmoji) + custom systemPrompt -> VALID" "VALID: " "$out"

cat "$FIX/valid.project.yaml" > "$CMT/custom-string.project.yaml"
printf 'commit:\n    convention: "our-shop-style"\n' >> "$CMT/custom-string.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$CMT/custom-string.project.yaml")"
check "commit.convention: any non-empty custom string is VALID" "VALID: " "$out"

cat "$FIX/valid.project.yaml" > "$CMT/empty-convention.project.yaml"
printf 'commit:\n    convention: ""\n' >> "$CMT/empty-convention.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$CMT/empty-convention.project.yaml" || true)"
check "commit.convention: empty string rejected" "commit.convention: must not be empty" "$out"

cat "$FIX/valid.project.yaml" > "$CMT/wrongtype-convention.project.yaml"
printf 'commit:\n    convention: 5\n' >> "$CMT/wrongtype-convention.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$CMT/wrongtype-convention.project.yaml" || true)"
check "commit.convention: non-string rejected" "commit.convention: must be a string" "$out"

cat "$FIX/valid.project.yaml" > "$CMT/empty-prompt.project.yaml"
printf 'commit:\n    convention: conventional-commits\n    systemPrompt: ""\n' >> "$CMT/empty-prompt.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$CMT/empty-prompt.project.yaml" || true)"
check "commit.systemPrompt: empty string rejected" "commit.systemPrompt: must not be empty" "$out"

cat "$FIX/valid.project.yaml" > "$CMT/unknown-key.project.yaml"
printf 'commit:\n    convention: conventional-commits\n    bogus: true\n' >> "$CMT/unknown-key.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$CMT/unknown-key.project.yaml" || true)"
check "commit: unknown key rejected" "commit.bogus: unknown key" "$out"

cat "$FIX/valid.project.yaml" > "$CMT/not-a-map.project.yaml"
printf 'commit: "conventional-commits"\n' >> "$CMT/not-a-map.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$CMT/not-a-map.project.yaml" || true)"
check "commit: non-mapping rejected" "commit: must be a mapping" "$out"
rm -rf "$CMT"

check "this repo's own .claude/project.yaml (commit block set per #418) still validates" "VALID: " \
    "$(python3 "$PLUGIN/scripts/validate-config.py" "$PLUGIN/../../.claude/project.yaml")"

