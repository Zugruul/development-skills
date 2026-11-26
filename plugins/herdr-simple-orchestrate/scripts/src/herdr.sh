#!/usr/bin/env bash
# src/herdr.sh -- sourced by the scripts one level up; not run by itself.
# Runs the herdr CLI and reads its JSON with jq. Helpers set variables instead
# of printing, so a failure can stop the calling script:
#   herdr_call ARGS...   -> HC_RC (exit code), HC_OUT (text), HC_JSON (1 when a JSON object)
#   agents_load          -> AGENTS_JSON (array of live agents)
#   workspaces_load      -> WS_JSON (array of workspaces; empty when herdr fails)
#   agent_get TARGET     -> AGENT_JSON; returns 1 when the target hosts no agent
#   screen TARGET SOURCE LINES -> SCREEN_TEXT
# Works with bash 3.2 (macOS), Linux and WSL on Windows. Needs jq.
# The variables are read by the scripts that source this file.
# shellcheck disable=SC2034

INTERVAL="${HERDR_CTL_INTERVAL:-2}"
HC_RC=0
HC_OUT=""
HC_JSON=0
AGENTS_JSON="[]"
WS_JSON="[]"
AGENT_JSON="{}"
SCREEN_TEXT=""

die() { # message [exit code]
    printf '%s\n' "$1" >&2
    exit "${2:-1}"
}

usage() { # usage line
    printf 'usage: %s\n' "$1" >&2
    exit 2
}

need_value() { # flag, number of arguments left
    [ "$2" -ge 2 ] || die "$1 needs a value" 2
}

herdr_call() {
    local errfile err
    errfile="$(mktemp "${TMPDIR:-/tmp}/herdr-call.XXXXXX")" || die "could not create a temporary file"
    HC_OUT="$(herdr "$@" 2>"$errfile")"
    HC_RC=$?
    if [ "$HC_RC" -ne 0 ]; then
        err="$(cat "$errfile")"
        [ -n "$err" ] && HC_OUT="$err"
    fi
    rm -f "$errfile"
    if printf '%s' "$HC_OUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
        HC_JSON=1
    else
        HC_JSON=0
    fi
}

hj() { # jq arguments, applied to the last herdr answer
    printf '%s' "$HC_OUT" | jq "$@"
}

err_code() {
    [ "$HC_JSON" -eq 1 ] || return 0
    hj -r '(.error | objects | .code) // ""'
}

err_text() {
    if [ "$HC_JSON" -eq 1 ] && hj -e '.error | type == "object"' >/dev/null 2>&1; then
        hj -r '.error | "\(.code // "error"): \(.message // "")"'
    elif [ -n "$HC_OUT" ]; then
        printf '%s\n' "$HC_OUT"
    else
        printf 'no output\n'
    fi
}

agents_load() {
    herdr_call agent list
    [ "$HC_RC" -eq 0 ] || die "herdr agent list failed: $(err_text)"
    AGENTS_JSON="[]"
    [ "$HC_JSON" -eq 1 ] && AGENTS_JSON="$(hj -c '[.result | objects | .agents | arrays | .[] | objects]')"
    return 0
}

workspaces_load() {
    herdr_call workspace list
    WS_JSON="[]"
    if [ "$HC_RC" -eq 0 ] && [ "$HC_JSON" -eq 1 ]; then
        WS_JSON="$(hj -c '[.result | objects | .workspaces | arrays | .[] | objects | select(.workspace_id | type == "string")]')"
    fi
    return 0
}

agent_get() { # target
    AGENT_JSON="{}"
    herdr_call agent get "$1"
    if [ "$HC_RC" -ne 0 ]; then
        [ "$(err_code)" = "agent_not_found" ] && return 1
        die "herdr agent get $1 failed: $(err_text)"
    fi
    [ "$HC_JSON" -eq 1 ] || return 1
    AGENT_JSON="$(hj -c '.result | objects | .agent | objects')"
    [ -n "$AGENT_JSON" ] && return 0
    AGENT_JSON="{}"
    return 1
}

af() { # field of AGENT_JSON, empty when absent
    printf '%s' "$AGENT_JSON" | jq -r --arg k "$1" '.[$k] // "" | tostring'
}

agent_label() { # name, else pane id, else ?
    printf '%s' "$AGENT_JSON" | jq -r '(.name | strings | select(. != "")) // (.pane_id | strings | select(. != "")) // "?"'
}

screen() { # target source lines
    local text
    herdr_call agent read "$1" --source "$2" --lines "$3"
    if [ "$HC_RC" -ne 0 ]; then
        SCREEN_TEXT="(could not read $2: $(err_text))"
        return 0
    fi
    # shellcheck disable=SC2016  # $r is a jq variable
    if [ "$HC_JSON" -eq 1 ] && text="$(hj -er '((.result | objects) // {}) as $r | [$r.text, $r.content, $r.output, ($r.read | objects | .text)] | map(strings) | .[0] // empty')"; then
        SCREEN_TEXT="$text"
    else
        SCREEN_TEXT="$HC_OUT"
    fi
    return 0
}
