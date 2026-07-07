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

check_rc() { # name  expected-exit-code  actual-exit-code
    if [[ "$2" -eq "$3" ]]; then
        echo "ok   $1"
    else
        echo "FAIL $1 — expected exit $2, got $3"
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
for p in config.py identity_lib.py validate-config.py next.py similar.py ui-hub.py brain.py neural-view.py feedback.py telemetry.py; do
    if python3 -m py_compile "$PLUGIN/scripts/$p"; then
        echo "ok   py_compile $p"
    else
        echo "FAIL py_compile $p"; fails=$((fails + 1))
    fi
done
# anti-pattern: a .py script invoked via `bash` in a skill doc — dies parsing the docstring
# shellcheck disable=SC2016  # single quotes are intentional: this is a grep pattern, not a shell expansion
bad_invocations="$(grep -rn 'bash "\${CLAUDE_PLUGIN_ROOT}/scripts/[^"]*\.py"' "$PLUGIN"/skills/ 2>/dev/null || true)"
if [[ -z "$bad_invocations" ]]; then
    echo "ok   no skill invokes a .py script via bash"
else
    echo "FAIL skill(s) invoke a .py script via bash (must be python3):"
    echo "$bad_invocations"
    fails=$((fails + 1))
fi

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

echo "== similar.py (dedup/similarity) =="
SIM="$PLUGIN/scripts/similar.py"
export SIMILAR_ISSUES_FILE="$FIX/issues.sample.json"

out="$(python3 "$SIM" "$HERE" "Add dark mode toggle to settings page")"
first_line="$(head -1 <<<"$out")"
check "exact title match: #21 is top-ranked" "#21" "$first_line"
check "exact title match: high tier" "high" "$first_line"

out="$(python3 "$SIM" "$HERE" "I want to add a dark theme toggle option on the settings screen")"
first_line="$(head -1 <<<"$out")"
check "paraphrase match: #21 is top-ranked" "#21" "$first_line"
check_absent "paraphrase match: not low tier" $'low\t' "$first_line"
unrelated="$(grep -E '#22|#23' <<<"$out" || true)"
check_absent "paraphrase match: unrelated issues not high tier" $'high\t' "$unrelated"
check_absent "paraphrase match: unrelated issues not medium tier" $'medium\t' "$unrelated"

out="$(python3 "$SIM" "$HERE" "refactor database connection pooling for performance"; echo "rc=$?")"
check "no-match query: exits 0" "rc=0" "$out"
check_absent "no-match query: no high tier" $'high\t' "$out"
check_absent "no-match query: no medium tier" $'medium\t' "$out"

export SIMILAR_ISSUES_FILE="$FIX/issues.control-chars.json"
out="$(python3 "$SIM" "$HERE" "weird title with control chars")"
lines="$(wc -l <<<"$out" | tr -d ' ')"
check "control chars in title: single-line output" "1" "$lines"
fields="$(awk -F'\t' '{print NF; exit}' <<<"$out")"
check "control chars in title: 5 tab-separated fields" "5" "$fields"

unset SIMILAR_ISSUES_FILE

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

echo "== neural-view boot crash + favicon + 3D template contract =="
NVHTML="$PLUGIN/templates/neural-view.html"
NVVENDOR_SHA="86bcee248b64f44bcfc23c331ae74619061957d59cab040171dcb6fb5900beb6"
check_absent "resize() no longer assigns read-only canvas.clientWidth" "canvas.clientWidth =" "$(cat "$NVHTML")"
check_absent "resize() no longer assigns read-only canvas.clientHeight" "canvas.clientHeight =" "$(cat "$NVHTML")"
check_absent "template has no CDN/external script or asset references" 'src="http' "$(cat "$NVHTML")"
check "template's importmap points three at the vendored, same-origin file" '"three":"/vendor/three.module.min.js"' "$(cat "$NVHTML")"
check "template imports three via the importmap specifier, not a URL" 'from "three"' "$(cat "$NVHTML")"
check "template wires an ambient directional pulse sprite per synapse link" 'kind:"synapsePulse"' "$(cat "$NVHTML")"
check "ambient synapse pulses are gated by the reduced-motion check" "if(!REDUCED){" "$(cat "$NVHTML")"
check "ambient pulse position is interpolated from the link's live endpoints (l.a/l.b), not a cached copy" "l.pulse.position.set(l.a.x+(l.b.x-l.a.x)*p, l.a.y+(l.b.y-l.a.y)*p, l.a.z+(l.b.z-l.a.z)*p)" "$(cat "$NVHTML")"
check "template has a tooltip DOM element for hover inspection" 'id="tooltip"' "$(cat "$NVHTML")"
check "tooltip is positioned fixed and never intercepts pointer events" "pointer-events:none;z-index:50" "$(cat "$NVHTML")"
check "pointermove wires a throttled hover raycast" "hoverTest(ev.clientX, ev.clientY)" "$(cat "$NVHTML")"
check "hoverTest() raycasts notes, repo regions/labels, and synapses" 'if(k==="repoRegion" || k==="repoLabel" || k==="synapse" || k==="synapsePulse") targets.push(child);' "$(cat "$NVHTML")"
check "click-to-inspect behavior (hitTest) is untouched by the hover feature" "function hitTest(clientX, clientY){" "$(cat "$NVHTML")"
check_absent "hover/projects/sessions code introduces no external fetch" 'fetch("http' "$(cat "$NVHTML")"
check "template polls GET /projects" 'fetch("/projects")' "$(cat "$NVHTML")"
check "template polls GET /sessions" 'fetch("/sessions")' "$(cat "$NVHTML")"
_nvvendorfile="$PLUGIN/templates/vendor/three.module.min.js"
if [[ -f "$_nvvendorfile" ]]; then
    got_sha="$(shasum -a 256 "$_nvvendorfile" | awk '{print $1}')"
    check "vendored three.js sha256 matches the recorded, audited version" "$NVVENDOR_SHA" "$got_sha"
else
    echo "FAIL vendored three.module.min.js is missing at $_nvvendorfile"; fails=$((fails + 1))
fi
if command -v node >/dev/null 2>&1; then
    script="$(python3 -c "
import re
html = open('$NVHTML').read()
m = re.search(r'<script type=\"module\">(.*)</script>', html, re.S)
print(m.group(1) if m else '')
")"
    _nvmodule="$(mktemp).mjs"
    printf '%s' "$script" >"$_nvmodule"
    if node --check "$_nvmodule" 2>/tmp/nv-node-check.$$; then
        echo "ok   neural-view.html inline module script has no syntax errors (node --check)"
    else
        echo "FAIL neural-view.html inline module script has syntax errors"; cat /tmp/nv-node-check.$$; fails=$((fails + 1))
    fi
    rm -f /tmp/nv-node-check.$$ "$_nvmodule"

    # layout: region size ∝ note count (empty repo floors at MIN_REGION), and
    # fitDistance() actually frames every repo region's bounding sphere within
    # the camera's FOV (the 3D analogue of the old 2D "doesn't fit / half
    # off-screen" regression test). layoutClusters()/fibSphere()/
    # boundingSphere()/fitDistance() are pure functions of module state, so we
    # eval them (extracted verbatim from the served template) against a fixture.
    _nvlayout="$(mktemp).cjs"
    cat >"$_nvlayout" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
const MIN_REGION = 46, BASE_REGION = 110, MIN_DIST = 80, MAX_DIST = 6000, FOV = 50 * Math.PI / 180;
let clusters, repoCenters, repoRadius, repoList, nodes;
const clusterKey = (repo, role) => repo + "|" + role;
function roleHue() { return 190; }

eval(extract("fibSphere"));
eval(extract("layoutClusters"));
eval(extract("boundingSphere"));
eval(extract("fitDistance"));

// asserts fitDistance(aspect) actually contains every repo region's own
// bounding sphere (center + radius + label headroom), not just the
// aggregate — this is the literal on-boot "everything visible with margin"
// contract, checked per aspect ratio (landscape + portrait, since a phone
// loads portrait).
function assertFits(label, aspect) {
    const fit = fitDistance(aspect);
    const hFov = 2 * Math.atan(Math.tan(FOV / 2) * aspect);
    const half = Math.min(FOV, hFov) / 2;
    if (fit.distance < MIN_DIST || fit.distance > MAX_DIST) throw new Error(label + ": fitDistance() out of clamp range: " + fit.distance);
    for (const repo of repoList) {
        const rc = repoCenters.get(repo); if (!rc) continue;
        const rad = (repoRadius.get(repo) || MIN_REGION) + 30;   // +30: label headroom, mirrors boundingSphere()'s own pad
        const distFromTarget = Math.hypot(rc.x - fit.target.x, rc.y - fit.target.y, rc.z - fit.target.z);
        const angle = Math.atan2(distFromTarget + rad, fit.distance);
        if (angle > half + 1e-6) throw new Error(label + ": " + repo + " falls outside the fitted FOV (angle=" + angle.toFixed(4) + " half=" + half.toFixed(4) + ")");
    }
}

// case 1: page just booted, before /graph has resolved — the exact state the
// user's screenshot showed landing on empty space. Must still produce a
// sane, non-NaN fit (the single-origin-point fallback).
clusters = new Map(); repoCenters = new Map(); repoRadius = new Map(); repoList = []; nodes = [];
layoutClusters();
assertFits("boot (no graph yet)", 1600 / 900);          // no-op loop (repoList empty) — the real check is next
assertFits("boot (no graph yet, portrait)", 900 / 1600);
for (const [label, aspect] of [["boot fallback point, landscape", 1600 / 900], ["boot fallback point, portrait", 900 / 1600]]) {
    const fit = fitDistance(aspect);
    if (Number.isNaN(fit.distance) || Number.isNaN(fit.target.x)) throw new Error(label + ": fitDistance() produced NaN with no repos yet");
    const hFov = 2 * Math.atan(Math.tan(FOV / 2) * aspect);
    const half = Math.min(FOV, hFov) / 2;
    if (!(fit.distance * Math.sin(half) >= 160 - 0.001)) throw new Error(label + ": the single-origin fallback (r=160) isn't framed: dist=" + fit.distance);
}

// case 2: a populated multi-repo graph, one repo empty — region size ∝ note
// count, empty repo floors at MIN_REGION, and every region (including the
// empty one) is framed.
clusters = new Map(); repoCenters = new Map(); repoRadius = new Map();
repoList = ["big-repo", "empty-repo", "mid-repo"];
nodes = [];
for (let i = 0; i < 20; i++) nodes.push({repo: "big-repo", role: "dev"});
for (let i = 0; i < 5; i++) nodes.push({repo: "mid-repo", role: "dev"});
// empty-repo: zero nodes — must still get a small placeholder region, not equal share
layoutClusters();
const bigR = repoRadius.get("big-repo"), emptyR = repoRadius.get("empty-repo"), midR = repoRadius.get("mid-repo");
if (!(bigR > midR && midR > emptyR)) throw new Error("region size must track note count: big=" + bigR + " mid=" + midR + " empty=" + emptyR);
if (Math.abs(emptyR - MIN_REGION) > 0.001) throw new Error("empty repo region must floor at MIN_REGION: got " + emptyR);
assertFits("populated 3-repo graph", 1600 / 900);
assertFits("populated 3-repo graph, portrait", 900 / 1600);

console.log("LAYOUT3D_OK bigR=" + bigR.toFixed(1) + " midR=" + midR.toFixed(1) + " emptyR=" + emptyR.toFixed(1));
NODEJS
    layout_out="$(node "$_nvlayout" "$NVHTML" 2>&1)"
    check "layoutClusters sizes regions by note count, empty repo floors at MIN_REGION" "LAYOUT3D_OK" "$layout_out"
    check "fitDistance frames every repo region on boot, reload, landscape + portrait" "LAYOUT3D_OK" "$layout_out"
    rm -f "$_nvlayout"

    # security: escapeHtml() is used to interpolate a board task TITLE (attacker-
    # influenced -- anyone who can title a GitHub issue in a tracked repo) into an
    # HTML ATTRIBUTE (title="${escapeHtml(t)}" in renderProjects()), not just a text
    # node. Escaping only &<> leaves a bare double-quote free to break out of the
    # attribute and inject a live event handler. escapeHtml() must also encode
    # both quote characters.
    _nvxss="$(mktemp).cjs"
    cat >"$_nvxss" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extractOneLine(name) {
    // escapeHtml() is a single-line function -- its closing brace isn't on its
    // own line, so the multi-line extract() pattern used elsewhere in this file
    // (which requires "\n}\n") doesn't match it. Same non-greedy idea, minus
    // that requirement.
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
eval(extractOneLine("escapeHtml"));
const payload = 'Fix bug" onmouseover="alert(document.cookie)<script>alert(1)</script>';
const out = escapeHtml(payload);
if (out.includes('"')) throw new Error("escapeHtml() leaves a raw double-quote in the output: " + out);
if (out.includes("'")) throw new Error("escapeHtml() leaves a raw single-quote in the output: " + out);
if (out.includes("<script>")) throw new Error("escapeHtml() leaves a raw <script> tag in the output: " + out);
if (!out.includes("&quot;")) throw new Error("escapeHtml() does not encode double quotes as &quot;: " + out);
console.log("ESCAPEHTML_XSS_OK " + out);
NODEJS
    xss_out="$(node "$_nvxss" "$NVHTML" 2>&1)"
    check "escapeHtml() neutralizes a double-quote-breakout XSS payload (attribute context)" "ESCAPEHTML_XSS_OK" "$xss_out"
    rm -f "$_nvxss"
fi

echo "== neural-view (lifecycle + endpoints on a scratch port, legacy single-repo mode) =="
NV="$PLUGIN/scripts/neural-view.py"
_nvroot="$(mktemp -d)"          # brains root (--dir)
_nvstate="$(mktemp -d)"         # server state (pid/port)
_nvscan_empty="$(mktemp -d)"    # empty scan base so real ~/Development repos never leak into these tests
_nvrepo="$(basename "$_nvroot")"
_nvbrain="$_nvroot/.claude/identities/dev/brain"
mkdir -p "$_nvbrain/notes"
cat >"$_nvbrain/notes/cas-retry.md" <<'EOF'
---
tags: [concurrency, cas]
paths: [packages/core]
strength: 4
graduated: false
---
Retry on CAS conflict; the loser reloads and re-applies. See [[idempotency]].
EOF
cat >"$_nvbrain/notes/idempotency.md" <<'EOF'
---
tags: [effects]
strength: 2
graduated: true
---
Deterministic ids make repeats safe.
EOF
printf '%s\n' '{"cas-retry->idempotency":{"weight":0.6,"fires":4,"last":"2026-07-06"}}' >"$_nvbrain/links.json"
printf '%s\n' '{"ts":"2026-07-06T10:00:00Z","role":"dev","event":"seed","note":"cas-retry","activation":0.8}' >"$_nvbrain/.activation.jsonl"

export NEURAL_VIEW_STATE="$_nvstate" NEURAL_VIEW_PORT=4788 NEURAL_VIEW_SCAN="$_nvscan_empty"
out="$(python3 "$NV" start --dir "$_nvroot")";  check "neural-view starts" "RUNNING http://127.0.0.1:4788" "$out"
out="$(python3 "$NV" status)";                  check "neural-view status running" "RUNNING http://127.0.0.1:4788" "$out"
check "neural-view status reports repos=1 (legacy single-dir)" "repos=1" "$out"
out="$(curl -sf http://127.0.0.1:4788/graph)";  check "graph has repo-qualified node id" "\"id\": \"$_nvrepo/dev/cas-retry\"" "$out"
check "graph node carries repo field" "\"repo\": \"$_nvrepo\"" "$out"
check "graph node carries strength" '"strength": 4' "$out"
check "graph node graduated flag" '"graduated": true' "$out"
check "graph has repo-qualified link edge" "\"source\": \"$_nvrepo/dev/cas-retry\"" "$out"
check "graph edge weight" '"weight": 0.6' "$out"
check "graph lists discovered repos" "\"repos\": [\"$_nvrepo\"]" "$out"
out="$(curl -sf "http://127.0.0.1:4788/note/$_nvrepo/dev/cas-retry")"
check "note renders fixture body" "the loser reloads" "$out"
code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4788/favicon.ico)"
check "favicon route no longer 404s" "200" "$code"
# vendored three.js: served same-origin, allowlisted (no path-derived fs access)
code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4788/vendor/three.module.min.js)"
check "vendor route serves three.module.min.js (200)" "200" "$code"
ctype="$(curl -s -D - -o /dev/null http://127.0.0.1:4788/vendor/three.module.min.js | tr -d '\r' | grep -i '^content-type:')"
check "vendor route content-type is javascript" "javascript" "$ctype"
for trav in "/vendor/../scripts/config.py" "/vendor/..%2fscripts%2fconfig.py" "/vendor/../../etc/passwd" "/vendor/not-on-the-allowlist.js"; do
    code="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:4788$trav")"
    check "vendor route rejects $trav (404)" "404" "$code"
