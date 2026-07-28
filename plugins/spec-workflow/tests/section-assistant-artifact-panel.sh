#!/usr/bin/env bash
# section-assistant-artifact-panel.sh -- AST-069: artifact panels with
# entrance animations (SPEC-ASSISTANT.md §12.1-§12.5, issue #344). Sourced
# by run-tests.sh; do not run standalone. Contract: the runner already
# defines set -uo pipefail and has sourced _lib.sh (check/check_rc/
# check_absent) and set HERE/PLUGIN/FIX/fails/flaky before sourcing this
# file. This file assumes those are already in scope.
#
# tasks.sqlite's queue/worker/state machine (AST-066/067) and the
# /assistant/artifact/<id> streamed endpoint (AST-068) are already merged
# and covered by section-assistant-tasks.sh/section-assistant-artifacts.sh
# -- this section covers only what AST-069 adds: the neural-view page's
# artifact-panel state machine (pure logic, extracted + eval'd), the
# rendering gate that keeps the viewer unmounted until state=completed,
# the trace rail, the failure path, TTS-announce-only-when-voice-on
# wiring, and chat-turn linking. Same "extract() + eval() against a
# stubbed DOM/fetch" harness style as section-assistant-inspector.sh /
# section-assistant-voice-turn.sh.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant artifact panels (AST-069: entrance animations, SPEC-ASSISTANT.md §12.1-§12.5, issue #344) =="

NVHTML_AP="$PLUGIN/templates/neural-view.html"
NVHTML_AP_BODY="$(cat "$NVHTML_AP")"

echo "-- template: chrome reuse -- panel is built on the EXISTING .media-window/.mw-3d chrome, not new markup (§12.1) --"
check "ensureArtifactPanel exists" "function ensureArtifactPanel(task, originRect){" "$NVHTML_AP_BODY"
check "panel window reuses the .media-window.mw-3d chrome class family" 'win.className = "hud note-window media-window mw-3d ast-artifact-win";' "$NVHTML_AP_BODY"
check "panel carries the AC10 c-win e2e hook" 'win.setAttribute("data-testid", "c-win");' "$NVHTML_AP_BODY"
check "grip carries c-grip" 'grip.className = "close grip"; grip.setAttribute("data-testid", "c-grip");' "$NVHTML_AP_BODY"
check "fullscreen button carries c-fs" 'fsBtn.className = "iconbtn mw-fs"; fsBtn.setAttribute("data-testid", "c-fs");' "$NVHTML_AP_BODY"
check "close button carries c-close" 'closeBtn.className = "close mw-x"; closeBtn.setAttribute("data-testid", "c-close");' "$NVHTML_AP_BODY"
check "viewport wrapper carries c-vp" 'vp.className = "aw-vp"; vp.setAttribute("data-testid", "c-vp");' "$NVHTML_AP_BODY"
check "New tab action carries c-newtab" 'newtabBtn.className = "iconbtn aw-newtab"; newtabBtn.setAttribute("data-testid", "c-newtab");' "$NVHTML_AP_BODY"
check "Spin action carries c-spin" 'spinBtn.className = "iconbtn aw-spin"; spinBtn.setAttribute("data-testid", "c-spin");' "$NVHTML_AP_BODY"
check "progress ring carries c-arc" 'arcEl.className = "aw-arc"; arcEl.setAttribute("data-testid", "c-arc");' "$NVHTML_AP_BODY"
check "percent readout carries c-pct" 'pctEl.className = "aw-pct"; pctEl.setAttribute("data-testid", "c-pct"); pctEl.textContent = "0%";' "$NVHTML_AP_BODY"
check "status text carries c-status" 'statusEl.className = "aw-status"; statusEl.setAttribute("data-testid", "c-status"); statusEl.textContent = "Queued";' "$NVHTML_AP_BODY"
check "trace rail carries c-rail" 'rail.className = "aw-rail"; rail.setAttribute("data-testid", "c-rail");' "$NVHTML_AP_BODY"
check "trace link carries c-trace" 'traceBtn.className = "aw-trace"; traceBtn.setAttribute("data-testid", "c-trace"); traceBtn.textContent = "View full trace →";' "$NVHTML_AP_BODY"
check "trace link opens the EXISTING metrics/trace inspector window, no new trace UI" 'traceBtn.onclick = ()=>{ openAstInspectorWindow(); };' "$NVHTML_AP_BODY"

echo "-- template: §12.2 -- artifacts are served ONLY via /assistant/artifact/<id>, never /file --"
check "mountArtifactViewer builds the src from /assistant/artifact/<id>" 'const url = "/assistant/artifact/" + encodeURIComponent(task.id);' "$NVHTML_AP_BODY"
check "New tab action opens the SAME artifact endpoint, once an artifact actually exists" 'if(entry && entry.pstate.artifactPath) window.open("/assistant/artifact/" + encodeURIComponent(task.id), "_blank");' "$NVHTML_AP_BODY"
check_absent "no artifact code path reads through /file" '"/file/"' "$NVHTML_AP_BODY"

echo "-- template: AC3 gate -- the artifact viewer is mounted ONLY on state=completed, never merely hidden earlier --"
check "mountArtifactViewer is the ONLY place that appends the viewer into .aw-stage" "function mountArtifactViewer(panel, task, pstate){" "$NVHTML_AP_BODY"
check "mountArtifactViewer is gated on the stage being empty (idempotent, never double-mounts)" "if(!panel || !panel.stage || panel.stage.children.length) return;" "$NVHTML_AP_BODY"
check "renderArtifactPanel calls mountArtifactViewer ONLY when pstate.state === completed" 'if(pstate.state === "completed") mountArtifactViewer(panel, task, pstate);' "$NVHTML_AP_BODY"

