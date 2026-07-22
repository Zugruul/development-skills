#!/usr/bin/env bash
# section-assistant-default.sh -- AST-007: machine-local default assistant
# store + §7.6 ambiguity resolution (SPEC-ASSISTANT.md §6.3, §7.6, issue
# #307). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant default store + resolution (AST-007: SPEC-ASSISTANT.md §6.3, §7.6) =="

AD_SCRIPT="$PLUGIN/scripts/assistant/default_store.py"
SA_SCRIPT="$PLUGIN/scripts/setup-assistant.sh"

# ad_repo <dir> <main-name> [alias...] -- a marker'd repo with a
# structurally valid, enabled assistant: section (names: [main, alias...]).
ad_repo() {
    local dir="$1" main="$2"
    shift 2
    mkdir -p "$dir/.claude"
    printf '%s\n' '# neural-network' >"$dir/.claude/.neural-network"
    local names="$main"
    local a
    for a in "$@"; do
        names="$names, $a"
    done
    printf '%s\n' \
        'schemaVersion: 2' \
        'assistant:' \
        '    version: 1' \
        '    enabled: true' \
        "    names: [$names]" \
        '    systemPrompt: |' \
        "        You are $main." \
        '    llm:' \
        '        provider: openai' \
        '        model: gpt-5.6-sol' \
        '    capabilities:' \
        '        codex:' \
        '            enabled: true' \
        '            provisioning:' \
        '                bin: codex' \
        >"$dir/.claude/project.yaml"
}

# ad_resolve <state-dir> [--flag NAME] <root>... -- runs the resolve verb.
ad_resolve() {
    local state="$1"
    shift
    local rootargs=()
    local flag=""
    local args=("$@")
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        if [[ "${args[$i]}" == "--flag" ]]; then
            flag="${args[$((i+1))]}"
            i=$((i+2))
        else
            rootargs+=(--root "${args[$i]}")
            i=$((i+1))
        fi
    done
    if [[ -n "$flag" ]]; then
        python3 "$AD_SCRIPT" resolve --state-dir "$state" "${rootargs[@]}" --flag "$flag"
    else
        python3 "$AD_SCRIPT" resolve --state-dir "$state" "${rootargs[@]}"
    fi
}

# ------------------------------------------------------------ sole assistant shortcut
ad_a="$(mktemp -d)"; ad_state="$(mktemp -d)"
ad_repo "$ad_a" jarvis
out="$(ad_resolve "$ad_state" "$ad_a")"
check_rc "sole assistant: resolves without any stored default" 0 $?
check "sole assistant: resolves to the sole candidate" "$ad_a	jarvis" "$out"
rm -rf "$ad_a" "$ad_state"

# ------------------------------------------------------------ flag beats sole beats default
ad_a="$(mktemp -d)"; ad_b="$(mktemp -d)"; ad_state="$(mktemp -d)"
ad_repo "$ad_a" jarvis
ad_repo "$ad_b" friday
python3 "$AD_SCRIPT" write-default friday --state-dir "$ad_state" >/dev/null
out="$(ad_resolve "$ad_state" --flag jarvis "$ad_a" "$ad_b")"
check_rc "flag beats stored default: exits 0" 0 $?
check "flag beats stored default: resolves to the FLAGGED candidate, not the default" \
    "$ad_a	jarvis" "$out"
rm -rf "$ad_a" "$ad_b" "$ad_state"

# ------------------------------------------------------------ stored default wins when no flag, 2+ candidates
ad_a="$(mktemp -d)"; ad_b="$(mktemp -d)"; ad_state="$(mktemp -d)"
ad_repo "$ad_a" jarvis
ad_repo "$ad_b" friday
python3 "$AD_SCRIPT" write-default friday --state-dir "$ad_state" >/dev/null
out="$(ad_resolve "$ad_state" "$ad_a" "$ad_b")"
check_rc "no flag, 2+ candidates: stored default resolves" 0 $?
check "no flag, 2+ candidates: resolves to the STORED DEFAULT candidate" "$ad_b	friday" "$out"
rm -rf "$ad_a" "$ad_b" "$ad_state"

# ------------------------------------------------------------ alias matching (flag)
ad_a="$(mktemp -d)"; ad_b="$(mktemp -d)"; ad_state="$(mktemp -d)"
ad_repo "$ad_a" jarvis j
ad_repo "$ad_b" friday
out="$(ad_resolve "$ad_state" --flag j "$ad_a" "$ad_b")"
check_rc "alias matching: flag matching an ALIAS resolves" 0 $?
check "alias matching: --flag j resolves to jarvis (whose alias is j)" "$ad_a	jarvis" "$out"
rm -rf "$ad_a" "$ad_b" "$ad_state"