done
# finding 2: path traversal via ../ in the slug must not escape notes/ (arbitrary file read)
printf 'TOPSECRET-XYZZY' >"$_nvbrain/SECRET.md"       # a file OUTSIDE notes/, one level up
body="$(curl -s --path-as-is "http://127.0.0.1:4788/note/$_nvrepo/dev/../SECRET")"
check_absent "note path traversal does not leak an out-of-tree file" "TOPSECRET-XYZZY" "$body"
code="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:4788/note/$_nvrepo/dev/../SECRET")"
check "note path traversal returns 404" "404" "$code"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:4788/note/$_nvrepo/dev/..%2fSECRET")"
check "note dotdot slug (encoded) returns 404" "404" "$code"
python3 "$NV" stop >/dev/null

# findings 1 + 3: offset-cursor /events — completeness from per-brain byte offsets, not sort order.
_nvev="$(mktemp -d)"
_nvevrepo="$(basename "$_nvev")"
for r in dev reviewer orchestrator; do mkdir -p "$_nvev/.claude/identities/$r/brain"; done
out="$(python3 "$NV" start --dir "$_nvev")"; check "neural-view starts (events root)" "RUNNING http://127.0.0.1:4788" "$out"
evout="$(P=4788 R="$_nvev" python3 - <<'PY'
import json, os, urllib.request
P, R = os.environ["P"], os.environ["R"]
log = lambda role: os.path.join(R, ".claude/identities", role, "brain", ".activation.jsonl")
def append(role, i, ts):
    with open(log(role), "a") as f:
        f.write(json.dumps({"ts": ts, "role": role, "event": "seed", "note": "n%d" % i, "id": i}) + "\n")
