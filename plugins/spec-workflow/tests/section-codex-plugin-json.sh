#!/usr/bin/env bash
# section-codex-plugin-json.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# Asserts that every marketplace plugin carries a `.codex-plugin/plugin.json` that
# passes Codex's plugin-ingestion validator. That validator lives OUTSIDE this
# repo (in the plugin-creator system skill) and needs the python `yaml`
# package, so when either is unavailable we SKIP with a visible note rather
# than crashing the suite or spuriously failing an environment that simply
# can't run the external check.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== codex-plugin-json =="

CODEX_VALIDATOR="$HOME/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py"
PLUGINS_DIR="$(dirname "$PLUGIN")"

for plug in spec-workflow scaffold-project peer-review remote-compute; do
    skill_path="$(python3 - "$PLUGINS_DIR/$plug/.codex-plugin/plugin.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    print(json.load(f).get("skills", ""))
PY
)"
    check "$plug: skills path is plugin-root-relative" "./skills/" "$skill_path"
done

if [[ ! -f "$CODEX_VALIDATOR" ]] || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "SKIP codex plugin.json validation — validator ($CODEX_VALIDATOR) or python 'yaml' package unavailable"
else
    for plug in spec-workflow scaffold-project peer-review remote-compute; do
        out="$(python3 "$CODEX_VALIDATOR" "$PLUGINS_DIR/$plug" 2>&1)"; rc=$?
        check_rc "$plug: validator exits 0" 0 "$rc"
        check "$plug: validator reports pass" "Plugin validation passed" "$out"
    done
fi
