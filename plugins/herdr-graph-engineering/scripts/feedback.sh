#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# feedback.sh -- the feedback loop: notes on how the whole flow could have been better, and
# the sanitiser that keeps every detail of a task out of the plugin's repository.
#
# The loop is off by default; the session file holds the toggle (session.sh set --key feedback
# --value on|off, asked by the feedback-loop skill and at the orchestrator's start).
# Raw notes (what the orchestrator and a lane's agents said) stay in the user's state folder,
# outside every repository:
#   ${XDG_STATE_HOME:-~/.local/state}/herdr-graph/sessions/feedback/<session>.yaml
# A lesson is a general rule written from those notes. It is stored only when the sanitiser
# finds no task detail in it, and the open lessons are the only text an improvement lane gets.
#
# Usage (every command takes --session NAME; default: the session whose pane is $HERDR_PANE_ID, else graph):
#   feedback.sh state                               FEEDBACK on|off (session)
#   feedback.sh add --text T [--from WHO] [--lane L] [--node N] [--repo DIR]
#                                                   a raw note (WHO default orchestrator); exit 4 while off
#   feedback.sh due --lane L                        FEEDBACK L (...) and exit 0 when the loop is on and the
#                                                   orchestrator has no note for L yet; exit 1 otherwise
#   feedback.sh lesson --text T [--repo DIR]... [--deny WORD]...
#                                                   a sanitised lesson; exit 3 (and nothing stored) on a leak
#   feedback.sh lessons                             the open lessons, one "- " line each
#   feedback.sh used (--id N | --all) [--ref TEXT]  lessons handed to an improvement lane (TEXT: where they went)
#   feedback.sh show [--json]                       notes and lessons
#   feedback.sh path                                the feedback file's path
#   feedback.sh sanitize [--file F]... [--strip] [--repo DIR]... [--deny WORD]...
#                                                   check text (the files, else stdin). Clean: print it
#                                                   unchanged, exit 0. Else one "LEAK <kind> line N: <what>"
#                                                   line per finding and REFUSED on stderr, exit 3. With
#                                                   --strip: print only the clean lines, exit 3 if none.
# Leak kinds: url email handle secret number sha ip path file code quote name deny.
# Denied words come from --deny, from each --repo (its folder name, its origin's owner and name,
# its branch names, its commit authors) and from the session (every lane and repository its
# feedback notes and queued lanes name). The sanitiser is conservative: it refuses a line rather
# than guess. It cannot know every name: see "What the sanitiser cannot catch" in the README.
# Exit codes: 0 ok, 1 error or not due, 2 usage or a secret, 3 a leak, 4 the loop is off, 6 no such item.
# shellcheck disable=SC2016 # jq programs and the code-span pattern are single-quoted on purpose
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"

USAGE="feedback.sh state|add|due|lesson|lessons|used|show|path|sanitize [--session NAME] [options] (see the header of feedback.sh)"
args=() files=() repos=() denies=()
session="" text="" from="orchestrator" lane="" node="" repo="" id="" all=0 ref="" strip=0 as_json=0
while [ $# -gt 0 ]; do
    case "$1" in
        --session) need_value "$1" $#; session="$2"; shift 2 ;;
        --text) need_value "$1" $#; text="$2"; shift 2 ;;
        --from) need_value "$1" $#; from="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        --node) need_value "$1" $#; node="$2"; shift 2 ;;
        --repo) need_value "$1" $#; repo="$2"; repos+=("$2"); shift 2 ;;
        --deny) need_value "$1" $#; denies+=("$2"); shift 2 ;;
        --file) need_value "$1" $#; files+=("$2"); shift 2 ;;
        --id) need_value "$1" $#; id="$2"; shift 2 ;;
        --ref) need_value "$1" $#; ref="$2"; shift 2 ;;
        --all) all=1; shift ;;
        --strip) strip=1; shift ;;
        --json) as_json=1; shift ;;
        -*) usage "$USAGE" ;;
        *) args+=("$1"); shift ;;
    esac
done
[ "${#args[@]}" -eq 1 ] || usage "$USAGE"
cmd="${args[0]}"
require_tools jq yq
if [ -z "$session" ]; then
    session="graph"
    [ -z "${HERDR_PANE_ID:-}" ] || session="$(bash "$HERE/session.sh" find --pane "$HERDR_PANE_ID" 2>/dev/null)" || session="graph"