def poll(token):
    url = "http://127.0.0.1:%s/events" % P + (("?since=%s" % token) if token else "")
    return json.load(urllib.request.urlopen(url))
d0 = poll("")                                   # first poll: end-of-logs, no backlog replay
print("FIRSTPOLL events=%d" % len(d0["events"]))
# round 1 — interleaved, deliberately NON-monotonic ts across brains
append("dev", 1, "2026-07-06T10:00:05Z"); append("orchestrator", 2, "2026-07-06T10:00:01Z"); append("reviewer", 3, "2026-07-06T10:00:09Z")
d1 = poll(d0["cursor"]); ids1 = sorted(e["id"] for e in d1["events"])
# round 2 — the replay trap: events with ts EARLIER than ones already delivered in round 1
append("reviewer", 4, "2026-07-06T10:00:02Z"); append("dev", 5, "2026-07-06T10:00:00Z")
d2 = poll(d1["cursor"]); ids2 = sorted(e["id"] for e in d2["events"])
d3 = poll(d2["cursor"])                          # idle poll: nothing appended
allids = ids1 + ids2
print("ROUND2 ids=%s" % ids2)                    # must be exactly [4, 5] (delivered once, no replay of round 1)
print("DELIVERED ids=%s" % sorted(allids))       # no loss: every appended event arrived
print("DUPS=%d" % (len(allids) - len(set(allids))))  # no duplicate delivery
print("IDLE events=%d bytesRead=%s" % (len(d3["events"]), d3.get("bytesRead")))  # reads ~zero new bytes
print("REPOTAG=%s" % d1["events"][0].get("repo"))  # delivered events are tagged with their repo
PY
)"
check "events first poll skips backlog" "FIRSTPOLL events=0" "$evout"
check "events replay-trap delivers only new (no replay)" "ROUND2 ids=[4, 5]" "$evout"
check "events no loss across interleaved earlier-ts writes" "DELIVERED ids=[1, 2, 3, 4, 5]" "$evout"
check "events no duplicate delivery" "DUPS=0" "$evout"
check "events idle poll reads zero new bytes" "IDLE events=0 bytesRead=0" "$evout"
check "events carry the repo tag (legacy single-dir)" "REPOTAG=$_nvevrepo" "$evout"
# round-2 finding: a token decoding to a NEGATIVE byte offset must not reach an
# un-clamped fh.seek() (OSError → dropped connection). Must return 200 + a batch.
negtok="$(python3 -c "import base64,json; print(base64.urlsafe_b64encode(json.dumps({'$_nvevrepo':{'dev':-999}}).encode()).rstrip(b'=').decode())")"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:4788/events?since=$negtok")"
check "events negative-offset token returns 200 (no dropped connection)" "200" "$code"
body="$(curl -s "http://127.0.0.1:4788/events?since=$negtok")"
check "events negative-offset token yields a sane batch" '"events"' "$body"
python3 "$NV" stop >/dev/null

_nvempty="$(mktemp -d)"          # a root with no brains at all
out="$(python3 "$NV" start --dir "$_nvempty")"; check "neural-view starts on empty root" "RUNNING http://127.0.0.1:4788" "$out"
out="$(curl -sf http://127.0.0.1:4788/graph)";  check "empty root -> empty nodes" '"nodes": []' "$out"
out="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4788/)"; check "page still loads on empty root" "200" "$out"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_nvroot" "$_nvstate" "$_nvev" "$_nvempty" "$_nvscan_empty" "$_hubtmp"

echo "== neural-view (multi-repo aggregation via .claude/.neural-network marker) =="
_scanbase="$(mktemp -d)"
_scanstate="$(mktemp -d)"
_repoA="$_scanbase/repo-alpha"; _repoB="$_scanbase/repo-beta"; _repoC="$_scanbase/repo-gamma"
mkdir -p "$_repoA/.claude" "$_repoB/.claude" "$_repoC/.claude"
: >"$_repoA/.claude/.neural-network"   # marker + brains
: >"$_repoB/.claude/.neural-network"   # marker, no brains at all
# repoC: NO marker — must be excluded even though it has a brain
_alphabrain="$_repoA/.claude/identities/dev/brain"
mkdir -p "$_alphabrain/notes"
cat >"$_alphabrain/notes/seed-note.md" <<'EOF'
---
strength: 3
---
A note that belongs to repo-alpha only.
EOF
_gammabrain="$_repoC/.claude/identities/dev/brain"
mkdir -p "$_gammabrain/notes"
cat >"$_gammabrain/notes/should-not-appear.md" <<'EOF'
This repo has no marker file and must be excluded from discovery.
EOF

export NEURAL_VIEW_STATE="$_scanstate" NEURAL_VIEW_PORT=4789 NEURAL_VIEW_SCAN="$_scanbase"
out="$(python3 "$NV" start)"; check "neural-view starts (scan discovery, no --dir)" "RUNNING http://127.0.0.1:4789" "$out"
out="$(python3 "$NV" status)"; check "status reports repos=2 (marker repos only)" "repos=2" "$out"
out="$(curl -sf http://127.0.0.1:4789/graph)"
check "graph includes marked repo-alpha node" '"id": "repo-alpha/dev/seed-note"' "$out"
check "graph node tags repo-alpha" '"repo": "repo-alpha"' "$out"
check_absent "graph excludes unmarked repo-gamma note" "should-not-appear" "$out"
check "graph repos list includes repo-alpha" '"repo-alpha"' "$out"
check "graph repos list includes brainless marked repo-beta" '"repo-beta"' "$out"
check_absent "graph repos list excludes unmarked repo-gamma" '"repo-gamma"' "$out"
out="$(curl -sf "http://127.0.0.1:4789/note/repo-alpha/dev/seed-note")"
check "multi-repo note fetch addresses by repo/role/slug" "belongs to repo-alpha only" "$out"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:4789/note/repo-gamma/dev/should-not-appear")"
check "unmarked repo's note is unreachable (404)" "404" "$code"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$_scanbase" "$_scanstate"

if [[ "$(id -u)" != "0" ]]; then   # permission tests are meaningless as root (bypasses all checks)
    echo "== neural-view (scan base with an unreadable child directory) =="
    _permbase="$(mktemp -d)"
    _permstate="$(mktemp -d)"
    _goodrepo="$_permbase/good-repo"; mkdir -p "$_goodrepo/.claude"
    : >"$_goodrepo/.claude/.neural-network"
    _denied="$_permbase/denied-repo"; mkdir -p "$_denied/.claude"
    chmod 000 "$_denied"   # simulates a scan-base child neural-view can't traverse into
    export NEURAL_VIEW_STATE="$_permstate" NEURAL_VIEW_PORT=4790 NEURAL_VIEW_SCAN="$_permbase"
    out="$(python3 "$NV" start 2>&1)"
    check "neural-view survives an unreadable scan-base child (starts)" "RUNNING http://127.0.0.1:4790" "$out"
    out="$(python3 "$NV" status)"
    check "status still reports the good repo despite the denied one" "repos=1" "$out"
    python3 "$NV" stop >/dev/null 2>&1 || true
    chmod 700 "$_denied"    # restore before cleanup so rm -rf can actually remove it
    unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
    rm -rf "$_permbase" "$_permstate"
