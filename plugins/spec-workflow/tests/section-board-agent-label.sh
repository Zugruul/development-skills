#!/usr/bin/env bash
# section-board-agent-label.sh -- sourced by run-tests.sh; do not run standalone.
# Task #566: board.sh agent N <name>|--clear labels an issue with the working agent.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== board.sh agent (fake gh: REST-only agent label, exact call budget) =="

AGB="$(mktemp -d)"; mkdir -p "$AGB/.claude" "$AGB/.neural-network"
cp "$FIX/valid.project.yaml" "$AGB/.neural-network/project.yaml"
AGH="$(mktemp -d)"
# Fake gh: logs every call (one line) to $AG_LOG. GET returns $AG_LABELS (one
# name per line). AG_FAIL=<verb> makes that verb fail with $AG_ERR on stderr.
cat >"$AGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >>"$AG_LOG"
[[ "$1" == "api" ]] || { echo "fake gh: non-api call: $*" >&2; exit 1; }
verb=GET; for a in "$@"; do [[ "$a" == "DELETE" || "$a" == "POST" ]] && verb="$a"; done
if [[ "${AG_FAIL:-}" == "$verb" ]]; then echo "${AG_ERR:-boom}" >&2; exit 1; fi
if [[ "$verb" == GET ]]; then cat "$AG_LABELS" 2>/dev/null; fi
exit 0
FAKE
chmod +x "$AGH/gh"

_ag() { # args... -> runs board.sh agent with the fake gh; prints output + rc=
    (cd "$AGB" && PATH="$AGH:$PATH" bash "$PLUGIN/scripts/board.sh" agent "$@" 2>&1; echo "rc=$?")
}
export AG_LOG="$AGB/calls.log" AG_LABELS="$AGB/labels.txt"
R=fixture-owner/fixture-project
check_calls() { # label expected-count -> exact (not substring) count of logged gh calls
    check_rc "$1" "$2" "$(wc -l <"$AG_LOG" | tr -d ' ')"
}

# 1. set on a clean issue: 1 GET + 1 POST, nothing else
: >"$AG_LOG"; : >"$AG_LABELS"
out="$(_ag 7 dev-SC-147)"; calls="$(cat "$AG_LOG")"
check_rc "agent set: exits 0" 0 "$(sed -n 's/.*rc=//p' <<<"$out")"
check "agent set: one REST GET of the issue labels" "api repos/$R/issues/7/labels" "$calls"
check "agent set: POSTs the lowercase label" "labels[]=agent: dev-sc-147" "$calls"
check_calls "agent set: exactly 2 gh calls (1 GET + 1 POST)" 2
check_absent "agent set: no GraphQL" "graphql" "$calls"
check "agent set: every call is a gh api call (no gh project)" "0" "$(grep -vc "^api " <<<"$calls")"
check_absent "agent set: no DELETE when nothing stale" "DELETE" "$calls"

# 2. re-brief: stale agent labels deleted (1 DELETE each), other labels untouched
: >"$AG_LOG"; printf 'type:feature\nagent: dev-sc-147\nagent: dev-old\n' >"$AG_LABELS"
out="$(_ag 7 dev-SC-147-b)"; calls="$(cat "$AG_LOG")"
check_rc "agent re-brief: exits 0" 0 "$(sed -n 's/.*rc=//p' <<<"$out")"
check "agent re-brief: deletes first stale label (url-encoded)" "DELETE repos/$R/issues/7/labels/agent%3A%20dev-sc-147" "$calls"
check "agent re-brief: deletes second stale label" "labels/agent%3A%20dev-old" "$calls"
check "agent re-brief: POSTs the new label" "labels[]=agent: dev-sc-147-b" "$calls"
check_calls "agent re-brief: exactly 4 gh calls (1 GET + 2 DELETE + 1 POST)" 4
check_absent "agent re-brief: never touches the non-agent label" "type%3Afeature" "$calls"
check_absent "agent re-brief: no GraphQL" "graphql" "$calls"

