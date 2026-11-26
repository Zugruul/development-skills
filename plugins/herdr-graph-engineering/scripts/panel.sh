#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# panel.sh -- the graph panel: a Herdr plugin pane next to the orchestrator.
#
# Usage (Herdr starts it as the plugin pane "panel"):
#   panel.sh                       the interactive panel
#   panel.sh --frame [--width N] [--interval S] [--selected I] [--seen JSON] [--feed]
#                                  print one frame and exit (tests, a quick look); --seen is
#                                  each lane's section at the last look ({"lane":"working"});
#                                  --feed first runs stdin (SGR mouse bytes, keys) through the
#                                  same input loop as the live panel
#   panel.sh --next-interval S     the interval after S in the cycle (tests)
#   panel.sh --buttons [--width N] [--interval S] [--rows R]
#                                  the bottom line's button columns and row (tests)
#   panel.sh --reset-view          what the live panel does once at start: clear a sidebar
#                                  filter an older version of the panel may have left (tests)
#
# Click only: the panel acts on mouse clicks and nothing else. Keystrokes are read and
# ignored (they do not quit, move, fold or disarm anything). The one non-mouse input is
# panel-action.sh refresh, which sends the private sequence ESC [ 99 ~ (no key sends it).
# Layout: no title (Herdr's pane border shows "Graph"), one column of padding each side; the
# lanes from the first line, each starting with its chevron and its lines hanging under it,
# NEEDS YOU, WORKING, DONE, CLOSED; a thin divider; the footer pinned to the pane's bottom, its
# last line ending with the [◷ 5s] and [↻] buttons. The size is read from the terminal on
# every draw, and a resize (SIGWINCH) redraws at once.
# A lane's first line ends with its buttons, right-aligned: [detail] (the selected lane only),
# [answer] (a lane that asks something), [restore] (the selected closed lane only), [x] (a
# DONE or CLOSED lane). When they do not all fit, they drop from the left. [x], [restore],
# [clear all reviews] and [clear all] ask first: the first click turns the button into
# [confirm] (green for [restore], red for the others), a second click on it acts, any other
# click puts it back.
# CLOSED: the closed lanes of every repository the panel reads, newest first, folded, the
# first five and then "… n more" (a click shows them all). The CLOSED header ends with
# [clear all reviews] (only while a closed review lane exists; it drops first when the two
# do not fit) and [clear all]. [x] on a DONE lane asks the lane's orchestrator to clean it up
# (it confirms with the user again and removes the worktree, never the panel); on a CLOSED
# lane, [clear all reviews] for every closed review lane and [clear all] for every closed
# lane, it runs lane.sh clear, which moves the lane file from closed/ to closed/cleared/.
# [restore] runs lane.sh restore: the lane's record comes back with its last status (open or
# done); never a worktree or a branch. A review lane: pattern review or review-stack; with
# no pattern or a custom one (a review stack's --pattern-file), a look/pr-<n> branch.
# It only reads: the lane files and Herdr, through status.sh. Every write still goes
# through lane.sh and every answer through the orchestrator.
# Refresh: automatic every interval; the interval cycles 5s, 10s, 15s, 30s, 1m, 5m with the
# [◷ 5s] button; [↻] refreshes now. The starting interval comes from the plugin's
# config file ($HERDR_PLUGIN_CONFIG_DIR/config, a line `refresh=10s`), default 5s; the
# button changes it for this panel only and writes nothing.
# Mouse: the panel asks the terminal for SGR mouse reports (Herdr passes them to pane apps
# that ask). A click on a lane selects it; a click on its fold chevron (▾ unfolded, ▸ folded)
# also folds it to its first line or unfolds its chain, question, references, last line and
# pull requests. A double click on a lane (two clicks on its rows within DOUBLE_CLICK_MS of
# the panel finishing the first) jumps to its agent. A click on a pull request opens it in
# the browser; on a file reference (any of its wrapped rows) opens it (open_ref); on a button
# presses it.
# Pull requests: each lane's, from prs.sh's cache (its branch's, and those it mentions),
# coloured by state; the live panel refreshes the cache in the background.
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
    fetch_prs
    VIEW="$(bash "$HERE/status.sh" --json 2>/dev/null)" || VIEW="[]"
    [ -n "$VIEW" ] || VIEW="[]"
    UPDATED="$(date +%H:%M:%S)"
}