echo "-- template: AC5 -- progress is driven by the shared trace-event stream, never a per-panel status poll --"
check "pollArtifactTraceEvents reads the SAME /assistant/traces stream the inspector already polls" 'data = await (await fetch("/assistant/traces?since=" + window.__artifactPollSeq + "&order=asc")).json();' "$NVHTML_AP_BODY"
check_absent "no per-task status/progress endpoint exists for this feature to poll instead" '"/assistant/task/"' "$NVHTML_AP_BODY"
check "applyArtifactTaskEvent re-renders on every applied trace event, not on a timer" "function applyArtifactTaskEvent(task, evt, originRect){" "$NVHTML_AP_BODY"

echo "-- template: AC7 -- completion announces via the EXISTING speakReply hook, which self-gates on voice-off/§17.9 --"
check "applyArtifactTaskEvent calls the real speakReply(), not a duplicate TTS path" 'speakReply((task.payload && task.payload.name ? task.payload.name : "Your artifact") + " is ready.", task.turn_id || task.id);' "$NVHTML_AP_BODY"

echo "-- template: AC6/AC8 -- chat turn links artifact+trace on completion, failure surfaces in-chat too --"
check "linkArtifactInChat reuses appendChatRow's existing red system-row treatment" 'appendChatRow(log, "system", text, null);' "$NVHTML_AP_BODY"
check "completion links via linkArtifactInChat(task, entry.pstate, false)" "linkArtifactInChat(task, entry.pstate, false);" "$NVHTML_AP_BODY"
check "failure/orphaned links via linkArtifactInChat(task, entry.pstate, true)" "linkArtifactInChat(task, entry.pstate, true);" "$NVHTML_AP_BODY"
check "a task with no turn_id (not yet wired to a real chat-driven invocation) is a no-op, not a crash" "if(!task.turn_id) return;" "$NVHTML_AP_BODY"

echo "-- template: §12.5 queue chip -- minimal running-count chip (scope call: no board task owns the fuller queue-list UX yet) --"
check "queue chip markup exists with the AC10 c-qchip hook, hidden by default" '<div class="ast-qchip" id="ast-queue-chip" data-testid="c-qchip" hidden></div>' "$NVHTML_AP_BODY"
check "renderQueueChip's scope-call comment documents the deliberate minimal-chip decision" "task owns the FULL queue-list UX yet" "$NVHTML_AP_BODY"

echo "-- review round 1 BLOCKER 1: AC1 routes by artifact type (3D/image/video), never hardcodes 3D --"
check "artifactViewerKind exists as the one place extensions are classified" "function artifactViewerKind(name){" "$NVHTML_AP_BODY"
check "mountArtifactViewer prefers the server-recorded artifactPath over the caller-supplied payload name" 'const name = pstate.artifactPath || (task.payload && task.payload.name) || task.id;' "$NVHTML_AP_BODY"
check "video kind mounts a real <video> element, not make3dBlock" 'box = document.createElement("video");' "$NVHTML_AP_BODY"
check "image kind mounts a real <img> element, not make3dBlock" 'box = document.createElement("img");' "$NVHTML_AP_BODY"
check "an unrecognized extension gets an HONEST unsupported notice, never a silent 3D default" 'box.textContent = "Unsupported artifact type: " + name;' "$NVHTML_AP_BODY"

echo "-- review round 1 BLOCKER 2: the queue chip's count is derived from the registry, never hardcoded --"
check "artifactActiveTaskCount exists as the one source of truth for the running count" "function artifactActiveTaskCount(){" "$NVHTML_AP_BODY"
check_absent "pollArtifactTraceEvents no longer hardcodes the chip count to 1" 'renderQueueChip(1,' "$NVHTML_AP_BODY"
check "the chip is re-rendered with the TRUE post-apply count after every event" "renderQueueChip(artifactActiveTaskCount(), taskName);" "$NVHTML_AP_BODY"

echo "-- review round 1 BLOCKER 3: entrance transform-origin is computed in real pixels, not vw/vh misread as px --"
check "panel open position is computed in real pixels from innerWidth/innerHeight, not a vw/vh CSS-length string" "const openLeft = Math.round(vw * 0.26), openTop = Math.round(vh * 0.14);" "$NVHTML_AP_BODY"
check "transform-origin math subtracts two pixel numbers, not a CSS-length string reinterpreted as pixels" 'win.style.transformOrigin = (originRect.left - openLeft) + "px " + (originRect.top - openTop) + "px";' "$NVHTML_AP_BODY"

echo "-- review round 1 REQUIRED MINOR 4: prefers-reduced-motion gates both the entrance and the completion reveal --"
check "the panel entrance class is gated by the template's own REDUCED convention" 'if(!REDUCED) win.classList.add("aw-enter");' "$NVHTML_AP_BODY"
check "the completion-reveal class is gated by REDUCED too" 'if(!REDUCED) box.classList.add("aw-reveal");' "$NVHTML_AP_BODY"

echo "-- review round 1 REQUIRED MINOR 5: closing a panel nulls the registry's dangling reference, a later event reopens it --"
check "closing the panel nulls entry.panel rather than leaving a detached-node reference alive" "if(entry) entry.panel = null;" "$NVHTML_AP_BODY"

echo "-- review round 1 JUDGMENT CALL: a stuck (not merely transient) trace-poll failure earns one honest signal, not permanent silence --"
check "3 consecutive poll failures log one honest warning" 'if(window.__artifactPollFailures === 3){' "$NVHTML_AP_BODY"
check "a later success resets the failure counter (a stuck run later recovering can signal again)" "window.__artifactPollFailures = 0;" "$NVHTML_AP_BODY"

