#!/usr/bin/env bash
# section-codex-e0-smoke.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# CDX-007 -- the Epic-0 EXIT-CONDITION test. E0's whole point was making the
# spec-workflow plugin installable and usable under Codex (not just Claude
# Code); this is the concrete end-to-end proof.
#
# HERMETIC TIER (this section): a real `codex plugin` CLI roundtrip against an
# ISOLATED CODEX_HOME (a throwaway temp dir -- NEVER the developer's real
# ~/.codex) that:
#   1. adds this repo as a local Codex marketplace (the CDX-004 manifest),
#   2. confirms both shipped plugins enumerate as AVAILABLE,
#   3. installs spec-workflow and confirms its changelog-generate skill +
#      backing script land in the install cache,
#   4. confirms CDX-002's relative `../../scripts/...` SKILL.md ref resolves
#      inside that installed-elsewhere layout,
#   5. runs the backing script standalone from a SEPARATE fresh consumer git
#      repo and asserts deterministic, correctly-grouped output.
# No model reasoning is involved -- it proves install + discovery + standalone
# runnability without any API call, so it is always-green and CI-safe. When
# `codex` is unavailable it SKIPs with a visible note.
#
# MODEL-DRIVEN TIER (NOT run here): the full "an LLM reads the skill and
# decides to invoke it via natural language" smoke is a real `codex exec`
# model call (real cost, real auth, non-deterministic), so it lives in the
# standalone manual script scripts/e0-smoke-manual.sh. This section only
# asserts that script exists and documents why it is not automated.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== codex-e0-smoke =="

REPO="$(cd "$PLUGIN/../.." && pwd)"
MANUAL="$REPO/plugins/spec-workflow/scripts/e0-smoke-manual.sh"

# --- model-driven tier evidence script (documented, not executed here) -----
if [[ ! -f "$MANUAL" ]]; then
    check "manual-tier smoke script exists at scripts/e0-smoke-manual.sh" "EXISTS" "MISSING"
else
    check "manual-tier smoke script exists at scripts/e0-smoke-manual.sh" "EXISTS" "EXISTS"
    manual_src="$(cat "$MANUAL")"
    check "manual-tier script drives the model via 'codex exec'" "codex exec" "$manual_src"
    check "manual-tier script documents it is NOT automated (real model call)" "not automated" "$manual_src"
    check "manual-tier script isolates CODEX_HOME (no real ~/.codex mutation)" "CODEX_HOME" "$manual_src"
fi

# --- hermetic Codex CLI roundtrip ------------------------------------------
if ! command -v codex >/dev/null 2>&1; then
    echo "SKIP codex E0 roundtrip — codex CLI unavailable"
else
    # Snapshot the developer's REAL config (mtime+size) so we can prove the
    # isolated-CODEX_HOME roundtrip never touched it. Absent on a fresh
    # machine -> "NONE", which must equal "NONE" after.
    REAL_CFG="$HOME/.codex/config.toml"
    cfg_before="$(stat -f '%m %z' "$REAL_CFG" 2>/dev/null || echo NONE)"

    CH="$(mktemp -d)"
    export CODEX_HOME="$CH/home"
    mkdir -p "$CODEX_HOME"

    # Separate fresh consumer repo -- NOT this repo. A seed root commit (which
    # `from..to` excludes as the FROM boundary) plus a feat and a fix, so the
    # changelog output is deterministic and exercises grouping + PR-ref keep.
    CONSROOT="$(mktemp -d)"
    CONS="$CONSROOT/consumer"
    mkdir -p "$CONS"
    (
        cd "$CONS" || exit 1
        git init -q
        git config user.email e0@smoke.test
        git config user.name "E0 Smoke"
        git config commit.gpgsign false
        : > seed.txt && git add seed.txt && git commit -qm "chore: seed consumer repo"
        echo alpha > alpha.txt && git add alpha.txt && git commit -qm "feat: add alpha feature (#1)"
        echo beta > beta.txt && git add beta.txt && git commit -qm "fix: correct beta bug (#2)"
    )

    add_out="$(codex plugin marketplace add "$REPO" --json 2>&1)"; add_rc=$?
    check_rc "marketplace add exits 0" 0 "$add_rc"
    check "marketplace add registers 'development-skills'" '"marketplaceName": "development-skills"' "$add_out"

    avail_out="$(codex plugin list --marketplace development-skills --available --json 2>&1)"; avail_rc=$?
    check_rc "plugin list --available exits 0" 0 "$avail_rc"
    check "spec-workflow enumerates as available" '"pluginId": "spec-workflow@development-skills"' "$avail_out"
    check "scaffold-project enumerates as available" '"pluginId": "scaffold-project@development-skills"' "$avail_out"

    inst_out="$(codex plugin add spec-workflow@development-skills --json 2>&1)"; inst_rc=$?
    check_rc "plugin add spec-workflow exits 0" 0 "$inst_rc"
    check "install reports an installedPath" '"installedPath"' "$inst_out"

    IPATH="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("installedPath",""))' <<<"$inst_out" 2>/dev/null)"
    if [[ -z "$IPATH" || ! -d "$IPATH" ]]; then
        check "installedPath is a real directory" "DIR" "MISSING($IPATH)"
    else
        check "installedPath is a real directory" "DIR" "DIR"
        [[ -f "$IPATH/skills/changelog-generate/SKILL.md" ]] \
            && skill_state="PRESENT" || skill_state="ABSENT"
        check "installed cache carries the changelog-generate skill" "PRESENT" "$skill_state"
        [[ -f "$IPATH/scripts/changelog.sh" ]] \
            && backing_state="PRESENT" || backing_state="ABSENT"
        check "installed cache carries the changelog.sh backing script" "PRESENT" "$backing_state"

        # CDX-002 relative ref: from the installed skill dir, does
        # ../../scripts/changelog.sh resolve to the installed backing script?
        if [[ -f "$IPATH/skills/changelog-generate/../../scripts/changelog.sh" ]]; then
            rel_state="RESOLVES"
        else
            rel_state="BROKEN"
        fi
        check "SKILL.md relative ../../scripts ref resolves in installed layout" "RESOLVES" "$rel_state"

        # Run the installed backing script standalone from the fresh consumer
        # repo's working dir -- proves the migrated relative refs and the pure
        # git-log behavior work in a genuinely installed-elsewhere scenario.
        run_out="$(cd "$CONS" && bash "$IPATH/scripts/changelog.sh" 2>&1)"; run_rc=$?
        check_rc "backing script runs standalone in consumer repo" 0 "$run_rc"
        check "changelog output has the Unreleased heading" "## Unreleased" "$run_out"
        check "changelog groups the feat commit" "### Feat" "$run_out"
        check "changelog keeps the feat subject + PR ref" "add alpha feature (#1)" "$run_out"
        check "changelog groups the fix commit" "### Fix" "$run_out"
        check "changelog keeps the fix subject + PR ref" "correct beta bug (#2)" "$run_out"
    fi

    # --- teardown + real-machine non-mutation proof ------------------------
    codex plugin marketplace remove development-skills >/dev/null 2>&1
    unset CODEX_HOME
    rm -rf "$CH" "$CONSROOT"

    cfg_after="$(stat -f '%m %z' "$REAL_CFG" 2>/dev/null || echo NONE)"
    check "real ~/.codex/config.toml untouched by isolated roundtrip" "$cfg_before" "$cfg_after"
fi
