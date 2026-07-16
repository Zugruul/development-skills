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

# development-skills#197: this repo dogfoods plugins/spec-workflow -- a
# session can invoke its scripts either from this repo's own working tree
# (always current) or via an installed marketplace cache copy
# (~/.claude/plugins/cache/*/spec-workflow/*/scripts, resolved via
# ${CLAUDE_PLUGIN_ROOT} in a normal session) that does NOT auto-update when
# this repo's own source changes and merges. A real merge once left the
# cache silently 77+ lines stale, causing a genuine correctness failure
# (a newly-added identity role unresolvable via the cache path moments
# after the merge that added it). Advisory only -- never blocks, never
# changes this script's own exit code. Silent no-op when this repo isn't
# the plugin's own source, or no installed cache is found to compare
# against. SPEC_WORKFLOW_CACHE_SEARCH_BASE overrides the search root
# (tests point it at a fixture directory instead of the real cache).
python3 - "$ROOT" <<'PY'
import glob
import os
import sys

root = sys.argv[1]
local_scripts = os.path.join(root, "plugins", "spec-workflow", "scripts")
if not os.path.isdir(local_scripts):
    sys.exit(0)  # this repo isn't plugins/spec-workflow's own source

# Which installed cache copy to compare against, when more than one
# version is installed simultaneously (a real, observed machine state --
# e.g. 0.1.0/0.25.0/0.6.1/0.9.0 all present at once): lexicographically
# sorting the glob and taking the first match is NOT the actually-active
# or newest one -- it's an arbitrary string-sort artifact (development-
# skills#197 review finding). Prefer CLAUDE_PLUGIN_ROOT when it's set and
# points at a real scripts dir (that's the copy THIS session actually
# resolved and would run); otherwise pick the candidate with the newest
# mtime on its identity_lib.py (the most recently installed/updated copy).
plugin_root_env = os.environ.get("CLAUDE_PLUGIN_ROOT")
cache_scripts = None
if plugin_root_env:
    candidate = os.path.join(plugin_root_env, "scripts")
    if os.path.isfile(os.path.join(candidate, "identity_lib.py")):
        cache_scripts = candidate

if cache_scripts is None:
    search_base = os.environ.get(
        "SPEC_WORKFLOW_CACHE_SEARCH_BASE",
        os.path.expanduser("~/.claude/plugins/cache"),
    )
    candidates = glob.glob(os.path.join(search_base, "*", "spec-workflow", "*", "scripts"))
    newest_mtime = None
    for c in candidates:
        key_file = os.path.join(c, "identity_lib.py")
        if not os.path.isfile(key_file):
            continue
        mtime = os.path.getmtime(key_file)
        if newest_mtime is None or mtime > newest_mtime:
            newest_mtime = mtime
            cache_scripts = c
if cache_scripts is None:
    sys.exit(0)  # no installed cache found to compare against

KEY_FILES = ("identity_lib.py", "identity.sh", "board.sh", "config.py")
diverged = []
for name in KEY_FILES:
    local_path = os.path.join(local_scripts, name)
    cache_path = os.path.join(cache_scripts, name)
    if not os.path.isfile(local_path) or not os.path.isfile(cache_path):
        continue
    with open(local_path, "rb") as f:
        local_content = f.read()
    with open(cache_path, "rb") as f:
        cache_content = f.read()
    if local_content != cache_content:
        diverged.append(name)

if diverged:
    print(
        "PLUGIN CACHE WARN: " + ", ".join(diverged)
        + " differ between this repo's own source and the installed plugin"
        + " cache (" + cache_scripts + "). A script invoked via the cache path"
        + " may be running stale logic. Reinstall/update the spec-workflow"
        + " plugin to pick up recent changes."
    )
PY
