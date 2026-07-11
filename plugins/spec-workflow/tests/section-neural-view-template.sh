#!/usr/bin/env bash
# section-neural-view-template.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== neural-view boot crash + favicon + 3D template contract =="
NVHTML="$PLUGIN/templates/neural-view.html"
NVVENDOR_SHA="86bcee248b64f44bcfc23c331ae74619061957d59cab040171dcb6fb5900beb6"
NVCORE_SHA="05b2609338c76cd65daf74f3ac515bc9a5045e1b3b33edc07d8c9bd55250fa90"
check_absent "resize() no longer assigns read-only canvas.clientWidth" "canvas.clientWidth =" "$(cat "$NVHTML")"
check_absent "resize() no longer assigns read-only canvas.clientHeight" "canvas.clientHeight =" "$(cat "$NVHTML")"
check_absent "template has no CDN/external script or asset references" 'src="http' "$(cat "$NVHTML")"
check "template's importmap points three at the vendored, same-origin file" '"three":"/vendor/three.module.min.js"' "$(cat "$NVHTML")"
check "template imports three via the importmap specifier, not a URL" 'from "three"' "$(cat "$NVHTML")"
check "template wires an ambient directional pulse layer for synapse links (batched)" 'synPulses = REDUCED ? null : makePulseLayer(CORE_TEX, links.length)' "$(cat "$NVHTML")"
check "ambient synapse pulses are gated by the reduced-motion check" 'REDUCED ? null : makePulseLayer(CORE_TEX' "$(cat "$NVHTML")"
check "ambient pulse position is interpolated from the link's live endpoints (l.a/l.b), not a cached copy" "mix(aA, aB, p)" "$(cat "$NVHTML")"
check "template has a tooltip DOM element for hover inspection" 'id="tooltip"' "$(cat "$NVHTML")"
check "tooltip is positioned fixed and never intercepts pointer events" "pointer-events:none;z-index:50" "$(cat "$NVHTML")"
check "pointermove wires a throttled hover raycast" "hoverTest(ev.clientX, ev.clientY)" "$(cat "$NVHTML")"
check "hitTest(clientX, clientY) keeps its signature -- only its raycast target set changes (#88)" "function hitTest(clientX, clientY){" "$(cat "$NVHTML")"
# #72/#88 (superseded by the neural-view-perf rewrite, fe7999d): hover/click
# picking no longer raycasts three.js objects at all -- note halos are one
# batched instanced sprite layer with no per-node object to raycast, so
# hoverTest()/hitTest() both project each node's world position to CSS pixels
# (pickNoteAt(), screen-space picking) and compare against a pixel radius.
# The nd._halo (nd.r*6) vs nd._core (nd.r*2) distinction lives on in that
# radius: pickNoteAt() sizes its hit test off nd.r*1.8 -- big enough to cover
# the visible glow, not just the tiny bright core -- so hover and click still
# share exactly one hit-area definition (one function, not two raycast target
# sets that could drift apart again).
check "note halo renders as a batched instanced layer (hover stays screen-space via pickNoteAt)" 'noteHalo = makeNoteLayer(HALO_TEX, nodes.length, true)' "$(cat "$NVHTML")"
check "pickNoteAt()'s hit radius covers the visible glow, not just the small core (screen-space picking, not raycasting) (#72)" "const rPix = worldToPixels(nd.r*1.8, p.depth);" "$(cat "$NVHTML")"
# #88: click-to-inspect (hitTest) and the dblclick empty-space guard must use
# the SAME pick as hover (pickNoteAt) -- previously hitTest raycast a
# separate, smaller core-only target set, so a note that showed a tooltip on
# hover could miss when clicked. Now both call pickNoteAt() directly, so
# there is no second target set left to drift out of alignment.
check_absent "hitTest()/dblclick guard no longer raycast the tiny core sprite -- must match hover's halo hit area (#88)" "nd=>nd._core).filter(Boolean)" "$(cat "$NVHTML")"
check "hitTest()'s note target is pickNoteAt(), the same screen-space pick hover uses (#88)" "const nd = pickNoteAt(clientX, clientY);" "$(cat "$NVHTML")"
# #72: the repo region boundary must be raycast as its rendered wireframe
# lines (so raycaster.params.Line.threshold narrows hits to near the visible
# lines), not as the underlying solid icosahedron Mesh -- a Mesh's face
# raycast hits anywhere in the projected disc, including the translucent
# interior that reads as empty space. LineSegments+EdgesGeometry render
# identically (three.js's Mesh wireframe:true already draws the same edges
# via gl.LINES) but raycast through the Line path instead of triangle faces.
check "repo region is built from EdgesGeometry so its rendered wireframe is exactly what's raycast" "new THREE.EdgesGeometry(geo)" "$(cat "$NVHTML")"
check "repo region hit target is a LineSegments object, not a solid Mesh, so raycasting respects Line.threshold" "new THREE.LineSegments(edges, mat)" "$(cat "$NVHTML")"
# #72: visible affordance -- cursor becomes pointer while a hover target is
# under the pointer, composing with (not replacing) the existing grab/
# grabbing drag cursors.
check "canvas gets a hoverable class when a hover target is found, driving the cursor affordance" 'canvas.classList.add("hoverable")' "$(cat "$NVHTML")"
check "canvas loses the hoverable class once no hover target is under the pointer" 'canvas.classList.remove("hoverable")' "$(cat "$NVHTML")"
check "CSS gives .hoverable canvas a pointer cursor without breaking grab/grabbing" "canvas.hoverable{cursor:pointer}" "$(cat "$NVHTML")"
check_absent "hover/projects/sessions code introduces no external fetch" 'fetch("http' "$(cat "$NVHTML")"
check "template polls GET /projects" 'fetch("/projects")' "$(cat "$NVHTML")"
check "template polls GET /sessions" 'fetch("/sessions")' "$(cat "$NVHTML")"
# #75: BRAINS panel groups per repo (never a flat cross-repo list) -- one
# repo-brains section per repo, orchestrator-first-then-alphabetical roles
# within it, and empty (zero-note) roles get a dimmed row instead of being
# omitted entirely (the omission is what made every repo look like a single
# shared brain trio).
check "loadGraph() stores the server's per-repo role list for the BRAINS panel" 'window.__repoRoles = g.repoRoles || {};' "$(cat "$NVHTML")"
check "orderedRoles() puts orchestrator first, remaining roles alphabetical" 'return known.includes("orchestrator") ? ["orchestrator", ...rest] : rest;' "$(cat "$NVHTML")"
check "renderGauges() builds one repo-brains section per repo" 'section.className="repo-brains";' "$(cat "$NVHTML")"
# row.className also grew a brainrow-hidden suffix (the #73-adjacent
# per-brain "hide from totals/scene" eye toggle) since this check was
# written -- the empty/non-empty dimming half of the expression is unchanged.
check "renderGauges() dims a role's row instead of omitting it when it has zero notes" 'row.className = (n ? "brainrow" : "brainrow brainrow-empty") + (hidden ? " brainrow-hidden" : "");' "$(cat "$NVHTML")"
check "CSS dims empty brain rows without hiding them" ".brainrow-empty{opacity:.4}" "$(cat "$NVHTML")"
check "CSS gives each repo section its own header" ".repo-brains-h{" "$(cat "$NVHTML")"
# #75 micro-fix: the repo-hover tooltip must not double up "board unavailable"
# when the server itself already prefixes proj.error with it -- render
# as-is in that case, prepend locally only when the server hasn't (yet).
check "tooltipHtml() renders proj.error as-is when the server already prefixed it with board unavailable" '/^board unavailable/i.test(raw) ? raw : (raw ? "board unavailable: "+raw : "board unavailable")' "$(cat "$NVHTML")"
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
// comboHue() (used by layoutClusters() when it records each cluster's color)
// normally reads window.__roleColors set by the server payload -- stubbed
// straight through to roleHue() here since color isn't what this fixture
// asserts (region sizing/framing is).
function comboHue(repo, role) { return roleHue(role); }
// updateSceneScale() (called at the end of layoutClusters() to grow the far
// plane/fog for big corpora) is a THREE.js/camera side effect out of scope
// for this pure-math fixture -- stubbed to a no-op, with webglOK/camera
// stubbed so ITS OWN early-return guard doesn't need a real renderer.
let webglOK = false, camera = null;
function updateSceneScale() {}
// ballR()/BALL_K (a brain of n notes settles into a ball of radius
// BALL_K*cbrt(n) -- see the comment above the real definition) is a const
// arrow function, not a `function` declaration, so extract()'s regex (which
// requires "function name(...)") can't pull it out like the others; hand-
// written here to match the template's definition verbatim.
const BALL_K = 55;
const ballR = n => BALL_K * Math.cbrt(Math.max(1, n));

