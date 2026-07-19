#!/usr/bin/env bash
# section-identity.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== identity resolution =="
T3="$(mktemp -d)"
( cd "$T3" && git init -q . && git config user.name "Test User" && git config user.email "test.user@example.com" )
run_id() { (cd "$T3" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$PLUGIN/scripts/identity.sh" "$@"); }
check "default reviewer email plus-addressed" "test.user+reviewer_agent@example.com" "$(run_id reviewer)"
check "default reviewer name templated" "Reviewer Agent - Test User" "$(run_id reviewer)"
check "flags line quoted" '-c user.name="Reviewer Agent - Test User"' "$(run_id reviewer)"
check "default peer-reviewer email plus-addressed" "test.user+peer_reviewer@example.com" "$(run_id peer-reviewer)"
check "default peer-reviewer name templated" "Peer Reviewer (codex) - Test User" "$(run_id peer-reviewer)"
check "check mode resolvable" "identities ok: 4 role(s)" "$(run_id --check)"
mkdir -p "$T3/.claude"
echo '{"delegation":{"identities":{"dev":null,"reviewer":{"name":"{name} - reviewer"}}}}' >"$T3/.claude/project.json"
check "null role reports OFF" "OFF (identities.dev is null" "$(run_id dev)"
check "name override keeps default email" "test.user+reviewer_agent@example.com" "$(run_id reviewer)"
check "name override applied" "Test User - reviewer" "$(run_id reviewer)"
echo '{"delegation":{"identities":false}}' >"$T3/.claude/project.json"
check "identities=false disables all" "OFF for all roles" "$(run_id --check)"
rm "$T3/.claude/project.json"
( cd "$T3" && git config --unset user.name )
check "missing git name warns" "IDENTITY WARN" "$(run_id --check)"
check "unresolved role reported" "UNRESOLVED" "$(run_id reviewer || true)"
rm -rf "$T3"

echo "== identity: covers routing + models (v2 yaml) =="
IT="$(mktemp -d)"
( cd "$IT" && git init -q . && git config user.name "Test User" && git config user.email "test.user@example.com" )
mkdir -p "$IT/.claude"; cp "$FIX/valid.project.yaml" "$IT/.claude/project.yaml"
rid() { (cd "$IT" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$PLUGIN/scripts/identity.sh" "$@"); }
check "covers routes core path to core dev" "Core Dev - Test User" "$(rid dev packages/core/index.ts)"
check "core dev models line" "models: claude-sonnet-5" "$(rid dev packages/core/index.ts)"
check "core dev email suffix" "test.user+dev_core@example.com" "$(rid dev packages/core/index.ts)"
check "non-core path falls back to dev agent" "Dev Agent - Test User" "$(rid dev packages/web/app.ts)"
check "fallback dev models line" "models: claude-sonnet-5, claude-haiku-4-5" "$(rid dev packages/web/app.ts)"
check "reviewer models line" "models: claude-sonnet-5, claude-sonnet-5[1m]" "$(rid reviewer)"
check "array role no path lists identities" "id: Core Dev - Test User" "$(rid dev)"
check "array role lists second identity" "id: Dev Agent - Test User" "$(rid dev)"
rm -rf "$IT"

echo "== identity: default models (no config) =="
IT2="$(mktemp -d)"
( cd "$IT2" && git init -q . && git config user.name "Test User" && git config user.email "test.user@example.com" )
rid2() { (cd "$IT2" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$PLUGIN/scripts/identity.sh" "$@"); }
check "default dev models" "models: claude-sonnet-5" "$(rid2 dev)"
check "default reviewer models" "models: claude-sonnet-5, claude-sonnet-5[1m]" "$(rid2 reviewer)"
check_absent "orchestrator has no models default" "models:" "$(rid2 orchestrator)"
check_absent "peer-reviewer has no models default" "models:" "$(rid2 peer-reviewer)"
rm -rf "$IT2"

echo "== identity: on-behalf recipe =="
OB="$(mktemp -d)"
( cd "$OB" && git init -q . && git config user.name "Test User" && git config user.email "test.user@example.com" )
mkdir -p "$OB/.claude"; cp "$FIX/valid.project.yaml" "$OB/.claude/project.yaml"
rob() { (cd "$OB" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$PLUGIN/scripts/identity.sh" on-behalf "$@"); }
out="$(rob dev --co reviewer)"
check "on-behalf committer defaults to orchestrator" '-c user.name="Orchestrator Agent - Test User" -c user.email="test.user+orchestrator_agent@example.com"' "$out"
check "on-behalf author flag = dev" '--author="Dev Agent - Test User <test.user+dev_agent@example.com>"' "$out"
check "on-behalf co trailer = reviewer" "Co-authored-by: Reviewer Agent - Test User <test.user+reviewer_agent@example.com>" "$out"
out="$(rob dev --committer reviewer --co orchestrator)"
check "on-behalf explicit committer" '-c user.name="Reviewer Agent - Test User" -c user.email="test.user+reviewer_agent@example.com"' "$out"
out="$(rob orchestrator --co dev --co reviewer)"
check "on-behalf repeated --co (dev)" "Co-authored-by: Dev Agent - Test User" "$out"
check "on-behalf repeated --co (reviewer)" "Co-authored-by: Reviewer Agent - Test User" "$out"
out="$(rob dev --co dev)"
check_absent "on-behalf drops co duplicate of author" "Co-authored-by: Dev Agent" "$out"
out="$(rob dev --co orchestrator)"
check_absent "on-behalf drops co equal to committer" "Co-authored-by: Orchestrator Agent" "$out"
out="$(rob nope 2>&1 || true)"
check "on-behalf unknown role errors" "unknown role 'nope'" "$out"
out="$(rob dev --committer ghost 2>&1 || true)"
check "on-behalf unknown committer errors" "unknown role 'ghost'" "$out"
rm "$OB/.claude/project.yaml"
echo '{"delegation":{"identities":{"dev":null}}}' > "$OB/.claude/project.json"
out="$(rob dev 2>&1 || true)"
check "on-behalf OFF role errors" "role 'dev' is OFF" "$out"
echo '{"delegation":{"identities":false}}' > "$OB/.claude/project.json"
out="$(rob orchestrator 2>&1 || true)"
check "on-behalf all-OFF errors" "delegation.identities is false" "$out"
rm -rf "$OB"

echo "== identity: on-behalf recipe — EXECUTED against a scratch repo (not just text-matched) =="
# A text-only match on the printed recipe is what let SW-65 ship: `flags:`
# combined a global `-c` option with `--author` (a `git commit`-only option),
# so the documented `git <paste flags line> commit ...` template failed with
# "unknown option: --author" the moment anyone actually ran it. These cases
# build the recipe into a real command line the way the documented template
# does, then RUN it, so a future paste-order regression fails here again.
exec_recipe() { # repo-dir  <on-behalf args...>  -- runs the printed recipe as
    # a real commit in repo-dir; sets EXEC_RC/EXEC_OUT for the caller.
    local repo="$1"; shift
    local out flags cflags trailers_block subject script
    out="$(robx "$@")"
    flags="$(sed -n 's/^flags: //p' <<<"$out")"
    cflags="$(sed -n 's/^commit-flags: //p' <<<"$out")"
    trailers_block="$(sed -n '/^trailers:$/,$p' <<<"$out" | tail -n +2)"
    [[ "$trailers_block" == "(none)" ]] && trailers_block=""
    subject="on-behalf test commit"
    script="$repo/.exec-recipe.sh"
    {
        echo "cd \"$repo\" || exit 1"
        echo "echo x >> file.txt && git add file.txt"
        # This is the template from auto-review.md §Commit identities (b),
        # verbatim: `git <flags> commit <commit-flags> -m "$(cat <<'EOF' ...)"`.
        # shellcheck disable=SC2016  # single-quoted heredoc delimiter is intentional here
        printf 'git %s commit %s -m "$(cat <<'"'"'EOF'"'"'\n' "$flags" "$cflags"
        printf '%s\n\n' "$subject"
        printf '%s\n' "$trailers_block"
        printf 'EOF\n)"\n'
    } >"$script"
    EXEC_OUT="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$script" 2>&1)"
    EXEC_RC=$?
    [[ "$EXEC_RC" -ne 0 ]] && echo "     exec_recipe failed: $EXEC_OUT" >&2
    rm -f "$script"
}

OBX="$(mktemp -d)"
( cd "$OBX" && git init -q . && git config user.name "Test User" && git config user.email "test.user@example.com" )
mkdir -p "$OBX/.claude"; cp "$FIX/valid.project.yaml" "$OBX/.claude/project.yaml"
robx() { (cd "$OBX" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$PLUGIN/scripts/identity.sh" on-behalf "$@"); }

exec_recipe "$OBX" dev --co reviewer
check_rc "executed on-behalf dev --co reviewer: recipe runs cleanly" 0 "$EXEC_RC"
last="$(cd "$OBX" && git log -1 --format='author=%an <%ae>%ncommitter=%cn <%ce>%n%B')"
check "executed recipe: author is dev" "author=Dev Agent - Test User <test.user+dev_agent@example.com>" "$last"
check "executed recipe: committer defaults to orchestrator" "committer=Orchestrator Agent - Test User <test.user+orchestrator_agent@example.com>" "$last"
check "executed recipe: reviewer co-author trailer lands in the commit" "Co-authored-by: Reviewer Agent - Test User <test.user+reviewer_agent@example.com>" "$last"

exec_recipe "$OBX" dev --co reviewer --committer reviewer
check_rc "executed on-behalf dev --co reviewer --committer reviewer: recipe runs cleanly" 0 "$EXEC_RC"
last="$(cd "$OBX" && git log -1 --format='author=%an <%ae>%ncommitter=%cn <%ce>')"
check "executed recipe: explicit committer applied" "committer=Reviewer Agent - Test User <test.user+reviewer_agent@example.com>" "$last"
check "executed recipe: author still dev" "author=Dev Agent - Test User <test.user+dev_agent@example.com>" "$last"

# Hostile name (spaces + a double quote) — must survive an actual shell
# execution of the recipe, not just appear correctly in printed text.
# project.json takes effect only once project.yaml is out of the way (yaml
# wins resolution order in config.py).
rm -f "$OBX/.claude/project.yaml"
echo '{"delegation":{"identities":{"dev":{"name":"Weird \"Dev\" Name","email":"weird.dev@example.com"}}}}' >"$OBX/.claude/project.json"
exec_recipe "$OBX" dev --co reviewer
check_rc "executed on-behalf with a hostile quoted name: recipe runs cleanly" 0 "$EXEC_RC"
last="$(cd "$OBX" && git log -1 --format='author=%an <%ae>')"
check 'executed recipe: hostile quoted name lands intact as author' 'author=Weird "Dev" Name <weird.dev@example.com>' "$last"
rm -f "$OBX/.claude/project.json"
rm -rf "$OBX"

echo "== identity_lib.normalize_models (CDX-020, #185) -- standalone, not yet wired into resolve_role =="
out="$(python3 - "$PLUGIN/scripts" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import identity_lib as IL

assert IL.normalize_models(None) == ([], None, None), IL.normalize_models(None)
assert IL.normalize_models(["claude-sonnet-5", "claude-sonnet-5[1m]"]) == (
    ["claude-sonnet-5", "claude-sonnet-5[1m]"], None, None
), IL.normalize_models(["claude-sonnet-5", "claude-sonnet-5[1m]"])
assert IL.normalize_models({"claude": ["claude-sonnet-5"], "codex": {"capability": "balanced"}}) == (
    ["claude-sonnet-5"], "balanced", None
), IL.normalize_models({"claude": ["claude-sonnet-5"], "codex": {"capability": "balanced"}})
claude, cap, err = IL.normalize_models({"claude": ["claude-sonnet-5"], "codex": {"capability": "super-fast"}})
assert not claude and cap is None, (claude, cap, err)
assert err, "expected a non-empty error for an unrecognized capability value, not a silent default"
assert "super-fast" in err, err
print("OK")
PY
)"
check "normalize_models: None / legacy list / dict-with-capability / bad-capability contract" "OK" "$out"

echo "== identity: --host codex model selection (CDX-021, #186) =="
CDX="$(mktemp -d)"
( cd "$CDX" && git init -q . && git config user.name "Test User" && git config user.email "test.user@example.com" )
mkdir -p "$CDX/.claude"
cat > "$CDX/.claude/project.json" <<'EOF'
{"delegation":{"identities":{"dev":{"models":{"claude":["claude-sonnet-5","claude-sonnet-5[1m]"],"codex":{"capability":"balanced"}}}}}}
EOF
rcx() { (cd "$CDX" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$PLUGIN/scripts/identity.sh" "$@"); }
out="$(rcx --host codex dev)"
check "host codex shows codex-capability line" "codex-capability: balanced" "$out"
check_absent "host codex output has zero Claude model id (bare)" "claude-sonnet-5" "$out"
check_absent "host codex output has zero Claude model id ([1m])" "claude-sonnet-5[1m]" "$out"
check_absent "host codex never prints a models: line" "models:" "$out"
out="$(rcx dev)"
check "omitted --host is byte-identical to pre-CDX-021: models line present" "models: claude-sonnet-5, claude-sonnet-5[1m]" "$out"
check_absent "omitted --host never shows codex-capability" "codex-capability:" "$out"

rm -f "$CDX/.claude/project.json"
cat > "$CDX/.claude/project.json" <<'EOF'
{"delegation":{"identities":{"dev":{"models":["claude-sonnet-5"]}}}}
EOF
out="$(rcx --host codex dev)"
check "host codex with legacy array models: unset host default" "codex-capability: (unset — host default)" "$out"
check_absent "host codex with legacy array models: zero Claude id leak" "claude-sonnet-5" "$out"

rm -f "$CDX/.claude/project.json"
cat > "$CDX/.claude/project.json" <<'EOF'
{"delegation":{"identities":{"dev":{"models":{"claude":["claude-sonnet-5"],"codex":{"capability":"super-fast"}}}}}}
EOF
out="$(rcx --host codex dev 2>&1 || true)"
check "host codex bad capability surfaces normalizer error" "UNRESOLVED" "$out"
check "host codex bad capability error names the bad value" "super-fast" "$out"
rm -rf "$CDX"

echo "== identity: --host codex regression -- covers/on-behalf/naming unaffected =="
IT3="$(mktemp -d)"
( cd "$IT3" && git init -q . && git config user.name "Test User" && git config user.email "test.user@example.com" )
mkdir -p "$IT3/.claude"; cp "$FIX/valid.project.yaml" "$IT3/.claude/project.yaml"
rid3() { (cd "$IT3" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$PLUGIN/scripts/identity.sh" "$@"); }
check "host codex: covers routing unchanged (core path)" "Core Dev - Test User" "$(rid3 --host codex dev packages/core/index.ts)"
check "host codex: covers routing unchanged (email)" "test.user+dev_core@example.com" "$(rid3 --host codex dev packages/core/index.ts)"
check "host codex: fallback routing unchanged (non-core path)" "Dev Agent - Test User" "$(rid3 --host codex dev packages/web/app.ts)"
check "host codex: multi-identity listing unchanged" "id: Core Dev - Test User" "$(rid3 --host codex dev)"
rm -rf "$IT3"

