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

# --- server-lifecycle helpers (SPEC 7.5) ---------------------------------
# Server-lifecycle sections (neural-view, ui-hub) bind a real TCP port. Under
# concurrent build-loop lanes, two runs picking the same fixed port race and
# whichever loses gets a spurious lifecycle failure blamed on its own diff.
# _rand_port() gives each lifecycle section its own per-run random port;
# lifecycle_start() retries a failed start ONCE on a fresh port and reports a
# pass-on-retry as a distinct FLAKY state, so genuine flakes stay visible
# instead of either failing innocent work or being silently swallowed.
_used_ports=()

_rand_port() {
    local p tries=0
    while :; do
        p=$((20000 + RANDOM % 20000))
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
