#!/usr/bin/env bash
# src/style.sh -- sourced by panel.sh and popup.sh; not run by itself.
# The terminal styles of the panel and the popups, as plain ANSI SGR codes, so both look
# the same: bold only for emphasis (section headers, lane names, the selected row), normal
# weight for content, grey for secondary text (patterns, last lines, references, hints,
# the footer). Every code is empty when NO_COLOR is set to a non-empty value (no-color.org).
# The variables are read by the scripts that source this file.
# shellcheck disable=SC2034

# The colours are the mockup's, as 24-bit SGR: red f85149, amber d29922, green 3fb950,
# grey 8b949e, the selected row's background 21262d; for pull requests also blue 58a6ff
# (open) and purple a371f7 (merged). Without colour the selected row ends
# with S_SELMARK instead of the background.
if [ -n "${NO_COLOR:-}" ]; then
    S_BOLD="" S_UNBOLD="" S_FG="" S_RESET="" S_EOL=""
    S_GREY="" S_RED="" S_YELLOW="" S_GREEN="" S_BLUE="" S_PURPLE="" S_SELBG="" S_SELMARK=" ◂"
    S_H_NEEDS="" S_H_WORKING="" S_H_DONE="" S_H_CLOSED=""
else
    _e=$'\033'
    S_BOLD="${_e}[1m" S_UNBOLD="${_e}[22m" S_FG="${_e}[39m" S_RESET="${_e}[0m" S_EOL="${_e}[K"
    S_GREY="${_e}[38;2;139;148;158m" S_RED="${_e}[38;2;248;81;73m" S_YELLOW="${_e}[38;2;210;153;34m"
    S_GREEN="${_e}[38;2;63;185;80m" S_BLUE="${_e}[38;2;88;166;255m" S_PURPLE="${_e}[38;2;163;113;247m"
    S_SELBG="${_e}[48;2;33;38;45m" S_SELMARK=""
    S_H_NEEDS="$S_BOLD$S_RED" S_H_WORKING="$S_BOLD$S_YELLOW" S_H_DONE="$S_BOLD$S_GREEN" S_H_CLOSED="$S_BOLD$S_GREY"
    unset _e
fi

style_json() { # the styles as one JSON object, for jq --argjson c
    jq -cn --arg bold "$S_BOLD" --arg unbold "$S_UNBOLD" --arg fg "$S_FG" --arg reset "$S_RESET" \
        --arg eol "$S_EOL" --arg grey "$S_GREY" --arg red "$S_RED" \
        --arg yellow "$S_YELLOW" --arg green "$S_GREEN" --arg blue "$S_BLUE" --arg purple "$S_PURPLE" --arg selbg "$S_SELBG" --arg selmark "$S_SELMARK" \
        --arg needs "$S_H_NEEDS" --arg working "$S_H_WORKING" --arg hdone "$S_H_DONE" --arg hclosed "$S_H_CLOSED" \
        '{bold: $bold, unbold: $unbold, fg: $fg, reset: $reset, eol: $eol, grey: $grey,
          red: $red, yellow: $yellow, green: $green, blue: $blue, purple: $purple, selbg: $selbg, selmark: $selmark,
          head: {needs: $needs, working: $working, done: $hdone, closed: $hclosed}}'
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

# A pull request's state, in the words of an orchestrator report (draft, open, merged,
# closed), with an open one's review decision added (jq, no $c needed).
# shellcheck disable=SC2016
STYLE_JQ_PR='
    def prstate: if .state == "MERGED" then "merged" elif .state == "CLOSED" then "closed"
                 elif .isDraft then "draft" elif .reviewDecision == "APPROVED" then "approved"
                 elif .reviewDecision == "CHANGES_REQUESTED" then "changes" else "open" end;
    def prword: {draft: "draft", open: "open", approved: "open · approved",
                 changes: "open · changes requested", merged: "merged", closed: "closed"}[prstate];'

# And its colour (jq, needs $c): draft grey, open blue, approved green, changes requested
# amber, merged purple, closed red.
# shellcheck disable=SC2016
STYLE_JQ_PRCOLOUR='
    def prcolour: {draft: $c.grey, open: $c.blue, approved: $c.green, changes: $c.yellow,
                   merged: $c.purple, closed: $c.red}[prstate];'
