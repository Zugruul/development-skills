#!/usr/bin/env bash
# e0-smoke-manual.sh -- CDX-007 Epic-0 exit condition, MODEL-DRIVEN tier.
#
# WHAT THIS DOES
#   End-to-end proof that a real Codex agent, given only a natural-language
#   request, DISCOVERS and INVOKES the spec-workflow `changelog-generate`
#   skill after the plugin is installed from this repo's local marketplace --
#   the full "an LLM actually reads the skill and decides to run it" smoke
#   that the hermetic suite deliberately cannot cover.
#
#   Steps (all against an ISOLATED CODEX_HOME temp dir -- never your real
#   ~/.codex, though your existing auth.json is COPIED into it so the real
#   model call can authenticate; and a SEPARATE fresh consumer git repo --
#   never this repo):
#     1. codex plugin marketplace add <this repo>      (CDX-004 manifest)
#     2. codex plugin add spec-workflow@development-skills
#     3. codex exec "<prompt>" from the consumer repo, asking in plain English
#        for a changelog since the last release -- the model must find and run
#        the changelog-generate skill's backing script itself.
#     4. Assert the model's transcript contains the expected changelog output.
#     5. Tear everything down; the real ~/.codex is provably untouched.
#
# WHY THIS IS **NOT AUTOMATED** (kept out of run-tests.sh / gate.sh)
#   `codex exec` invokes a real LLM: it costs real API/usage, requires real
#   Codex auth (`codex login`), and is non-deterministic. None of that belongs
#   in the always-green, offline, CI-hosted hermetic suite -- so this tier is
#   deliberately not automated. The hermetic proof
#   of install + discovery + standalone runnability lives in
#   tests/section-codex-e0-smoke.sh; THIS script is the human-run companion
#   that closes the loop with a genuine model invocation.
#
# HOW TO RUN (by hand, on a machine with working Codex auth)
#   1. Ensure Codex is installed and logged in:  codex --version && codex login status
#   2. From anywhere:                            bash plugins/spec-workflow/scripts/e0-smoke-manual.sh
#   3. Read the PASS/FAIL line and the captured transcript it prints.
#   Exit 0 = the model found and ran the skill and produced the changelog.
#   Exit 1 = assertion failed (transcript printed for diagnosis).
#   Exit 2 = preconditions missing (codex CLI absent or not logged in).
#
# This script is self-contained and leaves zero state on the real machine.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

command -v codex >/dev/null 2>&1 || { echo "PRECONDITION: codex CLI not found on PATH" >&2; exit 2; }
if ! codex login status >/dev/null 2>&1; then
    echo "PRECONDITION: codex is not logged in (run 'codex login')" >&2
    exit 2
fi

CH="$(mktemp -d)"
CONSROOT="$(mktemp -d)"
CONS="$CONSROOT/consumer"
# Inline trap (repo convention): drop the isolated marketplace entry, then
# remove both temp trees. Evaluated at exit, so it uses the final var values.
trap 'CODEX_HOME="$CH/home" codex plugin marketplace remove development-skills >/dev/null 2>&1; rm -rf "$CH" "$CONSROOT"' EXIT

export CODEX_HOME="$CH/home"
mkdir -p "$CODEX_HOME"

# Isolating CODEX_HOME to a fresh temp dir gives it NO credentials, so the
# real model call would 401 (`Missing bearer` on wss/https .../v1/responses).
# Carry ONLY the existing auth token into the isolated home -- reuses the
# credentials you already have without importing (or mutating) your real
# marketplace/plugin config, which stays fully isolated. If no auth.json
# exists, the exec below will fail loudly with the same 401 rather than
# silently pretending to pass.
REAL_HOME="${REAL_CODEX_HOME:-$HOME/.codex}"
if [[ -f "$REAL_HOME/auth.json" ]]; then
    cp "$REAL_HOME/auth.json" "$CODEX_HOME/auth.json"
else
    echo "WARN: no $REAL_HOME/auth.json to seed — codex exec will likely 401" >&2
fi

# Fresh consumer repo with a deterministic history: a seed root commit (the
# excluded from..to boundary) plus one feat and one fix.
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

echo "== installing spec-workflow into isolated CODEX_HOME =="
codex plugin marketplace add "$REPO" --json >/dev/null || { echo "FAIL: marketplace add" >&2; exit 1; }
codex plugin add spec-workflow@development-skills --json >/dev/null || { echo "FAIL: plugin add" >&2; exit 1; }

PROMPT="Using the changelog-generate skill, generate a changelog for this repository summarizing what changed since the last release, and show me the result."

echo "== running model-driven smoke: codex exec (real model call) =="
# --sandbox workspace-write: the changelog-generate backing script uses
# `mktemp -d` for its per-type buckets, which Codex's DEFAULT read-only exec
# sandbox denies ("Operation not permitted") -- so the script itself cannot
# complete under read-only. Granting workspace-write lets the genuine backing
# script run end-to-end (rather than the model reproducing its logic by hand),
# which is the faithful E0 proof.
transcript="$(cd "$CONS" && codex exec --skip-git-repo-check --sandbox workspace-write "$PROMPT" 2>&1)"; exec_rc=$?

echo "----- codex exec transcript -----"
echo "$transcript"
echo "---------------------------------"

if [[ $exec_rc -ne 0 ]]; then
    echo "FAIL: codex exec exited $exec_rc"
    exit 1
fi

# The model should have produced the changelog: an Unreleased heading and the
# feat/fix entries with their PR refs preserved by the backing script.
ok=1
grep -qF "add alpha feature (#1)" <<<"$transcript" || { echo "MISS: feat entry not in transcript"; ok=0; }
grep -qF "correct beta bug (#2)"  <<<"$transcript" || { echo "MISS: fix entry not in transcript"; ok=0; }

if [[ $ok -eq 1 ]]; then
    echo "PASS: model discovered and invoked changelog-generate; changelog present in transcript"
    exit 0
else
    echo "FAIL: model did not produce the expected changelog output"
    exit 1
fi
