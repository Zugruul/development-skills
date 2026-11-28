#!/usr/bin/env bash
# run-tests.sh -- tests of the repository's own scripts: install-skills.sh and
# .github/scripts/check-marketplaces.sh. Hermetic: temporary folders stand in for the
# project, the home folder and the client config folders; nothing real is touched.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # REPO is used by the section-*.sh files
REPO="$(cd "$HERE/../.." && pwd)"
fails=0

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

for section in "$HERE"/section-*.sh; do
    # shellcheck source=/dev/null
    source "$section"
done

echo "---"
if [[ "$fails" -eq 0 ]]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILURE(S)"
    exit 1
fi
