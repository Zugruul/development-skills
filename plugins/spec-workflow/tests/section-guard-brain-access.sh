#!/usr/bin/env bash
# section-guard-brain-access.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/hookjson/hookjsonpy/hookjson_named)
# and set HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file
# assumes those are already in scope. Mirrors section-gate-core.sh's
# hook-testing technique (pipe a hook-JSON payload into the script on
# stdin, capture stdout+stderr and rc).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== guard-brain-access hook (#237, CDX-031 gap #5) =="
GUARD="$PLUGIN/scripts/guard-brain-access.sh"

# 1. Read on a brain note -> blocked, actionable message naming brain.sh.
out="$(hookjson_named Read file_path ".claude/identities/dev/brain/notes/x.md" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "Read of brain note blocked" "BLOCKED" "$out"
check "Read block names brain.sh" "brain.sh" "$out"
check "Read block exit code 2" "rc=2" "$out"

# 2. Read on ROLE.md -> allowed (regression: always-legitimate verbatim read).
out="$(hookjson_named Read file_path ".claude/identities/dev/ROLE.md" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "Read of ROLE.md allowed" "rc=0" "$out"

# 3. Read on DIRECTORY.md -> allowed.
out="$(hookjson_named Read file_path ".claude/identities/DIRECTORY.md" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "Read of DIRECTORY.md allowed" "rc=0" "$out"

# 4. Bash cat of a brain file -> blocked.
out="$(hookjsonpy 'cat .claude/identities/reviewer/brain/links.json' | bash "$GUARD" 2>&1; echo "rc=$?")"
check "Bash cat of brain file blocked" "rc=2" "$out"
check "Bash cat block names brain.sh" "brain.sh" "$out"

# 5. Bash invoking brain.sh recall ... -> allowed (the sanctioned interface).
out="$(hookjsonpy 'bash brain.sh recall dev --paths "x/**"' | bash "$GUARD" 2>&1; echo "rc=$?")"
check "Bash brain.sh recall allowed" "rc=0" "$out"

# 6. Bash find .claude -iname '*brain*' -> allowed (discovery only, no dump).
out="$(hookjsonpy "find .claude -iname '*brain*'" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "Bash find discovery allowed" "rc=0" "$out"

# 7. Bash grep -r "foo" . (repo-wide, not brain-targeted) -> allowed.
out="$(hookjsonpy 'grep -r "foo" .' | bash "$GUARD" 2>&1; echo "rc=$?")"
check "Bash repo-wide grep allowed" "rc=0" "$out"

# 8. Bash bash -c "cat .../brain/notes/x.md" (wrapped) -> blocked, same
# recursion handling as guard-board-move.sh.
BASHC_CAT='bash -c "cat .claude/identities/dev/brain/notes/x.md"'
out="$(hookjsonpy "$BASHC_CAT" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "bash -c wrapped cat of brain file blocked" "rc=2" "$out"

# 8b. python3/node one-liner with the brain path embedded MID-TOKEN inside
# interpreter source (not preceded by a literal "/", not at token start) ->
# still blocked. Regression for a reported false-negative: BRAIN_RE is
# anchored (?:^|/) for the Read/DUMP_CMDS branches, which is correct there
# since the path is its own shlex token, but a python3/node one-liner is ONE
# token containing the whole source string, so the anchor must not apply.
PY_ONELINER="$(python3 -c '
import json
cmd = "python3 -c \"print(open(\x27.claude/identities/dev/brain/links.json\x27).read())\""
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}))
')"
out="$(printf '%s' "$PY_ONELINER" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "python3 one-liner with mid-token brain path blocked" "rc=2" "$out"

# 8d. pathlib.Path(...).read_text()/.read_bytes() is an idiomatic content
# dump that contains neither "open(" nor "readFile" -- the has_open gate must
# not require either literal; a bare brain-path literal in a python3/node
# one-liner's argv is suspicious enough on its own (pass-2 review finding).
PATHLIB_ONELINER="$(python3 -c '
import json
cmd = "python3 -c \"import pathlib; print(pathlib.Path(\x27.claude/identities/dev/brain/notes/x.md\x27).read_text())\""
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}))
')"
out="$(printf '%s' "$PATHLIB_ONELINER" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "python3 pathlib .read_text() one-liner with brain path blocked" "rc=2" "$out"

NODE_ONELINER="$(python3 -c '
import json
cmd = "node -e \"console.log(require(\x27fs\x27).readFileSync(\x27.claude/identities/dev/brain/notes/x.md\x27,\x27utf8\x27))\""
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}))
')"
out="$(printf '%s' "$NODE_ONELINER" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "node one-liner with mid-token brain path blocked" "rc=2" "$out"

# 8c. Regression: an UNRELATED python3 one-liner (open(), but no brain path
# anywhere) stays allowed -- the loosened mid-token match must not over-block.
UNRELATED_PY="$(python3 -c '
import json
cmd = "python3 -c \"print(open(\x27README.md\x27).read())\""
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}))
')"
out="$(printf '%s' "$UNRELATED_PY" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "unrelated python3 one-liner (no brain path) allowed" "rc=0" "$out"

# 9. Unrelated tool_name values (Write/Edit/Grep) -> allowed unconditionally,
# regardless of path.
out="$(hookjson_named Write file_path ".claude/identities/dev/brain/notes/x.md" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "Write tool_name allowed regardless of path" "rc=0" "$out"
out="$(hookjson_named Edit file_path ".claude/identities/dev/brain/notes/x.md" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "Edit tool_name allowed regardless of path" "rc=0" "$out"
out="$(hookjson_named Grep pattern ".claude/identities/dev/brain/notes/x.md" | bash "$GUARD" 2>&1; echo "rc=$?")"
check "Grep tool_name allowed regardless of path" "rc=0" "$out"

# 10. Hook payload with no tool_name field at all (old-style hookjson()
# output) -> treated as Bash; guard-board-move.sh's own tests on the same
# matcher stay green and unaffected by this new script's addition.
out="$(hookjson 'bash board.sh move 7 \"In review\"' | bash "$GUARD" 2>&1; echo "rc=$?")"
check "no tool_name field treated as Bash, non-brain command allowed" "rc=0" "$out"
out="$(hookjson 'cat .claude/identities/dev/brain/notes/x.md' | bash "$GUARD" 2>&1; echo "rc=$?")"
check "no tool_name field treated as Bash, brain-dump command blocked" "rc=2" "$out"
