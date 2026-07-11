#!/usr/bin/env bash
# section-gh-failures-corpus.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# Issue #91: fixtures for error-text classifiers are circular when authored
# alongside the detector they test (#77 shipped a detector blind to real
# gh's "unknown owner type"; #90 hotfixed it after live validation). This
# meta-check keeps tests/fixtures/gh-failures/ honest: every corpus entry
# must carry a provenance header (so nobody can silently add an invented
# string), and every corpus entry must actually be sourced by some fixture
# (a corpus nobody reads is dead weight, not evidence).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== gh-failures corpus (#91): provenance headers + no dead entries =="

_GHF="$FIX/gh-failures"

if [[ ! -d "$_GHF" ]]; then
    echo "FAIL gh-failures corpus directory missing: $_GHF"
    fails=$((fails + 1))
else
    _ghf_count=0
    for f in "$_GHF"/*; do
        [[ -f "$f" ]] || continue
        bn="$(basename "$f")"
        [[ "$bn" == "README.md" ]] && continue
        _ghf_count=$((_ghf_count + 1))

        # (1) provenance header: file must open with a '#' comment line...
        first_line="$(head -1 "$f")"
        if [[ "$first_line" == \#* ]]; then
            echo "ok   $bn: opens with a provenance header"
        else
            echo "FAIL $bn: missing provenance header (first line must start with '#')"
            fails=$((fails + 1))
        fi
        # ...and a non-empty payload must follow the header/payload blank-line
        # separator (the convention every fixture's awk 'f{print} /^$/{f=1}'
        # extraction relies on).
        payload="$(awk 'f{print} /^$/{f=1}' "$f")"
        if [[ -n "$payload" ]]; then
            echo "ok   $bn: has a non-empty payload after the header"
        else
            echo "FAIL $bn: no payload after the provenance header (missing blank-line separator, or header-only file)"
            fails=$((fails + 1))
        fi

        # (2) no dead corpus entries: every file must be named by at least
        # one section-*.sh fixture (this file's own prose never names a
        # specific corpus filename, so it can't produce a false match here).
        if grep -rl -F "$bn" "$HERE"/section-*.sh >/dev/null 2>&1; then
            echo "ok   $bn: referenced by at least one fixture"
        else
            echo "FAIL $bn: dead corpus entry -- not referenced by any section-*.sh fixture"
            fails=$((fails + 1))
        fi
    done
    if [[ "$_ghf_count" -eq 0 ]]; then
        echo "FAIL gh-failures corpus is empty -- no captured gh-failure fixtures found"
        fails=$((fails + 1))
    else
        echo "ok   gh-failures corpus has $_ghf_count entries"
    fi
fi

echo "== gh-failures corpus (#91): README documents the capture practice =="
_GHF_README="$(cat "$_GHF/README.md" 2>/dev/null)"
check "gh-failures README documents capturing raw bytes live" "capture" "$_GHF_README"
check "gh-failures README documents the provenance-header requirement" "provenance" "$_GHF_README"

echo "== plugin README references the gh-failures corpus (testing note) =="
check "plugin README documents the gh-failures corpus" "gh-failures" "$(cat "$PLUGIN/README.md" 2>/dev/null)"