# 3. same agent already present: no POST, no DELETE
: >"$AG_LOG"; printf 'agent: dev-sc-147\n' >"$AG_LABELS"
out="$(_ag 7 dev-SC-147)"; calls="$(cat "$AG_LOG")"
check_rc "agent idempotent: exits 0" 0 "$(sed -n 's/.*rc=//p' <<<"$out")"
check_calls "agent idempotent: exactly 1 call (the GET)" 1
check_absent "agent idempotent: no POST when already set" "POST" "$calls"
check_absent "agent idempotent: no DELETE when already set" "DELETE" "$calls"

# 4. --clear: 1 GET + 1 DELETE per agent label, no POST
: >"$AG_LOG"; printf 'agent: dev-a\nbug\nagent: dev-b\n' >"$AG_LABELS"
out="$(_ag 7 --clear)"; calls="$(cat "$AG_LOG")"
check_rc "agent --clear: exits 0" 0 "$(sed -n 's/.*rc=//p' <<<"$out")"
check_calls "agent --clear: exactly 3 gh calls (1 GET + 2 DELETE)" 3
check_absent "agent --clear: no POST" "POST" "$calls"
check_absent "agent --clear: no GraphQL" "graphql" "$calls"

# 5. name sanitised and truncated to 50 chars deterministically
: >"$AG_LOG"; : >"$AG_LABELS"
long="Dev Lane/$(printf 'x%.0s' $(seq 1 80))"
out="$(_ag 7 "$long")"; lab="$(sed -n 's/.*labels\[\]=//p' "$AG_LOG")"
check "agent long name: truncated to 50 chars" "50" "${#lab}"
check "agent long name: keeps the agent: prefix, lowercase, safe chars" "agent: dev-lane-xxx" "$lab"
check_rc "agent long name: exits 0" 0 "$(sed -n 's/.*rc=//p' <<<"$out")"
check_calls "agent long name: exactly 2 calls (GET + POST)" 2
first="$lab"; : >"$AG_LOG"; out="$(_ag 7 "$long")"
check_rc "agent long name (repeat): exits 0" 0 "$(sed -n 's/.*rc=//p' <<<"$out")"
check "agent long name: truncation is deterministic" "$first" "$(sed -n 's/.*labels\[\]=//p' "$AG_LOG")"

# 6. failures never fail the caller (warn, exit 0)
: >"$AG_LOG"; : >"$AG_LABELS"
out="$(AG_FAIL=POST AG_ERR='gh: Internal Server Error (HTTP 500)' _ag 7 dev-1)"
check_calls "agent: other POST error does not create or retry (GET + POST only)" 2
check_rc "agent: failed POST still exits 0" 0 "$(sed -n 's/.*rc=//p' <<<"$out")"
check "agent: failed POST prints a warning" "WARN" "$out"
out="$(AG_FAIL=GET AG_ERR='gh: Not Found (HTTP 404)' _ag 7 dev-1)"
check_rc "agent: failed GET still exits 0" 0 "$(sed -n 's/.*rc=//p' <<<"$out")"
check "agent: failed GET prints a warning" "WARN" "$out"
: >"$AG_LOG"
out="$(AG_FAIL=GET AG_ERR='gh: API rate limit exceeded for user ID 1. (HTTP 403)' _ag 7 dev-1)"
check_rc "agent: rate limit exits 0" 0 "$(sed -n 's/.*rc=//p' <<<"$out")"
check "agent: rate limit says so" "rate limit" "$out"
check_calls "agent: rate limit does not retry or queue (1 call)" 1
check "agent: rate limit queues nothing (no board-queue file under .claude)" "none" "$(find "$AGB/.claude" -name 'board-queue*' | grep . || echo none)"

