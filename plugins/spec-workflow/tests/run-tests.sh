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

# --- section filter (dev#96) ---------------------------------------------
# `--section <name>` restricts the run to sections whose base-name (the file
# name minus the `section-` prefix and `.sh` suffix) CONTAINS <name> as a
# substring. Repeatable and comma-separated: `--section board-queue`,
# `--section a,b`, and `--section a --section b` all work; the union runs in
# the registered SECTIONS order below (so the load-bearing ui-hub ->
# neural-view-lifecycle teardown pairing is preserved whenever both halves
# are selected — filtering to only ONE half is allowed but then that pair's
# create/teardown is a harmless no-op, not a failure). The SPEC_TESTS_SECTION
# env var is an equivalent filter source (comma-separated); it exists so
# gate.sh can DETECT a filtered invocation and refuse to record a pass for it
# — the recorded gate pass must always be a full-suite run (see gate.sh).
# With no filter at all, the run is byte-for-byte identical to before. An
# explicit filter that resolves to no non-empty terms (e.g. `--section=`)
# falls through to the no-match error below, never a crash.
_filters=()
_filter_requested=0
# _add_filters SPLITS $1 on commas and appends each NON-EMPTY term to
# _filters. Empty terms are ignored (an empty substring would match every
# section); skipping them here — rather than expanding a possibly-empty array
# with `"${arr[@]}"` — also sidesteps bash 3.2's set -u "unbound variable"
# error on an empty array. `set -f` around the split keeps a stray `*` in a
# term from glob-expanding against the cwd.
_add_filters() {
    local _t IFS=','
    set -f
    for _t in $1; do [[ -n "$_t" ]] && _filters+=("$_t"); done
    set +f
}
if [[ -n "${SPEC_TESTS_SECTION:-}" ]]; then
    _add_filters "$SPEC_TESTS_SECTION"; _filter_requested=1
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        --section)
            shift
            [[ $# -gt 0 ]] || { echo "run-tests.sh: --section requires a value" >&2; exit 2; }
            _add_filters "$1"; _filter_requested=1; shift ;;
        --section=*)
            _add_filters "${1#--section=}"; _filter_requested=1; shift ;;
        -h|--help)
            echo "usage: run-tests.sh [--section <name>[,<name>...]]..."
            echo "  --section <name>  run only sections whose base-name contains <name>"
            echo "                    (repeatable and/or comma-separated; substring match)"
            echo "  no --section      run the full suite (also honors \$SPEC_TESTS_SECTION)"
            exit 0 ;;
        *)
            echo "run-tests.sh: unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

# Sections are mostly independent (each mints/tears down its own temp dirs
# and ports), EXCEPT one documented pair: section-ui-hub.sh creates the
# _hubtmp temp dir and section-neural-view-lifecycle.sh tears it down (see
# the rm -rf there), so ui-hub MUST precede neural-view-lifecycle below.
# This array's order is otherwise just the original file's top-to-bottom
# order, but that one pair is load-bearing -- don't reorder it blindly.
SECTIONS=(
    section-plugin-root.sh
    section-syntax.sh
    section-snippet-lint.sh
    section-config.sh
    section-schema-lint.sh
    section-work-mode.sh
    section-next-similar.sh
    section-preflight.sh
    section-ui-hub.sh
    section-neural-view-template.sh
    section-neural-view-lifecycle.sh
    section-neural-view-rescan.sh
    section-neural-view-projects.sh
    section-neural-view-sessions.sh
    section-neural-view-render-body.sh
    section-lifecycle-retry.sh
    section-gate-core.sh
    section-guard-brain-access.sh
    section-gate-fingerprint.sh
    section-gate-preflight.sh
    section-comment-steering.sh
    section-red-first-preflight.sh
    section-gate-lessons.sh
    section-session-init.sh
    section-board-bug-add.sh
    section-board-queue.sh
    section-board-cache.sh
    section-identity.sh
    section-merge-mode.sh
    section-concurrency.sh
    section-brain.sh
    section-brain-index.sh
    section-brain-hybrid-recall.sh
    section-brain-events.sh
    section-brain-outcome.sh
    section-brain-outcome-ranking.sh
    section-brain-shrink-guard.sh
    section-entity-index.sh
    section-neural-view-entities.sh
    section-feedback.sh
    section-telemetry.sh
    section-find-task.sh
    section-pagination.sh
    section-skill-contracts.sh
    section-capability-language.sh
    section-argument-semantics.sh
    section-codex-plugin-json.sh
    section-codex-marketplace.sh
    section-codex-skill-lint.sh
    section-codex-e0-smoke.sh
    section-changelog.sh
    section-sync-configs.sh
    section-guard-pr-create.sh
    section-board-audit.sh
    section-board-labels.sh
    section-diff-symbols.sh
    section-gh-failures-corpus.sh
    section-runner-filter.sh
    section-section-guard.sh
    section-local-state-manifest.sh
    section-gitignore-sync.sh
    section-setup-project-gitignore.sh
    section-repo-hygiene.sh
    section-agents-claude.sh
    section-codex-parity-walkthrough.sh
)

if [[ ${#SECTIONS[@]} -eq 0 ]]; then
    echo "FATAL: no section files registered in run-tests.sh's SECTIONS array" >&2
    exit 1
fi

# Apply the --section filter (dev#96). No filter requested -> run every
# section, in the registered order, exactly as before. A requested filter
# that resolves to no non-empty terms (e.g. `--section=`) matches nothing and
# lands in the no-match error below rather than silently running the suite.
if [[ "$_filter_requested" -eq 0 ]]; then
    SELECTED=("${SECTIONS[@]}")
else
    SELECTED=()
    if [[ ${#_filters[@]} -gt 0 ]]; then
        for s in "${SECTIONS[@]}"; do
            _name="${s#section-}"; _name="${_name%.sh}"
            for term in "${_filters[@]}"; do
                case "$_name" in
                    *"$term"*) SELECTED+=("$s"); break ;;
                esac
            done
        done
    fi
    if [[ ${#SELECTED[@]} -eq 0 ]]; then
        echo "run-tests.sh: no section matched: ${_filters[*]-}" >&2
        echo "available sections:" >&2
        for s in "${SECTIONS[@]}"; do _n="${s#section-}"; echo "  ${_n%.sh}" >&2; done
        exit 2
    fi
fi

for s in "${SELECTED[@]}"; do
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
