#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# panel.sh -- the graph panel: a Herdr plugin pane next to the orchestrator.
#
# Usage (Herdr starts it as the plugin pane "panel"):
#   panel.sh                       the interactive panel
#   panel.sh --frame [--width N] [--interval S] [--selected I] [--seen JSON] [--feed]
#                                  print one frame and exit (tests, a quick look); --seen is
#                                  each lane's section at the last look ({"lane":"working"});
#                                  --feed first runs stdin (keys, SGR mouse bytes) through the
#                                  same input loop as the live panel
#   panel.sh --next-interval S     the interval after S in the cycle (tests)
#   panel.sh --buttons [--width N] [--interval S] [--rows R]
#                                  the bottom line's button columns and row (tests)
#
# Layout: no title (Herdr's pane border shows "Graph"), no margin; the lanes from the first line,
# NEEDS YOU, WORKING, DONE; a thin divider; the footer pinned to the pane's bottom, its
# last line ending with the [◷ 5s] and [↻] buttons. The size is read from the terminal on
# every draw, and a resize (SIGWINCH) redraws at once.
# It only reads: the lane files and Herdr, through status.sh. Every write still goes
# through lane.sh and every answer through the orchestrator.
# Refresh: automatic every interval; the interval cycles 5s, 10s, 15s, 30s, 1m, 5m with the
# [◷ 5s] button or t; [↻] or r refreshes now. The starting interval comes from the plugin's
# config file ($HERDR_PLUGIN_CONFIG_DIR/config, a line `refresh=10s`), default 5s; the
# button changes it for this panel only and writes nothing.
# Mouse: the panel asks the terminal for SGR mouse reports (Herdr passes them to pane apps
# that ask). A click on a lane selects it; a click on its fold icon (▾ unfolded, ▸ folded)
# also folds it to its first line or unfolds its chain, question, references and last line.
# A click on a button presses it.
# Keys: up/down select a lane, enter or space folds/unfolds it, g jumps to its agent,
# a answers its question, d shows its detail, f shows only its agents in the sidebar,
# n only the agents that need you, F all again, r refresh, t interval, q close.
# Colour: plain ANSI SGR (src/style.sh); none when NO_COLOR is set.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/style.sh
. "$HERE/src/style.sh"

PANEL_TITLE="herdr-graph-panel"
CYCLE="5 10 15 30 60 300"
STYLE="$(style_json)"

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

# Each lane's section when the user last looked (the last key or click), for "Since last look".
SEEN="{}"
mark_seen() { SEEN="$(jq -c 'map({(.lane): .section}) | add // {}' <<<"$VIEW")"; }

# Folded lanes, by name: |lane|lane|
FOLDED="|"
toggle_fold() { # lane name
    [ -n "$1" ] || return 0
    case "$FOLDED" in
        *"|$1|"*) FOLDED="${FOLDED/|$1|/|}" ;;
        *) FOLDED="$FOLDED$1|" ;;
    esac
}

