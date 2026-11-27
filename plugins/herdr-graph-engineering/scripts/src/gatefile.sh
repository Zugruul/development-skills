#!/usr/bin/env bash
# src/gatefile.sh -- sourced after src/common.sh; not run by itself.
# A gate run's heartbeat: <lane folder>/gates/<lane>/<node>.json, next to its output log
# <node>.log. gate.sh writes it when it starts a run; `gate.sh --exec`, the process that runs
# the command in the gate's tab, adds its pid and, at the end, the exit code, the ok/FAIL counts,
# the failing test names and what the gate changed in the checkout. One file per node: a new run
# replaces the last one. Fields:
#   lane node run pane pid dir log started ended finished exit ok fail failed last changed recorded
# gate_facts adds what only a reader can see now: alive (the pid runs; null before it started),
# elapsed and quiet (seconds since the start and since the log last grew), and for a running
# gate the counts and the last output line read from the log.

GATE_OK_RE='^ok([[:space:]]|$)'
GATE_FAIL_RE='^(FAIL|not ok)([[:space:]]|$)'

gate_dir() { # repo dir, lane
    printf '%s/gates/%s\n' "$(lane_dir "$1")" "$2"
}

mtime_of() { # file -> modification time, epoch seconds (GNU stat, else BSD stat)
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# A log read as plain lines: no colour codes, a carriage return starts a new line.
gate_plain() { # log file
    local esc
    esc="$(printf '\033')"
    tr '\r' '\n' <"$1" 2>/dev/null | sed "s/${esc}\[[0-9;?]*[A-Za-z]//g"
}

# Counts, failing names and the last line of a log, as JSON.
gate_log_facts() { # log file
    local plain ok fail last failed
    plain="$(gate_plain "$1")"
    ok="$(grep -cE "$GATE_OK_RE" <<<"$plain")"
    fail="$(grep -cE "$GATE_FAIL_RE" <<<"$plain")"
    last="$(grep -v '^[[:space:]]*$' <<<"$plain" | tail -1 | cut -c1-160)"
    failed="$(grep -E "$GATE_FAIL_RE" <<<"$plain" | sed -E 's/^(FAIL|not ok)[[:space:]]*//' | head -200 | jq -Rcs 'split("\n") | map(select(. != ""))')"
    jq -cn --argjson o "${ok:-0}" --argjson f "${fail:-0}" --arg l "$last" --argjson n "${failed:-[]}" \
        '{ok: $o, fail: $f, last: $l, failed: $n}'
}

gate_facts() { # heartbeat file -> its JSON with the live facts
    local hb now pid alive log mt logj
    hb="$(cat "$1" 2>/dev/null)" || return 1
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$hb" || return 1
    now="$(date +%s)"
    if [ "$(jq -r '.finished // false' <<<"$hb")" = true ]; then
        jq -c '. + {alive: false, quiet: 0, elapsed: (((.ended // .started // 0) - (.started // 0)) | if . < 0 then 0 else . end)}' <<<"$hb"
        return 0
    fi
    pid="$(jq -r '.pid // empty' <<<"$hb")" alive=null
    if [ -n "$pid" ]; then
        if kill -0 "$pid" 2>/dev/null; then alive=true; else alive=false; fi
    fi
    log="$(jq -r '.log // empty' <<<"$hb")" logj='{}'
    mt="$(jq -r '.started // 0' <<<"$hb")"
    if [ -n "$log" ] && [ -s "$log" ]; then
        mt="$(mtime_of "$log")" || mt="$(jq -r '.started // 0' <<<"$hb")"
        logj="$(gate_log_facts "$log")"
    fi
    jq -c --argjson now "$now" --argjson a "$alive" --argjson mt "${mt:-0}" --argjson f "$logj" \
        '. + {ok: 0, fail: 0, last: ""} + ($f | del(.failed))
         + {alive: $a, elapsed: ($now - (.started // $now)), quiet: ([$now - $mt, 0] | max)}' <<<"$hb"
}

# A duration for people: 45s, 12m 04s, 1h 05m.
gate_dur() { # seconds
    local s="${1:-0}"
    if [ "$s" -lt 60 ]; then printf '%ss' "$s"
    elif [ "$s" -lt 3600 ]; then printf '%sm %02ds' $((s / 60)) $((s % 60))
    else printf '%sh %02dm' $((s / 3600)) $((s % 3600 / 60)); fi
}
