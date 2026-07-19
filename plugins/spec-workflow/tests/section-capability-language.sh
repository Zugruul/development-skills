#!/usr/bin/env bash
# section-capability-language.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: same as section-skill-contracts.sh -- the runner already defines
# set -uo pipefail and has sourced _lib.sh (check/check_rc/check_absent/
# lifecycle_start/_rand_port) and set HERE/PLUGIN/FIX/fails/flaky before
# sourcing this file.
#
# CDX-010 (#180, SPEC-CODEX-COMPAT.md §7.1): the 9 skills that used to name
# `AskUserQuestion` directly in shared prose now describe structured input
# in capability language ("the host's structured-input facility"), so a
# Codex-side agent (no such tool) can still follow the instruction as
# written. Two complex skills (craft-spec, setup-project) isolate the exact
# Claude tool call into a dedicated references/host-claude.md adapter; the
# other 7 keep a single inline "(On Claude Code, this is the
# AskUserQuestion tool.)" note near their first capability-language mention.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }

PHRASE="the host's structured-input facility"

# stripfm FILE -- prints FILE's body with the leading YAML frontmatter block
# (the two "---" lines and everything between them) removed, so a check
# against the body never trips on the legitimate `allowed-tools:
# ...AskUserQuestion...` frontmatter line 5 of these skills carry. Verified
# against a real file below (auto-merge/SKILL.md) before being trusted for
# the assertions that follow.
#
# Deliberately awk+tail, not a sed line-range: `1,/^---$/d` is a
# numeric-start/regex-end range whose start line ALSO matches the end
# regex (frontmatter's line 1 IS `---`), and GNU sed vs BSD/macOS sed
# disagree on whether the end-check applies on the range's own start
# line -- BSD sed continues to the frontmatter's closing `---` (what this
# was written and tested against), GNU sed (this repo's CI runner) closes
# the range immediately and produces an empty body instead. awk's line
# counter and `tail -n +N` have no such same-line start/end ambiguity and
# behave identically on GNU and BSD.
stripfm() {
    local file="$1" end
    end="$(awk '/^---$/{c++; if (c==2) {print NR; exit}}' "$file" 2>/dev/null)"
    if [[ -n "$end" ]]; then
        tail -n +"$((end + 1))" "$file" 2>/dev/null
    else
        cat "$file" 2>/dev/null
    fi
}

echo "== capability-language rewrite: 9 AskUserQuestion skills (CDX-010, #180, SPEC-CODEX-COMPAT.md §7.1) =="

# Self-check stripfm() against a real artifact: auto-merge/SKILL.md keeps
# `AskUserQuestion` in its allowed-tools frontmatter line (out of scope,
# left unchanged) -- stripfm must remove that line while leaving the rest
# of the body intact, or every body-only check below would be meaningless.
AMFILE="$PLUGIN/skills/auto-merge/SKILL.md"
AM_RAW="$(cat "$AMFILE" 2>/dev/null)"
AM_STRIPPED="$(stripfm "$AMFILE")"
check "stripfm sanity: raw auto-merge/SKILL.md still has allowed-tools frontmatter" "allowed-tools: Bash, AskUserQuestion" "$AM_RAW"
check_absent "stripfm sanity: stripped auto-merge/SKILL.md body has no frontmatter block" "allowed-tools:" "$AM_STRIPPED"
check "stripfm sanity: stripped auto-merge/SKILL.md body still has its heading" "# Auto-merge mode" "$AM_STRIPPED"

# Simple skills: exactly ONE literal AskUserQuestion mention survives in the
# body -- inside a single inline Claude-only note, not required for a
# Codex-side agent to follow the instruction (the capability-language
# sentence carries the actual instruction). Complex skills push the literal
# tool name out of the body entirely, into references/host-claude.md.
SIMPLE_SKILLS="auto-merge build-next pr-review-model agent-identities concurrency ask-identity create-inbound"
COMPLEX_SKILLS="craft-spec setup-project"

for skill in $SIMPLE_SKILLS $COMPLEX_SKILLS; do
    f="$PLUGIN/skills/$skill/SKILL.md"
    body="$(stripfm "$f")"
    check "$skill SKILL.md body uses capability language for structured input" "$PHRASE" "$body"
done