# The click columns of the two buttons, which end the bottom line one column short of the
# right edge. Their symbols are one column wide everywhere (no emoji), so the columns come
# from the label's length: "[◷ 5s] [↻]" is label + 8 columns. BTN_ROW is the bottom row.
BTN_IV_FROM=0 BTN_IV_TO=0 BTN_RF_FROM=0 BTN_RF_TO=0 BTN_ROW=0
buttons() { # width, interval, row
    local label
    label="$(label_of "$2")"
    BTN_IV_FROM=$(($1 - ${#label} - 8))
    [ "$BTN_IV_FROM" -ge 1 ] || BTN_IV_FROM=1
    BTN_IV_TO=$((BTN_IV_FROM + ${#label} + 3))
    BTN_RF_FROM=$((BTN_IV_TO + 2))
    BTN_RF_TO=$((BTN_RF_FROM + 2))
    BTN_ROW="$3"
}

# The lanes, one "kind|width|line" per line: kind is the lane's display index, with an h
# on the lane's first line (the one with the fold icon), or -1 for lines of no lane
# (section headers, blanks, hints); width is the line's length without the style codes.
# shellcheck disable=SC2016
body() { # selected index
    jq -r --argjson sel "$1" --argjson c "$STYLE" --arg folded "$FOLDED" --argjson seen "$SEEN" "$STYLE_JQ_MARK"'
        def chain: [.nodes[] | "\(.node) \(markcolour)\(mark)"
                     + (if .max > 0 and .retries > 0 then " \(.retries)/\(.max)" else "" end) + $c.fg]
                   | join(" \($c.grey)→\($c.fg) ");
        def title: {"needs": "NEEDS YOU", "working": "WORKING", "done": "DONE"}[.];
        def isfolded: .lane as $n | $folded | contains("|\($n)|");
        # Every other lane (odd display index) has the zebra background on all its lines,
        # filled to the right edge; the selected row has its own background instead.
        def lane($i):
            (if isfolded then "▸" else "▾" end) as $icon
            | (if $i % 2 == 1 and $c.zebra != "" then $c.zebra else "" end) as $bg
            | def striped: if $bg == "" then . else "\($bg)\(.)\($c.eol)\($c.reset)" end;
            (if $i == $sel then
                 "\($i)h|\($c.selbg)\($icon) \($c.bold)\(.lane)\($c.unbold) \($c.grey)\(.pattern)\($c.fg)\($c.selmark)\($c.eol)\($c.reset)"
               else "\($i)h|" + ("\($icon) \($c.bold)\(.lane)\($c.unbold) \($c.grey)\(.pattern)\($c.fg)" | striped) end),
              (if isfolded then empty else
                 ( chain,
                   (if .question != "" then "\($c.red)? \(.question)\($c.fg)" else empty end),
                   (.nodes[] | select(.ref != "" and (.ref | test("/"))) | "\($c.grey)\(.node): \(.ref)\($c.fg)"),
                   (if (.last // "") != "" then "\($c.grey)last: \(.last)\($c.fg)" else empty end)
                 ) | "\($i)|" + striped
               end);
        def plain: gsub("\u001b\\[[0-9;]*[A-Za-z]"; "");
        ([.[] | select(.section == "needs")] + [.[] | select(.section == "working")] + [.[] | select(.section == "done")]) as $l
        | ( if ($l | length) == 0 then "-1|No lanes yet.", "-1|\($c.grey)Give the orchestrator an idea.\($c.fg)"
            else
              ( range(0; $l | length) as $i | $l[$i] as $x
                | (if $i == 0 or $l[$i - 1].section != $x.section then
                     (if $i == 0 then empty else "-1|" end),
                     "-1|\($c.head[$x.section])\($x.section | title) (\([$l[] | select(.section == $x.section)] | length))\($c.reset)"
                   else empty end),
                  ($x | lane($i)) ),
              ( if ($seen | length) == 0 then empty else
                  [$l[] | select($seen[.lane] != .section) | "\(.lane) → \(.section | title | ascii_downcase)"]
                  | if length == 0 then empty else "-1|", "-1|\($c.grey)Since last look: \(join(", "))\($c.fg)" end
                end )
            end )
        | capture("^(?<k>[^|]*)\\|(?<l>.*)$"; "s") | "\(.k)|\(.l | plain | length)|\(.l)"' <<<"$VIEW"
}

# The bottom block: a thin grey divider as wide as the pane, then the grey footer, wrapped at its " · " parts to the width,
# its last line ending with the buttons (on a line of their own when they do not fit).
# shellcheck disable=SC2016
bottom() { # width, interval
    jq -rn --argjson w "$1" --argjson c "$STYLE" --arg b "[◷ $(label_of "$2")] [↻]" \
        --arg upd "updated $UPDATED" --arg every "every $(label_of "$2")" '
        ($w - 1) as $max
        | [$upd, $every, "↵ fold", "g go", "a answer", "d detail", "? keys"]
        | reduce .[] as $p ([];
            if length > 0 and ((.[-1] + " · " + $p) | length) <= $max then .[-1] += " · " + $p else . + [$p] end)
        | (if ((.[-1] | length) + 3 + ($b | length)) <= $max then .[-1] |= . + (" " * ($max - length - ($b | length))) + $b
           else . + [(" " * ($max - ($b | length))) + $b] end)
        | "\($c.grey)\("─" * $w)\($c.fg)", (.[] | "\($c.grey)\(.)\($c.fg)")'
}

lane_count() { jq 'length' <<<"$VIEW"; }

# The lane at a display index, in the same order as body().
lane_at() { # index -> one line of JSON
    jq -c --argjson i "$1" '([.[] | select(.section == "needs")] + [.[] | select(.section == "working")] + [.[] | select(.section == "done")])[$i] // empty' <<<"$VIEW"
}

# layout fills TOP (the lane lines), TOPKIND and TOPWIDTH (each line's kind and width,
# see body) and BOTTOM (the divider and the footer).
TOP=() TOPKIND=() TOPWIDTH=() BOTTOM=()
layout() { # width, interval, selected
    local l rest
    TOP=() TOPKIND=() TOPWIDTH=() BOTTOM=()
    while IFS= read -r l; do
        TOPKIND+=("${l%%|*}")
        rest="${l#*|}"
        TOPWIDTH+=("${rest%%|*}")
        TOP+=("${rest#*|}")
    done < <(body "$3")
    while IFS= read -r l; do BOTTOM+=("$l"); done < <(bottom "$1" "$2")
    [ -z "${MSG:-}" ] || BOTTOM=("${BOTTOM[0]}" "$MSG" "${BOTTOM[@]:1}")
}

# place decides how many TOP lines fit in the rows above the bottom block and maps every
# screen row to its line's kind (ROWMAP; the h only on a lane line's first row). With a
# width, a line takes as many rows as it wraps into, as on the live pane; with width 0,
# one row per line (the text of --frame).
ROWMAP=() SHOWN=0
place() { # width (0: one row per line), rows available (0: all)
    local i=0 n rows r
    ROWMAP=() SHOWN=0
    n=${#TOP[@]}
    while [ "$i" -lt "$n" ]; do
        rows=1
        if [ "$1" -gt 0 ] && [ "${TOPWIDTH[$i]}" -gt "$1" ]; then rows=$(((TOPWIDTH[i] + $1 - 1) / $1)); fi
        [ "$2" -eq 0 ] || [ $((${#ROWMAP[@]} + rows)) -le "$2" ] || break
        ROWMAP+=("${TOPKIND[$i]}")
        r=1
        while [ "$r" -lt "$rows" ]; do ROWMAP+=("${TOPKIND[$i]%h}"); r=$((r + 1)); done
        i=$((i + 1))
    done
    SHOWN="$i"
}

frame() { # width, interval, selected: one frame as text, the footer on its last lines
    layout "$1" "$2" "$3"
    place 0 0
    buttons "$1" "$2" $((${#TOP[@]} + ${#BOTTOM[@]}))
    printf '%s\n' "${TOP[@]}" "${BOTTOM[@]}"
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

act() { # key
    local n lane i k
    n="$(lane_count)"
    lane="$(lane_at "$sel")"
    case "$1" in
        up) [ "$sel" -le 0 ] || sel=$((sel - 1)) ;;
        down) [ "$sel" -ge $((n - 1)) ] || sel=$((sel + 1)) ;;
        enter | space) [ -n "$lane" ] && toggle_fold "$(jq -r '.lane' <<<"$lane")" ;;
        g) [ -n "$lane" ] && jump "$lane" ;;
        a) if [ -n "$lane" ] && [ "$(jq -r '.question' <<<"$lane")" != "" ]; then open_popup answer "$lane"; else MSG="this lane asks nothing"; fi ;;
        d) [ -n "$lane" ] && open_popup detail "$lane" ;;
        f) [ -n "$lane" ] && agent_view "$(jq -c '{label: "lane \(.lane)", filter: {op: "eq", field: "workspace_id", value: .workspace}}' <<<"$lane")" ;;
        n) agent_view '{"label":"needs me","filter":{"op":"in","field":"status","values":["blocked"]}}' ;;
        F) agent_view "" ;;
        r) refresh_view ;;
        t) interval="$(next_interval "$interval")" ;;
        "?") MSG="↑↓ select · ↵/space/click fold · g go · a answer · d detail · f lane only · n needs me · F all · r refresh · t interval · q close" ;;
        q) exit 0 ;;
        click)
            if [ "$CLICK_ROW" -eq "$BTN_ROW" ] && [ "$CLICK_COL" -ge "$BTN_IV_FROM" ] && [ "$CLICK_COL" -le "$BTN_IV_TO" ]; then
                interval="$(next_interval "$interval")"
            elif [ "$CLICK_ROW" -eq "$BTN_ROW" ] && [ "$CLICK_COL" -ge "$BTN_RF_FROM" ] && [ "$CLICK_COL" -le "$BTN_RF_TO" ]; then
                refresh_view
            elif [ "$CLICK_ROW" -ge 1 ] && [ "$CLICK_ROW" -le "${#ROWMAP[@]}" ]; then
                # A click on a lane selects it; on its fold icon (columns 1-2 of its first
                # line) it also folds or unfolds it.
                k="${ROWMAP[$((CLICK_ROW - 1))]}"
                i="${k%h}"
                if [ "$i" -ge 0 ]; then
                    sel="$i"
                    if [ "$k" != "$i" ] && [ "$CLICK_COL" -le 2 ]; then
                        toggle_fold "$(lane_at "$sel" | jq -r '.lane')"
                    fi
                fi
            fi ;;
    esac
    [ "$sel" -lt "$(lane_count)" ] || sel=0
}

# Waits up to $1 seconds for a key; sets KEY (empty on a timeout or an ignored sequence)
# and CLICK_ROW/CLICK_COL. Returns nonzero at the end of the input (--feed).
read_key() {
    local c rest="" rc
    KEY=""
    IFS= read -rsn1 -t "$1" c
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
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
        " ") KEY=space ;;
        *) KEY="$c" ;;
    esac
}

case "${1:-}" in
--next-interval) next_interval "${2:?}"; exit 0 ;;
--buttons)
    shift
    w=48 iv=5 rows=24
    while [ $# -gt 0 ]; do
        case "$1" in
            --width) w="$2"; shift 2 ;;
            --interval) iv="$2"; shift 2 ;;
            --rows) rows="$2"; shift 2 ;;
            *) usage "panel.sh --buttons [--width N] [--interval S] [--rows R]" ;;
        esac
    done
    buttons "$w" "$iv" "$rows"
    printf 'IV %s-%s RF %s-%s ROW %s\n' "$BTN_IV_FROM" "$BTN_IV_TO" "$BTN_RF_FROM" "$BTN_RF_TO" "$BTN_ROW"
    exit 0 ;;
