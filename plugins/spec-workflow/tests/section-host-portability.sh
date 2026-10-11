#!/usr/bin/env bash
# section-host-portability.sh -- sourced by run-tests.sh; do not run standalone.
# Skills must work on ALL THREE hosts: Claude Code (marketplace or
# .claude/skills), Codex (.agents marketplace or .agents/skills), and
# OpenCode (.opencode/skills). install-skills.sh is the client-neutral
# installer (symlinks, never copies); every SKILL.md follows the portable
# contract (frontmatter name == dir, description present, lowercase-hyphenated).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== host portability: portable SKILL.md contract (claude + codex + opencode) =="
REPO_ROOT="$PLUGIN/../.."
out="$(python3 - "$REPO_ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]

def meaningful_scan_count(count):
    return count >= 30

# Pin the minimum and the decade transition that broke the former text-prefix check.
for sample, expected in ((0, False), (3, False), (29, False), (30, True),
                         (39, True), (40, True), (100, True)):
    assert meaningful_scan_count(sample) == expected, f"scan-count boundary: {sample}"
print("SCAN_BOUNDARIES OK")

bad, count = [], 0
for plugin in sorted(os.listdir(os.path.join(root, "plugins"))):
    sd = os.path.join(root, "plugins", plugin, "skills")
    if not os.path.isdir(sd):
        continue
    for skill in sorted(os.listdir(sd)):
        f = os.path.join(sd, skill, "SKILL.md")
        if not os.path.isfile(f):
            continue
        count += 1
        m = re.match(r"---\n(.*?)\n---", open(f).read(6000), re.S)
        if not m:
            bad.append(f"{plugin}/{skill}: no frontmatter"); continue
        fm = m.group(1)
        nm = re.search(r"^name:\s*(.+)$", fm, re.M)
        ds = re.search(r"^description:\s*(.+)$", fm, re.M)
        if not nm or nm.group(1).strip() != skill:
            bad.append(f"{plugin}/{skill}: name mismatch")
        elif not re.fullmatch(r"[a-z0-9-]+", nm.group(1).strip()):
            bad.append(f"{plugin}/{skill}: name not lowercase-hyphenated")
        if not ds or not ds.group(1).strip():
            bad.append(f"{plugin}/{skill}: missing description")
print(f"SCANNED {count}")
print("SCAN_MINIMUM_OK", meaningful_scan_count(count))
print("CONTRACT " + ("OK" if not bad else "BAD: " + "; ".join(bad)))
PY
)"
check "portable contract holds for every skill" "CONTRACT OK" "$out"
check "scan-count minimum accepts 30 and above, including 40" "SCAN_BOUNDARIES OK" "$out"
check "a meaningful number of skills were scanned (at least 30)" "SCAN_MINIMUM_OK True" "$out"

echo "== host portability: install-skills.sh (opencode + all clients) =="
INSTALLER="$REPO_ROOT/install-skills.sh"
if [[ -x "$INSTALLER" ]]; then echo "ok   installer exists and is executable"; else echo "FAIL installer missing or not executable: $INSTALLER"; fails=$((fails + 1)); fi
HP="$(mktemp -d)"
out="$(LUMA_SKILLS_PROJECT_ROOT="$HP" bash "$INSTALLER" opencode 2>&1)"; rc=$?
check_rc "opencode install exits 0" 0 "$rc"
[[ -f "$HP/.opencode/skills/implement-task/SKILL.md" ]] && r=yes || r=no
check "opencode: implement-task discoverable via .opencode/skills/" "yes" "$r"
[[ -L "$HP/.opencode/skills/implement-task" ]] && r=yes || r=no
check "opencode: installed as a symlink (edits propagate live)" "yes" "$r"
out="$(LUMA_SKILLS_PROJECT_ROOT="$HP" bash "$INSTALLER" opencode 2>&1)"; rc=$?
check_rc "opencode install is idempotent (second run exits 0)" 0 "$rc"
out="$(LUMA_SKILLS_PROJECT_ROOT="$HP" bash "$INSTALLER" all 2>&1)"; rc=$?
check_rc "all-clients install exits 0" 0 "$rc"
[[ -f "$HP/.claude/skills/implement-task/SKILL.md" ]] && r=yes || r=no
check "claude: implement-task discoverable via .claude/skills/" "yes" "$r"
[[ -f "$HP/.agents/skills/implement-task/SKILL.md" ]] && r=yes || r=no
check "codex: implement-task discoverable via .agents/skills/" "yes" "$r"
# Compare destination names AND resolved SKILL.md files with the source inventory.
# Equal counts alone miss wrong targets, copies, and missing-plus-extra entries.
hp_inventory() {
    python3 - "$REPO_ROOT" "$1" <<'PY'
from pathlib import Path
import sys

root, installed = map(Path, sys.argv[1:])
expected = {}
for source in sorted(root.glob("plugins/*/skills/*/SKILL.md")):
    name = source.parent.name
    if name in expected:
        name = source.parents[2].name + "-" + name
    assert name not in expected, f"ambiguous source inventory: {name}"
    expected[name] = source.resolve(strict=True)
assert expected, "empty source inventory"
actual = {entry.name: entry for entry in installed.iterdir()}
assert actual.keys() == expected.keys(), (
    f"missing={sorted(expected.keys() - actual.keys())}, "
    f"extra={sorted(actual.keys() - expected.keys())}"
)
for name, canonical in expected.items():
    entry = actual[name]
    assert entry.is_symlink(), f"not a symlink: {entry}"
    assert (entry / "SKILL.md").resolve(strict=True) == canonical, f"wrong target: {entry}"
print(f"CANONICAL {len(expected)}")
PY
}
for hp_client in .opencode .claude .agents; do
    hp_target="$HP/$hp_client/skills"
    out="$(hp_inventory "$hp_target" 2>&1)"; rc=$?
    check_rc "$hp_client: exact canonical inventory ($out)" 0 "$rc"
    # Exercise the oracle itself, retaining the entry count for wrong-target probes.
    hp_original="$(readlink "$hp_target/implement-task")"
    rm "$hp_target/implement-task"
    out="$(hp_inventory "$hp_target" 2>&1)"; rc=$?
    check_rc "$hp_client: oracle rejects a missing skill" 1 "$rc"
    ln -s "$hp_target/board" "$hp_target/implement-task"
    out="$(hp_inventory "$hp_target" 2>&1)"; rc=$?
    check_rc "$hp_client: oracle rejects a wrong canonical target" 1 "$rc"
    rm "$hp_target/implement-task"
    mkdir "$hp_target/implement-task"
    cp "$hp_original/SKILL.md" "$hp_target/implement-task/SKILL.md"
    out="$(hp_inventory "$hp_target" 2>&1)"; rc=$?
    check_rc "$hp_client: oracle rejects a copied skill" 1 "$rc"
    rm "$hp_target/implement-task/SKILL.md"
    rmdir "$hp_target/implement-task"
    ln -s "$hp_original" "$hp_target/implement-task"
    ln -s "$hp_original" "$hp_target/unexpected-skill"
    out="$(hp_inventory "$hp_target" 2>&1)"; rc=$?
    check_rc "$hp_client: oracle rejects an extra skill" 1 "$rc"
    rm "$hp_target/unexpected-skill"
    out="$(hp_inventory "$hp_target" 2>&1)"; rc=$?
    check_rc "$hp_client: restored inventory passes" 0 "$rc"
