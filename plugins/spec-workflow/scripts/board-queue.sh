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

# Mutual exclusion for flush (#92): a bash-3.2-portable mutex -- macOS bash
# has no flock builtin, but mkdir is atomic on every POSIX filesystem, so a
# lockdir next to the queue file is the portable equivalent. A stale lock
# (older than QUEUE_LOCK_TTL, mtime-based) is broken with a warning so a
# flusher that crashed mid-flush can't wedge the queue forever.
QUEUE_LOCK_DIR="$(dirname "$QUEUE_FILE")/board-queue.lock"
QUEUE_LOCK_TTL="${BOARD_QUEUE_LOCK_TTL:-600}"  # seconds

# _rate_limited <captured-stderr-or-combined-output> -> 0 if it looks like a
# GitHub rate-limit response. Two layers:
#  1. Fast path — case-insensitive "rate limit" substring (REST "API rate
#     limit exceeded", GraphQL "API rate limit exceeded (RATE_LIMITED)", a
#     secondary rate limit): every TEXT-VISIBLE variant we've seen contains
#     that phrase.
#  2. Probe fallback (#90) — gh sometimes MASKS GraphQL exhaustion as an
#     unrelated error (e.g. "unknown owner type", no "rate limit" text
#     anywhere: live evidence, #90). When the fast path misses, probe the
#     REST rate_limit endpoint (works even while GraphQL itself is
#     exhausted) and treat remaining==0 on the graphql resource as ground
#     truth. remaining>0 means the error is real — surface it verbatim.
_rate_limited() {
    grep -qi "rate limit" <<<"$1" && return 0
    # GitHub's own GraphQL payload (#544): {"type":"RATE_LIMIT","code":"graphql_rate_limit"}.
    # Recognised by code even when the text is reworded, and WITHOUT the REST probe below:
    # one token has two GraphQL counters and `gh api rate_limit` shows only one of them.
    grep -qE 'RATE_LIMIT|graphql_rate_limit' <<<"$1" && return 0
    # A recognised 5xx/timeout/network failure is not a masked rate limit: no probe call (#561).
    [[ "$(_gh_failure_label "$1")" != "gh error" ]] && return 1
    _graphql_remaining_is_zero
}

# _graphql_remaining_is_zero -> 0 (true) iff `gh api rate_limit`'s graphql
# resource reports remaining==0. A probe failure (gh itself erroring, e.g.
# also rate-limited on REST, or unparseable JSON) is NOT treated as
# rate-limited — that would mask a real error behind a silent queue.
_graphql_remaining_is_zero() {
    local raw remaining
    raw="$(gh api rate_limit 2>/dev/null)" || return 1
    remaining="$(python3 -c '
import json, sys
try:
    print(json.loads(sys.argv[1])["resources"]["graphql"]["remaining"])
except Exception:
    print(-1)
' "$raw")"
    [[ "$remaining" == "0" ]]
}

# _gh_failure_label <gh-error-text> -> short human reason for a non-rate-limit
# gh failure, used in "QUEUED (<reason>)" and the PENDING display (#561). It
# only LABELS: every non-guard failure is queued, the label says why. Order
# matters -- an "HTTP 504: Gateway Timeout" must read as HTTP 504, not timeout.
# Wording covered (see tests/fixtures/gh-failures/transient-*.txt): gh's
# "HTTP <code>: <text> (<url>)", Go net/http deadline/DNS errors, and gh's own
# "error connecting to api.github.com". Anything else is a generic "gh error".
_gh_failure_label() {
    local t="$1" code
    code="$(grep -oE 'HTTP 5[0-9][0-9]' <<<"$t" | head -1)"
    if [[ -n "$code" ]]; then printf '%s' "$code"; return 0; fi
    if grep -qiE 'timeout|timed out|deadline exceeded' <<<"$t"; then printf 'timeout'; return 0; fi
    if grep -qiE 'error connecting to|no such host|dial tcp|connection (refused|reset)|network is unreachable|TLS handshake|unexpected EOF|: EOF' <<<"$t"; then printf 'network error'; return 0; fi
    printf 'gh error'
}

# Cleanup registry (#561): ONE EXIT trap function removes every temp file and held
# lock directory this script registered, so no trap parsing or chaining is needed.
# paginate.sh's own EXIT trap only removes its reset file, which _bq_exit does too
# (callers that install their own EXIT trap must call _bq_exit from it).
_CLEAN_LIST=""
_cleanup_add() { _CLEAN_LIST="$_CLEAN_LIST$1"$'\n'; }
_cleanup_del() {
    local out="" l
    while IFS= read -r l; do
        if [[ -n "$l" && "$l" != "$1" ]]; then out="$out$l"$'\n'; fi
    done <<<"$_CLEAN_LIST"
    _CLEAN_LIST="$out"
}
_bq_exit() {
    local l
    [[ -n "${PAGINATE_RESET_FILE:-}" ]] && rm -f "$PAGINATE_RESET_FILE"
    while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        if [[ -d "$l" ]]; then rm -f "$l/pid"; rmdir "$l" 2>/dev/null || true; else rm -f "$l"; fi
    done <<<"$_CLEAN_LIST"
    _CLEAN_LIST=""
    return 0
}
trap _bq_exit EXIT

# Why the last move failed retryably (#561). _do_move runs parts of its work in
# subshells, so the reason travels through a private mktemp file, not a variable.
# Each _do_* that can fail retryably calls _qreason_begin (allocates the file once,
# empties it); every other _do_* sets _QREASON_WANT=0 so nothing is written.
# The caller reads it once with _take_reason; the EXIT trap removes the file.
_QREASON_FILE=""
_QREASON_WANT=0
_qreason_begin() {
    _QREASON_WANT=1
    if [[ -z "$_QREASON_FILE" ]]; then
        _QREASON_FILE="$(mktemp)"
        _cleanup_add "$_QREASON_FILE"
    fi
    : >"$_QREASON_FILE"
}
_qreason() {
    [[ "${_QREASON_WANT:-0}" == "1" && -n "$_QREASON_FILE" ]] && printf '%s' "$1" >"$_QREASON_FILE"
    return 0
}
_take_reason() {
    local r=""
    [[ -n "$_QREASON_FILE" ]] && { r="$(cat "$_QREASON_FILE" 2>/dev/null)"; : >"$_QREASON_FILE"; }
    printf '%s' "${r:-gh error}"
}
_qreason_cleanup() { _bq_exit; }

# _reason_attempts <reason> -> "1" for a live failure whose label is unrecognised
# (the live attempt counts), nothing otherwise.
_reason_attempts() {
    case "$1" in "gh error"|"board read failed: gh error") printf '1' ;; esac
}

# _now_ns -> wall clock in nanoseconds (bash 5 EPOCHREALTIME is free; python elsewhere).
_now_ns() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local t="${EPOCHREALTIME//[.,]/}"
        printf '%s000' "$t"
    else
        python3 -c 'import time; print(time.time_ns())'
    fi
}