# ------------------------------------------------------------ alias matching (stored default)
ad_a="$(mktemp -d)"; ad_b="$(mktemp -d)"; ad_state="$(mktemp -d)"
ad_repo "$ad_a" jarvis j
ad_repo "$ad_b" friday
python3 "$AD_SCRIPT" write-default j --state-dir "$ad_state" >/dev/null
out="$(ad_resolve "$ad_state" "$ad_a" "$ad_b")"
check_rc "alias matching: stored default matching an ALIAS resolves" 0 $?
check "alias matching: stored default 'j' resolves to jarvis" "$ad_a	jarvis" "$out"
rm -rf "$ad_a" "$ad_b" "$ad_state"

# ------------------------------------------------------------ case-insensitive matching
ad_a="$(mktemp -d)"; ad_b="$(mktemp -d)"; ad_state="$(mktemp -d)"
ad_repo "$ad_a" jarvis
ad_repo "$ad_b" friday
out="$(ad_resolve "$ad_state" --flag JARVIS "$ad_a" "$ad_b")"
check_rc "case-insensitive matching: --flag JARVIS resolves" 0 $?
check "case-insensitive matching: uppercase flag still matches lowercase stored name" \
    "$ad_a	jarvis" "$out"
rm -rf "$ad_a" "$ad_b" "$ad_state"

# ------------------------------------------------------------ missing default -> error LISTS candidates
ad_a="$(mktemp -d)"; ad_b="$(mktemp -d)"; ad_state="$(mktemp -d)"
ad_repo "$ad_a" jarvis
ad_repo "$ad_b" friday
python3 "$AD_SCRIPT" write-default nobody-by-this-name --state-dir "$ad_state" >/dev/null
out="$(ad_resolve "$ad_state" "$ad_a" "$ad_b" 2>&1)"
rc=$?
check_rc "missing default: resolution fails (non-zero rc)" 1 "$rc"
check "missing default: error names the stale stored default" \
    "local default 'nobody-by-this-name' matches no discovered assistant" "$out"
check "missing default: error LISTS candidate jarvis" "jarvis" "$out"
check "missing default: error LISTS candidate friday" "friday" "$out"
rm -rf "$ad_a" "$ad_b" "$ad_state"

# ------------------------------------------------------------ no default set, 2+ candidates -> error LISTS candidates
ad_a="$(mktemp -d)"; ad_b="$(mktemp -d)"; ad_state="$(mktemp -d)"
ad_repo "$ad_a" jarvis
ad_repo "$ad_b" friday
out="$(ad_resolve "$ad_state" "$ad_a" "$ad_b" 2>&1)"
rc=$?
check_rc "no default, 2+ candidates: resolution fails" 1 "$rc"
check "no default, 2+ candidates: error says no local default set" "no local default set" "$out"
check "no default, 2+ candidates: error LISTS candidate jarvis" "jarvis" "$out"
check "no default, 2+ candidates: error LISTS candidate friday" "friday" "$out"
rm -rf "$ad_a" "$ad_b" "$ad_state"

# ------------------------------------------------------------ duplicate/colliding default -> error LISTS the colliders specifically
ad_a="$(mktemp -d)"; ad_b="$(mktemp -d)"; ad_c="$(mktemp -d)"; ad_state="$(mktemp -d)"
ad_repo "$ad_a" jarvis
ad_repo "$ad_b" jarvis
ad_repo "$ad_c" friday
python3 "$AD_SCRIPT" write-default jarvis --state-dir "$ad_state" >/dev/null
out="$(ad_resolve "$ad_state" "$ad_a" "$ad_b" "$ad_c" 2>&1)"
rc=$?
check_rc "colliding default: resolution fails" 1 "$rc"
check "colliding default: error says the default is ambiguous" \
    "local default 'jarvis' is ambiguous" "$out"
check "colliding default: error lists collider root $ad_a" "$ad_a" "$out"
check "colliding default: error lists collider root $ad_b" "$ad_b" "$out"
check_absent "colliding default: error does NOT list the uninvolved friday candidate" "friday" "$out"
rm -rf "$ad_a" "$ad_b" "$ad_c" "$ad_state"

# ------------------------------------------------------------ ambiguous flag (2 candidates share the flagged name/alias)
ad_a="$(mktemp -d)"; ad_b="$(mktemp -d)"; ad_state="$(mktemp -d)"
ad_repo "$ad_a" jarvis
ad_repo "$ad_b" jarvis
out="$(ad_resolve "$ad_state" --flag jarvis "$ad_a" "$ad_b" 2>&1)"
rc=$?
check_rc "ambiguous flag: resolution fails" 1 "$rc"
check "ambiguous flag: error says the flagged name is ambiguous" \
    "assistant name 'jarvis' is ambiguous" "$out"
rm -rf "$ad_a" "$ad_b" "$ad_state"

# ------------------------------------------------------------ flag matching nothing
ad_a="$(mktemp -d)"; ad_state="$(mktemp -d)"
ad_repo "$ad_a" jarvis
out="$(ad_resolve "$ad_state" --flag nobody "$ad_a" 2>&1)"
rc=$?
check_rc "flag matches nothing: resolution fails" 1 "$rc"
check "flag matches nothing: error names the flag and lists candidates" \
    "no assistant named 'nobody' — candidates: jarvis" "$out"
