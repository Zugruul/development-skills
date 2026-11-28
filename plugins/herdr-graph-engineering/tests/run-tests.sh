#!/usr/bin/env bash
# run-tests.sh -- runs the plugins/herdr-graph-engineering test suite.
# Sets HERE/PLUGIN/FIX, sources _lib.sh (check/check_rc/check_absent), then
# sources every section-*.sh file. Exits nonzero if any check failed.
# Hermetic: a stub `herdr` on PATH stands in for the real one, so the suite
# never touches a live Herdr session and passes where herdr is not installed.
# The suite reads nothing outside plugins/herdr-graph-engineering.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # PLUGIN is used by the section-*.sh files
PLUGIN="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC2034  # FIX is used by the section-*.sh files
FIX="$HERE/fixtures"
fails=0
# Plugin state (the panel-action pane records) never reaches the real home folder.
TEST_STATE="$(mktemp -d)"
export XDG_STATE_HOME="$TEST_STATE"

# no call, from any section, may reach a real herdr: the stub is first on PATH
export PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$TEST_STATE/herdr-stub"
mkdir -p "$HERDR_STUB_DIR"
unset HERDR_SOCKET_PATH

# shellcheck source=plugins/herdr-graph-engineering/tests/_lib.sh
source "$HERE/_lib.sh"

# each section gets its own state folder: lane.sh keeps a registry of repositories there
for section in "$HERE"/section-*.sh; do
    name="${section##*/}"
    export XDG_STATE_HOME="$TEST_STATE/${name%.sh}"
    # shellcheck source=/dev/null
    source "$section"
done

rm -rf "$TEST_STATE"
echo "---"
if [[ "$fails" -eq 0 ]]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILURE(S)"
    exit 1
fi
