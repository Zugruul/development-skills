#!/usr/bin/env bash
# section-argument-semantics.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: same as section-skill-contracts.sh -- the runner already defines
# set -uo pipefail and has sourced _lib.sh (check/check_rc/check_absent/
# lifecycle_start/_rand_port) and set HERE/PLUGIN/FIX/fails/flaky before
# sourcing this file.
#
# CDX-013 (#183, SPEC-CODEX-COMPAT.md §7.4/§7.5): shared skill prose no
# longer relies on Claude-Code-only CLI mechanics -- an `ARGUMENTS:` header
# line (assumes the CLI already parsed/populated a variable) or a
# `!`-prefixed backtick span (Claude Code's CLI evaluates this as shell
# command substitution before the model ever sees the prompt; a Codex-side
# agent would see the literal, un-evaluated text instead). Both are rewritten
# into host-neutral prose usable by either host.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }

echo "== argument-semantics audit (CDX-013, #183, SPEC-CODEX-COMPAT.md §7.4/§7.5) =="

# stripfm FILE -- prints FILE's body with the leading YAML frontmatter block
# removed. Mirrors section-capability-language.sh's helper (awk+tail, not a
# sed line-range, for GNU/BSD sed portability -- see that file for the full
# rationale).
stripfm() {
    local file="$1" end
    end="$(awk '/^---$/{c++; if (c==2) {print NR; exit}}' "$file" 2>/dev/null)"
    if [[ -n "$end" ]]; then
        tail -n +"$((end + 1))" "$file" 2>/dev/null
    else
        cat "$file" 2>/dev/null
    fi
}

echo "-- §7.5: !\`...\` pre-start command-substitution sites (5 files) --"

PRESTART="Pre-start check — run this now, before anything else: \`bash \"../../scripts/preflight.sh\" --spec\`. If it prints \`PREFLIGHT FAIL\`, STOP — follow its instruction instead of continuing."

PRESTART_SKILLS="build-next implement-task next-task queue seed-board"
for skill in $PRESTART_SKILLS; do
    f="$PLUGIN/skills/$skill/SKILL.md"
    body="$(stripfm "$f")"
    # Match real Claude-CLI command substitution ("!`" immediately followed
    # by a command word, e.g. "!`bash ..."), not the seed-board:33 false
    # positive ("`!!`/`!`" -- a literal "!`" substring where the backtick
    # is immediately followed by "/" or whitespace, never a letter).
    if grep -qE '!`[A-Za-z]' <<<"$body"; then
        echo "FAIL $skill SKILL.md body still has a !\`...\` command-substitution span"
        fails=$((fails + 1))
    else
        echo "ok   $skill SKILL.md body never has a !\`...\` command-substitution span"
    fi
    check "$skill SKILL.md body has the explicit pre-start workflow step" "$PRESTART" "$body"
done

echo "-- §7.4: ARGUMENTS: header sites (2 files) --"

ABBODY="$(stripfm "$PLUGIN/skills/ask-brain/SKILL.md")"
check_absent "ask-brain SKILL.md body never has an ARGUMENTS: header" "ARGUMENTS:" "$ABBODY"
check "ask-brain SKILL.md body treats arguments as remainder of the request text" "Treat the remainder of the user's request (after the command name) as the question, verbatim." "$ABBODY"

AKBODY="$(stripfm "$PLUGIN/skills/ask-identity/SKILL.md")"
check_absent "ask-identity SKILL.md body never has an ARGUMENTS: header" "ARGUMENTS:" "$AKBODY"
check "ask-identity SKILL.md body treats arguments as remainder of the request text, role-first parsing preserved" "Treat the remainder of the user's request (after the command name) as \`<identity> <question...>\`: the first token names the role (\`dev\`, \`reviewer\`, \`orchestrator\`, or a repo-specific custom role like \`judge\`/\`player\`), everything after it is the question, verbatim." "$AKBODY"

echo "-- repo-wide belt-and-suspenders sweep (all plugins, not just spec-workflow) --"

BANG_HITS="$(grep -rlE '!`[A-Za-z]' "$HERE"/../../*/skills/*/SKILL.md 2>/dev/null || true)"
if [[ -z "$BANG_HITS" ]]; then
    echo "ok   repo-wide sweep: no !\`...\` command-substitution spans remain in any SKILL.md"
else
    echo "FAIL repo-wide sweep: !\`...\` command-substitution spans remain in: $BANG_HITS"
    fails=$((fails + 1))
fi

ARGS_HITS="$(grep -rln "ARGUMENTS:" "$HERE"/../../*/skills/*/SKILL.md 2>/dev/null || true)"
if [[ -z "$ARGS_HITS" ]]; then
    echo "ok   repo-wide sweep: no ARGUMENTS: headers remain in any SKILL.md"
else
    echo "FAIL repo-wide sweep: ARGUMENTS: headers remain in: $ARGS_HITS"
    fails=$((fails + 1))
fi

echo "-- explicitly out of scope: false-positive ! sites must remain untouched --"

SBBODY="$(cat "$PLUGIN/skills/seed-board/SKILL.md" 2>/dev/null)"
check "seed-board SKILL.md still explains preflight.sh's own log-line prefixes (not a command-substitution site)" "PREFLIGHT" "$SBBODY"

RTBODY="$(cat "$PLUGIN/skills/refine-task-ui/SKILL.md" 2>/dev/null)"
check "refine-task-ui SKILL.md still has its markdown image syntax (not a command-substitution site)" '![' "$RTBODY"