--frame)
    shift
    w=48 interval="$(configured_interval)" sel=0 feed=0 rowmap=0 height=0 MSG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --width) w="$2"; shift 2 ;;
            --interval) interval="$2"; shift 2 ;;
            --selected) sel="$2"; shift 2 ;;
            --seen) SEEN="$2"; shift 2 ;;
            --feed) feed=1; shift ;;
            --rowmap) rowmap=1; shift ;;
            --height) height="$2"; shift 2 ;;
            *) usage "panel.sh --frame [--width N] [--interval S] [--selected I] [--seen JSON] [--feed] [--rowmap [--height H]]" ;;
        esac
    done
    refresh_view
    if [ "$feed" -eq 1 ]; then
        frame "$w" "$interval" "$sel" >/dev/null
        while read_key 1; do
            [ -n "$KEY" ] || continue
            act "$KEY"
            frame "$w" "$interval" "$sel" >/dev/null
        done
    fi
    if [ "$rowmap" -eq 1 ]; then
        layout "$w" "$interval" "$sel"
        room=0
        [ "$height" -eq 0 ] || room=$((height - ${#BOTTOM[@]}))
        place "$w" "$room"
        for r in "${!ROWMAP[@]}"; do printf '%s %s\n' $((r + 1)) "${ROWMAP[$r]}"; done
        exit 0
    fi
    frame "$w" "$interval" "$sel"
    exit 0 ;;
"") ;;
*) usage "panel.sh [--frame ... | --next-interval S | --buttons ...]" ;;
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

# The pane's size, read from the terminal itself: Herdr may resize the pane after starting
# the panel, and tput can answer from the environment or terminfo instead.
term_size() { # sets TERM_ROWS and TERM_COLS
    local size
    size="$(stty size </dev/tty 2>/dev/null)"
    TERM_ROWS="${size%% *}" TERM_COLS="${size##* }"
    case "$TERM_ROWS$TERM_COLS" in "" | *[!0-9]*) TERM_ROWS="$(tput lines 2>/dev/null || echo 24)" TERM_COLS="$(tput cols 2>/dev/null || echo 48)" ;; esac
}

