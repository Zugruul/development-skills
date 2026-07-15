#!/usr/bin/env bash
# run-tests.sh -- runs the plugins/peer-review test suite.
# Sets HERE/PLUGIN, sources _lib.sh (check/check_rc/check_absent), then
# sources every section-*.sh file. Exits nonzero if any check failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # PLUGIN is used by the section-*.sh files
PLUGIN="$(cd "$HERE/.." && pwd)"
fails=0

# shellcheck source=plugins/peer-review/tests/_lib.sh
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