echo "-- template behavior: extract() + eval() against a stubbed DOM/fetch -- state machine, rendering gate, rail, failure, TTS/chat wiring --"
_aap_node="$(mktemp).cjs"
cat >"$_aap_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
function extractLine(prefix) {
    const re = new RegExp("^" + prefix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "[^\\n]*\\n", "m");
    const m = html.match(re);
    if (!m) throw new Error("could not find a line starting with " + prefix);
    return m[0];
}
// A direct `eval("const X = ...")` does NOT leak X into the enclosing
// scope the way `var`/function declarations do -- const/let bindings
// inside an eval are scoped to that eval call. Running the extracted line
// inside `new Function(...)` and RETURNING the bindings, then attaching
// them to `global` explicitly, is the reliable way to make a template
// `const` line's names available to the rest of this harness.
function defineConstsFromLine(prefix, names) {
    const line = extractLine(prefix).trim().replace(/;$/, "");
    const result = new Function(line + "; return {" + names.join(",") + "};")();
    for (const n of names) global[n] = result[n];
}

eval(extract("artifactFmtRel"));
eval(extract("artifactRankState"));
eval(extract("artifactRingOffset"));
eval(extract("artifactRailLabel"));
eval(extract("applyArtifactTraceEvent"));
// round 1 BLOCKER 1: artifactViewerKind depends on the SAME extension regexes
// hydrateNoteMedia already classifies note media with (VID_EXT/GLTF_EXT/
// MESH_EXT, one shared const line) plus this feature's own image set.
defineConstsFromLine("const VID_EXT = ", ["VID_EXT", "GLTF_EXT", "MESH_EXT"]);
defineConstsFromLine("const ARTIFACT_IMG_EXT = ", ["ARTIFACT_IMG_EXT"]);
eval(extract("artifactViewerKind"));

if (artifactViewerKind("model.glb") !== "3d") throw new Error("a .glb must classify as 3d, got " + artifactViewerKind("model.glb"));
if (artifactViewerKind("mesh.OBJ") !== "3d") throw new Error("a .OBJ (case-insensitive) must classify as 3d, got " + artifactViewerKind("mesh.OBJ"));
if (artifactViewerKind("clip.mp4") !== "video") throw new Error("a .mp4 must classify as video, got " + artifactViewerKind("clip.mp4"));
if (artifactViewerKind("photo.png") !== "image") throw new Error("a .png must classify as image, got " + artifactViewerKind("photo.png"));
if (artifactViewerKind("photo.JPEG") !== "image") throw new Error("a .JPEG (case-insensitive) must classify as image, got " + artifactViewerKind("photo.JPEG"));
if (artifactViewerKind("archive.zip") !== "unknown") throw new Error("an unrecognized extension must classify as unknown (never a silent 3d default), got " + artifactViewerKind("archive.zip"));
if (artifactViewerKind("") !== "unknown") throw new Error("no name at all must classify as unknown, got " + artifactViewerKind(""));
console.log("VIEWER_KIND_OK true");

if (artifactFmtRel(0) !== "00:00") throw new Error("artifactFmtRel(0) expected 00:00, got " + artifactFmtRel(0));
if (artifactFmtRel(61000) !== "01:01") throw new Error("artifactFmtRel(61000) expected 01:01, got " + artifactFmtRel(61000));
if (artifactFmtRel(125000) !== "02:05") throw new Error("artifactFmtRel(125000) expected 02:05, got " + artifactFmtRel(125000));
if (artifactFmtRel(-500) !== "00:00") throw new Error("artifactFmtRel must clamp negative elapsed to 00:00, got " + artifactFmtRel(-500));
console.log("FMT_REL_OK true");

const RING_CASES = {0: 170, 12: 150, 60: 68, 100: 0};
for (const [pct, want] of Object.entries(RING_CASES)) {
  const got = artifactRingOffset(Number(pct));
  if (got !== want) throw new Error("artifactRingOffset(" + pct + ") expected " + want + ", got " + got);
}
console.log("RING_OFFSET_OK true");

if (artifactRailLabel("queued", {}) !== "queued") throw new Error("queued label wrong: " + artifactRailLabel("queued", {}));
if (artifactRailLabel("progress", {progress: {pct: 60}}) !== "progress 60%") throw new Error("progress label wrong: " + artifactRailLabel("progress", {progress: {pct: 60}}));
if (artifactRailLabel("progress", {}) !== "progress") throw new Error("progress-without-pct label wrong: " + artifactRailLabel("progress", {}));
if (artifactRailLabel("failed", {error: "exit 1"}) !== "failed · exit 1") throw new Error("failed label wrong: " + artifactRailLabel("failed", {error: "exit 1"}));
console.log("RAIL_LABEL_OK true");

function freshPstate(){ return {lastSeq: -1, firstTs: null, state: null, pct: 0, artifactPath: null, error: null, terminal: false, rail: []}; }
{
  const p = freshPstate();
  const T0 = "2026-01-01T00:00:00.000Z";
  const r1 = applyArtifactTraceEvent(p, {seq: 1, ts: T0, payload: {task_id: "t1", state: "queued"}});
  const r2 = applyArtifactTraceEvent(p, {seq: 2, ts: "2026-01-01T00:00:03.000Z", payload: {task_id: "t1", state: "started"}});
  const r3 = applyArtifactTraceEvent(p, {seq: 3, ts: "2026-01-01T00:00:38.000Z", payload: {task_id: "t1", state: "progress", progress: {pct: 60}}});
  const r4 = applyArtifactTraceEvent(p, {seq: 4, ts: "2026-01-01T00:01:12.000Z", payload: {task_id: "t1", state: "completed", artifact_path: "art/t1.glb"}});
  if (!(r1.applied && r2.applied && r3.applied && r4.applied)) throw new Error("happy-path events must all apply: " + JSON.stringify([r1,r2,r3,r4]));
  if (p.state !== "completed" || p.pct !== 100 || p.artifactPath !== "art/t1.glb" || p.terminal !== true) throw new Error("pstate after completion wrong: " + JSON.stringify(p));
  if (p.rail.length !== 4) throw new Error("expected 4 rail rows, got " + p.rail.length);
  if (p.rail[2].ts !== "00:38" || p.rail[2].label !== "progress 60%") throw new Error("progress rail row wrong: " + JSON.stringify(p.rail[2]));
  if (p.rail[3].ts !== "01:12") throw new Error("completed rail row timestamp wrong: " + JSON.stringify(p.rail[3]));
  console.log("HAPPY_PATH_OK true");

  const dup = applyArtifactTraceEvent(p, {seq: 3, ts: "2026-01-01T00:00:38.000Z", payload: {task_id: "t1", state: "progress", progress: {pct: 60}}});
  if (dup.applied !== false || dup.reason !== "stale-or-duplicate") throw new Error("duplicate seq must be rejected as stale-or-duplicate, got " + JSON.stringify(dup));
  if (p.rail.length !== 4) throw new Error("a rejected duplicate must not grow the rail: " + p.rail.length);
  console.log("DUPLICATE_REJECTED_OK true");

  const stray = applyArtifactTraceEvent(p, {seq: 5, ts: "2026-01-01T00:02:00.000Z", payload: {task_id: "t1", state: "progress", progress: {pct: 10}}});
  if (stray.applied !== false || stray.reason !== "terminal") throw new Error("a post-terminal event must be rejected as terminal, got " + JSON.stringify(stray));
  if (p.state !== "completed") throw new Error("terminal state must never regress: " + p.state);
  console.log("TERMINAL_LOCK_OK true");
}