eval(extract("fibSphere"));
eval(extract("packByRadius"));
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
function updateFly() {}
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

    # #72 (superseded by the neural-view-perf rewrite, fe7999d): hoverTest()
    # must resolve overlapping hits by an explicit kind priority (note >
    # synapse/pulse > brain/role label > repo label > repo region), NOT by
    # raw distance -- a repo region can sit "behind" a note in world space
    # yet still be the nearer pixel hit, and pure nearest-wins would let the
    # coarser region shadow the more specific note. Picking is no longer
    # three.js raycasting at all (see the pickNoteAt() comment above pick*()
    # in the template) -- every pick*At() function projects world positions
    # to CSS pixels and measures pixel distance, so this fixture drives the
    # real extracted pickNoteAt()/pickSynapseAt()/pickRoleLabelAt()/
    # pickRepoAt()/hoverTest() with a stubbed projectToScreen()/
    # worldToPixels() (an identity projection: screen coords == world x/y,
    # fixed depth) so every candidate's hit/no-hit outcome is fully
    # controllable by its world position, without needing real camera/FOV
    # math (which isn't what this fixture is pinning).
    _nvhovertest="$(mktemp).cjs"
    cat >"$_nvhovertest" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

const webglOK = true;
const MIN_REGION = 46;
let sceneGroup = {};   // hoverTest() only checks truthiness, never traverses it
let nodes = [], links = [], liveClusterCenters = new Map(), liveRepoCenters = new Map(), repoCenters = new Map(), repoRadius = new Map(), repoList = [];
let hoveredNode = null, hoveredLink = null;
let lastTooltipKind = null, hoverableSet = null;
const canvas = { classList: {
    add(c) { if (c === "hoverable") hoverableSet = true; },
    remove(c) { if (c === "hoverable") hoverableSet = false; },
} };
function hideTooltip() { hoveredNode = null; hoveredLink = null; lastTooltipKind = null; canvas.classList.remove("hoverable"); }
function showTooltip(x, y, html) { lastTooltipKind = html; canvas.classList.add("hoverable"); }
function tooltipHtml(ud) { return ud.kind; }
function projectToScreen(x, y, z) { return { x, y, depth: 1 }; }
function worldToPixels(worldSize) { return worldSize; }