done
# a REAL pre-existing dir is never clobbered: the plugin's skill lands under
# the <plugin>-<skill> fallback name instead (reference installer semantics);
# refusal happens only when BOTH names are taken by foreign content.
HP2="$(mktemp -d)"; mkdir -p "$HP2/.opencode/skills/implement-task"
echo custom > "$HP2/.opencode/skills/implement-task/SKILL.md"
out="$(LUMA_SKILLS_PROJECT_ROOT="$HP2" bash "$INSTALLER" opencode 2>&1)"; rc=$?
check_rc "collision install still exits 0 (fallback name used)" 0 "$rc"
check "the real dir's content is untouched" "custom" "$(cat "$HP2/.opencode/skills/implement-task/SKILL.md")"
[[ -f "$HP2/.opencode/skills/spec-workflow-implement-task/SKILL.md" ]] && r=yes || r=no
check "colliding skill installed under the plugin-prefixed fallback name" "yes" "$r"
HP3="$(mktemp -d)"; mkdir -p "$HP3/.opencode/skills/implement-task" "$HP3/.opencode/skills/spec-workflow-implement-task"
echo custom > "$HP3/.opencode/skills/implement-task/SKILL.md"
echo custom2 > "$HP3/.opencode/skills/spec-workflow-implement-task/SKILL.md"
out="$(LUMA_SKILLS_PROJECT_ROOT="$HP3" bash "$INSTALLER" opencode 2>&1)"; rc=$?
if [[ $rc -ne 0 ]]; then echo "ok   refuses when both names are taken by foreign content"; else echo "FAIL double collision did not refuse"; fails=$((fails + 1)); fi
check "refusal names the conflicting path" "spec-workflow-implement-task" "$out"
rm -rf "$HP" "$HP2" "$HP3"

echo "== host portability: codex manifests cover every plugin =="
out="$(python3 - "$REPO_ROOT" <<'PY'
import json, os, sys
root = sys.argv[1]
mp = json.load(open(os.path.join(root, ".agents", "plugins", "marketplace.json")))
listed = sorted(p["name"] for p in mp["plugins"])
have_skills = sorted(
    p for p in os.listdir(os.path.join(root, "plugins"))
    if os.path.isdir(os.path.join(root, "plugins", p, "skills"))
)
print("LISTED", listed)
print("HAVE", have_skills)
print("COVERED", listed == have_skills)
for p in have_skills:
    pj = os.path.join(root, "plugins", p, ".codex-plugin", "plugin.json")
    ok = os.path.isfile(pj) and json.load(open(pj)).get("name") == p
    print(f"CODEXPLUGIN {p} {'OK' if ok else 'MISSING'}")
PY
)"
check "codex marketplace lists every skills-bearing plugin" "COVERED True" "$out"
check "peer-review has a codex plugin manifest" "CODEXPLUGIN peer-review OK" "$out"
check "spec-workflow codex manifest intact" "CODEXPLUGIN spec-workflow OK" "$out"
check "scaffold-project codex manifest intact" "CODEXPLUGIN scaffold-project OK" "$out"
