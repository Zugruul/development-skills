#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# gate.sh -- run a gate node's command in a visible Herdr pane and record its result.
# Usage:
#   gate.sh --lane L --node N --pane PANE [--repo DIR] [--timeout S] [--detach]
#       start a run in the pane; wait for it (S seconds, default 1800) unless --detach
#   gate.sh --wait --lane L --node N [--repo DIR] [--timeout S]     (--resume ID is the same)
#       block until the running gate finishes; portable bash, nothing to guess
#   gate.sh --collect --lane L --node N [--repo DIR] [--pane PANE]
#       record a finished run after the fact: from its heartbeat, else from the tab's EXIT line
#   gate.sh --exec --lane L --node N --run ID [--repo DIR]
#       what the pane runs (typed there by the first form); not for people
# Why a script: `herdr pane run` only queues text and returns no exit code. The pane runs
# `gate.sh --exec`, which runs the command with no pager and no terminal on stdin (PAGER and
# GIT_PAGER are cat, stdin is /dev/null), copies its output to a log, keeps a heartbeat
# (src/gatefile.sh: pid, start, counts, last line, exit, what it changed in the checkout) and
# records the result with lane.sh itself, so a caller that is interrupted loses nothing. The
# tab still prints `GATE <node> <run> EXIT=<n>`.
# Prints, for a finished run:
#   GATE PASS|FAIL <node> EXIT=<n> (<elapsed>, <n> ok, <n> FAIL, log: <path>)
#   GATE FAILED TESTS <node>: <names>                          (lines starting FAIL or not ok)
#   GATE CHECKOUT CHANGED <node>: <git status lines> | restore: git -C DIR checkout -- PATHS
# GATE STARTED <node> RUN=<id> (--detach); GATE TIMEOUT <node> RUN=<id> (exit 5: still running,
# wait again); GATE LOST <node> RUN=<id> (exit 4: its process is gone without an EXIT line).
# Exit codes: 0 a result (pass or fail), 1 error, 2 usage, 4 lost, 5 still running, 6 no such lane, gate or run.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
. "$HERE/src/common.sh"
# shellcheck source=src/gatefile.sh
. "$HERE/src/gatefile.sh"

USAGE="gate.sh [--wait | --collect | --detach] --lane L --node N [--pane PANE] [--repo DIR] [--timeout SECONDS]"
repo="$(pwd)" lane="" node="" pane="" timeout=1800 run="" mode=start detach=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) need_value "$1" $#; repo="$2"; shift 2 ;;
        --lane) need_value "$1" $#; lane="$2"; shift 2 ;;
        --node) need_value "$1" $#; node="$2"; shift 2 ;;
        --pane) need_value "$1" $#; pane="$2"; shift 2 ;;
        --timeout) need_value "$1" $#; timeout="$2"; shift 2 ;;
        --resume) need_value "$1" $#; mode="wait"; shift 2 ;;
        --run) need_value "$1" $#; run="$2"; shift 2 ;;
        --wait) mode="wait"; shift ;;
        --collect) mode=collect; shift ;;
        --exec) mode="exec"; shift ;;
        --detach) detach=1; shift ;;
        *) usage "$USAGE" ;;
    esac
done
[ -n "$lane" ] && [ -n "$node" ] || usage "$USAGE"
case "$timeout" in '' | *[!0-9]*) usage "$USAGE" ;; esac
[ "$mode" != start ] || [ -n "$pane" ] || usage "$USAGE"
[ "$mode" != exec ] || [ -n "$run" ] || usage "$USAGE"
require_tools jq yq git
repo="$(cd "$repo" 2>/dev/null && pwd)" || die "no such directory: $repo" 2
file="$(lane_file "$repo" "$lane")"
[ -f "$file" ] || die "NO LANE: $lane" 6
cmd="$(yq -r ".graph[\"$node\"].gate // \"\"" "$file")"
[ -n "$cmd" ] || die "NOT A GATE: $node in lane $lane" 6
gdir="$(gate_dir "$repo" "$lane")"
hbf="$gdir/$node.json" log="$gdir/$node.log"
at="--repo $(printf '%q' "$repo") --lane $lane --node $node"

hb_set() { # jq program, jq args...: rewrite the heartbeat
    local prog="$1" out
    shift
    out="$(jq -c "$@" "$prog" "$hbf")" || return 1
    printf '%s\n' "$out" >"$hbf.tmp" && mv "$hbf.tmp" "$hbf"
}

trimmed() { sed -E 's/^[[:space:]]+//'; }

