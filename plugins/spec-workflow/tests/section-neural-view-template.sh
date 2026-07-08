#!/usr/bin/env bash
# section-neural-view-template.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
echo "== neural-view boot crash + favicon + 3D template contract =="
NVHTML="$PLUGIN/templates/neural-view.html"
NVVENDOR_SHA="86bcee248b64f44bcfc23c331ae74619061957d59cab040171dcb6fb5900beb6"
NVCORE_SHA="05b2609338c76cd65daf74f3ac515bc9a5045e1b3b33edc07d8c9bd55250fa90"
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
_nvcorefile="$PLUGIN/templates/vendor/three.core.min.js"
if [[ -f "$_nvcorefile" ]]; then
    got_core_sha="$(shasum -a 256 "$_nvcorefile" | awk '{print $1}')"
    check "vendored three.js core-build sha256 matches the recorded, audited version" "$NVCORE_SHA" "$got_core_sha"
else
    echo "FAIL vendored three.core.min.js is missing at $_nvcorefile"; fails=$((fails + 1))
fi
# generalized split-build guard: every relative import the vendored
# three.module.min.js makes (e.g. `from"./three.core.min.js"`) must itself be
# vendored on disk AND allowlisted in neural-view.py's VENDOR_FILES -- this is
# what should have caught the r0.185.1 re-vendor that silently dropped the
# second file (module imports core, only module was vendored/allowlisted).
if [[ -f "$_nvvendorfile" ]]; then
    _nvpy="$PLUGIN/scripts/neural-view.py"
    _nvimports="$(grep -oE '(from|import)"\./[^"]+"' "$_nvvendorfile" | sed -E 's/^(from|import)"\.\///; s/"$//' | sort -u)"
    if [[ -z "$_nvimports" ]]; then
        echo "FAIL split-build guard found no relative imports to check in three.module.min.js -- extraction regex may be stale"; fails=$((fails + 1))
    else
        while IFS= read -r _nvimport; do
            [[ -z "$_nvimport" ]] && continue
            if [[ -f "$PLUGIN/templates/vendor/$_nvimport" ]]; then
                echo "ok   three.module.min.js's relative import ./$_nvimport is vendored on disk"
            else
                echo "FAIL three.module.min.js imports ./$_nvimport but it is not vendored at $PLUGIN/templates/vendor/$_nvimport"; fails=$((fails + 1))
            fi
            check "three.module.min.js's relative import ./$_nvimport is allowlisted in VENDOR_FILES" "\"$_nvimport\":" "$(cat "$_nvpy")"
        done <<<"$_nvimports"
    fi
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

    # #68 regression: on boot, requestAnimationFrame(frame) fires before the
    # first /graph fetch resolves, so sceneGroup is still null when frame() ->
    # updateVisuals() runs. updateVisuals() iterated sceneGroup.children
    # unconditionally, throwing "Cannot read properties of null (reading
    # 'children')" -- and because the exception was uncaught, it killed
    # frame() before its tail requestAnimationFrame(frame) call re-armed the
    # loop, so the render loop died permanently on frame 1 (black screen even
    # after the graph later loaded). Two independent guards, pinned
    # separately: (1) updateVisuals() must no-op when sceneGroup is null, (2)
    # frame() must always re-arm requestAnimationFrame(frame) even when its
    # body throws, so no future per-frame exception can ever repeat this.
    check "updateVisuals() guards against sceneGroup still being null (pre-first-/graph-build) before touching it" "if(!webglOK || !sceneGroup) return;" "$(cat "$NVHTML")"

    _nvscenegroup="$(mktemp).cjs"
    cat >"$_nvscenegroup" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

// updateVisuals() behavioral check: must not throw when sceneGroup is null
// (the exact pre-graph-load state), independent of the guard's exact wording
// -- this survives a future refactor of the guard as long as the behavior
// (no-throw) holds.
let webglOK = true, sceneGroup = null, nodes = [], tick = 0, REDUCED = true;
let hoveredNode = null, hoveredLink = null;
const performance = { now: () => 0 };
function updateAnims() {}
eval(extract("updateVisuals"));
updateVisuals();
console.log("UPDATEVISUALS_NULL_SCENEGROUP_OK");
NODEJS
    scenegroup_out="$(node "$_nvscenegroup" "$NVHTML" 2>&1)"
    check "updateVisuals() does not throw when sceneGroup is still null (pre-graph-load state)" "UPDATEVISUALS_NULL_SCENEGROUP_OK" "$scenegroup_out"
    rm -f "$_nvscenegroup"

    _nvframe="$(mktemp).cjs"
    cat >"$_nvframe" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

// frame() behavioral check: requestAnimationFrame(frame) must re-arm the
// loop even when the frame body throws (step() is stubbed to throw here,
// simulating any future per-frame exception) -- this is what prevents the
// render loop from dying permanently on a single bad frame, regardless of
// where in frame() the throw originates or how the guard above is worded.
let tick = 0, webglOK = true;
function step() { throw new Error("simulated per-frame exception"); }
function updateVisuals() {}
function updateCameraPosition() {}
const renderer = { render: () => {} };
const scene = {}, camera = {};
let rafCalls = 0;
function requestAnimationFrame(fn) { rafCalls++; }
eval(extract("frame"));
try { frame(); } catch (e) { /* expected: step() throws by design */ }
if (rafCalls !== 1) throw new Error("requestAnimationFrame(frame) was not re-armed when frame()'s body threw: rafCalls=" + rafCalls);
console.log("FRAME_REARM_ON_THROW_OK");
NODEJS
    frame_out="$(node "$_nvframe" "$NVHTML" 2>&1)"
    check "frame() re-arms requestAnimationFrame(frame) even when its body throws" "FRAME_REARM_ON_THROW_OK" "$frame_out"
    rm -f "$_nvframe"

    # #71 regression: userMoved must become true ONLY on a genuine camera
    # gesture (drag past a small pixel threshold, wheel, or pinch) -- never on
    # a bare pointerdown/pointerup with no real movement (e.g. clicking the
    # page/tab to focus it, which still fires a sub-pixel-to-few-pixel
    # pointermove jitter). Before the fix, the pointermove handler called
    # orbitBy()/panBy() (which set userMoved=true) on ANY move while a single
    # pointer was down, with no threshold gate -- so that jitter alone
    # cancelled the pending first /graph auto-fit and the constellation
    # rendered off-viewport until a manual (V) reset.
    #
    # The pointer handlers are addEventListener callbacks, not named
    # functions, so the generic extract() pattern (which anchors on
    # "function name(...){...}\n}\n") doesn't apply here. Instead we slice the
    # literal wiring block between two unique, stable substrings already
    # present in the template (the pointers Map declaration through the end
    # of the wheel listener) and eval it against a stub canvas/THREE, then
    # drive it with synthetic pointer/wheel events -- this pins the actual
    # runtime behavior of the handlers, not just their source text.
    _nvusermoved="$(mktemp).cjs"
    cat >"$_nvusermoved" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

const startMarker = "const pointers = new Map();";
const endMarker = "}, {passive:false});";
const startIdx = html.indexOf(startMarker);
const endIdx = html.indexOf(endMarker, startIdx);
if (startIdx === -1 || endIdx === -1) throw new Error("could not locate the pointer-interaction wiring block (pointerdown..wheel) in template -- markers may be stale");
const block = html.slice(startIdx, endIdx + endMarker.length);

function extractOneLine(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

const handlers = {};
const canvas = {
    addEventListener(type, fn) { handlers[type] = fn; },
    setPointerCapture() {},
    classList: { add() {}, remove() {} },
};
const webglOK = true;
let userMoved = false;
let theta = 0, phi = 1, radius = 900, target = {x: 0, y: 0, z: 0};
const MIN_DIST = 80, MAX_DIST = 6000;
function updateCameraPosition() {}
function hitTest() {}
function hideTooltip() {}
function hoverTest() {}
let hoverThrottle = 0;
global.performance = {now: () => 0};
class Vector3Stub { constructor(x, y, z) { this.x = x; this.y = y; this.z = z; } applyQuaternion() { return this; } }
const THREE = {Vector3: Vector3Stub};
const camera = {quaternion: {}};

eval(block);
eval(extractOneLine("resetView"));
function applyFit() {}   // resetView() calls this; layout is irrelevant here

function fireEvent(type, x, y, extra) {
    handlers[type](Object.assign({clientX: x, clientY: y, pointerId: 1, button: 0, shiftKey: false, preventDefault(){}}, extra || {}));
}

// case (a): bare pointerdown/pointerup, no movement at all -- must not set userMoved.
fireEvent("pointerdown", 100, 100);
fireEvent("pointerup", 100, 100);
if (userMoved) throw new Error("a bare pointerdown/pointerup with zero movement set userMoved=true");

// case (a'): pointerdown + sub-threshold jitter (the realistic click case) + pointerup -- must not set userMoved.
fireEvent("pointerdown", 100, 100);
fireEvent("pointermove", 101, 100);   // 1px jitter, well under the drag threshold
fireEvent("pointerup", 101, 100);
if (userMoved) throw new Error("a click's sub-pixel-threshold pointermove jitter set userMoved=true (the #71 regression)");

// case (b): a real drag past the threshold DOES set userMoved.
fireEvent("pointerdown", 200, 200);
fireEvent("pointermove", 300, 200);   // 100px, well past any reasonable threshold
if (!userMoved) throw new Error("a real drag past the movement threshold did not set userMoved=true");
fireEvent("pointerup", 300, 200);

// case (c): wheel always counts as a real interaction, no threshold.
userMoved = false;
handlers["wheel"]({deltaY: 10, preventDefault(){}});
if (!userMoved) throw new Error("a wheel event did not set userMoved=true");

// case (d): a two-pointer pinch always counts as a real interaction, no threshold.
userMoved = false;
fireEvent("pointerdown", 100, 100, {pointerId: 1});
fireEvent("pointerdown", 120, 100, {pointerId: 2});
fireEvent("pointermove", 121, 100, {pointerId: 2});   // 1px pinch move
if (!userMoved) throw new Error("a two-pointer pinch move did not set userMoved=true");
fireEvent("pointerup", 121, 100, {pointerId: 1});
fireEvent("pointerup", 121, 100, {pointerId: 2});

// case (e): resetView() unregressed -- clears userMoved back to false.
userMoved = true;
resetView();
if (userMoved) throw new Error("resetView() did not clear userMoved back to false");

console.log("USERMOVED_GATED_ON_REAL_INTERACTION_OK");
NODEJS
    usermoved_out="$(node "$_nvusermoved" "$NVHTML" 2>&1)"
    check "userMoved is set only by a real drag past threshold, wheel, or pinch -- never a bare click/jitter (#71)" "USERMOVED_GATED_ON_REAL_INTERACTION_OK" "$usermoved_out"
    rm -f "$_nvusermoved"
fi