# Each lane's section when the user last looked (the last key or click), for "Since last look".
SEEN="{}"
mark_seen() { SEEN="$(jq -c 'map({(.lane): .section}) | add // {}' <<<"$VIEW")"; }

# The display order: NEEDS YOU, WORKING, DONE, then CLOSED newest first, the first five
# unless ALLCLOSED (a click on "… n more"). body, lane_at and lane_count share it.
ALLCLOSED=0
# shellcheck disable=SC2016
ORDER_JQ='
    def ordered($all): [.[] | select(.section == "needs")] + [.[] | select(.section == "working")]
        + [.[] | select(.section == "done")]
        + ([.[] | select(.section == "closed")] | sort_by([.closed, .lane]) | reverse
           | if $all == 1 then . else .[:5] end);'

# A review lane, for [clear all reviews]: the recorded pattern when it says (review,
# review-stack, or another pattern: not a review); with no pattern or a custom one, its
# branch, look/pr-<n> as the review patterns name it.
# shellcheck disable=SC2016
REVIEW_JQ='
    def isreview: if .pattern == "review" or .pattern == "review-stack" then true
        elif (.pattern // "") == "" or .pattern == "custom" then (.branch // "") | test("^look/pr-[0-9]+$")
        else false end;'

# The armed button, shown as [confirm]: "x|root|lane" for a lane's [x], "restore|root|lane"
# for its [restore], "all" for [clear all], "reviews" for [clear all reviews].
ARMED="" PREV=""

# Lanes whose fold differs from their default, by name: |lane|lane|. Open lanes start
# unfolded, closed lanes folded.
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
# on the lane's first line (the one with the fold chevron), u<URL> on a pull request's line,
# f<ref> on every row of a file reference; c on the CLOSED header, m on its "… n more" line;
# or -1 for lines of no lane (other section headers, blanks, hints). An h or c line with
# buttons adds @id=from-to;id=from-to, each button's columns as drawn. width is the line's
# length without the style codes. One column of padding on each side; a lane's lines
# hang under it on ├ and └, and long text wraps inside that, under its own start.
# shellcheck disable=SC2016
body() { # selected index, width
    jq -r --argjson sel "$1" --argjson w "$2" --argjson c "$STYLE" --arg folded "$FOLDED" --argjson seen "$SEEN" \
        --arg armed "$ARMED" --argjson all "$ALLCLOSED" \
        "$STYLE_JQ_MARK$STYLE_JQ_PR$STYLE_JQ_PRCOLOUR$ORDER_JQ$REVIEW_JQ"'
        def plain: gsub("\u001b\\[[0-9;]*[A-Za-z]"; "");
        def chain: [.nodes[] | "\(.node) \(markcolour)\(mark)"
                     + (if .max > 0 and .retries > 0 then " \(.retries)/\(.max)" else "" end) + $c.fg]
                   | join(" \($c.grey)→\($c.fg) ");
        def title: {"needs": "NEEDS YOU", "working": "WORKING", "done": "DONE", "closed": "CLOSED"}[.];
        def isfolded: .lane as $n | ($folded | contains("|\($n)|")) != (.section == "closed");
        # a button: {id, key (armed as [confirm]; "" never), label, green} -> + {t: styled, n: columns}
        def button: . + (if .key != "" and $armed == .key
                           then {t: "\(if .green then $c.green else $c.red end)[confirm]\($c.fg)", n: 9}
                           else {t: "\($c.grey)\(.label)\($c.fg)", n: (.label | length)} end);
        # styled text (one column of padding before it), then the buttons, one space apart,
        # ending one column short of the right edge; those that do not fit drop from the left (all of them in a pane too narrow for even one).
        # -> {l: the line, m: "id=from-to;..." with the columns of each button}
        def withbuttons($bl): (plain | length) as $n
            | ($bl | map(button)
               | until(length == 0 or ((map(.n) | add) + length + $n) <= $w - 2; .[1:])) as $b
            | if ($b | length) == 0 then {l: ., m: ""} else
                (($b | map(.n) | add) + ($b | length) - 1) as $bn
                | ([1, $w - 2 - $n - $bn] | max) as $pad
                | {l: "\(.)\(" " * $pad)\($b | map(.t) | join(" "))",
                   m: (reduce $b[] as $x ({at: (2 + $n + $pad), m: []};
                         .m += ["\($x.id)=\(.at)-\(.at + $x.n - 1)"] | .at += $x.n + 1) | .m | join(";"))} end;
        def withmap($k): if .m == "" then "\($k)|\(.l)" else "\($k)@\(.m)|\(.l)" end;
        def hasx: .section == "done" or .section == "closed";
        # plain text -> lines of at most $n columns, broken at spaces, long words cut
        def wrap($n): if $n < 8 or length <= $n then [.] else
            reduce (split(" ")[] | if length > $n then ([range(0; length; $n) as $i | .[$i:$i + $n]] | .[]) else . end) as $x
              ([]; if length > 0 and ((.[-1] + " " + $x) | length) <= $n then .[-1] += " " + $x else . + [$x] end) end;
        # one child line of a lane: {k: kind suffix, l: [styled lines]}
        def styled($s; $n): wrap($n) | map("\($s)\(.)\($c.fg)");
        def prs:
            (.prs // []) as $p
            | ([$p[] | "● #\(.number) \(prword)" | length] | max // 0) as $hw
            | $p[] | "● #\(.number) \(prword)" as $h
            | {k: "u\(.url)", l: ["\(prcolour)\($h)\($c.fg)\(" " * ($hw - ($h | length) + 2))\($c.grey)\(.url)\($c.fg)"]};
        def lane($i):
            ($w - 8) as $n
            | (if isfolded then "▸" else "▾" end) as $icon
            | "\($icon) \($c.bold)\(.lane)\($c.unbold)  \($c.grey)\(.pattern)\($c.fg)" as $head
            | [ (if $i == $sel then {id: "detail", key: "", label: "[detail]"} else empty end),
                (if .question != "" then {id: "answer", key: "", label: "[answer]"} else empty end),
                (if .section == "closed" and $i == $sel
                 then {id: "restore", key: "restore|\(.root)|\(.lane)", label: "[restore]", green: true} else empty end),
                (if hasx then {id: "x", key: "x|\(.root)|\(.lane)", label: "[x]"} else empty end) ] as $bl
            | (if $i == $sel then
                 ("\($head)\($c.selmark)" | withbuttons($bl)) | .l |= "\($c.selbg) \(.)\($c.eol)\($c.reset)" | withmap("\($i)h")
               else ($head | withbuttons($bl)) | .l |= " \(.)" | withmap("\($i)h") end),
              (if isfolded then empty else
                 [ {k: "", l: [chain]},
                   (if .question != "" then {k: "", l: ("? \(.question)" | styled($c.red; $n))} else empty end),
                   (.nodes[] | select(.ref != "" and (.ref | test("/"))) | {k: "f\(.ref)", l: ("\(.node): \(.ref)" | styled($c.grey; $n))}),
                   (if (.last // "") != "" then {k: "", l: ("last: \(.last)" | styled($c.grey; $n))} else empty end),
                   prs ]
                 | length as $m | to_entries[] | .key as $j | .value as $v
                 | (if $j == $m - 1 then ["└ ", "  "] else ["├ ", "│ "] end) as $tw
                 | $v.l | to_entries[]
                 | "\($i)\($v.k)| \($c.grey)  \(if .key == 0 then $tw[0] else $tw[1] end)\($c.fg)\(.value)"
               end);
        ([.[] | select(.section == "closed")] | length) as $nclosed
        | ([.[] | select(.section == "closed" and isreview)] | length) as $nreviews
        | ordered($all) as $l
        | ( if ($l | length) == 0 then "-1| No lanes yet.", "-1| \($c.grey)Give the orchestrator an idea.\($c.fg)"
            else
              ( range(0; $l | length) as $i | $l[$i] as $x
                | (if $i == 0 or $l[$i - 1].section != $x.section then
                     (if $i == 0 then empty else "-1|" end),
                     (if $x.section == "closed" then
                        # [clear all reviews] only while a closed review lane exists
                        "\($c.head.closed)CLOSED (\($nclosed))\($c.reset)"
                        | withbuttons([ (if $nreviews > 0 then {id: "reviews", key: "reviews", label: "[clear all reviews]"} else empty end),
                                        {id: "all", key: "all", label: "[clear all]"} ])
                        | .l |= " \(.)" | withmap("c")
                      else
                        "-1| \($c.head[$x.section])\($x.section | title) (\([$l[] | select(.section == $x.section)] | length))\($c.reset)"
                      end)
                   else empty end),
                  ($x | lane($i)) ),
              ( ($nclosed - ([$l[] | select(.section == "closed")] | length)) as $more
                | if $more > 0 then "m|   \($c.grey)… \($more) more\($c.fg)" else empty end ),
              ( if ($seen | length) == 0 then empty else
                  [$l[] | select($seen[.lane] != .section) | "\(.lane) → \(.section | title | ascii_downcase)"]
                  | if length == 0 then empty
                    else "-1|", ("Since last look: \(join(", "))" | wrap($w - 2) | .[] | "-1| \($c.grey)\(.)\($c.fg)") end
                end )
            end )
        | capture("^(?<k>[^|]*)\\|(?<l>.*)$"; "s") | "\(.k)|\(.l | plain | length)|\(.l)"' <<<"$VIEW"
}

# The bottom block: a thin grey divider and the grey footer ("updated HH:MM:SS · every 5s"),
# inside the one-column padding, the footer wrapped at its " · " parts, its last line ending with the buttons (on a line
# of their own when they do not fit), one column short of the right edge.
# shellcheck disable=SC2016
bottom() { # width, interval
    jq -rn --argjson w "$1" --argjson c "$STYLE" --arg b "[◷ $(label_of "$2")] [↻]" \
        --arg upd "updated $UPDATED" --arg every "every $(label_of "$2")" '
        ($w - 2) as $max
        | [$upd, $every]
        | reduce .[] as $p ([];
            if length > 0 and ((.[-1] + " · " + $p) | length) <= $max then .[-1] += " · " + $p else . + [$p] end)
        | (if ((.[-1] | length) + 3 + ($b | length)) <= $max then .[-1] |= . + (" " * ($max - length - ($b | length))) + $b
           else . + [(" " * ($max - ($b | length))) + $b] end)
        | " \($c.grey)\("─" * $max)\($c.fg)", (.[] | " \($c.grey)\(.)\($c.fg)")'
}

lane_count() { jq --argjson all "$ALLCLOSED" "$ORDER_JQ"' ordered($all) | length' <<<"$VIEW"; }

# The lane at a display index, in the same order as body().
lane_at() { # index -> one line of JSON
    jq -c --argjson i "$1" --argjson all "$ALLCLOSED" "$ORDER_JQ"' ordered($all)[$i] // empty' <<<"$VIEW"
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
    done < <(body "$3" "$1")
    while IFS= read -r l; do BOTTOM+=("$l"); done < <(bottom "$1" "$2")
    [ -z "${MSG:-}" ] || BOTTOM=("${BOTTOM[0]}" " $MSG" "${BOTTOM[@]:1}")
}

# place decides how many TOP lines fit in the rows above the bottom block and maps every
# screen row to its line's kind (ROWMAP; the h only on a lane line's first row). With a
# width, a line takes as many rows as it wraps into, as on the live pane; with width 0,
# one row per line (the text of --frame).
ROWMAP=() SHOWN=0
place() { # width (0: one row per line), rows available (0: all)
    local i=0 n rows r more k idx
    ROWMAP=() SHOWN=0
    n=${#TOP[@]}
    while [ "$i" -lt "$n" ]; do
        rows=1
        if [ "$1" -gt 0 ] && [ "${TOPWIDTH[$i]}" -gt "$1" ]; then rows=$(((TOPWIDTH[i] + $1 - 1) / $1)); fi
        [ "$2" -eq 0 ] || [ $((${#ROWMAP[@]} + rows)) -le "$2" ] || break
        ROWMAP+=("${TOPKIND[$i]}")
        r=1
        # the further rows of a lane's first line are no longer its chevron or its buttons
        k="${TOPKIND[$i]}" idx="${TOPKIND[$i]%%[!0-9-]*}"
        case "${k#"$idx"}" in h*) more="$idx" ;; *) more="$k" ;; esac
        while [ "$r" -lt "$rows" ]; do ROWMAP+=("$more"); r=$((r + 1)); done
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

# Once at start: clear a sidebar filter that an older version of the panel (which had the
# f/n/F keys) may have left set. Herdr's agent view lives on the socket only, reached with
# nc -U; without nc or a socket this is skipped, and an error is ignored.
reset_view() {
    command -v nc >/dev/null 2>&1 && [ -n "${HERDR_SOCKET_PATH:-}" ] || return 0
    printf '%s\n' '{"id":"graph-view","method":"agent.view.clear","params":{"source":"graph-panel"}}' |
        nc -U -w 1 "$HERDR_SOCKET_PATH" >/dev/null 2>&1 || true
}

open_popup() { # entrypoint, lane JSON
    local lane repo
    lane="$(jq -r '.lane' <<<"$2")" repo="$(jq -r '.repo' <<<"$2")"
    herdr plugin pane open --plugin "${HERDR_PLUGIN_ID:-herdr-graph-engineering.graph}" --entrypoint "$1" \
        --env "GRAPH_LANE=$lane" --env "GRAPH_REPO=$repo" >/dev/null 2>&1 || MSG="could not open the $1 popup"
}

# Opens a pull request, a URL or an .html file in the browser, in the background
# (GRAPH_BROWSER, else open or xdg-open).
browse() { # URL or path
    local b="${GRAPH_BROWSER:-}"
    if [ -z "$b" ]; then
        if command -v open >/dev/null 2>&1; then b=open
        elif command -v xdg-open >/dev/null 2>&1; then b=xdg-open
        else MSG="no browser opener (open or xdg-open) for $1"; return 0; fi
    fi
    "$b" "$1" >/dev/null 2>&1 &
}

# Editors that need a terminal: they cannot run inside the panel, so they get a Herdr tab.
# GRAPH_EDITOR_TERMINAL=yes|no overrides the guess.
is_terminal_editor() { # editor command
    local words
    case "${GRAPH_EDITOR_TERMINAL:-}" in yes) return 0 ;; no) return 1 ;; esac
    read -r -a words <<<"$1"
    case "$(basename "${words[0]:-}")" in
        vi | vim | nvim | nano | pico | micro | hx | helix | kak | joe | ne | mg | ed | jed) return 0 ;;
        emacs | emacsclient) case " $1 " in *" -nw "* | *" -t "* | *" --tty "*) return 0 ;; esac ;;
    esac
    return 1
}

# Opens a file in the user's editor: $VISUAL, else $EDITOR, else the system opener
# (GRAPH_OPENER, else open on macOS or xdg-open on Linux). A terminal editor runs in a new
# Herdr tab in the panel's workspace (the tab closes when the editor exits); any other one
# just runs, in the background.
edit_file() { # path
    local ed="${VISUAL:-${EDITOR:-}}" words pane tab
    if [ -z "$ed" ]; then
        ed="${GRAPH_OPENER:-}"
        if [ -z "$ed" ]; then
            if command -v open >/dev/null 2>&1; then ed=open
            elif command -v xdg-open >/dev/null 2>&1; then ed=xdg-open
            else MSG="no editor: set VISUAL or EDITOR to open $1"; return 0; fi
        fi
    fi
    if is_terminal_editor "$ed"; then
        tab=(herdr tab create --label edit --cwd "$(dirname "$1")" --focus)
        [ -z "${HERDR_WORKSPACE_ID:-}" ] || tab=(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --label edit --cwd "$(dirname "$1")" --focus)
        pane="$("${tab[@]}" 2>/dev/null | jq -r '.result.root_pane.pane_id // empty')"
        if [ -z "$pane" ]; then MSG="could not open a tab for $ed"; return 0; fi
        herdr pane run "$pane" "$ed $(printf '%q' "$1"); exit" >/dev/null 2>&1 || MSG="could not start $ed"
    else
        read -r -a words <<<"$ed"
        "${words[@]}" "$1" >/dev/null 2>&1 &
    fi
}

# A click on a file reference. URLs and .html/.htm files open in the browser; every other
# file in the editor (edit_file). A relative path is read from the lane's repository.
# Format-specific panes (a viewer for some formats) would hook in at the case below.
open_ref() { # reference, lane JSON
    local ref="$1" path
    case "$ref" in
        http://* | https://*) browse "$ref"; return 0 ;;
        /*) path="$ref" ;;
        *) path="$(jq -r '.root' <<<"$2")/$ref" ;;
    esac
    [ -e "$path" ] || { MSG="no such file: $path"; return 0; }
    case "$path" in
        *.html | *.htm) browse "$path" ;;
        *) edit_file "$path" ;;
    esac
}

# The pull requests come from prs.sh's cache. The live panel asks prs.sh to refresh it in
# the background, at most once a minute; a render never waits on gh or the network.
FETCH_PRS=0
fetch_prs() { [ "$FETCH_PRS" -eq 0 ] || (bash "$HERE/prs.sh" fetch --max-age 60 >/dev/null 2>&1 &); }

jump() { # lane JSON: focus the agent that needs the user, else a running one
    local agent
    agent="$(jq -r '[.nodes[] | select(.agent != "" and .live != "")] | (map(select(.live == "blocked")) + map(select(.status == "running")) + .)[0].agent // empty' <<<"$1")"
    if [ -n "$agent" ]; then
        herdr agent focus "$agent" >/dev/null 2>&1 || MSG="could not focus $agent"
    else
        MSG="no live agent in this lane"
    fi
}

# The [x] of a DONE or CLOSED lane, pressed and confirmed. A DONE lane: its orchestrator is
# asked to clean it up, and confirms with the user before it removes anything. A CLOSED
# lane: lane.sh clear moves its file to closed/cleared/.
close_lane() { # lane JSON
    local name root owner
    name="$(jq -r '.lane' <<<"$1")" root="$(jq -r '.root' <<<"$1")" owner="$(jq -r '.owner' <<<"$1")"
    case "$(jq -r '.section' <<<"$1")" in
        closed)
            bash "$HERE/lane.sh" clear --repo "$root" --lane "$name" >/dev/null 2>&1 || MSG="could not clear $name"
            refresh_view ;;
        done)
            if [ -z "$owner" ]; then
                MSG="no orchestrator owns $name; close it in its chat"
            elif herdr agent prompt "$owner" "Clean up lane $name ($root): the user pressed close on it in the graph panel. Offer your cleanup step as usual: confirm with the user, remove its worktree (never --force), then lane.sh close." >/dev/null 2>&1; then
                MSG="asked $owner to clean up $name"
            else
                MSG="could not reach $owner; close $name in its chat"
            fi ;;
    esac
}

# The [restore] of a closed lane, confirmed: lane.sh restore brings its record back with its
# last status. The record only: no worktree or branch is made.
restore_lane() { # lane JSON
    local name root out
    name="$(jq -r '.lane' <<<"$1")" root="$(jq -r '.root' <<<"$1")"
    if out="$(bash "$HERE/lane.sh" restore --repo "$root" --lane "$name" 2>&1)"; then
        MSG="restored $name (the record only: no worktree or branch)"
    else
        MSG="could not restore $name: ${out#*: }"
    fi
    refresh_view
}

# [clear all] (every closed lane, shown or not) or [clear all reviews] (every closed review
# lane), confirmed. Open lanes, worktrees and branches are never touched.
clear_closed() { # all | reviews
    local root name
    while IFS="$(printf '\t')" read -r root name; do
        [ -n "$name" ] || continue
        bash "$HERE/lane.sh" clear --repo "$root" --lane "$name" >/dev/null 2>&1 || MSG="could not clear $name"
    done < <(jq -r --arg which "$1" "$REVIEW_JQ"'
        .[] | select(.section == "closed" and ($which == "all" or isreview)) | [.root, .lane] | @tsv' <<<"$VIEW")
    refresh_view
}

# A press of a button that asks first ([x]: x|root|lane, [restore]: restore|root|lane,
# [clear all]: all, [clear all reviews]: reviews): the first arms it, a press of the armed
# button acts. act has already put any armed button back in PREV.
press() { # key, lane JSON (for [x] and [restore])
    if [ "$PREV" = "$1" ]; then
        case "$1" in
            all | reviews) clear_closed "$1" ;;
            restore\|*) restore_lane "$2" ;;
            *) close_lane "$2" ;;
        esac
    else
        ARMED="$1"
    fi
}

# Milliseconds, for the double click: bash 5's EPOCHREALTIME, else perl, else whole seconds.
now_ms() {
    local t="${EPOCHREALTIME:-}"
    if [ -n "$t" ]; then t="${t/[.,]/}"; printf '%s\n' $((10#$t / 1000)); return 0; fi
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000' 2>/dev/null || printf '%s000\n' "$(date +%s)"
}

# A double click: a plain click (not a button, chevron, pull request or file) on a lane, then
# another on the same lane within DOUBLE_CLICK_MS of the panel finishing the first (the click
# is stamped after the redraw, so a slow redraw does not eat the window).
DOUBLE_CLICK_MS="${GRAPH_DOUBLE_CLICK_MS:-400}"
DC_LANE="" DC_AT=0 DC_PENDING=0
plain_click() { # display index
    local now
    sel="$1"
    now="$(now_ms)"
    if [ "$DC_LANE" = "$1" ] && [ $((now - DC_AT)) -le "$DOUBLE_CLICK_MS" ]; then
        DC_LANE=""
        jump "$(lane_at "$1")"
    else
        DC_LANE="$1" DC_PENDING=1
    fi
}
clicked_done() { # after the redraw that follows a click
    [ "$DC_PENDING" -eq 0 ] || DC_AT="$(now_ms)"
    DC_PENDING=0
}

# The button of a lane's first line or the CLOSED header under a column, from the
# "id=from-to;..." map body() drew; prints its id.
button_at() { # map, column
    local b from to IFS=';'
    for b in $1; do
        from="${b#*=}" to="${from#*-}" from="${from%-*}"
        if [ "$2" -ge "$from" ] && [ "$2" -le "$to" ]; then printf '%s\n' "${b%%=*}"; return 0; fi
    done
}

act() { # key: only click (and refresh, from panel-action.sh) does anything
    local lane k idx rest map hit
    case "$1" in
        refresh) refresh_view; return 0 ;;
        click) ;;
        *) return 0 ;;
    esac
    # any click puts an armed button back; press arms it again
    PREV="$ARMED" ARMED=""
    if [ "$CLICK_ROW" -eq "$BTN_ROW" ] && [ "$CLICK_COL" -ge "$BTN_IV_FROM" ] && [ "$CLICK_COL" -le "$BTN_IV_TO" ]; then
        interval="$(next_interval "$interval")"
        DC_LANE=""
    elif [ "$CLICK_ROW" -eq "$BTN_ROW" ] && [ "$CLICK_COL" -ge "$BTN_RF_FROM" ] && [ "$CLICK_COL" -le "$BTN_RF_TO" ]; then
        refresh_view
        DC_LANE=""
    elif [ "$CLICK_ROW" -ge 1 ] && [ "$CLICK_ROW" -le "${#ROWMAP[@]}" ]; then
        k="${ROWMAP[$((CLICK_ROW - 1))]}"
        idx="${k%%[!0-9-]*}" rest="${k#"$idx"}" map="" hit=""
        case "$rest" in h*@* | c@*) map="${rest#*@}" rest="${rest%%@*}" ;; esac
        [ -z "$map" ] || hit="$(button_at "$map" "$CLICK_COL")"
        [ "$rest" = h ] && [ -z "$hit" ] && [ "$CLICK_COL" -ge 2 ] && [ "$CLICK_COL" -le 3 ] && hit="fold"
        case "$rest" in
            u*) sel="$idx" DC_LANE=""; browse "${rest#u}" ;;
            f*) sel="$idx" DC_LANE=""; open_ref "${rest#f}" "$(lane_at "$idx")" ;;
            c) DC_LANE=""
               case "$hit" in all | reviews) press "$hit" "" ;; esac ;;
            m) ALLCLOSED=1 DC_LANE="" ;;
            h | "")
                if [ "$idx" -lt 0 ]; then DC_LANE=""
                elif [ -z "$hit" ]; then plain_click "$idx"
                else
                    sel="$idx" DC_LANE=""
                    lane="$(lane_at "$idx")"
                    case "$hit" in
                        fold) toggle_fold "$(jq -r '.lane' <<<"$lane")" ;;
                        detail) open_popup detail "$lane" ;;
                        answer) open_popup answer "$lane" ;;
                        x | restore) press "$hit|$(jq -r '"\(.root)|\(.lane)"' <<<"$lane")" "$lane" ;;
                    esac
                fi ;;
        esac
    fi
    [ "$sel" -lt "$(lane_count)" ] || sel=0
}

# Waits up to $1 seconds for input; sets KEY (click, refresh, or the key that was pressed,
# which act ignores; empty on a timeout or an ignored sequence) and CLICK_ROW/CLICK_COL.
# Returns nonzero at the end of the input (--feed).
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
                "<") # SGR mouse: button;col;row then M (press) or m (release)
                    while IFS= read -rsn1 -t 1 c; do
                        case "$c" in M | m) break ;; *) rest="$rest$c" ;; esac
                    done
                    if [ "$c" = M ] && [ "${rest%%;*}" = 0 ]; then
                        CLICK_COL="$(cut -d';' -f2 <<<"$rest")" CLICK_ROW="$(cut -d';' -f3 <<<"$rest")"
                        KEY=click
                    fi ;;
                [0-9]) # ESC [ n ~ : ESC [ 99 ~ is panel-action.sh refresh; other keys are ignored
                    rest="$c"
                    while IFS= read -rsn1 -t 1 c; do
                        case "$c" in [0-9]) rest="$rest$c" ;; *) break ;; esac
                    done
                    [ "$rest$c" = "99~" ] && KEY=refresh ;;
                *) KEY=key ;;
            esac ;;
        *) KEY=key ;;
    esac
}

case "${1:-}" in
--next-interval) next_interval "${2:?}"; exit 0 ;;
--reset-view) reset_view; exit 0 ;;
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
        while read_key 5; do
            [ -n "$KEY" ] || continue
            act "$KEY"
            frame "$w" "$interval" "$sel" >/dev/null
            clicked_done
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
    wait
    exit 0 ;;
"") ;;
*) usage "panel.sh [--frame ... | --next-interval S | --buttons ... | --reset-view]" ;;
esac

# ---- interactive ----
require_tools jq yq git herdr
FETCH_PRS=1
interval="$(configured_interval)"
sel=0 MSG=""
reset_view
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
    fi
    case "$KEY" in
        click | refresh) ;;
        *) # a timeout or a keystroke (ignored): only the timer
            if [ $((SECONDS - last)) -ge "$interval" ]; then
                refresh_view
                last=$SECONDS
                draw
            fi
            continue ;;
    esac
    [ "$KEY" != click ] || mark_seen
    act "$KEY"
    [ "$KEY" = refresh ] && last=$SECONDS
    draw
    clicked_done
done
