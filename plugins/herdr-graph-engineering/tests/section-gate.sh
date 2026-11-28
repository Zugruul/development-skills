#!/usr/bin/env bash
# section-gate.sh -- sourced by run-tests.sh; do not run standalone.
# Gate liveness: gate.sh runs the gate through `gate.sh --exec` in the pane, which writes a
# heartbeat (<lane folder>/gates/<lane>/<node>.json) and a log, records the result itself
# (so a caller that dies loses nothing), runs the command without a pager or a terminal on
# stdin, and notes what the gate changed in the checkout. status.sh and the panel show a
# running gate's elapsed time and ok/FAIL counts; drift.sh flags a gate that is gone, stalled
# or finished without a record; gate.sh --wait and --collect wait and record after the fact.
# The stub herdr runs the typed text for real (pane_exec), detached, like a pane's shell.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

T_TMP="$(mktemp -d)"
T_REPO="$T_TMP/repo"
git init -q -b main "$T_REPO"
printf 'a\n' >"$T_REPO/fixture.txt"
git -C "$T_REPO" add fixture.txt && git -C "$T_REPO" -c user.name=t -c user.email=t@t commit -q -m init
export XDG_CONFIG_HOME="$T_TMP/config"
FAKE="$T_TMP/fake.sh"
cat >"$FAKE" <<'EOF'
#!/usr/bin/env bash
# a stand-in test suite
case "$1" in
    pass) echo "ok   one"; echo "ok   two"; exit 0 ;;
    fail) echo "ok   one"; echo "FAIL two — expected x"; echo "not ok 3 three"; exit 1 ;;
    env) echo "PAGER=$PAGER GIT_PAGER=$GIT_PAGER"; if [ -t 0 ]; then echo stdin-tty; else echo stdin-not-tty; fi; exit 0 ;;
    chmod) chmod +x fixture.txt; echo "ok   mode"; exit 0 ;;
    hang) echo "ok   start"; sleep "$2"; exit 0 ;;
    spin) echo "ok   start"; bash -c 'while :; do :; done' spin-"$2"; exit 0 ;;
    churn) echo "ok   start"; while [ "$SECONDS" -lt "$2" ]; do bash -c 'i=0; while [ "$i" -lt 20000 ]; do i=$((i+1)); done'; done; exit 0 ;;
