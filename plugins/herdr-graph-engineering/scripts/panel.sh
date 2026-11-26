#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# panel.sh -- the graph panel: a Herdr plugin pane next to the orchestrator.
#
# Usage (Herdr starts it as the plugin pane "panel"):
#   panel.sh                       the interactive panel
#   panel.sh --frame [--width N] [--interval S] [--selected I]
#                                  print one frame and exit (tests, a quick look)
#   panel.sh --next-interval S     the interval after S in the cycle (tests)
#   panel.sh --buttons [--width N] [--interval S]
#                                  the header's button columns (tests)
#
# It only reads: the lane files and Herdr, through status.sh. Every write still goes
# through lane.sh and every answer through the orchestrator.
# Refresh: automatic every interval; the interval cycles 5s, 10s, 15s, 30s, 1m, 5m with the
# [◷ 5s] button or t; [↻] or r refreshes now. The starting interval comes from the plugin's
# config file ($HERDR_PLUGIN_CONFIG_DIR/config, a line `refresh=10s`), default 5s; the
# button changes it for this panel only and writes nothing.
# Keys: up/down select a lane, enter jumps to its agent, a answers its question, d shows
# its detail, f shows only its agents in the sidebar, n only the agents that need you,
# F all again, r refresh, t interval, q close.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

PANEL_TITLE="herdr-graph-panel"
CYCLE="5 10 15 30 60 300"

next_interval() { # seconds -> the next value in the cycle
    local first="" found=0 v
    for v in $CYCLE; do
        [ -n "$first" ] || first="$v"
        if [ "$found" -eq 1 ]; then
            printf '%s\n' "$v"
            return 0
        fi
        [ "$v" = "$1" ] && found=1
    done
    printf '%s\n' "$first"
}

label_of() { # seconds -> 5s, 1m, 5m
    if [ "$1" -ge 60 ] && [ $(($1 % 60)) -eq 0 ]; then printf '%sm' $(($1 / 60)); else printf '%ss' "$1"; fi
}

configured_interval() {
    local f="${HERDR_PLUGIN_CONFIG_DIR:-}/config" v
    v="$(sed -n 's/^refresh=\([0-9][0-9]*\)\([sm]\)\{0,1\}$/\1 \2/p' "$f" 2>/dev/null | tail -1)"
    case "$v" in
        *" m") printf '%s\n' $((${v%% *} * 60)) ;;
        "") printf '5\n' ;;
        *) printf '%s\n' "${v%% *}" ;;
    esac
}

VIEW="[]"
UPDATED=""
refresh_view() {
    VIEW="$(bash "$HERE/status.sh" --json 2>/dev/null)" || VIEW="[]"
    [ -n "$VIEW" ] || VIEW="[]"
    UPDATED="$(date +%H:%M:%S)"
}

