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
for p in config.py validate-config.py next.py ui-hub.py brain.py; do
    if python3 -m py_compile "$PLUGIN/scripts/$p"; then
        echo "ok   py_compile $p"
    else
        echo "FAIL py_compile $p"; fails=$((fails + 1))
    fi
done

echo "== config.py (shared loader) =="
CT="$(mktemp -d)"; mkdir -p "$CT/.claude"
cp "$FIX/valid.project.yaml" "$CT/.claude/project.yaml"
check "yaml dot-path get" "fixture-project" "$(python3 "$PLUGIN/scripts/config.py" "$CT" get project.name)"
check "yaml nested get" "true" "$(python3 "$PLUGIN/scripts/config.py" "$CT" get commands.gate)"
check "path verb resolves yaml" "project.yaml" "$(python3 "$PLUGIN/scripts/config.py" "$CT" path)"
check "json verb emits normalized" '"schemaVersion"' "$(python3 "$PLUGIN/scripts/config.py" "$CT" json)"
check "v2 dev array models get" "claude-haiku-4-5" "$(python3 "$PLUGIN/scripts/config.py" "$CT" get delegation.identities.dev.1.models.1)"
cp "$FIX/valid.project.json" "$CT/.claude/project.json"
check "yaml preferred over json" "project.yaml" "$(python3 "$PLUGIN/scripts/config.py" "$CT" path)"
rm -rf "$CT"
CJ="$(mktemp -d)"; mkdir -p "$CJ/.claude"
cp "$FIX/valid.project.json" "$CJ/.claude/project.json"
check "legacy json deprecation warning" "DEPRECATION" "$(python3 "$PLUGIN/scripts/config.py" "$CJ" json 2>&1 >/dev/null)"
check "legacy path resolves json" "project.json" "$(python3 "$PLUGIN/scripts/config.py" "$CJ" path 2>/dev/null)"
check "legacy devModel -> dev.models[0]" "sonnet" "$(python3 "$PLUGIN/scripts/config.py" "$CJ" get delegation.identities.dev.models.0 2>/dev/null)"
check "legacy reviewModel -> reviewer.models[0]" "sonnet" "$(python3 "$PLUGIN/scripts/config.py" "$CJ" get delegation.identities.reviewer.models.0 2>/dev/null)"
check "PROJECT_CONFIG override" "fixture-project" "$(PROJECT_CONFIG="$FIX/valid.project.yaml" python3 "$PLUGIN/scripts/config.py" "$CJ" get project.name)"
rm -rf "$CJ"

echo "== validate-config =="
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/valid.project.yaml")"
check "valid yaml passes" "VALID: " "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/broken.project.yaml" || true)"
check "broken yaml: schemaVersion 2" "schemaVersion must be 2" "$out"
check "broken yaml: statusFlow option" "'Done' has no matching status option id" "$out"
check "broken yaml: empty priority options" "priority.options is empty" "$out"
check "broken yaml: unknown board ref" "does not match any boards[].id" "$out"
check "broken yaml: unknown blockedBy epic" "unknown epic 'EZ'" "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/shorthand.project.yaml" || true)"
check "v2 shorthand dev model rejected" "'sonnet'" "$out"
check "v2 shorthand reviewer model rejected" "'opus'" "$out"
check "shorthand error names full nomenclature" "full model-id" "$out"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FIX/valid.project.json")"
check "legacy json still VALID" "VALID: " "$out"
check "legacy json deprecation noted" "legacy" "$out"
check "legacy json shorthand allowed (devModel=sonnet)" "VALID: " "$out"
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
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$PLUGIN/templates/project.example.yaml" || true)"
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
check "no config -> setup-project" "PREFLIGHT FAIL: no .claude/project.yaml" "$out"
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
rm -rf "$IT2"

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

echo "== brain (per-identity zettel memory) =="
BT="$(mktemp -d)"
BRAIN="$PLUGIN/scripts/brain.py"
brain() { python3 "$BRAIN" "$BT" "$@"; }

# mint two dev notes; A wikilinks to B
printf 'YAML dumps sort keys unless sort_keys=False.\n\nRelated: [[merge-yaml]]\n' \
    | brain mint dev yaml-key-order --tags yaml,config --paths "scripts/**,**/*.yaml" --source "PR#3 review"