fi
[ "$(slug "$session")" = "$session" ] || die "SESSION NAME: '$session' must be a lowercase slug" 2
sfile="$(session_dir)/$session.yaml"
dir="$(session_dir)/feedback"
file="$dir/$session.yaml"

loop_state() {
    local v="off"
    [ -f "$sfile" ] && v="$(yq -r '.feedback // "off"' "$sfile" 2>/dev/null)"
    [ "$v" = on ] && echo on || echo off
}

fb_json() {
    if [ -f "$file" ]; then read_json "$file"; else echo '{}'; fi
}

update() { # jq program, extra jq args...
    local prog="$1" out cur='{}'
    shift
    lock_in "$dir"
    [ -f "$file" ] && cur="$(read_json "$file")"
    [ -n "$cur" ] && [ "$cur" != null ] || cur='{}'
    out="$(jq -c --arg now "$(now)" --arg s "$session" "$@" \
        '{session: $s, next_id: 1, notes: [], lessons: []} + . | '"$prog"' | .updated = $now' <<<"$cur")" || die "could not update $file"
    printf '%s' "$out" | write_yaml "$file"
    unlock
}

# ---------------------------------------------------------------------------------------------
# The sanitiser.

DENY=""      # newline-separated lowercase words
add_deny() { # word...
    local w
    for w in "$@"; do
        w="$(printf '%s' "$w" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        case "$w" in '' | main | master | develop | trunk | head | origin) continue ;; esac
        [ "${#w}" -ge 3 ] || continue
        DENY="$DENY
$w"
    done
}

