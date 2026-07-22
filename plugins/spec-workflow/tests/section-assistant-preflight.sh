#!/usr/bin/env bash
# section-assistant-preflight.sh -- AST-006: preflight assistant checks with
# enumerated failures (SPEC-ASSISTANT.md §6.6, issue #306). Sourced by
# run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant preflight (AST-006: enumerated checks, SPEC-ASSISTANT.md §6.6) =="

AP_SCRIPT="$PLUGIN/scripts/assistant/preflight.py"

ap_marker() { # $1: dir -- writes the shipped-verbatim marker
    mkdir -p "$1/.claude"
    printf '%s\n' '# neural-view discovery marker — repos with this file are included in the aggregated neural view' \
        >"$1/.claude/.neural-network"
}

# ap_run <root> [state_dir] -- runs preflight.py, isolated NEURAL_VIEW_STATE
# so cache tests never touch the real repo's own local state.
ap_run() {
    local root="$1" state="${2:-}"
    if [[ -n "$state" ]]; then
        ( cd "$root" && NEURAL_VIEW_STATE="$state" python3 "$AP_SCRIPT" "$root" )
    else
        ( cd "$root" && python3 "$AP_SCRIPT" "$root" )
    fi
}

# ap_stub_dir <bin-name> <exit-code> [counter-file] -- creates a PATH dir
# with one stub executable that: exits with <exit-code> to any invocation,
# and (if given) appends a line to <counter-file> every time it's invoked
# (proves/disproves cache-skips-the-subprocess-probe).
ap_stub_dir() {
    local name="$1" rc="$2" counter="${3:-}"
    local d; d="$(mktemp -d)"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        if [[ -n "$counter" ]]; then
            printf 'echo call >> %q\n' "$counter"
        fi
        printf 'exit %s\n' "$rc"
    } >"$d/$name"
    chmod +x "$d/$name"
    printf '%s\n' "$d"
}

# ---------------------------------------------------------------- no marker
ap_d="$(mktemp -d)"
out="$(ap_run "$ap_d")"
# explicit emptiness assertion -- check()'s grep -qF with an empty expected
# matches unconditionally (vacuous), so it can't guard the zero-noise contract.
if [[ -z "$out" ]]; then
    echo "ok   no marker: prints nothing (zero noise for non-assistant repos)"
else
    echo "FAIL no marker: expected empty output, got: $out"
    fails=$((fails + 1))
fi
rm -rf "$ap_d"

# --------------------------------------------------------- legacy marker: no config at all
ap_d="$(mktemp -d)"
ap_marker "$ap_d"
out="$(ap_run "$ap_d")"
check "legacy marker, no config file: informational, not a failure" \
    "marker present, no assistant section (not an assistant repo)" "$out"
check_absent "legacy marker, no config file: never FAILs the whole preflight" "FAIL" "$out"
rm -rf "$ap_d"

# --------------------------------------------------------- legacy marker: config, no assistant:
ap_d="$(mktemp -d)"
ap_marker "$ap_d"
printf '%s\n' 'schemaVersion: 2' 'project:' '    name: no-assistant-here' >"$ap_d/.claude/project.yaml"
out="$(ap_run "$ap_d")"
check "legacy marker, config present but no assistant: section: informational" \
    "marker present, no assistant section (not an assistant repo)" "$out"
check_absent "legacy marker, no assistant: section: never a FAIL" "FAIL" "$out"
rm -rf "$ap_d"

# --------------------------------------------------------- invalid section (structural)
ap_d="$(mktemp -d)"
ap_marker "$ap_d"
printf '%s\n' \
    'schemaVersion: 2' \
    'assistant:' \
    '    version: 1' \
    '    enabled: true' \
    '    names: [jarvis]' \
    '    llm:' \
    '        provider: claude' \
    '        model: claude-sonnet-5' \
    '    capabilities:' \
    '        claude-code:' \
    '            enabled: true' \
    '            provisioning:' \
    '                bin: claude' \
    >"$ap_d/.claude/project.yaml"   # missing required systemPrompt
out="$(ap_run "$ap_d")"
check "invalid section: FAIL naming the exact missing key" \
    "assistant preflight FAIL: $ap_d: invalid assistant section: assistant: missing required key 'systemPrompt'" "$out"
