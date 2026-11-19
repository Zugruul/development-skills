#!/usr/bin/env bash
# run-tests.sh -- runs the plugins/herdr test suite.
# Sets HERE/PLUGIN/FIX, sources _lib.sh (check/check_rc/check_absent), then
# sources every section-*.sh file. Exits nonzero if any check failed.
# Hermetic: a stub `herdr` on PATH stands in for the real one, so the suite
# never touches a live Herdr session and passes where herdr is not installed.
# This plugin is standalone: the suite reads nothing outside plugins/herdr.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # PLUGIN is used by the section-*.sh files
PLUGIN="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC2034  # FIX is used by the section-*.sh files
FIX="$HERE/fixtures"
fails=0

# shellcheck source=plugins/herdr/tests/_lib.sh
source "$HERE/_lib.sh"

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