fi

echo "== neural-view (start fails to bind: no false RUNNING claim) =="
_bindstate="$(mktemp -d)"
python3 - <<'PY' &
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 4791))
s.listen(1)
time.sleep(6)
PY
_blocker=$!
sleep 0.3   # let the scratch listener actually bind before racing neural-view for the port
export NEURAL_VIEW_STATE="$_bindstate" NEURAL_VIEW_PORT=4791
out="$(python3 "$NV" start 2>&1)"; rc=$?
check_absent "start does not claim RUNNING when the port is already taken" "RUNNING" "$out"
check "start's failure message points at server.log" "server.log" "$out"
if [[ $rc -ne 0 ]]; then echo "ok   start exits non-zero when it fails to bind"
else echo "FAIL start exits non-zero when it fails to bind — got rc=0"; fails=$((fails + 1)); fi
kill "$_blocker" 2>/dev/null || true
wait "$_blocker" 2>/dev/null || true
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT
rm -rf "$_bindstate"

echo "== neural-view /projects (per-repo board state via THIS plugin's board.sh, cached) =="
NVP_REPO="$(mktemp -d)"
mkdir -p "$NVP_REPO/.claude"
cp "$FIX/valid.project.yaml" "$NVP_REPO/.claude/project.yaml"
NVP_NOBOARD="$(mktemp -d)"   # discovered repo, no .claude/project.yaml at all -> must be omitted
NVP_GH="$(mktemp -d)"
_nvpscan_empty="$(mktemp -d)"   # empty scan base -- real ~/Development repos must never leak into these tests
cat >"$NVP_GH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
    "project item-list")
        [[ -n "${FAKE_GH_LOG:-}" ]] && echo "$*" >>"$FAKE_GH_LOG"
        if [[ -n "${FAKE_GH_CALLCOUNT:-}" ]]; then
            n=$(( $(cat "$FAKE_GH_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
            echo "$n" >"$FAKE_GH_CALLCOUNT"
        fi
        if [[ "${FAKE_GH_FAIL:-0}" == "1" ]]; then
            echo "fake gh: item-list boom" >&2
            exit 1
        fi
        if [[ "${FAKE_GH_HANG:-0}" == "1" ]]; then
            sleep "${FAKE_GH_HANG_SECS:-3}"
        fi
        printf 'In progress\tP0\t#1\tAdd widget\n'
        printf 'In review\tP1\t#2\tFix bug\n'
        printf 'Backlog\tP2\t#3\tIdea\n'
        [[ -n "${FAKE_GH_XSS_TITLE:-}" ]] && printf 'In progress\tP0\t#9\t%s\n' "${FAKE_GH_XSS_TITLE}"
        true
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$NVP_GH/gh"
NV="$PLUGIN/scripts/neural-view.py"
_nvpstate="$(mktemp -d)"

# scenario 1: happy path + within-TTL caching (call-count observed via shim log)
LOG1="$(mktemp)"; CC1="$(mktemp)"
export NEURAL_VIEW_STATE="$_nvpstate" NEURAL_VIEW_PORT=4792 NEURAL_VIEW_PROJECTS_TTL=100 NEURAL_VIEW_SCAN="$_nvpscan_empty"
out="$(PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG1" FAKE_GH_CALLCOUNT="$CC1" python3 "$NV" start --dir "$NVP_REPO")"
check "neural-view starts (projects fixture)" "RUNNING http://127.0.0.1:4792" "$out"
body="$(curl -sf http://127.0.0.1:4792/projects)"
_nvprepo="$(basename "$NVP_REPO")"
check "projects: repo key present" "\"$_nvprepo\"" "$body"
check "projects: ok true" '"ok": true' "$body"
check "projects: status counts" '"In progress": 1' "$body"
check "projects: in-progress titles" '"Add widget"' "$body"
check "projects: in-review titles" '"Fix bug"' "$body"
curl -sf http://127.0.0.1:4792/projects >/dev/null    # second call, well within TTL
n1="$(cat "$CC1")"
check "projects: second call within TTL does not re-invoke board.sh" "1" "$n1"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_PROJECTS_TTL

# scenario 2: TTL expiry -> a call after the TTL DOES re-invoke
LOG2="$(mktemp)"; CC2="$(mktemp)"
export NEURAL_VIEW_PORT=4792 NEURAL_VIEW_PROJECTS_TTL=1 NEURAL_VIEW_SCAN="$_nvpscan_empty"
out="$(PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG2" FAKE_GH_CALLCOUNT="$CC2" python3 "$NV" start --dir "$NVP_REPO")"
check "neural-view starts (TTL-expiry scenario)" "RUNNING http://127.0.0.1:4792" "$out"
curl -sf http://127.0.0.1:4792/projects >/dev/null
sleep 1.3
curl -sf http://127.0.0.1:4792/projects >/dev/null
n2="$(cat "$CC2")"
if [[ "$n2" -ge 2 ]]; then echo "ok   projects: a call after TTL expiry re-invokes board.sh"
else echo "FAIL projects: expected >=2 board.sh invocations after TTL expiry, got $n2"; fails=$((fails + 1)); fi
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_PROJECTS_TTL

# scenario 3: gh/network failure degrades gracefully (ok:false, no crash)
LOG3="$(mktemp)"; CC3="$(mktemp)"
out="$(PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG3" FAKE_GH_CALLCOUNT="$CC3" FAKE_GH_FAIL=1 python3 "$NV" start --dir "$NVP_REPO")"
check "neural-view starts (failure scenario)" "RUNNING http://127.0.0.1:4792" "$out"
code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4792/projects)"
check "projects: failure still returns 200 (degraded, not a crash)" "200" "$code"
body="$(curl -sf http://127.0.0.1:4792/projects)"
check "projects: gh failure reported as ok:false" '"ok": false' "$body"
check "projects: gh failure carries an error message" '"error"' "$body"
python3 "$NV" stop >/dev/null

# scenario 4: a discovered repo with no .claude/project.yaml is omitted entirely
out="$(python3 "$NV" start --dir "$NVP_NOBOARD")"
check "neural-view starts (no-board repo)" "RUNNING http://127.0.0.1:4792" "$out"
body="$(curl -sf http://127.0.0.1:4792/projects)"
check "projects: repo without project.yaml is omitted" "{}" "$body"
python3 "$NV" stop >/dev/null

# scenario 5b: a board task title carrying an XSS payload (attacker-controlled --
# anyone who can title a GitHub issue) is passed through /projects RAW, unescaped.
# The server is not the defense here; this pins that fact down so the client-side
# escapeHtml() (checked above, in the template-contract block) stays the only guard.
LOG5B="$(mktemp)"; CC5B="$(mktemp)"
XSS_TITLE='Fix bug" onmouseover="alert(document.cookie)<script>alert(1)</script>'
out="$(PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG5B" FAKE_GH_CALLCOUNT="$CC5B" FAKE_GH_XSS_TITLE="$XSS_TITLE" python3 "$NV" start --dir "$NVP_REPO")"
check "neural-view starts (XSS-title fixture)" "RUNNING http://127.0.0.1:4792" "$out"
body="$(curl -sf http://127.0.0.1:4792/projects)"
check "projects: server passes an attacker-controlled title through unescaped (client must escape it)" 'onmouseover=' "$body"
check "projects: server does not strip/encode the embedded <script> tag either" '<script>alert(1)</script>' "$body"
python3 "$NV" stop >/dev/null

