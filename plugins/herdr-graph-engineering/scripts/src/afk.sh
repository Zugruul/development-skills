#!/usr/bin/env bash
# src/afk.sh -- sourced by the scripts one level up after common.sh; not run by itself.
# Reads the session's AFK and auto-merge state (session.sh writes it). Everything that cannot be
# read counts as off: AFK and auto-merge only ever come from their commands.
# shellcheck disable=SC2016

# The session of this chat: the one whose pane is $HERDR_PANE_ID, else "graph".
default_session() {
    local f
    if [ -n "${HERDR_PANE_ID:-}" ]; then
        for f in "$(session_dir)"/*.yaml; do
            [ -f "$f" ] || continue
            [ "$(yq -r '.pane // ""' "$f" 2>/dev/null)" != "$HERDR_PANE_ID" ] || { basename "$f" .yaml; return 0; }
        done
    fi
    echo graph
}

session_json() { # session -> its file as JSON, {} when there is none
    local f
    f="$(session_dir)/$1.yaml"
    { [ -f "$f" ] && read_json "$f" 2>/dev/null; } || echo '{}'
}

# The AFK object while AFK is on and its time limit has not passed, else {"state":"off"}.
afk_json() { # session
    session_json "$1" | jq -c --arg now "$(now)" '(.afk // {}) as $a
        | if $a.state == "on" and (($a.until // "") == "" or $now < $a.until) then $a else {state: "off"} end'
}

afk_line() { # session -> one line for people
    afk_json "$1" | jq -r 'if .state != "on" then "AFK off" else
        "AFK on, tiers \(.tiers | map(tostring) | join(",")), lanes \(if (.lanes | length) == 0 then "all" else .lanes | join(",") end), queued ideas \(if .queued then "yes" else "no" end), worktree removal \(if .cleanup then "yes" else "no" end), until \(if (.until // "") == "" then "you return" else .until end) (since \(.since))" end'
}

# "on (lane|repository|session)", "off (...)" or "off": the narrowest setting wins.
automerge_state() { # session, repo root, lane
    local entry root="$2"
    entry="$(repo_entry "$2" 2>/dev/null)" && root="${entry#*$'\t'}"
    session_json "$1" | jq -r --arg r "$root" --arg l "$3" '(.automerge // {}) as $a
        | if $l != "" and ($a.lanes[$r + "|" + $l] // "") != "" then "\($a.lanes[$r + "|" + $l]) (lane)"
          elif ($a.repos[$r] // "") != "" then "\($a.repos[$r]) (repository)"
          elif ($a.session // "") == "on" then "on (session)"
          else "off" end'
}
