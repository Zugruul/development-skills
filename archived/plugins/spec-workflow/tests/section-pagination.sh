#!/usr/bin/env bash
# section-pagination.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2030,SC2031  # scenarios deliberately set PATH/env inside $(...) subshells, one fake gh per scenario
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== board.sh pagination (SW-013: no silent 400/500-item truncation, SPEC 7.4) =="
PG="$(mktemp -d)"; mkdir -p "$PG/.claude" "$PG/.neural-network"
cp "$FIX/valid.project.yaml" "$PG/.neural-network/project.yaml"
PGH="$(mktemp -d)"
cat >"$PGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
_limit_of() { # extract the value following a --limit flag from "$@"
    local prev=""
    for a in "$@"; do
        if [[ "$prev" == "--limit" ]]; then printf '%s' "$a"; return 0; fi
        prev="$a"
    done
    printf '400'
}
_arg_of() { # _arg_of <key> "$@" -> value of the -f/-F key=value flag
    local key="$1" prev=""; shift
    for a in "$@"; do
        if [[ "$prev" == "-f" || "$prev" == "-F" ]] && [[ "$a" == "$key="* ]]; then printf '%s' "${a#"$key="}"; return 0; fi
        prev="$a"
    done
}
case "$1 $2" in
    "api graphql")
        # Field-name resolution (#544 review): one cheap query, names configurable per test.
        if [[ "$(_arg_of query "$@")" == *"fields(first"* ]]; then
            if [[ -n "${FAKE_GH_FIELDS_FAIL:-}" ]]; then
                printf 'HTTP/2.0 502 Bad Gateway\n\n<html>bad gateway</html>\n'; echo "gh: HTTP 502" >&2; exit 1
            fi
            [[ -n "${FAKE_GH_LOG:-}" ]] && echo "api graphql kind=fields" >>"$FAKE_GH_LOG"
            python3 -c "
import json, os
names = [n for n in os.environ.get('FAKE_GH_FIELDS', 'Status,Priority,Estimate').split(',') if n]
print('HTTP/2.0 200 OK'); print('X-Ratelimit-Remaining: 4000'); print()
print(json.dumps({'data': {'repositoryOwner': {'projectV2': {'fields': {'nodes': [{'name': n} for n in ['Title'] + names]}}}}}))
"
            exit 0
        fi
        # Slim cursor read (#544). Cursor is "cur<offset>"; pages are 100 nodes.
        # Every call is logged with its cursor so tests can prove no page is read twice.
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "api graphql after=$(_arg_of after "$@") $(_arg_of owner "$@") first=$(_arg_of first "$@")" >>"$FAKE_GH_LOG"
        [[ -n "${FAKE_GH_QUERY_LOG:-}" ]] && _arg_of query "$@" >>"$FAKE_GH_QUERY_LOG"
        n=$(( $(cat "${FAKE_GH_GQL_CALLCOUNT:-/dev/null}" 2>/dev/null || echo 0) + 1 ))
        [[ -n "${FAKE_GH_GQL_CALLCOUNT:-}" ]] && echo "$n" >"$FAKE_GH_GQL_CALLCOUNT"
        if [[ -n "${FAKE_GH_SCOPE_FROM:-}" && "$n" -ge "$FAKE_GH_SCOPE_FROM" ]]; then FAKE_GH_MODE=scope; fi
        case "${FAKE_GH_MODE:-}" in
            scope) printf 'HTTP/2.0 200 OK\n\n{"errors":[{"type":"INSUFFICIENT_SCOPES","message":"Your token has not been granted the required scopes to execute this query."}]}\n'
                   echo "gh: Your token has not been granted the required scopes" >&2; exit 1 ;;
            code-only) printf 'HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 0\n\n{"errors":[{"type":"X","code":"graphql_rate_limit","message":"Please slow down."}]}\n'; exit 1 ;;
            type-only) printf 'HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 0\n\n{"errors":[{"type":"RATE_LIMIT"}]}\n'; exit 1 ;;
            no-reset-header) printf 'HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 0\n\n{"errors":[{"type":"RATE_LIMIT","message":"API rate limit already exceeded for user ID 1."}]}\n'; exit 1 ;;
            date-retry) printf 'HTTP/2.0 403 Forbidden\nRetry-After: Wed, 21 Oct 2037 07:28:00 GMT\nX-Ratelimit-Remaining: 0\nX-Ratelimit-Reset: 1999999999\n\n{"message":"You have exceeded a secondary rate limit."}\n'; exit 1 ;;
            past-reset) printf 'HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 0\nX-Ratelimit-Reset: 1\n\n{"errors":[{"type":"RATE_LIMIT","message":"API rate limit already exceeded for user ID 1."}]}\n'; exit 1 ;;
        esac
        if [[ -n "${FAKE_GH_FAIL_AT_PAGE:-}" && "$n" == "$FAKE_GH_FAIL_AT_PAGE" ]]; then
            # a rate-limited rejection: headers (reset = now+600s) + the REAL error object, exit 1 like gh
            python3 -c "
import json, sys, time
print('HTTP/2.0 200 OK'); print('X-Ratelimit-Remaining: 0'); print('X-Ratelimit-Reset: %d' % (int(time.time()) + 600)); print()
print(json.dumps({'errors': [{'type': 'RATE_LIMIT', 'code': 'graphql_rate_limit', 'message': 'API rate limit already exceeded for user ID 12402908.'}]}))
"
            echo "gh: API rate limit already exceeded for user ID 12402908." >&2
            exit 1
        fi
        after="$(_arg_of after "$@")"; off=0
        [[ "$after" == cur* ]] && off="${after#cur}"
        Q="$(_arg_of query "$@")" CALLN="$n" python3 -c "
import json, os, sys
off, total, special, size = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
q, mode, calln = os.environ['Q'], os.environ.get('FAKE_GH_MODE', ''), int(os.environ['CALLN'])
fields = os.environ.get('FAKE_GH_FIELDS', 'Status,Priority,Estimate').split(',')
def has(kind):  # a field value is only returned when the query used the board's exact field name
    return any(f.lower() == kind and ('name: \"%s\"' % f) in q for f in fields)
end = min(off + size, total)
nodes = []
for i in range(off + 1, end + 1):
    special_hit = (i == special)
    nodes.append({'id': 'ITEM_PAGE2' if special_hit else 'ITEM_' + str(i),
                  'status': {'name': 'Backlog' if special_hit else 'Deployed'} if has('status') else None,
                  'priority': ({'name': 'P0' if special_hit else 'P2'}) if has('priority') else None,
                  'estimate': None,
                  'content': {'__typename': 'Issue', 'number': i, 'body': 'b', 'url': 'u',
                              'title': ('Task ' if special_hit else 'Filler ') + str(i),
                              'repository': {'nameWithOwner': 'fixture-owner/fixture-project'},
                              'labels': {'nodes': []}}})