{
  const p = freshPstate();
  const rCompleted = applyArtifactTraceEvent(p, {seq: 3, ts: "2026-01-01T00:01:00.000Z", payload: {task_id: "t2", state: "completed"}});
  const rProgress = applyArtifactTraceEvent(p, {seq: 2, ts: "2026-01-01T00:00:30.000Z", payload: {task_id: "t2", state: "progress", progress: {pct: 50}}});
  if (!rCompleted.applied) throw new Error("completed (seq 3) must apply when it's the first event seen");
  if (rProgress.applied) throw new Error("a lower-seq progress arriving AFTER a terminal event must never reopen the panel: " + JSON.stringify(rProgress));
  if (p.state !== "completed") throw new Error("out-of-order delivery must not regress state: " + p.state);
  console.log("OUT_OF_ORDER_OK true");
}

{
  const p = freshPstate();
  const r = applyArtifactTraceEvent(p, {seq: 1, ts: "2026-01-01T00:00:00.000Z", payload: {task_id: "t3", state: "bogus"}});
  if (r.applied !== false || r.reason !== "unknown-state") throw new Error("unknown state must be rejected, got " + JSON.stringify(r));
  console.log("UNKNOWN_STATE_OK true");
}

{
  const p = freshPstate();
  applyArtifactTraceEvent(p, {seq: 1, ts: "2026-01-01T00:00:00.000Z", payload: {task_id: "t4", state: "queued"}});
  applyArtifactTraceEvent(p, {seq: 2, ts: "2026-01-01T00:00:05.000Z", payload: {task_id: "t4", state: "started"}});
  const rf = applyArtifactTraceEvent(p, {seq: 3, ts: "2026-01-01T00:00:44.000Z", payload: {task_id: "t4", state: "failed", error: "exit 1"}});
  if (!rf.applied || p.state !== "failed" || p.error !== "exit 1" || p.terminal !== true) throw new Error("failure transition wrong: " + JSON.stringify(p));
  if (p.rail[2].label !== "failed · exit 1") throw new Error("failure rail label wrong: " + JSON.stringify(p.rail[2]));
  console.log("FAILURE_PATH_OK true");
}
NODEJS
if node "$_aap_node" "$NVHTML_AP" >/tmp/aap_out.$$ 2>&1; then
    for tag in VIEWER_KIND_OK FMT_REL_OK RING_OFFSET_OK RAIL_LABEL_OK HAPPY_PATH_OK DUPLICATE_REJECTED_OK TERMINAL_LOCK_OK OUT_OF_ORDER_OK UNKNOWN_STATE_OK FAILURE_PATH_OK; do
        check "artifact-panel state machine: $tag" "$tag true" "$(cat /tmp/aap_out.$$)"
    done
else
    echo "FAIL: artifact-panel state-machine harness errored:" >&2
    cat /tmp/aap_out.$$ >&2
    fails=$((fails+1))
fi
rm -f /tmp/aap_out.$$ "$_aap_node"

echo "-- template behavior: DOM-level -- rendering gate (viewer absent pre-completion, mounted on completion), rail append+testids, TTS/chat wiring, queue chip --"
_aap2_node="$(mktemp).cjs"
cat >"$_aap2_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
function extractLine(prefix) {
    const re = new RegExp("^" + prefix.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "[^\\n]*\\n", "m");
    const m = html.match(re);
    if (!m) throw new Error("could not find a line starting with " + prefix);
    return m[0];
}
// A direct `eval("const X = ...")` does NOT leak X into the enclosing
// scope the way `var`/function declarations do -- const/let bindings
// inside an eval are scoped to that eval call. Running the extracted line
// inside `new Function(...)` and RETURNING the bindings, then attaching
// them to `global` explicitly, is the reliable way to make a template
// `const` line's names available to the rest of this harness.
function defineConstsFromLine(prefix, names) {
    const line = extractLine(prefix).trim().replace(/;$/, "");
    const result = new Function(line + "; return {" + names.join(",") + "};")();
    for (const n of names) global[n] = result[n];
}

