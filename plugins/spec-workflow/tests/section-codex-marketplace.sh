#!/usr/bin/env bash
# section-codex-marketplace.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# Asserts the repo-local Codex marketplace manifest at
# .agents/plugins/marketplace.json matches the plugin-creator reference shape
# and lists EXACTLY the two Codex-covered plugins (spec-workflow,
# scaffold-project) AND peer-review -- originally excluded pending its own
# Codex-compat sweep, peer-review is provider-pluggable now (codex + claude
# backends, mandatory ask-which-provider step per its SKILL.md), so the
# cross-vendor premise holds under a Codex host and it ships in this
# marketplace like the other two (tri-host work, section-host-portability.sh). Scoped to the manifest file's own structure/content: the live
# `codex plugin marketplace add`/`list` roundtrip mutates ~/.codex/config.toml
# (persistent global state on the developer's machine), so it is a MANUAL
# verification step recorded in the PR, not something this hermetic suite runs.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== codex-marketplace =="

REPO="$(cd "$PLUGIN/../.." && pwd)"
MANIFEST="$REPO/.agents/plugins/marketplace.json"
CLAUDE_MP="$REPO/.claude-plugin/marketplace.json"

if [[ ! -f "$MANIFEST" ]]; then
    check "codex marketplace manifest exists at .agents/plugins/marketplace.json" "EXISTS" "MISSING"
else
    check "codex marketplace manifest exists at .agents/plugins/marketplace.json" "EXISTS" "EXISTS"

    # One python pass emits diagnostic lines the grep-based checks assert on.
    report="$(python3 - "$MANIFEST" <<'PY' 2>&1
import json, sys
try:
    with open(sys.argv[1]) as f:
        m = json.load(f)
except Exception as e:
    print("JSON_INVALID", e)
    sys.exit(0)
print("JSON_VALID")
print("TOP_NAME", "present" if isinstance(m.get("name"), str) and m["name"] else "absent")
print("DISPLAY_NAME", "present" if isinstance(m.get("interface"), dict)
      and isinstance(m["interface"].get("displayName"), str)
      and m["interface"]["displayName"] else "absent")
plugins = m.get("plugins")
if not isinstance(plugins, list):
    print("PLUGINS_TYPE bad")
    sys.exit(0)
names = [p.get("name") for p in plugins if isinstance(p, dict)]
print("PLUGIN_COUNT", len(plugins))
print("PLUGIN_NAMES", ",".join(str(n) for n in names))
for p in plugins:
    if not isinstance(p, dict):
        continue
    n = p.get("name")
    src = p.get("source") or {}
    pol = p.get("policy") or {}
    print(f"ENTRY {n} source.source={src.get('source')}")
    print(f"ENTRY {n} source.path={src.get('path')}")
    print(f"ENTRY {n} policy.installation={pol.get('installation')}")
    print(f"ENTRY {n} policy.authentication={pol.get('authentication')}")
    print(f"ENTRY {n} category={p.get('category')}")
PY
)"

    check "manifest is valid JSON" "JSON_VALID" "$report"
    check "top-level name present" "TOP_NAME present" "$report"
    check "interface.displayName present" "DISPLAY_NAME present" "$report"
    check "lists exactly three plugins" "PLUGIN_COUNT 3" "$report"
    check "lists spec-workflow, scaffold-project and peer-review" "PLUGIN_NAMES spec-workflow,scaffold-project,peer-review" "$report"

    for plug in spec-workflow scaffold-project peer-review; do
        check "$plug: source.source=local" "ENTRY $plug source.source=local" "$report"
        check "$plug: source.path=./plugins/$plug" "ENTRY $plug source.path=./plugins/$plug" "$report"
        check "$plug: policy.installation=AVAILABLE" "ENTRY $plug policy.installation=AVAILABLE" "$report"
        check "$plug: policy.authentication=ON_INSTALL" "ENTRY $plug policy.authentication=ON_INSTALL" "$report"
        check "$plug: category=Productivity" "ENTRY $plug category=Productivity" "$report"
    done
fi

# The Codex manifest must be a DISTINCT file from Claude's own marketplace,
# which still carries all three plugins (incl. peer-review) untouched. This
# guards against accidentally pointing the new file at, or editing, the wrong
# marketplace.
claude_mp="$(cat "$CLAUDE_MP" 2>/dev/null)"
check ".claude-plugin/marketplace.json still lists peer-review (untouched)" "peer-review" "$claude_mp"
