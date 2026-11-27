#!/usr/bin/env bash
# Sourced by run-tests.sh. Exercise the real smoke harness with a local CLI
# fixture; the separate real-Codex roundtrip remains registered and unchanged.
declare -F check >/dev/null 2>&1 || { echo "run via run-tests.sh" >&2; exit 2; }
echo "== codex-e0-smoke-streams =="

_e0_fixture="$(mktemp -d)"
mkdir -p "$_e0_fixture/bin"
cat > "$_e0_fixture/bin/codex" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys

home = Path(os.environ["CODEX_HOME"])
args = sys.argv[1:]
if args[:3] == ["plugin", "marketplace", "add"]:
    (home / "source").write_text(args[3])
    print(json.dumps({"marketplaceName": "development-skills"}))
elif args == ["plugin", "list", "--marketplace", "development-skills", "--available", "--json"]:
    print(json.dumps([{"pluginId": name + "@development-skills"}
                      for name in ("spec-workflow", "scaffold-project")]))
elif args == ["plugin", "add", "spec-workflow@development-skills", "--json"]:
    source = Path((home / "source").read_text()) / "plugins/spec-workflow"
    installed = home / "cache/spec-workflow"
    shutil.copytree(source, installed)
    # Synthetic trigger: stderr text must never become part of JSON stdout.
    print("WARNING: fixture helper setup unavailable", file=sys.stderr)
    mode = os.environ["E0_INSTALL_MODE"]
    if mode == "malformed":
        print("not JSON: do not filter this line away")
    print(json.dumps({"installedPath": str(installed)}))
    sys.exit(37 if mode == "failed" else 0)
elif args == ["plugin", "marketplace", "remove", "development-skills"]:
    pass
else:
    sys.exit("unexpected fixture CLI arguments: " + repr(args))
PY
chmod +x "$_e0_fixture/bin/codex"

for _e0_mode in success malformed failed; do
    # Source only the existing smoke section in a child shell, avoiding runner
    # recursion and keeping its CODEX_HOME, consumer repo, and state isolated.
    PATH="$_e0_fixture/bin:$PATH" E0_INSTALL_MODE="$_e0_mode" \
        bash -c '
            set -uo pipefail
            HERE="$1"
            PLUGIN="$2"
            fails=0
            source "$HERE/_lib.sh"
            source "$HERE/section-codex-e0-smoke.sh"
            [[ "$fails" -eq 0 ]]
        ' bash "$HERE" "$PLUGIN" \
        > "$_e0_fixture/$_e0_mode.out" 2> "$_e0_fixture/$_e0_mode.err"
    _e0_rc=$?
    _e0_out="$(cat "$_e0_fixture/$_e0_mode.out")"
    _e0_err="$(cat "$_e0_fixture/$_e0_mode.err")"
    check "$_e0_mode install retains stderr diagnostics" \
        "WARNING: fixture helper setup unavailable" "$_e0_err"
    case "$_e0_mode" in
        success)
            check_rc "warning plus valid JSON passes smoke" 0 "$_e0_rc"
            for _e0_proof in \
                "installedPath is a real directory" \
                "installed cache carries the changelog-generate skill" \
                "installed cache carries the changelog.sh backing script" \
                "SKILL.md relative ../../scripts ref resolves in installed layout" \
                "backing script runs standalone in consumer repo" \
                "changelog keeps the feat subject + PR ref" \
                "changelog keeps the fix subject + PR ref"; do
                check "warning success exercises: $_e0_proof" "ok   $_e0_proof" "$_e0_out"
            done
            ;;
        malformed)
            check_rc "malformed stdout fails smoke" 1 "$_e0_rc"
            check "malformed stdout cannot yield an installed path" \
                "FAIL installedPath is a real directory" "$_e0_out"
            ;;
        failed)
            check_rc "failed install with valid JSON fails smoke" 1 "$_e0_rc"
            check "failed install retains actual exit status" \
                "FAIL plugin add spec-workflow exits 0 — expected exit 0, got 37" "$_e0_out"
            ;;
    esac
done
rm -rf "$_e0_fixture"