# scenario 5: a hanging board.sh call never blocks another route (/graph)
LOG5="$(mktemp)"; CC5="$(mktemp)"
out="$(PATH="$NVP_GH:$PATH" FAKE_GH_LOG="$LOG5" FAKE_GH_CALLCOUNT="$CC5" FAKE_GH_HANG=1 FAKE_GH_HANG_SECS=4 python3 "$NV" start --dir "$NVP_REPO")"
check "neural-view starts (hang scenario)" "RUNNING http://127.0.0.1:4792" "$out"
curl -sf http://127.0.0.1:4792/projects >/tmp/nv-hang-out.$$ &
_hangpid=$!
sleep 0.5   # let the hanging /projects request actually start (past the fake gh's sleep having begun)
t0=$(date +%s)
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:4792/graph)"
t1=$(date +%s)
check "projects: sibling route (/graph) still responds while board.sh hangs" "200" "$code"
elapsed=$(( t1 - t0 ))
if [[ "$elapsed" -le 2 ]]; then echo "ok   projects: /graph was not blocked by the hanging board.sh call (${elapsed}s)"
else echo "FAIL projects: /graph took ${elapsed}s while board.sh hung -- looks blocked"; fails=$((fails + 1)); fi
wait "$_hangpid" 2>/dev/null || true
rm -f /tmp/nv-hang-out.$$
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_SCAN
rm -rf "$NVP_REPO" "$NVP_NOBOARD" "$NVP_GH" "$_nvpstate" "$_nvpscan_empty" "$LOG1" "$CC1" "$LOG2" "$CC2" "$LOG3" "$CC3" "$LOG5" "$CC5" "$LOG5B" "$CC5B"

echo "== neural-view /sessions (best-effort local Claude session discovery) =="
NVS_CLAUDE="$(mktemp -d)"
NVS_JOBS="$NVS_CLAUDE/jobs"
mkdir -p "$NVS_JOBS/job-working" "$NVS_JOBS/job-recent-done" "$NVS_JOBS/job-stale-done" "$NVS_JOBS/job-unmatched-repo"
NVS_REPO="$(mktemp -d)"
mkdir -p "$NVS_REPO/.claude"
: >"$NVS_REPO/.claude/.neural-network"
cat >"$NVS_JOBS/job-working/state.json" <<EOF
{"state":"working","cwd":"$NVS_REPO","name":"messaging","createdAt":"2026-07-07T10:00:00Z","updatedAt":"2026-07-07T10:05:00Z"}
EOF
cat >"$NVS_JOBS/job-recent-done/state.json" <<EOF
{"state":"done","cwd":"$NVS_REPO/subdir","name":"cleanup","createdAt":"2026-07-07T09:00:00Z","updatedAt":"2026-07-07T09:01:00Z"}
EOF
cat >"$NVS_JOBS/job-stale-done/state.json" <<EOF
{"state":"done","cwd":"$NVS_REPO","name":"old-task","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:05:00Z"}
EOF
touch -t 202601010000 "$NVS_JOBS/job-stale-done/state.json"
cat >"$NVS_JOBS/job-unmatched-repo/state.json" <<EOF
{"state":"working","cwd":"/tmp/somewhere-not-discovered","name":"lonely","createdAt":"2026-07-07T10:00:00Z","updatedAt":"2026-07-07T10:00:00Z"}
EOF
_nvsstate="$(mktemp -d)"
_nvsscan_empty="$(mktemp -d)"   # empty scan base -- real ~/Development repos must never leak into these tests
export NEURAL_VIEW_STATE="$_nvsstate" NEURAL_VIEW_PORT=4793 NEURAL_VIEW_CLAUDE_DIR="$NVS_CLAUDE" NEURAL_VIEW_SCAN="$_nvsscan_empty"
_nvsrepo="$(basename "$NVS_REPO")"
out="$(python3 "$NV" start --dir "$NVS_REPO")"
check "neural-view starts (sessions fixture)" "RUNNING http://127.0.0.1:4793" "$out"
body="$(curl -sf http://127.0.0.1:4793/sessions)"
check "sessions: working job included" '"messaging"' "$body"
check "sessions: recently-updated done job included" '"cleanup"' "$body"
check_absent "sessions: stale done job excluded" '"old-task"' "$body"
check "sessions: job cwd matched to the discovered repo" "\"repo\": \"$_nvsrepo\"" "$body"
check "sessions: job outside any discovered repo still reported (repo: null)" '"repo": null' "$body"
check "sessions: unmatched job still carries its description" '"lonely"' "$body"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_CLAUDE_DIR NEURAL_VIEW_SCAN

# no jobs dir at all -> []
_nvsempty="$(mktemp -d)"
_nvs_noclaude="$(mktemp -d)"
export NEURAL_VIEW_CLAUDE_DIR="$_nvs_noclaude" NEURAL_VIEW_SCAN="$_nvsscan_empty"
out="$(python3 "$NV" start --dir "$_nvsempty")"
check "neural-view starts (no jobs dir)" "RUNNING http://127.0.0.1:4793" "$out"
body="$(curl -sf http://127.0.0.1:4793/sessions)"
check "sessions: absent jobs dir yields empty array" "[]" "$body"
python3 "$NV" stop >/dev/null
unset NEURAL_VIEW_STATE NEURAL_VIEW_PORT NEURAL_VIEW_CLAUDE_DIR NEURAL_VIEW_SCAN
rm -rf "$NVS_CLAUDE" "$NVS_REPO" "$_nvsstate" "$_nvsscan_empty" "$_nvsempty" "$_nvs_noclaude"

