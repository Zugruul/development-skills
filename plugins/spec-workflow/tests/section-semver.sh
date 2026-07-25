#!/usr/bin/env bash
# section-semver.sh -- sourced by run-tests.sh; do not run standalone.
# Semver release pipeline (#400): classify a conventional commit into a bump
# level, bump plugin.json + the marketplace entry in lockstep, and
# apply-head end-to-end on a real commit.
# shellcheck disable=SC2154  # check/check_rc/PLUGIN come from run-tests.sh
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }

SEMVER="$PLUGIN/scripts/semver.sh"

echo "== semver release pipeline (#400) =="

echo "-- classify: conventional-commit type -> bump level --"
check "feat -> minor"            "minor" "$(bash "$SEMVER" classify "feat(400): add semver pipeline")"
check "fix -> patch"             "patch" "$(bash "$SEMVER" classify "fix(399): header polish round")"
check "perf -> patch"            "patch" "$(bash "$SEMVER" classify "perf: cheaper hover raycast")"
check "refactor -> patch"        "patch" "$(bash "$SEMVER" classify "refactor(board): split move guard")"
check "feat! -> major"           "major" "$(bash "$SEMVER" classify "feat!: drop schemaVersion 1")"
check "fix! -> major"            "major" "$(bash "$SEMVER" classify "fix(board)!: new id format")"
check "BREAKING CHANGE in body -> major" "major" "$(bash "$SEMVER" classify "feat(x): thing

BREAKING CHANGE: config key renamed")"
check "docs -> none"             "none"  "$(bash "$SEMVER" classify "docs: readme touch-up")"
check "chore -> none"            "none"  "$(bash "$SEMVER" classify "chore(release): spec-workflow v9.9.9")"
check "retro/non-conventional -> none" "none" "$(bash "$SEMVER" classify "retro: 399 close — notes minted")"

echo "-- bump: plugin.json + marketplace entry move in lockstep --"
TMP_ROOT="$(mktemp -d)"
mkdir -p "$TMP_ROOT/.claude-plugin" "$TMP_ROOT/plugins/spec-workflow/.claude-plugin"
cat > "$TMP_ROOT/plugins/spec-workflow/.claude-plugin/plugin.json" <<'JSON'
{"name": "spec-workflow", "version": "1.2.3"}
JSON
cat > "$TMP_ROOT/.claude-plugin/marketplace.json" <<'JSON'
{"version": "1.0.0", "plugins": [{"name": "other", "version": "0.5.0"}, {"name": "spec-workflow", "version": "1.2.3"}]}
JSON

out="$(bash "$SEMVER" bump "$TMP_ROOT" spec-workflow patch)"
check "patch bump prints the new version" "1.2.4" "$out"
check "patch bump rewrites plugin.json"   '"version": "1.2.4"' "$(cat "$TMP_ROOT/plugins/spec-workflow/.claude-plugin/plugin.json")"
check "patch bump rewrites ONLY the matching marketplace entry" '"version": "1.2.4"' "$(cat "$TMP_ROOT/.claude-plugin/marketplace.json")"
check "other plugins' marketplace versions untouched" '"version": "0.5.0"' "$(cat "$TMP_ROOT/.claude-plugin/marketplace.json")"
check "marketplace's own top-level version untouched" '"version": "1.0.0"' "$(cat "$TMP_ROOT/.claude-plugin/marketplace.json")"

out="$(bash "$SEMVER" bump "$TMP_ROOT" spec-workflow minor)"
check "minor bump resets patch" "1.3.0" "$out"
out="$(bash "$SEMVER" bump "$TMP_ROOT" spec-workflow major)"
check "major bump resets minor+patch" "2.0.0" "$out"

out="$(bash "$SEMVER" bump "$TMP_ROOT" spec-workflow none)"
rc=$?
check_rc "bump level 'none' is a no-op exit 0" 0 "$rc"
check "bump level 'none' leaves the version alone" "2.0.0" "$out"

echo "-- apply-head: end-to-end on a real repo commit --"
GTMP="$(mktemp -d)"
git -C "$GTMP" init -q
mkdir -p "$GTMP/.claude-plugin" "$GTMP/plugins/spec-workflow/.claude-plugin"
cat > "$GTMP/plugins/spec-workflow/.claude-plugin/plugin.json" <<'JSON'
{"name": "spec-workflow", "version": "0.1.0"}
JSON
cat > "$GTMP/.claude-plugin/marketplace.json" <<'JSON'
{"version": "1.0.0", "plugins": [{"name": "spec-workflow", "version": "0.1.0"}]}
JSON
git -C "$GTMP" add -A
git -C "$GTMP" -c user.name=t -c user.email=t@t commit -qm "feat(x): a minor-worthy change"
out="$(bash "$SEMVER" apply-head "$GTMP" spec-workflow)"
rc=$?
check_rc "apply-head exits 0" 0 "$rc"
check "apply-head classifies HEAD and bumps (feat -> 0.2.0)" "0.2.0" "$out"
check "apply-head leaves the bump UNCOMMITTED for the caller's release commit" " M plugins/spec-workflow/.claude-plugin/plugin.json" "$(git -C "$GTMP" status --porcelain)"

git -C "$GTMP" add -A
git -C "$GTMP" -c user.name=t -c user.email=t@t commit -qm "chore(release): spec-workflow v0.2.0"
out="$(bash "$SEMVER" apply-head "$GTMP" spec-workflow)"
check "apply-head on a release/none commit is a clean no-op" "none" "$out"
check "no-op leaves the tree clean" "" "$(git -C "$GTMP" status --porcelain)"

rm -rf "$TMP_ROOT" "$GTMP"