const elements = {};
function mkEl(tag) {
    const el = {
        tagName: (tag || "div").toUpperCase(),
        _classes: new Set(),
        classList: {
            add(c){ this._parent._classes.add(c); },
            remove(c){ this._parent._classes.delete(c); },
            contains(c){ return this._parent._classes.has(c); },
            toggle(c, force){ const on = force === undefined ? !this.contains(c) : !!force; if(on) this.add(c); else this.remove(c); return on; },
        },
        style: {},
        dataset: {},
        title: "",
        textContent: "",
        _items: [],
        get children(){ return new Proxy(this._items, { set(){ throw new TypeError("read-only children"); } }); },
        appendChild(child){ this._items.push(child); return child; },
        remove(){ if (this._id && elements[this._id] === this) delete elements[this._id]; },
        get id(){ return this._id; },
        set id(v){ this._id = v; if (v) elements[v] = this; },
        get className(){ return [...this._classes].join(" "); },
        set className(v){ this._classes = new Set(v.split(" ").filter(Boolean)); },
        get hidden(){ return !!this._hidden; },
        set hidden(v){ this._hidden = !!v; },
        setAttribute(k, v){ if (k === "class") { this.className = v; return; } this["_attr_" + k] = v; },
        getAttribute(k){ return this["_attr_" + k] !== undefined ? this["_attr_" + k] : null; },
        removeAttribute(k){ delete this["_attr_" + k]; },
        addEventListener(){},
        getBoundingClientRect(){ return {left: 40, top: 500, width: 120, height: 20}; },
        // round 1 REQUIRED MINOR 5's close-button test needs to reach a
        // nested button (win > bar > closeBtn) -- a shallow direct-children
        // find (the original harness's shape) can't see it, so this walks
        // the whole subtree, same as a real querySelector would.
        querySelector(sel){ return findDeep(this, sel); },
    };
    el.classList._parent = el;
    return el;
}
function findDeep(el, sel) {
    for (const child of el._items || []) {
        if (matchesSel(child, sel)) return child;
        const found = findDeep(child, sel);
        if (found) return found;
    }
    return null;
}
function matchesSel(el, sel) {
    if (sel[0] === ".") return !!(el.classList && el.classList.contains(sel.slice(1)));
    const attrEq = sel.match(/^\[([\w-]+)="([^"]*)"\]$/);
    if (attrEq) return el.getAttribute && el.getAttribute(attrEq[1]) === attrEq[2];
    if (sel[0] === "[" && sel[sel.length - 1] === "]") return el.getAttribute && el.getAttribute(sel.slice(1, -1)) !== null;
    return false;
}
global.document = {
    body: mkEl("body"),
    createElement(tag){ return mkEl(tag); },
    getElementById(id){ return elements[id] || null; },
};
global.window = global;
global.noteWinZ = 0;
// round 1 BLOCKER 3: deterministic viewport so the panel's real-pixel open
// position (openLeft/openTop) and the transform-origin math built on it are
// both pinnable to exact numbers below.
global.innerWidth = 1000;
global.innerHeight = 700;
// round 1 REQUIRED MINOR 4: default un-reduced (matches a real browser's
// common case); the dedicated REDUCED_MOTION_GATED_OK block below flips
// this to true for its own scope and restores it after.
global.REDUCED = false;
function wireWinDrag(){}
global.wireWinDrag = wireWinDrag;
function openAstInspectorWindow(){ global.__inspectorOpened = true; }
global.openAstInspectorWindow = openAstInspectorWindow;
function make3dBlock(name, url){
    global.__make3dBlockCalls = (global.__make3dBlockCalls || []).concat([{name, url}]);
    const box = mkEl("div");
    box.className = "n3d";
    const pop = mkEl("button"); pop.className = "n3d-pop";
    box._items.push(pop);
    box.querySelector = function(sel){ return matchesSel(pop, sel) ? pop : null; };
    return box;
}
global.make3dBlock = make3dBlock;
let speakReplyCalls = [];
global.speakReply = (text, turnId) => { speakReplyCalls.push({text, turnId}); };
let appendChatRowCalls = [];
global.appendChatRow = (log, role, text, chips) => { appendChatRowCalls.push({role, text}); return mkEl("div"); };
elements["ast-chat-log"] = mkEl("div"); elements["ast-chat-log"].id = "ast-chat-log";
elements["ast-queue-chip"] = mkEl("div"); elements["ast-queue-chip"].id = "ast-queue-chip"; elements["ast-queue-chip"].hidden = true;

eval(extract("artifactFmtRel"));
eval(extract("artifactRankState"));
eval(extract("artifactRingOffset"));
eval(extract("artifactRailLabel"));
eval(extract("applyArtifactTraceEvent"));
eval(extract("ensureArtifactPanel"));
eval(extract("appendArtifactRailRow"));
eval(extract("mountArtifactViewer"));
eval(extract("renderArtifactPanel"));
eval(extract("applyArtifactTaskEvent"));
eval(extract("linkArtifactInChat"));
eval(extract("renderQueueChip"));
// round 1 BLOCKER 1: same extension consts + classifier the pure-logic
// harness above already validated in isolation -- mountArtifactViewer
// (already eval'd above) calls artifactViewerKind internally, so it must
// exist in THIS harness's global scope too.
defineConstsFromLine("const VID_EXT = ", ["VID_EXT", "GLTF_EXT", "MESH_EXT"]);
defineConstsFromLine("const ARTIFACT_IMG_EXT = ", ["ARTIFACT_IMG_EXT"]);
eval(extract("artifactViewerKind"));
// round 1 BLOCKER 2/judgment call: the real-count function and the poller
// itself (fetch-driven, so the fetch stub below feeds it fixture batches).
eval(extract("artifactActiveTaskCount"));
eval(extract("pollArtifactTraceEvents"));

global.__artifactTasks = {};
window.__artifactPollSeq = 0;
window.__artifactPollFailures = 0;