echo "== gate enforcement (gate.sh + guard-board-move hook) =="
T3="$(mktemp -d)"
( cd "$T3" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$T3/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3/.claude/project.json"
hookjson() { printf '{"tool_input":{"command":"%s"}}' "$1"; }
hookjsonpy() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"; }
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "move blocked without pass" "BLOCKED: no recorded gate pass" "$out"
check "block exit code 2" "rc=2" "$out"
out="$(hookjson 'bash board.sh comment 7 \"please move to in review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "comment mentioning review status is allowed, no substring FP" "rc=0" "$out"
out="$(hookjson 'bash board.sh move 7 Backlog && gh issue comment 3 --body \"Please consider In review after QA\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "move to Backlog allowed despite embedded In review text (live incident)" "rc=0" "$out"
out="$(hookjson 'cd /tmp && bash /some/path/board.sh move 7 \"In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "compound command still parsed and blocked without pass" "rc=2" "$out"
out="$(hookjson 'echo \"moving to In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "non board.sh command mentioning status unaffected" "rc=0" "$out"
out="$(hookjson 'bash board.sh move 7 \"In review' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "unparseable board.sh move command fails closed" "BLOCKED: could not safely parse" "$out"
check "unparseable fail-closed exit code 2" "rc=2" "$out"
BASHC_MOVE='bash -c "board.sh move 9 '\''In review'\''"'
out="$(hookjsonpy "$BASHC_MOVE" | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "bash -c wrapped move to review blocked without pass" "rc=2" "$out"
SHC_MOVE='sh -c "board.sh move 9 '\''In review'\''"'
out="$(hookjsonpy "$SHC_MOVE" | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "sh -c wrapped move to review blocked without pass" "rc=2" "$out"
NESTED_BASHC='bash -c '\''bash -c "board.sh move 9 \"In review\""'\'''
out="$(hookjsonpy "$NESTED_BASHC" | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "nested bash -c move to review blocked without pass" "rc=2" "$out"
BASHC_COMMENT='bash -c '\''board.sh comment 9 "please move to In review"'\'''
out="$(hookjsonpy "$BASHC_COMMENT" | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "bash -c wrapped comment mentioning review status allowed, no FP" "rc=0" "$out"
out="$(cd "$T3" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "gate pass recorded" "GATE PASS recorded" "$out"
check "gate telemetry: ok:true event recorded" '"kind": "gate"' "$(cat "$T3/.claude/telemetry.jsonl" 2>/dev/null)"
check "gate telemetry: ok:true value" '"ok": true' "$(cat "$T3/.claude/telemetry.jsonl" 2>/dev/null)"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "move allowed with fresh pass" "rc=0" "$out"
out="$(hookjsonpy "$BASHC_MOVE" | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "bash -c wrapped move allowed with fresh pass" "rc=0" "$out"
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
check "gate telemetry: ok:false event recorded on red" '"ok": false' "$(cat "$T3/.claude/telemetry.jsonl" 2>/dev/null)"
if [[ ! -f "$T3/.claude/gate-pass" ]]; then echo "ok   pass file removed on red"; else echo "FAIL pass file should be removed"; fails=$((fails+1)); fi
rm -rf "$T3"

echo "== gate enforcement (untracked-file content in fingerprint, SW-010) =="
T3U="$(mktemp -d)"
( cd "$T3U" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$T3U/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3U/.claude/project.json"
echo '*.local' > "$T3U/.gitignore"
out="$(cd "$T3U" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "untracked: gate pass recorded" "GATE PASS recorded" "$out"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: move allowed right after pass" "rc=0" "$out"
echo new > "$T3U/untracked.txt"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: new untracked file blocks move" "tree changed since the last recorded gate pass" "$out"
out="$(cd "$T3U" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "untracked: gate re-recorded after add" "GATE PASS recorded" "$out"
echo modified >> "$T3U/untracked.txt"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: modifying an untracked file blocks move" "tree changed since the last recorded gate pass" "$out"
out="$(cd "$T3U" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "untracked: gate re-recorded after modify" "GATE PASS recorded" "$out"
rm -f "$T3U/untracked.txt"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: deleting an untracked file blocks move" "tree changed since the last recorded gate pass" "$out"
out="$(cd "$T3U" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "untracked: gate re-recorded after delete" "GATE PASS recorded" "$out"
echo ignored > "$T3U/churn.local"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: ignored-file churn does not invalidate pass" "rc=0" "$out"
echo changed >> "$T3U/churn.local"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: ignored-file modification does not invalidate pass" "rc=0" "$out"
rm -f "$T3U/churn.local"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: ignored-file deletion does not invalidate pass" "rc=0" "$out"
rm -rf "$T3U"

echo "== gate enforcement (gate-pass marker excluded even when .claude/ has a TRACKED file, SW-010 follow-up) =="
T3M="$(mktemp -d)"
mkdir -p "$T3M/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3M/.claude/project.json"
( cd "$T3M" && git init -q . && git add .claude/project.json && git commit -q -m init )
# No .gitignore entry for .claude/gate-pass, and .claude/ has a tracked file so
# it can't collapse to a single "?? .claude/" porcelain line — this is the
# shape that exposes gate-pass to `git status --porcelain` once it exists.
# Compare tree-state.sh's raw output directly (not through gate.sh's record
# step): gate.sh's `>"$MARKER"` redirection happens to pre-create gate-pass
# before tree-state.sh runs, which accidentally masks the porcelain leak in
# that one call path — this direct comparison is the real, unmasked check.
before="$(cd "$T3M" && bash "$PLUGIN/scripts/tree-state.sh")"
: > "$T3M/.claude/gate-pass"
after="$(cd "$T3M" && bash "$PLUGIN/scripts/tree-state.sh")"
if [[ "$before" == "$after" ]]; then
    echo "ok   marker: fingerprint unaffected by .claude/gate-pass appearing in a tracked .claude/ dir"
else
    echo "FAIL marker: fingerprint changed when .claude/gate-pass appeared — before=$before after=$after"
    fails=$((fails + 1))
fi
rm -f "$T3M/.claude/gate-pass"
out="$(cd "$T3M" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "marker: gate pass recorded" "GATE PASS recorded" "$out"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3M" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "marker: move allowed immediately after pass despite tracked .claude dir" "rc=0" "$out"
rm -rf "$T3M"

echo "== gate enforcement (telemetry.jsonl excluded from fingerprint, SW-023 follow-up) =="
T3N="$(mktemp -d)"; mkdir -p "$T3N/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3N/.claude/project.json"
( cd "$T3N" && git init -q . && git add .claude/project.json && git commit -q -m init )
before="$(cd "$T3N" && bash "$PLUGIN/scripts/tree-state.sh")"
echo '{"kind":"gate","task":"x","ok":true,"ts":"2026-01-01T00:00:00Z"}' > "$T3N/.claude/telemetry.jsonl"
after="$(cd "$T3N" && bash "$PLUGIN/scripts/tree-state.sh")"
if [[ "$before" == "$after" ]]; then
    echo "ok   telemetry: fingerprint unaffected by .claude/telemetry.jsonl appearing"
else
    echo "FAIL telemetry: fingerprint changed when .claude/telemetry.jsonl appeared -- before=$before after=$after"
    fails=$((fails + 1))
fi
rm -f "$T3N/.claude/telemetry.jsonl"

# Full integration: gate green, then a routine board.sh move (any task, any
# status) appends a transition event to the SAME telemetry.jsonl the pass was
# recorded against; the guard re-check for a DIFFERENT move must still see a
# VALID, current pass. Also a concurrency-safety property: one lane's routine
# move must not invalidate another lane's recorded pass (telemetry.jsonl is
# shared across the whole repo).
out="$(cd "$T3N" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "telemetry: gate pass recorded" "GATE PASS recorded" "$out"
T3NGH="$(mktemp -d)"
cat >"$T3NGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
    "project item-list") echo "ITEM_7" ;;
    "project item-edit") echo "edited" ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$T3NGH/gh"
out="$(cd "$T3N" && PATH="$T3NGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 7 Backlog 2>&1)"
check "telemetry: routine move succeeded" "moved #7 -> Backlog" "$out"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3N" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "telemetry: a routine move must not invalidate a still-current gate pass" "rc=0" "$out"
rm -rf "$T3N" "$T3NGH"

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

echo "== board.sh bug verb (fake gh: item-add + eventual consistency) =="
BG="$(mktemp -d)"; mkdir -p "$BG/.claude"
cp "$FIX/valid.project.yaml" "$BG/.claude/project.yaml"
FGH="$(mktemp -d)"
cat >"$FGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
echo "$*" >>"$FAKE_GH_LOG"
case "$1 $2" in
    "issue create")
        echo "https://github.com/fixture-owner/fixture-project/issues/${FAKE_GH_ISSUE_NUM:-501}"
        ;;
    "project item-add")
        : # board.sh discards item-add's stdout; only the call itself (in FAKE_GH_LOG) matters
        ;;
    "project item-list")
        n=$(( $(cat "$FAKE_GH_CALLCOUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$FAKE_GH_CALLCOUNT"
        if [[ "$*" == *"select(.content.number=="* ]]; then
            if [[ "${FAKE_GH_NEVER_VISIBLE:-0}" != "1" && "$n" -ge "${FAKE_GH_VISIBLE_AFTER:-1}" ]]; then
                echo "ITEM_${FAKE_GH_ISSUE_NUM:-501}"
            fi
        else
            echo '{"items":[]}'
        fi
        ;;
    "project item-edit")
        if [[ "${FAKE_GH_FAIL_EDIT:-0}" == "1" ]]; then
            echo "fake gh: item-edit boom" >&2
            exit 1
        fi
        echo "edited"
        ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$FGH/gh"

# scenario 1: happy path -- issue created, item-add invoked with its URL, item visible on the first poll
LOG1="$(mktemp)"; CC1="$(mktemp)"
out="$(cd "$BG" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG1" FAKE_GH_CALLCOUNT="$CC1" FAKE_GH_ISSUE_NUM=501 FAKE_GH_VISIBLE_AFTER=1 \
    bash "$PLUGIN/scripts/board.sh" bug "widget breaks on save" "" 42 2>&1; echo "rc=$?")"
check "bug verb: filed bug line on success" "filed bug #501 [P0]" "$out"
check "bug verb: exits 0 on success" "rc=0" "$out"
check "bug verb: issue title prefixed BUG:" "BUG: widget breaks on save" "$(cat "$LOG1")"
check "bug verb: default priority is first option (P0)" "filed bug #501 [P0]" "$out"
check "bug verb: origin-issue link in body" "Originating task: #42." "$(cat "$LOG1")"
check "bug verb: item-add invoked with the created issue's URL" "project item-add 1 --owner fixture-owner --url https://github.com/fixture-owner/fixture-project/issues/501" "$(cat "$LOG1")"

# scenario 2: eventual consistency -- item-list only shows the new item from the 4th call onward
LOG2="$(mktemp)"; CC2="$(mktemp)"
out="$(cd "$BG" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG2" FAKE_GH_CALLCOUNT="$CC2" FAKE_GH_ISSUE_NUM=502 FAKE_GH_VISIBLE_AFTER=4 \
    bash "$PLUGIN/scripts/board.sh" bug "flaky spinner" P1 2>&1; echo "rc=$?")"
check "bug verb: eventual consistency -- retries until item-list shows the item, then succeeds" "filed bug #502 [P1]" "$out"
check "bug verb: eventual consistency exits 0" "rc=0" "$out"
n2="$(cat "$CC2")"
if [[ "$n2" -ge 4 ]]; then echo "ok   bug verb: item-list was polled multiple times before succeeding"
else echo "FAIL bug verb: expected >=4 item-list polls, got $n2"; fails=$((fails + 1)); fi