# Record a finished run once: the node must still be running; returns 3 while it runs.
record_run() {
    local f code note changed st ran
    lock_in "$gdir"
    f="$(gate_facts "$hbf")" || { unlock; return 3; }
    [ "$(jq -r '.finished' <<<"$f")" = true ] || { unlock; return 3; }
    if [ "$(jq -r '.recorded // false' <<<"$f")" != true ]; then
        st="$(yq -r ".nodes[\"$node\"].status // \"\"" "$file")"
        if [ "$st" = running ]; then
            code="$(jq -r '.exit' <<<"$f")"
            ran="$(jq -r '.head // ""' <<<"$f")"
            changed="$(jq -r '.changed // [] | .[]' <<<"$f" | trimmed | paste -sd ',' - | sed 's/,/, /g')"
            note="${changed:+checkout changed by the gate: $changed}"
            if [ "$code" = 0 ]; then
                bash "$HERE/lane.sh" node --repo "$repo" --lane "$lane" --node "$node" --status "done" --result pass --exit 0 ${ran:+--head "$ran"} \
                    --ref "$log" ${note:+--note "$note"} >/dev/null || { unlock; return 1; }
            else
                bash "$HERE/lane.sh" node --repo "$repo" --lane "$lane" --node "$node" --status failed --result fail --exit "$code" \
                    --ref "$log" ${note:+--note "$note"} >/dev/null || { unlock; return 1; }
            fi
        fi
        hb_set '.recorded = true' || { unlock; return 1; }
    fi
    unlock
    return 0
}

print_result() { # facts JSON of a finished run
    local f="$1" code word names changed tracked dir
    code="$(jq -r '.exit' <<<"$f")" word=FAIL
    [ "$code" = 0 ] && word=PASS
    printf 'GATE %s %s EXIT=%s (%s, %s ok, %s FAIL, log: %s)\n' "$word" "$node" "$code" \
        "$(gate_dur "$(jq -r '.elapsed // 0' <<<"$f")")" "$(jq -r '.ok // 0' <<<"$f")" "$(jq -r '.fail // 0' <<<"$f")" "$(jq -r '.log // ""' <<<"$f")"
    names="$(jq -r '.failed // [] | .[:10] | join("; ")' <<<"$f")"
    [ -z "$names" ] || printf 'GATE FAILED TESTS %s: %s\n' "$node" "$names"
    changed="$(jq -r '.changed // [] | .[]' <<<"$f" | trimmed | paste -sd ',' - | sed 's/,/, /g')"
    if [ -n "$changed" ]; then
        dir="$(jq -r '.dir // ""' <<<"$f")"
        tracked="$(jq -r '.changed // [] | .[] | select(startswith("??") | not) | .[3:] | sub(".* -> "; "")' <<<"$f" | paste -sd ' ' -)"
        printf 'GATE CHECKOUT CHANGED %s: %s%s\n' "$node" "$changed" "${tracked:+ | restore: git -C $dir checkout -- $tracked}"
    fi
}

lost() { # facts
    printf 'GATE LOST %s RUN=%s\n' "$node" "$(jq -r '.run' <<<"$1")"
    echo "Its process $(jq -r '.pid' <<<"$1") is gone without an EXIT line. Read its tab (herdr pane read $(jq -r '.pane' <<<"$1") --source recent --lines 80), then gate.sh --collect $at if it shows one, else lane.sh node $at --status waiting to run it again."
    exit 4
}

wait_run() { # seconds
    local deadline f
    deadline=$(($(date +%s) + $1))
    while :; do
        f="$(gate_facts "$hbf")" || die "NO GATE RUN: no heartbeat for $node in lane $lane ($hbf); gate.sh --collect --pane PANE reads its tab" 6
        if [ "$(jq -r '.finished' <<<"$f")" = true ]; then
            record_run || die "could not record the result of $node"
            print_result "$(gate_facts "$hbf")"
            exit 0
        fi
        [ "$(jq -r '.alive' <<<"$f")" != false ] || lost "$f"
        if [ "$(date +%s)" -ge "$deadline" ]; then
            printf 'GATE TIMEOUT %s RUN=%s (%s, %s ok, %s FAIL)\n' "$node" "$(jq -r '.run' <<<"$f")" \
                "$(gate_dur "$(jq -r '.elapsed' <<<"$f")")" "$(jq -r '.ok' <<<"$f")" "$(jq -r '.fail' <<<"$f")"
            echo "Still running in its tab; it records its own result. Wait again with gate.sh --wait $at; do not start it a second time."
            exit 5
        fi
        sleep "$INTERVAL"
    done
}

# The EXIT line of a run on the pane's screen (the run id when known, else the last one).
tab_exit() { # pane, run id or ""
    local out text
    require_tools herdr
    out="$(herdr pane read "$1" --source recent-unwrapped --lines 400 2>/dev/null)" || return 1
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
        text="$(jq -r '((.result | objects) // {}) as $r | [$r.text, $r.content, $r.output] | map(strings) | .[0] // ""' <<<"$out")"
    else
        text="$out"
    fi
    printf '%s\n' "$text" | sed -nE "s/.*GATE $node ${2:-[0-9]+} EXIT=([0-9]+).*/\\1/p" | tail -1
}

