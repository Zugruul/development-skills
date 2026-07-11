#!/usr/bin/env bash
# section-merge-mode.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
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

echo "== merge-mode requirements (GitHub branch protection / rulesets probe — #85) =="
# Fake gh understands only `api <path>`; every invocation increments
# FAKE_GH_CALLCOUNT so tests can prove the cache avoids a second call.
_rqsetup() { # -> sets RQ (fixture repo dir) and FGH2 (fake-gh dir on PATH)
    RQ="$(mktemp -d)"; mkdir -p "$RQ/.claude"
    cp "$FIX/valid.project.yaml" "$RQ/.claude/project.yaml"
    FGH2="$(mktemp -d)"
    cat >"$FGH2/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
n=$(( $(cat "$FAKE_GH_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FAKE_GH_CALLCOUNT"
case "$1" in
    api)
        case "$2" in
            */protection/required_pull_request_reviews)
                case "${FAKE_GH_PROTECTION_MODE:-404}" in
                    404) echo "gh: Branch not protected (HTTP 404: Not Found)" >&2; exit 1 ;;
                    required) echo '{"required_approving_review_count":1}' ;;
                    error) echo "gh: connection reset by peer" >&2; exit 1 ;;
                esac
                ;;
            */rules/branches/*)
                case "${FAKE_GH_RULES_MODE:-empty}" in
                    empty) echo '[]' ;;
                    zero-count) echo '[{"type":"pull_request","parameters":{"required_approving_review_count":0}}]' ;;
                    required) echo '[{"type":"pull_request","parameters":{"required_approving_review_count":2}}]' ;;
                esac
                ;;
            *) echo "fake gh: unexpected api path: $2" >&2; exit 1 ;;
        esac
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
    chmod +x "$FGH2/gh"
}

# (1) no branch protection, no matching ruleset -> none
_rqsetup
CC="$(mktemp)"; echo 0 >"$CC"
out="$(cd "$RQ" && PATH="$FGH2:$PATH" FAKE_GH_CALLCOUNT="$CC" FAKE_GH_PROTECTION_MODE=404 \
    bash "$PLUGIN/scripts/merge-mode.sh" requirements 2>&1)"
check "requirements: no protection/ruleset -> none" "requirements: none" "$out"
rm -rf "$RQ" "$FGH2" "$CC"

# (1b) a pull_request ruleset rule is PRESENT but requires 0 approvals -> none
# (a rule matched by TYPE ALONE, ignoring required_approving_review_count, is
# a false positive: PRs-required-but-zero-approvals is not formal review).
_rqsetup
CC="$(mktemp)"; echo 0 >"$CC"
out="$(cd "$RQ" && PATH="$FGH2:$PATH" FAKE_GH_CALLCOUNT="$CC" FAKE_GH_PROTECTION_MODE=404 FAKE_GH_RULES_MODE=zero-count \
    bash "$PLUGIN/scripts/merge-mode.sh" requirements 2>&1)"
check "requirements: pull_request rule present with 0 required approvals -> none" "requirements: none" "$out"
rm -rf "$RQ" "$FGH2" "$CC"

# (1c) a pull_request ruleset rule requiring >=1 approvals -> formal-review-required
_rqsetup
CC="$(mktemp)"; echo 0 >"$CC"
out="$(cd "$RQ" && PATH="$FGH2:$PATH" FAKE_GH_CALLCOUNT="$CC" FAKE_GH_PROTECTION_MODE=404 FAKE_GH_RULES_MODE=required \
    bash "$PLUGIN/scripts/merge-mode.sh" requirements 2>&1)"
check "requirements: pull_request rule requiring approvals -> formal-review-required" "requirements: formal-review-required" "$out"
rm -rf "$RQ" "$FGH2" "$CC"

# (2) branch protection requires approving reviews -> formal-review-required
_rqsetup
CC="$(mktemp)"; echo 0 >"$CC"
out="$(cd "$RQ" && PATH="$FGH2:$PATH" FAKE_GH_CALLCOUNT="$CC" FAKE_GH_PROTECTION_MODE=required \
    bash "$PLUGIN/scripts/merge-mode.sh" requirements 2>&1)"
check "requirements: protection required -> formal-review-required" "requirements: formal-review-required" "$out"
rm -rf "$RQ" "$FGH2" "$CC"

# (3) gh call itself fails (not a 404) -> unknown, with a reason
_rqsetup
CC="$(mktemp)"; echo 0 >"$CC"
out="$(cd "$RQ" && PATH="$FGH2:$PATH" FAKE_GH_CALLCOUNT="$CC" FAKE_GH_PROTECTION_MODE=error \
    bash "$PLUGIN/scripts/merge-mode.sh" requirements 2>&1)"
check "requirements: gh failure -> unknown" "requirements: unknown" "$out"
rm -rf "$RQ" "$FGH2" "$CC"

# (4) cache file written on first probe, reused (no second gh call) on the next
_rqsetup
CC="$(mktemp)"; echo 0 >"$CC"
out1="$(cd "$RQ" && PATH="$FGH2:$PATH" FAKE_GH_CALLCOUNT="$CC" FAKE_GH_PROTECTION_MODE=404 \
    bash "$PLUGIN/scripts/merge-mode.sh" requirements 2>&1)"
check "requirements: first probe -> none" "requirements: none" "$out1"
if [[ -f "$RQ/.claude/merge-requirements.json" ]]; then
    echo "ok   requirements: cache file written"
else
    echo "FAIL requirements: cache file not written"; fails=$((fails + 1))
fi
callcount1="$(cat "$CC")"
# Flip the fake gh's answer -- if the cache were bypassed this would flip the verdict too.
out2="$(cd "$RQ" && PATH="$FGH2:$PATH" FAKE_GH_CALLCOUNT="$CC" FAKE_GH_PROTECTION_MODE=required \
    bash "$PLUGIN/scripts/merge-mode.sh" requirements 2>&1)"
callcount2="$(cat "$CC")"
check "requirements: cached verdict reused (not re-probed)" "requirements: none" "$out2"
if [[ "$callcount1" -eq "$callcount2" ]]; then
    echo "ok   requirements: cache hit made no additional gh call ($callcount1 == $callcount2)"
else
    echo "FAIL requirements: cache hit made additional gh call(s) ($callcount1 -> $callcount2)"
    fails=$((fails + 1))
fi

# (5) --refresh forces a fresh probe even with a warm cache
out3="$(cd "$RQ" && PATH="$FGH2:$PATH" FAKE_GH_CALLCOUNT="$CC" FAKE_GH_PROTECTION_MODE=required \
    bash "$PLUGIN/scripts/merge-mode.sh" requirements --refresh 2>&1)"
callcount3="$(cat "$CC")"
check "requirements --refresh: re-probes and picks up the new verdict" "requirements: formal-review-required" "$out3"
if [[ "$callcount3" -gt "$callcount2" ]]; then
    echo "ok   requirements --refresh made a fresh gh call ($callcount2 -> $callcount3)"
else
    echo "FAIL requirements --refresh did not re-probe ($callcount2 -> $callcount3)"
    fails=$((fails + 1))
fi
rm -rf "$RQ" "$FGH2" "$CC"