has_next, cursor = end < total, 'cur%d' % end
if mode == 'emptynext': nodes, has_next, cursor = [], True, 'e%d' % calln
if mode == 'cycle': nodes, has_next, cursor = nodes[:1], True, 'AB'[calln % 2]
items = {'totalCount': total + int(os.environ.get('FAKE_GH_TOTAL_LIE', '0')), 'pageInfo': {'hasNextPage': has_next, 'endCursor': cursor}, 'nodes': nodes}
print('HTTP/2.0 200 OK'); print('X-Ratelimit-Remaining: 4000'); print()
print(json.dumps({'data': {'repositoryOwner': {'projectV2': {'items': items}}}}))
" "$off" "${FAKE_GH_TOTAL_ITEMS:-450}" "${FAKE_GH_SPECIAL_ITEM:-420}" "$(_arg_of first "$@" | sed 's/^$/100/')"
        ;;
    "api rate_limit")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "api rate_limit" >>"$FAKE_GH_LOG"
        echo "{\"resources\":{\"graphql\":{\"remaining\":${FAKE_GH_GRAPHQL_REMAINING:-4000},\"reset\":${FAKE_GH_REST_RESET:-1}}}}"
        ;;
    "project item-add")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "$*" >>"$FAKE_GH_LOG"
        echo '{}'
        ;;
    "project item-list")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "$*" >>"$FAKE_GH_LOG"
        echo "fake gh: project item-list costs 101 points/100 items and must not be used for board reads (#544)" >&2
        exit 1
        ;;
    "project item-edit")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "$*" >>"$FAKE_GH_LOG"
        if [[ -n "${FAKE_GH_EDIT_FAIL:-}" ]]; then echo "boom: edit failed" >&2; exit 1; fi
        echo "edited"
        ;;
    "issue create")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "$*" >>"$FAKE_GH_LOG"
        echo "https://github.com/fixture-owner/fixture-project/issues/777"
        ;;
    "issue list")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "$*" >>"$FAKE_GH_LOG"
        if [[ -n "${FAKE_GH_ISSUELIST_CALLCOUNT:-}" ]]; then
            n=$(( $(cat "$FAKE_GH_ISSUELIST_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
            echo "$n" >"$FAKE_GH_ISSUELIST_CALLCOUNT"
        fi
        limit="$(_limit_of "$@")"
        python3 -c "
import json, sys
limit, total, special = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
n = min(limit, total)
issues = []
for i in range(1, n + 1):
    if i == special:
        issues.append({'number': i, 'title': 'Task ' + str(i), 'body': 'x', 'state': 'OPEN'})
    else:
        issues.append({'number': i, 'title': 'Filler issue ' + str(i), 'body': 'x', 'state': 'OPEN'})
print(json.dumps(issues))
" "$limit" "${FAKE_GH_TOTAL_ISSUES:-450}" "${FAKE_GH_SPECIAL_ITEM:-420}"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$PGH/gh"

# scenario 1: list -- a >limit fixture (450 items, base page 400) proves the page-2 item
# (#420) is visible and NOT silently truncated, and the full 450-item count comes through.
LOGP1="$(mktemp)"; CCP1="$(mktemp)"; QLP1="$(mktemp)"
out="$(cd "$PG" && PATH="$PGH:$PATH" FAKE_GH_LOG="$LOGP1" FAKE_GH_GQL_CALLCOUNT="$CCP1" FAKE_GH_QUERY_LOG="$QLP1" \
    bash "$PLUGIN/scripts/board.sh" list 2>&1)"
check "list: page-2 item (#420) is present, not truncated at page-1's 400" $'Backlog\tP0\t#420\tTask 420' "$out"
linecount="$(wc -l <<<"$out" | tr -d ' ')"
check "list: all 450 items present -- no silent truncation" "450" "$linecount"
callsp1="$(cat "$CCP1")"
check "list: 450 items = exactly 5 cursor pages of 100 (hasNextPage is the exhaustion proof)" "5" "$callsp1"
check "list: every page read once (5 distinct cursors)" "5" "$(grep -o 'after=[^ ]*' "$LOGP1" | sort -u | wc -l | tr -d ' ')"
check "list: first page starts with an empty cursor" "api graphql after= " "$(grep -v kind=fields "$LOGP1" | head -1)"
check "list: exactly one cheap field-name resolution call, then 5 item pages (6 graphql calls)" "1 6" "$(grep -c 'kind=fields' "$LOGP1") $(grep -c '^api graphql' "$LOGP1")"
check "list: second page continues from the first page's endCursor" "after=cur100 " "$(grep -v kind=fields "$LOGP1" | sed -n 2p)"
check_absent "list: never falls back to the expensive gh project item-list" "project item-list" "$(cat "$LOGP1")"
check_absent "list: the query has no fieldValues(first:100) connection" "fieldValues(" "$(cat "$QLP1")"
check "list: the query uses fieldValueByName aliases" "fieldValueByName" "$(cat "$QLP1")"
check_absent "list: no separate owner-type lookup (users/orgs/api rate_limit) on a successful read" "api rate_limit" "$(cat "$LOGP1")"
check "list: user-owned and org-owned share one repositoryOwner query" "repositoryOwner" "$(cat "$QLP1")"

# scenario 2: next -- the page-2 item is the only Backlog item, so it must be picked
# (the picker only sees what board.sh hands it; this proves board.sh, not next.py, paginates)
out="$(cd "$PG" && PATH="$PGH:$PATH" bash "$PLUGIN/scripts/board.sh" next 2>&1)"
check "next: picks the page-2 item that a fixed 400-limit would have hidden" "=> PICK: #420" "$out"

# scenario 3: move (item_id()) -- resolves and edits an item whose id lives on page 2.
# This is the key regression: before pagination, item_id() silently returned empty for
# any item beyond the --limit ceiling and move failed with a generic bad-issue# error.
LOGP3="$(mktemp)"
# #234: pre-seed the comment-steering marker for #420 -- this scenario tests
# pagination's item_id() resolution, unrelated to #234.
printf '{"420": true}' >"$PG/.claude/board-comments-seen.json"
out="$(cd "$PG" && PATH="$PGH:$PATH" FAKE_GH_LOG="$LOGP3" bash "$PLUGIN/scripts/board.sh" move 420 "In progress" 2>&1; echo "rc=$?")"
check "move: resolves + edits a page-2 item id" "moved #420 -> In progress" "$out"
check "move: rc=0 resolving a page-2 item" "rc=0" "$out"
check "move: item-edit invoked with the page-2 item's real id" "project item-edit --id ITEM_PAGE2" "$(cat "$LOGP3")"

# scenario 4: issues -- gh issue list also paginates past its own page-1 ceiling. Uses a
# 900-item fixture (deliberately > the OLD hardcoded 500 ceiling) so a regression here
# proves real truncation, not just an incidental undercount.
LOGP4="$(mktemp)"; CCP4="$(mktemp)"
out="$(cd "$PG" && PATH="$PGH:$PATH" FAKE_GH_LOG="$LOGP4" FAKE_GH_ISSUELIST_CALLCOUNT="$CCP4" FAKE_GH_TOTAL_ISSUES=900 \
    bash "$PLUGIN/scripts/board.sh" issues 2>&1)"
check "issues: page-2 issue is present" '"number": 420' "$out"
issuecount="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["issues"]))' <<<"$out")"
check "issues: all 900 issues present -- no silent truncation past the old 500 ceiling" "900" "$issuecount"
callsp4="$(cat "$CCP4")"
if [[ "$callsp4" -ge 2 ]]; then echo "ok   issues: gh issue list was actually re-paged (>=2 calls)"
else echo "FAIL issues: expected >=2 gh issue list calls to exhaust 900 issues, got $callsp4"; fails=$((fails + 1)); fi

# scenario 5: hard-cap backstop (#544: counted in ITEMS now, a backstop only). Hitting the cap
# with hasNextPage still true = no exhaustion proof: warn on stderr (non-strict), WIP BLOCKED (strict).
out5="$(cd "$PG" && PATH="$PGH:$PATH" PAGINATE_HARD_CAP=200 bash "$PLUGIN/scripts/board.sh" list 2>&1 1>/dev/null)"
check "hard cap: warns on stderr when the cap is hit before exhaustion" "WARNING: hit pagination hard cap (200)" "$out5"
out5_stdout="$(cd "$PG" && PATH="$PGH:$PATH" PAGINATE_HARD_CAP=200 bash "$PLUGIN/scripts/board.sh" list 2>/dev/null)"
check_absent "hard cap: warning stays on stderr, doesn't corrupt stdout output" "WARNING" "$out5_stdout"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
out5s="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_HARD_CAP=200 gh_project_items_json 5 fixture-owner --strict 2>&1 >/dev/null; echo "rc=$?")"
check "hard cap (strict): fails closed with WIP BLOCKED" "WIP BLOCKED: pagination hard cap (200)" "$out5s"
check "hard cap (strict): returns 3" "rc=3" "$out5s"

# scenario 6: strict read, success: complete snapshot carries totalCount == items
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
out6="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" gh_project_items_json 5 fixture-owner --strict)"; rc6=$?
check "strict: complete read succeeds" "0" "$rc6"
check "strict: merged snapshot has all 450 items and a matching totalCount" "450 450" "$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["items"]), d["totalCount"])' <<<"$out6")"

# scenario 7: a failure on page 3 emits NOTHING from pages 1-2 (strict AND non-strict), rc != 0
for mode in "" "--strict"; do
    CC7="$(mktemp)"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
    out7="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/reset7" FAKE_GH_GQL_CALLCOUNT="$CC7" FAKE_GH_FAIL_AT_PAGE=3 gh_project_items_json 5 fixture-owner $mode 2>/dev/null; echo "rc=$?")"
    check "page-3 failure ($mode): stdout is empty -- no partial board" "rc=1" "$out7"
    check_absent "page-3 failure ($mode): earlier pages are not emitted" "ITEM_" "$out7"
    rm -f "$CC7"
done

# scenario 8: rate-limited read reports GitHub's REAL error + the reset from the response headers,
# without a second (gh api rate_limit) call, and stdout stays clean.
LOGP8="$(mktemp)"; CC8="$(mktemp)"; ERR8="$(mktemp)"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
out8="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/reset" FAKE_GH_LOG="$LOGP8" FAKE_GH_GQL_CALLCOUNT="$CC8" FAKE_GH_FAIL_AT_PAGE=1 gh_project_items_json 5 fixture-owner 2>"$ERR8"; echo "rc=$?")"
check "rate-limited read: nonzero exit, stdout empty" "rc=1" "$out8"
check "rate-limited read: stderr carries GitHub's real message" "API rate limit already exceeded for user ID 12402908" "$(cat "$ERR8")"
check "rate-limited read: stderr names the RATE_LIMIT type, not 'unknown owner type'" "RATE_LIMIT" "$(cat "$ERR8")"
check_absent "rate-limited read: no unknown-owner-type masking" "unknown owner type" "$(cat "$ERR8")"
check "rate-limited read: reset time is taken from the response headers" "resets" "$(cat "$ERR8")"
check_absent "rate-limited read: no extra gh api rate_limit call" "api rate_limit" "$(cat "$LOGP8")"
rm -f "$LOGP8" "$CC8" "$ERR8"

