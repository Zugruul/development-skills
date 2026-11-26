#!/usr/bin/env bash
# src/style.sh -- sourced by panel.sh and popup.sh; not run by itself.
# The terminal styles of the panel and the popups, as plain ANSI SGR codes, so both look
# the same: bold only for emphasis (section headers, lane names, the selected row), normal
# weight for content, grey for secondary text (patterns, last lines, references, hints,
# the footer). Every code is empty when NO_COLOR is set to a non-empty value (no-color.org).
# The variables are read by the scripts that source this file.
# shellcheck disable=SC2034

if [ -n "${NO_COLOR:-}" ]; then
    S_BOLD="" S_UNBOLD="" S_FG="" S_RESET="" S_EOL=""
    S_GREY="" S_DIM="" S_RED="" S_YELLOW="" S_GREEN="" S_ACCENT="" S_SELBG=""
    S_H_NEEDS="" S_H_WORKING="" S_H_DONE=""
else
    _e=$'\033'
    S_BOLD="${_e}[1m" S_UNBOLD="${_e}[22m" S_FG="${_e}[39m" S_RESET="${_e}[0m" S_EOL="${_e}[K"
    S_GREY="${_e}[90m" S_DIM="${_e}[2;90m" S_RED="${_e}[31m" S_YELLOW="${_e}[33m" S_GREEN="${_e}[32m"
    S_ACCENT="${_e}[36m" S_SELBG="${_e}[48;5;236m"
    S_H_NEEDS="${_e}[1;31m" S_H_WORKING="${_e}[1;33m" S_H_DONE="${_e}[1;32m"
    unset _e
fi

style_json() { # the styles as one JSON object, for jq --argjson c
    jq -cn --arg bold "$S_BOLD" --arg unbold "$S_UNBOLD" --arg fg "$S_FG" --arg reset "$S_RESET" \
        --arg eol "$S_EOL" --arg grey "$S_GREY" --arg dim "$S_DIM" --arg red "$S_RED" \
        --arg yellow "$S_YELLOW" --arg green "$S_GREEN" --arg accent "$S_ACCENT" --arg selbg "$S_SELBG" \
        --arg needs "$S_H_NEEDS" --arg working "$S_H_WORKING" --arg hdone "$S_H_DONE" \
        '{bold: $bold, unbold: $unbold, fg: $fg, reset: $reset, eol: $eol, grey: $grey, dim: $dim,
          red: $red, yellow: $yellow, green: $green, accent: $accent, selbg: $selbg,
          head: {needs: $needs, working: $working, done: $hdone}}'
}

# A node's mark and its colour, the same in the panel and the detail popup (jq, needs $c).
# shellcheck disable=SC2016
STYLE_JQ_MARK='
    def mark: if .status == "done" and .result == "changes" then "✗" elif .status == "done" then "✓"
              elif .status == "running" then "⟳" elif .status == "failed" then "✗"
              elif .status == "blocked" then "?" elif .status == "skipped" then "–" else "·" end;
    def markcolour: if .status == "done" and .result == "changes" then $c.red elif .status == "done" then $c.green
                    elif .status == "running" then $c.yellow elif .status == "failed" or .status == "blocked" then $c.red
                    else $c.grey end;'
