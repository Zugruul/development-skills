#!/usr/bin/env bash
# section-board-ensure-issue.sh -- sourced by run-tests.sh; do not run standalone.
# Task #565: board.sh ensure-issue gives every orchestrator PR an issue first.
# The real board.sh add runs against a fake gh (no stub board.sh, no production override).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== board.sh ensure-issue (fake gh: REST-only lookup, exact call budget) =="

EIB="$(mktemp -d)"; mkdir -p "$EIB/.claude" "$EIB/.neural-network"
cp "$FIX/valid.project.yaml" "$EIB/.neural-network/project.yaml"
EIH="$(mktemp -d)"
# Fake gh: logs each call (one line) to $EI_LOG.
#  GET repos/R/issues/N : $EI_ISSUES lists existing numbers; "N:closed" = closed issue, "N:pr" = a pull request.
#                         EI_ID_ERR=1 -> non-404 failure; absent -> 404 (exit 1).
#  GET repos/R/pulls    : prints $EI_PULLS (JSON); EI_PULLS_FAIL=1 -> exit 1.
#  PATCH repos/R/issues/N -F body=@F : copies F to $EI_BODY_OUT.
#  issue create / project item-add / item-list / item-edit : just enough for board.sh add.
#  EI_CREATE=fail|ratelimit -> issue create fails; EI_NEVER_VISIBLE=1 -> item never shows (add queues).
#  EI_WARN=1 -> every successful api call also writes a warning line on stderr.
# NOTE: the error wordings ("gh: Not Found (HTTP 404)", "gh: Bad Gateway (HTTP 502)", "API rate limit
# exceeded") are RECONSTRUCTED from gh's usual output, not captured from a live call.
cat >"$EIH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >>"$EI_LOG"
warn() { [[ "${EI_WARN:-}" == 1 ]] && echo "gh: warning: a new release is available" >&2; return 0; }
case "$1" in
api)
    case "$*" in
        *"-X PATCH"*)
            for a in "$@"; do [[ "$a" == body=@* ]] && cp "${a#body=@}" "$EI_BODY_OUT"; done
            warn; exit 0 ;;
        *"repos/"*"/pulls"*)
            if [[ "${EI_PULLS_FAIL:-}" == 1 ]]; then echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; fi
            warn; cat "$EI_PULLS" 2>/dev/null || echo "[]"; exit 0 ;;
        *"repos/"*"/issues/"*)
            last="${!#}"; n="${last##*/}"
            if [[ "${EI_ID_ERR:-}" == 1 ]]; then echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; fi
            for e in ${EI_ISSUES:-}; do
                if [[ "${e%%:*}" == "$n" ]]; then
                    st=open; extra=""
                    [[ "$e" == *:closed ]] && st=closed
                    [[ "$e" == *:pr ]] && extra=', "pull_request": {"url": "x"}'
                    warn; echo "{\"number\": $n, \"state\": \"$st\"$extra}"; exit 0
                fi
            done
            echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
        "api graphql"*) exec python3 "$GH_GQL_ADAPTER" "$0" "$@" ;;
        *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
    esac ;;
issue)
    case "${EI_CREATE:-ok}" in
        fail) echo "fake gh: validation failed" >&2; exit 1 ;;
        ratelimit) echo "gh: API rate limit exceeded for user" >&2; exit 1 ;;
    esac
    echo "https://github.com/fixture-owner/fixture-project/issues/${EI_NUM:-77}" ;;
project)
    case "$2" in
        item-add) ;;
        item-list)
            if [[ "${EI_ITEMLIST_FAIL:-}" == 1 ]]; then echo "fake gh: boom (HTTP 500)" >&2; exit 1; fi
            if [[ "${EI_NEVER_VISIBLE:-}" == 1 ]]; then echo '{"items":[]}'
            else echo "{\"items\":[{\"id\":\"ITEM_${EI_NUM:-77}\",\"content\":{\"number\":${EI_NUM:-77}}}]}"; fi ;;
        item-edit) if [[ "${EI_FAIL_EDIT:-}" == 1 ]]; then echo "fake gh: edit boom" >&2; exit 1; fi; echo edited ;;
        *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
    esac ;;
*) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$EIH/gh"
export EI_LOG="$EIB/calls.log" EI_PULLS="$EIB/pulls.json" EI_BODY_OUT="$EIB/body.out"
R=fixture-owner/fixture-project
_ei() { # args... -> "<stdout>|rc=N"; stderr to $EIB/err.txt (and appended to allerr.txt)
    (cd "$EIB" && PATH="$EIH:$PATH" bash "$PLUGIN/scripts/board.sh" ensure-issue "$@" 2>"$EIB/err.txt"; echo "|rc=$?")
    cat "$EIB/err.txt" >>"$EIB/allerr.txt"
}
_reset() {
    : >"$EI_LOG"; : >"$EIB/err.txt"; rm -f "$EI_BODY_OUT"; echo "[]" >"$EI_PULLS"
    unset EI_ITEMLIST_FAIL EI_FAIL_EDIT EI_ISSUES EI_ID_ERR EI_PULLS_FAIL EI_CREATE EI_NEVER_VISIBLE EI_WARN EI_NUM
}
so() { printf '%s' "${out%%|rc=*}"; }   # stdout of the last _ei (trailing newline stripped)
rcof() { printf '%s' "${out##*|rc=}"; }
calls() { grep -c . "$EI_LOG" | tr -d ' '; }
apis() { grep -c '^api ' "$EI_LOG" | tr -d ' '; }
creates() { grep -c '^issue create' "$EI_LOG" | tr -d ' '; }
patches() { grep -c '^api -X PATCH' "$EI_LOG" | tr -d ' '; }
err() { cat "$EIB/err.txt"; }
is() { [[ "$(so)" == "$1" ]] && echo 0 || echo 1; }

# 1. branch id exists: 1 REST GET, nothing created
_reset; export EI_ISSUES="42"
out="$(_ei --title "t" --for-branch fx/42-some-slug)"
check_rc "ensure branch-id: stdout is exactly the number" 0 "$(is 42)"
check_rc "ensure branch-id: exits 0" 0 "$(rcof)"
check_rc "ensure branch-id: exactly 1 gh call" 1 "$(calls)"
check "ensure branch-id: REST GET of the issue" "api repos/$R/issues/42" "$(cat "$EI_LOG")"
check_rc "ensure branch-id: nothing created" 0 "$(creates)"
check "ensure branch-id: human line on stderr" "#42" "$(err)"

# 1b. branch id issue is closed: reused, with a warning
_reset; export EI_ISSUES="42:closed"
out="$(_ei --title "t" --for-branch fx/42-some-slug)"
check_rc "ensure closed id: still returns it" 0 "$(is 42)"
check "ensure closed id: warns it is closed" "closed" "$(err)"
check_rc "ensure closed id: exactly 1 gh call" 1 "$(calls)"

# 1c. id GET fails for a non-404 reason (network/rate limit): trust the branch id, never duplicate
_reset; export EI_ID_ERR=1
out="$(_ei --title "t" --for-branch fx/42-some-slug)"
check_rc "ensure id-GET error: trusts the branch id" 0 "$(is 42)"
check_rc "ensure id-GET error: exits 0" 0 "$(rcof)"
check_rc "ensure id-GET error: exactly 1 gh call" 1 "$(calls)"
check_rc "ensure id-GET error: nothing created" 0 "$(creates)"
check "ensure id-GET error: warns it was not confirmed" "could not confirm" "$(err)"

# 1d. the id resolves to a pull request, not an issue: rejected, falls through to the PR lookup
_reset; export EI_ISSUES="42:pr"; printf '%s\n' '[{"number": 9, "body": "Closes #31"}]' >"$EI_PULLS"
out="$(_ei --title "t" --for-branch fx/42-some-slug)"
check_rc "ensure id-is-PR: rejected, PR body Closes #31 used" 0 "$(is 31)"
check_rc "ensure id-is-PR: exactly 2 gh calls (id GET + pulls GET)" 2 "$(calls)"

