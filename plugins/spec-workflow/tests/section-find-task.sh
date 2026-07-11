#!/usr/bin/env bash
# section-find-task.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== board.sh issues verb + find-task pipeline (SW-002) =="
FTD="$(mktemp -d)"; mkdir -p "$FTD/.claude"
cp "$FIX/valid.project.yaml" "$FTD/.claude/project.yaml"
FTGH="$(mktemp -d)"
cat >"$FTGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
    "issue list")
        if [[ "${FAKE_GH_ISSUES_FAIL:-0}" == "1" ]]; then
            echo "fake gh: issue list boom" >&2
            exit 1
        fi
        cat <<'JSON'
[
  {"number": 21, "title": "Add dark mode toggle to settings page", "body": "Let users switch between light and dark themes from the settings screen.", "state": "OPEN"},
  {"number": 22, "title": "Fix login button color on mobile safari", "body": "The submit button on the login form renders with the wrong background color in mobile Safari.", "state": "OPEN"},
  {"number": 23, "title": "Improve search relevance ranking algorithm", "body": "Search results for common queries are not well ordered; boost exact title matches.", "state": "CLOSED"}
]
JSON
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$FTGH/gh"

out="$(cd "$FTD" && PATH="$FTGH:$PATH" bash "$PLUGIN/scripts/board.sh" issues 2>&1; echo "rc=$?")"
check "issues verb: exits 0 on success" "rc=0" "$out"
check "issues verb: output is the issues-wrapped JSON shape" '"issues"' "$out"
check "issues verb: OPEN issue present with title" "Add dark mode toggle to settings page" "$out"
check "issues verb: CLOSED issue status carried through" "CLOSED" "$out"

# full pipeline: feed board.sh issues output into similar.py via SIMILAR_ISSUES_FILE
# and confirm a known query ranks the right issue first.
FTPIPE="$(mktemp)"
(cd "$FTD" && PATH="$FTGH:$PATH" bash "$PLUGIN/scripts/board.sh" issues) >"$FTPIPE"
pipe_out="$(SIMILAR_ISSUES_FILE="$FTPIPE" python3 "$PLUGIN/scripts/similar.py" "$FTD" "Add dark mode toggle to settings page")"
first_line="$(head -1 <<<"$pipe_out")"
check "pipeline: board.sh issues -> similar.py ranks the exact-title issue first" "#21" "$first_line"
check "pipeline: exact-title match is high tier" "high" "$first_line"
rm -f "$FTPIPE"

# gh failure: non-zero, actionable error, no partial/garbage JSON on stdout
out="$(cd "$FTD" && PATH="$FTGH:$PATH" FAKE_GH_ISSUES_FAIL=1 bash "$PLUGIN/scripts/board.sh" issues 2>&1; echo "rc=$?")"
check "issues verb: gh failure exits nonzero" "rc=1" "$out"
check "issues verb: gh failure -- actionable error" "ERROR:" "$out"
check_absent "issues verb: gh failure -- no partial issues JSON on stdout" '"issues"' "$out"

rm -rf "$FTD" "$FTGH"