# scenario 9: board-queue recognises the REAL rate-limit error even while gh api rate_limit shows quota
# (two counters per token: the REST probe can report thousands remaining during a rejection) --
# move QUEUES, and its message uses the header reset (no 'unknown'), without probing.
LOGP9="$(mktemp)"; CC9="$(mktemp)"
printf '{"420": true}' >"$PG/.claude/board-comments-seen.json"
out9="$(cd "$PG" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/reset" FAKE_GH_LOG="$LOGP9" FAKE_GH_GQL_CALLCOUNT="$CC9" FAKE_GH_FAIL_AT_PAGE=1 FAKE_GH_GRAPHQL_REMAINING=4000 \
    bash "$PLUGIN/scripts/board.sh" move 420 "In progress" 2>&1; echo "rc=$?")"
check "move: real RATE_LIMIT read error queues the move though rate_limit shows quota" "QUEUED (rate-limited until 20" "$out9"
check_absent "move: reset comes from the rejected response, not from 'unknown'" "until unknown" "$out9"
check_absent "move: no mutation attempted" "item-edit" "$(cat "$LOGP9")"
rm -f "$LOGP9" "$CC9"


# scenario 10 (#544 review A): field names are matched case-insensitively. A board whose fields are
# lowercase ("status") must still yield statuses (a silently empty Status is a WIP-admission fail-open).
LOGA="$(mktemp)"; QLA="$(mktemp)"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
outA="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/resetA" FAKE_GH_LOG="$LOGA" FAKE_GH_QUERY_LOG="$QLA" FAKE_GH_FIELDS=status,priority,estimate gh_project_items_json 5 fixture-owner --strict)"; rcA=$?
check "field names: lowercase board read succeeds strictly" "0" "$rcA"
check "field names: every item keeps its status ('status' resolved case-insensitively)" "450" "$(python3 -c 'import json,sys; print(sum(1 for i in json.load(sys.stdin)["items"] if i.get("status")))' <<<"$outA")"
check "field names: the query asked for the board's real name" 'fieldValueByName(name: "status")' "$(cat "$QLA")"
rm -f "$LOGA" "$QLA"
# Status absent entirely: strict fails closed; non-strict warns and returns today's status-less items.
errB="$(mktemp)"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
outB="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/resetB" FAKE_GH_FIELDS=Priority,Estimate gh_project_items_json 5 fixture-owner --strict 2>"$errB"; echo "rc=$?")"
check "no Status field: strict read fails closed (rc 3)" "rc=3" "$outB"
check "no Status field: strict read says WIP BLOCKED" "WIP BLOCKED" "$(cat "$errB")"
check_absent "no Status field: strict read emits no board" "ITEM_" "$outB"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
outB2="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/resetB" FAKE_GH_FIELDS=Priority,Estimate gh_project_items_json 5 fixture-owner 2>"$errB"; echo "rc=$?")"
check "no Status field: non-strict read still returns the board (as gh project item-list did)" "rc=0" "$outB2"
check "no Status field: non-strict read warns on stderr" "no Status field" "$(cat "$errB")"
rm -f "$errB"