# 2. branch id not found, open PR body says Closes #N: GET + pulls = 2 calls
_reset; printf '%s\n' '[{"number": 9, "body": "stuff\n\nCloses #31\n"}]' >"$EI_PULLS"
out="$(_ei --title "t" --for-branch fx/99-gone)"
check_rc "ensure PR-closes: stdout is exactly the number" 0 "$(is 31)"
check_rc "ensure PR-closes: exactly 2 gh calls (issue GET + pulls GET)" 2 "$(calls)"
check "ensure PR-closes: pulls lookup uses -f head= (gh encodes it)" "api -X GET repos/$R/pulls -f head=fixture-owner:fx/99-gone -f state=open" "$(cat "$EI_LOG")"
check_rc "ensure PR-closes: nothing created" 0 "$(creates)"

# 2b. stderr noise on successful api calls must not break the JSON parse
_reset; export EI_WARN=1 EI_ISSUES="42"
out="$(_ei --title "t" --for-branch fx/42-some-slug)"
check_rc "ensure gh warning on stderr: JSON still parsed" 0 "$(is 42)"
_reset; export EI_WARN=1; printf '%s\n' '[{"number": 9, "body": "Fixes #12"}]' >"$EI_PULLS"
out="$(_ei --title "t" --for-branch hotfix-thing)"
check_rc "ensure gh warning on stderr: pulls JSON still parsed" 0 "$(is 12)"

# 3. non-pattern branch: skips the issue GET, 1 pulls call
_reset; printf '%s\n' '[{"number": 9, "body": "Fixes #12"}]' >"$EI_PULLS"
out="$(_ei --title "t" --for-branch hotfix-thing)"
check_rc "ensure non-pattern branch: PR Fixes #12 -> 12" 0 "$(is 12)"
check_rc "ensure non-pattern branch: exactly 1 gh call" 1 "$(calls)"

# 3b. PR body refs: <slug>#N (repo name) accepted; other repo's ref and fenced code ignored
_reset; printf '%s\n' '[{"number": 9, "body": "Part of fixture-project#55"}]' >"$EI_PULLS"
out="$(_ei --title "t" --for-branch hotfix-thing)"
check_rc "ensure qualified ref: fixture-project#55 -> 55" 0 "$(is 55)"
_reset; printf '%s\n' '[{"number": 9, "body": "see other-repo#66 only"}]' >"$EI_PULLS"
out="$(_ei --title "t" --for-branch hotfix-thing)"
check_rc "ensure other-repo ref: not used, creates instead" 0 "$(is 77)"
_reset
# shellcheck disable=SC2016  # literal markdown fence in JSON
printf '%s\n' '[{"number": 9, "body": "example:\n```\nCloses #99\n```\nno ref here"}]' >"$EI_PULLS"
out="$(_ei --title "t" --for-branch hotfix-thing)"
check_rc "ensure fenced ref: Closes #99 inside a code fence is ignored" 0 "$(is 77)"

# 3c. branch with URL-special characters goes through -f unmangled
_reset
out="$(_ei --title "t" --for-branch 'tool/a+b#c')"
check "ensure special branch: passed as -f head= value" "-f head=fixture-owner:tool/a+b#c -f state=open" "$(cat "$EI_LOG")"

# 4. nothing linked: creates inbound via the REAL board.sh add, prints its number
_reset
out="$(_ei --title "Tune grafana restart" --for-branch tool/grafana-restart --prio P1)"
check_rc "ensure create: stdout is exactly the new number" 0 "$(is 77)"
check_rc "ensure create: exits 0" 0 "$(rcof)"
check_rc "ensure create: exactly 1 REST lookup + 1 REST body PATCH" 2 "$(apis)"
check_rc "ensure create: exactly 1 gh issue create" 1 "$(creates)"
check "ensure create: issue created with the title" "--title Tune grafana restart" "$(cat "$EI_LOG")"
check_rc "ensure create: exactly 1 body PATCH" 1 "$(patches)"
check "ensure create: PATCH targets the new issue" "api -X PATCH repos/$R/issues/77" "$(cat "$EI_LOG")"
# shellcheck disable=SC2016  # literal backticks (markdown code span)
check "ensure create: default body is truthful (names branch and title)" 'Filed by board.sh ensure-issue for branch `tool/grafana-restart` / title `Tune grafana restart`' "$(cat "$EI_BODY_OUT")"
check_absent "ensure create: body does not claim a dedup search" "dedup" "$(cat "$EI_BODY_OUT")"
check "ensure create: prio P1 option id set on the card" "bbbb0002" "$(cat "$EI_LOG")"
check_absent "ensure create: no GraphQL from ensure-issue itself" "api graphql" "$(grep '^api ' "$EI_LOG")"

