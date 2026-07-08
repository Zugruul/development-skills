#!/usr/bin/env bash
# run-tests.sh — hermetic tests for the spec-workflow plugin (no gh/network needed).
# Used by CI and runnable locally: bash plugins/spec-workflow/tests/run-tests.sh
#
# Thin runner: defines shared state, sources _lib.sh for the shared check*/
# lifecycle_start helpers, then sources each per-area section-*.sh in a fixed
# order. Splitting the old monolith into per-area files lets concurrent build
# lanes add tests to disjoint files instead of all appending to one file
# (guaranteed rebase conflict on every merge). See tests/README.md (if
# present) or the plugin README's test-layout note for how to add a new
# section file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # PLUGIN/FIX are used by the section-*.sh files
# sourced below via a variable path, which defeats shellcheck's static
# cross-file analysis of "source $f" in a loop.
PLUGIN="$(dirname "$HERE")"
# shellcheck disable=SC2034
FIX="$HERE/fixtures"
fails=0
flaky=0

# shellcheck source=plugins/spec-workflow/tests/_lib.sh
source "$HERE/_lib.sh"

# Sections are mostly independent (each mints/tears down its own temp dirs
# and ports), EXCEPT one documented pair: section-ui-hub.sh creates the
# _hubtmp temp dir and section-neural-view-lifecycle.sh tears it down (see
# the rm -rf there), so ui-hub MUST precede neural-view-lifecycle below.
# This array's order is otherwise just the original file's top-to-bottom
# order, but that one pair is load-bearing -- don't reorder it blindly.
SECTIONS=(
    section-syntax.sh
    section-config.sh
    section-next-similar.sh
    section-preflight.sh
    section-ui-hub.sh
    section-neural-view-template.sh
    section-neural-view-lifecycle.sh
    section-neural-view-projects.sh
    section-neural-view-sessions.sh
    section-lifecycle-retry.sh
    section-gate-core.sh
    section-gate-fingerprint.sh
    section-gate-lessons.sh
    section-session-init.sh
    section-board-bug-add.sh
    section-identity.sh
    section-merge-mode.sh
    section-concurrency.sh
    section-brain.sh
    section-feedback.sh
    section-telemetry.sh
    section-find-task.sh
    section-pagination.sh
    section-skill-contracts.sh
    section-sync-configs.sh
)

if [[ ${#SECTIONS[@]} -eq 0 ]]; then
    echo "FATAL: no section files registered in run-tests.sh's SECTIONS array" >&2
    exit 1
fi

for s in "${SECTIONS[@]}"; do
    f="$HERE/$s"
    if [[ ! -f "$f" ]]; then
        echo "FATAL: missing section file: $s (registered in run-tests.sh but not found on disk)" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$f"
done

echo
if [[ $flaky -gt 0 ]]; then echo "$flaky lifecycle check(s) FLAKY (passed on retry)"; fi
if [[ $fails -gt 0 ]]; then echo "$fails test(s) FAILED"; exit 1; fi
echo "all tests passed"