# scenario 3: the item never becomes visible -- honest failure, not a false "filed bug"
LOG3="$(mktemp)"; CC3="$(mktemp)"
out="$(cd "$BG" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG3" FAKE_GH_CALLCOUNT="$CC3" FAKE_GH_ISSUE_NUM=503 FAKE_GH_NEVER_VISIBLE=1 \
    bash "$PLUGIN/scripts/board.sh" bug "ghost item" P2 2>&1; echo "rc=$?")"
check "bug verb: never-visible item -- actionable ERROR naming the issue" "ERROR: issue #503" "$out"
check_absent "bug verb: never-visible item -- no false success line" "filed bug" "$out"
check "bug verb: never-visible item exits nonzero" "rc=1" "$out"

# scenario 4 (invariant #3): item-add/visibility succeed but the subsequent move/prio fails --
# the verb must not report success
LOG4="$(mktemp)"; CC4="$(mktemp)"
out="$(cd "$BG" && PATH="$FGH:$PATH" FAKE_GH_LOG="$LOG4" FAKE_GH_CALLCOUNT="$CC4" FAKE_GH_ISSUE_NUM=504 FAKE_GH_VISIBLE_AFTER=1 FAKE_GH_FAIL_EDIT=1 \
    bash "$PLUGIN/scripts/board.sh" bug "move/prio fails" P0 2>&1; echo "rc=$?")"
check_absent "bug verb: move/prio failure -- no false success line" "filed bug" "$out"
check "bug verb: move/prio failure exits nonzero" "rc=1" "$out"

rm -rf "$BG" "$FGH" "$LOG1" "$CC1" "$LOG2" "$CC2" "$LOG3" "$CC3" "$LOG4" "$CC4"

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

echo "== concurrency (maxInProgress surgical set) =="
CC="$(mktemp -d)"; ( cd "$CC" && git init -q . )
mkdir -p "$CC/.claude"; cp "$FIX/valid.project.yaml" "$CC/.claude/project.yaml"
cc() { (cd "$CC" && bash "$PLUGIN/scripts/concurrency.sh" "$@"); }
check "concurrency default status" "concurrency: 1 (strictly sequential" "$(cc status)"
cc set 3 >/dev/null
check "concurrency set persists" "3" "$(python3 "$PLUGIN/scripts/config.py" "$CC" get methodology.maxInProgress)"
check "concurrency status reflects N" "up to 3 tasks in parallel lanes" "$(cc status)"
check "concurrency comment survives set" "# reviewerTokenEnv: GH_TOKEN_REVIEWER" "$(cat "$CC/.claude/project.yaml")"
check "concurrency flow-style survives set" "taskRanges: [[90, 99]]" "$(cat "$CC/.claude/project.yaml")"
check "concurrency rejects zero" "usage: concurrency.sh set" "$(cc set 0 2>&1 || true)"
check "concurrency rejects non-int" "usage: concurrency.sh set" "$(cc set abc 2>&1 || true)"
python3 "$PLUGIN/scripts/config.py" "$CC" set methodology.maxInProgress 2
check "config.py set verb round-trips" "2" "$(python3 "$PLUGIN/scripts/config.py" "$CC" get methodology.maxInProgress)"
rm -rf "$CC"

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

echo "== feedback (loop feedback feed) =="
FT="$(mktemp -d)"; mkdir -p "$FT/.claude"
cp "$FIX/valid.project.yaml" "$FT/.claude/project.yaml"
fb() { (cd "$FT" && python3 "$PLUGIN/scripts/feedback.py" "$FT" "$@"); }

# config parsing: shorthand + expanded forms via config.py get
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback true >/dev/null
check "shorthand feedback=true readable" "true" "$(python3 "$PLUGIN/scripts/config.py" "$FT" get methodology.feedback)"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FT/.claude/project.yaml")"
check "validator accepts shorthand feedback" "VALID: " "$out"
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "feed": ".claude/feedback/feed.yaml", "roles": ["orchestrator"], "autoTriage": false}' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FT/.claude/project.yaml")"
check "validator accepts expanded feedback" "VALID: " "$out"
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "bogus": 1}' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FT/.claude/project.yaml" || true)"
check "validator rejects unknown feedback key" "unknown key" "$out"
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "feed": ".claude/feedback/feed.yaml", "roles": ["orchestrator"], "autoTriage": false}' >/dev/null

# feed path containment: absolute paths and ../ escapes are rejected by the validator
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "feed": "/tmp/escape-feed.yaml"}' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FT/.claude/project.yaml" || true)"
check "validator rejects absolute feed path" "must be repo-relative" "$out"
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "feed": "../../escape/feed.yaml"}' >/dev/null
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$FT/.claude/project.yaml" || true)"
check "validator rejects ../ escaping feed path" "must not escape" "$out"
python3 "$PLUGIN/scripts/config.py" "$FT" set methodology.feedback '{"enabled": true, "feed": ".claude/feedback/feed.yaml", "roles": ["orchestrator"], "autoTriage": false}' >/dev/null

# status: disabled by default (no methodology.feedback key)
FD="$(mktemp -d)"; mkdir -p "$FD/.claude"; cp "$FIX/valid.project.yaml" "$FD/.claude/project.yaml"
out="$(cd "$FD" && python3 "$PLUGIN/scripts/feedback.py" "$FD" status)"
check "status: disabled by default" "feedback: disabled" "$out"
rm -rf "$FD"

check "status: enabled + feed path + pending=0" "feedback: enabled feed=.claude/feedback/feed.yaml pending=0" "$(fb status)"

# emit: valid record round-trips into the feed
out="$(fb emit "$FIX/feedback-valid.yaml")"
check "emit ok" "OK" "$out"
check "feed file created" "loop-feedback" "$(cat "$FT/.claude/feedback/feed.yaml" 2>/dev/null)"
check "status: pending reflects 2 unrouted items" "pending=2" "$(fb status)"

# emit: rejects a second record reusing an already-emitted ts (would make routing ambiguous)
out="$(fb emit "$FIX/feedback-valid.yaml" || true)"
check "emit rejects duplicate ts" "INVALID" "$out"
check "emit rejects duplicate ts: names the clash" "already exists" "$out"
check "status: pending unaffected by rejected duplicate" "pending=2" "$(fb status)"

# emit: rejects generalized/summary text carrying project-specific refs (#N)
out="$(fb emit "$FIX/feedback-bad-refs.yaml" || true)"
check "emit rejects #N ref" "INVALID" "$out"
check "emit rejects #N ref: names the offending ref" "#23" "$out"

# emit: rejects generalized text containing the iteration's own task id
BADTASK="$FT/bad-task.yaml"
cat >"$BADTASK" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-07-01T12:00:00Z"
iteration:
  task: FX-023
  outcome: merged
  reviewRounds: 1
source:
  role: dev
  model: claude-sonnet-5
items:
  - category: friction
    area: board
    severity: low
    summary: "FX-023 took longer than expected because of board flakiness."
    generalized: "FX-023 took longer than expected because of board flakiness."
YAML
out="$(fb emit "$BADTASK" || true)"
check "emit rejects task-id in generalized text" "INVALID" "$out"

# pending: lists the unrouted items from the valid record
out="$(fb pending)"
check "pending lists record ts" "2026-07-01T10:00:00Z" "$out"
check "pending lists category" "friction" "$out"
check "pending lists summary" "Front-load the human merge check-in" "$out"

# route: writes routing back, unknown action rejected, pending drops
out="$(fb route "2026-07-01T10:00:00Z" 0 bogus-action "n/a" || true)"
check "route rejects unknown action" "unknown routing action" "$out"
fb route "2026-07-01T10:00:00Z" 0 brain-note "friction-self-approval" >/dev/null
fb route "2026-07-01T10:00:00Z" 1 backlog "#41" >/dev/null
check "status: pending drops to zero after routing" "pending=0" "$(fb status)"
check "routing written into feed" "brain-note" "$(cat "$FT/.claude/feedback/feed.yaml")"

# route: re-routing an already-routed item is allowed but names the prior action
out="$(fb route "2026-07-01T10:00:00Z" 0 graduate "graduated-lesson")"
check "re-route surfaces the prior action" "(was: brain-note)" "$out"
rm -rf "$FT"

# route: a hand-crafted feed with a duplicate ts is refused as ambiguous rather than
# silently rewriting the first match and stranding the second
DT="$(mktemp -d)"; mkdir -p "$DT/.claude/feedback"
cp "$FIX/valid.project.yaml" "$DT/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$DT" set methodology.feedback true >/dev/null
cat >"$DT/.claude/feedback/feed.yaml" <<'YAML'
schemaVersion: 1
kind: loop-feedback
ts: "2026-08-01T00:00:00Z"
iteration: {task: FX-001, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "a", generalized: "a"}
---
schemaVersion: 1
kind: loop-feedback
ts: "2026-08-01T00:00:00Z"
iteration: {task: FX-002, outcome: merged, reviewRounds: 1}
source: {role: dev, model: claude-sonnet-5}
items:
  - {category: friction, area: board, severity: low, summary: "b", generalized: "b"}
