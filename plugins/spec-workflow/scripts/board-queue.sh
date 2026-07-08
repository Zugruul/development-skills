#!/usr/bin/env bash
# board-queue.sh — rate-limit resilience for board.sh (issue #77 / #84).
#
# Sourced by board.sh AFTER the per-board vars (OWNER/REPO/PN/PID/*_FIELD/
# FIRST_STATUS) are resolved and item_id()/opt_id() are defined — every
# function below depends on those. Not meant to be executed directly.
#
# Model: a mutating op (move/prio/est/item-add) that hits a GitHub rate limit
# is appended to a durable local queue (QUEUE_FILE, one JSON object per line)
# instead of failing the caller. `board.sh flush` (and every board-READING
# command, automatically) replays the queue in order once quota returns.
# Replaying a `move` first checks the item's current status and skips if the
# target already holds (SPEC: prevents a stale queued move from regressing a
# status a newer, already-applied move already advanced past). If the limit
# re-trips mid-replay, the remainder (current op + everything after it) is
# written back to QUEUE_FILE verbatim and flush returns success — the loop
# keeps going, nothing is lost, nothing double-applies.
set -uo pipefail

QUEUE_FILE="${BOARD_QUEUE_FILE:-$ROOT/.claude/board-queue.jsonl}"

# _rate_limited <captured-stderr-or-combined-output> -> 0 if it looks like a
# GitHub rate-limit response (REST "API rate limit exceeded", GraphQL
# "API rate limit exceeded (RATE_LIMITED)", or a secondary rate limit).
# Deliberately broad (case-insensitive "rate limit" substring): every real
# variant we've seen contains that phrase, and a false positive here just
# means an op gets queued instead of erroring — safe, not silent.
_rate_limited() {
    grep -qi "rate limit" <<<"$1"
}

# _rate_limit_reset_human -> ISO-8601 UTC reset time from the REST rate_limit
# endpoint (works even when GraphQL itself is the thing exhausted).
_rate_limit_reset_human() {
    local raw
    raw="$(gh api rate_limit 2>/dev/null)" || { echo "unknown"; return; }
    python3 -c '
import json, sys, datetime
try:
    d = json.loads(sys.argv[1])
    ts = d["rate"]["reset"]
    print(datetime.datetime.utcfromtimestamp(ts).strftime("%Y-%m-%dT%H:%M:%SZ"))
except Exception:
    print("unknown")
' "$raw"
}

