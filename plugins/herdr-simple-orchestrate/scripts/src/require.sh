#!/usr/bin/env bash
# src/require.sh -- sourced after src/herdr.sh; not run by itself.
# require_herdr stops the script unless it runs inside a Herdr pane.
# Codex does not inherit Herdr's HERDR_ENV, so a Codex session is accepted only
# when its session marker is set and Herdr lists exactly one live Codex agent
# whose cwd and foreground_cwd are both this checkout.

real_dir() { # path -> physical path, or the path itself when it cannot be entered
    (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

require_herdr() {
    local here matches reason pane tab ws
    command -v jq >/dev/null 2>&1 || die "HERDR UNAVAILABLE: jq is not on PATH. These scripts need jq." 2
    command -v herdr >/dev/null 2>&1 || die "HERDR UNAVAILABLE: the herdr binary is not on PATH." 2
    [ "${HERDR_ENV:-}" = "1" ] && return 0
    if [ -n "${CODEX_SESSION_ID:-}" ]; then
        herdr_call agent list
        if [ "$HC_RC" -eq 0 ] && [ "$HC_JSON" -eq 1 ]; then
            here="$(pwd -P)"
            matches=""
            while IFS="$(printf '\t')" read -r cwd fg pane tab ws; do
                [ -n "$cwd" ] && [ -n "$fg" ] || continue
                [ "$(real_dir "$cwd")" = "$here" ] && [ "$(real_dir "$fg")" = "$here" ] || continue
                matches="${matches}${pane}	${tab}	${ws}
"
            done <<EOT
$(hj -r '.result | objects | .agents | arrays | .[] | objects | select(.agent == "codex") | [(.cwd | strings) // "", (.foreground_cwd | strings) // "", .pane_id // "", .tab_id // "", .workspace_id // ""] | @tsv')
EOT
            if [ "$(printf '%s' "$matches" | grep -c .)" -eq 1 ]; then
                IFS="$(printf '\t')" read -r pane tab ws <<EOT
$matches
EOT
                [ -n "$pane" ] && export HERDR_PANE_ID="${HERDR_PANE_ID:-$pane}"
                [ -n "$tab" ] && export HERDR_TAB_ID="${HERDR_TAB_ID:-$tab}"
                [ -n "$ws" ] && export HERDR_WORKSPACE_ID="${HERDR_WORKSPACE_ID:-$ws}"
                return 0
            fi
        fi
        reason="no unique live Herdr Codex agent matches this checkout"
    else
        reason="this agent is not running inside a Herdr pane (HERDR_ENV is not 1)"
    fi
    die "HERDR UNAVAILABLE: $reason. Do not control Herdr from outside it." 2
}
