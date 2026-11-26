#!/usr/bin/env bash
# ui-hub.sh — the local decision hub for Iterative UI mode.
#
# One long-lived page (http://127.0.0.1:<port>) the human keeps open. The agent
# enqueues decision cards (self-contained HTML pages), the human answers in
# place (the page POSTs back), and the agent collects the answers. State is
# plain files, so everything survives restarts.
#
#   ui-hub.sh start [--port N]        start the server in the background (idempotent)
#   ui-hub.sh status                  RUNNING <url> pending=N answered=N | STOPPED
#   ui-hub.sh stop
#   ui-hub.sh ask <id> <title> <html-file> [--blocking]   enqueue a decision card
#   ui-hub.sh answers [--consume] [--id ID]
#       print answers as JSON lines; --consume archives them; --id restricts to
#       one exact card id (and its kept fixes) — ALWAYS pass --id when several
#       agents share the hub, since a bare --consume drains and archives every
#       OTHER pending answer too, not just your own.
#
# State dir: $UI_HUB_STATE, else <PRIMARY repo root>/.claude/ui-hub (gitignore it).
# Port: --port, else $UI_HUB_PORT, else 4747. Binds 127.0.0.1 only.
#
# The server is socat listening on 127.0.0.1 and forking scripts/src/hub-handler.sh
# for each connection. socat is the one extra tool: bash cannot accept TCP
# connections itself, and nc variants differ and serve one connection at a time.
# $UI_HUB_SOCAT names another socat binary.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/ui-design/scripts/src/repo-root.sh
source "$HERE/src/repo-root.sh"

if [[ -n "${UI_HUB_STATE:-}" ]]; then
    S="$UI_HUB_STATE"
else
    # #463: the PRIMARY repo root, so a hub asked from a linked worktree is the
    # same hub the main checkout and every other worktree see.
    S="$(ui_design_repo_root)/.claude/ui-hub"
fi
INBOX="$S/inbox"; OUTBOX="$S/outbox"; ARCHIVE="$S/archive"; HTML="$S/html"
PIDFILE="$S/pid"; PORTFILE="$S/port"
DEFAULT_PORT="${UI_HUB_PORT:-4747}"
SOCAT="${UI_HUB_SOCAT:-socat}"

usage() {
    sed -n '9,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

ensure_dirs() { mkdir -p "$INBOX" "$OUTBOX" "$HTML" "$ARCHIVE/asked" "$ARCHIVE/answers"; }

# pid_alive — prints the server pid when its pid file names a live process.
pid_alive() {
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null)" || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

port_of() { # <args...> -- the --port value, else the default
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --port && $# -ge 2 ]]; then echo "$2"; return; fi
        shift
    done
    echo "$DEFAULT_PORT"
}

has_flag() { # <flag> <args...>
    local f="$1"; shift
    local a
    for a in "$@"; do [[ "$a" == "$f" ]] && return 0; done
    return 1
}

cmd="${1:-status}"
[[ $# -gt 0 ]] && shift
ensure_dirs

case "$cmd" in
    start)
        if pid_alive >/dev/null; then
            echo "RUNNING http://127.0.0.1:$(tr -d '[:space:]' <"$PORTFILE")"
            exit 0
        fi
        port="$(port_of "$@")"
        if ! command -v "$SOCAT" >/dev/null 2>&1; then
            echo "FAILED to start on port $port -- socat is not installed (macOS: brew install socat; Debian/Ubuntu/WSL: apt-get install socat)"
            exit 1
        fi
        # The listener runs `eval $UI_HUB_EXEC` through /bin/sh for each
        # connection: the handler path is %q-quoted inside the variable, so a
        # plugin path with spaces survives socat's own address parsing.
        UI_HUB_EXEC="exec bash $(printf '%q' "$HERE/src/hub-handler.sh")"
        export UI_HUB_EXEC
        UI_HUB_STATE_DIR="$S"
        export UI_HUB_STATE_DIR
        # shellcheck disable=SC2016  # $UI_HUB_EXEC is expanded by the listener's /bin/sh, not here
        nohup "$SOCAT" "TCP-LISTEN:$port,bind=127.0.0.1,reuseaddr,fork" 'SYSTEM:eval $UI_HUB_EXEC' \
            >>"$S/server.log" 2>&1 </dev/null &
        child=$!
        # A bind failure (the port is held — #55) ends socat within
        # milliseconds. Only a listener still alive after that window writes
        # the pid and port files, so a loser never clobbers the winner's.
        for _ in 1 2 3 4; do
            sleep 0.15
            if ! kill -0 "$child" 2>/dev/null; then
                echo "FAILED to start on port $port -- see $S/server.log"
                exit 1
            fi
        done
        echo "$port" >"$PORTFILE"
        echo "$child" >"$PIDFILE"
        echo "RUNNING http://127.0.0.1:$port"
        ;;
    status)
        if pid_alive >/dev/null; then
            pending=0; answered=0
            for f in "$INBOX"/*.json; do [[ -f "$f" ]] && pending=$((pending + 1)); done
            for f in "$OUTBOX"/*.json; do [[ -f "$f" ]] && answered=$((answered + 1)); done
            echo "RUNNING http://127.0.0.1:$(tr -d '[:space:]' <"$PORTFILE") pending=$pending answered=$answered"
        else
            echo "STOPPED"
            exit 1
        fi ;;
    stop)
        if pid="$(pid_alive)"; then
            kill -TERM "$pid" 2>/dev/null
            # Claim "stopped" only once the process is really gone (#98). No
            # SIGKILL: stopping is polite; forcing it is the caller's decision.
            for _ in $(seq 1 20); do
                sleep 0.15
                if ! kill -0 "$pid" 2>/dev/null; then
                    rm -f "$PIDFILE"
                    echo "stopped"
                    exit 0
                fi
            done
            echo "still running after SIGTERM -- kill $pid yourself or retry"
            exit 1
        else
            echo "not running"
        fi ;;
    ask)
        if [[ $# -lt 3 ]]; then
            echo "usage: ui-hub.sh ask <id> <title> <html-file> [--blocking]" >&2
            exit 1
        fi
        did="$1"; title="$2"; html_file="$3"
        cp "$html_file" "$HTML/$did.html" || exit 1
        blocking=false
        has_flag --blocking "$@" && blocking=true
        card="$(jq -n --indent 1 --arg id "$did" --arg t "$title" --argjson b "$blocking" --argjson c "$(date +%s)" \
            '{id: $id, title: $t, blocking: $b, created: $c}')"
        printf '%s' "$card" >"$INBOX/$did.json"
        if pid_alive >/dev/null; then url="http://127.0.0.1:$(tr -d '[:space:]' <"$PORTFILE")"
        else url="(server STOPPED — run: ui-hub.sh start)"; fi
        echo "asked '$did' — hub: $url" ;;
    answers)
        want=""; consume=0
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --id) want="${2:-}"; shift ;;
                --consume) consume=1 ;;
            esac
            shift
        done
        for f in "$OUTBOX"/*.json; do
            [[ -f "$f" ]] || continue
            name="${f##*/}"; stem="${name%.json}"
            # The final "<id>.json" and any kept "<id>.fix-<ts>.json" — never
            # a different id that merely starts with this one.
            if [[ -n "$want" && "$stem" != "$want" && "$stem" != "$want".fix-* ]]; then continue; fi
            tr '\n' ' ' <"$f"; echo
            [[ $consume -eq 1 ]] && mv "$f" "$ARCHIVE/answers/$name"
        done ;;
    *)
        usage
        exit 1 ;;
esac