esac
EOF
# every command runs inside the checkout, as a gate tab does
gt() { local s="$1"; shift; (cd "$T_REPO" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$T_TMP" HERDR_ENV=1 NO_COLOR=1 HERDR_GRAPH_INTERVAL=0.2 bash "$PLUGIN/scripts/$s.sh" "$@"); }
printf '{"pane_exec":true}' >"$T_TMP/state.json"
: >"$T_TMP/calls.log"
T_DIR="$(git -C "$T_REPO" rev-parse --path-format=absolute --git-common-dir)/herdr-graph"
tlf() { yq -r "$1" "$T_DIR/$2.yaml"; }
hb() { jq -r "$1" "$T_DIR/gates/$2/tests.json"; }
tlane() { # lane, fake mode...
    local l="$1"
    shift
    gt lane new --repo "$T_REPO" --lane "$l" --pattern solo --idea x --gate "bash $FAKE $*" >/dev/null
    gt lane node --repo "$T_REPO" --lane "$l" --node impl --status "done" --result pass >/dev/null
}
# wait up to 10 s for a jq condition on a lane file
until_lane() { # lane, yq expression printing true
    local i=0
    while [ "$i" -lt 50 ] && [ "$(tlf "$2" "$1")" != true ]; do sleep 0.2; i=$((i + 1)); done
}

echo "== gate: the gate records itself, whatever happens to its caller =="
tlane alone pass
out="$(gt gate --repo "$T_REPO" --lane alone --node tests --pane w1:p2 --detach)"; rc=$?
check_rc "--detach returns at once" 0 "$rc"
check "it says the gate started, with its run id" "GATE STARTED tests RUN=" "$out"
check "the node is running" "running" "$(tlf '.nodes.tests.status' alone)"
until_lane alone '.nodes.tests.status == "done"'
check "with nobody waiting the gate recorded its own pass" "done pass 0" "$(tlf '[.nodes.tests.status, .nodes.tests.result, .nodes.tests.exit] | join(" ")' alone)"
check "the heartbeat says it finished and was recorded" "true 0 true" "$(hb '[.finished, .exit, .recorded] | map(tostring) | join(" ")' alone)"
check "with its counts" "2 0" "$(hb '"\(.ok) \(.fail)"' alone)"
check "the record points to the gate's log" "gates/alone/tests.log" "$(tlf '.nodes.tests.ref' alone)"
check "the marker line is still printed in the tab" "GATE tests " "$(cat "$T_TMP/pane-w1_p2.out")"
out="$(gt gate --repo "$T_REPO" --lane alone --node tests --wait)"
check "--wait on a finished gate prints its result" "GATE PASS tests EXIT=0" "$out"
check "and records nothing twice" "1" "$(tlf '[.history[] | select(test("tests done pass"))] | length' alone)"

echo "== gate: a failing gate names its failures =="
tlane red fail
out="$(gt gate --repo "$T_REPO" --lane red --node tests --pane w1:p3 --timeout 10)"
check "a failing gate reports its exit code" "GATE FAIL tests EXIT=1" "$out"
check "with its counts" "1 ok, 2 FAIL" "$out"
check "and the failing tests" "two — expected x" "$out"
check "the failure is recorded" "failed fail 1" "$(tlf '[.nodes.tests.status, .nodes.tests.result, .nodes.tests.exit] | join(" ")' red)"
check "the failing names are kept for a later comparison" "3 three" "$(hb '.failed | join("; ")' red)"

echo "== gate: no pager, no terminal on stdin =="
tlane quiet env
gt gate --repo "$T_REPO" --lane quiet --node tests --pane w1:p4 --timeout 10 >/dev/null
check "the gate runs with PAGER and GIT_PAGER set to cat" "PAGER=cat GIT_PAGER=cat" "$(cat "$T_DIR/gates/quiet/tests.log")"
check "and stdin is not a terminal" "stdin-not-tty" "$(cat "$T_DIR/gates/quiet/tests.log")"

echo "== gate: what the gate changed in the checkout =="
tlane mode chmod
out="$(gt gate --repo "$T_REPO" --lane mode --node tests --pane w1:p5 --timeout 10)"
check "the gate's result names the changed file" "GATE CHECKOUT CHANGED tests: M fixture.txt" "$out"
check "with the command that restores it" "git -C $T_REPO checkout -- fixture.txt" "$out"
check "the heartbeat keeps it" "M fixture.txt" "$(hb '.changed | join(" ")' mode)"
check "and the lane's record says so" "checkout changed by the gate: M fixture.txt" "$(tlf '.history[-1]' mode)"
git -C "$T_REPO" checkout -- fixture.txt

echo "== gate: a running gate shows that it is alive =="
tlane slow hang 30
gt gate --repo "$T_REPO" --lane slow --node tests --pane w1:p6 --detach >/dev/null
i=0; while [ "$i" -lt 50 ] && ! grep -q "ok   start" "$T_DIR/gates/slow/tests.log" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
node="$(gt status --json --repo "$T_REPO" | jq -c '.[] | select(.lane == "slow") | .nodes[] | select(.node == "tests")')"
check "status carries the gate's live facts" "1" "$(jq -r '.gate.ok' <<<"$node")"
check "its process is alive" "true" "$(jq -r '.gate.alive' <<<"$node")"
check "and a progress line" "running" "$(jq -r '.progress' <<<"$node")"
check "with the counts and the last output line" "1 ok · 0 FAIL · last: ok   start" "$(jq -r '.progress' <<<"$node")"
check "a live gate is still working" "working" "$(gt status --json --repo "$T_REPO" | jq -r '.[] | select(.lane == "slow") | .section')"
check "status --text shows it" "tests: running" "$(gt status --text --repo "$T_REPO")"
frame="$(cd "$T_REPO" && env -u HERDR_PANE_ID -u HERDR_TAB_ID PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$T_TMP" HERDR_ENV=1 NO_COLOR=1 bash "$PLUGIN/scripts/panel.sh" --frame --width 160)"
check "the panel shows the progress under the lane" "tests: running" "$frame"
out="$(gt gate --repo "$T_REPO" --lane slow --node tests --wait --timeout 1)"; rc=$?
check_rc "--wait gives up after its timeout with exit 5" 5 "$rc"
check "and says how to keep waiting" "GATE TIMEOUT tests" "$out"

echo "== gate: a gate whose output stopped =="
touch -t 202001010000 "$T_DIR/gates/slow/tests.log"
check "no output for longer than the limit needs the user" "needs" "$(gt status --json --repo "$T_REPO" | jq -r '.[] | select(.lane == "slow") | .section')"
check "it says how long it has been quiet" "tests: no gate output for" "$(gt status --json --repo "$T_REPO" | jq -r '.[] | select(.lane == "slow") | .attention | join(" ")')"
check "drift.sh flags it with what to look at" "DRIFT slow/tests gate-stalled: no output for" "$(gt drift --repo "$T_REPO")"
check "the limit is configurable" "working" "$(HERDR_GRAPH_GATE_STALL=99999999 gt status --json --repo "$T_REPO" | jq -r '.[] | select(.lane == "slow") | .section')"
check "drift.sh takes it too" "NO DRIFT" "$(gt drift --repo "$T_REPO" --gate-stall 99999999)"

echo "== gate: a gate whose process is gone =="
kill -9 "$(hb '.pid' slow)" 2>/dev/null
check "a gone gate needs the user" "tests: gate process $(hb '.pid' slow) is gone without an EXIT line" "$(gt status --json --repo "$T_REPO" | jq -r '.[] | select(.lane == "slow") | .attention | join(" ")')"
out="$(gt drift --repo "$T_REPO")"
check "drift.sh flags it" "DRIFT slow/tests gate-lost" "$out"
check "with the pane to read and the command to collect from it" "herdr pane read w1:p6" "$out"
out="$(gt gate --repo "$T_REPO" --lane slow --node tests --wait --timeout 5)"; rc=$?
check_rc "--wait on a gone gate stops with exit 4" 4 "$rc"
check "and says so" "GATE LOST tests" "$out"

echo "== gate: a gate that finished but was never recorded =="
tlane lost pass
gt lane node --repo "$T_REPO" --lane lost --node tests --status running --note "run 42" >/dev/null
mkdir -p "$T_DIR/gates/lost"
printf 'ok   one\n' >"$T_DIR/gates/lost/tests.log"
jq -cn --arg log "$T_DIR/gates/lost/tests.log" --arg dir "$T_REPO" \
    '{lane: "lost", node: "tests", run: "42", pane: "w1:p7", pid: 999999, dir: $dir, log: $log, started: 1, ended: 5,
      finished: true, exit: 0, ok: 1, fail: 0, failed: [], last: "ok   one", changed: [], recorded: false}' >"$T_DIR/gates/lost/tests.json"