# scenario 11 (C): a read that cannot make progress must end. hasNextPage=true with empty pages and
# advancing cursors, and an A,B,A,B cursor cycle, both fail (strict and not) instead of looping forever.
for mode in emptynext cycle; do
    for flag in "" "--strict"; do
        CCC="$(mktemp)"; errC="$(mktemp)"
        # shellcheck source=plugins/spec-workflow/scripts/paginate.sh
        # shellcheck disable=SC2016  # $0 is the child bash's
        outC="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/resetC" FAKE_GH_GQL_CALLCOUNT="$CCC" FAKE_GH_MODE="$mode" timeout 20 bash -c 'source "$0"; gh_project_items_json 5 fixture-owner '"$flag" "$PLUGIN/scripts/paginate.sh" 2>"$errC"; echo "rc=$?")"
        check "no progress ($mode $flag): read ends with an error, not a hang or a partial board" "rc=1" "$outC"
        check "no progress ($mode $flag): the loop stopped within 6 item pages" "yes" "$([[ "$(cat "$CCC")" -le 6 ]] && echo yes || echo no)"
        check_absent "no progress ($mode $flag): nothing emitted on stdout" "ITEM_" "$outC"
        rm -f "$CCC" "$errC"
    done
done

# scenario 12 (J): totalCount disagreeing with the items read is incomplete: strict fails closed (rc 3), non-strict returns the board.
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
outD="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/resetD" FAKE_GH_TOTAL_LIE=1 gh_project_items_json 5 fixture-owner --strict 2>/dev/null; echo "rc=$?")"
check "strict: totalCount that disagrees with the items read fails closed" "rc=3" "$outD"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
outD2="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/resetD" FAKE_GH_TOTAL_LIE=1 gh_project_items_json 5 fixture-owner 2>/dev/null; echo "rc=$?")"
check "non-strict: the same read returns the board" "rc=0" "$outD2"

# scenario 13 (J): "@me" owners route to the viewer query (no repositoryOwner, no owner variable).
LOGM="$(mktemp)"; QLM="$(mktemp)"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/resetM" FAKE_GH_LOG="$LOGM" FAKE_GH_QUERY_LOG="$QLM" gh_project_items_json 5 "@me" >/dev/null 2>&1)
check "@me: queries the viewer's projects" "viewer" "$(cat "$QLM")"
check_absent "@me: no repositoryOwner lookup" "repositoryOwner" "$(cat "$QLM")"
check_absent "@me: no owner variable is sent" "owner=fixture" "$(cat "$LOGM")"
rm -f "$LOGM" "$QLM"

# scenario 14 (E): the reset time is per invocation. No predictable shared file survives a run, and another
# process's rejection (reset in the future) is never reported for this one.
TD14="$(mktemp -d)"
out14a="$(cd "$PG" && env -u PAGINATE_RESET_FILE TMPDIR="$TD14" PATH="$PGH:$PATH" FAKE_GH_FAIL_AT_PAGE=1 bash "$PLUGIN/scripts/board.sh" move 420 Backlog 2>&1)"
check "reset: first process is queued with its header reset" "QUEUED (rate-limited until 20" "$out14a"
check "reset: no reset file left behind in TMPDIR" "0" "$(find "$TD14" -maxdepth 1 -name 'sw-gh-*' | wc -l | tr -d ' ')"
out14b="$(cd "$PG" && env -u PAGINATE_RESET_FILE TMPDIR="$TD14" PATH="$PGH:$PATH" FAKE_GH_MODE=past-reset FAKE_GH_REST_RESET=86400 bash "$PLUGIN/scripts/board.sh" move 420 Backlog 2>&1)"
check "reset: a second process with a PAST header reset falls back to gh api rate_limit, not the first process's reset" "until 1970-01-02T00:00:00Z" "$out14b"
out14c="$(cd "$PG" && env -u PAGINATE_RESET_FILE TMPDIR="$TD14" PATH="$PGH:$PATH" FAKE_GH_FAIL_AT_PAGE=1 bash "$PLUGIN/scripts/board.sh" move 420 Backlog 2>&1 >/dev/null; env -u PAGINATE_RESET_FILE TMPDIR="$TD14" PATH="$PGH:$PATH" FAKE_GH_MODE=no-reset-header FAKE_GH_REST_RESET=86400 bash "$PLUGIN/scripts/board.sh" move 420 Backlog 2>&1)"
check "reset: a rejection with NO reset header never borrows an earlier process's reset" "until 1970-01-02T00:00:00Z" "$out14c"
rm -rf "$TD14"

# scenario 15 (G): a payload with only a code, or only a type, is still classified as a rate limit and queues.
for mode in code-only type-only; do
    rm -f "$PG/.claude/board-queue.jsonl" "$PG/.claude/board-cache.json"
    out15="$(cd "$PG" && env -u PAGINATE_RESET_FILE PATH="$PGH:$PATH" FAKE_GH_MODE="$mode" FAKE_GH_GRAPHQL_REMAINING=4000 bash "$PLUGIN/scripts/board.sh" move 420 Backlog 2>&1; echo "rc=$?")"
    check "rate limit ($mode): the move is queued, not blocked" "QUEUED (rate-limited until" "$out15"
    check "rate limit ($mode): exits 0" "rc=0" "$out15"
done