rm -rf "$ap_d"

# --------------------------------------------------------- provider mismatch (§6.5)
ap_d="$(mktemp -d)"
ap_marker "$ap_d"
printf '%s\n' \
    'schemaVersion: 2' \
    'assistant:' \
    '    version: 1' \
    '    enabled: true' \
    '    names: [jarvis]' \
    '    systemPrompt: |' \
    '        You are Jarvis.' \
    '    llm:' \
    '        provider: openai' \
    '        model: gpt-5.6-sol' \
    '    capabilities:' \
    '        codex:' \
    '            enabled: false' \
    '            provisioning:' \
    '                bin: codex' \
    '        claude-code:' \
    '            enabled: true' \
    '            provisioning:' \
    '                bin: claude' \
    >"$ap_d/.claude/project.yaml"   # provider openai but codex disabled
out="$(ap_run "$ap_d")"
check "provider mismatch: FAIL with the both-sides message (config.py's own)" \
    "assistant preflight FAIL: $ap_d: provider mismatch: assistant.llm.provider: 'openai' requires capabilities.codex.enabled: true" "$out"
check_absent "provider mismatch: does not also claim a generic invalid section" \
    "invalid assistant section" "$out"
rm -rf "$ap_d"

# --------------------------------------------------------- helper: minimal valid section
# ap_valid_yaml <dir> <bin-name> -- a structurally + cross-field valid
# assistant: section (provider openai / capability codex / given bin).
ap_valid_yaml() {
    local dir="$1" bin="$2"
    printf '%s\n' \
        'schemaVersion: 2' \
        'assistant:' \
        '    version: 1' \
        '    enabled: true' \
        '    names: [jarvis]' \
        '    systemPrompt: |' \
        '        You are Jarvis.' \
        '    llm:' \
        '        provider: openai' \
        '        model: gpt-5.6-sol' \
        '    capabilities:' \
        '        codex:' \
        '            enabled: true' \
        '            provisioning:' \
        "                bin: $bin" \
        >"$dir/.claude/project.yaml"
}

# --------------------------------------------------------- enabled capability bin missing
ap_d="$(mktemp -d)"
ap_marker "$ap_d"
ap_valid_yaml "$ap_d" "definitely-not-a-real-assistant-bin-xyz"
out="$(ap_run "$ap_d")"
check "bin missing: FAIL naming the capability" "capability 'codex'" "$out"
check "bin missing: FAIL naming the bin" "bin 'definitely-not-a-real-assistant-bin-xyz' not found on PATH" "$out"
rm -rf "$ap_d"

# --------------------------------------------------------- bin present but unauthenticated
ap_d="$(mktemp -d)"
ap_marker "$ap_d"
ap_valid_yaml "$ap_d" "codex"
ap_unauth_dir="$(ap_stub_dir codex 1)"
out="$(cd "$ap_d" && PATH="$ap_unauth_dir:$PATH" NEURAL_VIEW_STATE="$(mktemp -d)" python3 "$AP_SCRIPT" "$ap_d")"
check "unauthenticated: FAIL naming the CLI" "codex ('$ap_unauth_dir/codex') not authenticated" "$out"
check "unauthenticated: FAIL names the login command to run" "run 'codex login'" "$out"
rm -rf "$ap_d" "$ap_unauth_dir"

# --------------------------------------------------------- all good -> ok line
ap_d="$(mktemp -d)"
ap_marker "$ap_d"
ap_valid_yaml "$ap_d" "codex"
ap_ok_dir="$(ap_stub_dir codex 0)"
out="$(cd "$ap_d" && PATH="$ap_ok_dir:$PATH" NEURAL_VIEW_STATE="$(mktemp -d)" python3 "$AP_SCRIPT" "$ap_d")"
check "all good: ok line names the assistant, provider, capability count" \
    "assistant preflight ok: jarvis (openai, 1 capabilities)" "$out"
check_absent "all good: no FAIL" "FAIL" "$out"
rm -rf "$ap_d" "$ap_ok_dir"