# 5. no --for-branch: no lookups; create + PATCH only
_reset
out="$(_ei --title "Config tweak")"
check_rc "ensure no branch: prints new number" 0 "$(is 77)"
check_rc "ensure no branch: exactly 1 REST call (no lookup, just the body PATCH)" 1 "$(apis)"
check "ensure no branch: default prio P2 option id set on the card" "bbbb0003" "$(cat "$EI_LOG")"

# 6. --body-file content becomes the issue body; a missing file warns and falls back to the default
_reset; printf 'why this exists\n' >"$EIB/body.md"
out="$(_ei --title "With body" --body-file "$EIB/body.md")"
check_rc "ensure body-file: still prints the number" 0 "$(is 77)"
check "ensure body-file: file content is the body" "why this exists" "$(cat "$EI_BODY_OUT")"
_reset
out="$(_ei --title "Missing body" --body-file "$EIB/nope.md")"
check_rc "ensure missing body-file: still creates and prints" 0 "$(is 77)"
check "ensure missing body-file: warns on stderr" "nope.md" "$(err)"
check "ensure missing body-file: default body used" "Filed by board.sh ensure-issue" "$(cat "$EI_BODY_OUT")"

# 7. titles containing #N must never be scraped as the issue number
_reset
out="$(_ei --title "Cherry-pick #540 from other branch")"
check_rc "ensure title with #540 on success: prints the NEW issue (77)" 0 "$(is 77)"
check "ensure title with #540: PATCH hits the new issue" "api -X PATCH repos/$R/issues/77" "$(cat "$EI_LOG")"
check_absent "ensure title with #540: never touches #540" "issues/540" "$(cat "$EI_LOG")"
_reset; export EI_CREATE=fail
out="$(_ei --title "Cherry-pick #540 from other branch")"
check_rc "ensure failed create with #540 title: stdout empty" 0 "$([[ -z "$(so)" ]] && echo 0 || echo 1)"
check_rc "ensure failed create with #540 title: exits 0" 0 "$(rcof)"
check_rc "ensure failed create with #540 title: no PATCH at all" 0 "$(patches)"
_reset; export EI_NEVER_VISIBLE=1 EI_NUM=78
out="$(_ei --title "Cherry-pick #540 queued")"
check_rc "ensure queued with #540 title: prints the queued issue (78)" 0 "$(is 78)"
check_rc "ensure queued: exits 0" 0 "$(rcof)"
check "ensure queued: says QUEUED on stderr" "QUEUED" "$(err)"
check "ensure queued: PATCH hits the created issue" "api -X PATCH repos/$R/issues/78" "$(cat "$EI_LOG")"
check_absent "ensure queued with #540 title: never touches #540" "issues/540" "$(cat "$EI_LOG")"

# 8. create fails (error and rate limit): never stops work, gives the path forward
for mode in fail ratelimit; do
    _reset; export EI_CREATE=$mode
    out="$(_ei --title "Cannot make")"
    check_rc "ensure create-$mode: stdout empty" 0 "$([[ -z "$(so)" ]] && echo 0 || echo 1)"
    check_rc "ensure create-$mode: exits 0 (caller continues)" 0 "$(rcof)"
    check "ensure create-$mode: says no issue could be created" "no issue could be created" "$(err)"
    check "ensure create-$mode: tells the caller to retry after the reset" "retry board.sh ensure-issue after the rate-limit reset" "$(err)"
    check "ensure create-$mode: then open the PR with Closes #N" "Closes #N" "$(err)"
    check "ensure create-$mode: commit the branch and keep working" "Keep working: commit the branch" "$(err)"
    check_rc "ensure create-$mode: no PATCH" 0 "$(patches)"
done