printf 'Merging YAML needs a deep merge, not dict.update.\n' \
    | brain mint dev merge-yaml --tags merge --paths "scripts/merge.sh" --source "PR#4"

# direct hit by path glob → full body injected
out="$(brain recall dev --paths "scripts/foo.sh" --keywords "")"
check "recall direct hit body" "sort_keys=False" "$out"
check "recall direct hit title" "yaml-key-order" "$out"

# spreading activation: only A matches by glob, B surfaces via the A->B link
out="$(brain recall dev --paths "docs/only.yaml" --keywords "")"
check "recall seeds A via glob" "yaml-key-order" "$out"
check "recall propagates to linked B" "merge-yaml" "$out"

# keyword seed (tag intersection)
out="$(brain recall dev --paths "" --keywords "merge")"
check "recall keyword seed" "merge-yaml" "$out"

# budget truncation → titles only, no bodies
out="$(brain recall dev --paths "scripts/foo.sh" --keywords "" --budget 8)"
check "budget truncation keeps a title" "yaml-key-order" "$out"
check_absent "budget truncation drops bodies" "sort_keys=False" "$out"

# graduated note is excluded from injection but still bridges links
brain graduate dev yaml-key-order >/dev/null
out="$(brain recall dev --paths "scripts/foo.sh" --keywords "")"
check_absent "graduated note not injected" "sort_keys=False" "$out"
check "graduated note still bridges to B" "merge-yaml" "$out"

# activation log: every line valid JSON with the frozen contract fields
LOG="$BT/.claude/identities/dev/brain/.activation.jsonl"
out="$(python3 - "$LOG" <<'PY'
import json, sys
seen = set()
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    o = json.loads(line)
    for k in ("ts", "role", "event", "note", "activation"):
        assert k in o, (k, o)
    if o["event"] == "hop":
        assert "link" in o and "->" in o["link"], o
    seen.add(o["event"])
print("events:" + ",".join(sorted(seen)))
PY
)"
check "activation log valid json + fields" "events:" "$out"
check "activation log has seed event" "seed" "$out"
check "activation log has hop event" "hop" "$out"
check "activation log has inject event" "inject" "$out"

# directory lists titles + tags, never bodies
brain directory >/dev/null
out="$(cat "$BT/.claude/identities/DIRECTORY.md")"
check "directory lists a slug" "yaml-key-order" "$out"
check "directory lists tags" "merge" "$out"
check_absent "directory omits bodies" "sort_keys=False" "$out"

# consult: prints the owner's body, logs to the OWNER, recurs on 2nd
printf 'Reviewer rule: verify tests exist before approving.\n' \
    | brain mint reviewer verify-tests --tags review --paths "**/*.test.*" --source "PR#5"
out="$(brain consult dev reviewer verify-tests)"
check "consult prints owner body" "verify tests exist" "$out"
check_absent "consult no recurrence first time" "RECURRENCE" "$out"
out="$(brain consult dev reviewer verify-tests)"
check "consult recurrence on 2nd" "RECURRENCE" "$out"
check "consult recurrence names consumer" "dev's brain" "$out"
out="$(cat "$BT/.claude/identities/reviewer/brain/.activation.jsonl")"
check "consult logged to owner brain" '"event": "consult"' "$out"
check "consult log names consumer" '"consumer": "dev"' "$out"

# finding 1 — budget accounting: joined output (incl. separators) never exceeds the char budget.
# Short slugs so several title-only blocks fit and inter-block separators accumulate (the repro).
for i in 1 2 3 4 5 6 7 8; do
    printf 'body line %s\n' "$i" | brain mint dev "b$i" --tags bud --paths "bud/**" --source x >/dev/null
done
out="$(brain recall dev --paths "bud/x.txt" --keywords "" --budget 5 \
    | python3 -c 'import sys; s=sys.stdin.read().rstrip("\n"); print("WITHIN" if len(s) <= 20 else "OVER:"+str(len(s)))')"
check "budget accounting stays within bound" "WITHIN" "$out"

# finding 2 — consult log lines omit activation; seed/hop/inject carry it
out="$(python3 - "$BT/.claude/identities/dev/brain/.activation.jsonl" "$BT/.claude/identities/reviewer/brain/.activation.jsonl" <<'PY'
import json, sys
ok = True
for path in sys.argv[1:]:
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        o = json.loads(line)
        if o["event"] in ("seed", "hop", "inject"):
            ok = ok and "activation" in o
        if o["event"] == "consult":
            ok = ok and "activation" not in o
            ok = ok and set(o.keys()) == {"ts", "role", "event", "note", "consumer"}