# scenario 16 (F): a non-rate-limit read failure is reported, never disguised as a bad issue number, and
# adopt/add-finish do not call item-add on it ("could not read" is not "not on the board").
rm -f "$PG/.claude/board-queue.jsonl" "$PG/.claude/board-cache.json"
LOGF="$(mktemp)"
out16="$(cd "$PG" && env -u PAGINATE_RESET_FILE PATH="$PGH:$PATH" FAKE_GH_LOG="$LOGF" FAKE_GH_MODE=scope bash "$PLUGIN/scripts/board.sh" move 420 Backlog 2>&1; echo "rc=$?")"
check "read failure: GitHub's real error is shown" "required scopes" "$out16"
check_absent "read failure: not disguised as a bad issue number" "bad issue#" "$out16"
check "read failure: move is queued as a board read failure and exits 0 (#561 round 2: work never stops)" "rc=0" "$out16"
check "read failure: QUEUED names the board read" "QUEUED (board read failed: gh error): move #" "$out16"
out16b="$(cd "$PG" && env -u PAGINATE_RESET_FILE PATH="$PGH:$PATH" FAKE_GH_LOG="$LOGF" FAKE_GH_MODE=scope bash "$PLUGIN/scripts/board.sh" adopt 420 2>&1; echo "rc=$?")"
check "read failure (adopt): fails with GitHub's error" "required scopes" "$out16b"
check "read failure (adopt): queued, exit 0 (#561 round 3)" "rc=0" "$out16b"
check_absent "read failure (adopt): item-add is not called" "project item-add" "$(cat "$LOGF")"
rm -f "$LOGF"


# scenario 17 (E): each process gets its OWN private reset file, and a stale value from an earlier
# rejected read never survives a later read in the same process.
# shellcheck disable=SC2016  # $0 and $PAGINATE_RESET_FILE belong to the child bash
rf1="$(env -u PAGINATE_RESET_FILE bash -c 'source "$0"; printf %s "$PAGINATE_RESET_FILE"' "$PLUGIN/scripts/paginate.sh")"
# shellcheck disable=SC2016
rf2="$(env -u PAGINATE_RESET_FILE bash -c 'source "$0"; printf %s "$PAGINATE_RESET_FILE"' "$PLUGIN/scripts/paginate.sh")"
check "reset: each process gets a different file" "differ" "$([[ -n "$rf1" && "$rf1" != "$rf2" ]] && echo differ || echo same)"
check_absent "reset: the file name is not a fixed per-user path" "graphql-reset" "$rf1"
check "reset: the private file is removed when the process exits" "gone" "$([[ ! -e "$rf1" ]] && echo gone || echo present)"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
# shellcheck disable=SC2030,SC2031  # PATH is deliberately changed inside this subshell only
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
stale="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && export PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/reset17" && FAKE_GH_FAIL_AT_PAGE=1 gh_project_items_json 5 fixture-owner >/dev/null 2>&1
    printf '<%s>' "$(cat "$PAGINATE_RESET_FILE")"; gh_project_items_json 5 fixture-owner >/dev/null 2>&1; printf '[%s]' "$(cat "$PAGINATE_RESET_FILE")")"
check "reset: a rejected read does record its reset" "<1" "$stale"
check "reset: a later successful read clears a stale reset left by an earlier rejection" "[]" "$stale"


# scenario 18 (#544 round 2, finding 1): `add` whose post-create board read fails for a NON-rate-limit reason
# keeps the add-finish op, shows GitHub's error, claims no rate limit and exits nonzero (build-next must see a stop).
rm -f "$PG/.claude/board-queue.jsonl" "$PG/.claude/board-cache.json"
CC18="$(mktemp)"
out18="$(cd "$PG" && env -u PAGINATE_RESET_FILE PATH="$PGH:$PATH" FAKE_GH_GQL_CALLCOUNT="$CC18" FAKE_GH_MODE=scope bash "$PLUGIN/scripts/board.sh" add --type feature "found while reading" P2 2>&1; echo "rc=$?")"
check "add + read failure: GitHub's error is shown" "required scopes" "$out18"
check_absent "add + read failure: no rate-limit claim" "rate-limited" "$out18"
check "add + read failure: QUEUED with the read reason, never a stop (#561 round 3)" "QUEUED (board read failed: gh error): item-add #" "$out18"
check_absent "add + read failure: no DEFERRED stop any more" "DEFERRED" "$out18"
check "add + read failure: exits 0" "rc=0" "$out18"
check "add + read failure: the add-finish op is kept so no work is lost" '"op": "add-finish"' "$(cat "$PG/.claude/board-queue.jsonl" 2>/dev/null)"
check "add + read failure: polling stops at the first failed read (one read, not two)" "1" "$(cat "$CC18")"
rm -f "$CC18" "$PG/.claude/board-queue.jsonl"

# scenario 19 (N4b/N4e): flush replays an add-finish op. A failed read must never turn into item-add, and is not a rate limit.
for from in 1 2; do
    rm -f "$PG/.claude/board-cache.json"
    LOG19="$(mktemp)"; CC19="$(mktemp)"
    printf '{"op": "add-finish", "issue": "777", "url": "https://github.com/fixture-owner/fixture-project/issues/777", "first_status": "Backlog", "prio": "P2", "ts": "2026-01-01T00:00:00Z"}\n' >"$PG/.claude/board-queue.jsonl"
    out19="$(cd "$PG" && env -u PAGINATE_RESET_FILE PATH="$PGH:$PATH" FAKE_GH_LOG="$LOG19" FAKE_GH_GQL_CALLCOUNT="$CC19" FAKE_GH_TOTAL_ITEMS=50 FAKE_GH_SCOPE_FROM="$from" bash "$PLUGIN/scripts/board.sh" flush 2>&1; echo "rc=$?")"
    check "flush add-finish (reads fail from #$from): GitHub's error is shown" "required scopes" "$out19"
    check_absent "flush add-finish (reads fail from #$from): not reported as a rate limit" "QUEUED (rate-limited" "$out19"
    check "flush add-finish (reads fail from #$from): op kept for follow-up" "kept in queue" "$out19"
    if [[ "$from" == 1 ]]; then
        check_absent "flush add-finish (first lookup fails): item-add is never called" "project item-add" "$(cat "$LOG19")"
    else
        check "flush add-finish (poll after item-add fails): stops at the failed poll read, reads=2" "2" "$(cat "$CC19")"
    fi
    rm -f "$LOG19" "$CC19" "$PG/.claude/board-queue.jsonl"
done