# --------------------------------------------------------- claude-code auth probe: claude auth status --json shape
ap_d="$(mktemp -d)"
ap_marker "$ap_d"
printf '%s\n' \
    'schemaVersion: 2' \
    'assistant:' \
    '    version: 1' \
    '    enabled: true' \
    '    names: [jarvis]' \
    '    systemPrompt: |' \
    '        You are Jarvis.' \
    '    llm:' \
    '        provider: claude' \
    '        model: claude-sonnet-5' \
    '    capabilities:' \
    '        claude-code:' \
    '            enabled: true' \
    '            provisioning:' \
    '                bin: claude' \
    >"$ap_d/.claude/project.yaml"
ap_cc_dir="$(mktemp -d)"
cat >"$ap_cc_dir/claude" <<'STUB'
#!/usr/bin/env bash
echo '{"loggedIn": false}'
exit 0
STUB
chmod +x "$ap_cc_dir/claude"
out="$(cd "$ap_d" && PATH="$ap_cc_dir:$PATH" NEURAL_VIEW_STATE="$(mktemp -d)" python3 "$AP_SCRIPT" "$ap_d")"
check "claude-code: loggedIn:false in JSON is unauthenticated even though rc=0" \
    "claude-code ('$ap_cc_dir/claude') not authenticated" "$out"
check "claude-code: names the claude login command" "run 'claude auth login'" "$out"
rm -rf "$ap_d" "$ap_cc_dir"

# --------------------------------------------------------- positive-path caching
ap_d="$(mktemp -d)"
ap_marker "$ap_d"
ap_valid_yaml "$ap_d" "codex"
ap_state="$(mktemp -d)"
ap_counter="$(mktemp -d)/calls"
ap_cache_dir="$(ap_stub_dir codex 0 "$ap_counter")"

out1="$(cd "$ap_d" && PATH="$ap_cache_dir:$PATH" NEURAL_VIEW_STATE="$ap_state" python3 "$AP_SCRIPT" "$ap_d")"
check "cache: first run reports ok" "assistant preflight ok: jarvis" "$out1"
count1="$(wc -l <"$ap_counter" | tr -d ' ')"
check "cache: first run invoked the auth probe once" "1" "$count1"

out2="$(cd "$ap_d" && PATH="$ap_cache_dir:$PATH" NEURAL_VIEW_STATE="$ap_state" python3 "$AP_SCRIPT" "$ap_d")"
check "cache: second run within TTL still reports ok" "assistant preflight ok: jarvis" "$out2"
count2="$(wc -l <"$ap_counter" | tr -d ' ')"
check "cache: second run within TTL did NOT re-invoke the auth probe" "1" "$count2"

# a config change invalidates the cache -- bump the model string
python3 "$PLUGIN/scripts/config.py" "$ap_d" set assistant.llm.model '"gpt-5.7-nova"' >/dev/null 2>&1
out3="$(cd "$ap_d" && PATH="$ap_cache_dir:$PATH" NEURAL_VIEW_STATE="$ap_state" python3 "$AP_SCRIPT" "$ap_d")"
check "cache: config change still reports ok" "assistant preflight ok: jarvis" "$out3"
count3="$(wc -l <"$ap_counter" | tr -d ' ')"
check "cache: config change invalidates the cache (probe invoked again)" "2" "$count3"
rm -rf "$ap_d" "$ap_state" "$ap_cache_dir" "$(dirname "$ap_counter")"

# --------------------------------------------------------- negative verdicts are NEVER cached
ap_d="$(mktemp -d)"
ap_marker "$ap_d"
ap_valid_yaml "$ap_d" "codex"
ap_neg_state="$(mktemp -d)"
ap_neg_counter="$(mktemp -d)/calls"
ap_neg_dir="$(ap_stub_dir codex 1 "$ap_neg_counter")"

nout1="$(cd "$ap_d" && PATH="$ap_neg_dir:$PATH" NEURAL_VIEW_STATE="$ap_neg_state" python3 "$AP_SCRIPT" "$ap_d")"
check "negative caching: first run reports FAIL" "not authenticated" "$nout1"
ncount1="$(wc -l <"$ap_neg_counter" | tr -d ' ')"
check "negative caching: first run invoked the probe once" "1" "$ncount1"

