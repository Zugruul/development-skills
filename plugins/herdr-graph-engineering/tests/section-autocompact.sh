#!/usr/bin/env bash
# section-autocompact.sh -- sourced by run-tests.sh; do not run standalone.
# Auto-compaction at 40% of the context for the orchestrator: autocompact.sh checks the running
# chat, prints how to turn it on for Claude Code, Codex and OpenCode, and writes a settings file
# only with --write (never the user's global ~/.claude settings). The compaction hooks keep firing
# on an automatic compaction, so the state survives it.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

A_TMP="$(mktemp -d)"
A_HOME="$A_TMP/home"
A_DIR="$A_TMP/orch"
mkdir -p "$A_HOME" "$A_DIR"
# ac: run autocompact.sh with a throwaway HOME and none of the compaction variables of this shell.
ac() { (cd "$A_DIR" && env -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE -u DISABLE_AUTO_COMPACT -u DISABLE_COMPACT -u CLAUDECODE HOME="$A_HOME" "$@"); }
AC="$PLUGIN/scripts/autocompact.sh"
empty() { if [ -z "$(ls -A "$1")" ]; then echo empty; else ls -A "$1"; fi; }

echo "== autocompact: check the running chat =="
out="$(ac env CLAUDECODE=1 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 bash "$AC" check 2>&1)"; rc=$?
check_rc "on at 40%: exit 0" 0 "$rc"
check "it says it is on" "AUTOCOMPACT ON 40%" "$out"
out="$(ac env CLAUDECODE=1 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=30 bash "$AC" check 2>&1)"; rc=$?
check_rc "lower than asked is still on" 0 "$rc"
check "and says the real value" "AUTOCOMPACT ON 30%" "$out"
out="$(ac env CLAUDECODE=1 bash "$AC" check 2>&1)"; rc=$?
check_rc "not set: exit 1" 1 "$rc"
check "it says it is off" "AUTOCOMPACT OFF" "$out"
check "it names the variable" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40" "$out"
check "it points at the print step" "autocompact.sh" "$out"
out="$(ac env CLAUDECODE=1 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80 bash "$AC" check 2>&1)"; rc=$?
check_rc "higher than asked: exit 1" 1 "$rc"
check "it says it compacts later than asked" "AUTOCOMPACT OFF" "$out"
out="$(ac env CLAUDECODE=1 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 DISABLE_AUTO_COMPACT=1 bash "$AC" check 2>&1)"; rc=$?
check_rc "auto-compaction disabled: exit 1" 1 "$rc"
check "it names what disables it" "DISABLE_AUTO_COMPACT" "$out"
out="$(ac env CLAUDECODE=1 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=25 bash "$AC" check --pct 25 2>&1)"; rc=$?
check_rc "--pct changes the target" 0 "$rc"
out="$(ac bash "$AC" check 2>&1)"; rc=$?
check_rc "outside Claude Code: exit 1" 1 "$rc"
check "it cannot tell there" "AUTOCOMPACT UNKNOWN" "$out"
out="$(ac bash "$AC" check --pct 0 2>&1)"; rc=$?
check_rc "--pct must be 1 to 100" 2 "$rc"
out="$(ac bash "$AC" check --pct abc 2>&1)"; rc=$?
check_rc "--pct must be a number" 2 "$rc"
out="$(ac bash "$AC" bogus 2>&1)"; rc=$?
check_rc "an unknown command is a usage error" 2 "$rc"

