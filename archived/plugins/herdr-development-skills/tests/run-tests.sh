#!/usr/bin/env bash
# run-tests.sh -- runs the plugins/herdr-development-skills test suite.
# Sets HERE/PLUGIN, sources _lib.sh (check/check_rc/check_absent), then
# sources every section-*.sh file. Exits nonzero if any check failed.
# Hermetic: a private HOME and throwaway repositories; no Herdr, no network.
# The suite may reach INTO plugins/herdr and plugins/spec-workflow (their
# skills, config loader and fixtures) -- that mirrors this plugin's declared
# dependency direction (it integrates them), never the reverse: their suites
# must keep passing with this plugin deleted.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # PLUGIN is used by the section-*.sh files
PLUGIN="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC2034  # PLUGINS (the marketplace's plugins directory) is used by the section-*.sh files
PLUGINS="$(cd "$PLUGIN/.." && pwd)"
fails=0

# shellcheck source=plugins/herdr-development-skills/tests/_lib.sh
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