check "status says it finished without a record" "tests finished EXIT=0 but was never recorded" "$(gt status --json --repo "$T_REPO" | jq -r '.[] | select(.lane == "lost") | .attention | join(" ")')"
check "drift.sh points to --collect" "DRIFT lost/tests gate-unrecorded: finished EXIT=0, never recorded | gate.sh --collect --repo $T_REPO --lane lost --node tests" "$(gt drift --repo "$T_REPO")"
out="$(gt gate --repo "$T_REPO" --lane lost --node tests --collect)"
check "--collect records it" "GATE PASS tests EXIT=0" "$out"
check "the lane has the result" "done pass" "$(tlf '[.nodes.tests.status, .nodes.tests.result] | join(" ")' lost)"
check_absent "and drift.sh is quiet about it" "lost/tests" "$(gt drift --repo "$T_REPO")"

echo "== gate: collecting from the tab when there is no heartbeat =="
tlane old pass
gt lane node --repo "$T_REPO" --lane old --node tests --status running --note "run 7" >/dev/null
printf '{"pane_exec":true,"panes":{"w1:p8":{"lines":["GATE tests 7 EXIT=2"]}}}' >"$T_TMP/state.json"
out="$(gt gate --repo "$T_REPO" --lane old --node tests --collect 2>&1)"; rc=$?
check_rc "without a heartbeat or a pane there is nothing to read" 6 "$rc"
out="$(gt gate --repo "$T_REPO" --lane old --node tests --collect --pane w1:p8)"
check "--collect --pane reads the EXIT line from the tab" "GATE FAIL tests EXIT=2" "$out"
check "and records it" "failed fail 2" "$(tlf '[.nodes.tests.status, .nodes.tests.result, .nodes.tests.exit] | join(" ")' old)"

echo "== gate: a silent step that uses the CPU is not stalled =="
# the CPU is used by children of the gate: one long one (a compiler), or many short ones
for mode in spin churn; do
    tlane "$mode" "$mode" 120
    gt gate --repo "$T_REPO" --lane "$mode" --node tests --pane "w2:$mode" --detach >/dev/null
    i=0; while [ "$i" -lt 50 ] && ! grep -q "ok   start" "$T_DIR/gates/$mode/tests.log" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
    touch -t 202001010000 "$T_DIR/gates/$mode/tests.log"
    check "$mode: silent but busy is still working" "working" "$(gt status --json --repo "$T_REPO" | jq -r ".[] | select(.lane == \"$mode\") | .section")"
    check_absent "$mode: drift.sh does not call it stalled" "$mode/tests gate-stalled" "$(gt drift --repo "$T_REPO")"
    check "$mode: the progress line says why it is quiet" "using the CPU" "$(gt status --json --repo "$T_REPO" | jq -r ".[] | select(.lane == \"$mode\") | .nodes[] | select(.node == \"tests\") | .progress")"
    pid="$(hb .pid "$mode")"
    # stop the gate's whole tree, the busy children first
    tree_kill() { local c; for c in $(pgrep -P "$1"); do tree_kill "$c"; done; kill -9 "$1" 2>/dev/null; }
    tree_kill "$pid"
done
unset -f tree_kill

pkill -f "$FAKE hang" 2>/dev/null
rm -rf "$T_TMP"
unset XDG_CONFIG_HOME
