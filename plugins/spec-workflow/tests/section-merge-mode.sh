#!/usr/bin/env bash
# section-merge-mode.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
echo "== merge-mode (yaml round-trip) =="
MT="$(mktemp -d)"; ( cd "$MT" && git init -q . )
mkdir -p "$MT/.claude"; cp "$FIX/valid.project.yaml" "$MT/.claude/project.yaml"
mm() { (cd "$MT" && bash "$PLUGIN/scripts/merge-mode.sh" "$@"); }
check "set single reviewer model" "claude-opus-4-8" "$(mm model claude-opus-4-8)"
check "status shows reviewer models" "claude-opus-4-8" "$(mm status)"
check "model round-trips in yaml" "claude-opus-4-8" "$(python3 "$PLUGIN/scripts/config.py" "$MT" get delegation.identities.reviewer.models.0)"
mm model "claude-sonnet-5[1m],claude-opus-4-8" >/dev/null
check "csv model -> array elem 2" "claude-opus-4-8" "$(python3 "$PLUGIN/scripts/config.py" "$MT" get delegation.identities.reviewer.models.1)"
check "auto-merge on" "autoMerge: ON" "$(mm on)"
check "status reflects ON" "autoMerge: ON" "$(mm status)"
check "yaml keeps 4-space indent" "    identities:" "$(cat "$MT/.claude/project.yaml")"
check "yaml still parses after edits" "fixture-project" "$(python3 "$PLUGIN/scripts/config.py" "$MT" get project.name)"
# surgical edits must not disturb unrelated bytes: comments + flow style survive on+model round-trip
check "mid-file comment survives" "# --- delegation: agent roster (who codes/reviews, as whom, on which models) ---" "$(cat "$MT/.claude/project.yaml")"
check "commented reviewerTokenEnv survives" "# reviewerTokenEnv: GH_TOKEN_REVIEWER   # second account so auto-merge approvals are non-self" "$(cat "$MT/.claude/project.yaml")"
check "flow-style taskRanges untouched" "taskRanges: [[90, 99]]" "$(cat "$MT/.claude/project.yaml")"
mm method rebase >/dev/null
check "mergeMethod set surgically" "rebase" "$(python3 "$PLUGIN/scripts/config.py" "$MT" get methodology.mergeMethod)"
check "comment still there after method edit" "# reviewerTokenEnv: GH_TOKEN_REVIEWER" "$(cat "$MT/.claude/project.yaml")"
rm -rf "$MT"

echo "== merge-mode preauth =="
PA="$(mktemp -d)"
pa() { (cd "$PA" && bash "$PLUGIN/scripts/merge-mode.sh" "$@"); }

out="$(pa preauth 2>&1)"; rc=$?
check "preauth no settings -> missing" "preauth: missing" "$out"
check_rc "preauth no settings exit code" 1 "$rc"

mkdir -p "$PA/.claude"
cat > "$PA/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash(gh pr merge:*)", "Bash(gh pr review:*)"]}}
EOF
out="$(pa preauth 2>&1)"; rc=$?
check "preauth both rules -> ok" "preauth: ok" "$out"
check_rc "preauth both rules exit code" 0 "$rc"

cat > "$PA/.claude/settings.json" <<'EOF'
{"permissions": {"allow": ["Bash(gh pr merge:*)"]}}
EOF
out="$(pa preauth 2>&1)"; rc=$?
check "preauth one rule -> names absent rule" "missing Bash(gh pr review:*)" "$out"
check_absent "preauth one rule -> present rule not named" "missing Bash(gh pr merge:*)" "$out"
check_rc "preauth one rule exit code" 1 "$rc"

rm "$PA/.claude/settings.json"
cat > "$PA/.claude/settings.local.json" <<'EOF'
{"permissions": {"allow": ["Bash(gh pr merge:*)", "Bash(gh pr review:*)"]}}
EOF
out="$(pa preauth 2>&1)"; rc=$?
check "preauth settings.local.json fallback -> ok" "preauth: ok" "$out"
check_rc "preauth settings.local.json fallback exit code" 0 "$rc"
rm -rf "$PA"

snippet="$(bash "$PLUGIN/scripts/merge-mode.sh" preauth-snippet)"
check "preauth-snippet has merge rule" "Bash(gh pr merge:*)" "$snippet"
check "preauth-snippet has review rule" "Bash(gh pr review:*)" "$snippet"
check "preauth-snippet has comment rule" "Bash(gh pr comment:*)" "$snippet"
check "preauth-snippet has push rule" "Bash(git push:*)" "$snippet"
valid="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print("valid" if "Bash(gh pr merge:*)" in d["permissions"]["allow"] else "invalid")' <<<"$snippet")"
check "preauth-snippet is valid JSON with the rules" "valid" "$valid"