deny_from_repo() { # dir
    local d="$1" top url b n
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || { add_deny "$(basename "$d")"; return 0; }
    add_deny "$(basename "$top")"
    url="$(git -C "$d" remote get-url origin 2>/dev/null)" || url=""
    if [ -n "$url" ]; then
        url="${url%.git}"
        url="${url%/}"
        add_deny "${url##*/}"
        url="${url%/*}"
        add_deny "${url##*[/:]}"
    fi
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        add_deny "$b" "${b##*/}"
    done < <(git -C "$d" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
    while IFS= read -r n; do
        # shellcheck disable=SC2086 # split an author's name into its words
        add_deny ${n//[^A-Za-z0-9_-]/ }
    done < <(git -C "$d" log -n 200 --format='%an%n%ae' 2>/dev/null | sed 's/@.*//' | sort -u)
}

deny_from_session() {
    local r
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        add_deny "$r"
    done < <(jq -r '[.notes // [] | .[] | .lane // empty] | unique | .[]' <<<"$(fb_json)")
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        deny_from_repo "$r"
    done < <(jq -r '[.notes // [] | .[] | .repo // empty] | unique | .[]' <<<"$(fb_json)")
    [ -f "$sfile" ] || return 0
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        case "$r" in /*) deny_from_repo "$r" ;; *) add_deny "$r" ;; esac
    done < <(read_json "$sfile" | jq -r '[.queued // [], .renames // [] | .[] | (.lane // empty), (.repo // empty)] | unique | .[]')
}

# Words a lesson may use although they look like a name, a file or a path: the plugin's own.
PLUGIN_FILES="$(find "$PLUGIN_ROOT" -path "$PLUGIN_ROOT/tests" -prune -o -type f -print 2>/dev/null | sed 's#.*/##' | sort -u)
AGENTS.md
CLAUDE.md"
ALLOW_SLASH=" and/or on/off pass/fail read/write yes/no either/or input/output stdout/stderr origin/main "
ALLOW_NAMES=" Herdr Herdr's Claude Code Codex OpenCode GitHub Git Markdown Bash AskUserQuestion macOS Linux Windows I "
ALLOW_CODE=" herdr git gh jq yq bash "

is_plugin_file() { grep -qxF -- "$1" <<<"$PLUGIN_FILES"; }
is_denied() { [ -n "$DENY" ] && grep -qxF -- "$1" <<<"$DENY"; }
plugin_path() { # token -> 0 when it names something inside this plugin
    local p="$1"
    while :; do
        case "$p" in
            ../*) p="${p#../}" ;;
            ./*) p="${p#./}" ;;
            plugins/herdr-graph-engineering/*) p="${p#plugins/herdr-graph-engineering/}" ;;
            herdr-graph-engineering/*) p="${p#herdr-graph-engineering/}" ;;
            *) break ;;
        esac
    done
    case "$p" in '' | /* | *..* | tests* ) return 1 ;; esac
    [ -e "$PLUGIN_ROOT/$p" ]
}

RE_URL='[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]*|www\.[^[:space:]]+'
RE_EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
RE_HANDLE='(^|[^A-Za-z0-9_.])@[A-Za-z0-9_][A-Za-z0-9_-]*'
RE_REF='#[0-9]+|(^|[^A-Za-z])([Pp][Rr]|[Ii]ssue|[Tt]icket|[Pp]ull)[ -]?#?[0-9]+|[A-Z][A-Z0-9]{1,9}-[0-9]+|[0-9]{4,}'
RE_SHA='(^|[^A-Za-z0-9])[0-9a-fA-F]{7,40}([^A-Za-z0-9]|$)'
RE_IP='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
RE_CODE='[{}]|=>|==|!=|&&|\|\||\$\(|\$\{|</|\(\)'
RE_FENCE='^[[:space:]]*(```|~~~)'
# shellcheck disable=SC1111 # the curly quotes are what it looks for
RE_QUOTE="\"|“|”|«|»|‘|^[[:space:]]*>|(^|[[:space:](])'[^']+'"
RE_SPAN='`([^`]+)`'
RE_LEAD="^[][(){}\"'\`*_<>]"
RE_TRAIL="[][(){}.,;:!?\"'\`*_<>]\$"
RE_SPAN_OK='^(--|<|[A-Z][A-Z_]+:?$)'
RE_FILE='^[A-Za-z0-9_-]{2,}(\.[A-Za-z0-9_-]+)*\.[A-Za-z][A-Za-z0-9]{0,5}$'

FOUND=""
leak() { FOUND="$FOUND$1 line $2: $3
"; }

scan_line() { # line, number
    local line="$1" n="$2" rest tok prev="" first w part start lower words span whole
    [[ "$line" =~ $RE_URL ]] && leak url "$n" "${BASH_REMATCH[0]}"
    [[ "$line" =~ $RE_EMAIL ]] && leak email "$n" "${BASH_REMATCH[0]}"
    [[ "$line" =~ $RE_HANDLE ]] && leak handle "$n" "${BASH_REMATCH[0]}"
    looks_secret "$line" && leak secret "$n" "(a token, key or password)"
    [[ "$line" =~ $RE_REF ]] && leak number "$n" "${BASH_REMATCH[0]}"
    [[ "$line" =~ $RE_SHA ]] && leak sha "$n" "${BASH_REMATCH[0]}"
    [[ "$line" =~ $RE_IP ]] && leak ip "$n" "${BASH_REMATCH[0]}"
    [[ "$line" =~ $RE_CODE ]] && leak code "$n" "${BASH_REMATCH[0]}"
    [[ "$line" =~ $RE_QUOTE ]] && leak quote "$n" "${BASH_REMATCH[0]}"
    rest="$line"
    while [[ "$rest" =~ $RE_SPAN ]]; do
        span="${BASH_REMATCH[1]}" whole="${BASH_REMATCH[0]}"
        first="${span%% *}"
        case "$ALLOW_CODE" in *" $first "*) ;; *)
            if ! is_plugin_file "$first" && ! is_plugin_file "$first.sh" && [[ ! "$first" =~ $RE_SPAN_OK ]] && ! plugin_path "$first"; then
                leak code "$n" "\`$span\`"
            fi ;;
        esac
        rest="${rest#*"$whole"}"
    done
    start=1
    read -r -a words <<<"$line"
    for w in ${words[@]+"${words[@]}"}; do
        tok="$w"
        # strip surrounding punctuation and a possessive
        while [[ "$tok" =~ $RE_LEAD ]]; do tok="${tok:1}"; done
        while [[ "$tok" =~ $RE_TRAIL ]]; do tok="${tok%?}"; done
        tok="${tok%\'s}"
        tok="${tok%’s}"
        if [ -n "$tok" ]; then
            if [[ "$tok" != *://* && "$tok" != *@* ]]; then
                if [[ "$tok" == */* || "$tok" == \~* || "$tok" == *\\* ]]; then
                    case "$ALLOW_SLASH" in *" $tok "*) ;; *) plugin_path "$tok" || leak path "$n" "$tok" ;; esac
                elif [[ "$tok" =~ $RE_FILE ]] && ! is_plugin_file "$tok" && ! [[ "$tok" =~ ^[0-9.]+$ ]]; then
                    leak file "$n" "$tok"
                fi
            fi
            lower="$(printf '%s' "$tok" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
            if is_denied "$lower"; then
                leak deny "$n" "$tok"
            else
                for part in ${lower//[^a-z0-9]/ }; do
                    is_denied "$part" && { leak deny "$n" "$tok"; break; }
                done
            fi
            # A capitalised word: a name unless it is the plugin's own, all capitals, or (plain
            # Titlecase only) the first word of a sentence. CamelCase is a name anywhere.
            if [[ "$tok" =~ [A-Z] && "$tok" =~ [a-z] ]]; then
                case "$ALLOW_NAMES" in *" $tok "*) ;; *)
                    if [[ "${tok:1}" =~ [A-Z] ]] || [ "$start" -eq 0 ]; then
                        leak name "$n" "$tok"
                    fi ;;
                esac
            fi
        fi
        prev="$w"
        start=0
        case "$prev" in
            *. | *! | *\? | *: | - | \* | + | \#* | \| | \>) start=1 ;;
        esac
    done
}