nout2="$(cd "$ap_d" && PATH="$ap_neg_dir:$PATH" NEURAL_VIEW_STATE="$ap_neg_state" python3 "$AP_SCRIPT" "$ap_d")"
check "negative caching: second run still reports FAIL (never cached)" "not authenticated" "$nout2"
ncount2="$(wc -l <"$ap_neg_counter" | tr -d ' ')"
check "negative caching: second run re-invoked the probe (a FAIL was never cached)" "2" "$ncount2"
rm -rf "$ap_d" "$ap_neg_state" "$ap_neg_dir" "$(dirname "$ap_neg_counter")"

# --------------------------------------------------------- wired into preflight.sh
pf_d="$(mktemp -d)"
( cd "$pf_d" && git init -q . )
mkdir -p "$pf_d/.claude"
printf '%s\n' '# neural-view discovery marker — repos with this file are included in the aggregated neural view' \
    >"$pf_d/.claude/.neural-network"
ap_valid_yaml "$pf_d" "codex"
touch "$pf_d/SPEC.md" 2>/dev/null
pf_ok_dir="$(ap_stub_dir codex 0)"
pf_out="$(cd "$pf_d" && PATH="$pf_ok_dir:$PATH" NEURAL_VIEW_STATE="$(mktemp -d)" bash "$PLUGIN/scripts/preflight.sh")"
check "preflight.sh: prints the assistant verdict line for a marker'd root" \
    "assistant preflight ok: jarvis" "$pf_out"
rm -rf "$pf_d" "$pf_ok_dir"

# a repo with NO marker: preflight.sh's existing output is unchanged (no new noise)
pf_d2="$(mktemp -d)"
( cd "$pf_d2" && git init -q . )
mkdir -p "$pf_d2/.claude" && cp "$FIX/valid.project.json" "$pf_d2/.claude/project.json"
touch "$pf_d2/SPEC.md"
pf_out2="$(cd "$pf_d2" && bash "$PLUGIN/scripts/preflight.sh" --spec)"
check_absent "preflight.sh: no marker -> no assistant preflight noise" "assistant preflight" "$pf_out2"
rm -rf "$pf_d2"

# --- review r2 blocker 1: an UNREADABLE project.yaml (PermissionError, an
# OSError not a ConfigError) must yield an enumerated FAIL line, never a
# traceback. (Fixture proven to reach the fixed path: chmod 000 makes
# load_config raise PermissionError before any parse.) ------------------------
ap_d="$(mktemp -d)"
mkdir -p "$ap_d/.claude"
ap_marker "$ap_d"
ap_valid_yaml "$ap_d" "codex"
chmod 000 "$ap_d/.claude/project.yaml"
ap_r2_out="$(ap_run "$ap_d" 2>&1)"
ap_r2_rc=$?
chmod 644 "$ap_d/.claude/project.yaml"
check_rc "r2: unreadable config exits 0 (advisory contract)" 0 "$ap_r2_rc"
check "r2: unreadable config yields an enumerated FAIL line" "cannot read config" "$ap_r2_out"
check_absent "r2: unreadable config leaks no traceback" "Traceback (most recent call last)" "$ap_r2_out"
rm -rf "$ap_d"

# --- review r2 blocker 2: an UNWRITABLE state dir degrades only the cache --
# the ok verdict must still be reported, no crash. ----------------------------
ap_d="$(mktemp -d)"; ap_state="$(mktemp -d)"
mkdir -p "$ap_d/.claude"
ap_marker "$ap_d"
ap_valid_yaml "$ap_d" "codex"
ap_stub="$(ap_stub_dir codex 0)"
chmod 555 "$ap_state"
ap_r2b_out="$(cd "$ap_d" && PATH="$ap_stub:$PATH" NEURAL_VIEW_STATE="$ap_state" python3 "$AP_SCRIPT" "$ap_d" 2>&1)"
ap_r2b_rc=$?
chmod 755 "$ap_state"
check_rc "r2: unwritable cache dir exits 0" 0 "$ap_r2b_rc"
check "r2: unwritable cache dir still reports the ok verdict" "assistant preflight ok: jarvis" "$ap_r2b_out"
check_absent "r2: unwritable cache dir leaks no traceback" "Traceback (most recent call last)" "$ap_r2b_out"
rm -rf "$ap_d" "$ap_state" "$ap_stub"