{
  const task = {id: "task-abc", turn_id: "turn-1", payload: {name: "turbine.glb"}};
  const evts = [
    {seq: 1, ts: "2026-01-01T00:00:00.000Z", payload: {task_id: task.id, state: "queued"}},
    {seq: 2, ts: "2026-01-01T00:00:03.000Z", payload: {task_id: task.id, state: "started"}},
    {seq: 3, ts: "2026-01-01T00:00:38.000Z", payload: {task_id: task.id, state: "progress", progress: {pct: 60}}},
  ];
  for (const evt of evts) applyArtifactTaskEvent(task, evt, {left: 10, top: 480});
  const entry = global.__artifactTasks[task.id];
  if (!entry || !entry.panel) throw new Error("panel must exist after the first (queued) event");
  if (entry.panel.stage.children.length !== 0) throw new Error("AC3 REGRESSION: viewer must be ABSENT from the stage before completion, found " + entry.panel.stage.children.length + " children");
  if (entry.panel.status.textContent !== "Generating…") throw new Error("status text wrong mid-progress: " + entry.panel.status.textContent);
  if (entry.panel.pct.textContent !== "60%") throw new Error("pct readout wrong: " + entry.panel.pct.textContent);
  if (entry.panel.arc.getAttribute("stroke-dashoffset") !== "68") throw new Error("ring offset wrong at 60%: " + entry.panel.arc.getAttribute("stroke-dashoffset"));
  console.log("VIEWER_ABSENT_PRE_COMPLETION_OK true");

  applyArtifactTaskEvent(task, {seq: 4, ts: "2026-01-01T00:01:12.000Z", payload: {task_id: task.id, state: "completed", artifact_path: "art/turbine.glb"}}, null);
  if (entry.panel.stage.children.length !== 1) throw new Error("AC3: exactly one viewer must mount on completion, got " + entry.panel.stage.children.length);
  if (!global.__make3dBlockCalls || global.__make3dBlockCalls.length !== 1) throw new Error("make3dBlock must be called exactly once");
  if (global.__make3dBlockCalls[0].url !== "/assistant/artifact/task-abc") throw new Error("viewer must load from /assistant/artifact/<id>, got " + global.__make3dBlockCalls[0].url);
  if (entry.panel.stage._items[0].classList.contains("aw-reveal") !== true) throw new Error("mounted viewer must carry the completion-reveal class");
  console.log("VIEWER_MOUNTS_ON_COMPLETION_OK true");

  if (speakReplyCalls.length !== 1 || speakReplyCalls[0].text.indexOf("is ready") === -1) throw new Error("speakReply must be called exactly once on completion: " + JSON.stringify(speakReplyCalls));
  console.log("TTS_ANNOUNCE_OK true");

  const completionRows = appendChatRowCalls.filter(c => c.role === "system" && c.text.indexOf("turbine.glb") !== -1);
  if (completionRows.length !== 1 || completionRows[0].text.indexOf("trace") === -1) throw new Error("chat must link artifact+trace on completion: " + JSON.stringify(appendChatRowCalls));
  console.log("CHAT_LINK_COMPLETION_OK true");

  const railRows = entry.panel.railList._items;
  if (railRows.length !== 4) throw new Error("expected 4 rail rows, got " + railRows.length);
  if (railRows[3].getAttribute("data-testid") !== "c-ev-done") throw new Error("final row must carry c-ev-done: " + railRows[3].getAttribute("data-testid"));
  if (railRows.slice(0, 3).some(r => r.getAttribute("data-testid") === "c-ev-now")) throw new Error("no row may still carry c-ev-now once the task is terminal");
  console.log("RAIL_APPEND_ORDER_OK true");
}

{
  speakReplyCalls = []; appendChatRowCalls = [];
  const task = {id: "task-fail", turn_id: "turn-2", payload: {name: "vase.glb"}};
  applyArtifactTaskEvent(task, {seq: 1, ts: "2026-01-01T00:00:00.000Z", payload: {task_id: task.id, state: "queued"}}, null);
  applyArtifactTaskEvent(task, {seq: 2, ts: "2026-01-01T00:00:05.000Z", payload: {task_id: task.id, state: "started"}}, null);
  applyArtifactTaskEvent(task, {seq: 3, ts: "2026-01-01T00:00:44.000Z", payload: {task_id: task.id, state: "failed", error: "exit 1"}}, null);
  const entry = global.__artifactTasks[task.id];
  if (!entry.panel.win.classList.contains("aw-failed")) throw new Error("panel must recolor to the error state on failure");
  if (entry.panel.stage.children.length !== 0) throw new Error("a failed task must never mount a viewer");
  const failRow = entry.panel.railList._items[2];
  if (failRow.getAttribute("data-testid") !== "c-ev-fail") throw new Error("failure row must carry c-ev-fail: " + failRow.getAttribute("data-testid"));
  if (speakReplyCalls.length !== 0) throw new Error("a failed task must never announce completion via TTS");
  const failChatRows = appendChatRowCalls.filter(c => c.role === "system" && c.text.indexOf("failed") !== -1);
  if (failChatRows.length !== 1 || failChatRows[0].text.indexOf("exit 1") === -1) throw new Error("chat failure row must name the reason: " + JSON.stringify(appendChatRowCalls));
  console.log("FAILURE_SURFACED_OK true");
}

{
  appendChatRowCalls = [];
  const task = {id: "task-noturn", payload: {name: "no-turn.glb"}};
  applyArtifactTaskEvent(task, {seq: 1, ts: "2026-01-01T00:00:00.000Z", payload: {task_id: task.id, state: "queued"}}, null);
  applyArtifactTaskEvent(task, {seq: 2, ts: "2026-01-01T00:00:01.000Z", payload: {task_id: task.id, state: "completed"}}, null);
  if (appendChatRowCalls.length !== 0) throw new Error("a task with no turn_id must not touch the chat log: " + JSON.stringify(appendChatRowCalls));
  console.log("NO_TURN_ID_NOOP_OK true");
}