eval(extract("pickNoteAt"));
eval(extract("distToSegment"));
eval(extract("pickSynapseAt"));
eval(extract("pickRepoAt"));
eval(extract("pickRoleLabelAt"));
eval(extract("hoverTest"));

const CX = 100, CY = 100;
function reset() {
    hoveredNode = null; hoveredLink = null; lastTooltipKind = null; hoverableSet = null;
    nodes = []; links = []; liveClusterCenters = new Map();
    // a far-away second repo keeps pickRepoAt()'s repoList.length<2 guard
    // from short-circuiting it in every tier.
    repoList = ["r1", "r2"];
    repoCenters = new Map([["r2", { x: 9000, y: 9000, z: 0 }]]);
    repoRadius = new Map([["r2", 10]]);
}

// tier 1: note wins over every other kind, all of which would otherwise hit.
reset();
nodes = [{ x: CX, y: CY, z: 0, r: 5, slug: "n1" }];
links = [{ a: { x: CX - 10, y: CY, z: 0 }, b: { x: CX + 10, y: CY, z: 0 }, w: 1 }];
liveClusterCenters = new Map([["r1|dev", { x: CX, y: CY - 26, z: 0, n: 3 }]]);
repoCenters.set("r1", { x: CX, y: CY - 56, z: 0 }); repoRadius.set("r1", 30);
hoverTest(CX, CY);
if (lastTooltipKind !== "note") throw new Error("note did not win top priority: got " + lastTooltipKind);
if (hoverableSet !== true) throw new Error("hoverable class was not set on a note hit");

// tier 2: no note -- synapse must win over brain/repoLabel/repoRegion.
reset();
links = [{ a: { x: CX - 10, y: CY, z: 0 }, b: { x: CX + 10, y: CY, z: 0 }, w: 1 }];
liveClusterCenters = new Map([["r1|dev", { x: CX, y: CY - 26, z: 0, n: 3 }]]);
repoCenters.set("r1", { x: CX, y: CY - 56, z: 0 }); repoRadius.set("r1", 30);
hoverTest(CX, CY);
if (lastTooltipKind !== "synapse") throw new Error("synapse did not win priority over brain/repoLabel/repoRegion: got " + lastTooltipKind);

// tier 3: no note/synapse -- brain (role) label must win over repoLabel/repoRegion.
reset();
liveClusterCenters = new Map([["r1|dev", { x: CX, y: CY - 26, z: 0, n: 3 }]]);
repoCenters.set("r1", { x: CX, y: CY - 56, z: 0 }); repoRadius.set("r1", 30);
hoverTest(CX, CY);
if (lastTooltipKind !== "brain") throw new Error("brain (role) label did not win priority over repoLabel/repoRegion: got " + lastTooltipKind);

// tier 4: no note/synapse/brain -- repo label must win over repo region.
reset();
repoCenters.set("r1", { x: CX, y: CY - 56, z: 0 }); repoRadius.set("r1", 30);
hoverTest(CX, CY);
if (lastTooltipKind !== "repoLabel") throw new Error("repoLabel did not win priority over repoRegion: got " + lastTooltipKind);

// tier 5: only the region rim hits -- region is the fallback, lowest priority.
reset();
repoCenters.set("r1", { x: CX - 30, y: CY, z: 0 }); repoRadius.set("r1", 30);
hoverTest(CX, CY);
if (lastTooltipKind !== "repoRegion") throw new Error("repoRegion (the only hit) was not reported: got " + lastTooltipKind);

// nothing hits -- tooltip hides and the hoverable affordance clears.
reset();
repoList = [];
hoverTest(CX, CY);
if (lastTooltipKind !== null) throw new Error("a tooltip was shown with no hits: " + lastTooltipKind);
if (hoverableSet !== false) throw new Error("hoverable class was not cleared with no hits");