YAML
out="$(cd "$DT" && python3 "$PLUGIN/scripts/feedback.py" "$DT" route "2026-08-01T00:00:00Z" 0 ignore "n/a" 2>&1; echo "rc=$?")"
check "route refuses ambiguous duplicate ts" "ambiguous" "$out"
check "route refuses ambiguous duplicate ts: nonzero exit" "rc=1" "$out"
rm -rf "$DT"

# feedback.py independently refuses to write outside the repo root, even if a bad
# config slipped past validate-config.py (defense in depth)
ESC="$(mktemp -d)"; mkdir -p "$ESC/.claude"
ESCTARGET="$ESC-escape"  # unique per run (derived from $ESC), never left dangling across runs
rm -rf "$ESCTARGET"
cp "$FIX/valid.project.yaml" "$ESC/.claude/project.yaml"
python3 "$PLUGIN/scripts/config.py" "$ESC" set methodology.feedback "{\"enabled\": true, \"feed\": \"../$(basename "$ESCTARGET")/feed.yaml\"}" >/dev/null
out="$(cd "$ESC" && python3 "$PLUGIN/scripts/feedback.py" "$ESC" emit "$FIX/feedback-valid.yaml" 2>&1; echo "rc=$?")"
check "feedback.py refuses to emit outside repo root" "ERROR" "$out"
check "feedback.py refuses to emit outside repo root: nonzero exit" "rc=1" "$out"
check "feedback.py did not write outside the root" "MISSING" "$([[ -f "$ESCTARGET/feed.yaml" ]] && echo FOUND || echo MISSING)"
rm -rf "$ESC" "$ESCTARGET"

echo "== telemetry.py record (validation + append) =="
TT="$(mktemp -d)"; mkdir -p "$TT/.claude"
rec() { python3 "$PLUGIN/scripts/telemetry.py" "$TT" record "$1" 2>&1; }
check "record: unknown kind rejected" "INVALID" "$(rec '{"kind":"bogus","task":"1","ts":"2026-01-01T00:00:00Z"}')"
check "record: malformed json rejected" "INVALID" "$(rec 'not-json')"
check "record: missing ts rejected" "INVALID" "$(rec '{"kind":"gate","task":"1","ok":true}')"
check "record: transition ok" "OK: recorded transition" "$(rec '{"kind":"transition","task":"1","from":"","to":"In progress","ts":"2026-01-01T00:00:00Z"}')"
check "record: gate ok" "OK: recorded gate" "$(rec '{"kind":"gate","task":"1","ok":true,"ts":"2026-01-01T01:00:00Z"}')"
check "record: gate.ok must be boolean" "INVALID" "$(rec '{"kind":"gate","task":"1","ok":"yes","ts":"2026-01-01T01:00:00Z"}')"
check "record: review-round ok" "OK: recorded review-round" "$(rec '{"kind":"review-round","task":"1","round":1,"verdict":"approved","ts":"2026-01-01T02:00:00Z"}')"
check "record: review-round.round must be an int" "INVALID" "$(rec '{"kind":"review-round","task":"1","round":"one","verdict":"approved","ts":"2026-01-01T02:00:00Z"}')"
check "record: task-close ok" "OK: recorded task-close" "$(rec '{"kind":"task-close","task":"1","estimate":3,"ts":"2026-01-01T03:00:00Z"}')"
check "record: task-close.estimate must be a number" "INVALID" "$(rec '{"kind":"task-close","task":"1","estimate":"big","ts":"2026-01-01T03:00:00Z"}')"
n="$(wc -l < "$TT/.claude/telemetry.jsonl" | tr -d ' ')"
if [[ "$n" == "4" ]]; then echo "ok   record: 4 valid records appended, invalid ones did not land"
else echo "FAIL record: expected 4 lines in telemetry.jsonl, got $n"; fails=$((fails + 1)); fi
rm -rf "$TT"

echo "== telemetry.py metrics (missing / garbage log) =="
TE="$(mktemp -d)"; mkdir -p "$TE/.claude"
check "metrics: missing log" "no telemetry yet" "$(python3 "$PLUGIN/scripts/telemetry.py" "$TE" metrics)"
printf 'not json\n{"kind":"bogus","task":"1","ts":"x"}\n' > "$TE/.claude/telemetry.jsonl"
out="$(python3 "$PLUGIN/scripts/telemetry.py" "$TE" metrics 2>&1)"
check "metrics: garbage-only log reports no telemetry" "no telemetry yet" "$out"
check "metrics: garbage-only log reports skip count on stderr" "skipped 2 malformed line(s)" "$out"
rm -rf "$TE"

echo "== telemetry.py metrics (fixture log: cycle time, gate, rework, estimate) =="
TF="$(mktemp -d)"; mkdir -p "$TF/.claude"
cp "$FIX/telemetry.jsonl" "$TF/.claude/telemetry.jsonl"
out="$(python3 "$PLUGIN/scripts/telemetry.py" "$TF" metrics 2>&1)"
check "metrics: tasks/events/skipped summary" "tasks=3 events=15 skipped=2" "$out"
check "metrics: cycle time avg for In progress" "In progress  avg=6.0h  n=2" "$out"
check "metrics: cycle time avg for In review" "In review  avg=2.0h  n=2" "$out"
check "metrics: gate first-try rate" "gate first-try rate: 50.0% (1/2 tasks)" "$out"
check "metrics: rework rate" "rework rate: 50.0% (1/2 tasks with review rounds)" "$out"
check "metrics: estimate vs actual task 10" "task=10  estimate=3  actual=6.0h" "$out"
check "metrics: estimate vs actual task 11" "task=11  estimate=5  actual=10.0h" "$out"
rm -rf "$TF"

echo "== board.sh metrics (delegates to telemetry.py) =="
BMT="$(mktemp -d)"; mkdir -p "$BMT/.claude"
cp "$FIX/valid.project.yaml" "$BMT/.claude/project.yaml"
cp "$FIX/telemetry.jsonl" "$BMT/.claude/telemetry.jsonl"
out="$(cd "$BMT" && bash "$PLUGIN/scripts/board.sh" metrics 2>&1)"
check "board.sh metrics delegates to telemetry.py" "gate first-try rate: 50.0% (1/2 tasks)" "$out"
rm -rf "$BMT"

echo "== board.sh move telemetry (transition events; move never fails on telemetry write failure) =="
BM="$(mktemp -d)"; mkdir -p "$BM/.claude"
cp "$FIX/valid.project.yaml" "$BM/.claude/project.yaml"
BMGH="$(mktemp -d)"
cat >"$BMGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
    "project item-list") echo "ITEM_1" ;;
    "project item-edit") echo "edited" ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$BMGH/gh"

out="$(cd "$BM" && PATH="$BMGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 1 "In progress" 2>&1; echo "rc=$?")"
check "move telemetry: move still reports success" "moved #1 -> In progress" "$out"
check "move telemetry: exits 0" "rc=0" "$out"
check "move telemetry: transition event appended" '"kind": "transition"' "$(cat "$BM/.claude/telemetry.jsonl" 2>/dev/null)"
check "move telemetry: to field set" '"to": "In progress"' "$(cat "$BM/.claude/telemetry.jsonl" 2>/dev/null)"
check "move telemetry: task field set" '"task": "1"' "$(cat "$BM/.claude/telemetry.jsonl" 2>/dev/null)"

BM2="$(mktemp -d)"; mkdir -p "$BM2/.claude"
cp "$FIX/valid.project.yaml" "$BM2/.claude/project.yaml"
chmod 555 "$BM2/.claude"
out2="$(cd "$BM2" && PATH="$BMGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 1 "In progress" 2>&1; echo "rc=$?")"
chmod 755 "$BM2/.claude"
check "move telemetry: unwritable .claude does not fail the move" "moved #1 -> In progress" "$out2"
check "move telemetry: unwritable .claude -- still exits 0" "rc=0" "$out2"
rm -rf "$BM" "$BM2" "$BMGH"

echo
if [[ $fails -gt 0 ]]; then echo "$fails test(s) FAILED"; exit 1; fi
echo "all tests passed"