{
  const chip = elements["ast-queue-chip"];
  const rectNone = renderQueueChip(0, "turbine.glb");
  if (chip.hidden !== true || rectNone !== null) throw new Error("queue chip must stay hidden with 0 running tasks");
  const rect = renderQueueChip(2, "turbine.glb");
  if (chip.hidden !== false) throw new Error("queue chip must show once a task is running");
  if (chip.textContent.indexOf("2 running") === -1 || chip.textContent.indexOf("turbine.glb") === -1) throw new Error("queue chip text wrong: " + chip.textContent);
  if (!rect || typeof rect.left !== "number") throw new Error("renderQueueChip must return a bounding rect for the entrance origin");
  console.log("QUEUE_CHIP_OK true");
}

// round 1 BLOCKER 1: mountArtifactViewer routes by REAL extension, three
// artifact kinds each get their own real element -- not always make3dBlock.
{
  const videoTask = {id: "task-video", payload: {name: "clip.mp4"}};
  applyArtifactTaskEvent(videoTask, {seq: 1, ts: "2026-01-01T00:00:00.000Z", payload: {task_id: videoTask.id, state: "queued"}}, null);
  applyArtifactTaskEvent(videoTask, {seq: 2, ts: "2026-01-01T00:00:01.000Z", payload: {task_id: videoTask.id, state: "completed", artifact_path: "media/clip.mp4"}}, null);
  const videoEntry = global.__artifactTasks[videoTask.id];
  const videoEl = videoEntry.panel.stage._items[0];
  if (videoEl.tagName !== "VIDEO" || videoEl.src !== "/assistant/artifact/task-video") throw new Error("a .mp4 artifact must mount a real <video>, got tag=" + videoEl.tagName + " src=" + videoEl.src);

  const imageTask = {id: "task-image", payload: {name: "photo.png"}};
  applyArtifactTaskEvent(imageTask, {seq: 1, ts: "2026-01-01T00:00:00.000Z", payload: {task_id: imageTask.id, state: "queued"}}, null);
  applyArtifactTaskEvent(imageTask, {seq: 2, ts: "2026-01-01T00:00:01.000Z", payload: {task_id: imageTask.id, state: "completed", artifact_path: "media/photo.png"}}, null);
  const imageEntry = global.__artifactTasks[imageTask.id];
  const imageEl = imageEntry.panel.stage._items[0];
  if (imageEl.tagName !== "IMG" || imageEl.src !== "/assistant/artifact/task-image") throw new Error("a .png artifact must mount a real <img>, got tag=" + imageEl.tagName + " src=" + imageEl.src);

  const unknownTask = {id: "task-unknown", payload: {name: "output.bin"}};
  applyArtifactTaskEvent(unknownTask, {seq: 1, ts: "2026-01-01T00:00:00.000Z", payload: {task_id: unknownTask.id, state: "queued"}}, null);
  applyArtifactTaskEvent(unknownTask, {seq: 2, ts: "2026-01-01T00:00:01.000Z", payload: {task_id: unknownTask.id, state: "completed", artifact_path: "media/output.bin"}}, null);
  const unknownEntry = global.__artifactTasks[unknownTask.id];
  const unknownEl = unknownEntry.panel.stage._items[0];
  if (!unknownEl.classList.contains("aw-unsupported") || unknownEl.textContent.indexOf("output.bin") === -1) throw new Error("an unrecognized extension must render an honest unsupported notice naming the file, got class=" + unknownEl.className + " text=" + unknownEl.textContent);
  console.log("VIEWER_ROUTES_BY_TYPE_OK true");
}

// round 1 BLOCKER 3: transform-origin is real pixel math end to end --
// innerWidth=1000/innerHeight=700 (set at harness top) pin openLeft=260,
// openTop=98 exactly; a known origin rect makes the whole subtraction
// pinnable, not just "does it run without throwing".
{
  const task = {id: "task-origin", payload: {name: "thing.glb"}};
  applyArtifactTaskEvent(task, {seq: 1, ts: "2026-01-01T00:00:00.000Z", payload: {task_id: task.id, state: "queued"}}, {left: 40, top: 500});
  const entry = global.__artifactTasks[task.id];
  if (entry.panel.win.style.left !== "260px" || entry.panel.win.style.top !== "98px") throw new Error("panel open position must be real px (round(1000*.26)=260, round(700*.14)=98), got left=" + entry.panel.win.style.left + " top=" + entry.panel.win.style.top);
  if (entry.panel.win.style.transformOrigin !== "-220px 402px") throw new Error("transform-origin must be (originRect - openPosition) in real pixels, got " + JSON.stringify(entry.panel.win.style.transformOrigin));
  console.log("TRANSFORM_ORIGIN_PX_OK true");
}

// round 1 REQUIRED MINOR 4: prefers-reduced-motion suppresses BOTH the
// entrance and the completion reveal -- scoped to this block, restored
// after (every other block in this harness assumes REDUCED === false).
{
  global.REDUCED = true;
  const task = {id: "task-reduced", payload: {name: "thing.png"}};
  applyArtifactTaskEvent(task, {seq: 1, ts: "2026-01-01T00:00:00.000Z", payload: {task_id: task.id, state: "queued"}}, null);
  const entry = global.__artifactTasks[task.id];
  if (entry.panel.win.classList.contains("aw-enter")) throw new Error("prefers-reduced-motion must suppress the panel's entrance animation class");
  applyArtifactTaskEvent(task, {seq: 2, ts: "2026-01-01T00:00:01.000Z", payload: {task_id: task.id, state: "completed", artifact_path: "img/thing.png"}}, null);
  if (entry.panel.stage._items[0].classList.contains("aw-reveal")) throw new Error("prefers-reduced-motion must suppress the completion-reveal class too");
  global.REDUCED = false;
  console.log("REDUCED_MOTION_GATED_OK true");
}

