#!/usr/bin/env bash
# work-mode.sh — resolve work.type / work.sync.mode (.claude/project.yaml, or
# legacy .json) and decide whether a board-sync event fires now or defers,
# per work.sync.mode's batching cadence (#79).
#   work-mode.sh type                 # prints pr | local (default: pr)
#   work-mode.sh sync-mode            # prints realtime | task-close | session-end | manual (default: realtime)
#   work-mode.sh should-sync <event>  # event in {transition, task-close, session-end, blocked, new-item}
#                                      # prints "now" or "defer"
#
# Matrix (sync.mode x event -> now/defer). SAFETY VALVE first: `blocked` and
# `new-item` ALWAYS resolve "now" in every mode — a human must never wait
# through a batching window to learn a task is blocked or that a brand-new
# item exists. Otherwise: realtime flushes every event immediately; every
# other mode defers every event EXCEPT the one matching its own name (that
# is its flush trigger); manual defers everything (only an explicit
# board.sh flush call moves it).
#
#   mode         transition  task-close  session-end  blocked  new-item
#   realtime     now         now         now          now      now
#   task-close   defer       now         defer        now      now
#   session-end  defer       defer       now          now      now
#   manual       defer       defer       defer        now      now
#
# The queue mechanism itself (board-queue.sh, #77) already handles deferral
# storage — a caller that gets "defer" simply skips the board call until the
# next sync point, where the batched calls run (self-queuing again if
# rate-limited). This script never touches board-queue.sh; it only answers
# the now-vs-defer question skills consult before deciding to call board.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

jget() { python3 "$HERE/config.py" "$ROOT" get "$1" 2>/dev/null; }

work_type() {
    local t
    t="$(jget work.type)"
    echo "${t:-pr}"
}

sync_mode() {
    local m
    m="$(jget work.sync.mode)"
    echo "${m:-realtime}"
}

case "${1:-}" in
    type) work_type ;;
    sync-mode) sync_mode ;;
    should-sync)
        event="${2:-}"
        case "$event" in
            transition|task-close|session-end|blocked|new-item) ;;
            *) echo "usage: work-mode.sh should-sync <transition|task-close|session-end|blocked|new-item>" >&2; exit 2 ;;
        esac
        case "$event" in
            blocked|new-item) echo "now"; exit 0 ;;  # safety valve
        esac
        mode="$(sync_mode)"
        if [[ "$mode" == "realtime" || "$mode" == "$event" ]]; then
            echo "now"
        else
            echo "defer"
        fi
        ;;
    *) echo "usage: work-mode.sh {type|sync-mode|should-sync <event>}" >&2; exit 2 ;;
esac
