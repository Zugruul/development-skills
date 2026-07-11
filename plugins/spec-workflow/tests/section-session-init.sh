#!/usr/bin/env bash
# section-session-init.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
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
check "fresh config is yaml" "project.yaml" "$out"
check "projectId captured" "PVT_live1234567890" "$out"
out="$(python3 -c "
import yaml
c = yaml.safe_load(open('$T2/.claude/project.yaml'))
b = c['boards'][0]
assert c['schemaVersion'] == 2, c['schemaVersion']
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

