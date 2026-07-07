#!/usr/bin/env bash
# run-tests.sh — hermetic tests for the spec-workflow plugin (no gh/network needed).
# Used by CI and runnable locally: bash plugins/spec-workflow/tests/run-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname "$HERE")"
FIX="$HERE/fixtures"
fails=0

check() { # name  expected-substring  actual-output
    if grep -qF -- "$2" <<<"$3"; then
        echo "ok   $1"
    else
        echo "FAIL $1 — expected to contain: $2"
        echo "     got: $(head -3 <<<"$3")"
        fails=$((fails + 1))
    fi
}

check_absent() { # name  forbidden-substring  actual-output
    if grep -qF -- "$2" <<<"$3"; then
        echo "FAIL $1 — must NOT contain: $2"
        fails=$((fails + 1))
    else
        echo "ok   $1"
    fi
}

echo "== syntax =="
for f in "$PLUGIN"/scripts/*.sh "$HERE"/run-tests.sh; do
    if bash -n "$f"; then echo "ok   bash -n $(basename "$f")"; else echo "FAIL bash -n $f"; fails=$((fails + 1)); fi
done
for p in validate-config.py next.py ui-hub.py; do
    if python3 -m py_compile "$PLUGIN/scripts/$p"; then
        echo "ok   py_compile $p"
    else
        echo "FAIL py_compile $p"; fails=$((fails + 1))
    fi
done

echo "== validate-config =="
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/valid.project.json")"
check "valid fixture passes" "VALID: " "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/broken.project.json" || true)"
check "broken: schemaVersion" "schemaVersion must be 1" "$out"
check "broken: statusFlow option" "'Done' has no matching status option id" "$out"
check "broken: empty priority options" "priority.options is empty" "$out"
check "broken: bad taskPrefix" "must be alphanumeric starting with a letter" "$out"
check "broken: unknown board ref" "does not match any boards[].id" "$out"
check "broken: overlapping ranges" "overlaps epic" "$out"
check "broken: unknown blockedBy epic" "unknown epic 'EZ'" "$out"
check "broken: bad untilStatus" "not in statusFlow" "$out"
check "broken: missing gate" "missing required key 'gate'" "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$PLUGIN/templates/project.example.json" || true)"
check "template rejected (placeholders)" "template placeholder" "$out"

echo "== next.py (picker) =="
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.json" "" "$FIX/items.sample.json")"
check "bug preempts features" "=> PICK: #99" "$out"
check "guard blocks E1" "BLOCKED #10 FX-010: link endpoint  (epic E0 not fully Deployed)" "$out"
check "P0 candidate listed" "#2  [P0]  FX-002" "$out"
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.json" "" "$FIX/items.wip.json")"
check "wip resume guard" "=> RESUME: #2  FX-002: auth model" "$out"
check_absent "wip: no new pick" "=> PICK:" "$out"

echo "== preflight =="
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
( cd "$T" && git init -q . )
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh" --spec)"
check "no config -> setup-project" "PREFLIGHT FAIL: no .claude/project.json" "$out"
mkdir -p "$T/.claude" && cp "$FIX/valid.project.json" "$T/.claude/project.json"
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh" --spec)"
check "missing spec file -> craft-spec" "spec file(s) missing: SPEC.md" "$out"
touch "$T/SPEC.md"
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh" --spec)"
check "config + spec ok" "preflight ok: config + 1 spec(s) present" "$out"
out="$(cd "$T" && bash "$PLUGIN/scripts/preflight.sh")"
check "config-only ok" "preflight ok: config present" "$out"

echo "== ui-hub (lifecycle on a scratch port) =="
_hubtmp="$(mktemp -d)"
export UI_HUB_STATE="$_hubtmp/hub" UI_HUB_PORT=4799
HUB="$PLUGIN/scripts/ui-hub.py"
out="$(python3 "$HUB" start)";                        check "hub starts" "RUNNING http://127.0.0.1:4799" "$out"
echo '<h1>d</h1>' > "$UI_HUB_STATE/d.html"
out="$(python3 "$HUB" ask d1 "T" "$UI_HUB_STATE/d.html" --blocking)"; check "hub ask" "asked 'd1'" "$out"
out="$(curl -sf http://127.0.0.1:4799/api/state)";    check "hub state has pending" '"id": "d1"' "$out"
out="$(curl -sf -X POST http://127.0.0.1:4799/api/answer -H 'Content-Type: application/json' -d '{"id":"d1","selection":"- Use: Option A"}')"
check "hub answer accepted" '"ok": true' "$out"
out="$(python3 "$HUB" answers --consume)";            check "hub answer collected" "Use: Option A" "$out"
out="$(python3 "$HUB" answers)";                      check_absent "hub consume archived it" "d1" "$out"
python3 "$HUB" stop >/dev/null
unset UI_HUB_STATE UI_HUB_PORT

echo "== gate enforcement (gate.sh + guard-board-move hook) =="
T3="$(mktemp -d)"
( cd "$T3" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$T3/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3/.claude/project.json"
hookjson() { printf '{"tool_input":{"command":"%s"}}' "$1"; }
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "move blocked without pass" "BLOCKED: no recorded gate pass" "$out"
check "block exit code 2" "rc=2" "$out"
out="$(cd "$T3" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "gate pass recorded" "GATE PASS recorded" "$out"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "move allowed with fresh pass" "rc=0" "$out"
echo dirty > "$T3/file.txt" && (cd "$T3" && git add file.txt)
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "stale pass re-blocked after edit" "tree changed since the last recorded gate pass" "$out"
out="$(hookjson 'bash board.sh move 7 QA' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "non-review moves unaffected" "rc=0" "$out"
out="$(hookjson 'ls -la' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "unrelated commands unaffected" "rc=0" "$out"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="false"; json.dump(c,open(sys.argv[1],"w"))' "$T3/.claude/project.json"
out="$( (cd "$T3" && bash "$PLUGIN/scripts/gate.sh") 2>&1; echo "rc=$?")"
check "red gate clears pass" "GATE RED" "$out"
if [[ ! -f "$T3/.claude/gate-pass" ]]; then echo "ok   pass file removed on red"; else echo "FAIL pass file should be removed"; fails=$((fails+1)); fi
rm -rf "$T3"

echo "== session-start hook =="
T4="$(mktemp -d)"
( cd "$T4" && git init -q . )
out="$(cd "$T4" && bash "$PLUGIN/scripts/session-start.sh"; echo "rc=$?")"
check "silent without config" "rc=0" "$out"
check_absent "no output without config" "spec-workflow is active" "$out"
mkdir -p "$T4/.claude" && cp "$FIX/valid.project.json" "$T4/.claude/project.json" && echo reason > "$T4/.claude/CHECKPOINT"
out="$(cd "$T4" && bash "$PLUGIN/scripts/session-start.sh")"
check "announces project" "spec-workflow is active for 'fixture-project'" "$out"
check "announces paused loop" "CHECKPOINT flag is present" "$out"
rm -rf "$T4"

echo "== init-config (fake gh) =="
G="$(mktemp -d)"
cat >"$G/gh" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
    "project view") echo '{"id":"PVT_live1234567890","number":7,"title":"Fixture"}' ;;
    "project field-list") cat <<'EOF'
{"fields":[
  {"id":"PVTSSF_liveStatus","name":"Status","type":"ProjectV2SingleSelectField","options":[
    {"id":"s1","name":"Backlog"},{"id":"s2","name":"In progress"},{"id":"s3","name":"In review"},
    {"id":"s4","name":"QA"},{"id":"s5","name":"Ready"},{"id":"s6","name":"Deployed"}]},
  {"id":"PVTSSF_livePrio","name":"Priority","type":"ProjectV2SingleSelectField","options":[
    {"id":"p1","name":"P0"},{"id":"p2","name":"P1"},{"id":"p3","name":"P2"}]},
  {"id":"PVTF_liveEst","name":"Estimate","type":"ProjectV2Field"}]}
EOF
    ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$G/gh"
T2="$(mktemp -d)"
( cd "$T2" && git init -q . )
out="$(cd "$T2" && PATH="$G:$PATH" bash "$PLUGIN/scripts/init-config.sh" fixture-owner fixture-owner/repo 7)"
check "fresh config created" "created " "$out"
check "projectId captured" "PVT_live1234567890" "$out"
out="$(python3 -c "
import json
c = json.load(open('$T2/.claude/project.json'))
b = c['boards'][0]
assert b['projectId'] == 'PVT_live1234567890', b['projectId']
assert b['fields']['status']['options']['In review'] == 's3'
assert list(b['fields']['priority']['options']) == ['P0', 'P1', 'P2']
assert b['statusFlow'][0] == 'Backlog' and b['statusFlow'][-1] == 'Deployed'
assert b['fields']['estimate']['fieldId'] == 'PVTF_liveEst'
print('config-contents-ok')")"
check "config contents correct" "config-contents-ok" "$out"
out="$(cd "$T2" && PATH="$G:$PATH" bash "$PLUGIN/scripts/init-config.sh" fixture-owner fixture-owner/repo 7)"
check "existing config updated (idempotent)" "updated " "$out"
rm -rf "$G" "$T2"

echo "== identity resolution =="
T3="$(mktemp -d)"
( cd "$T3" && git init -q . && git config user.name "Test User" && git config user.email "test.user@example.com" )
run_id() { (cd "$T3" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$PLUGIN/scripts/identity.sh" "$@"); }
check "default reviewer email plus-addressed" "test.user+reviewer_agent@example.com" "$(run_id reviewer)"
check "default reviewer name templated" "Reviewer Agent - Test User" "$(run_id reviewer)"
check "flags line quoted" '-c user.name="Reviewer Agent - Test User"' "$(run_id reviewer)"
check "check mode resolvable" "identities ok: 3 role(s)" "$(run_id --check)"
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

echo
if [[ $fails -gt 0 ]]; then echo "$fails test(s) FAILED"; exit 1; fi
echo "all tests passed"
