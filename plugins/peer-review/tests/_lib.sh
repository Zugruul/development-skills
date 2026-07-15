#!/usr/bin/env bash
# _lib.sh -- shared helpers for run-tests.sh's section-*.sh files.
# Sourced once by run-tests.sh, after it sets HERE/PLUGIN/fails and before
# any section-*.sh is sourced. Not runnable standalone.

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