rm -rf "$ad_a" "$ad_state"

# ------------------------------------------------------------ stored file location: gitignored local state, never a tracked file
ad_a="$(mktemp -d)"
( cd "$ad_a" && git init -q . )
ad_repo "$ad_a" jarvis
bash "$SA_SCRIPT" --root "$ad_a" set-default jarvis >/dev/null 2>&1
bash "$PLUGIN/scripts/gitignore-sync.sh" "$ad_a/.gitignore" >/dev/null 2>&1
[[ -f "$ad_a/.claude/neural-view/assistant-default" ]] && r=yes || r=no
check "stored default: file exists under .claude/neural-view/" "yes" "$r"
if ( cd "$ad_a" && git check-ignore -q .claude/neural-view/assistant-default ); then
    r=ignored
else
    r=NOT-IGNORED
fi
check "stored default: git check-ignore confirms it is gitignored (never a tracked file)" "ignored" "$r"
check_absent "stored default: assistant-default never appears in project.yaml" \
    "assistant-default" "$(cat "$ad_a/.claude/project.yaml")"
rm -rf "$ad_a"

# ------------------------------------------------------------ atomic write: no partial/temp file left behind
ad_state="$(mktemp -d)"
python3 "$AD_SCRIPT" write-default jarvis --state-dir "$ad_state" >/dev/null
# count, not empty-expected substring match -- check() with "" passes
# unconditionally (grep -qF "" matches anything), so a leftover tmp file
# could never flip that form of the assertion to FAIL.
leftover_count="$(find "$ad_state" -maxdepth 1 -name '.assistant-default-tmp-*' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$leftover_count" == "0" ]]; then
    echo "ok   atomic write: no leftover tmp file after a successful write"
else
    echo "FAIL atomic write: $leftover_count leftover tmp file(s) after a successful write"
    fails=$((fails + 1))
fi
content="$(cat "$ad_state/assistant-default")"
check "atomic write: final file content is the stripped name" "jarvis" "$content"
rm -rf "$ad_state"

# ------------------------------------------------------------ OSError degradation: unwritable state dir -> clean error, no traceback
ad_ro="$(mktemp -d)"
chmod 555 "$ad_ro"
ad_unwritable_target="$ad_ro/neural-view-state"
out="$(python3 "$AD_SCRIPT" write-default jarvis --state-dir "$ad_unwritable_target" 2>&1)"
rc=$?
chmod 755 "$ad_ro"
check_rc "OSError degradation (write): unwritable parent exits non-zero" 1 "$rc"
check "OSError degradation (write): clean STORE FAIL line naming the path" \
    "STORE FAIL: cannot write local default to $ad_unwritable_target/assistant-default" "$out"
check_absent "OSError degradation (write): no traceback leaked" "Traceback (most recent call last)" "$out"
rm -rf "$ad_ro"

# fixture-must-reach-fixed-path: prove the SAME fixture (state dir with an
# unreadable default file) drives read_default's own OSError path too.
ad_unreadable="$(mktemp -d)"
printf '%s\n' jarvis >"$ad_unreadable/assistant-default"
chmod 000 "$ad_unreadable/assistant-default"
out="$(python3 "$AD_SCRIPT" read-default --state-dir "$ad_unreadable" 2>&1)"
rc=$?
chmod 644 "$ad_unreadable/assistant-default"
check_rc "OSError degradation (read): unreadable default file exits non-zero" 1 "$rc"
check "OSError degradation (read): clean STORE FAIL line naming the path" \
    "STORE FAIL: cannot read local default from $ad_unreadable/assistant-default" "$out"
check_absent "OSError degradation (read): no traceback leaked" "Traceback (most recent call last)" "$out"
rm -rf "$ad_unreadable"

# ------------------------------------------------------------ no candidates at all
ad_state="$(mktemp -d)"
out="$(python3 "$AD_SCRIPT" resolve --state-dir "$ad_state" 2>&1)"
rc=$?
check_rc "no candidates: resolution fails" 1 "$rc"
check "no candidates: error is specific (not a generic default-missing message)" \
    "no assistants discovered" "$out"
rm -rf "$ad_state"

# ------------------------------------------------------------ existing set-default CLI surface stays unchanged (single source of truth)
ad_a="$(mktemp -d)"
ad_repo "$ad_a" jarvis
sa_out="$(bash "$SA_SCRIPT" --root "$ad_a" set-default jarvis 2>&1)"
check_rc "setup.py wiring: set-default still exits 0" 0 $?
case "$sa_out" in
    "$ad_a"/.claude/neural-view/*) r=under-local-state ;;
    *) r="WRONG: $sa_out" ;;
esac
check "setup.py wiring: set-default still writes under .claude/neural-view/" "under-local-state" "$r"
content="$(cat "$ad_a/.claude/neural-view/assistant-default" 2>/dev/null)"
check "setup.py wiring: set-default's file content is unchanged (name, via default_store now)" "jarvis" "$content"
rm -rf "$ad_a"