echo "== autocompact: print how, per client =="
out="$(ac bash "$AC" 2>&1)"; rc=$?
check_rc "print is the default and succeeds" 0 "$rc"
check "claude: launch the orchestrator with the variable" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40 claude" "$out"
check "claude: or a settings file for the orchestrator's folder" "$A_DIR/.claude/settings.local.json" "$out"
check "claude: the settings snippet" '"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "40"' "$out"
check "claude: how to write it" "--write" "$out"
check "codex: the token limit" "model_auto_compact_token_limit" "$out"
check "codex: 40% of a 400k window" "160000" "$(ac bash "$AC" print --window 400000 2>&1)"
check "opencode: keep 60% free" '"buffer": "60%"' "$out"
check "print writes nothing" "no" "$([ -e "$A_DIR/.claude" ] && echo yes || echo no)"
check "print never touches the home folder" "empty" "$(empty "$A_HOME")"
out="$(ac bash "$AC" print --pct 50 2>&1)"
check "--pct reaches every client" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 claude" "$out"
check "--pct reaches opencode" '"buffer": "50%"' "$out"

echo "== autocompact: --write, only to the orchestrator folder's local settings =="
SL="$A_DIR/.claude/settings.local.json"
out="$(ac bash "$AC" print --write 2>&1)"; rc=$?
check_rc "--write succeeds" 0 "$rc"
check "it says what it wrote" "SETTINGS WRITTEN" "$out"
check "the setting is in the file" "40" "$(jq -r '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$SL" 2>&1)"
check "it says when it applies" "next" "$out"
check "the home folder is untouched" "empty" "$(empty "$A_HOME")"
out="$(ac bash "$AC" print --write 2>&1)"; rc=$?
check_rc "writing again is fine" 0 "$rc"
check "and changes nothing" "ALREADY SET" "$out"
printf '{"permissions":{"allow":["Bash(ls)"]},"env":{"FOO":"1"}}\n' >"$SL"
out="$(ac bash "$AC" print --write 2>&1)"
check "it keeps the other settings" '["Bash(ls)"]' "$(jq -c '.permissions.allow' "$SL")"
check "it keeps the other env" "1" "$(jq -r '.env.FOO' "$SL")"
check "it adds the variable" "40" "$(jq -r '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$SL")"
check "it backs the file up first" "backup" "$out"
check "the backup is the old file" "1" "$(find "$A_DIR/.claude" -name 'settings.local.json.bak.*' | wc -l | tr -d ' ')"
printf 'not json' >"$SL"
out="$(ac bash "$AC" print --write 2>&1)"; rc=$?
check_rc "a broken settings file is refused" 1 "$rc"
check "and left as it was" "not json" "$(cat "$SL")"
out="$(ac bash "$AC" print --write --dir "$A_HOME" 2>&1)"; rc=$?
check_rc "the home folder is refused" 1 "$rc"
check "it says why" "global" "$out"
check "nothing is written there" "empty" "$(empty "$A_HOME")"
mkdir -p "$A_TMP/other"
out="$(ac bash "$AC" print --write --dir "$A_TMP/other" 2>&1)"; rc=$?
check_rc "--dir picks the folder" 0 "$rc"
check "the file is in that folder" "40" "$(jq -r '.env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE' "$A_TMP/other/.claude/settings.local.json" 2>&1)"

echo "== autocompact: the state survives an automatic compaction =="
HJ="$PLUGIN/hooks/hooks.json"
check "the pre-compact hook fires on automatic and manual compaction" "any" "$(jq -r '.hooks.PreCompact[0].matcher // "" | if . == "" or . == "*" then "any" else . end' "$HJ" 2>&1)"
check "the session-start hook fires after any compaction" "compact" "$(jq -r '.hooks.SessionStart[0].matcher' "$HJ" 2>&1)"

echo "== autocompact: the skill and the docs =="
orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: checks auto-compaction at the start" 'autocompact.sh" check' "$orch"
check "orchestrate: compacts at 40%" "40%" "$orch"
check "orchestrate: asks before --write" "--write" "$orch"
rd="$(cat "$PLUGIN/README.md")"
check "README: the Claude Code variable" "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" "$rd"
check "README: codex" "model_auto_compact_token_limit" "$rd"
check "README: opencode" "compaction" "$rd"
check "README: the script" "autocompact.sh" "$rd"

rm -rf "$A_TMP"
