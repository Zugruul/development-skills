#!/usr/bin/env bash
# _lib.sh -- shared helpers for run-tests.sh's section-*.sh files.
# Sourced once by run-tests.sh, after it sets HERE/PLUGIN/FIX/fails/flaky
# and before any section-*.sh is sourced. Not runnable standalone: it
# mutates the caller's $fails/$flaky and reads $HERE, all defined by
# run-tests.sh.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.

check() { # name  expected-substring  actual-output
    if grep -qF -- "$2" <<<"$3"; then
        echo "ok   $1"
    else
        echo "FAIL $1 — expected to contain: $2"
        echo "     got: $(head -3 <<<"$3")"
        fails=$((fails + 1))
    fi
}

check_rc() { # name  expected-exit-code  actual-exit-code
    if [[ "$2" -eq "$3" ]]; then
        echo "ok   $1"
    else
        echo "FAIL $1 — expected exit $2, got $3"
        fails=$((fails + 1))
    fi
}

check_absent() { # name  forbidden-substring  actual-output
    if grep -qF -- "$2" <<<"$3"; then
        echo "FAIL $1 — must NOT contain: $2"
        fails=$((fails + 1))
    else
        echo "ok   $1"
    fi
}

# --- PreToolUse(Bash) hook stdin builders -------------------------------
# Wrap a command string as the {"tool_input":{"command":...}} JSON the
# guard-board-move / guard-pr-create hooks read on stdin. Defined here in
# _lib.sh (always sourced) rather than in one section file so that filtering
# the suite to a single guard section (dev#96 --section) still has them in
# scope -- otherwise the hook gets empty stdin and default-allows, turning
# real assertions into spurious passes/FAILs. hookjson() is the fast printf
# form (callers pre-escape any embedded quotes); hookjsonpy() routes through
# python's json so a command string with arbitrary quoting is encoded safely.
hookjson() { printf '{"tool_input":{"command":"%s"}}' "$1"; }
hookjsonpy() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"; }

# hookjson_named <tool_name> <input-key> <input-value> -- builds the general
# {"tool_name":..., "tool_input":{<key>:<value>}} shape guard-brain-access.sh
# reads (Read's file_path, Bash's command, or any other tool_name where the
# key/value are irrelevant filler). Routed through python's json like
# hookjsonpy() so arbitrary quoting is safe.
hookjson_named() { python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1], "tool_input":{sys.argv[2]:sys.argv[3]}}))' "$1" "$2" "$3"; }

# --- server-lifecycle helpers (SPEC 7.5) ---------------------------------
# Server-lifecycle sections (neural-view, ui-hub) bind a real TCP port. Under
# concurrent build-loop lanes, two runs picking the same fixed port race and
# whichever loses gets a spurious lifecycle failure blamed on its own diff.
# _rand_port() gives each lifecycle section its own per-run random port;
# lifecycle_start() retries a failed start ONCE on a fresh port and reports a
# pass-on-retry as a distinct FLAKY state, so genuine flakes stay visible
# instead of either failing innocent work or being silently swallowed.
_used_ports=()

# development-skills#97: the port-in-use check inside _rand_port() only ever
# sees THIS process's own picks (_used_ports is per-process) -- it has no
# way to know what some OTHER concurrently-running run-tests.sh already
# claimed. Two suites drawing from the same full 20000-39999 band can (and,
# rarely but repeatably under load, did) land on the identical port number.
# When that port then gets reused for a genuine neural-view server in one
# suite while the other suite's kill gate is still looking at it, the gate
# (which only ever asks "who holds MY configured port right now" -- correct
# in isolation, see section-lifecycle-retry.sh's cross-suite gate check)
# kills a completely unrelated process. Fix: slice the band into disjoint
# _PORT_SLICE_COUNT bands of _PORT_SLICE_WIDTH ports each and floor every
# draw by a band chosen from this PROCESS's own PID ($$, guaranteed unique
# among concurrently-running processes on one host) -- two suites now
# collide only if their PIDs happen to be congruent mod _PORT_SLICE_COUNT,
# not on every shared draw. A suite-scoped slice (rather than true
# cross-process bind-first allocation) is sufficient here: nothing but this
# same process ever reads _used_ports, and the port is handed to a spawned
# child (neural-view's "serve"), so there's no way to hold the socket open
# across the handoff anyway.
_PORT_SLICE_COUNT=200
_PORT_SLICE_WIDTH=100   # _PORT_SLICE_COUNT * _PORT_SLICE_WIDTH == 20000, the full band

# _port_base [pid] -- this suite's disjoint port-range floor. Pure function
# of pid (defaults to $$, this process's own PID); exposed separately from
# _rand_port so tests can probe the PID->band mapping with arbitrary pid
# values instead of depending on real spawned PIDs happening to differ.
_port_base() {
    local pid="${1:-$$}"
    printf '%s\n' $((20000 + (pid % _PORT_SLICE_COUNT) * _PORT_SLICE_WIDTH))
}

_rand_port() {
    local p tries=0 base
    base="$(_port_base "$$")"
    while :; do
        p=$((base + RANDOM % _PORT_SLICE_WIDTH))
        tries=$((tries + 1))
        case " ${_used_ports[*]-} " in
            *" $p "*) [[ $tries -lt 50 ]] && continue ;;
        esac
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
            _used_ports+=("$p")
            printf '%s\n' "$p"
            return
        fi
        [[ $tries -ge 50 ]] && { _used_ports+=("$p"); printf '%s\n' "$p"; return; }
    done
}

# lifecycle_start <check-name> <port-env-var-name> <command-string>
# Exports a fresh random port into <port-env-var-name>, then evals
# <command-string> (a single shell command, possibly with its own
# VAR=value prefixes) and expects its output to contain
# "RUNNING http://127.0.0.1:<port>". On failure, retries ONCE with a newly
# picked port. Leaves <port-env-var-name> exported to whichever port
# actually worked, so follow-up curl calls / checks in the same section can
# just keep referencing it.
lifecycle_start() {
    local name="$1" portvar="$2" cmdstr="$3"
    local attempt p out expect
    for attempt in 1 2; do
        p="$(_rand_port)"
        export "$portvar=$p"
        out="$(eval "$cmdstr" 2>&1)"
        expect="RUNNING http://127.0.0.1:$p"
        if grep -qF -- "$expect" <<<"$out"; then
            if [[ $attempt -eq 1 ]]; then
                echo "ok   $name"
            else
                echo "FLAKY $name (passed on retry)"
                flaky=$((flaky + 1))
            fi
            return 0
        fi
    done
    echo "FAIL $name — expected to contain: $expect"
    echo "     got: $(head -3 <<<"$out")"
    fails=$((fails + 1))
    return 1
}
