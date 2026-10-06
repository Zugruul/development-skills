#!/usr/bin/env bash
# section-remote-command.sh -- sourced by run-tests.sh; do not run standalone.
# Exercises the on-machine `remote-compute` command (remote-compute-remote.sh)
# locally against a fake ~/.remote-compute layout: the same files dispatch
# writes (jobs/<id>/{job.log,pid,exitcode}, caps/<bundle>/capability.yaml).
# No ssh involved -- this is the bash that runs ON the compute machine.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/remote-compute/tests/run-tests.sh" >&2; exit 2; }
echo "== on-machine remote-compute command =="

RCMD="$PLUGIN/scripts/remote-capabilities/_shared/remote-compute-remote.sh"
RT="$(mktemp -d)"
RROOT="$RT/.remote-compute"
mkdir -p "$RROOT/jobs/done1" "$RROOT/jobs/fail1" "$RROOT/jobs/_caps" "$RROOT/caps/demo" "$RROOT/tools"
cp "$PLUGIN/scripts/remote-capabilities/_shared/compute-top.py" "$RROOT/tools/"
printf 'hello from done1\nline two\n' > "$RROOT/jobs/done1/job.log"; echo 4242 > "$RROOT/jobs/done1/pid"; echo 0 > "$RROOT/jobs/done1/exitcode"
printf 'boom\n' > "$RROOT/jobs/fail1/job.log"; echo 4243 > "$RROOT/jobs/fail1/pid"; echo 2 > "$RROOT/jobs/fail1/exitcode"
printf 'name: demo\ndescription: a demo bundle\njobs: {}\n' > "$RROOT/caps/demo/capability.yaml"
mkdir -p "$RROOT/caps/folded"
printf 'name: folded\ndescription: >-\n  first folded line\n  second folded line\njobs: {}\n' > "$RROOT/caps/folded/capability.yaml"
# a genuinely running job: a background sleep whose pid is recorded like dispatch does
mkdir -p "$RROOT/jobs/run1"
bash -c 'sleep 30' >/dev/null 2>&1 &
RPID=$!; disown 2>/dev/null; echo "$RPID" > "$RROOT/jobs/run1/pid"; : > "$RROOT/jobs/run1/job.log"

run_rcmd() { REMOTE_COMPUTE_ROOT="$RROOT" bash "$RCMD" "$@"; }

out="$(bash -n "$RCMD" 2>&1)"; check_rc "remote command: bash -n" 0 "$?"
out="$(run_rcmd help 2>&1)"; check "help: lists top" "top" "$out"; check "help: lists cancel" "cancel" "$out"
out="$(run_rcmd version 2>&1)"; check "version prints" "on-machine command" "$out"
out="$(run_rcmd bogus 2>&1)"; rc=$?; check_rc "unknown verb: exit 2" 2 "$rc"; check "unknown verb: says so" "unknown verb" "$out"
out="$(run_rcmd paths 2>&1)"; check "paths: root" "root:   $RROOT" "$out"; check "paths: bin" ".local/bin" "$out"
out="$(run_rcmd identity 2>&1)"; rc=$?; check_rc "identity: unstamped exit 1" 1 "$rc"; check "identity: unstamped says so" "no identity file" "$out"
echo gpubox > "$RROOT/.identity"
out="$(run_rcmd identity 2>&1)"; rc=$?; check_rc "identity: stamped exit 0" 0 "$rc"; check "identity: prints the nick" "gpubox" "$out"
out="$(run_rcmd paths 2>&1)"; check "paths: shows identity" "identity: gpubox" "$out"

out="$(run_rcmd running 2>&1)"
check "running: lists the live job" "run1" "$out"
check_absent "running: not the finished one" "done1" "$out"
check_absent "running: payload dirs are not jobs" "_caps" "$out"

out="$(run_rcmd status done1 2>&1)"
check "status: state done" "state:     done" "$out"
check "status: exit 0" "exit:      0" "$out"
check "status: log size" "bytes" "$out"
out="$(run_rcmd status fail1 2>&1)"; check "status: failed state" "state:     failed" "$out"
out="$(run_rcmd status run1 2>&1)"; check "status: running state" "state:     running" "$out"; check "status: pid alive" "alive: yes" "$out"
out="$(run_rcmd status nosuch 2>&1)"; rc=$?; check_rc "status: unknown job exit 2" 2 "$rc"
out="$(run_rcmd status ../etc 2>&1)"; rc=$?; check_rc "status: path-looking id refused" 2 "$rc"

out="$(run_rcmd log done1 2>&1)"; check "log: prints the tail" "line two" "$out"

out="$(run_rcmd jobs 2>&1)"; rc=$?
check_rc "jobs: dashboard --once exit 0" 0 "$rc"
check "jobs: table has the running job" "run1" "$out"
check "jobs: counts" "1 running" "$out"

out="$(run_rcmd caps 2>&1)"; check "caps: name + description" "demo" "$out"; check "caps: description" "a demo bundle" "$out"
check "caps: folded block description resolved" "first folded line second folded line" "$out"
check_absent "caps: no raw block indicator" ">-" "$out"

out="$(run_rcmd cancel done1 --yes 2>&1)"; rc=$?; check_rc "cancel: finished job refused" 2 "$rc"
out="$(run_rcmd cancel run1 --yes 2>&1)"; rc=$?
check_rc "cancel: exit 0" 0 "$rc"
check "cancel: reports" "cancelled run1" "$out"
check "cancel: exitcode written" "143" "$(cat "$RROOT/jobs/run1/exitcode")"
check "cancel: log annotated" "cancelled by" "$(cat "$RROOT/jobs/run1/job.log")"
sleep 0.3
if kill -0 "$RPID" 2>/dev/null; then echo "FAIL cancel: process still alive"; fails=$((fails + 1)); kill "$RPID" 2>/dev/null; else echo "ok   cancel: process gone"; fi
out="$(run_rcmd running 2>&1)"; check "running after cancel: nothing" "(nothing running)" "$out"

rm -rf "$RT"
