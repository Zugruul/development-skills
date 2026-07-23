#!/usr/bin/env bash
# section-assistant-discovery.sh -- AST-020: multi-repo discovery scan
# (config-authoritative classifier + scan outcome, SPEC-ASSISTANT.md §7.1,
# §6.1, §6.2, issue #317). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant.discovery (AST-020: multi-repo scan, SPEC-ASSISTANT.md §7.1) =="

DS_SCRIPTS="$PLUGIN/scripts"

# ds_py <python-body> <argv...> -- runs a python3 snippet with
# assistant.discovery importable, repo roots passed as sys.argv[1:].
ds_py() {
    local script="$1"; shift
    PLUGIN_SCRIPTS="$DS_SCRIPTS" python3 -c '
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
from assistant import discovery
'"$script" "$@"
}

# ds_marker <dir> [content] -- .claude/.neural-network, default legacy comment-only.
ds_marker() {
    local dir="$1"
    local content="${2:-# neural-network}"
    mkdir -p "$dir/.claude"
    printf '%s\n' "$content" >"$dir/.claude/.neural-network"
}

# ds_config <dir> <name> <enabled-line-or-empty> [extra-flag]
#   extra-flag=omit-llm -> section is missing the required llm block (section-invalid)
#   extra-flag=malformed -> project.yaml itself fails to parse (config-invalid)
#   extra-flag=no-section -> project.yaml has no assistant: key at all
ds_config() {
    local dir="$1" name="$2" enabled_line="$3" extra="${4:-}"
    mkdir -p "$dir/.claude"
    if [[ "$extra" == "malformed" ]]; then
        printf '%s\n' \
            'schemaVersion: 2' \
            'assistant: [this is not' \
            '  valid yaml mapping' \
            >"$dir/.claude/project.yaml"
        return
    fi
    if [[ "$extra" == "no-section" ]]; then
        printf '%s\n' \
            'schemaVersion: 2' \
            'someOtherKey: true' \
            >"$dir/.claude/project.yaml"
        return
    fi
    {
        printf '%s\n' 'schemaVersion: 2' 'assistant:' '    version: 1'
        [[ -n "$enabled_line" ]] && printf '%s\n' "    enabled: $enabled_line"
        printf '%s\n' "    names: [$name]" '    systemPrompt: |' "        You are $name."
        if [[ "$extra" != "omit-llm" ]]; then
            printf '%s\n' \
                '    llm:' \
                '        provider: openai' \
                '        model: gpt-5.6-sol' \
                '    capabilities:' \
                '        codex:' \
                '            enabled: true'
        fi
    } >"$dir/.claude/project.yaml"
}

# ds_candidate <dir> <name> -- full fixture: marker + valid, enabled config.
ds_candidate() {
    local dir="$1" name="$2"
    ds_marker "$dir"
    ds_config "$dir" "$name" "true"
}

ds_classify() { # <dir> -> prints Classification.kind
    ds_py '
c = discovery.classify_repo(sys.argv[1])
print(c.kind)
' "$1"
}

# ------------------------------------------------------------ candidate: valid + enabled
ds_a="$(mktemp -d)"
ds_candidate "$ds_a" jarvis
out="$(ds_classify "$ds_a")"
check "valid+enabled marker'd repo classifies as candidate" "candidate" "$out"
out="$(ds_py '
c = discovery.classify_repo(sys.argv[1])
print(sorted(c.section["names"]))
' "$ds_a")"
check "candidate classification carries the parsed assistant section" "['jarvis']" "$out"
rm -rf "$ds_a"

# ------------------------------------------------------------ legacy comment-only / empty marker + valid config -> candidate
ds_a="$(mktemp -d)"
ds_marker "$ds_a" ""
ds_config "$ds_a" jarvis "true"
out="$(ds_classify "$ds_a")"
check "legacy empty-content marker + valid enabled config -> candidate" "candidate" "$out"
rm -rf "$ds_a"

# ------------------------------------------------------------ enabled but section structurally invalid -> section-invalid
ds_a="$(mktemp -d)"
ds_marker "$ds_a"
ds_config "$ds_a" jarvis "true" "omit-llm"
out="$(ds_classify "$ds_a")"
check "enabled but structurally invalid section (missing llm) -> section-invalid" "section-invalid" "$out"
rm -rf "$ds_a"

# ------------------------------------------------------------ enabled: false -> disabled
ds_a="$(mktemp -d)"
ds_marker "$ds_a"
ds_config "$ds_a" jarvis "false"
out="$(ds_classify "$ds_a")"
check "structurally valid section with enabled: false -> disabled" "disabled" "$out"
rm -rf "$ds_a"

# ------------------------------------------------------------ missing enabled key -> disabled (validate_assistant does not require it)
ds_a="$(mktemp -d)"
ds_marker "$ds_a"
ds_config "$ds_a" jarvis ""
out="$(ds_classify "$ds_a")"
check "structurally valid section with NO enabled key -> disabled, not section-invalid" "disabled" "$out"
rm -rf "$ds_a"