# queue_append <op> <key=value>... -> appends one JSON line (op + given keys
# + a ts) to QUEUE_FILE. Values are passed as argv (never string-concatenated
# into JSON by hand) so titles/statuses with quotes/spaces stay safe.
queue_append() {
    local op="$1"; shift
    mkdir -p "$(dirname "$QUEUE_FILE")"
    python3 -c '
import json, sys, time
op = sys.argv[1]
d = {"op": op}
for pair in sys.argv[2:]:
    k, _, v = pair.partition("=")
    d[k] = v
d["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
print(json.dumps(d))
' "$op" "$@" >>"$QUEUE_FILE"
}

_jf() { # <json-line> <field> -> value ("" if absent)
    python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$1" "$2"
}

_current_status() { # issue# -> status string ("" if not found / lookup failed)
    gh_project_items_json "$PN" "$OWNER" 2>/dev/null | python3 -c '
import json, sys
try:
    n = int(sys.argv[1])
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in data.get("items", []):
    if (it.get("content") or {}).get("number") == n:
        print(it.get("status") or "")
        break
' "$1"
}

# _do_move/_do_prio/_do_est: same effect as the move/prio/est case branches,
# factored out so both the live command AND flush replay share one
# implementation. Return 0 = applied, 1 = real (non-rate-limit) failure,
# 2 = rate-limited (caller decides: queue live, or re-queue-and-stop in flush).
_do_move() {
    local num="$1" status="$2" id opt out rc
    id="$(item_id "$num")"; opt="$(opt_id status "$status")"
    if [[ -z "$id" || -z "$opt" ]]; then
        echo "ERROR: bad issue# or status '$status' (must match statusFlow)" >&2
        return 1
    fi
    out="$(gh project item-edit --id "$id" --project-id "$PID" --field-id "$STATUS_FIELD" --single-select-option-id "$opt" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "moved #$num -> $status"
        python3 "$HERE/telemetry.py" "$ROOT" record \
            "{\"kind\":\"transition\",\"task\":\"$num\",\"from\":\"\",\"to\":\"$status\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
            >/dev/null 2>&1 || true
        return 0
    fi
    _rate_limited "$out" && return 2
    echo "$out" >&2
    return 1
}

_do_prio() {
    local num="$1" prio="$2" id opt out rc
    id="$(item_id "$num")"; opt="$(opt_id priority "$prio")"
    if [[ -z "$id" || -z "$opt" ]]; then
        echo "ERROR: bad issue# or priority '$prio'" >&2
        return 1
    fi
    out="$(gh project item-edit --id "$id" --project-id "$PID" --field-id "$PRIO_FIELD" --single-select-option-id "$opt" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "prio #$num -> $prio"
        return 0
    fi
    _rate_limited "$out" && return 2
    echo "$out" >&2
    return 1
}

_do_est() {
    local num="$1" points="$2" id out rc
    if [[ -z "$EST_FIELD" ]]; then
        echo "ERROR: no estimate field configured" >&2
        return 1
    fi
    id="$(item_id "$num")"
    out="$(gh project item-edit --id "$id" --project-id "$PID" --field-id "$EST_FIELD" --number "$points" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "est #$num -> $points"
        return 0
    fi
    _rate_limited "$out" && return 2
    echo "$out" >&2
    return 1
}

# _do_add_finish: the remainder of `add`'s work after the issue itself
# exists (item-add, poll for visibility, move to FIRST_STATUS, set prio).
# Used both by `add`'s own fallback (visibility cap hit) and by flush
# replaying a queued add-finish op. Idempotent: skips item-add / move when
# the item is already visible / already at the target status.
_do_add_finish() {
    local num="$1" url="$2" first_status="$3" prio="$4" id out rc cur i
    id="$(item_id "$num")"
    if [[ -z "$id" ]]; then
        out="$(gh project item-add "$PN" --owner "$OWNER" --url "$url" 2>&1)"; rc=$?
        if [[ $rc -ne 0 ]]; then
            _rate_limited "$out" && return 2
            echo "ERROR: add-finish #$num: gh project item-add failed: $out" >&2
            return 1
        fi
        for ((i = 0; i < 3; i++)); do
            id="$(item_id "$num")"
            [[ -n "$id" ]] && break
            sleep 0.3
        done
        [[ -z "$id" ]] && return 2  # still not visible -- re-queue, try again later
    fi
    cur="$(_current_status "$num")"
    if [[ "$cur" != "$first_status" ]]; then
        _do_move "$num" "$first_status"; rc=$?
        [[ "$rc" -ne 0 ]] && return "$rc"
    fi
    _do_prio "$num" "$prio"; rc=$?
    [[ "$rc" -ne 0 ]] && return "$rc"
    echo "flush: finished add #$num [$prio]"
    return 0
}

# _do_adopt: add an EXISTING issue to the board (issue #84). Idempotent —
# a no-op (with a message) if the issue is already a board item.
_do_adopt() {
    local num="$1" id url out rc
    id="$(item_id "$num")"
    if [[ -n "$id" ]]; then
        echo "adopt #$num: already on board"
        return 0
    fi
    url="https://github.com/$REPO/issues/$num"
    out="$(gh project item-add "$PN" --owner "$OWNER" --url "$url" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "adopted #$num"
        return 0
    fi
    _rate_limited "$out" && return 2
    echo "ERROR: adopt #$num: gh project item-add failed: $out" >&2
    return 1
}

# _flush_queue: replay QUEUE_FILE in order. No-op if empty/absent. On a
# rate-limit mid-replay, re-queues the current op + every op after it
# (untouched, order preserved) and returns 0 — the caller (a read command or
# the explicit `flush` verb) keeps going, nothing is lost.
_flush_queue() {
    [[ -s "$QUEUE_FILE" ]] || return 0
    local tmp line op issue status priority points url first_status prio rc cur requeued reset
    tmp="$(mktemp)"; cp "$QUEUE_FILE" "$tmp"
    : >"$QUEUE_FILE"
    requeued=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        if [[ "$requeued" -eq 1 ]]; then
            printf '%s\n' "$line" >>"$QUEUE_FILE"
            continue
        fi
        op="$(_jf "$line" op)"
        case "$op" in
            move)
                issue="$(_jf "$line" issue)"; status="$(_jf "$line" status)"
                cur="$(_current_status "$issue")"
                if [[ -n "$cur" && "$cur" == "$status" ]]; then
                    echo "flush: skip move #$issue (already $status)"
                    rc=0
                else
                    _do_move "$issue" "$status"; rc=$?
                fi
                ;;
            prio)
                issue="$(_jf "$line" issue)"; priority="$(_jf "$line" priority)"
                _do_prio "$issue" "$priority"; rc=$?
                ;;
            est)
                issue="$(_jf "$line" issue)"; points="$(_jf "$line" points)"
                _do_est "$issue" "$points"; rc=$?
                ;;
            add-finish)
                issue="$(_jf "$line" issue)"; url="$(_jf "$line" url)"
                first_status="$(_jf "$line" first_status)"; prio="$(_jf "$line" prio)"
                _do_add_finish "$issue" "$url" "$first_status" "$prio"; rc=$?
                ;;
            adopt)
                issue="$(_jf "$line" issue)"
                _do_adopt "$issue"; rc=$?
                ;;
            *)
                echo "flush: WARNING dropping queued line with unknown op '$op'" >&2
                rc=0
                ;;
        esac
        if [[ "$rc" -eq 2 ]]; then
            reset="$(_rate_limit_reset_human)"
            echo "QUEUED (rate-limited until $reset): $op #$issue"
            printf '%s\n' "$line" >>"$QUEUE_FILE"
            requeued=1
        fi
    done <"$tmp"
    rm -f "$tmp"
}