# _rate_limit_reset_human -> ISO-8601 UTC reset time: from the last rejected read's
# response header when still in the future, else the GRAPHQL resource of the
# REST rate_limit endpoint (the counter that's actually exhausted when
# GraphQL masks its own errors). If `resources.graphql` is absent from the
# payload, report "unknown" rather than falling back to the top-level `rate`
# key: in real gh responses `rate` ALIASES resources.core, whose reset can differ
# from graphql's by ~12min (see fixtures/gh-failures/rate-limit-endpoint-sample.json,
# issue #101). This string is interpolated into "rate-limited until X" messages,
# where a confident-but-wrong core-based timestamp is worse than an honest unknown.
_rate_limit_reset_human() {
    local raw saved now
    # Prefer the reset from the REJECTED response's X-Ratelimit-Reset header (saved by
    # project_items.py, #544): no extra call, and it is the counter that actually rejected.
    saved="$(cat "${PAGINATE_RESET_FILE:-/dev/null}" 2>/dev/null)"
    now="$(date +%s)"
    if [[ "$saved" =~ ^[0-9]+$ && "$saved" -gt "$now" ]]; then
        python3 -c '
import datetime, sys
print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$saved"
        return
    fi
    raw="$(gh api rate_limit 2>/dev/null)" || { echo "unknown"; return; }
    python3 -c '
import json, sys, datetime
try:
    ts = json.loads(sys.argv[1])["resources"]["graphql"]["reset"]
    print(datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
except Exception:
    print("unknown")
' "$raw"
}

# Short mutex around every REWRITE of the live queue file and every append to
# it (#561): a drop that rewrites the file must not lose an append or a flush
# requeue made meanwhile. Bounded wait (BOARD_QUEUE_FILE_LOCK_ITERS x 0.05s). A
# holder whose pid is dead is broken at once; a pidless lock only after 30s; a
# live holder never. The break renames the lock aside first (atomic), so two
# waiters cannot both end up holding it. Distinct from the flush lock above,
# which is held for a whole replay. Returns 1 if the wait ran out.
QUEUE_FILE_LOCK_DIR="$(dirname "$QUEUE_FILE")/board-queue.file.lock"
QUEUE_SPOOL_DIR="$(dirname "$QUEUE_FILE")/board-queue.spool"
# _lock_break_if <lockdir> <probed-pid>: break a lock whose holder was probed dead.
# The dir is renamed aside FIRST (atomic: one breaker wins), then the pid inside the
# renamed copy must still be the one that was probed -- otherwise another waiter broke
# it and a live holder re-took it between our probe and our rename, so the lock is put
# back. Returns 0 only when the stale lock is gone.
_lock_break_if() {
    local dir="$1" probed="$2" aside inner
    aside="$dir.stale.$$.$RANDOM"
    mv "$dir" "$aside" 2>/dev/null || return 1
    inner="$(cat "$aside/pid" 2>/dev/null || true)"
    if [[ "$inner" == "$probed" ]]; then
        rm -rf "$aside"
        return 0
    fi
    mv "$aside" "$dir" 2>/dev/null || rm -rf "$aside"
    return 1
}

# _lock_dead_holder <lockdir> -> prints the holder pid and returns 0 iff a pid file
# names a process that is no longer running.
_lock_dead_holder() {
    local hp
    hp="$(cat "$1/pid" 2>/dev/null || true)"
    [[ -n "$hp" ]] && ! kill -0 "$hp" 2>/dev/null && { printf '%s' "$hp"; return 0; }
    return 1
}

_qfile_lock() {
    local n=0 max="${BOARD_QUEUE_FILE_LOCK_ITERS:-100}" hp age dead
    mkdir -p "$(dirname "$QUEUE_FILE")"
    while :; do
        if mkdir "$QUEUE_FILE_LOCK_DIR" 2>/dev/null; then
            echo "$$" >"$QUEUE_FILE_LOCK_DIR/pid" 2>/dev/null || true
            _cleanup_add "$QUEUE_FILE_LOCK_DIR"
            return 0
        fi
        dead=0
        hp="$(cat "$QUEUE_FILE_LOCK_DIR/pid" 2>/dev/null || true)"
        if [[ -n "$hp" ]]; then
            kill -0 "$hp" 2>/dev/null || dead=1
        else
            age=$(( $(date +%s) - $(_dir_mtime "$QUEUE_FILE_LOCK_DIR") ))
            [[ "$age" -ge 30 ]] && dead=1
        fi
        [[ "$dead" -eq 1 ]] && _lock_break_if "$QUEUE_FILE_LOCK_DIR" "$hp"
        n=$((n + 1))
        [[ "$n" -ge "$max" ]] && return 1
        [[ "$dead" -eq 1 ]] || sleep 0.05
    done
}
# Remove the lock only if the pid inside is ours (a lock broken and re-taken by
# another process must not be released by its former, slow holder).
_qfile_unlock() {
    local hp
    hp="$(cat "$QUEUE_FILE_LOCK_DIR/pid" 2>/dev/null || true)"
    [[ "$hp" == "$$" ]] || return 0
    rm -f "$QUEUE_FILE_LOCK_DIR/pid" 2>/dev/null
    rmdir "$QUEUE_FILE_LOCK_DIR" 2>/dev/null || true
    _cleanup_del "$QUEUE_FILE_LOCK_DIR"
}

# _qwrite_line <json-line>: append one line to the queue. Two bounded waits for the
# file lock; if it is still held, write an atomic spool file instead (never an
# unlocked append next to a rewrite). The next flush merges the spool.
_qwrite_line() {
    mkdir -p "$(dirname "$QUEUE_FILE")"
    if _qfile_lock || _qfile_lock; then
        printf '%s\n' "$1" >>"$QUEUE_FILE"
        _qfile_unlock
        return 0
    fi
    mkdir -p "$QUEUE_SPOOL_DIR"
    local tmp name
    tmp="$(mktemp "$QUEUE_SPOOL_DIR/.tmp.XXXXXX")" || return 1
    printf '%s\n' "$1" >"$tmp"
    name="$(date +%s)-$$-$RANDOM"
    mv "$tmp" "$QUEUE_SPOOL_DIR/$name"
    return 0
}

# _spool_merge: move spooled entries into the queue file (caller holds the file lock).
_spool_merge() {
    local f
    [[ -d "$QUEUE_SPOOL_DIR" ]] || return 0
    for f in "$QUEUE_SPOOL_DIR"/*; do
        [[ -f "$f" ]] || continue
        cat "$f" >>"$QUEUE_FILE" && rm -f "$f"
    done
}

# queue_append <op> <key=value>... -> appends one JSON line (op + given keys
# + a ts and a nanosecond seq) to QUEUE_FILE. Values are passed as argv (never
# string-concatenated into JSON by hand) so titles/statuses with quotes/spaces
# stay safe. seq orders an entry against a supersede marker (see
# _queue_drop_moves) finer than the one-second ts.
queue_append() {
    local op="$1" line; shift
    line="$(python3 -c '
import json, sys, time
op = sys.argv[1]
d = {"op": op}
for pair in sys.argv[2:]:
    k, _, v = pair.partition("=")
    if k == "attempts" and v == "":
        continue
    d[k] = v
d["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
d.setdefault("seq", str(time.time_ns()))
print(json.dumps(d))
' "$op" "$@")"
    _qwrite_line "$line"
}

# _queue_append_raw <json-line>: flush's requeue, same lock and spool rules.
_queue_append_raw() { _qwrite_line "$1"; }

_jf() { # <json-line> <field> -> value ("" if absent)
    python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$1" "$2"
}

# _flush_sync <tag>: test-only synchronization point, a no-op in production.
# Two conditions must BOTH hold before this does anything (review #92
# round 2 -- an unbounded wait here, misfired outside a test, would hang
# every flush forever, silently):
#   1. BOARD_QUEUE_TEST_SYNC names a directory that exists.
#   2. That directory contains an explicit opt-in sentinel file,
#      .board-queue-test-sync -- a stray/leaked env var pointing at some
#      unrelated real directory must not activate this hook.
# When active: touches <dir>/<tag>.ready then blocks (poll) until
# <dir>/<tag>.go appears, capped at BOARD_QUEUE_TEST_SYNC_MAX_WAIT_ITERS
# iterations of a 0.02s sleep (default 1500 =~ 30s) -- past the cap it
# gives up loudly and proceeds, rather than hanging forever. Lets
# concurrency tests pin the exact interleaving of overlapping flush calls
# instead of racing on wall-clock sleeps (see section-board-queue.sh, #92).
_flush_sync() {
    local tag="$1" dir="${BOARD_QUEUE_TEST_SYNC:-}" waited=0 cap="${BOARD_QUEUE_TEST_SYNC_MAX_WAIT_ITERS:-1500}"
    [[ -n "$dir" && -d "$dir" && -f "$dir/.board-queue-test-sync" ]] || return 0
    : >"$dir/$tag.ready"
    while [[ ! -f "$dir/$tag.go" ]]; do
        sleep 0.02
        waited=$((waited + 1))
        if [[ "$waited" -ge "$cap" ]]; then
            echo "flush: WARNING _flush_sync($tag) gave up after $waited iterations waiting for $dir/$tag.go -- proceeding without the test hook" >&2
            return 0
        fi
    done
}

# _item_id_rl <issue#> -> prints the project item id to stdout if found.
# Cache-first (issue #78, .claude/board-cache.json, see board.sh): a cache
# HIT costs zero gh calls. A cache MISS costs one full board read
# (gh_project_items_json: a cursor-paginated slim GraphQL query), whose result
# refreshes the WHOLE cache as a side effect, so every other issue's lookup
# this session is then free too -- instead of a blind full re-read per lookup.
# Unlike item_id() (board.sh) this does NOT swallow the underlying read error
# — it distinguishes "no such item" from "the lookup itself failed" so callers
# can queue a rate limit (#90) and never misreport a failed read as
# "bad issue# or status".
# Return: 0 = found (id on stdout), 1 = real miss (the read succeeded, no
# such item/issue), 2 = the read failed and looks rate-limited, 4 = the read
# failed for another reason (GitHub's error is already on stderr). Callers
# must NOT treat 4 as "not on the board" (adopt/add-finish would item-add).
_item_id_rl() {
    local num="$1" hit out err rc id label
    hit="$(_cache_get "$num")" && { cut -f1 <<<"$hit"; return 0; }
    err="$(mktemp)"
    out="$(gh_project_items_json "$PN" "$OWNER" 2>"$err")"; rc=$?
    if [[ $rc -ne 0 ]]; then
        if _rate_limited "$(cat "$err")"; then
            rm -f "$err"
            return 2
        fi
        cat "$err" >&2
        # Board-wide read failure (#561): the reason names it, so a replay stops the pass
        # and keeps the queue instead of counting attempts against every entry.
        label="$(_gh_failure_label "$(cat "$err")")"
        _qreason "board read failed: $label"
        rm -f "$err"
        return 4
    fi
    rm -f "$err"
    # The cache refresh below is a pure side effect (best-effort write, see
    # board.sh) -- THIS call's correctness is decided by parsing $out
    # directly, so a write failure (e.g. read-only .claude/) can never turn a
    # real hit into a false miss.
    printf '%s' "$out" | _cache_refresh_from_items
    id="$(python3 -c '
import json, sys
try:
    n = int(sys.argv[1])
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for it in data.get("items", []):
    if (it.get("content") or {}).get("number") == n:
        print(it["id"])
        break
' "$num" <<<"$out")"
    if [[ -n "$id" ]]; then
        printf '%s' "$id"
        return 0
    fi
    return 1
}

# _poll_visible <issue#> -> prints the item id on stdout if it becomes
# visible within the cap. Cap: 2 attempts with backoff (0.3s, 0.6s) -- issue
# #78, down from the pre-#77 value of 10 and #77's own value of 3: each
# attempt is a cache-aware lookup (_item_id_rl), so a hit is free and even a
# miss costs one full-board call, not a blind re-list. Return: 0 = found (id
# on stdout), 1 = still not visible after the cap (caller defers to the
# queue), 2 = a lookup attempt looked rate-limited (caller defers to the
# queue too -- further polling would just burn quota for nothing), 4 = a
# lookup attempt failed for another reason (error already printed).
_poll_visible() {
    local num="$1" delays=(0.3 0.6) i id rc
    for i in 0 1; do
        id="$(_item_id_rl "$num")"; rc=$?
        if [[ $rc -eq 2 || $rc -eq 4 ]]; then return "$rc"; fi
        if [[ -n "$id" ]]; then printf '%s' "$id"; return 0; fi
        sleep "${delays[$i]}"
    done
    return 1
}

# _current_status: DELIBERATELY NOT cache-first, unlike _item_id_rl. This is
# flush's stale-move-regression guard (#92): it must see the TRUE remote
# status, because the whole reason a move is sitting in the queue is that it
# never actually applied -- the cache can only reflect mutations THIS script
# applied, never an out-of-band remote change (or a still-pending queued
# one), so trusting it here would silently defeat the guard. It still
# refreshes the whole cache as a side effect (the fetch happens either way),
# so _item_id_rl calls made right after this one are free.
_current_status() { # issue# -> status string ("" if not found / lookup failed)
    local num="$1" out current
    out="$(gh_project_items_json "$PN" "$OWNER" --strict)" || return 1
    # A repeat can only be discarded when a complete snapshot establishes
    # one target. A malformed/ambiguous read must retain queued recovery work.
    current="$(python3 "$HERE/wip.py" current "$CONFIG" "${BOARD:-}" "$num" <<<"$out")" || return 1
    printf '%s' "$out" | _cache_refresh_from_items
    printf '%s' "$current"
}

# _mutate_field <issue#> <field-id> <edit-flag> <value> <new-status-or-empty>
# -> shared by _do_move/_do_prio/_do_est: resolves the item id (cache-first),
# applies the edit, and on success updates the cache (issue #78 acceptance
# criterion 5 -- "every mutation updates the cached entry"). <new-status> is
# the status to cache iff this edit changes Status (move); empty leaves the
# cached status untouched (prio/est don't change it).
# If the edit itself fails for a reason that ISN'T a rate limit, the cached
# id may simply be stale (the item was removed from the board, the cache
# predates a board change, etc.) -- drop it and re-resolve ONCE (a fresh
# full-board lookup, bypassing the now-empty cache slot) before giving up,
# per criterion 5 ("a mutation rejected because remote state changed drops
# the entry and re-resolves once").
# Return: 0 = applied, 1 = real failure (message already printed), 2 =
# rate-limited, 3 = no such item (caller prints the specific message), 5 =
# queueable gh failure (#561: a board read or edit failed, not a rate limit; the
# reason is left for _take_reason: a transient label, "board read failed: <label>"
# for a board-wide read, or "gh error" for an unrecognised per-entry error, which
# the queue counts attempts for). Callers queue it so work never stops on a card.
_mutate_field() {
    local num="$1" field="$2" flag="$3" value="$4" new_status="$5" id out rc id2 label
    # Admission passes the exact fresh identity. It must never be replaced by
    # a concurrent cache refresh or the generic stale-id retry below.
    if [[ -n "${6:-}" ]]; then
        id="$6"
        rc=0
    else
        id="$(_item_id_rl "$num")"; rc=$?
    fi
    [[ $rc -eq 2 ]] && return 2
    [[ $rc -eq 4 ]] && return 5   # board-wide read failure; _item_id_rl left the reason
    [[ -z "$id" ]] && return 3
    out="$(gh project item-edit --id "$id" --project-id "$PID" --field-id "$field" "$flag" "$value" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        _cache_put "$num" "$id" "$new_status"
        return 0
    fi
    if _rate_limited "$out"; then
        return 2
    fi
    label="$(_gh_failure_label "$out")"
    # A 5xx/timeout/network failure says nothing about the cached id: report
    # and let the caller queue, without another board read (#561). During a
    # replay the id came from a snapshot read moments ago, so an unrecognised
    # error is not a stale id either: no full-board re-read, the entry's
    # attempt count takes it from here.
    if [[ "$label" != "gh error" || "${_FLUSH_USE_SNAP:-0}" == "1" || -n "${6:-}" ]]; then
        echo "$out" >&2
        _qreason "$label"
        return 5
    fi
    _cache_drop "$num"
    id2="$(_item_id_rl "$num")"; rc=$?
    if [[ $rc -eq 2 ]]; then return 2; fi
    if [[ $rc -eq 4 ]]; then return 5; fi
    if [[ -z "$id2" || "$id2" == "$id" ]]; then
        echo "$out" >&2
        _qreason "$label"
        return 5
    fi
    out="$(gh project item-edit --id "$id2" --project-id "$PID" --field-id "$field" "$flag" "$value" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        _cache_put "$num" "$id2" "$new_status"
        return 0
    fi
    if _rate_limited "$out"; then return 2; fi
    echo "$out" >&2
    _qreason "$(_gh_failure_label "$out")"
    return 5
}

# Lock ordering is flush -> WIP. Direct moves never take the flush lock.
# A subshell owns cleanup without overwriting the caller's queue traps. This
# directory is shared through ROOT across linked worktrees; never steal on age.
# Hard-crash leftovers require verified-idle manual recovery (see README).
_wip_mutate() (
    local num="$1" status="$2" opt="$3" lock="$ROOT/.claude/board-wip.lock"
    local waited=0 out err rc id dead
    if [[ "${_FLUSH_HOLDS_WIP:-0}" != "1" ]]; then
        mkdir -p "$(dirname "$lock")" || return 1
        until mkdir "$lock" 2>/dev/null; do
            # A SIGKILLed holder must not freeze board moves: break only on a DEAD pid.
            if dead="$(_lock_dead_holder "$lock")"; then
                echo "WIP: breaking admission mutex of dead holder (pid $dead)" >&2
                _lock_break_if "$lock" "$dead"
                continue
            fi
            if [[ "$waited" -eq 0 ]]; then
                echo "WIP: waiting for admission mutex $lock" >&2
            fi
            if [[ "$waited" -ge "${BOARD_WIP_MUTEX_MAX_WAIT_ITERS:-200}" ]]; then
                echo "WIP BLOCKED: admission mutex busy or stuck at $lock; verify all holders and child commands are idle before manual recovery (never remove a live lock)" >&2
                _qreason "admission mutex busy"
                return 5
            fi
            sleep 0.05
            waited=$((waited + 1))
        done
        trap 'rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
        printf '%s\n' "$$" >"$lock/pid" || return 1
    fi
    # Do not stretch the early checkpoint check across time spent waiting.
    bash "$HERE/checkpoint-preflight.sh" --root "$ROOT" --board "${BOARD:-}" --status "$status" || return 1
    err="$(mktemp)" || return 1
    if [[ "${_FLUSH_HOLDS_WIP:-0}" == "1" && -n "${_FLUSH_SNAP:-}" ]]; then
        # Replay (#561): the flush already read a complete snapshot under its lock and
        # patches it after every applied move, so N queued starts cost ONE board read.
        out="$_FLUSH_SNAP"; rc=0
    else
        out="$(gh_project_items_json "$PN" "$OWNER" --strict 2>"$err")"; rc=$?
    fi
    if [[ "$rc" -ne 0 ]]; then
        local errtext label
        errtext="$(cat "$err")"
        # rc=3 is malformed/incomplete data, never a transport rate limit.
        if [[ "$rc" -ne 3 ]] && _rate_limited "$errtext"; then
            rm -f "$err"
            return 2
        fi
        echo "WIP BLOCKED: cannot obtain complete board snapshot" >&2
        printf '%s\n' "$errtext" >&2
        rm -f "$err"
        if [[ "$rc" -eq 3 ]]; then
            label="board snapshot incomplete"
        else
            # Same label as a non-WIP live move that cannot read the board.
            label="board read failed: $(_gh_failure_label "$errtext")"
        fi
        _qreason "$label"
        return 5
    fi
    rm -f "$err"
    local over_flag=()
    [[ -n "${OVER_WIP_REASON:-}" ]] && over_flag=(--over)
    out="$(python3 "$HERE/wip.py" admit "$CONFIG" "${BOARD:-}" "$num" "$status" ${over_flag[@]+"${over_flag[@]}"} <<<"$out")" || return 1
    id="${out%%$'\n'*}"
    _mutate_field "$num" "$STATUS_FIELD" --single-select-option-id "$opt" "$status" "$id"; rc=$?
    # #560: an over-limit admission moved the card anyway; flag it once, from the
    # snapshot already read above (no extra board read): one comment, one local record.
    if [[ "$rc" -eq 0 && "$out" == *$'\nOVER '* ]]; then
        _over_wip_flag "$num" "$status" "${out##*OVER }"
    fi
    return "$rc"
)

# Same rule as guard-board-move.sh: a value must not be blank or start with `--`
# (a likely mis-parsed flag).
_over_wip_value_ok() { [[ -n "${1//[[:space:]]/}" && "$1" != --* ]]; }

_over_wip_flag() {
    local num="$1" status="$2" ratio="$3" by="${OVER_WIP_BY:-orchestrator}"
    # REST (not `gh issue comment`, which is GraphQL): one call, and a failure only warns.
    local bodyf
    bodyf="$(mktemp)" && printf 'Over WIP (%s): moved to %s although the lane limit was reached. Reason: %s. Asked by: %s.\n' \
        "$ratio" "$status" "$OVER_WIP_REASON" "$by" >"$bodyf" \
        && gh api -X POST "repos/$REPO/issues/$num/comments" -F "body=@$bodyf" >/dev/null \
        || echo "WARN: could not post the over-WIP comment on #$num (the move is applied)" >&2
    rm -f "$bodyf"
    python3 "$HERE/wip.py" record-over "$ROOT" "$CONFIG" "${BOARD:-}" "$num" "$OVER_WIP_REASON" "$by" "$status" "$ratio" \
        || echo "WARN: could not write the over-WIP record for #$num" >&2
    echo "OVER WIP $ratio: #$num moved to $status ($OVER_WIP_REASON)"
}

# _move_guards <issue#> <status>: every LOCAL precondition of a move (checkpoint,
# gate, red-first, design-registry, two-pass review, closure, comments read). No
# gh call. Returns 1 with the refusal printed. Flush runs it BEFORE any board read
# so a guard-refused queued entry costs zero gh calls per board.sh call (#561).
_move_guards() {
    local num="$1" status="$2" norm_status _seen
    # Check the active board's configured work status, independently of the
    # historical English-label comment/review/closure guards below.
    bash "$HERE/checkpoint-preflight.sh" --root "$ROOT" --board "${BOARD:-}" --status "$status" || return 1
    norm_status="$(python3 -c 'import re,sys; print(re.sub(r"\s+"," ",sys.argv[1].strip()).lower())' "$status")"
    if [[ "$norm_status" == "in review" ]]; then
        bash "$HERE/gate-preflight.sh" || return 1
        # #235 (CDX-031 gap #3): red-first TDD commit-ordering check, same
        # precondition point/failure contract as gate-preflight.sh above --
        # a structural heuristic (commit order only, no test execution), see
        # red-first-preflight.sh's own header comment for the full rationale.
        bash "$HERE/red-first-preflight.sh" || return 1
        # #461 (team-lead round-2 review item 1): mechanical enforcement
        # that a finalized UI design registered against this issue was
        # actually APPLIED before the task can go to review -- same
        # precondition point/failure contract as the two checks above.
        # See design-registry-preflight.sh's own header for the known
        # forward-enforcing-only limitation.
        bash "$HERE/design-registry-preflight.sh" --root "$ROOT" --issue "$num" || return 1
    fi
    # #236 (CDX-031 gap #4): a move to "QA" requires both documented review
    # passes (spec-compliance, code-quality) to be recorded in telemetry for
    # this task -- independent of, and a DIFFERENT transition than, the
    # "in review" checks above (two-pass review happens AFTER "In review" in
    # this workflow's actual sequencing; see two-pass-review-preflight.sh's
    # own header comment and docs/design/cdx-E3.md's "Follow-up: #236").
    if [[ "$norm_status" == "qa" ]]; then
        bash "$HERE/two-pass-review-preflight.sh" --root "$ROOT" --task "$num" || return 1
    fi
    # #238: post-merge learning evidence precedes terminal board mutations,
    # through this same entrypoint for direct commands and queued replay.
    if [[ "$norm_status" == "ready" || "$norm_status" == "deployed" ]]; then
        bash "$HERE/closure-preflight.sh" --root "$ROOT" --task "$num" || return 1
    fi
    # #234 (CDX-031 gap #2): a move to "In progress" requires that this
    # issue's comments were actually read via `board.sh show` first --
    # existence-only marker (see board.sh's show) case), not staleness-aware
    # by design: a comment posted after show but before this move is a real
    # but deliberately out-of-scope gap (would need a new live gh call in
    # this hot path, which flush replay also runs through).
    if [[ "$norm_status" == "in progress" ]]; then
        _seen="$(python3 -c '
import json, sys
path, num = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except (OSError, ValueError):
    data = {}
print("yes" if data.get(num) is True else "no")
' "$ROOT/.claude/board-comments-seen.json" "$num" 2>/dev/null)"
        if [[ "$_seen" != "yes" ]]; then
            echo "BLOCKED: issue #$num's comments have not been read this session -- run \`bash \"$HERE/board.sh\" show $num\` first, its comments must be read before implementation starts, then retry the move to 'In progress'." >&2
            return 1
        fi
    fi
    return 0
}

# _do_move/_do_prio/_do_est: same effect as the move/prio/est case branches,
# factored out so both the live command AND flush replay share one
# implementation. Return 0 = applied, 1 = guard/validation refusal (never
# queued; replay drops it), 2 = rate-limited (caller decides: queue live, or
# re-queue-and-stop in flush), 5 = retryable failure that is not a rate limit
# (#561: gh/network error, incomplete snapshot, busy admission mutex; the
# caller queues it and reads the reason with _take_reason).
#
# CDX-030 (SPEC-CODEX-COMPAT.md §9.1/§12): a move to "In review" runs
# gate-preflight.sh BEFORE any mutation, regardless of entrypoint (direct
# call, flush replay, a future non-hook wrapper) -- this is the actual
# gate-before-review enforcement point; the Claude PreToolUse hook
# (guard-board-move.sh) is defense in depth on top of it, not the sole
# mechanism (Codex has no hook-equivalent lifecycle event at all). Status
# comparison is normalized the same way guard-board-move.sh's norm() does
# (collapse whitespace, lowercase) so "In review"/"in review"/etc. all match.
_do_move() {
    local num="$1" status="$2" opt rc
    _qreason_begin
    if [[ "${_GUARDS_DONE:-}" != "$num:$status" ]]; then
        _move_guards "$num" "$status" || return 1
    fi
    opt="$(opt_id status "$status")"
    if [[ -z "$opt" ]]; then
        echo "ERROR: bad issue# or status '$status' (must match statusFlow)" >&2
        return 1
    fi
    python3 "$HERE/wip.py" classify "$CONFIG" "${BOARD:-}" "$status"; rc=$?
    case "$rc" in
        0) _wip_mutate "$num" "$status" "$opt"; rc=$? ;;
        3) _mutate_field "$num" "$STATUS_FIELD" --single-select-option-id "$opt" "$status"; rc=$? ;;
        *) return 1 ;;
    esac
    case "$rc" in
        0)
            _APPLIED_NS="$(_now_ns)"
            echo "moved #$num -> $status"
            python3 "$HERE/telemetry.py" "$ROOT" record \
                "{\"kind\":\"transition\",\"task\":\"$num\",\"from\":\"\",\"to\":\"$status\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
                >/dev/null 2>&1 || true
            return 0
            ;;
        2) return 2 ;;
        5) return 5 ;;
        3) echo "ERROR: bad issue# or status '$status' (must match statusFlow)" >&2; return 1 ;;
        *) return 1 ;;
    esac
}

_do_prio() {
    local num="$1" prio="$2" opt rc
    _qreason_begin
    opt="$(opt_id priority "$prio")"
    if [[ -z "$opt" ]]; then
        echo "ERROR: bad issue# or priority '$prio'" >&2
        return 1
    fi
    _mutate_field "$num" "$PRIO_FIELD" --single-select-option-id "$opt" ""; rc=$?
    case "$rc" in
        0) echo "prio #$num -> $prio"; return 0 ;;
        2) return 2 ;;
        5) return 5 ;;
        3) echo "ERROR: bad issue# or priority '$prio'" >&2; return 1 ;;
        *) return 1 ;;
    esac
}

_do_est() {
    local num="$1" points="$2" rc
    _qreason_begin
    if [[ -z "$EST_FIELD" ]]; then
        echo "ERROR: no estimate field configured" >&2
        return 1
    fi
    _mutate_field "$num" "$EST_FIELD" --number "$points" ""; rc=$?
    case "$rc" in
        0) echo "est #$num -> $points"; return 0 ;;
        2) return 2 ;;
        5) return 5 ;;
        3) echo "ERROR: bad issue# '$num'" >&2; return 1 ;;
        *) return 1 ;;
    esac
}

# _do_add_finish: the remainder of `add`'s work after the issue itself
# exists (item-add, poll for visibility, move to FIRST_STATUS, set prio).
# Used both by `add`'s own fallback (visibility cap hit) and by flush
# replaying a queued add-finish op. Idempotent: skips item-add / move when
# the item is already visible / already at the target status.
_do_add_finish() {
    local num="$1" url="$2" first_status="$3" prio="$4" id out rc cur
    _qreason_begin
    if [[ "${_FLUSH_USE_SNAP:-0}" == "1" ]]; then
        # Replay: the flush snapshot answers presence and status; at most ONE extra read
        # (after item-add) to see the new card -- no polling, no separate status read.
        if ! _flush_snap_has "$num"; then
            out="$(gh project item-add "$PN" --owner "$OWNER" --url "$url" 2>&1)"; rc=$?
            if [[ $rc -ne 0 ]]; then
                _rate_limited "$out" && return 2
                echo "ERROR: add-finish #$num: gh project item-add failed: $out" >&2
                _qreason "$(_gh_failure_label "$out")"
                return 5
            fi
            _flush_snap_refresh; rc=$?
            [[ $rc -eq 2 ]] && return 2
            [[ $rc -ne 0 ]] && return 5
            if ! _flush_snap_has "$num"; then _qreason "board read failed: card not visible yet"; return 5; fi
        fi
        cur="$(_flush_snap_status_of "$num")"
    else
        id="$(_item_id_rl "$num")"; rc=$?
        [[ $rc -eq 2 ]] && return 2
        [[ $rc -eq 4 ]] && return 5  # could not read the board: that is not "not on the board"; retry later, never counts an attempt
        if [[ -z "$id" ]]; then
            out="$(gh project item-add "$PN" --owner "$OWNER" --url "$url" 2>&1)"; rc=$?
            if [[ $rc -ne 0 ]]; then
                _rate_limited "$out" && return 2
                echo "ERROR: add-finish #$num: gh project item-add failed: $out" >&2
                _qreason "$(_gh_failure_label "$out")"
                return 5
            fi
            id="$(_poll_visible "$num")"; rc=$?
            [[ $rc -eq 4 ]] && return 5
            [[ -z "$id" ]] && return 2  # still not visible (or rate-limited) within the cap -- re-queue, try again later
        fi
        cur="$(_current_status "$num")"
    fi
    # The first status is only for a card that has NONE: a card somebody (or a direct move)
    # already moved is never put back (independent review 1).
    if [[ -z "$cur" || "$cur" == "-" ]]; then
        _do_move "$num" "$first_status"; rc=$?
        [[ "$rc" -ne 0 ]] && return "$rc"
        [[ "${_FLUSH_USE_SNAP:-0}" == "1" ]] && _flush_snap_patch "$num" "$first_status"
    fi
    _do_prio "$num" "$prio"; rc=$?
    [[ "$rc" -ne 0 ]] && return "$rc"
    echo "flush: finished add #$num [$prio]"
    return 0
}

# _do_adopt: add an EXISTING issue to the board (issue #84). Idempotent —
# a no-op (with a message) if the issue is already a board item. #92: a
# freshly-added item has no Status set by item-add itself (it landed with
# '-' on the board) -- poll briefly for visibility (same cache-aware,
# 2-attempt/backoff cap as _do_add_finish -- issue #78 -- via _poll_visible)
# and set FIRST_STATUS, matching `add`'s behavior. If the item never
# becomes visible in that window the adopt still succeeds (the issue IS on
# the board); if setting the status itself rate-limits, queue a follow-up
# move instead of failing the whole adopt.
_do_adopt() {
    local num="$1" id url out rc cur
    _qreason_begin
    if [[ "${_FLUSH_USE_SNAP:-0}" == "1" ]] && ! _flush_snap_has "$num"; then
        id=""; rc=0   # the fresh snapshot already proves it is absent: no second read
    else
        id="$(_item_id_rl "$num")"; rc=$?
    fi
    [[ $rc -eq 2 ]] && return 2
    [[ $rc -eq 4 ]] && return 5  # could not read the board: that is not "not on the board"
    if [[ -n "$id" ]]; then
        # Already a board item. Its status may still be empty (a half-finished add/adopt):
        # set the first status then, never touch a card somebody already moved (#561).
        local st
        if [[ "${_FLUSH_USE_SNAP:-0}" == "1" ]]; then
            st="$(_flush_snap_status_of "$num")"   # the fresh snapshot, never a cache that may be stale
        else
            st="$(_cache_get "$num" | cut -f2)"
            if [[ -z "$st" || "$st" == "-" ]]; then st="$(_current_status "$num")" || st="?"; fi
        fi
        # shellcheck disable=SC2153  # FIRST_STATUS is the global set by board.sh's eval block
        if [[ -z "$st" || "$st" == "-" ]]; then
            _do_move "$num" "$FIRST_STATUS"; rc=$?
            if [[ "$rc" -eq 0 ]]; then
                [[ "${_FLUSH_USE_SNAP:-0}" == "1" ]] && _flush_snap_patch "$num" "$FIRST_STATUS"
                echo "adopt #$num: already on board, initial status set"; return 0
            fi
            return "$rc"
        fi
        echo "adopt #$num: already on board"
        return 0
    fi
    url="https://github.com/$REPO/issues/$num"
    out="$(gh project item-add "$PN" --owner "$OWNER" --url "$url" 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]]; then
        _rate_limited "$out" && return 2
        echo "ERROR: adopt #$num: gh project item-add failed: $out" >&2
        _qreason "$(_gh_failure_label "$out")"
        return 5
    fi
    if [[ "${_FLUSH_USE_SNAP:-0}" == "1" ]]; then
        # Replay: one read-back, patched into the shared snapshot; a failure is retryable and
        # stops the pass (the original queue entry stays; nothing new is queued).
        _flush_snap_refresh; rc=$?
        [[ $rc -eq 2 ]] && return 2
        [[ $rc -ne 0 ]] && return 5
        if ! _flush_snap_has "$num"; then _qreason "board read failed: card not visible yet"; return 5; fi
        local st; st="$(_flush_snap_status_of "$num")"
        if [[ -z "$st" || "$st" == "-" ]]; then
            # shellcheck disable=SC2153  # FIRST_STATUS is the global set by board.sh's eval block
            _do_move "$num" "$FIRST_STATUS"; rc=$?
            [[ "$rc" -ne 0 ]] && return "$rc"
            _flush_snap_patch "$num" "$FIRST_STATUS"
        fi
        echo "adopted #$num"
        return 0
    fi
    id="$(_poll_visible "$num")"; rc=$?
    if [[ $rc -eq 2 ]]; then echo "adopted #$num"; return 0; fi
    if [[ $rc -eq 4 ]]; then
        # The item IS on the board; only its initial status is unknown. Queue an adopt op:
        # replay re-checks membership and sets the first status only if it is still empty,
        # so a card a human moved meanwhile is left alone (#561 round 4).
        local why; why="$(_take_reason)"
        echo "adopt #$num: added to board but could not read it back to set the initial status" >&2
        queue_append adopt issue="$num" reason="$why" attempts="$(_reason_attempts "$why")"
        echo "QUEUED ($why): adopt #$num"
        return 0
    fi
    if [[ -n "$id" ]]; then
        cur="$(_current_status "$num")"
        # shellcheck disable=SC2153  # FIRST_STATUS is the global set by board.sh's
        # eval block, not a typo of a local first_status
        if [[ "$cur" != "$FIRST_STATUS" ]]; then
            _do_move "$num" "$FIRST_STATUS"; rc=$?
            if [[ "$rc" -eq 2 ]]; then
                queue_append move issue="$num" status="$FIRST_STATUS" reason="rate-limited"
            elif [[ "$rc" -eq 5 ]]; then
                local why; why="$(_take_reason)"
                queue_append move issue="$num" status="$FIRST_STATUS" reason="$why" attempts="$(_reason_attempts "$why")"
            elif [[ "$rc" -ne 0 ]]; then
                echo "ERROR: adopt #$num: added to board but failed to set initial status" >&2
                return 1
            fi
        fi
    fi
    echo "adopted #$num"
    return 0
}

# _queue_pending -> prints one "PENDING: move #N -> S (queued <age>, <reason>)"
# line per queued move, oldest first. Reads QUEUE_FILE only: ZERO gh calls
# (#561 -- the human's quota budget). Entries queued before reasons existed
# were rate-limit queued, so they read "rate-limited".
_queue_pending() {
    local spooled=""
    [[ -d "$QUEUE_SPOOL_DIR" ]] && spooled="$(cat "$QUEUE_SPOOL_DIR"/* 2>/dev/null)"
    [[ -s "$QUEUE_FILE" || -n "$spooled" ]] || return 0
    { cat "$QUEUE_FILE" 2>/dev/null; [[ -n "$spooled" ]] && printf '%s\n' "$spooled"; true; } | python3 -c '
import json, sys, time, calendar
now = time.time()
for ln in sys.stdin.read().splitlines():
    try:
        d = json.loads(ln)
    except Exception:
        continue
    if d.get("op") != "move":
        continue
    try:
        age = max(0, int(now - calendar.timegm(time.strptime(d.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ"))))
    except Exception:
        age = 0
    if age < 60:
        a = "%ds ago" % age
    elif age < 3600:
        a = "%dm ago" % (age // 60)
    elif age < 86400:
        a = "%dh ago" % (age // 3600)
    else:
        a = "%dd ago" % (age // 86400)
    print("PENDING: move #%s -> %s (queued %s, %s)" % (d.get("issue", "?"), d.get("status", "?"), a, d.get("reason") or "rate-limited"))
'
}

# Supersede markers (#561): $(dirname QUEUE_FILE)/board-queue.superseded/<issue>
# holds the nanosecond time a direct move of that issue applied. Any queued move
# of the issue with a smaller seq is stale: it must not replay and regress the
# newer status. The marker is written first and without a lock (one atomic
# rename), so a flush that already moved the queue aside still honours it.
_supersede_dir() { printf '%s' "$(dirname "$QUEUE_FILE")/board-queue.superseded"; }

# _queue_drop_moves <issue#>: a move that just applied supersedes older queued
# moves for the same issue. Marker first, then the rewrite under the queue file
# lock (bounded wait; if it runs out the marker alone keeps replay correct).
_queue_drop_moves() {
    local dir ns="${2:-}"; dir="$(_supersede_dir)"
    [[ -n "$ns" ]] || ns="$(_now_ns)"
    mkdir -p "$dir"
    python3 -c '
import os, sys
d, num, ns = sys.argv[1], sys.argv[2], sys.argv[3]
tmp = os.path.join(d, ".%s.%d" % (num, os.getpid()))
with open(tmp, "w") as f:
    f.write(ns)
os.replace(tmp, os.path.join(d, num))
' "$dir" "$1" "$ns"
    find "$dir" -type f -mtime +1 -delete 2>/dev/null || true
    _qfile_lock || return 0
    if [[ -s "$QUEUE_FILE" ]]; then
        python3 -c '
import calendar, json, os, sys, time
path, num, marker = sys.argv[1], sys.argv[2], int(open(sys.argv[3]).read() or 0)
def seq(d):
    try:
        return int(d["seq"])
    except Exception:
        return calendar.timegm(time.strptime(d.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ")) * 10**9
keep = []
for ln in open(path).read().splitlines():
    if not ln.strip():
        continue
    try:
        d = json.loads(ln)
        if d.get("op") == "move" and str(d.get("issue")) == num and seq(d) < marker:
            continue
    except Exception:
        pass
    keep.append(ln)
tmp = path + ".drop.%d" % os.getpid()
with open(tmp, "w") as f:
    for ln in keep:
        f.write(ln + "\n")
os.replace(tmp, path)
' "$QUEUE_FILE" "$1" "$dir/$1"
    fi
    _qfile_unlock
}

# _entry_seq <json-line> -> the entry's nanosecond seq (an entry without one: its ts as ns).
_entry_seq() {
    python3 -c '
import calendar, json, sys, time
d = json.loads(sys.argv[1])
try:
    print(int(d["seq"]))
except Exception:
    print(calendar.timegm(time.strptime(d.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ")) * 10**9)
' "$1"
}

# _superseded <json-line> -> 0 iff a newer applied move of the same issue exists.
_superseded() {
    local m; m="$(_supersede_dir)/$(_jf "$1" issue)"
    [[ -f "$m" ]] || return 1
    python3 -c '
import calendar, json, sys, time
d = json.loads(sys.argv[1])
try:
    seq = int(d["seq"])
except Exception:
    seq = calendar.timegm(time.strptime(d.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ")) * 10**9
sys.exit(0 if seq < int(open(sys.argv[2]).read() or 0) else 1)
' "$1" "$m" 2>/dev/null
}

# Back-off (#561): an entry that failed retryably 3 times in a row is replayed at most once
# per BOARD_QUEUE_BACKOFF_SECS (default 600), so polling (neural-view's `list`) cannot burn a
# read + an edit per poll against a persistently failing call.
_line_with_fail() {
    python3 -c '
import json, sys, time
d = json.loads(sys.argv[1])
d["fails"] = str(int(d.get("fails") or 0) + 1)
d["last_try"] = str(int(time.time()))
# keep the line style it came in (compact stays compact)
print(json.dumps(d, separators=(",", ":")) if "\": \"" not in sys.argv[1] else json.dumps(d))
' "$1"
}
_backed_off() {
    python3 -c '
import json, sys, time
d = json.loads(sys.argv[1])
try:
    fails, last = int(d.get("fails") or 0), int(d.get("last_try") or 0)
except ValueError:
    sys.exit(1)
sys.exit(0 if fails >= 3 and time.time() - last < int(sys.argv[2]) else 1)
' "$1" "${BOARD_QUEUE_BACKOFF_SECS:-600}" 2>/dev/null
}

# _line_with_attempts <json-line> <n> -> the line with attempts=n (string).
_line_with_attempts() {
    python3 -c '
import json, sys
d = json.loads(sys.argv[1]); d["attempts"] = sys.argv[2]
print(json.dumps(d))
' "$1" "$2"
}

# _dir_mtime <dir> -> mtime as epoch seconds (GNU stat, then BSD/macOS stat;
# 0 if neither works, which never satisfies a staleness check as "past TTL"
# less than TTL is treated as fresh, so a stat failure fails safe: the lock
# is treated as held, never spuriously broken).
_dir_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date +%s
}

# _queue_lock_acquire: mkdir-based mutex (#92) -- portable on bash 3.2/macOS,
# which has no flock builtin, and mkdir is atomic on every POSIX filesystem.
# Returns 0 = lock now held by us, 1 = another flush holds a live lock (the
# caller SKIPS -- never blocks, never replays concurrently). A lock older
# than QUEUE_LOCK_TTL is broken with a warning: a flusher that crashed
# mid-flush must not wedge the queue forever.
#
# Liveness probe (#104): the TTL-only check above meant a crashed flush's
# lock sat SKIPping every auto-flush for up to the full TTL (600s default)
# even though the holder was verifiably dead seconds after the crash -- the
# 2026-07-08 incident needed a human to `ps`/rmdir it by hand. Every
# acquired lock now also gets a pidfile ($QUEUE_LOCK_DIR/pid, this process's
# $$). When mkdir fails (someone else holds it), read that pidfile FIRST: if
# it names a PID that `kill -0` says isn't running, the holder is
# definitively dead -- break the lock immediately, regardless of the TTL
# age, instead of waiting it out. A pidfile naming a live PID, or no
# pidfile at all (e.g. a lock left by a pre-#104 build), falls back to the
# existing TTL-age behavior unchanged.
_queue_lock_acquire() {
    mkdir -p "$(dirname "$QUEUE_LOCK_DIR")"
    if mkdir "$QUEUE_LOCK_DIR" 2>/dev/null; then
        echo "$$" >"$QUEUE_LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi
    local holder_pid age
    holder_pid="$(cat "$QUEUE_LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
        echo "flush: WARNING breaking dead-holder lock (pid $holder_pid not running)" >&2
        rm -f "$QUEUE_LOCK_DIR/pid"
        rmdir "$QUEUE_LOCK_DIR" 2>/dev/null
        if mkdir "$QUEUE_LOCK_DIR" 2>/dev/null; then
            echo "$$" >"$QUEUE_LOCK_DIR/pid" 2>/dev/null || true
            return 0
        fi
    fi
    age=$(( $(date +%s) - $(_dir_mtime "$QUEUE_LOCK_DIR") ))
    if [[ "$age" -ge "$QUEUE_LOCK_TTL" ]]; then
        echo "flush: WARNING breaking stale lock (age ${age}s >= ${QUEUE_LOCK_TTL}s TTL) -- a previous flush likely crashed" >&2
        rm -f "$QUEUE_LOCK_DIR/pid"
        rmdir "$QUEUE_LOCK_DIR" 2>/dev/null
        if mkdir "$QUEUE_LOCK_DIR" 2>/dev/null; then
            echo "$$" >"$QUEUE_LOCK_DIR/pid" 2>/dev/null || true
            return 0
        fi
    fi
    return 1
}

_queue_lock_release() {
    rm -f "$QUEUE_LOCK_DIR/pid" 2>/dev/null
    rmdir "$QUEUE_LOCK_DIR" 2>/dev/null || true
}

# _dedupe_aside <file>: rewrites <file> in place (review #92 round 2,
# BLOCKING finding), keeping only the most-recently-enqueued entry per
# (op, issue) for op kinds whose replay can regress a value if a stale
# entry re-applies after a newer one already has (move/prio/est). Without
# this: a rate-limited requeue appends the OLDER op to the TAIL of the
# live queue file, but a NEWER op for the same issue can already be
# sitting there (queued live while the first flush was mid-flight) ahead
# of it. Replay in file order then applies the newer one first (cur
# becomes its target) and the stale older one second -- the `cur ==
# target` skip guard doesn't catch this, since cur is now the NEWER
# target, not the one the stale op checks against -- so the stale op
# re-applies and regresses the value. Recency is judged by each entry's
# own `ts` (untouched across every requeue, so it always reflects original
# enqueue time, not append time); ties keep the later file position.
# Survivors keep their original relative order -- only the stale
# duplicates are dropped.
_dedupe_aside() {
    python3 -c '
import json, sys

path = sys.argv[1]
DEDUPE_OPS = {"move", "prio", "est"}
with open(path) as f:
    lines = [ln for ln in f.read().splitlines() if ln.strip()]

import calendar, time

def rank(d):
    # nanosecond seq when present; the one-second ts (as ns) only for entries without one
    try:
        return int(d["seq"])
    except Exception:
        try:
            return calendar.timegm(time.strptime(d.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ")) * 10**9
        except Exception:
            return 0

best_idx = {}  # (op, issue) -> (rank, line-index) of the winning entry
for i, ln in enumerate(lines):
    try:
        d = json.loads(ln)
    except Exception:
        continue
    op = d.get("op")
    if op not in DEDUPE_OPS:
        continue
    # Only the NEWEST entry per (op, issue) survives; an older flagged move never overrides a
    # newer plain one (the flag is carried over below, and only to the same target status).
    key = (op, d.get("issue"))
    r = rank(d)
    if key not in best_idx or r >= best_idx[key][0]:
        best_idx[key] = (r, i)

winners = {idx for _, idx in best_idx.values()}

# #560 x #561: a winning plain move inherits the over_wip flag of the newest OLDER flagged
# move for the same issue, but only when both target the same status.
carry = {}
for i, ln in enumerate(lines):
    try:
        d = json.loads(ln)
    except Exception:
        continue
    if d.get("op") != "move" or not d.get("over_wip") or i in winners:
        continue
    k = (d.get("issue"), d.get("status"))
    if k not in carry or rank(d) >= rank(carry[k]):
        carry[k] = d

kept = []
for i, ln in enumerate(lines):
    try:
        d = json.loads(ln)
    except Exception:
        kept.append(ln)
        continue
    if d.get("op") not in DEDUPE_OPS or i in winners:
        if d.get("op") == "move" and not d.get("over_wip"):
            c = carry.get((d.get("issue"), d.get("status")))
            if c is not None and rank(c) < rank(d):
                d["over_wip"] = c["over_wip"]
                d["over_wip_by"] = c.get("over_wip_by", "orchestrator")
                ln = json.dumps(d)
        kept.append(ln)

with open(path, "w") as f:
    for ln in kept:
        f.write(ln + "\n")
' "$1"
}

# _flush_queue [--verbose]: replay QUEUE_FILE in order, guarded by the
# lockdir mutex. A second flush that can't take the lock SKIPS immediately
# (issue #92) -- never blocks, never replays concurrently with another
# flush. The lock is taken BEFORE the emptiness check (not after): once
# another flush has moved the queue file aside, the live path is briefly
# and legitimately empty, but that's a "locked" state, not a "nothing to
# do" state -- an emptiness check ahead of the lock attempt would
# misreport the former as the latter. --verbose (used by the explicit
# `flush` verb) prints "queue empty" when there's genuinely nothing to do
# AFTER the lock is held -- so it can never misfire as "empty" during
# another flush's momentary aside-move window. Auto-flush call sites
# (next/list/show) omit --verbose and stay silent on an empty queue,
# matching pre-#92 behavior.
_flush_queue() {
    local verbose=0
    [[ "${1:-}" == "--verbose" ]] && verbose=1
    if ! _queue_lock_acquire; then
        echo "flush: SKIP -- another flush holds the lock ($QUEUE_LOCK_DIR)"
        return 0
    fi
    if _qfile_lock; then _spool_merge; _qfile_unlock; fi
    if [[ -s "$QUEUE_FILE" ]]; then
        _flush_queue_locked
    elif [[ "$verbose" -eq 1 ]]; then
        echo "queue empty"
    fi
    _queue_lock_release
}

# _aside_write_remaining <aside-file> <line>... : atomically REPLACES
# <aside-file> with exactly the given lines (one per arg), one per line.
# Factored out of _flush_queue_locked (#104) so the durability invariant it
# exists to maintain -- an entry's bytes exist on disk (aside or queue)
# until its mutation is CONFIRMED applied, never a delete-then-apply window
# -- has one tested chokepoint instead of being inlined at every call site.
# Review finding (#104, round 1): an earlier version truncated <aside-file>
# in place (`: >"$file"` then appended line-by-line) -- a kill -9 between
# the truncate and the last append left the aside file empty or partially
# written, i.e. an entry mid-rewrite in neither the aside file nor
# $QUEUE_FILE, exactly the invariant this function exists to close. Fixed
# by writing the new content to a sibling temp file first, then a single
# atomic `mv` over the aside path (same filesystem, one rename syscall --
# the same mv-based atomicity _flush_queue_locked already relies on for the
# queue file itself, just applied here too): the aside path always shows
# either its old (pre-rewrite) content or its new (post-rewrite) content in
# full, never a partial write.
#
# BOARD_QUEUE_TEST_ASIDE_SYNC=1 (test-only, opt-in SEPARATELY from the
# general BOARD_QUEUE_TEST_SYNC gate _flush_sync itself checks) pauses right
# before the `mv`, tagged "<BOARD_QUEUE_TEST_TAG>-aside-write" -- lets a test
# pin exactly this window and assert the aside path still shows its OLD,
# untruncated content while the new content sits only in the sibling temp
# file. Gated behind its own flag (not just _flush_sync's existing dir+
# sentinel check) because this call happens once per queued line, not once
# per flush -- an unconditional pause here would silently cost every OTHER
# test that already sets BOARD_QUEUE_TEST_SYNC (v/w/x/m/n/r/s) up to
# BOARD_QUEUE_TEST_SYNC_MAX_WAIT_ITERS' worth of wall-clock time per line,
# since none of them know about this tag and would never supply its .go file.
_aside_write_remaining() {
    local file="$1"; shift
    local tmp l
    tmp="$(mktemp "$(dirname "$file")/.flush-remaining.XXXXXX")"
    for l in "$@"; do
        printf '%s\n' "$l" >>"$tmp"
    done
    [[ "${BOARD_QUEUE_TEST_ASIDE_SYNC:-0}" == "1" ]] && _flush_sync "${BOARD_QUEUE_TEST_TAG:-flush}-aside-write"
    mv "$tmp" "$file"
}

# _flush_queue_locked: the actual replay, called with the lock already held.
# Lost-append prevention (#92): instead of a blind truncate, the queue file
# is MOVED ASIDE atomically (mv, same filesystem -- a single rename syscall,
# no read-then-clear gap for a concurrent queue_append to fall into and get
# wiped) before replay. Any re-queued remainder is appended back to the LIVE
# queue path afterward -- which new queue_appends may have grown meanwhile --
# instead of clobbering it.
#
# Durability (#104): a live incident (2026-07-08) saw a flush die mid-replay
# and leave NEITHER the queue file NOR the aside file behind -- every queued
# mutation had to be reconstructed by hand from session memory. The prior
# code unconditionally `rm -f`'d the aside file once the loop over its lines
# finished, regardless of whether each line had actually been confirmed
# applied -- a kill -9 anywhere in the loop (or in the final rm itself) could
# lose everything not yet requeued to $QUEUE_FILE. Fixed by rewriting the
# aside file (via _aside_write_remaining) after EVERY line is resolved --
# applied, requeued (rate limit), or written back on a real failure -- so it
# always holds exactly "remaining unconfirmed work": a crash at any point
# leaves every not-yet-confirmed entry either still in the aside file or
# already durably in $QUEUE_FILE, never in neither. The trailing `rm -f
# "$aside"` is then just tidying up an already-empty file, not a durability
# boundary.
#
# Also #104: a real (non-rate-limit, rc=1) apply failure used to vanish the
# line silently -- only rc==2 (rate-limited) got written back anywhere. Now
# rc==1 writes the line back to $QUEUE_FILE too (so a human/next flush can
# see and address it -- _mutate_field already echoes the underlying gh error
# to stderr) instead of dropping it, and the loop keeps processing the
# REMAINING lines (unlike rc==2, which stops touching gh at all -- once
# rate-limited, further calls this pass would just burn quota for nothing).
# Replay reads the board AT MOST ONCE per flush (#561): the first queued move
# fetches a complete snapshot (under the flush lock); every later one -- WIP
# admission included, see _wip_mutate -- reuses it, and _flush_snap_patch keeps it
# current after each applied move. A failed fetch is not retried per op and sets
# FLUSH_SNAP_RC (2 rate-limited, 5 retryable + FLUSH_SNAP_REASON, 1 loud).
# Called directly, never in $(...), so the globals survive. Sets FLUSH_CUR.
_flush_snap_status() {
    local err rc errtext
    FLUSH_CUR=""
    if [[ -z "${_FLUSH_SNAP:-}" && "${_FLUSH_SNAP_FAILED:-0}" != "1" ]]; then
        err="$(mktemp)"
        _FLUSH_SNAP="$(gh_project_items_json "$PN" "$OWNER" --strict 2>"$err")"; rc=$?
        if [[ "$rc" -ne 0 ]]; then
            _FLUSH_SNAP=""; _FLUSH_SNAP_FAILED=1
            errtext="$(cat "$err")"; rm -f "$err"
            echo "WIP BLOCKED: cannot obtain complete board snapshot" >&2
            printf '%s\n' "$errtext" >&2
            if [[ "$rc" -ne 3 ]] && _rate_limited "$errtext"; then
                FLUSH_SNAP_RC=2
            elif [[ "$rc" -eq 3 ]]; then
                FLUSH_SNAP_RC=5; FLUSH_SNAP_REASON="board snapshot incomplete"
            else
                FLUSH_SNAP_RC=5; FLUSH_SNAP_REASON="$(_gh_failure_label "$errtext")"
            fi
            return 1
        fi
        rm -f "$err"
        printf '%s' "$_FLUSH_SNAP" | _cache_refresh_from_items
        # Test-only pause (no-op in production): the snapshot is in hand, the WIP mutex is held.
        [[ "${_FLUSH_HOLDS_WIP:-0}" == "1" ]] && _flush_sync "${BOARD_QUEUE_TEST_TAG:-flush}-snap"
    fi
    [[ -n "${_FLUSH_SNAP:-}" ]] || return 1
    FLUSH_CUR="$(python3 "$HERE/wip.py" current "$CONFIG" "${BOARD:-}" "$1" <<<"$_FLUSH_SNAP")" || FLUSH_CUR=""
}

# _flush_snap_has <issue#>: 0 unless the (complete, fresh) flush snapshot proves the
# issue is NOT a board item. An unusable snapshot counts as "present": the normal path
# then reports its own error.
_flush_snap_has() {
    [[ -n "${_FLUSH_SNAP:-}" ]] || return 0
    python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    items = d["items"]
    sys.exit(0 if any(isinstance(i, dict) and str((i.get("content") or {}).get("number")) == sys.argv[1] for i in items) else 1)
except Exception:
    sys.exit(0)
' "$1" <<<"$_FLUSH_SNAP"
}

# _flush_snap_status_of <issue#> -> the issue's status in the flush snapshot ("" empty
# status, "?" when the snapshot cannot say: no match, several matches, unusable).
_flush_snap_status_of() {
    python3 -c '
import json, sys
try:
    items = json.loads(sys.stdin.read())["items"]
    m = [i for i in items if isinstance(i, dict) and str((i.get("content") or {}).get("number")) == sys.argv[1]]
    print(m[0].get("status") or "" if len(m) == 1 else "?")
except Exception:
    print("?")
' "$1" <<<"${_FLUSH_SNAP:-}"
}

# _flush_snap_refresh: ONE re-read of the board after the flush added a card, replacing the
# shared snapshot (so later entries see the card). Returns 0 ok, 2 rate-limited, 1 failed
# (reason left for _take_reason; the caller maps it to the retryable code).
_flush_snap_refresh() {
    local err out rc errtext
    err="$(mktemp)"
    out="$(gh_project_items_json "$PN" "$OWNER" --strict 2>"$err")"; rc=$?
    errtext="$(cat "$err")"; rm -f "$err"
    if [[ "$rc" -ne 0 ]]; then
        if [[ "$rc" -ne 3 ]] && _rate_limited "$errtext"; then return 2; fi
        printf '%s\n' "$errtext" >&2
        if [[ "$rc" -eq 3 ]]; then _qreason "board snapshot incomplete"; else _qreason "board read failed: $(_gh_failure_label "$errtext")"; fi
        return 1
    fi
    _FLUSH_SNAP="$out"
    printf '%s' "$out" | _cache_refresh_from_items
    return 0
}

# _flush_snap_patch <issue#> <status>: record an applied move in the shared snapshot.
_flush_snap_patch() {
    [[ -n "${_FLUSH_SNAP:-}" ]] || return 0
    _FLUSH_SNAP="$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
for it in d.get("items", []):
    if isinstance(it, dict) and str((it.get("content") or {}).get("number")) == sys.argv[1]:
        it["status"] = sys.argv[2]
print(json.dumps(d))
' "$1" "$2" <<<"$_FLUSH_SNAP")" || _FLUSH_SNAP=""
}

# _flush_wip_prepare <status>: before the flush reads its snapshot for a WIP-counted
# status, take the WIP admission mutex FIRST and hold it until the pass ends (#561:
# lock order flush -> WIP). Admission from a snapshot taken BEFORE the mutex could
# over-admit next to a live start. A snapshot read earlier for a non-WIP entry is
# dropped and re-read once under the mutex. Returns 1 if the mutex stayed busy
# (bounded wait; not retried again this pass).
_flush_wip_prepare() {
    local c waited=0 dead lock="$ROOT/.claude/board-wip.lock"
    [[ "${_FLUSH_HOLDS_WIP:-0}" == "1" ]] && return 0
    python3 "$HERE/wip.py" classify "$CONFIG" "${BOARD:-}" "$1"; c=$?
    [[ "$c" -eq 3 ]] && return 0            # not WIP-counted: no mutex needed
    [[ "${_FLUSH_WIP_FAILED:-0}" == "1" ]] && return 1
    mkdir -p "$(dirname "$lock")" || return 1
    until mkdir "$lock" 2>/dev/null; do
        if dead="$(_lock_dead_holder "$lock")"; then
            echo "WIP: breaking admission mutex of dead holder (pid $dead)" >&2
            _lock_break_if "$lock" "$dead"
            continue
        fi
        if [[ "$waited" -ge "${BOARD_WIP_MUTEX_MAX_WAIT_ITERS:-200}" ]]; then
            echo "WIP BLOCKED: admission mutex busy or stuck at $lock; verify all holders and child commands are idle before manual recovery (never remove a live lock)" >&2
            _FLUSH_WIP_FAILED=1
            return 1
        fi
        sleep 0.05
        waited=$((waited + 1))
    done
    printf '%s\n' "$$" >"$lock/pid"
    _cleanup_add "$lock"
    _FLUSH_HOLDS_WIP=1
    _FLUSH_SNAP=""; _FLUSH_SNAP_FAILED=0
    return 0
}
_flush_wip_release() {
    local lock="$ROOT/.claude/board-wip.lock"
    if [[ "${_FLUSH_HOLDS_WIP:-0}" == "1" ]]; then
        rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true
        _cleanup_del "$lock"
    fi
    _FLUSH_HOLDS_WIP=0
}

_flush_queue_locked() {
    local aside line op issue status priority points url first_status prio rc cur requeued reset reason attempts hint
    local -a lines
    local i n
    _FLUSH_SNAP=""; _FLUSH_SNAP_FAILED=0; _FLUSH_USE_SNAP=1; _FLUSH_HOLDS_WIP=0; _FLUSH_WIP_FAILED=0
    aside="$(mktemp "$(dirname "$QUEUE_FILE")/.flush.XXXXXX")"
    # The move-aside shares the queue file lock with appends and drops (#561).
    if ! _qfile_lock; then
        # Never move the queue aside unlocked (a rewrite or append could be in flight).
        echo "flush: SKIP -- queue file lock busy ($QUEUE_FILE_LOCK_DIR); the queue is untouched, the next call retries"
        rm -f "$aside"; _FLUSH_USE_SNAP=0
        return 0
    fi
    mv "$QUEUE_FILE" "$aside" 2>/dev/null || { _qfile_unlock; rm -f "$aside"; _FLUSH_USE_SNAP=0; return 0; }
    _qfile_unlock
    _dedupe_aside "$aside"
    _flush_sync "${BOARD_QUEUE_TEST_TAG:-flush}"

    lines=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        lines+=("$line")
    done <"$aside"
    n=${#lines[@]}
    # A queue holding ANY WIP-counted move takes the WIP mutex before the first board
    # read, so a mixed queue still costs one read (the snapshot must be read under it).
    for ((i = 0; i < n; i++)); do
        [[ "$(_jf "${lines[$i]}" op)" == "move" ]] || continue
        status="$(_jf "${lines[$i]}" status)"
        issue="$(_jf "${lines[$i]}" issue)"
        # Only an entry that will really be attempted needs the mutex: a superseded, paused
        # or guard-refused one must not block live starts (the loop prints its refusal).
        _superseded "${lines[$i]}" && continue
        bash "$HERE/checkpoint-preflight.sh" --root "$ROOT" --board "${BOARD:-}" --status "$status" >/dev/null 2>&1 || continue
        _move_guards "$issue" "$status" >/dev/null 2>&1 || continue
        python3 "$HERE/wip.py" classify "$CONFIG" "${BOARD:-}" "$status"; rc=$?
        if [[ "$rc" -ne 3 ]]; then _flush_wip_prepare "$status" || true; break; fi
    done
    requeued=0
    for ((i = 0; i < n; i++)); do
        line="${lines[$i]}"
        op="$(_jf "$line" op)"
        issue="$(_jf "$line" issue)"
        OVER_WIP_REASON=""; OVER_WIP_BY=""  # #560: only a queued move entry may set these
        if [[ "$requeued" -eq 1 ]]; then
            _queue_append_raw "$line"
            _aside_write_remaining "$aside" "${lines[@]:$((i + 1))}"
            continue
        fi
        if _backed_off "$line"; then
            # Failed 3 times in a row and tried within the back-off window: zero gh calls.
            _queue_append_raw "$line"
            _aside_write_remaining "$aside" "${lines[@]:$((i + 1))}"
            continue
        fi
        case "$op" in
            move)
                status="$(_jf "$line" status)"
                OVER_WIP_REASON="$(_jf "$line" over_wip)"; OVER_WIP_BY="$(_jf "$line" over_wip_by)"
                _over_wip_value_ok "$OVER_WIP_REASON" || { OVER_WIP_REASON=""; OVER_WIP_BY=""; }
                if _superseded "$line"; then
                    echo "flush: skip superseded move #$issue -> $status (a newer move already applied)"
                    rc=0
                # Pause also guards cached repeat requests: do not discard a
                # pending start merely because stale cache says it happened.
                elif ! bash "$HERE/checkpoint-preflight.sh" --root "$ROOT" --board "${BOARD:-}" --status "$status"; then
                    rc=6  # a pause is temporary: keep the move for after resume (#561)
                elif ! _move_guards "$issue" "$status"; then
                    rc=1  # local guards first: a refused entry costs ZERO gh calls (#561)
                elif ! _flush_wip_prepare "$status"; then
                    rc=5; _qreason_begin; _qreason "admission mutex busy"
                elif ! _flush_snap_status "$issue" && [[ "${_FLUSH_SNAP_FAILED:-0}" == "1" ]]; then
                    rc="$FLUSH_SNAP_RC"
                    # A board-wide read failure belongs to no entry: stop the pass, keep all.
                    if [[ "$rc" -eq 5 ]]; then _qreason_begin; _qreason "board read failed: $FLUSH_SNAP_REASON"; fi
                elif ! _flush_snap_has "$issue"; then
                    # Decided from the fresh snapshot: no second read. Counted, dropped on the 5th.
                    rc=5; _qreason_begin; _qreason "not on the board"
                else
                    cur="$FLUSH_CUR"
                    if [[ -n "$cur" && "$cur" == "$status" ]]; then
                        echo "flush: skip move #$issue (already $status)"
                        rc=0
                    else
                        if _superseded "$line"; then
                            # Re-checked right before the apply: a newer move landed meanwhile.
                            echo "flush: skip superseded move #$issue -> $status (a newer move already applied)"
                            rc=0
                        else
                            _GUARDS_DONE="$issue:$status"
                            _do_move "$issue" "$status"; rc=$?
                            _GUARDS_DONE=""
                            if [[ "$rc" -eq 0 ]]; then
                                _flush_snap_patch "$issue" "$status"
                                # A replayed move supersedes OLDER queued moves of the issue too.
                                _seq="$(_entry_seq "$line")"
                                _queue_drop_moves "$issue" "$_seq"
                            fi
                        fi
                    fi
                fi
                ;;
            prio)
                priority="$(_jf "$line" priority)"
                # The id comes from the cache: refresh it from this flush's snapshot first, so
                # the replay's "no stale-id re-read" is true for prio/est too.
                if ! _flush_snap_status "$issue" && [[ "${_FLUSH_SNAP_FAILED:-0}" == "1" ]]; then
                    rc="$FLUSH_SNAP_RC"
                    if [[ "$rc" -eq 5 ]]; then _qreason_begin; _qreason "board read failed: $FLUSH_SNAP_REASON"; fi
                elif ! _flush_snap_has "$issue"; then
                    rc=5; _qreason_begin; _qreason "not on the board"
                else
                    _do_prio "$issue" "$priority"; rc=$?
                fi
                ;;
            est)
                points="$(_jf "$line" points)"
                if ! _flush_snap_status "$issue" && [[ "${_FLUSH_SNAP_FAILED:-0}" == "1" ]]; then
                    rc="$FLUSH_SNAP_RC"
                    if [[ "$rc" -eq 5 ]]; then _qreason_begin; _qreason "board read failed: $FLUSH_SNAP_REASON"; fi
                elif ! _flush_snap_has "$issue"; then
                    rc=5; _qreason_begin; _qreason "not on the board"
                else
                    _do_est "$issue" "$points"; rc=$?
                fi
                ;;
            add-finish)
                url="$(_jf "$line" url)"
                first_status="$(_jf "$line" first_status)"; prio="$(_jf "$line" prio)"
                if ! _flush_snap_status "$issue" && [[ "${_FLUSH_SNAP_FAILED:-0}" == "1" ]]; then
                    rc="$FLUSH_SNAP_RC"
                    if [[ "$rc" -eq 5 ]]; then _qreason_begin; _qreason "board read failed: $FLUSH_SNAP_REASON"; fi
                else
                    _do_add_finish "$issue" "$url" "$first_status" "$prio"; rc=$?
                fi
                ;;
            adopt)
                # Fresh snapshot first: the cache then tells the adopt whether the card is on the
                # board and whether its status is empty, without another read.
                if ! _flush_snap_status "$issue" && [[ "${_FLUSH_SNAP_FAILED:-0}" == "1" ]]; then
                    rc="$FLUSH_SNAP_RC"
                    if [[ "$rc" -eq 5 ]]; then _qreason_begin; _qreason "board read failed: $FLUSH_SNAP_REASON"; fi
                else
                    _do_adopt "$issue"; rc=$?
                fi
                ;;
            *)
                echo "flush: WARNING dropping queued line with unknown op '$op'" >&2
                rc=0
                ;;
        esac
        case "$rc" in
            2)
                reset="$(_rate_limit_reset_human)"
                echo "QUEUED (rate-limited until $reset): $op #$issue"
                _queue_append_raw "$line"
                requeued=1
                ;;
            5)
                reason="$(_take_reason)"
                case "$reason" in
                    "timeout"|"network error")
                        # One entry's own call timed out: the network is down for everyone, so
                        # stop this pass, but say it was this entry's call, not a board read.
                        echo "flush: $op #$issue hit a $reason — stopping this pass, entry kept" >&2
                        _queue_append_raw "$line"
                        requeued=1
                        ;;
                    "board read failed"*)
                        # Board-wide failure or the network is down: it belongs to no entry,
                        # so no attempt is counted. Stop touching gh this pass, keep everything.
                        echo "flush: board read failed (${reason#board read failed: }) — queue kept: $op #$issue kept in queue for follow-up" >&2
                        _queue_append_raw "$line"
                        requeued=1
                        ;;
                    "gh error"|"not on the board")
                        # Unrecognised wording: bounded, so a config error cannot loop for ever.
                        attempts=$(( $(_jf "$line" attempts | grep -E '^[0-9]+$' || echo 0) + 1 ))
                        if [[ "$attempts" -ge 5 ]]; then
                            case "$op" in
                                add-finish) hint="adopt $issue" ;;
                                *) if [[ "$reason" == "not on the board" ]]; then hint="adopt $issue"
                                   elif [[ "$op" == "move" ]]; then hint="move $issue \"$status\""
                                   else hint="$op $issue"; fi ;;
                            esac
                            echo "flush: DROPPED $op #$issue after 5 attempts ($reason) — fix and re-run board.sh $hint"
                        else
                            echo "flush: still queued ($reason, attempt $attempts of 5): $op #$issue" >&2
                            _queue_append_raw "$(_line_with_attempts "$line" "$attempts")"
                        fi
                        ;;
                    *)
                        echo "flush: still queued ($reason): $op #$issue" >&2
                        _queue_append_raw "$(_line_with_fail "$line")"
                        ;;
                esac
                ;;
            1)
                # A refusal that can still clear (gate, review, closure evidence, comments read,
                # WIP room) keeps the move queued, as before #561. Only a status that does not
                # exist in statusFlow can never apply: that one is dropped with a printed line.
                if [[ "$op" == "move" && -z "$(opt_id status "$status")" ]]; then
                    echo "flush: DROPPED move #$issue -> $status (invalid status, see above)"
                elif [[ "$op" == "prio" || "$op" == "est" ]]; then
                    # An invalid option or a missing item can never apply: drop it, say so.
                    echo "flush: DROPPED $op #$issue (invalid value or item, see above)"
                else
                    echo "flush: ERROR $op #$issue failed (not rate-limited) -- kept in queue for follow-up" >&2
                    _queue_append_raw "$line"
                fi
                ;;
            6)
                echo "flush: ERROR $op #$issue failed (not rate-limited) -- kept in queue for follow-up" >&2
                _queue_append_raw "$line"
                ;;
        esac
        _aside_write_remaining "$aside" "${lines[@]:$((i + 1))}"
    done
    # Second test-only sync point (#104): right before the now-purely-cosmetic
    # cleanup (the aside file is already empty by construction at this point,
    # see the durability comment above) -- lets a test pin the exact
    # "last mutation confirmed, cleanup not yet run" window.
    _flush_sync "${BOARD_QUEUE_TEST_TAG:-flush}-done"
    _FLUSH_USE_SNAP=0
    _flush_wip_release
    rm -f "$aside"
}