console.log("HOVERTEST_PRIORITY_OK");
NODEJS
    hovertest_out="$(node "$_nvhovertest" "$NVHTML" 2>&1)"
    check "hoverTest() resolves overlapping hits by kind priority (note > synapse/pulse > brain label > repoLabel > repoRegion) and drives the hoverable cursor affordance" "HOVERTEST_PRIORITY_OK" "$hovertest_out"
    rm -f "$_nvhovertest"

    # #88 behavioral (superseded by the neural-view-perf rewrite, fe7999d):
    # hitTest() (click-to-inspect) and the dblclick empty-space guard must
    # both pick a note through the exact same function hoverTest() does
    # (pickNoteAt()) -- previously hitTest raycast a separate, core-only
    # target set, so a note that showed a tooltip on hover could be missed by
    # a click at the same spot. Drives the real extracted pickNoteAt()/
    # pickRoleLabelAt()/hitTest() and the anonymous dblclick listener (sliced
    # by unique markers, same pattern as the #71/#73 pointer-wiring
    # harnesses) with the same stubbed identity projection as the hoverTest
    # fixture above, so hits/misses are driven by world position, not a fake
    # raycaster.
    _nvhittest="$(mktemp).cjs"
    cat >"$_nvhittest" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
const dblStart = html.indexOf('canvas.addEventListener("dblclick", ev=>{');
const dblEndMarker = "resetView();\n});";
const dblEndIdx = html.indexOf(dblEndMarker, dblStart);
if (dblStart === -1 || dblEndIdx === -1) throw new Error("could not locate the dblclick listener block -- markers may be stale");
const dblBlock = html.slice(dblStart, dblEndIdx + dblEndMarker.length);

const webglOK = true;
let nodes = [], liveClusterCenters = new Map();
function projectToScreen(x, y, z) { return { x, y, depth: 1 }; }
function worldToPixels(worldSize) { return worldSize; }

let openNoteCalls = [];
function openNote(nd) { openNoteCalls.push(nd); }
let flyToClusterCalls = [];
function flyToCluster(repo, role) { flyToClusterCalls.push({ repo, role }); }
let resetViewCalls = 0;
function resetView() { resetViewCalls++; }

eval(extract("pickNoteAt"));
eval(extract("pickRoleLabelAt"));
eval(extract("hitTest"));
eval(dblBlock.replace('canvas.addEventListener("dblclick", ev=>{', "function dblclickHandler(ev){").replace(/\}\);\s*$/, "}"));

// case 1: click lands on a note (pickNoteAt()'s nd.r*1.8 pixel radius) --
// hitTest() must open it, proving its note target is the same pick hover uses.
nodes = [{ x: 100, y: 100, z: 0, r: 5, slug: "n1" }];
hitTest(100, 100);
if (openNoteCalls.length !== 1 || openNoteCalls[0].slug !== "n1") throw new Error("hitTest() did not open the note under the cursor -- it is not using pickNoteAt()");

// case 2: no note under the cursor, but a brain (role) label is -- flies to
// that cluster.
nodes = [];
liveClusterCenters = new Map([["r1|dev", { x: 200, y: 200, z: 0, n: 3 }]]);
hitTest(200, 226);   // pickRoleLabelAt() projects (s.x, s.y+26, s.z)
if (flyToClusterCalls.length !== 1 || flyToClusterCalls[0].repo !== "r1" || flyToClusterCalls[0].role !== "dev") throw new Error("hitTest() did not fly to the brain label under the cursor");

// case 3: dblclick on a note -- must NOT reset (aligned with hitTest's own
// pickNoteAt() target, so a note reachable by a single click is also exempt).
nodes = [{ x: 500, y: 500, z: 0, r: 5, slug: "n2" }];
resetViewCalls = 0;
dblclickHandler({ clientX: 500, clientY: 500 });
if (resetViewCalls !== 0) throw new Error("dblclick on a note must not reset the view (guard not aligned with hitTest's pickNoteAt target)");

// case 4: dblclick on real empty space (nothing hits) -- reset must still fire.
nodes = [];
resetViewCalls = 0;
dblclickHandler({ clientX: 9999, clientY: 9999 });
if (resetViewCalls !== 1) throw new Error("dblclick on empty space must still reset the view");

console.log("HITTEST_HALO_ALIGNED_OK");
NODEJS
    hittest_out="$(node "$_nvhittest" "$NVHTML" 2>&1)"
    check "hitTest() and the dblclick empty-space guard pick notes through the same pickNoteAt() hover uses (#88)" "HITTEST_HALO_ALIGNED_OK" "$hittest_out"
    rm -f "$_nvhittest"

    # #75 behavioral: renderGauges() must (a) group into one section per repo
    # in repoList order, (b) order roles orchestrator-first-then-alphabetical
    # within each section via orderedRoles(), and (c) still render a role with
    # zero notes as a dimmed row rather than omitting it -- the exact bug that
    # made two repos with no notes yet invisible and every repo look like one
    # shared brain trio. A minimal fake DOM (createElement/getElementById
    # returning plain objects that track className/innerHTML/children) drives
    # the real extracted functions instead of re-implementing their logic.
    _nvgauges="$(mktemp).cjs"
    cat >"$_nvgauges" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