# 9. PR lookup exits non-zero: reported, falls through to create
_reset; export EI_PULLS_FAIL=1
out="$(_ei --title "t" --for-branch tool/x)"
check_rc "ensure lookup-fail: falls through to create" 0 "$(is 77)"
check "ensure lookup-fail: says PR lookup failed" "PR lookup failed" "$(err)"

# 10. usage and validation (exit 2, no gh calls)
_reset
out="$(_ei --for-branch x)"
check_rc "ensure usage: missing --title exits 2" 2 "$(rcof)"
check_rc "ensure usage: 0 gh calls" 0 "$(calls)"
out="$(_ei --title "t" --prio P9)"
check_rc "ensure bad --prio: exits 2" 2 "$(rcof)"
check "ensure bad --prio: names the valid priorities" "P0" "$(err)"
check_rc "ensure bad --prio: 0 gh calls" 0 "$(calls)"
out="$(_ei --title "$(printf 'a\nfiled inbound #5 [P1]')")"
check_rc "ensure newline in title: exits 2" 2 "$(rcof)"
check_rc "ensure newline in title: 0 gh calls" 0 "$(calls)"

# 13. add's other non-zero / odd paths (real add against the fake gh)
_reset; export EI_FAIL_EDIT=1
out="$(_ei --title "Edit fails")"
check_rc "ensure move/prio queued (#561): still prints the created issue" 0 "$(is 77)"
check_rc "ensure move/prio queued: exits 0" 0 "$(rcof)"
check "ensure move/prio queued (#561): says board placement is queued, never a failure" "board placement is queued" "$(err)"
check_rc "ensure ERROR move/prio failed: body PATCH on 77" 1 "$(patches)"
_reset; export EI_ITEMLIST_FAIL=1
out="$(_ei --title "Board read fails #540")"
check_rc "ensure DEFERRED (board read failed): prints the created issue" 0 "$(is 77)"
check_rc "ensure DEFERRED: exits 0" 0 "$(rcof)"
check_absent "ensure DEFERRED: never touches #540" "issues/540" "$(cat "$EI_LOG")"

# 14. scripts copy with a stub board.sh (no production override): canned add output
STUBS="$(mktemp -d)"; cp -R "$PLUGIN/scripts/." "$STUBS/"
cat >"$STUBS/board.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$EI_ADDLOG"
printf '%s\n' "$EI_ADD_OUT"
exit "${EI_ADD_RC:-0}"
STUB
export EI_ADDLOG="$EIB/add.log"
_st() { # config args... -> "<stdout>|rc=N" using the stub copy
    local cfg="$1"; shift
    (cd "$EIB" && PATH="$EIH:$PATH" bash "$STUBS/board-ensure-issue.sh" "$R" "$cfg" "$@" 2>"$EIB/err.txt"; echo "|rc=$?")
    cat "$EIB/err.txt" >>"$EIB/allerr.txt"
}
CFG="$EIB/.neural-network/project.yaml"
_reset; : >"$EI_ADDLOG"
export EI_ADD_OUT=$'QUEUED (rate-limited until 10:00): add-finish #9\nfiled inbound #77 [P2]'
out="$(_st "$CFG" --title "Stray queued line")"
check_rc "ensure stray add-finish QUEUED line: prints 77" 0 "$(is 77)"
check_absent "ensure stray add-finish QUEUED line: does not mislabel 77 as queued" "QUEUED" "$(err)"
export EI_ADD_OUT='QUEUED (gh error): item-add #81'
out="$(_st "$CFG" --title "Queued by gh error")"
check_rc "ensure QUEUED (gh error) item-add: prints 81" 0 "$(is 81)"
check "ensure QUEUED (gh error) item-add: says QUEUED" "QUEUED" "$(err)"
export EI_ADD_OUT='DEFERRED (board read failed, not a rate limit): add-finish #82 is kept in the queue; fix the error above, then run: board.sh flush' EI_ADD_RC=1
out="$(_st "$CFG" --title "Deferred")"
check_rc "ensure DEFERRED line: prints 82" 0 "$(is 82)"
export EI_ADD_RC=0

