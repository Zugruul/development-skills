#!/usr/bin/env bash
# preflight.sh [--spec] — fast existence checks, injected into skill context at load time.
# Always exits 0: the skill still loads so the model can read the FAIL line and redirect.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="$(python3 "$HERE/config.py" "$ROOT" path)"

if [[ -z "$CONFIG" || ! -f "$CONFIG" ]]; then
    echo "PREFLIGHT FAIL: no .claude/project.yaml — STOP: run /spec-workflow:setup-project first (it will suggest /spec-workflow:craft-spec if there is no spec yet)."
    exit 0
fi

if [[ "${1:-}" == "--spec" ]]; then
    python3 - "$CONFIG" "$ROOT" <<'PY'
import os, sys
import config as C
try:
    cfg = C.load_config(path=sys.argv[1], warn=False)
except C.ConfigError as e:
    print(f"PREFLIGHT FAIL: cannot parse config ({e}) — STOP: fix it, then re-run.")
    sys.exit(0)
root = sys.argv[2]
specs = cfg.get("specs", [])
if not specs:
    print("PREFLIGHT FAIL: no specs configured in the config — STOP: run /spec-workflow:craft-spec to create one, then register it (setup-project).")
    sys.exit(0)
missing = [s.get("specPath", "?") for s in specs if not os.path.exists(os.path.join(root, s.get("specPath", "")))]
if missing:
    print("PREFLIGHT FAIL: spec file(s) missing: " + ", ".join(missing) + " — STOP: run /spec-workflow:craft-spec to create them (or fix specPath in the config).")
else:
    print("preflight ok: config + " + str(len(specs)) + " spec(s) present")
PY
else
    echo "preflight ok: config present"
fi

# Agent identities: a WARN here never blocks (identity.sh --check always exits 0);
# unresolvable roles just fall back to committing as the human.
bash "$HERE/identity.sh" --check