function extractOneLine(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

function makeEl() {
    return {
        _className: "", _children: [], _html: "", _attrs: {},
        set className(v) { this._className = v; }, get className() { return this._className; },
        set innerHTML(v) { this._html = v; }, get innerHTML() { return this._html; },
        appendChild(c) { this._children.push(c); },
        setAttribute(k, v) { this._attrs[k] = v; },
    };
}
let gaugeList;
const document = {
    getElementById(id) { if (id === "gauge-list") return gaugeList; throw new Error("unexpected getElementById(" + id + ")"); },
    createElement() { return makeEl(); },
};
const clusterKey = (repo, role) => repo + "|" + role;
function roleHue() { return 190; }
// comboHue() (see the layoutClusters fixture's own comment above) is stubbed
// straight through to roleHue() -- color isn't what this fixture asserts.
function comboHue(repo, role) { return roleHue(role); }
function cssColor() { return "hsla(190,95%,72%,.95)"; }
function arc() { return "<svg></svg>"; }
// isBrainHidden() (the #73-adjacent per-brain "hide from totals/scene"
// toggle) reads uiState/localStorage -- stubbed to "nothing is hidden" since
// that toggle isn't what this fixture asserts (grouping/ordering/dimming).
function isBrainHidden() { return false; }
function dispName(repo) { return repo; }
let uiState = {};
function saveUiState() {}
function openTalkPanel() {}
const WHOLE_BRAIN = "__whole__";
eval(extractOneLine("escapeHtml"));
eval(extractOneLine("orderedRoles"));
eval(extract("renderGauges"));

// fixture: two repos, alphabetical (repo-a, repo-b). repo-a has all three
// canonical roles with dev the only one carrying a note; repo-b is entirely
// brainless (all three roles present in repoRoles, zero notes for any).
let repoList = ["repo-a", "repo-b"];
window = { __repoRoles: {
    "repo-a": ["dev", "orchestrator", "reviewer"],
    "repo-b": ["dev", "orchestrator", "reviewer"],
} };
let nodes = [{ repo: "repo-a", role: "dev", strength: 3 }];
let links = [];

gaugeList = makeEl();
renderGauges();

// each repo-brains section is [hrow (header + talk button), rows (the
// actual role rows)] -- the #73 fly-to-cluster rewrite added the collapse
// header row and the rows wrapper div; role rows are no longer direct
// children of the section.
if (gaugeList._children.length !== 2) throw new Error("expected one repo-brains section per repo, got " + gaugeList._children.length);
const [secA, secB] = gaugeList._children;
if (secA.className !== "repo-brains" || secB.className !== "repo-brains") throw new Error("sections must use the repo-brains class");
const [hrowA, rowsA] = secA._children, [hrowB, rowsB] = secB._children;
if (hrowA._children[0].textContent !== "repo-a") throw new Error("repo-a section header missing repo name: " + hrowA._children[0].textContent);
if (hrowB._children[0].textContent !== "repo-b") throw new Error("repo-b section header missing repo name: " + hrowB._children[0].textContent);

if (rowsA._children.length !== 3) throw new Error("expected 3 role rows in repo-a (canonical roles), got " + rowsA._children.length);
const rolesA = rowsA._children.map(r => { const m = r.innerHTML.match(/class="rname"[^>]*>([a-z]+)</); return m ? m[1] : null; });
if (rolesA.join(",") !== "orchestrator,dev,reviewer") throw new Error("repo-a roles not orchestrator-first-then-alphabetical: " + rolesA.join(","));

const devRow = rowsA._children[1];
if (devRow.className !== "brainrow") throw new Error("repo-a's dev row (has a note) must not be dimmed: " + devRow.className);
const orchRowA = rowsA._children[0], revRowA = rowsA._children[2];
if (orchRowA.className !== "brainrow brainrow-empty") throw new Error("repo-a's note-less orchestrator row must be dimmed: " + orchRowA.className);
if (revRowA.className !== "brainrow brainrow-empty") throw new Error("repo-a's note-less reviewer row must be dimmed: " + revRowA.className);

if (rowsB._children.length !== 3) throw new Error("expected 3 role rows in repo-b (brainless repo), got " + rowsB._children.length);
for (const row of rowsB._children) {
    if (row.className !== "brainrow brainrow-empty") throw new Error("every role in a brainless repo must render as a dimmed row, not be omitted: " + row.className);
}

console.log("RENDERGAUGES_GROUPED_ORDERED_EMPTY_OK");
NODEJS
    gauges_out="$(node "$_nvgauges" "$NVHTML" 2>&1)"
    check "renderGauges() groups per repo, orders orchestrator-first-then-alphabetical, and renders empty brains as dimmed rows instead of omitting them (#75)" "RENDERGAUGES_GROUPED_ORDERED_EMPTY_OK" "$gauges_out"
    rm -f "$_nvgauges"

    # #73: clicking a brain row in the BRAINS panel flies the camera to frame
    # that brain's cluster. Structural wiring first (cursor affordance,
    # click/keyboard handlers on every row -- including empty ones, so a
    # 0-note brain is still reachable and falls back to its repo region).
    check "CSS gives every brain row a pointer cursor, signalling it's clickable (#73)" ".brainrow{cursor:pointer;" "$(cat "$NVHTML")"
    check "CSS gives brain rows a hover/focus affordance consistent with the rest of the HUD (#73)" ".brainrow:hover,.brainrow:focus-visible{" "$(cat "$NVHTML")"
    check "brain rows are keyboard-focusable so Enter can trigger the fly-to (#73)" "row.tabIndex = 0;" "$(cat "$NVHTML")"
    check "brain rows expose a button role for assistive tech (#73)" 'row.setAttribute("role", "button");' "$(cat "$NVHTML")"
    check "clicking a brain row flies the camera to that (repo,role) cluster (#73)" "row.onclick = ()=>flyToCluster(repo, role);" "$(cat "$NVHTML")"
    check "Enter on a focused brain row triggers the same fly-to as a click (#73)" 'if(ev.key==="Enter"){ ev.preventDefault(); flyToCluster(repo, role); }' "$(cat "$NVHTML")"
    check "frame() steps the in-flight fly-to animation every frame before repositioning the camera (#73)" "updateFly();" "$(cat "$NVHTML")"

    # #73 behavioral: clusterSphere()/distanceForSphere() -- the fly-to framing
    # math, mirroring boundingSphere()/fitDistance()'s centroid+margin+FOV-fit
    # approach but scoped to one (repo,role) cluster's own nodes instead of the
    # whole graph. Covers: correct centroid/radius over just that cluster's
    # nodes (excluding other roles), and the empty-cluster -> repo-region
    # fallback (acceptance criterion 3 -- no NaN/crash on a 0-note brain).
    _nvclustersphere="$(mktemp).cjs"
    cat >"$_nvclustersphere" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
const MIN_DIST = 80, MAX_DIST = 6000, FOV = 50 * Math.PI / 180, MIN_REGION = 46;
let nodes, repoCenters, repoRadius;
eval(extract("clusterSphere"));
eval(extract("distanceForSphere"));

// case 1: a populated cluster -- centroid is the mean of ITS OWN nodes only
// (a same-repo different-role node must not skew it), and the radius covers
// the farthest node's own extent (distance from centroid + that node's r),
// not just a floor.
nodes = [
  {repo: "r1", role: "dev", x: 0, y: 0, z: 0, r: 5},
  {repo: "r1", role: "dev", x: 200, y: 0, z: 0, r: 5},
  {repo: "r1", role: "reviewer", x: 999, y: 999, z: 999, r: 5},
];
repoCenters = new Map([["r1", {x: 0, y: 0, z: 0}]]);
repoRadius = new Map([["r1", 100]]);
let b = clusterSphere("r1", "dev");
if (Math.abs(b.x - 100) > 0.001 || b.y !== 0 || b.z !== 0) throw new Error("centroid must be the mean of only this cluster's own nodes: " + JSON.stringify(b));
if (b.r < 100) throw new Error("radius must cover the farthest node's own extent, not just a floor: got " + b.r);

// case 2: an empty cluster (zero notes for this repo/role) falls back to
// framing the repo region instead of NaN/crashing (#73 acceptance 3).
nodes = [];
b = clusterSphere("r1", "dev");
if (Number.isNaN(b.x) || Number.isNaN(b.r)) throw new Error("empty cluster produced NaN: " + JSON.stringify(b));
if (b.x !== 0 || b.y !== 0 || b.z !== 0) throw new Error("empty cluster must fall back to its repo's own center: " + JSON.stringify(b));
if (Math.abs(b.r - 130) > 0.001) throw new Error("empty cluster must fall back to repoRadius+30: got " + b.r);

// case 3: an empty cluster in a repo with no layout yet still returns a sane,
// non-NaN sphere (pre-/graph-load safety, same spirit as fitDistance()'s
// single-origin-point boot fallback).
repoCenters = new Map(); repoRadius = new Map();
b = clusterSphere("ghost-repo", "dev");
if (Number.isNaN(b.x) || Number.isNaN(b.r)) throw new Error("unknown-repo empty cluster produced NaN: " + JSON.stringify(b));

// distanceForSphere(): same FOV-fit formula as fitDistance() (margin*1.35,
// clamped to [MIN_DIST,MAX_DIST]), applied to an arbitrary sphere.
const fit = distanceForSphere({x: 1, y: 2, z: 3, r: 50}, 1600 / 900);
if (fit.target.x !== 1 || fit.target.y !== 2 || fit.target.z !== 3) throw new Error("distanceForSphere()'s target must equal the sphere's own center: " + JSON.stringify(fit));
if (fit.distance < MIN_DIST || fit.distance > MAX_DIST) throw new Error("distanceForSphere() distance out of clamp range: " + fit.distance);

console.log("CLUSTERSPHERE_OK");
NODEJS
    clustersphere_out="$(node "$_nvclustersphere" "$NVHTML" 2>&1)"
    check "clusterSphere() bounds one (repo,role) cluster's own nodes (centroid+radius), falling back to the repo region when empty (#73)" "CLUSTERSPHERE_OK" "$clustersphere_out"
    rm -f "$_nvclustersphere"

    # #73 behavioral: flyToCluster()/updateFly() -- the fly-to counts as taking
    # the wheel (userMoved=true, so auto-refit doesn't fight it); under
    # prefers-reduced-motion it jumps the camera instantly (no animation
    # object, camera repositioned synchronously); otherwise it starts a short
    # eased animation that updateFly() converges to the exact destination by
    # the animation's own duration, then clears itself.
    _nvflytocluster="$(mktemp).cjs"
    cat >"$_nvflytocluster" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

const MIN_DIST = 80, MAX_DIST = 6000, FOV = 50 * Math.PI / 180, MIN_REGION = 46;
let nodes = [{repo: "r1", role: "dev", x: 50, y: 0, z: 0, r: 5}];
let repoCenters = new Map([["r1", {x: 0, y: 0, z: 0}]]);
let repoRadius = new Map([["r1", 100]]);
let W = 1600, H = 900;
const webglOK = true;
let target = {x: 0, y: 0, z: 0}, radius = 900;
let flyAnim = null;
let userMoved = false;
let updateCameraPositionCalls = 0;
function updateCameraPosition() { updateCameraPositionCalls++; }
let nowVal = 0;
global.performance = { now: () => nowVal };

eval(extract("clusterSphere"));
eval(extract("distanceForSphere"));

// case (a): prefers-reduced-motion -- instant jump, no animation object, the
// camera is repositioned synchronously (not left for a future frame).
let REDUCED = true;
eval(extract("flyToCluster"));
flyToCluster("r1", "dev");
if (!userMoved) throw new Error("flyToCluster() did not set userMoved=true under reduced motion");
if (flyAnim !== null) throw new Error("reduced motion must jump instantly, not create an animation");
if (updateCameraPositionCalls !== 1) throw new Error("reduced motion must reposition the camera synchronously: calls=" + updateCameraPositionCalls);
if (target.x <= 0) throw new Error("reduced motion did not move the target toward the cluster: " + JSON.stringify(target));

// case (b): motion allowed -- a short animated transition, not an instant
// jump, converging on the same destination that the reduced-motion path
// jumps to directly.
REDUCED = false;
userMoved = false; flyAnim = null; updateCameraPositionCalls = 0;
target = {x: 0, y: 0, z: 0}; radius = 900; nowVal = 0;
flyToCluster("r1", "dev");
if (!userMoved) throw new Error("flyToCluster() did not set userMoved=true");
if (!flyAnim) throw new Error("non-reduced-motion fly-to must start an animation, not jump instantly");
if (updateCameraPositionCalls !== 0) throw new Error("non-reduced-motion fly-to must not snap the camera synchronously -- updateFly() drives it per frame");
const dest = { x: flyAnim.toTarget.x, radius: flyAnim.toRadius };

eval(extract("updateFly"));
nowVal = 0; updateFly();
if (target.x === dest.x) throw new Error("updateFly() at t0 should not already be at the destination");

nowVal = flyAnim.dur; updateFly();
if (Math.abs(target.x - dest.x) > 0.01) throw new Error("updateFly() did not converge on the destination target by the animation's own duration: " + JSON.stringify(target));
if (Math.abs(radius - dest.radius) > 0.01) throw new Error("updateFly() did not converge on the destination radius by the animation's own duration: got " + radius);
if (flyAnim !== null) throw new Error("updateFly() must clear the animation once it completes");

console.log("FLYTOCLUSTER_OK");
NODEJS
    flytocluster_out="$(node "$_nvflytocluster" "$NVHTML" 2>&1)"
    check "flyToCluster() sets userMoved and jumps instantly under reduced motion, else animates (#73)" "FLYTOCLUSTER_OK" "$flytocluster_out"
    rm -f "$_nvflytocluster"

    # #73 review follow-up (1/2): distanceForSphere() is a deliberate parallel
    # copy of fitDistance()'s margin/FOV-fit formula (kept separate so it
    # doesn't disturb the pinned boundingSphere()/fitDistance() extraction
    # tests above) -- nothing else pins that the two formulas actually AGREE,
    # so a future tweak to fitDistance()'s margin/clamp could silently diverge
    # fly-to framing from the whole-graph auto-fit. This feeds
    # distanceForSphere() the exact sphere boundingSphere() computes for a
    # single-repo layout and asserts fitDistance(aspect) and
    # distanceForSphere(sphere, aspect) produce identical output across
    # several aspect ratios (landscape, portrait, square, ultrawide).
    _nvformulaagreement="$(mktemp).cjs"
    cat >"$_nvformulaagreement" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
    const re = new RegExp("function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
const MIN_DIST = 80, MAX_DIST = 6000, FOV = 50 * Math.PI / 180, MIN_REGION = 46;
let repoList = ["r1"];
let repoCenters = new Map([["r1", {x: 5, y: 6, z: 7}]]);
let repoRadius = new Map([["r1", 50]]);

eval(extract("boundingSphere"));
eval(extract("fitDistance"));
eval(extract("distanceForSphere"));

const equivalentSphere = boundingSphere();   // the exact sphere fitDistance() itself frames
for (const [label, aspect] of [["landscape", 1600 / 900], ["portrait", 900 / 1600], ["square", 1], ["ultrawide", 21 / 9]]) {
    const viaFit = fitDistance(aspect);
    const viaGeneric = distanceForSphere(equivalentSphere, aspect);
    if (Math.abs(viaFit.distance - viaGeneric.distance) > 1e-9) throw new Error(label + ": fitDistance() and distanceForSphere() disagree on distance: " + viaFit.distance + " vs " + viaGeneric.distance);
    if (viaFit.target.x !== viaGeneric.target.x || viaFit.target.y !== viaGeneric.target.y || viaFit.target.z !== viaGeneric.target.z) throw new Error(label + ": fitDistance() and distanceForSphere() disagree on target: " + JSON.stringify(viaFit.target) + " vs " + JSON.stringify(viaGeneric.target));
}
console.log("FORMULA_AGREEMENT_OK");
NODEJS
    formulaagreement_out="$(node "$_nvformulaagreement" "$NVHTML" 2>&1)"
    check "distanceForSphere() agrees with fitDistance() on an equivalent sphere across aspect ratios -- a margin/clamp tweak to one alone must not silently diverge fly-to framing (#73 review)" "FORMULA_AGREEMENT_OK" "$formulaagreement_out"
    rm -f "$_nvformulaagreement"

    # #73 review follow-up (2/2): a real drag/wheel/pinch gesture started while
    # a fly-to is still animating must win instantly -- the user's own camera
    # input should never be stomped by up to 650ms of a stale in-flight
    # animation. Extends the pinned #71 pointer-wiring harness (same
    # start/end markers, same stub canvas/THREE) with a flyAnim sentinel:
    # every case that already sets userMoved=true must also clear flyAnim,
    # and every case that must NOT set userMoved (bare click/jitter) must
    # leave flyAnim untouched.
    _nvflycancel="$(mktemp).cjs"
    cat >"$_nvflycancel" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

const startMarker = "const pointers = new Map();";
const endMarker = "}, {passive:false});";
const startIdx = html.indexOf(startMarker);
const endIdx = html.indexOf(endMarker, startIdx);
if (startIdx === -1 || endIdx === -1) throw new Error("could not locate the pointer-interaction wiring block (pointerdown..wheel) in template -- markers may be stale");
const block = html.slice(startIdx, endIdx + endMarker.length);

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

const SENTINEL = {fromTarget: {x: 0, y: 0, z: 0}, toTarget: {x: 1, y: 1, z: 1}, fromRadius: 1, toRadius: 2, t0: 0, dur: 1};
let flyAnim = null;

eval(block);

function fireEvent(type, x, y, extra) {
    handlers[type](Object.assign({clientX: x, clientY: y, pointerId: 1, button: 0, shiftKey: false, preventDefault(){}}, extra || {}));
}

// bare pointerdown/pointerup, no movement -- must NOT clear an in-flight fly-to.
flyAnim = SENTINEL;
fireEvent("pointerdown", 100, 100);
fireEvent("pointerup", 100, 100);
if (flyAnim !== SENTINEL) throw new Error("a bare pointerdown/pointerup with zero movement must not cancel an in-flight fly-to");

// sub-threshold jitter (realistic click) -- must NOT clear an in-flight fly-to.
flyAnim = SENTINEL;
fireEvent("pointerdown", 100, 100);
fireEvent("pointermove", 101, 100);
fireEvent("pointerup", 101, 100);
if (flyAnim !== SENTINEL) throw new Error("a click's sub-pixel jitter must not cancel an in-flight fly-to");

// a real drag past the threshold DOES cancel an in-flight fly-to -- the
// user's own gesture wins instantly instead of being stomped for up to 650ms.
flyAnim = SENTINEL;
fireEvent("pointerdown", 200, 200);
fireEvent("pointermove", 300, 200);
if (flyAnim !== null) throw new Error("a real drag past the movement threshold did not cancel an in-flight fly-to");
fireEvent("pointerup", 300, 200);

// wheel always cancels an in-flight fly-to, no threshold.
flyAnim = SENTINEL;
handlers["wheel"]({deltaY: 10, preventDefault(){}});
if (flyAnim !== null) throw new Error("a wheel event did not cancel an in-flight fly-to");

// a two-pointer pinch move always cancels an in-flight fly-to, no threshold.
flyAnim = SENTINEL;
fireEvent("pointerdown", 100, 100, {pointerId: 1});
fireEvent("pointerdown", 120, 100, {pointerId: 2});
fireEvent("pointermove", 121, 100, {pointerId: 2});
if (flyAnim !== null) throw new Error("a two-pointer pinch move did not cancel an in-flight fly-to");
fireEvent("pointerup", 121, 100, {pointerId: 1});
fireEvent("pointerup", 121, 100, {pointerId: 2});

console.log("FLYANIM_CANCELLED_ON_REAL_INTERACTION_OK");
NODEJS
    flycancel_out="$(node "$_nvflycancel" "$NVHTML" 2>&1)"
    check "a real drag/wheel/pinch cancels an in-flight fly-to instantly instead of being stomped by it (#73 review)" "FLYANIM_CANCELLED_ON_REAL_INTERACTION_OK" "$flycancel_out"
    rm -f "$_nvflycancel"
fi