# scenario 20 (N4f): adopt whose read-back after item-add fails must not claim it adopted the issue.
rm -f "$PG/.claude/board-cache.json" "$PG/.claude/board-queue.jsonl"
out20="$(cd "$PG" && env -u PAGINATE_RESET_FILE PATH="$PGH:$PATH" FAKE_GH_TOTAL_ITEMS=50 FAKE_GH_SCOPE_FROM=2 FAKE_GH_GQL_CALLCOUNT="$(mktemp)" bash "$PLUGIN/scripts/board.sh" adopt 777 2>&1; echo "rc=$?")"
check_absent "adopt + failed read-back: does not print 'adopted'" "adopted #" "$out20"
check "adopt + failed read-back: reports the failure" "could not read it back" "$out20"
check "adopt + failed read-back: shows GitHub's error" "required scopes" "$out20"
check "adopt + failed read-back: an adopt-style op is queued, exit 0 (#561 round 4)" "QUEUED (board read failed: gh error): adopt #777" "$out20"
check "adopt + failed read-back: exits 0" "rc=0" "$out20"

# scenario 21 (N4h): the stale-cache-id retry re-resolves; a failing re-read shows the READ error, not the edit error.
printf '{"420": {"itemId": "ITEM_STALE", "status": "Backlog"}}' >"$PG/.claude/board-cache.json"
out21="$(cd "$PG" && env -u PAGINATE_RESET_FILE PATH="$PGH:$PATH" FAKE_GH_EDIT_FAIL=1 FAKE_GH_MODE=scope bash "$PLUGIN/scripts/board.sh" move 420 Backlog 2>&1; echo "rc=$?")"
check "stale cache id + failing re-read: GitHub's read error is shown" "required scopes" "$out21"
check_absent "stale cache id + failing re-read: the edit error is not blamed" "boom" "$out21"
check "stale cache id + failing re-read: move is queued, exit 0 (#561 round 2)" "rc=0" "$out21"

# scenario 22 (N14): a failed field-name query fails the read in both modes, with nothing on stdout.
for flag in "" "--strict"; do
    # shellcheck source=plugins/spec-workflow/scripts/paginate.sh
    out22="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/reset22" FAKE_GH_FIELDS_FAIL=1 gh_project_items_json 5 fixture-owner $flag 2>/dev/null; echo "rc=$?")"
    check "field query fails ($flag): the read fails" "rc=1" "$out22"
    check_absent "field query fails ($flag): no board on stdout" "ITEM_" "$out22"
done

# scenario 23 (finding 5): a Status field existing twice, differing by case, is ambiguous (init-config may have
# written either id): strict fails closed; non-strict warns and uses the exact-case field.
errE="$(mktemp)"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
outE="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/resetE" FAKE_GH_FIELDS=status,Status,Priority gh_project_items_json 5 fixture-owner --strict 2>"$errE"; echo "rc=$?")"
check "ambiguous Status: strict read fails closed" "rc=3" "$outE"
check "ambiguous Status: strict read says WIP BLOCKED" "WIP BLOCKED" "$(cat "$errE")"
check_absent "ambiguous Status: strict read emits no board" "ITEM_" "$outE"
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
outE2="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/resetE" FAKE_GH_FIELDS=status,Status,Priority FAKE_GH_TOTAL_ITEMS=3 gh_project_items_json 5 fixture-owner 2>"$errE"; echo "rc=$?")"
check "ambiguous Status: non-strict read still returns the board" "rc=0" "$outE2"
check "ambiguous Status: non-strict read warns" "ambiguous" "$(cat "$errE")"
check "ambiguous Status: non-strict read used the exact-case field (statuses present)" "3" "$(python3 -c 'import json,sys; t=sys.stdin.read().rsplit("rc=",1)[0]; print(sum(1 for i in json.loads(t)["items"] if i.get("status")))' <<<"$outE2")"
rm -f "$errE"

# scenario 24 (finding 4): verbs that exec (config, metrics) must not leave the private reset file behind.
TD24="$(mktemp -d)"
(cd "$PG" && env -u PAGINATE_RESET_FILE TMPDIR="$TD24" PATH="$PGH:$PATH" bash "$PLUGIN/scripts/board.sh" config >/dev/null 2>&1)
(cd "$PG" && env -u PAGINATE_RESET_FILE TMPDIR="$TD24" PATH="$PGH:$PATH" bash "$PLUGIN/scripts/board.sh" metrics >/dev/null 2>&1)
(cd "$PG" && env -u PAGINATE_RESET_FILE TMPDIR="$TD24" PATH="$PGH:$PATH" FAKE_GH_TOTAL_ITEMS=5 bash "$PLUGIN/scripts/board.sh" next >/dev/null 2>&1)
check "config, metrics and next leave no sw-gh-reset file in TMPDIR" "0" "$(find "$TD24" -maxdepth 1 -name 'sw-gh-reset*' | wc -l | tr -d ' ')"
rm -rf "$TD24"


# scenario 25 (round 3, blocker): a Retry-After given as an HTTP date is ignored ALONE; the primary
# X-Ratelimit-Reset from the same response is still the reported reset (not gh api rate_limit's).
rm -f "$PG/.claude/board-queue.jsonl" "$PG/.claude/board-cache.json"
LOG25="$(mktemp)"
out25="$(cd "$PG" && env -u PAGINATE_RESET_FILE PATH="$PGH:$PATH" FAKE_GH_LOG="$LOG25" FAKE_GH_MODE=date-retry FAKE_GH_REST_RESET=86400 bash "$PLUGIN/scripts/board.sh" move 420 Backlog 2>&1)"
check "HTTP-date Retry-After: the reset comes from X-Ratelimit-Reset" "until 2033-05-18T03:33:19Z" "$out25"
check_absent "HTTP-date Retry-After: gh api rate_limit is not consulted" "api rate_limit" "$(cat "$LOG25")"
rm -f "$LOG25" "$PG/.claude/board-queue.jsonl"

# scenario 26 (N13): the strict hard cap is its OWN failure: with totalCount agreeing with the items read
# (so the merged-snapshot check would pass), hitting the cap while hasNextPage is true must still fail closed.
# shellcheck source=plugins/spec-workflow/scripts/paginate.sh
out26="$(cd "$PG" && source "$PLUGIN/scripts/paginate.sh" && PATH="$PGH:$PATH" PAGINATE_RESET_FILE="$PG/reset26" PAGINATE_HARD_CAP=200 FAKE_GH_TOTAL_LIE=-250 gh_project_items_json 5 fixture-owner --strict 2>&1; echo "rc=$?")"
check "strict hard cap with a consistent totalCount: fails closed (rc 3)" "rc=3" "$out26"
check "strict hard cap with a consistent totalCount: names the cap" "WIP BLOCKED: pagination hard cap (200)" "$out26"
check_absent "strict hard cap with a consistent totalCount: no board on stdout" "ITEM_" "$out26"