print("FIELD-SETS-OK" if ok else "FIELD-SETS-BAD")
PY
)"
check "consult omits activation; others keep it" "FIELD-SETS-OK" "$out"

# finding 3 — quote-aware frontmatter list parse: a comma-containing tag is not corrupted
printf 'quoted comma tag note.\n' | brain mint dev qtag --tags placeholder --paths "qt/**" --source x >/dev/null
python3 - "$BT" <<'PY'
import os, re, sys
p = os.path.join(sys.argv[1], ".claude/identities/dev/brain/notes/qtag.md")
s = open(p).read()
open(p, "w").write(re.sub(r"tags: .*", 'tags: ["a,b", "c"]', s))
PY
brain directory >/dev/null
out="$(cat "$BT/.claude/identities/DIRECTORY.md")"
check "comma-containing tag survives parse" "a,b" "$out"
check_absent "comma tag not split into fragments" 'b" ' "$out"
# recall still surfaces the note by its intact second tag
out="$(brain recall dev --paths "" --keywords "c")"
check "recall matches note with quoted-comma tag list" "qtag" "$out"

# prune: a never-fired link off an aged note is flagged (isolated pair, never recalled)
printf 'Old stale idea.\n\nRelated: [[stale-dst]]\n' \
    | brain mint dev stale-src --tags stale --paths "nope/**" --source "old"
printf 'Target of the stale link.\n' \
    | brain mint dev stale-dst --tags stale --paths "nope2/**" --source "old"
python3 - "$BT" <<'PY'
import os, re, sys
p = os.path.join(sys.argv[1], ".claude/identities/dev/brain/notes/stale-src.md")
s = open(p).read()
open(p, "w").write(re.sub(r"created: .*", "created: 2020-01-01", s))
PY
brain retro-mark >/dev/null; brain retro-mark >/dev/null; brain retro-mark >/dev/null
out="$(brain prune dev)"
check "prune flags never-fired aged link" "stale-src->stale-dst" "$out"
rm -rf "$BT"

echo "== brain.sh wrapper (flag-less default path, set -u) =="
# Regression: brain.sh WITHOUT --dir/BRAIN_DIR must not die on empty-array expansion under set -u.
# Runs via the wrapper (ROOT from git rev-parse), the path the brain.py tests above never exercise.
BW="$(mktemp -d)"
( cd "$BW" && git init -q . )
out="$(cd "$BW" && printf 'wrapper lesson body.\n' | bash "$PLUGIN/scripts/brain.sh" mint dev wrapper-note --tags w --paths "x/**" --source "test" 2>&1; echo "rc=$?")"
check "brain.sh mint (no --dir) succeeds" "minted dev/wrapper-note" "$out"
check_absent "brain.sh flag-less: no unbound-variable error" "unbound variable" "$out"
check "brain.sh mint (no --dir) exits 0" "rc=0" "$out"
out="$(cd "$BW" && bash "$PLUGIN/scripts/brain.sh" directory 2>&1; echo "rc=$?")"
check "brain.sh directory (no --dir) exits 0" "rc=0" "$out"
check "brain.sh wrote into default .claude/identities" "wrapper-note" "$(cat "$BW/.claude/identities/DIRECTORY.md" 2>/dev/null)"
# BRAIN_DIR override path still works
out="$(cd "$BW" && printf 'override body.\n' | BRAIN_DIR=".claude/custom" bash "$PLUGIN/scripts/brain.sh" mint dev ov-note --tags o --paths "y/**" --source "test" 2>&1; echo "rc=$?")"
check "brain.sh BRAIN_DIR override succeeds" "rc=0" "$out"
out="$([[ -f "$BW/.claude/custom/dev/brain/notes/ov-note.md" ]] && echo FOUND || echo MISSING)"
check "brain.sh BRAIN_DIR override targets custom dir" "FOUND" "$out"
rm -rf "$BW"

echo
if [[ $fails -gt 0 ]]; then echo "$fails test(s) FAILED"; exit 1; fi
echo "all tests passed"