# 7. label missing: create by REST POST repos/<repo>/labels, then retry the set once
cat >"$AGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >>"$AG_LOG"
if [[ "$*" == *POST* && "$*" == */issues/* ]]; then
    if [[ -e "$AG_LOG.created" ]]; then exit 0; fi
    echo "${AG_POST_ERR:-gh: Not Found (HTTP 404)}" >&2; exit 1
fi
if [[ "$*" == *POST* && "$*" == */labels* ]]; then
    touch "$AG_LOG.created"
    if [[ -n "${AG_CREATE_OUT:-}" ]]; then echo "$AG_CREATE_OUT" >&2; exit 1; fi
fi
exit 0
FAKE
: >"$AG_LABELS"
_seq() { awk '/DELETE/{printf "DELETE,"; next} /POST/ && /\/issues\//{printf "POST-issue,"; next} /POST/{printf "POST-label,"; next} {printf "GET,"}' "$AG_LOG"; }
: >"$AG_LOG"; rm -f "$AG_LOG.created"
out="$(_ag 7 dev-9)"; calls="$(cat "$AG_LOG")"
check "agent first use: call sequence GET, failing POST, create POST, retry POST" "GET,POST-issue,POST-label,POST-issue," "$(_seq)"
check_calls "agent first use: exactly 4 calls" 4
check "agent first use: success line printed" "agent label on #7: agent: dev-9" "$out"
check_absent "agent first use: no WARN" "WARN" "$out"
check_rc "agent first use: exits 0" 0 "$(sed -n 's/.*rc=//p' <<<"$out")"
check_absent "agent first use: no GraphQL" "graphql" "$calls"

: >"$AG_LOG"; rm -f "$AG_LOG.created"
out="$(AG_CREATE_OUT='gh: Validation Failed (HTTP 422) {"errors":[{"code":"already_exists"}]}' _ag 7 dev-9)"
check_calls "agent create 422 already_exists: retry still runs (4 calls)" 4
check "agent create 422 already_exists: success line" "agent label on #7: agent: dev-9" "$out"
check_absent "agent create 422 already_exists: no WARN" "WARN" "$out"

: >"$AG_LOG"; rm -f "$AG_LOG.created"
out="$(AG_POST_ERR='gh: You have exceeded a secondary rate limit. (HTTP 403)' _ag 7 dev-9)"
check_calls "agent rate limit on POST: exactly 2 calls (GET + POST), no create" 2
check "agent rate limit on POST: says rate limit" "rate limit" "$out"
check_rc "agent rate limit on POST: exits 0" 0 "$(sed -n 's/.*rc=//p' <<<"$out")"

: >"$AG_LOG"; rm -f "$AG_LOG.created"
out="$(AG_POST_ERR='gh: Bad credentials (HTTP 401)' _ag 7 dev-9)"
check_calls "agent other POST error: exactly 2 calls, no create" 2
check "agent other POST error: WARN printed" "WARN" "$out"

# newline inside a name is cleaned out of the slug (one label, one line)
: >"$AG_LOG"; rm -f "$AG_LOG.created"
touch "$AG_LOG.created"; _ag 7 $'dev\nevil' >/dev/null
check "agent newline name: single-line sanitised label" "labels[]=agent: dev-evil" "$(cat "$AG_LOG")"
check_calls "agent newline name: only one label POST line" 2
rm -f "$AG_LOG.created"

# 8. invalid arguments exit 2
for bad in "" "x dev" "7" "7 --bogus"; do
    # shellcheck disable=SC2086
    out="$(_ag $bad)"
    check_rc "agent invalid args [$bad]: exit 2" 2 "$(sed -n 's/.*rc=//p' <<<"$out")"
done
out="$(cd "$AGB" && PATH="$AGH:$PATH" bash "$PLUGIN/scripts/board.sh" agent 7 "" 2>&1; echo "rc=$?")"
check_rc "agent invalid args [empty name]: exit 2" 2 "$(sed -n 's/.*rc=//p' <<<"$out")"
check "agent invalid args: prints usage" "usage" "$(_ag x dev)"

rm -rf "$AGB" "$AGH"