# scenario 27 (R10/R11): config and metrics keep their exit codes now that they no longer exec.
# config: an invalid config fails (and the valid one passes); metrics: a failing telemetry read is nonzero.
CFG_BAD="$(mktemp -d)"; mkdir -p "$CFG_BAD/.claude" "$CFG_BAD/.neural-network"; (cd "$CFG_BAD" && git init -q .)
cp "$FIX/bounds-bool.project.yaml" "$CFG_BAD/.neural-network/project.yaml"
out27a="$(cd "$CFG_BAD" && bash "$PLUGIN/scripts/board.sh" config 2>&1; echo "rc=$?")"
check "config: an invalid config reports INVALID" "INVALID" "$out27a"
check "config: an invalid config exits 1" "rc=1" "$out27a"
out27b="$(cd "$PG" && PATH="$PGH:$PATH" bash "$PLUGIN/scripts/board.sh" config >/dev/null 2>&1; echo "rc=$?")"
check "config: a valid config exits 0" "rc=0" "$out27b"
MET="$(mktemp -d)"; mkdir -p "$MET/.claude" "$MET/.neural-network"; (cd "$MET" && git init -q .)
cp "$FIX/valid.project.yaml" "$MET/.neural-network/project.yaml"
out27d="$(cd "$MET" && bash "$PLUGIN/scripts/board.sh" metrics 2>&1; echo "rc=$?")"
check "metrics: with no telemetry it reports so" "no telemetry yet" "$out27d"
check "metrics: exits 0 with no telemetry" "rc=0" "$out27d"
mkdir "$MET/.claude/telemetry.jsonl"
out27c="$(cd "$MET" && bash "$PLUGIN/scripts/board.sh" metrics 2>&1; echo "rc=$?")"
check "metrics: a failing telemetry read exits nonzero (rc propagated)" "rc=1" "$out27c"
rm -rf "$MET"
rm -rf "$CFG_BAD"

rm -rf "$PG" "$PGH" "$LOGP1" "$CCP1" "$QLP1" "$LOGP3" "$LOGP4" "$CCP4"

echo "== seed-board.sh pagination (SW-013: sees + doesn't recreate a page-2 item) =="
SBG="$(mktemp -d)"; mkdir -p "$SBG/.claude" "$SBG/.neural-network"
cp "$FIX/valid.project.yaml" "$SBG/.neural-network/project.yaml"
SBTASKS="$(mktemp)"
cat >"$SBTASKS" <<'TASKS'
FX-005|P0|5|E1|page two existing task
TASKS
SBGH="$(mktemp -d)"
cat >"$SBGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
_limit_of() {
    local prev=""
    for a in "$@"; do
        if [[ "$prev" == "--limit" ]]; then printf '%s' "$a"; return 0; fi
        prev="$a"
    done
    printf '400'
}
_arg_of() { # _arg_of <key> "$@" -> value of the -f/-F key=value flag
    local key="$1" prev=""; shift
    for a in "$@"; do
        if [[ "$prev" == "-f" || "$prev" == "-F" ]] && [[ "$a" == "$key="* ]]; then printf '%s' "${a#"$key="}"; return 0; fi
        prev="$a"
    done
}
case "$1 $2" in
    "label list") echo "$*" >>"$FAKE_GH_LOG"; echo "" ;;
    "label create") echo "$*" >>"$FAKE_GH_LOG"; exit 0 ;;
    "issue list")
        echo "$*" >>"$FAKE_GH_LOG"
        if [[ "$*" == *"--search"* ]]; then
            echo "fake gh: unexpected fallback --search issue list -- FX-005 should already have been found on page 2" >&2
            exit 1
        fi
        n=$(( $(cat "$FAKE_GH_ISSUELIST_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_ISSUELIST_CALLCOUNT"
        limit="$(_limit_of "$@")"
        python3 -c "
import json, sys
limit, total, special = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
n = min(limit, total)
out = []
for i in range(1, n + 1):
    out.append({'title': ('FX-005: page two existing task' if i == special else 'Filler issue ' + str(i))})
print(json.dumps(out))
" "$limit" "${FAKE_GH_TOTAL_ISSUES:-450}" "${FAKE_GH_SPECIAL_ITEM:-420}"
        ;;
    "issue create")
        echo "$*" >>"$FAKE_GH_LOG"
        echo "fake gh: unexpected issue create -- FX-005 already exists (page-2 pagination bug would recreate it)" >&2
        exit 1
        ;;
    "api graphql")
        # Field-name resolution (#544 review): one cheap query, names configurable per test.
        if [[ "$(_arg_of query "$@")" == *"fields(first"* ]]; then
            if [[ -n "${FAKE_GH_FIELDS_FAIL:-}" ]]; then
                printf 'HTTP/2.0 502 Bad Gateway\n\n<html>bad gateway</html>\n'; echo "gh: HTTP 502" >&2; exit 1
            fi
            [[ -n "${FAKE_GH_LOG:-}" ]] && echo "api graphql kind=fields" >>"$FAKE_GH_LOG"
            python3 -c "
import json, os
names = [n for n in os.environ.get('FAKE_GH_FIELDS', 'Status,Priority,Estimate').split(',') if n]
print('HTTP/2.0 200 OK'); print('X-Ratelimit-Remaining: 4000'); print()
print(json.dumps({'data': {'repositoryOwner': {'projectV2': {'fields': {'nodes': [{'name': n} for n in ['Title'] + names]}}}}}))
"
            exit 0
        fi
        # Slim cursor read (#544). Cursor is "cur<offset>"; pages are 100 nodes.
        # Every call is logged with its cursor so tests can prove no page is read twice.
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "api graphql after=$(_arg_of after "$@") $(_arg_of owner "$@") first=$(_arg_of first "$@")" >>"$FAKE_GH_LOG"
        [[ -n "${FAKE_GH_QUERY_LOG:-}" ]] && _arg_of query "$@" >>"$FAKE_GH_QUERY_LOG"
        n=$(( $(cat "${FAKE_GH_ITEMLIST_CALLCOUNT:-/dev/null}" 2>/dev/null || echo 0) + 1 ))
        [[ -n "${FAKE_GH_ITEMLIST_CALLCOUNT:-}" ]] && echo "$n" >"$FAKE_GH_ITEMLIST_CALLCOUNT"
        case "${FAKE_GH_MODE:-}" in
            scope) printf 'HTTP/2.0 200 OK\n\n{"errors":[{"type":"INSUFFICIENT_SCOPES","message":"Your token has not been granted the required scopes to execute this query."}]}\n'
                   echo "gh: Your token has not been granted the required scopes" >&2; exit 1 ;;
            code-only) printf 'HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 0\n\n{"errors":[{"type":"X","code":"graphql_rate_limit","message":"Please slow down."}]}\n'; exit 1 ;;
            type-only) printf 'HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 0\n\n{"errors":[{"type":"RATE_LIMIT"}]}\n'; exit 1 ;;
            no-reset-header) printf 'HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 0\n\n{"errors":[{"type":"RATE_LIMIT","message":"API rate limit already exceeded for user ID 1."}]}\n'; exit 1 ;;
            past-reset) printf 'HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 0\nX-Ratelimit-Reset: 1\n\n{"errors":[{"type":"RATE_LIMIT","message":"API rate limit already exceeded for user ID 1."}]}\n'; exit 1 ;;
        esac
        if [[ -n "${FAKE_GH_FAIL_AT_PAGE:-}" && "$n" == "$FAKE_GH_FAIL_AT_PAGE" ]]; then
            # a rate-limited rejection: headers (reset = now+600s) + the REAL error object, exit 1 like gh
            python3 -c "