# 14b. default priority when P2 is not configured: the middle option, said on stderr
sed -e 's/P0:/Urgent:/' -e 's/P1:/High:/' -e 's/P2:/Normal:/' "$CFG" >"$EIB/prio-config.yaml"
export EI_ADD_OUT='filed inbound #77 [High]'; : >"$EI_ADDLOG"
out="$(_st "$EIB/prio-config.yaml" --title "Middle prio")"
check "ensure default prio: middle option passed to add" "add --type inbound Middle prio High" "$(cat "$EI_ADDLOG")"
check "ensure default prio: says which" "P2 is not configured; using High" "$(err)"

# 14c. unreadable config never stops work: warn and continue (exit 0)
export EI_ADD_OUT='filed inbound #77 [P0]'
out="$(_st "$EIB/does-not-exist.yaml" --title "No config")"
check_rc "ensure unreadable config: still creates and prints" 0 "$(is 77)"
check_rc "ensure unreadable config: exits 0" 0 "$(rcof)"
check "ensure unreadable config: clear stderr line" "could not read the board config" "$(err)"

# 14d. default body: title and branch in code spans (no @mention / #N cross-reference)
_reset
# shellcheck disable=SC2016  # literal backticks
out="$(_ei --title 'Ping @user about #540 `x`' --for-branch tool/z)"
check "ensure body: title sits in a code span" 'title `Ping @user about #540 '"'"'x'"'"'`' "$(cat "$EI_BODY_OUT")"

# 14e. ~~~ fences are ignored in PR bodies too
_reset
# shellcheck disable=SC2016  # literal fence
printf '%s\n' '[{"number": 9, "body": "e:\n~~~\nCloses #98\n~~~\nok"}]' >"$EI_PULLS"
out="$(_ei --title "t" --for-branch hotfix-thing)"
check_rc "ensure ~~~ fence: Closes #98 inside is ignored" 0 "$(is 77)"
rm -rf "$STUBS"

check_absent "ensure: no Python traceback on stderr in any case" "Traceback" "$(cat "$EIB/allerr.txt")"

# 11. no production test override left in the script
check_absent "ensure-issue script: no ENSURE_ISSUE_BOARD_SH override" "ENSURE_ISSUE_BOARD_SH" "$(cat "$PLUGIN/scripts/board-ensure-issue.sh")"

# 12. guard-pr-create block message + skills point at ensure-issue
GE="$(mktemp -d)"; ( cd "$GE" && git init -q . && git commit -q --allow-empty -m init && git branch -m fx/1-x )
mkdir -p "$GE/.neural-network"; cp "$FIX/valid.project.yaml" "$GE/.neural-network/project.yaml"
gout="$(python3 -c 'import json; print(json.dumps({"tool_input":{"command":"gh pr create --title t --body nothing"}}))' | (cd "$GE" && bash "$PLUGIN/scripts/guard-pr-create.sh" 2>&1); true)"
check "guard-pr-create: block message points at board.sh ensure-issue" "board.sh ensure-issue" "$gout"
gout2="$(python3 -c 'import json; print(json.dumps({"tool_input":{"command":"gh pr create --title t"}}))' | (cd "$GE" && bash "$PLUGIN/scripts/guard-pr-create.sh" 2>&1); true)"
check "guard-pr-create: no-body block also points at ensure-issue" "board.sh ensure-issue" "$gout2"
for sk in build-next implement-task; do
    check "skill $sk: every orchestrator PR goes through ensure-issue" "board.sh\" ensure-issue" "$(cat "$PLUGIN/skills/$sk/SKILL.md")"
    check "skill $sk: local direct merge references #N in subject" "merge commit subject" "$(cat "$PLUGIN/skills/$sk/SKILL.md")"
    check "skill $sk: path forward when no issue can be created" "retry board.sh ensure-issue after the rate-limit reset" "$(cat "$PLUGIN/skills/$sk/SKILL.md")"
done
check "spec delta exists" "ensure-issue" "$(cat "$PLUGIN/../../docs/spec-deltas/565.md" 2>&1)"
check "spec delta: path forward when no issue can be created" "retry board.sh ensure-issue after the rate-limit reset" "$(cat "$PLUGIN/../../docs/spec-deltas/565.md" 2>&1)"
