#!/usr/bin/env bash
# run-tests.sh -- runs the plugins/remote-compute test suite.
# Sets HERE/PLUGIN/FIX, sources _lib.sh (check/check_rc/check_absent), then
# sources every section-*.sh file. Exits nonzero if any check failed.
# The suite may reach INTO plugins/spec-workflow (config.py, validate-config.py,
# fixtures, snippet-lint.py) -- that mirrors the plugin's own declared
# dependency direction (remote-compute requires spec-workflow), never the
# reverse: spec-workflow's suite must keep passing with this plugin deleted.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # PLUGIN is used by the section-*.sh files
PLUGIN="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC2034  # FIX is used by the section-*.sh files
FIX="$HERE/fixtures"
# shellcheck disable=SC2034  # SW (the declared spec-workflow dependency) is used by the section-*.sh files
SW="$(cd "$PLUGIN/../spec-workflow" && pwd)"
fails=0

# shellcheck source=plugins/remote-compute/tests/_lib.sh
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
