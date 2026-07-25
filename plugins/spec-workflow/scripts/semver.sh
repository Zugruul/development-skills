#!/bin/bash
# semver.sh — conventional-commit semver pipeline (#400).
#
#   semver.sh classify "<commit message>"          -> major|minor|patch|none
#   semver.sh bump <repo-root> <plugin> <level>    -> bumps plugin.json + the
#                                                     plugin's marketplace
#                                                     entry in lockstep,
#                                                     prints the new version
#                                                     (level none: prints the
#                                                     current version, no-op)
#   semver.sh apply-head <repo-root> <plugin>      -> classify HEAD's commit
#                                                     message and bump
#                                                     accordingly; prints the
#                                                     new version, or "none".
#                                                     Leaves the bump
#                                                     UNCOMMITTED — the caller
#                                                     owns the release commit
#                                                     (chore(release): ...).
#
# Classification (conventional commits):
#   BREAKING CHANGE in the body, or a `!` before the `:` -> major
#   feat                                                 -> minor
#   fix / perf / refactor                                -> patch
#   anything else (docs/chore/test/ci/retro/...)         -> none
#
# The release commit itself is `chore(release): ...` -> none, so re-running
# apply-head after a release is always a clean no-op (loop-safe for CI).
set -uo pipefail

CMD="${1:-}"

classify() {
    local msg="$1"
    local subject="${msg%%$'\n'*}"
    if printf '%s' "$msg" | grep -q "BREAKING CHANGE"; then echo major; return; fi
    if printf '%s' "$subject" | grep -Eq '^[a-z]+(\([^)]*\))?!:'; then echo major; return; fi
    case "$subject" in
        feat:*|feat\(*) echo minor ;;
        fix:*|fix\(*|perf:*|perf\(*|refactor:*|refactor\(*) echo patch ;;
        *) echo none ;;
    esac
}

bump() {
    local root="$1" plugin="$2" level="$3"
    python3 - "$root" "$plugin" "$level" <<'PY'
import json, sys
root, plugin, level = sys.argv[1], sys.argv[2], sys.argv[3]
pj_path = f"{root}/plugins/{plugin}/.claude-plugin/plugin.json"
mp_path = f"{root}/.claude-plugin/marketplace.json"
with open(pj_path) as f: pj = json.load(f)
cur = pj["version"]
if level == "none":
    print(cur); sys.exit(0)
major, minor, patch = (int(x) for x in cur.split("."))
if level == "major": major, minor, patch = major + 1, 0, 0
elif level == "minor": minor, patch = minor + 1, 0
elif level == "patch": patch += 1
else: sys.exit(f"unknown bump level: {level}")
new = f"{major}.{minor}.{patch}"
pj["version"] = new
with open(pj_path, "w") as f: json.dump(pj, f, indent=4); f.write("\n")
with open(mp_path) as f: mp = json.load(f)
for entry in mp.get("plugins", []):
    if entry.get("name") == plugin:
        entry["version"] = new
with open(mp_path, "w") as f: json.dump(mp, f, indent=4); f.write("\n")
print(new)
PY
}

case "$CMD" in
    classify)
        classify "${2:?usage: semver.sh classify \"<commit message>\"}"
        ;;
    bump)
        bump "${2:?repo root}" "${3:?plugin name}" "${4:?level}"
        ;;
    apply-head)
        ROOT="${2:?repo root}"; PLUGIN_NAME="${3:?plugin name}"
        MSG="$(git -C "$ROOT" log -1 --format='%B')"
        LEVEL="$(classify "$MSG")"
        if [[ "$LEVEL" == "none" ]]; then echo none; exit 0; fi
        bump "$ROOT" "$PLUGIN_NAME" "$LEVEL"
        ;;
    *)
        echo "usage: semver.sh {classify <msg> | bump <root> <plugin> <level> | apply-head <root> <plugin>}" >&2
        exit 2
        ;;
esac