# scan_text FILE: fills FOUND; prints the clean lines to stdout when strip is on; returns the
# number of clean lines in CLEAN_LINES.
CLEAN_LINES=0
scan_text() { # file
    local line n=0 fence=0 before
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        before="$FOUND"
        if [[ "$line" =~ $RE_FENCE ]]; then
            leak code "$n" "a fenced code block"
            fence=$((1 - fence))
        elif [ "$fence" -eq 1 ]; then
            leak code "$n" "inside a fenced code block"
        else
            scan_line "$line" "$n"
        fi
        if [ "$FOUND" = "$before" ]; then
            CLEAN_LINES=$((CLEAN_LINES + 1))
            [ "$strip" -eq 0 ] || printf '%s\n' "$line"
        fi
    done <"$1"
}

# sanitize FILE: 0 clean (text printed), 3 a leak (LEAK lines on stderr)
sanitize() { # file
    local f="$1" r
    DENY="" FOUND="" CLEAN_LINES=0
    deny_from_session
    for r in ${repos[@]+"${repos[@]}"}; do deny_from_repo "$r"; done
    add_deny ${denies[@]+"${denies[@]}"}
    if [ "$strip" -eq 1 ]; then
        scan_text "$f"
        if [ -n "$FOUND" ]; then
            printf '%s' "$FOUND" | awk 'NF' | sed 's/^/STRIPPED /' >&2
        fi
        [ "$CLEAN_LINES" -gt 0 ] || { echo "REFUSED: no line is free of task details" >&2; return 3; }
        return 0
    fi
    scan_text "$f"
    if [ -n "$FOUND" ]; then
        printf '%s' "$FOUND" | awk 'NF' | sed 's/^/LEAK /' >&2
        echo "REFUSED: $(printf '%s' "$FOUND" | awk 'NF' | wc -l | tr -d ' ') leak(s). Write the general lesson only: no names, paths, branches, numbers, links, code or quoted words; or use --strip to drop those lines." >&2
        return 3
    fi
    cat "$f"
}

TMP=""
cleanup_tmp() { [ -z "$TMP" ] || rm -f "$TMP"; unlock; }
trap cleanup_tmp EXIT

case "$cmd" in
state) printf 'FEEDBACK %s (%s)\n' "$(loop_state)" "$session" ;;
add)
    [ -n "$text" ] || usage "feedback.sh add --text T [--from WHO] [--lane L] [--node N] [--repo DIR]"
    [ "$(loop_state)" = on ] || die "FEEDBACK OFF: the feedback loop is off for session $session; turn it on with the feedback-loop skill (session.sh set --key feedback --value on)" 4
    ! looks_secret "$text" || die "SECRET: that looks like a token, key or password; it is never stored." 2
    if [ -n "$repo" ]; then repo="$(cd "$repo" 2>/dev/null && pwd)" || die "no such directory: $repo" 2; fi
    update '.next_id as $id | .next_id += 1
            | .notes += [{id: $id, from: $from, text: $t, at: $now}
                         + (if $lane != "" then {lane: $lane} else {} end)
                         + (if $node != "" then {node: $node} else {} end)
                         + (if $repo != "" then {repo: $repo} else {} end)]' \
        --arg from "$from" --arg t "$text" --arg lane "$lane" --arg node "$node" --arg repo "$repo"
    printf 'ADDED note %s\n' "$(yq -r '.notes[-1].id' "$file")" ;;