// round 1 REQUIRED MINOR 5: closing the panel nulls the dangling registry
// reference; a later trace event for the SAME (still-running) task
// transparently reopens a fresh panel rather than staying dropped forever.
{
  const task = {id: "task-close", payload: {name: "close.glb"}};
  applyArtifactTaskEvent(task, {seq: 1, ts: "2026-01-01T00:00:00.000Z", payload: {task_id: task.id, state: "queued"}}, null);
  const entry = global.__artifactTasks[task.id];
  const closeBtn = entry.panel.win.querySelector('[data-testid="c-close"]');
  if (!closeBtn) throw new Error("could not locate the close button via [data-testid=c-close]");
  closeBtn.onclick();
  if (entry.panel !== null) throw new Error("closing the panel must null entry.panel, got " + JSON.stringify(entry.panel));
  applyArtifactTaskEvent(task, {seq: 2, ts: "2026-01-01T00:00:01.000Z", payload: {task_id: task.id, state: "progress", progress: {pct: 40}}}, null);
  if (!entry.panel) throw new Error("a later event for a closed-but-still-running task must reopen a fresh panel, not stay dropped");
  console.log("CLOSE_NULLS_AND_REOPENS_OK true");
}

// round 1 BLOCKER 2/JUDGMENT CALL: pollArtifactTraceEvents is async, so
// these two blocks run inside one top-level IIFE (this file is loaded as
// plain CommonJS, not a module -- no top-level await available) whose
// rejection is caught and turned into a real nonzero exit + stack trace,
// the same failure shape every synchronous throw above already produces.
(async () => {

// round 1 BLOCKER 2: the chip's count is derived from the registry through
// the REAL poll path (pollArtifactTraceEvents), not renderQueueChip poked
// directly -- two concurrent tasks, one completes, both terminal.
{
  global.__artifactTasks = {};
  window.__artifactPollSeq = 0;
  const batches = [
    { events: [
      {seq: 10, ts: "2026-01-01T00:00:00.000Z", turn_id: null, kind: "task.queued", payload: {task_id: "qa", kind: "gen", state: "queued"}},
      {seq: 11, ts: "2026-01-01T00:00:00.000Z", turn_id: null, kind: "task.queued", payload: {task_id: "qb", kind: "gen", state: "queued"}},
    ] },
    { events: [
      {seq: 12, ts: "2026-01-01T00:00:10.000Z", turn_id: null, kind: "task.completed", payload: {task_id: "qa", kind: "gen", state: "completed"}},
    ] },
    { events: [
      {seq: 13, ts: "2026-01-01T00:00:20.000Z", turn_id: null, kind: "task.completed", payload: {task_id: "qb", kind: "gen", state: "completed"}},
    ] },
  ];
  global.fetch = async () => ({ json: async () => (batches.shift() || {events: []}) });
  const chip = elements["ast-queue-chip"];

  await pollArtifactTraceEvents();
  if (chip.hidden !== false || chip.textContent.indexOf("2 running") === -1) throw new Error("two concurrently queued tasks must show '2 running', got hidden=" + chip.hidden + " text=" + JSON.stringify(chip.textContent));

  await pollArtifactTraceEvents();
  if (chip.hidden !== false || chip.textContent.indexOf("1 running") === -1) throw new Error("after one task completes the chip must show '1 running', got hidden=" + chip.hidden + " text=" + JSON.stringify(chip.textContent));

  await pollArtifactTraceEvents();
  if (chip.hidden !== true) throw new Error("once BOTH tasks are terminal the chip must hide, got hidden=" + chip.hidden + " text=" + JSON.stringify(chip.textContent));
  console.log("QUEUE_CHIP_REAL_COUNT_OK true");
}

// round 1 JUDGMENT CALL: a transient poll failure stays silent (self-heals
// next tick); a STUCK one (3 consecutive misses) earns exactly one honest
// console.warn, and a later success resets the counter so a later stuck
// run can signal again.
{
  const origWarn = console.warn;
  const warnCalls = [];
  console.warn = (...args) => { warnCalls.push(args); };
  window.__artifactPollFailures = 0;
  global.fetch = async () => { throw new Error("network down"); };
  await pollArtifactTraceEvents();
  await pollArtifactTraceEvents();
  if (warnCalls.length !== 0) throw new Error("1-2 consecutive failures must stay silent (self-healing), got " + warnCalls.length + " warnings");
  await pollArtifactTraceEvents();
  if (warnCalls.length !== 1) throw new Error("the 3rd consecutive failure must emit exactly one honest signal, got " + warnCalls.length);
  global.fetch = async () => ({ json: async () => ({events: []}) });
  await pollArtifactTraceEvents();
  if (window.__artifactPollFailures !== 0) throw new Error("a later success must reset the failure counter, got " + window.__artifactPollFailures);
  console.warn = origWarn;
  console.log("POLL_FAILURE_SIGNAL_OK true");
}

})().catch(err => { console.error(err); process.exit(1); });
NODEJS
if node "$_aap2_node" "$NVHTML_AP" >/tmp/aap2_out.$$ 2>&1; then
    for tag in VIEWER_ABSENT_PRE_COMPLETION_OK VIEWER_MOUNTS_ON_COMPLETION_OK TTS_ANNOUNCE_OK CHAT_LINK_COMPLETION_OK RAIL_APPEND_ORDER_OK FAILURE_SURFACED_OK NO_TURN_ID_NOOP_OK QUEUE_CHIP_OK VIEWER_ROUTES_BY_TYPE_OK TRANSFORM_ORIGIN_PX_OK REDUCED_MOTION_GATED_OK CLOSE_NULLS_AND_REOPENS_OK QUEUE_CHIP_REAL_COUNT_OK POLL_FAILURE_SIGNAL_OK; do
        check "artifact-panel DOM harness: $tag" "$tag true" "$(cat /tmp/aap2_out.$$)"
    done
else
    echo "FAIL: artifact-panel DOM harness errored:" >&2
    cat /tmp/aap2_out.$$ >&2
    fails=$((fails+1))
fi
rm -f /tmp/aap2_out.$$ "$_aap2_node"