# ------------------------------------------------------------ no assistant: section -> no-assistant-section
ds_a="$(mktemp -d)"
ds_marker "$ds_a"
ds_config "$ds_a" jarvis "true" "no-section"
out="$(ds_classify "$ds_a")"
check "config with no assistant: section -> no-assistant-section" "no-assistant-section" "$out"
rm -rf "$ds_a"

# ------------------------------------------------------------ project.yaml unparseable -> config-invalid
ds_a="$(mktemp -d)"
ds_marker "$ds_a"
ds_config "$ds_a" jarvis "true" "malformed"
out="$(ds_classify "$ds_a")"
check "unparseable project.yaml -> config-invalid" "config-invalid" "$out"
rm -rf "$ds_a"

# ------------------------------------------------------------ no project.yaml at all -> no-config
ds_a="$(mktemp -d)"
ds_marker "$ds_a"
out="$(ds_classify "$ds_a")"
check "marker present, no project.yaml -> no-config" "no-config" "$out"
rm -rf "$ds_a"

# ------------------------------------------------------------ no marker -> no-marker
ds_a="$(mktemp -d)"
ds_config "$ds_a" jarvis "true"
out="$(ds_classify "$ds_a")"
check "project.yaml present, no marker -> no-marker" "no-marker" "$out"
rm -rf "$ds_a"

# ------------------------------------------------------------ marker present but unreadable -> marker-unreadable, never a crash
ds_a="$(mktemp -d)"
ds_marker "$ds_a"
ds_config "$ds_a" jarvis "true"
chmod 000 "$ds_a/.claude/.neural-network"
out="$(ds_classify "$ds_a")"
rc=$?
chmod 644 "$ds_a/.claude/.neural-network"
check_rc "unreadable marker: classify_repo does not raise (clean rc)" 0 "$rc"
check "unreadable marker -> marker-unreadable (config authority never consulted)" "marker-unreadable" "$out"
rm -rf "$ds_a"

# ------------------------------------------------------------ scan(): one candidate -> outcome "one"
ds_a="$(mktemp -d)"; ds_b="$(mktemp -d)"
ds_candidate "$ds_a" jarvis
ds_config "$ds_b" friday "false"
ds_marker "$ds_b"
out="$(ds_py '
r = discovery.scan(sys.argv[1:])
print(r.outcome)
print(len(r.candidates))
' "$ds_a" "$ds_b")"
check "scan: exactly one candidate among the roots -> outcome one" "one" "$out"
check "scan: one candidate -> candidates list has length 1" "1" "$out"
rm -rf "$ds_a" "$ds_b"

# ------------------------------------------------------------ scan(): two candidates -> outcome "multiple"
ds_a="$(mktemp -d)"; ds_b="$(mktemp -d)"
ds_candidate "$ds_a" jarvis
ds_candidate "$ds_b" friday
out="$(ds_py '
r = discovery.scan(sys.argv[1:])
print(r.outcome)
print(len(r.candidates))
' "$ds_a" "$ds_b")"
check "scan: two candidates among the roots -> outcome multiple" "multiple" "$out"
check "scan: two candidates -> candidates list has length 2" "2" "$out"
rm -rf "$ds_a" "$ds_b"

# ------------------------------------------------------------ scan(): zero candidates -> outcome "none"
ds_a="$(mktemp -d)"; ds_b="$(mktemp -d)"
ds_marker "$ds_a"
ds_config "$ds_b" friday "false"; ds_marker "$ds_b"
out="$(ds_py '
r = discovery.scan(sys.argv[1:])
print(r.outcome)
print(len(r.candidates))
' "$ds_a" "$ds_b")"
check "scan: no candidates among the roots -> outcome none" "none" "$out"
check "scan: no candidates -> candidates list is empty" "0" "$out"
rm -rf "$ds_a" "$ds_b"

# ------------------------------------------------------------ scan(): a broken/malformed root among valid ones still classifies the rest (fail-closed)
ds_a="$(mktemp -d)"
ds_candidate "$ds_a" jarvis
out="$(ds_py '
r = discovery.scan([None, sys.argv[1]])
print(r.outcome)
print(len(r.repos))
print(r.candidates[0][0] == sys.argv[1])
' "$ds_a")"
rc=$?
check_rc "scan: a broken sibling root never raises out of scan()" 0 "$rc"
check "scan: broken sibling does not block the valid sibling's classification" "True" "$out"
check "scan: broken sibling -> outcome still reflects the one good candidate" "one" "$out"
rm -rf "$ds_a"

# ------------------------------------------------------------ default_store.discover_candidate delegates: behavior-identical wrapper
out="$(PLUGIN_SCRIPTS="$DS_SCRIPTS" python3 -c '
import os, sys
sys.path.insert(0, os.environ["PLUGIN_SCRIPTS"])
from assistant import default_store, discovery
import inspect
src = inspect.getsource(default_store.discover_candidate)
print("classify_repo" in src)
')"
check "default_store.discover_candidate delegates to discovery.classify_repo (one classifier only)" "True" "$out"