due)
    [ -n "$lane" ] || usage "feedback.sh due --lane L"
    [ "$(loop_state)" = on ] || exit 1
    has="$(jq -r --arg l "$lane" '[.notes // [] | .[] | select(.lane == $l and .from == "orchestrator")] | length' <<<"$(fb_json)")"
    [ "${has:-0}" -eq 0 ] || exit 1
    printf 'FEEDBACK %s (the feedback loop is on: before cleanup, ask the lane'"'"'s live agents how the whole flow could have been better, then write your own note: feedback.sh add --from orchestrator --lane %s --text ...)\n' "$lane" "$lane" ;;
lesson)
    [ -n "$text" ] || usage "feedback.sh lesson --text T [--repo DIR]... [--deny WORD]..."
    [ "$(loop_state)" = on ] || die "FEEDBACK OFF: the feedback loop is off for session $session" 4
    TMP="$(mktemp)"
    printf '%s\n' "$text" >"$TMP"
    strip=0
    sanitize "$TMP" >/dev/null || exit 3
    rm -f "$TMP"; TMP=""
    update '.next_id as $id | .next_id += 1 | .lessons += [{id: $id, text: $t, at: $now}]' --arg t "$text"
    printf 'ADDED lesson %s\n' "$(yq -r '.lessons[-1].id' "$file")" ;;
lessons)
    jq -r '[.lessons // [] | .[] | select(.used == null)] | if length == 0 then "(no open lessons)" else .[] | "- " + (.text | gsub("\n"; " ")) end' <<<"$(fb_json)" ;;
used)
    [ -n "$id" ] || [ "$all" -eq 1 ] || usage "feedback.sh used (--id N | --all) [--ref TEXT]"
    [ -f "$file" ] || die "NO FEEDBACK for session $session" 6
    ! looks_secret "$ref" || die "SECRET: that looks like a token, key or password; it is never stored." 2
    hit="$(jq -r --arg id "$id" --argjson all "$all" '[.lessons // [] | .[] | select(.used == null) | select($all == 1 or (.id | tostring) == $id)] | length' <<<"$(fb_json)")"
    [ "${hit:-0}" -gt 0 ] || die "NO OPEN LESSON${id:+ with id $id}" 6
    update '.lessons |= map(if .used == null and ($all == 1 or (.id | tostring) == $id) then .used = (if $ref == "" then "yes" else $ref end) | .used_at = $now else . end)' \
        --arg id "$id" --argjson all "$all" --arg ref "$ref"
    printf 'USED %s lesson(s)\n' "$hit" ;;
show)
    if [ "$as_json" -eq 1 ]; then fb_json; else
        printf 'FEEDBACK %s (%s): %s\n' "$(loop_state)" "$session" "$file"
        jq -r '"NOTES (raw: never leave this folder)",
               (.notes // [] | if length == 0 then "  (none)" else .[] | "  #\(.id) \(.from)" + (if .lane then " lane \(.lane)" else "" end) + (if .node then "/\(.node)" else "" end) + ": \(.text | gsub("\n"; " "))" end),
               "LESSONS (sanitised)",
               (.lessons // [] | if length == 0 then "  (none)" else .[] | "  #\(.id) " + (if .used then "[used: \(.used)] " else "" end) + (.text | gsub("\n"; " ")) end)' <<<"$(fb_json)"
    fi ;;
path) printf '%s\n' "$file" ;;
sanitize)
    TMP="$(mktemp)"
    if [ "${#files[@]}" -gt 0 ]; then
        for f in "${files[@]}"; do
            [ -f "$f" ] || die "no such file: $f" 2
            cat "$f" >>"$TMP"
            [ -z "$(tail -c1 "$f")" ] || printf '\n' >>"$TMP"
        done
    else
        cat >"$TMP"
    fi
    sanitize "$TMP" ;;
*) usage "$USAGE" ;;
esac