# The header with its two buttons. Their symbols are one column wide everywhere (no emoji),
# so the click columns can be computed from plain lengths: label + 4 for the interval button.
BTN_IV_FROM=0 BTN_IV_TO=0 BTN_RF_FROM=0 BTN_RF_TO=0
header() { # width, interval
    local w="$1" label pad
    label="$(label_of "$2")"
    pad=$((w - 6 - (${#label} + 4) - 3 - 2))
    [ "$pad" -ge 1 ] || pad=1
    BTN_IV_FROM=$((6 + pad + 1))
    BTN_IV_TO=$((BTN_IV_FROM + ${#label} + 3))
    BTN_RF_FROM=$((BTN_IV_TO + 2))
    BTN_RF_TO=$((BTN_RF_FROM + 2))
    printf ' Graph%*s[◷ %s] [↻]\n' "$pad" "" "$label"
}

# The body: one entry per lane, NEEDS YOU first; the selected lane is marked with ▸.
body() { # selected index
    jq -r --argjson sel "$1" '
        def mark: if .status == "done" and .result == "changes" then "✗" elif .status == "done" then "✓"
                  elif .status == "running" then "⟳" elif .status == "failed" then "✗"
                  elif .status == "blocked" then "?" elif .status == "skipped" then "–" else "·" end;
        def chain: [.nodes[] | "\(.node) \(mark)" + (if .max > 0 and .retries > 0 then " \(.retries)/\(.max)" else "" end)] | join(" → ");
        ([.[] | select(.section == "needs")] + [.[] | select(.section == "working")] + [.[] | select(.section == "done")]) as $l
        | if ($l | length) == 0 then "", " No lanes yet.", " Give the orchestrator an idea."
          else
            [ range(0; $l | length) as $i | $l[$i] as $x
              | (if $i == 0 or $l[$i - 1].section != $x.section then
                   ["", ({"needs": " NEEDS YOU", "working": " WORKING", "done": " DONE"}[$x.section]
                         + " (\([$l[] | select(.section == $x.section)] | length))")] else [] end)
                + ["\(if $i == $sel then " ▸ " else "   " end)\($x.lane)  \($x.pattern)",
                   "     \($x | chain)"]
                + (if $x.question != "" then ["     ? \($x.question)"] else [] end) ] | add | .[]
          end' <<<"$VIEW"
}

lane_count() { jq 'length' <<<"$VIEW"; }

# The lane at a display index, in the same order as body().
lane_at() { # index -> one line of JSON
    jq -c --argjson i "$1" '([.[] | select(.section == "needs")] + [.[] | select(.section == "working")] + [.[] | select(.section == "done")])[$i] // empty' <<<"$VIEW"
}

frame() { # width, interval, selected
    local w="$1"
    header "$w" "$2"
    printf '%s\n' "$(printf '%*s' "$w" '' | tr ' ' '-')"
    body "$3"
    printf '\n %s\n' "updated $UPDATED · every $(label_of "$2") · ⏎ go · a answer · d detail · ? keys"
}

# Herdr's agent view lives on the socket only; nc -U talks to it when available.
agent_view() { # JSON params, or "" to clear
    local req
    command -v nc >/dev/null 2>&1 && [ -n "${HERDR_SOCKET_PATH:-}" ] || { MSG="sidebar filters need nc with -U"; return 0; }
    if [ -n "$1" ]; then
        req="$(jq -cn --argjson p "$1" '{id: "graph-view", method: "agent.view.set", params: ({source: "graph-panel"} + $p)}')"
    else
        req='{"id":"graph-view","method":"agent.view.clear","params":{"source":"graph-panel"}}'
    fi
    printf '%s\n' "$req" | nc -U -w 1 "$HERDR_SOCKET_PATH" >/dev/null 2>&1 || MSG="Herdr refused the sidebar filter"
}

open_popup() { # entrypoint, lane JSON
    local lane repo
    lane="$(jq -r '.lane' <<<"$2")" repo="$(jq -r '.repo' <<<"$2")"
    herdr plugin pane open --plugin "${HERDR_PLUGIN_ID:-herdr-graph-engineering.graph}" --entrypoint "$1" \
        --env "GRAPH_LANE=$lane" --env "GRAPH_REPO=$repo" >/dev/null 2>&1 || MSG="could not open the $1 popup"
}

jump() { # lane JSON: focus the agent that needs the user, else a running one
    local agent
    agent="$(jq -r '[.nodes[] | select(.agent != "" and .live != "")] | (map(select(.live == "blocked")) + map(select(.status == "running")) + .)[0].agent // empty' <<<"$1")"
    if [ -n "$agent" ]; then
        herdr agent focus "$agent" >/dev/null 2>&1 || MSG="could not focus $agent"
    else
        MSG="no live agent in this lane"
    fi
}

case "${1:-}" in
--next-interval) next_interval "${2:?}"; exit 0 ;;
--buttons)
    w=48 iv=5
    [ "${2:-}" = --width ] && w="$3"
    [ "${4:-}" = --interval ] && iv="$5"
    header "$w" "$iv" >/dev/null
    printf 'IV %s-%s RF %s-%s\n' "$BTN_IV_FROM" "$BTN_IV_TO" "$BTN_RF_FROM" "$BTN_RF_TO"
    exit 0 ;;
--frame)
    shift
    w=48 iv="$(configured_interval)" sel=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --width) w="$2"; shift 2 ;;
            --interval) iv="$2"; shift 2 ;;
            --selected) sel="$2"; shift 2 ;;
            *) usage "panel.sh --frame [--width N] [--interval S] [--selected I]" ;;
        esac
    done
    refresh_view
    frame "$w" "$iv" "$sel"
    exit 0 ;;
"") ;;
*) usage "panel.sh [--frame ... | --next-interval S]" ;;
esac

