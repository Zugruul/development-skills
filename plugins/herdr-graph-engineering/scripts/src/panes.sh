#!/usr/bin/env bash
# src/panes.sh -- sourced by the scripts one level up; not run by itself.
# Which pane is whose, as small files a hook can test without running any tool:
#   <state>/herdr-graph/panes/<pane>.lane   {repo, lane, node, agent}: a running node's agent
#   <state>/herdr-graph/panes/<pane>.orch   the orchestrator session that lives in the pane
# lane.sh, session.sh and notify.sh write them; a stale file only means a hook looks and leaves.

panes_dir() {
    printf '%s/herdr-graph/panes\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

pane_key() { # pane id -> file name
    printf '%s' "${1//[^A-Za-z0-9]/_}"
}

pane_lane_set() { # pane, repo, lane, node, agent
    local d f
    d="$(panes_dir)"
    f="$d/$(pane_key "$1").lane"
    mkdir -p "$d" 2>/dev/null || return 0
    jq -cn --arg r "$2" --arg l "$3" --arg n "$4" --arg a "$5" '{repo: $r, lane: $l, node: $n, agent: $a}' >"$f.$$" 2>/dev/null && mv "$f.$$" "$f"
}

# One orchestrator pane per session: its earlier pane file goes.
pane_orch_set() { # pane, session
    local d f
    d="$(panes_dir)"
    mkdir -p "$d" 2>/dev/null || return 0
    for f in "$d"/*.orch; do
        [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "$2" ] && rm -f "$f"
    done
    printf '%s\n' "$2" >"$d/$(pane_key "$1").orch"
}
