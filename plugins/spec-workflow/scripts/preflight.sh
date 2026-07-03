#!/usr/bin/env bash
# preflight.sh [--spec] — fast existence checks, injected into skill context at load time.
# Always exits 0: the skill still loads so the model can read the FAIL line and redirect.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="${PROJECT_CONFIG:-$ROOT/.claude/project.json}"

if [[ ! -f "$CONFIG" ]]; then
    echo "PREFLIGHT FAIL: no .claude/project.json — STOP: run /spec-workflow:setup-project first (it will suggest /spec-workflow:craft-spec if there is no spec yet)."
    exit 0
fi

if [[ "${1:-}" == "--spec" ]]; then
    python3 - "$CONFIG" "$ROOT" <<'PY'
import json, os, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception as e:  # noqa: BLE001
    print(f"PREFLIGHT FAIL: cannot parse project.json ({e}) — STOP: fix it, then re-run.")
    sys.exit(0)
root = sys.argv[2]
specs = cfg.get("specs", [])
if not specs:
    print("PREFLIGHT FAIL: no specs configured in project.json — STOP: run /spec-workflow:craft-spec to create one, then register it (setup-project).")
    sys.exit(0)
missing = [s.get("specPath", "?") for s in specs if not os.path.exists(os.path.join(root, s.get("specPath", "")))]
if missing:
    print("PREFLIGHT FAIL: spec file(s) missing: " + ", ".join(missing) + " — STOP: run /spec-workflow:craft-spec to create them (or fix specPath in project.json).")
else:
    print("preflight ok: config + " + str(len(specs)) + " spec(s) present")
PY
else
    echo "preflight ok: config present"
fi