import json, sys, time
print('HTTP/2.0 200 OK'); print('X-Ratelimit-Remaining: 0'); print('X-Ratelimit-Reset: %d' % (int(time.time()) + 600)); print()
print(json.dumps({'errors': [{'type': 'RATE_LIMIT', 'code': 'graphql_rate_limit', 'message': 'API rate limit already exceeded for user ID 12402908.'}]}))
"
            echo "gh: API rate limit already exceeded for user ID 12402908." >&2
            exit 1
        fi
        after="$(_arg_of after "$@")"; off=0
        [[ "$after" == cur* ]] && off="${after#cur}"
        Q="$(_arg_of query "$@")" CALLN="$n" python3 -c "
import json, os, sys
off, total, special, size = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
q, mode, calln = os.environ['Q'], os.environ.get('FAKE_GH_MODE', ''), int(os.environ['CALLN'])
fields = os.environ.get('FAKE_GH_FIELDS', 'Status,Priority,Estimate').split(',')
def has(kind):  # a field value is only returned when the query used the board's exact field name
    return any(f.lower() == kind and ('name: \"%s\"' % f) in q for f in fields)
end = min(off + size, total)
nodes = []
for i in range(off + 1, end + 1):
    special_hit = (i == special)
    nodes.append({'id': 'ITEM_PAGE2' if special_hit else 'ITEM_' + str(i),
                  'status': {'name': 'Backlog' if special_hit else 'Deployed'} if has('status') else None,
                  'priority': ({'name': 'P0' if special_hit else 'P2'}) if has('priority') else None,
                  'estimate': None,
                  'content': {'__typename': 'Issue', 'number': i, 'body': 'b', 'url': 'u',
                              'title': ('FX-005: page two existing task' if special_hit else 'Filler ' + str(i)),
                              'repository': {'nameWithOwner': 'fixture-owner/fixture-project'},
                              'labels': {'nodes': []}}})
has_next, cursor = end < total, 'cur%d' % end
if mode == 'emptynext': nodes, has_next, cursor = [], True, 'e%d' % calln
if mode == 'cycle': nodes, has_next, cursor = nodes[:1], True, 'AB'[calln % 2]
items = {'totalCount': total + int(os.environ.get('FAKE_GH_TOTAL_LIE', '0')), 'pageInfo': {'hasNextPage': has_next, 'endCursor': cursor}, 'nodes': nodes}
print('HTTP/2.0 200 OK'); print('X-Ratelimit-Remaining: 4000'); print()
print(json.dumps({'data': {'repositoryOwner': {'projectV2': {'items': items}}}}))
" "$off" "${FAKE_GH_TOTAL_ITEMS:-450}" "${FAKE_GH_SPECIAL_ITEM:-420}" "$(_arg_of first "$@" | sed 's/^$/100/')"
        ;;
    "api rate_limit")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "api rate_limit" >>"$FAKE_GH_LOG"
        echo "{\"resources\":{\"graphql\":{\"remaining\":${FAKE_GH_GRAPHQL_REMAINING:-4000},\"reset\":1}}}"
        ;;
    "project item-list")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "$*" >>"$FAKE_GH_LOG"
        echo "fake gh: project item-list costs 101 points/100 items and must not be used for board reads (#544)" >&2
        exit 1
        ;;
    "project item-edit")
        echo "$*" >>"$FAKE_GH_LOG"
        echo "edited"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$SBGH/gh"

LOGSB="$(mktemp)"; CCSB_I="$(mktemp)"; CCSB_L="$(mktemp)"
# shellcheck disable=SC2031
TDSB="$(mktemp -d)"
out="$(cd "$SBG" && TMPDIR="$TDSB" PATH="$SBGH:$PATH" FAKE_GH_LOG="$LOGSB" FAKE_GH_ISSUELIST_CALLCOUNT="$CCSB_I" FAKE_GH_ITEMLIST_CALLCOUNT="$CCSB_L" \
    bash "$PLUGIN/scripts/seed-board.sh" "$SBTASKS" 2>&1; echo "rc=$?")"
check "seed-board: leaves no sw-gh-reset file in TMPDIR" "0" "$(find "$TDSB" -maxdepth 1 -name 'sw-gh-reset*' | wc -l | tr -d ' ')"
rm -rf "$TDSB"
check "seed-board: completes (page-2 existing issue correctly found, not recreated)" "rc=0" "$out"
check "seed-board: does not re-create the page-2 issue (dedup across pages)" "==> done" "$out"
check_absent "seed-board: no missing-project-item warning for the page-2 item" "no project item for" "$out"
check "seed-board: sets fields on the page-2 item's real id" "project item-edit --id ITEM_PAGE2" "$(cat "$LOGSB")"
callssb_i="$(cat "$CCSB_I")"
if [[ "$callssb_i" -ge 2 ]]; then echo "ok   seed-board: issue-list dedup check was re-paged (>=2 calls) to find FX-005 on page 2"
else echo "FAIL seed-board: expected >=2 issue-list calls, got $callssb_i"; fails=$((fails + 1)); fi
callssb_l="$(cat "$CCSB_L")"
check "seed-board: item MAP build paged through 5 cursor pages (450 items) to find FX-005's item" "5" "$callssb_l"
check "seed-board: calls board.sh ensure-labels (label list issued)" "label list -R fixture-owner/fixture-project" "$(cat "$LOGSB")"
check "seed-board: ensure-labels creates the configured bug label" "label create type:bug" "$(cat "$LOGSB")"
check "seed-board: ensure-labels creates the configured feature label" "label create type:feature" "$(cat "$LOGSB")"
check "seed-board: ensure-labels creates the (default) inbound label" "label create inbound" "$(cat "$LOGSB")"

rm -rf "$SBG" "$SBGH" "$SBTASKS" "$LOGSB" "$CCSB_I" "$CCSB_L"


