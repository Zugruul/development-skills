#!/usr/bin/env bash
# section-compute-overlay.sh -- sourced by run-tests.sh; do not run standalone.
# The spec-workflow SIDE of the remote-compute contract seam
# (docs/design/remote-compute-plugin-extraction.md): the `compute:` section of
# the gitignored project.local.yaml overlay is WRITTEN by the remote-compute
# PLUGIN but read/validated by THIS plugin's config machinery
# (config.py LOCAL_OVERLAY_KEYS + validate-config.py + the project schema).
# These tests exercise the machinery with a hand-crafted overlay — the
# enable -> config.py round-trip integration test (real remote-compute.py
# output flowing through this loader) lives in the remote-compute plugin's own
# suite, which depends on spec-workflow in the same direction the plugin does.
# Also asserts the extraction itself: the moved tree lives in
# plugins/remote-compute and is wired into gate/docs/marketplaces.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== compute overlay (contract seam with the remote-compute plugin) =="

CO="$(mktemp -d)"; mkdir -p "$CO/.claude" "$CO/.neural-network"
cp "$FIX/valid.project.yaml" "$CO/.neural-network/project.yaml"
cat > "$CO/.neural-network/project.local.yaml" <<'YAML'
compute:
    resources:
        gpubox:
            enabled: true
            roles:
            - training
YAML
check "overlay: merged read via config.py" "training" "$(python3 "$PLUGIN/scripts/config.py" "$CO" get compute.resources.gpubox.roles.0)"
check "overlay: enabled flag merged" "true" "$(python3 "$PLUGIN/scripts/config.py" "$CO" get compute.resources.gpubox.enabled)"
check "overlay: committed config (with overlay present) still VALID" "VALID" "$(python3 "$PLUGIN/scripts/validate-config.py" "$CO/.neural-network/project.yaml" 2>&1)"
# non-allowlisted overlay keys are deliberately ignored (no silent override)
printf 'project:\n    name: hacked-by-overlay\n' >> "$CO/.neural-network/project.local.yaml"
check "overlay: non-allowlisted key ignored" "fixture-project" "$(python3 "$PLUGIN/scripts/config.py" "$CO" get project.name)"
# a missing local file is the normal case, never an error
rm -f "$CO/.neural-network/project.local.yaml"
check "overlay: absent file is fine" "fixture-project" "$(python3 "$PLUGIN/scripts/config.py" "$CO" get project.name)"
rm -rf "$CO"

echo "== remote-compute extraction: tree moved, wiring intact =="
REPO_ROOT="$(cd "$PLUGIN/../.." && pwd)"
RC="$REPO_ROOT/plugins/remote-compute"
[[ -f "$RC/.claude-plugin/plugin.json" ]] && r=yes || r=no
check "remote-compute plugin manifest exists" "yes" "$r"
[[ -f "$RC/.codex-plugin/plugin.json" ]] && r=yes || r=no
check "remote-compute codex manifest exists" "yes" "$r"
[[ -f "$RC/scripts/remote-compute.py" ]] && r=yes || r=no
check "remote-compute.py lives in the new plugin" "yes" "$r"
[[ -d "$RC/scripts/remote-capabilities/_shared" ]] && r=yes || r=no
check "remote-capabilities tree lives in the new plugin" "yes" "$r"
[[ -f "$RC/skills/remote-compute/SKILL.md" && -f "$RC/skills/compute-top/SKILL.md" ]] && r=yes || r=no
check "both skills live in the new plugin" "yes" "$r"
[[ -f "$RC/tests/run-tests.sh" ]] && r=yes || r=no
check "new plugin has its own test runner" "yes" "$r"
[[ -e "$PLUGIN/scripts/remote-compute.py" || -d "$PLUGIN/scripts/remote-capabilities" || -d "$PLUGIN/skills/remote-compute" || -d "$PLUGIN/skills/compute-top" ]] && r=stale || r=clean
check "old spec-workflow locations are gone" "clean" "$r"
check "new plugin README declares the spec-workflow requirement" "requires the spec-workflow plugin" "$(cat "$RC/README.md" 2>/dev/null)"
check "remote-compute SKILL.md declares the spec-workflow requirement" "requires the spec-workflow plugin" "$(cat "$RC/skills/remote-compute/SKILL.md" 2>/dev/null)"
DOGFOOD="$(cat "$REPO_ROOT/.neural-network/project.yaml" 2>/dev/null)"
check "repo gate runs the remote-compute suite" "plugins/remote-compute/tests/run-tests.sh" "$DOGFOOD"
check "repo gate validates the remote-compute plugin" "claude plugin validate plugins/remote-compute" "$DOGFOOD"
check "docs registry covers plugins/remote-compute" "plugins/remote-compute/**" "$DOGFOOD"