# ---- interactive ----
require_tools jq yq git herdr
interval="$(configured_interval)"
sel=0 MSG=""
old_stty="$(stty -g 2>/dev/null)"
restore() {
    printf '\033[?1000l\033[?1006l\033[?25h\033[?1049l'
    [ -n "$old_stty" ] && stty "$old_stty" 2>/dev/null
}
trap 'restore; exit 0' EXIT INT TERM HUP
stty -echo -icanon 2>/dev/null
printf '\033[?1049h\033[?25l\033[?1000h\033[?1006h\033]0;%s\007' "$PANEL_TITLE"

draw() {
    local w
    w="$(tput cols 2>/dev/null || echo 48)"
    printf '\033[H\033[2J'
    frame "$w" "$interval" "$sel"
    [ -z "$MSG" ] || printf ' %s\n' "$MSG"
    MSG=""
}

act() { # key
    local n lane
    n="$(lane_count)"
    lane="$(lane_at "$sel")"
    case "$1" in
        up) [ "$sel" -le 0 ] || sel=$((sel - 1)) ;;
        down) [ "$sel" -ge $((n - 1)) ] || sel=$((sel + 1)) ;;
        enter) [ -n "$lane" ] && jump "$lane" ;;
        a) if [ -n "$lane" ] && [ "$(jq -r '.question' <<<"$lane")" != "" ]; then open_popup answer "$lane"; else MSG="this lane asks nothing"; fi ;;
        d) [ -n "$lane" ] && open_popup detail "$lane" ;;
        f) [ -n "$lane" ] && agent_view "$(jq -c '{label: "lane \(.lane)", filter: {op: "eq", field: "workspace_id", value: .workspace}}' <<<"$lane")" ;;
        n) agent_view '{"label":"needs me","filter":{"op":"in","field":"status","values":["blocked"]}}' ;;
        F) agent_view "" ;;
        r) refresh_view ;;
        t) interval="$(next_interval "$interval")" ;;
        "?") MSG="↑↓ select · ⏎ go · a answer · d detail · f lane only · n needs me · F all · r refresh · t interval · q close" ;;
        q) exit 0 ;;
        click)
            if [ "$CLICK_ROW" -eq 1 ] && [ "$CLICK_COL" -ge "$BTN_IV_FROM" ] && [ "$CLICK_COL" -le "$BTN_IV_TO" ]; then
                interval="$(next_interval "$interval")"
            elif [ "$CLICK_ROW" -eq 1 ] && [ "$CLICK_COL" -ge "$BTN_RF_FROM" ] && [ "$CLICK_COL" -le "$BTN_RF_TO" ]; then
                refresh_view
            fi ;;
    esac
    [ "$sel" -lt "$(lane_count)" ] || sel=0
}

read_key() { # waits up to $1 seconds; sets KEY (empty on timeout) and CLICK_ROW/CLICK_COL
    local c rest=""
    KEY=""
    IFS= read -rsn1 -t "$1" c || return 0
    case "$c" in
        $'\033')
            IFS= read -rsn1 -t 1 c || { KEY=esc; return 0; }
            [ "$c" = "[" ] || return 0
            IFS= read -rsn1 -t 1 c || return 0
            case "$c" in
                A) KEY=up ;;
                B) KEY=down ;;
                "<") # SGR mouse: button;col;row then M (press) or m (release)
                    while IFS= read -rsn1 -t 1 c; do
                        case "$c" in M | m) break ;; *) rest="$rest$c" ;; esac
                    done
                    if [ "$c" = M ] && [ "${rest%%;*}" = 0 ]; then
                        CLICK_COL="$(cut -d';' -f2 <<<"$rest")" CLICK_ROW="$(cut -d';' -f3 <<<"$rest")"
                        KEY=click
                    fi ;;
            esac ;;
        "" | $'\n' | $'\r') KEY=enter ;;
        *) KEY="$c" ;;
    esac
}

refresh_view
last=$SECONDS
draw
while :; do
    wait_s=$((interval - (SECONDS - last)))
    [ "$wait_s" -ge 1 ] || wait_s=1
    read_key "$wait_s"
    if [ -z "$KEY" ]; then
        if [ $((SECONDS - last)) -ge "$interval" ]; then
            refresh_view
            last=$SECONDS
            draw
        fi
        continue
    fi
    act "$KEY"
    [ "$KEY" = r ] && last=$SECONDS
    draw
done