case "$mode" in
exec)
    [ "$(jq -r '.run // ""' "$hbf" 2>/dev/null)" = "$run" ] || die "STALE RUN: $run is not the current run of $node in lane $lane" 6
    snap() { git status --porcelain=v1 --untracked-files=all 2>/dev/null | LC_ALL=C sort; }
    before="$(snap)"
    # shellcheck disable=SC2016  # $p and $d are jq variables
    hb_set '. + {pid: $p, dir: $d, head: $h}' --argjson p "$$" --arg d "$(pwd)" --arg h "$(git rev-parse HEAD 2>/dev/null)" || die "could not write $hbf"
    interrupted=0
    trap 'interrupted=1' INT TERM
    env PAGER=cat GIT_PAGER=cat MANPAGER=cat GIT_TERMINAL_PROMPT=0 DEBIAN_FRONTEND=noninteractive \
        bash -c "$cmd" </dev/null 2>&1 | tee -a "$log"
    code="${PIPESTATUS[0]}"
    trap - INT TERM
    [ "$interrupted" -eq 0 ] || [ "$code" -ne 0 ] || code=130
    after="$(snap)"
    changed="$(LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | jq -Rcs 'split("\n") | map(select(. != ""))')"
    # shellcheck disable=SC2016  # jq variables
    hb_set '. + $f + {finished: true, exit: $x, ended: $t, changed: $c, recorded: false}' \
        --argjson f "$(gate_log_facts "$log")" --argjson x "$code" --argjson t "$(date +%s)" --argjson c "$changed" ||
        die "could not write $hbf"
    printf 'GATE %s %s EXIT=%s\n' "$node" "$run" "$code"
    record_run || die "could not record the result of $node"
    print_result "$(gate_facts "$hbf")" ;;
start)
    require_tools herdr
    run="$(date +%s)$$"
    bash "$HERE/lane.sh" node --repo "$repo" --lane "$lane" --node "$node" --status running --note "run $run" >/dev/null || exit 1
    mkdir -p "$gdir" || die "could not create $gdir"
    : >"$log"
    jq -cn --arg l "$lane" --arg n "$node" --arg r "$run" --arg p "$pane" --arg log "$log" --argjson t "$(date +%s)" \
        '{lane: $l, node: $n, run: $r, pane: $p, pid: null, dir: "", log: $log, started: $t, finished: false,
          exit: null, ok: 0, fail: 0, failed: [], last: "", changed: [], recorded: false}' >"$hbf.tmp" && mv "$hbf.tmp" "$hbf"
    herdr pane run "$pane" "bash $(printf '%q' "$HERE/gate.sh") --exec --repo $(printf '%q' "$repo") --lane $lane --node $node --run $run" \
        >/dev/null 2>&1 || die "herdr pane run failed for pane $pane"
    if [ "$detach" -eq 1 ]; then
        printf 'GATE STARTED %s RUN=%s (log: %s)\n' "$node" "$run" "$log"
        echo "It records its own result. Block on it with gate.sh --wait $at [--timeout S]."
        exit 0
    fi
    wait_run "$timeout" ;;
wait)
    wait_run "$timeout" ;;
collect)
    if f="$(gate_facts "$hbf")"; then
        if [ "$(jq -r '.finished' <<<"$f")" = true ]; then
            record_run || die "could not record the result of $node"
            print_result "$(gate_facts "$hbf")"
            exit 0
        fi
        if [ "$(jq -r '.alive' <<<"$f")" != false ]; then
            printf 'GATE RUNNING %s RUN=%s (%s, %s ok, %s FAIL)\n' "$node" "$(jq -r '.run' <<<"$f")" \
                "$(gate_dur "$(jq -r '.elapsed' <<<"$f")")" "$(jq -r '.ok' <<<"$f")" "$(jq -r '.fail' <<<"$f")"
            exit 5
        fi
        [ -n "$pane" ] || pane="$(jq -r '.pane // ""' <<<"$f")"
        run="$(jq -r '.run // ""' <<<"$f")"
    else
        f=""
        run="$(yq -r '.history[]' "$file" | sed -nE "s/.* $node running( .*)? - run ([0-9]+)\$/\\2/p" | tail -1)"
    fi
    [ -n "$pane" ] || die "NO GATE RUN: no heartbeat for $node in lane $lane; pass --pane PANE to read its tab" 6
    code="$(tab_exit "$pane" "$run")"
    if [ -z "$code" ]; then
        [ -z "$f" ] || lost "$f"
        die "NO EXIT LINE: pane $pane shows no GATE $node ${run:-<run>} EXIT=<n> line" 6
    fi
    st="$(yq -r ".nodes[\"$node\"].status // \"\"" "$file")"
    [ "$st" = running ] || die "NOT RUNNING: $node in lane $lane is $st; nothing to record" 6
    if [ "$code" = 0 ]; then
        bash "$HERE/lane.sh" node --repo "$repo" --lane "$lane" --node "$node" --status "done" --result pass --exit 0 --note "read from pane $pane" >/dev/null || exit 1
        printf 'GATE PASS %s EXIT=0 (read from pane %s)\n' "$node" "$pane"
    else
        bash "$HERE/lane.sh" node --repo "$repo" --lane "$lane" --node "$node" --status failed --result fail --exit "$code" --note "read from pane $pane" >/dev/null || exit 1
        printf 'GATE FAIL %s EXIT=%s (read from pane %s)\n' "$node" "$code" "$pane"
    fi ;;
esac