draw() {
    local w h r
    term_size
    w="$TERM_COLS" h="$TERM_ROWS"
    layout "$w" "$interval" "$sel"
    MSG=""
    place "$w" $((h - ${#BOTTOM[@]}))
    buttons "$w" "$interval" "$h"
    printf '\033[H\033[2J'
    r=0
    while [ "$r" -lt "$SHOWN" ]; do
        printf '%s\n' "${TOP[$r]}"
        r=$((r + 1))
    done
    # The bottom block on the pane's last rows; no newline after the last, so nothing scrolls.
    printf '\033[%s;1H' $((h - ${#BOTTOM[@]} + 1))
    r=0
    while [ "$r" -lt "${#BOTTOM[@]}" ]; do
        [ "$r" -eq 0 ] || printf '\n'
        printf '%s' "${BOTTOM[$r]}"
        r=$((r + 1))
    done
}

# A resize redraws at once, at the new size.
RESIZED=0
trap 'RESIZED=1' WINCH

refresh_view
mark_seen
last=$SECONDS
draw
while :; do
    wait_s=$((interval - (SECONDS - last)))
    [ "$wait_s" -ge 1 ] || wait_s=1
    read_key "$wait_s"
    if [ "$RESIZED" -eq 1 ]; then
        RESIZED=0
        draw
        [ -n "$KEY" ] || continue
    fi
    if [ -z "$KEY" ]; then
        if [ $((SECONDS - last)) -ge "$interval" ]; then
            refresh_view
            last=$SECONDS
            draw
        fi
        continue
    fi
    mark_seen
    act "$KEY"
    [ "$KEY" = r ] && last=$SECONDS
    draw
done