for skill in $SIMPLE_SKILLS; do
    f="$PLUGIN/skills/$skill/SKILL.md"
    body="$(stripfm "$f")"
    n="$(grep -oF 'AskUserQuestion' <<<"$body" | wc -l | tr -d ' ')"
    if [[ "$n" -eq 1 ]]; then
        echo "ok   $skill SKILL.md body names AskUserQuestion exactly once (the inline Claude note)"
    else
        echo "FAIL $skill SKILL.md body should name AskUserQuestion exactly once (inline note), found $n"
        fails=$((fails + 1))
    fi
    check "$skill SKILL.md carries the inline Claude-note pattern" "On Claude Code, this is the AskUserQuestion tool." "$body"
done

for skill in $COMPLEX_SKILLS; do
    f="$PLUGIN/skills/$skill/SKILL.md"
    body="$(stripfm "$f")"
    check_absent "$skill SKILL.md body never names AskUserQuestion (isolated to the adapter)" "AskUserQuestion" "$body"
    check "$skill SKILL.md body points at the Claude Code adapter" "references/host-claude.md" "$body"
    adapter="$PLUGIN/skills/$skill/references/host-claude.md"
    if [[ -f "$adapter" ]]; then echo "ok   $skill/references/host-claude.md exists"; else echo "FAIL $skill/references/host-claude.md missing"; fails=$((fails + 1)); fi
    abody="$(cat "$adapter" 2>/dev/null)"
    check "$skill/references/host-claude.md names the literal AskUserQuestion tool" "AskUserQuestion" "$abody"
done

echo "== preserved constraints survive the rewrite (per-skill, verbatim or near-verbatim) =="

AMBODY="$(stripfm "$PLUGIN/skills/auto-merge/SKILL.md")"
check "auto-merge: option-ordering rule preserved (opposite of current state first)" "put the CURRENT state's opposite first" "$AMBODY"
check "auto-merge: pre-authorize-merges second ask preserved" "Pre-authorize merges?" "$AMBODY"

BNBODY2="$(stripfm "$PLUGIN/skills/build-next/SKILL.md")"
check "build-next: session-consent-gate single-ask preserved" "ask the human once per session" "$BNBODY2"
check "build-next: negative operating rule preserved, renamed to capability language" "does not use $PHRASE unless a hard permission denial or an explicit instruction requires human direction" "$BNBODY2"

PRBODY="$(stripfm "$PLUGIN/skills/pr-review-model/SKILL.md")"
check "pr-review-model: no-previews constraint preserved" "no previews" "$PRBODY"
check "pr-review-model: free-text Other affordance preserved" "via Other" "$PRBODY"

AIBODY="$(stripfm "$PLUGIN/skills/agent-identities/SKILL.md")"
check "agent-identities: header preserved" "header \"Identities\"" "$AIBODY"

CCBODY="$(stripfm "$PLUGIN/skills/concurrency/SKILL.md")"
check "concurrency: current-value-noted framing preserved" "current value noted in the question" "$CCBODY"

AKBODY="$(stripfm "$PLUGIN/skills/ask-identity/SKILL.md")"
check "ask-identity: exact 3-option wording preserved" "\"It is\" / \"It is not\" / \"I'm unsure\"" "$AKBODY"

CIBODY="$(stripfm "$PLUGIN/skills/create-inbound/SKILL.md")"
check "create-inbound: stop/continue semantics preserved (absent/no-answer => do not create)" "If the human is absent or does not answer, do NOT create" "$CIBODY"

CSBODY="$(stripfm "$PLUGIN/skills/craft-spec/SKILL.md")"
check "craft-spec: max-4-questions-per-round constraint preserved" "rounds of at most 4 questions" "$CSBODY"
check "craft-spec: sign-off iterate-until-approved loop preserved" "Iterate until approved" "$CSBODY"
CS_ADAPTER="$(cat "$PLUGIN/skills/craft-spec/references/host-claude.md" 2>/dev/null)"
check "craft-spec adapter: max-4-questions constraint present" "4 questions" "$CS_ADAPTER"

SPBODY="$(stripfm "$PLUGIN/skills/setup-project/SKILL.md")"
check "setup-project: Board header preserved" "header \"Board\"" "$SPBODY"
check "setup-project: Merging header preserved" "header \"Merging\"" "$SPBODY"
check "setup-project: Feedback header preserved" "header \"Feedback\"" "$SPBODY"
SP_ADAPTER="$(cat "$PLUGIN/skills/setup-project/references/host-claude.md" 2>/dev/null)"
check "setup-project adapter: Board/Merging/Feedback moments documented" "Board" "$SP_ADAPTER"
check "setup-project adapter: merge-policy sub-question documented" "mergeMethod" "$SP_ADAPTER"
