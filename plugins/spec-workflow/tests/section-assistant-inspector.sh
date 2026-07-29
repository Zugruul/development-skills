#!/usr/bin/env bash
# section-assistant-inspector.sh -- AST-044: voice-panel metrics expansion
# (SPEC-ASSISTANT.md §10.5, issue #330). Sourced by run-tests.sh; do not run
# standalone. Contract: the runner already defines set -uo pipefail and has
# sourced _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/
# fails/flaky before sourcing this file. This file assumes those are already
# in scope.
#
# Template-only: no engine change was needed for this task -- GET
# /assistant/metrics and GET /assistant/traces already return everything
# this fold needs (AST-043, #329). This section extracts and exercises the
# template's inspector functions, the same "extract() + eval() named
# functions against a stubbed DOM+fetch" harness style as
# section-assistant-chat.sh / section-assistant-selection.sh.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant inspector (AST-044: voice-panel metrics expansion, SPEC-ASSISTANT.md §10.5, issue #330) =="

echo "-- template: percentile estimation, turn grouping, waterfall geometry, error flagging, gated/offline, turn-click wiring --"
NVHTML_INSPECTOR="$PLUGIN/templates/neural-view.html"

_ai_node="$(mktemp).cjs"
cat >"$_ai_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

// DOM stub, same "getter-only children Proxy" shape as
// section-assistant-chat.sh's -- `.children.length = 0` on a real live
// HTMLCollection throws (getter, no setter); `_items` is the real backing
// array, appendChild/innerHTML= mutate it directly, `.children` is a Proxy
// that forwards reads but throws on any external `set`.
const elements = {};
function mkEl(initialId) {
    const el = {
        _id: initialId,
        _classes: new Set(),
        classList: {
            add(c){ this._parent._classes.add(c); },
            remove(c){ this._parent._classes.delete(c); },
            contains(c){ return this._parent._classes.has(c); },
            // renderAssistantPicker's setActiveRow() (three-way Esc test,
            // review round 1 #330) is the first real caller here needing
            // toggle -- same add/remove-by-boolean semantics as a real
            // DOMTokenList's.
            toggle(c, force){
                const on = force === undefined ? !this.contains(c) : !!force;
                if(on) this.add(c); else this.remove(c);
                return on;
            },
        },
        disabled: false,
        title: "",
        textContent: "",
        value: "",
        style: {},
        _items: [],
        get children(){
            return new Proxy(this._items, {
                set(_target, prop){
                    throw new TypeError("Cannot set property " + String(prop) + " of #<Array> which has only a getter");
                },
            });
        },
        appendChild(child){ this._items.push(child); },
        get innerHTML(){ return this._innerHTML || ""; },
        set innerHTML(v){ this._items.length = 0; this._innerHTML = v; },
        get id(){ return this._id; },
        set id(v){ this._id = v; if (v) elements[v] = this; },
        // AST-044 restyle (Option B, #330): the inspector window is now a
        // detached DOM subtree (mirrors .note-window/.media-window) instead
        // of static markup -- remove() must tear down the WHOLE subtree's id
        // registrations, not just its own, or a stale entry would let
        // getElementById keep "seeing" a closed window's children (a real
        // browser's document tree removal has this same effect for free).
        remove(){
            if (this._id && elements[this._id] === this) delete elements[this._id];
            for (const child of this._items || []) if (child && typeof child.remove === "function") child.remove();
        },
        get className(){ return [...this._classes].join(" "); },
        set className(v){ this._classes = new Set(v.split(" ").filter(Boolean)); },
        setAttribute(k, v){ this[k === "class" ? "className" : k] = v; this["_attr_" + k] = v; },
        getAttribute(k){ return this["_attr_" + k] !== undefined ? this["_attr_" + k] : null; },
        // minimal selector support (class + [attr] only) -- enough for
        // wireWinDrag's own querySelector(".grip")/querySelectorAll("[data-drag]")
        // calls, the only selectors the production window-chrome code uses.
        querySelector(sel){ return queryAll(this, sel)[0] || null; },
        querySelectorAll(sel){ return queryAll(this, sel); },
        addEventListener(){},
        removeEventListener(){},
        setPointerCapture(){},
        releasePointerCapture(){},
    };
    if (initialId) elements[initialId] = el;
    return el;
}
function matchesSel(el, sel) {
    if (sel[0] === ".") return !!(el.classList && el.classList.contains(sel.slice(1)));
    if (sel[0] === "[" && sel[sel.length - 1] === "]") return el.getAttribute && el.getAttribute(sel.slice(1, -1)) !== null;
    return false;
}
function queryAll(el, sel) {
    const out = [];
    for (const child of el._items || []) {
        if (matchesSel(child, sel)) out.push(child);
        out.push(...queryAll(child, sel));
    }
    return out;
}
function seedEl(id, className) {
    const el = mkEl(id);
    el.classList._parent = el;
    el.className = className;
    return el;
}
const docBody = mkEl(null);
const document = {
    body: docBody,
    getElementById(id) {
        return elements[id] || null;
    },
    createElement(_tag) {
        const el = mkEl(null);
        el.classList._parent = el;
        return el;
    },
};
// static in production markup, always present -- renderAssistantPicker
// (review round 1's three-way Esc coordination test) bails out early
// without it.
seedEl("ast-picker-anchor", "");
global.assistantChat = { queue: [], inFlight: false, exchanges: [], lastX: 2, elapsedTimer: null, elapsedStart: 0 };
global.window = global;

// AST-044 restyle (Option B, #330): openAstInspectorWindow/closeAstInspectorWindow
// bind/unbind a real keydown listener (Esc) while the window is open -- same
// "stub addEventListener like the DOM would, drive it with fireKeydown()"
// harness style as section-assistant-selection.sh's picker keydown tests.
global.__listeners = { keydown: [] };
global.addEventListener = (type, fn) => {
    global.__listeners[type] = global.__listeners[type] || [];
    global.__listeners[type].push(fn);
};
global.removeEventListener = (type, fn) => {
    const arr = global.__listeners[type] || [];
    const i = arr.indexOf(fn);
    if (i !== -1) arr.splice(i, 1);
};
function fireKeydown(props) {
    const ev = Object.assign({ defaultPrevented: false, preventDefault(){ this.defaultPrevented = true; } }, props);
    for (const fn of [...(global.__listeners.keydown || [])]) fn(ev);
    return ev;
}
// noteWinZ is a top-level `let` counter in production (shared by every
// detached-window opener: detachNote/openMediaViewer/open3dWindow/
// openAstInspectorWindow), not a function -- can't be extract()'d by name,
// so it's seeded here the same starting value production uses.
global.noteWinZ = 70;

let fetchCalls = [];
let statusResponse = null;
let metricsResponse = { roots: {} };
let tracesResponse = { events: [] };
let statusThrows = false;
let metricsThrows = false;
global.fetch = async (url) => {
    fetchCalls.push({url});
    if (url === "/assistant/status") {
        if (statusThrows) throw new Error("network down");
        return { status: 200, json: async () => statusResponse };
    }
    if (url === "/assistant/metrics") {
        if (metricsThrows) throw new Error("network down");
        return { status: 200, json: async () => metricsResponse };
    }
    if (url === "/assistant/traces?order=desc") {
        if (metricsThrows) throw new Error("network down");
        return { status: 200, json: async () => tracesResponse };
    }
    return { status: 200, json: async () => ({}) };
};

eval(extract("astMetricsBucketBoundaries"));
eval(extract("astMetricsBucketKey"));
eval(extract("astEstimatePercentile"));
eval(extract("astMetricsRootFor"));
eval(extract("astMetricsRow"));
// #460: the Per-area block's vertical bar columns, and the percentile
// marker-line position helper the bucket graph uses (the "percentile
// sparkline (p50/p95 lines)" half of the recorded #330 Option B decision
// text) -- both extracted here too, same "real production wiring" posture
// as the rest of this file's extract() list.
eval(extract("astMetricsBarCol"));
eval(extract("astMetricsValuePosition"));
eval(extract("buildAstMetricsGraphMarkup"));
eval(extract("renderAstMetrics"));
eval(extract("groupTurnsById"));
eval(extract("turnDurationMs"));
eval(extract("turnHasError"));
eval(extract("computeWaterfallSpans"));
eval(extract("astTurnDominantLabel"));
eval(extract("renderAstTurnlist"));
eval(extract("renderAstWaterfall"));
eval(extract("selectAstTurn"));
eval(extract("renderAstTruncated"));
eval(extract("renderAstInspectorGated"));
eval(extract("renderAstInspectorOffline"));
eval(extract("clearAstInspectorState"));
eval(extract("loadAssistantInspector"));
// AST-044 restyle (Option B, #330): the metrics/turns fold now lives in a
// detached window, same chrome family as .note-window/.media-window --
// wireWinDrag is the SAME shared drag helper those use (extracted here too,
// not reimplemented, so this exercises the real wiring).
eval(extract("wireWinDrag"));
eval(extract("buildAstInspectorWindow"));
eval(extract("closeAstInspectorWindow"));
eval(extract("handleAstInspectorKeydown"));
eval(extract("openAstInspectorWindow"));
// review round 1 (#330): a three-way Esc coordination test needs the OTHER
// two real Esc owners too (the T-key chat overlay, the AST-021 picker) --
// extracted verbatim, same "real production wiring, not a simplified
// fork" posture section-assistant-selection.sh already uses for the
// chat<->picker pair. onPickerKeydown itself is a nested function inside
// renderAssistantPicker (extract()'s "up to the first unindented \n}\n"
// regex can only grab whole top-level functions) -- calling the real
// renderAssistantPicker(candidates) is what binds it for real, exactly
// like initAssistantSelection() does in production.
eval(extract("setVoiceHeaderName"));
eval(extract("gateVoiceAndChat"));
eval(extract("escapeHtml"));
eval(extract("isChatTypingTarget"));
eval(extract("unbindAssistantPickerKeys"));
eval(extract("renderAssistantPicker"));
eval(extract("stopChatElapsed"));
global.syncChatDockBodyClass = () => {};
if (typeof global.stopChatStatusSync === "undefined") global.stopChatStatusSync = () => {};
eval(extract("closeChatOverlay"));
eval(extract("handleAssistantChatKeydown"));

function resetInspector() {
    for (const id of ["ast-metrics-refresh", "ast-metrics-retry", "ast-metrics-state", "ast-metrics", "ast-truncated", "ast-turnlist", "ast-waterfall"]) {
        delete elements[id];
    }
    seedEl("ast-metrics-refresh", "iconbtn");
    seedEl("ast-metrics-retry", "iconbtn ast-metrics-retry ast-metrics-hidden");
    seedEl("ast-metrics-state", "ast-metrics-state");
    seedEl("ast-metrics", "ast-metrics");
    seedEl("ast-truncated", "ast-truncated ast-metrics-hidden");
    seedEl("ast-turnlist", "ast-turnlist");
    seedEl("ast-waterfall", "ast-waterfall ast-metrics-hidden");
    fetchCalls = [];
    statusThrows = false;
    metricsThrows = false;
    statusResponse = {outcome: "one", candidates: [{name: "jarvis", aliases: [], root: "/r"}], selected: "jarvis", gated: false, askAgain: false};
    metricsResponse = { roots: {} };
    tracesResponse = { events: [] };
    window.assistantInspector = { turns: [], selectedTurnId: null };
}

const TURN_EVENTS = [
    {kind: "turn.start", turn_id: "A", ts: "2024-01-01T00:00:00.000Z"},
    {kind: "recall.summary", turn_id: "A", ts: "2024-01-01T00:00:00.500Z"},
    {kind: "provider.call", turn_id: "A", ts: "2024-01-01T00:00:00.500Z", status: "ok"},
    {kind: "turn.end", turn_id: "A", ts: "2024-01-01T00:00:02.000Z", status: "ok"},
    {kind: "turn.start", turn_id: "B", ts: "2024-01-01T00:00:03.000Z"},
    {kind: "provider.error", turn_id: "B", ts: "2024-01-01T00:00:03.200Z", status: "error", payload: {error: "boom"}},
    {kind: "turn.end", turn_id: "B", ts: "2024-01-01T00:00:03.400Z", status: "error"},
];

const flushMicrotasks = () => new Promise(r => setTimeout(r, 0));

(async () => {
    // ---- percentile estimation math, from a known cumulative-bucket fixture ----
    const bucketsMid = {"0.1": 0, "0.5": 2, "1": 5, "2": 8, "5": 10, "10": 10, "30": 10, "+Inf": 10};
    if (astEstimatePercentile(bucketsMid, 10, 0.5) !== 1) throw new Error("p50 mismatch: " + astEstimatePercentile(bucketsMid, 10, 0.5));
    if (astEstimatePercentile(bucketsMid, 10, 0.95) !== 4.25) throw new Error("p95 mismatch: " + astEstimatePercentile(bucketsMid, 10, 0.95));
    if (astEstimatePercentile({}, 0, 0.5) !== null) throw new Error("zero-count percentile must be null");
    const bucketsTail = {"0.1": 0, "0.5": 0, "1": 0, "2": 0, "5": 0, "10": 0, "30": 2, "+Inf": 10};
    if (astEstimatePercentile(bucketsTail, 10, 0.5) !== 30) throw new Error("past-last-finite-bucket estimate should be the last finite boundary (30), got " + astEstimatePercentile(bucketsTail, 10, 0.5));
    console.log("PERCENTILE_MATH_OK true");

    // ---- turn grouping + duration computation ----
    const turns = groupTurnsById(TURN_EVENTS);
    if (turns.length !== 2) throw new Error("expected 2 grouped turns, got " + turns.length);
    if (turns[0].turnId !== "A" || turns[1].turnId !== "B") throw new Error("turn order not preserved: " + JSON.stringify(turns.map(t => t.turnId)));
    if (turnDurationMs(turns[0]) !== 2000) throw new Error("turn A duration mismatch: " + turnDurationMs(turns[0]));
    if (turnHasError(turns[0])) throw new Error("turn A must not be flagged as error");
    if (!turnHasError(turns[1])) throw new Error("turn B (provider.error + status error) must be flagged as error");
    console.log("TURN_GROUPING_OK true");

    // ---- waterfall geometry: offsets/widths proportional to ts deltas, zero/unknown durations render as instants ----
    const spansA = computeWaterfallSpans(turns[0]);
    if (spansA.length !== 4) throw new Error("expected 4 spans for turn A, got " + spansA.length);
    if (spansA[0].offsetPct !== 0 || spansA[0].widthPct !== 25 || spansA[0].instant) throw new Error("span0 geometry wrong: " + JSON.stringify(spansA[0]));
    if (spansA[1].offsetPct !== 25 || !spansA[1].instant) throw new Error("span1 (zero-delta) should be an instant: " + JSON.stringify(spansA[1]));
    if (spansA[2].offsetPct !== 25 || spansA[2].widthPct !== 75 || spansA[2].instant) throw new Error("span2 geometry wrong: " + JSON.stringify(spansA[2]));
    if (spansA[3].offsetPct !== 100 || !spansA[3].instant) throw new Error("span3 (last event) should be an instant: " + JSON.stringify(spansA[3]));
    console.log("WATERFALL_GEOMETRY_OK true");

    // ---- error inline flagging: rendered bar carries the class + payload message as title ----
    resetInspector();
    renderAstWaterfall(turns[1]);
    const wfEl = document.getElementById("ast-waterfall");
    if (wfEl.classList.contains("ast-metrics-hidden")) throw new Error("rendering a turn must reveal the waterfall");
    // Option B rows (2026-07-29): each span renders as an .ast-waterfall-row
    // (label · track lane · duration); the track nests inside the row now.
    const wrows = wfEl.children.filter(c => c.className.includes("ast-waterfall-row"));
    if (wrows.length !== 3) throw new Error("expected 3 waterfall rows for turn B, got " + wrows.length);
    const trackB = wrows[1].children.find(c => c.className.includes("ast-waterfall-track"));
    if (!trackB) throw new Error("waterfall row must nest its track lane");
    const errorBar = trackB.children.find(b => b.className.includes("ast-waterfall-error"));
    if (!errorBar) throw new Error("provider.error span must render with ast-waterfall-error");
    if (errorBar.title !== "boom") throw new Error("error bar title must carry the payload message verbatim: " + errorBar.title);
    console.log("ERROR_INLINE_OK true");

    // ---- gated branches: reuse the existing status-reason posture ----
    resetInspector();
    renderAstInspectorGated({outcome: "multiple", gated: true});
    let stateText = document.getElementById("ast-metrics-state").textContent;
    if (!document.getElementById("ast-metrics-state").className.includes("ast-metrics-state-gated")) throw new Error("gated (skip) must set the gated state class");
    if (!stateText || stateText.toLowerCase().indexOf("switcher") === -1) throw new Error("gated (skip) reason text missing: " + stateText);
    console.log("GATED_SKIP_OK true");

    resetInspector();
    renderAstInspectorGated({outcome: "none", gated: true});
    stateText = document.getElementById("ast-metrics-state").textContent;
    if (!stateText || stateText.toLowerCase().indexOf("no assistant") === -1) throw new Error("gated (none) reason text missing: " + stateText);
    console.log("GATED_NONE_OK true");

    // ---- offline branch: fetch failure shows a specific message + retry hook ----
    resetInspector();
    renderAstInspectorOffline();
    stateText = document.getElementById("ast-metrics-state").textContent;
    if (!stateText || stateText.toLowerCase().indexOf("offline") === -1) throw new Error("offline message missing: " + stateText);
    if (document.getElementById("ast-metrics-retry").className.includes("ast-metrics-hidden")) throw new Error("offline must reveal the retry affordance");
    console.log("OFFLINE_OK true");

    // ---- end-to-end: load wires metrics+turns, click wires the waterfall ----
    resetInspector();
    metricsResponse = { roots: { jarvis: {
        turnsByStatus: {ok: 1, error: 1},
        providerErrors: 1,
        eventsTotal: {turn: 4, recall: 1, provider: 2},
        distillBatches: 0,
        notesMinted: 0,
        turnDuration: {count: 1, sum: 2, buckets: {"0.1": 0, "0.5": 0, "1": 0, "2": 1, "5": 1, "10": 1, "30": 1, "+Inf": 1}},
    } } };
    tracesResponse = { events: TURN_EVENTS };
    await loadAssistantInspector();
    if (fetchCalls.filter(c => c.url === "/assistant/metrics").length !== 1) throw new Error("open must fetch /assistant/metrics exactly once");
    if (fetchCalls.filter(c => c.url === "/assistant/traces?order=desc").length !== 1) throw new Error("open must fetch /assistant/traces?order=desc exactly once (#393: newest-first, not the stale oldest-first default)");
    if (!document.getElementById("ast-truncated").classList.contains("ast-metrics-hidden")) throw new Error("truncated marker must stay hidden when the response carries no truncated flag");
    const metricsEl = document.getElementById("ast-metrics");
    // rows are built from two child <span>s (label, value) -- the stub's
    // `textContent` is a plain field (unlike a real DOM's auto-aggregating
    // one), so read it off the children the way the stub actually supports.
    // #460: rows now nest inside the Latency/Per-area blocks (mockup's real
    // two-column .wtop composition), so this uses querySelectorAll(".ast-
    // metrics-row") (recursive, unlike raw .children) instead of assuming
    // every row is a direct child of #ast-metrics.
    const metricsRowEls = metricsEl.querySelectorAll(".ast-metrics-row");
    const metricsRows = metricsRowEls.map(r => (r.children || []).map(c => c.textContent).join(" "));
    if (!metricsRows.some(t => t.indexOf("p50 turn duration") !== -1 && t.indexOf("1.50s") !== -1)) throw new Error("p50 row wrong: " + JSON.stringify(metricsRows));
    if (!metricsRows.some(t => t.indexOf("p95 turn duration") !== -1 && t.indexOf("1.95s") !== -1)) throw new Error("p95 row wrong: " + JSON.stringify(metricsRows));
    if (!metricsRows.some(t => t.indexOf("turns ok") !== -1 && t.indexOf("1") !== -1)) throw new Error("turns-ok row wrong: " + JSON.stringify(metricsRows));
    const graphHost = metricsEl.querySelectorAll(".ast-metrics-graph-host")[0];
    if (!graphHost || graphHost.innerHTML.indexOf("ast-metrics-graph") === -1) throw new Error("expected a structural ast-metrics-graph SVG placeholder to render");
    console.log("LOAD_METRICS_OK true");

    // ---- #460: real Option B composition, cross-checked against the
    // finalized mockup (.claude/ui-hub/html/AST-044-r1.html) after an
    // earlier pass of this fix had only gone by the recorded decision text
    // -- two side-by-side blocks (Latency, Per area), percentile marker
    // lines on the bucket graph, and eventsTotal-bound vertical bar columns
    // for the per-area breakdown (turn/recall/provider from the fixture
    // above), not the flat text-row list the shipped restyle regressed to.
    const blocks = metricsEl.querySelectorAll(".ast-metrics-block");
    if (blocks.length !== 2) throw new Error("expected 2 top-level blocks (Latency, Per area), got " + blocks.length);
    const blabs = metricsEl.querySelectorAll(".ast-metrics-blab").map(b => b.textContent);
    if (blabs.indexOf("Latency") === -1) throw new Error("Latency block label missing: " + JSON.stringify(blabs));
    if (blabs.indexOf("Per area") === -1) throw new Error("Per area block label missing: " + JSON.stringify(blabs));
    const legends = metricsEl.querySelectorAll(".ast-metrics-legend").map(l => l.className + ":" + l.textContent);
    if (!legends.some(l => l.indexOf("ast-metrics-legend-p50") !== -1 && l.indexOf("p50") !== -1)) throw new Error("p50 legend chip missing: " + JSON.stringify(legends));
    if (!legends.some(l => l.indexOf("ast-metrics-legend-p95") !== -1 && l.indexOf("p95") !== -1)) throw new Error("p95 legend chip missing: " + JSON.stringify(legends));
    if (graphHost.innerHTML.indexOf("ast-metrics-marker-p50") === -1) throw new Error("bucket graph missing the p50 marker line");
    if (graphHost.innerHTML.indexOf("ast-metrics-marker-p95") === -1) throw new Error("bucket graph missing the p95 marker line");
    const barcols = metricsEl.querySelectorAll(".ast-metrics-barcol");
    if (barcols.length !== 3) throw new Error("expected 3 per-area bar columns (turn/recall/provider from the eventsTotal fixture), got " + barcols.length);
    const barByLabel = {};
    for (const col of barcols) {
        const lab = col.querySelectorAll(".ast-metrics-barlab")[0];
        const val = col.querySelectorAll(".ast-metrics-barval")[0];
        const fill = col.querySelectorAll(".ast-metrics-barfill")[0];
        barByLabel[lab.textContent] = { value: val.textContent, height: fill.style.height };
    }
    if (!barByLabel.turn || barByLabel.turn.value !== "4" || barByLabel.turn.height !== "100%") throw new Error("turn bar wrong (eventsTotal max=4): " + JSON.stringify(barByLabel));
    if (!barByLabel.recall || barByLabel.recall.value !== "1" || barByLabel.recall.height !== "25%") throw new Error("recall bar wrong: " + JSON.stringify(barByLabel));
    if (!barByLabel.provider || barByLabel.provider.value !== "2" || barByLabel.provider.height !== "50%") throw new Error("provider bar wrong: " + JSON.stringify(barByLabel));
    console.log("METRICS_BARS_AND_MARKERS_OK true");

    const turnlistEl = document.getElementById("ast-turnlist");
    if (turnlistEl.children.length !== 2) throw new Error("expected 2 turn rows, got " + turnlistEl.children.length);
    const rowB = turnlistEl.children.find(r => r.getAttribute("data-turn-id") === "B");
    if (!rowB || !rowB.className.includes("ast-turnlist-error")) throw new Error("turn B row must carry ast-turnlist-error");
    console.log("TURNLIST_OK true");

    if (!document.getElementById("ast-waterfall").classList.contains("ast-metrics-hidden")) throw new Error("waterfall must stay hidden before any turn is clicked");
    rowB.onclick();
    const wfAfterClick = document.getElementById("ast-waterfall");
    if (wfAfterClick.classList.contains("ast-metrics-hidden")) throw new Error("clicking a turn row must reveal the waterfall");
    const clickedRows = wfAfterClick.children.filter(c => c.className.includes("ast-waterfall-row"));
    if (clickedRows.length !== 3) throw new Error("waterfall after click should have 3 rows (turn B's 3 events), got " + clickedRows.length);
    const clickedTrack = clickedRows[1].children.find(c => c.className.includes("ast-waterfall-track"));
    const clickedError = clickedTrack && clickedTrack.children.find(b => b.className.includes("ast-waterfall-error"));
    if (!clickedError || clickedError.title !== "boom") throw new Error("waterfall after click must still carry the error bar + title");
    const rowBAfter = turnlistEl.children.find(r => r.getAttribute("data-turn-id") === "B");
    if (!rowBAfter.className.includes("ast-turnlist-selected")) throw new Error("clicked row must be marked selected");
    console.log("TURN_CLICK_WIRING_OK true");

    // ---- #460, second conformance pass (mockup `.mB2 .wbot .blab`): a
    // turn-context header above the waterfall, missing from the shipped
    // restyle entirely -- built from real fields (id/status/duration), not
    // the mockup's own illustrative wording ("provider call"), which this
    // data does not carry. ----
    const turnlab = wfAfterClick.children.find(c => c.className && c.className.includes("ast-waterfall-turnlab"));
    if (!turnlab) throw new Error("waterfall missing its ast-waterfall-turnlab header");
    // 2026-07-29: the header is a flex row now -- text span + the raw-JSON
    // detach button (human-directed) -- so the text lives on the first child.
    const turnlabText = turnlab.children && turnlab.children[0] ? turnlab.children[0].textContent : turnlab.textContent;
    if (turnlabText !== "Turn B · error · 0.40s") throw new Error("turn-context header wrong: " + JSON.stringify(turnlabText));
    const rawBtn = turnlab.children.find(c => c.className && c.className.includes("ast-waterfall-raw"));
    if (!rawBtn) throw new Error("waterfall header missing the raw-provider-JSON detach button");
    console.log("WATERFALL_TURNLAB_OK true");

    // ---- #393: truncated marker reveals/hides on the endpoint's own truncated flag ----
    resetInspector();
    tracesResponse = { events: TURN_EVENTS, truncated: true };
    await loadAssistantInspector();
    if (document.getElementById("ast-truncated").classList.contains("ast-metrics-hidden")) throw new Error("truncated=true must reveal the ast-truncated marker");
    resetInspector();
    tracesResponse = { events: TURN_EVENTS, truncated: false };
    await loadAssistantInspector();
    if (!document.getElementById("ast-truncated").classList.contains("ast-metrics-hidden")) throw new Error("truncated=false must keep the ast-truncated marker hidden");
    console.log("TRUNCATED_MARKER_OK true");

    // ---- AST-044 restyle (Option B, #330): detached inspector window --
    // open/focus/close lifecycle + Esc ownership handshake ----
    function resetInspectorWindow() {
        delete elements["ast-inspector-window"];
        docBody._items.length = 0;
        global.__listeners.keydown = [];
        window.astInspectorWin = null;
        window.__astInspectorKeydown = null;
        fetchCalls = [];
        statusResponse = {outcome: "one", candidates: [{name: "jarvis", aliases: [], root: "/r"}], selected: "jarvis", gated: false, askAgain: false};
        metricsResponse = { roots: {} };
        tracesResponse = { events: [] };
        window.assistantInspector = { turns: [], selectedTurnId: null };
    }

    // opening builds the window (pinned chrome + fold ids), fetches once,
    // appends to <body>, and binds exactly one keydown listener
    resetInspectorWindow();
    const win1 = openAstInspectorWindow();
    await flushMicrotasks();
    if (!win1 || win1.id !== "ast-inspector-window") throw new Error("openAstInspectorWindow did not build the window");
    if (docBody._items.indexOf(win1) === -1) throw new Error("window was not appended to document.body");
    if (window.astInspectorWin !== win1) throw new Error("window.astInspectorWin not set to the opened window");
    if (!document.getElementById("ast-metrics") || !document.getElementById("ast-turnlist") || !document.getElementById("ast-waterfall"))
        throw new Error("window is missing one of the pinned fold ids (ast-metrics/ast-turnlist/ast-waterfall)");
    if (fetchCalls.filter(c => c.url === "/assistant/metrics").length !== 1) throw new Error("opening the window did not fetch /assistant/metrics");
    if ((global.__listeners.keydown || []).length !== 1) throw new Error("open must bind exactly one keydown listener, got " + (global.__listeners.keydown || []).length);
    if (window.__astInspectorKeydown !== handleAstInspectorKeydown) throw new Error("window.__astInspectorKeydown must reference the bound handler");
    console.log("OPEN_BUILDS_AND_LOADS_OK true");

    // ---- #460: the dot row from the finalized mockup (.claude/ui-hub/
    // html/AST-044-r1.html, Option B `.mB2 .dots i`, 3 dots) -- missing
    // from the shipped restyle entirely; the grip also carries the
    // mockup's own "⠿ drag" label, not the bare-icon convention this app's
    // OTHER detached windows use. ----
    const dotsEl = win1.querySelectorAll(".aiw-dots")[0];
    if (!dotsEl) throw new Error("title bar missing the .aiw-dots row");
    if ((dotsEl.children || []).length !== 3) throw new Error("expected 3 dots in the title bar, got " + (dotsEl.children || []).length);
    const gripEl = win1.querySelectorAll(".grip")[0];
    if (!gripEl || gripEl.textContent !== "⠿ drag") throw new Error("grip must carry the mockup's own label, got: " + JSON.stringify(gripEl && gripEl.textContent));
    console.log("DOTS_AND_GRIP_OK true");

    // reopening while already open FOCUSES (same reference, raised z-index,
    // no duplicate fetch, no second listener) instead of opening a duplicate
    const zBefore = win1.style.zIndex;
    fetchCalls = [];
    const win2 = openAstInspectorWindow();
    if (win2 !== win1) throw new Error("reopening while open must return the SAME window, not a duplicate");
    if (Number(win2.style.zIndex) <= Number(zBefore)) throw new Error("reopening while open must raise z-index (focus): before=" + zBefore + " after=" + win2.style.zIndex);
    if (fetchCalls.length !== 0) throw new Error("reopening an already-open window must not re-fetch");
    if ((global.__listeners.keydown || []).length !== 1) throw new Error("reopening while open must not bind a second keydown listener");
    console.log("REOPEN_FOCUSES_OK true");

    // closing tears down BOTH the window and its keydown listener
    closeAstInspectorWindow();
    if (window.astInspectorWin !== null) throw new Error("close must clear window.astInspectorWin");
    if (document.getElementById("ast-inspector-window")) throw new Error("close must remove the window from the DOM");
    if (document.getElementById("ast-metrics")) throw new Error("close must remove the window's descendant fold ids too");
    if ((global.__listeners.keydown || []).length !== 0) throw new Error("close must unbind the keydown listener (leaked: " + (global.__listeners.keydown || []).length + " remaining)");
    if (window.__astInspectorKeydown !== null) throw new Error("close must clear window.__astInspectorKeydown");
    console.log("CLOSE_TEARS_DOWN_OK true");

    // reopening after a close fetches fresh data again (not a stale window)
    resetInspectorWindow();
    openAstInspectorWindow();
    await flushMicrotasks();
    closeAstInspectorWindow();
    fetchCalls = [];
    openAstInspectorWindow();
    await flushMicrotasks();
    if (fetchCalls.filter(c => c.url === "/assistant/metrics").length !== 1) throw new Error("reopening after a close must fetch fresh metrics again");
    console.log("REOPEN_AFTER_CLOSE_REFETCHES_OK true");

    // Esc owns the keypress when nothing claimed it first: closes + marks
    // the event handled (preventDefault) so listeners bound after this one
    // can defer via the same ev.defaultPrevented flag the picker checks
    let ev = fireKeydown({key: "Escape"});
    if (window.astInspectorWin !== null) throw new Error("Esc must close the inspector window when it owns the keypress");
    if (!ev.defaultPrevented) throw new Error("Esc must call preventDefault when the inspector window handles it");
    console.log("ESC_CLOSES_OK true");

    // Esc defers when another handler already claimed it (defaultPrevented
    // already true) -- window.astInspectorWin currently null (closed above,
    // simulating "nothing to own" is a distinct case); reopen and prove a
    // pre-claimed event does NOT get closed by the inspector's own handler
    resetInspectorWindow();
    openAstInspectorWindow();
    await flushMicrotasks();
    handleAstInspectorKeydown({key: "Escape", defaultPrevented: true, preventDefault(){ throw new Error("must not preventDefault an already-claimed event"); }});
    if (window.astInspectorWin === null) throw new Error("Esc must NOT close the inspector window when ev.defaultPrevented is already true (another handler owns it)");
    console.log("ESC_DEFERS_WHEN_ALREADY_CLAIMED_OK true");

    // non-Escape keys are ignored
    handleAstInspectorKeydown({key: "a", defaultPrevented: false, preventDefault(){ throw new Error("must not preventDefault a non-Escape key"); }});
    if (window.astInspectorWin === null) throw new Error("a non-Escape keydown must not close the inspector window");
    closeAstInspectorWindow();
    console.log("ESC_ONLY_OK true");

    // ---- review round 1 (#330): three-way Esc coordination -- the T-key
    // chat overlay (handleAssistantChatKeydown, bound unconditionally at
    // module load, never torn down) and the AST-021 picker (onPickerKeydown,
    // bound only while its own card is open, via the real
    // renderAssistantPicker) are BOTH already-shipped real Esc owners; the
    // inspector's handler must slot into the SAME defaultPrevented ownership
    // chain without double-firing or starving the others. fireKeydown()
    // drives every currently-bound listener in registration order on one
    // shared event object, exactly like a real Escape keypress dispatches.
    function resetThreeWay() {
        delete elements["ast-inspector-window"];
        delete elements["ast-chat-overlay"];
        delete elements["ast-picker-wrap"];
        delete elements["ast-picker"];
        docBody._items.length = 0;
        global.__listeners.keydown = [];
        window.astInspectorWin = null;
        window.__astInspectorKeydown = null;
        window.__astPickerKeydown = null;
        fetchCalls = [];
        statusResponse = {outcome: "one", candidates: [{name: "jarvis", aliases: [], root: "/r"}], selected: "jarvis", gated: false, askAgain: false};
        metricsResponse = { roots: {} };
        tracesResponse = { events: [] };
        window.assistantInspector = { turns: [], selectedTurnId: null };
        window.assistantChat = { queue: [], inFlight: false, exchanges: [], lastX: 2, elapsedTimer: null, elapsedStart: 0 };
        addEventListener("keydown", handleAssistantChatKeydown);   // module-load binding, never torn down
    }

    // A) chat overlay + picker + inspector all open: the chat overlay is
    // registered FIRST (module load) and claims Escape -- neither the
    // picker nor the inspector may also act on the same keypress.
    resetThreeWay();
    document.createElement("div").id = "ast-chat-overlay";   // id setter registers it in elements[], same as production's getElementById lookup
    renderAssistantPicker([{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}]);
    openAstInspectorWindow();
    await flushMicrotasks();
    fetchCalls = [];
    const evA = fireKeydown({key: "Escape"});
    await flushMicrotasks();
    if (document.getElementById("ast-chat-overlay")) throw new Error("3-way A: the chat overlay should have closed (it owns this Escape)");
    if (!evA.defaultPrevented) throw new Error("3-way A: the chat overlay must preventDefault when it owns Escape");
    if (!document.getElementById("ast-picker-wrap")) throw new Error("3-way A: the picker must NOT act once the chat overlay already claimed Escape");
    if (fetchCalls.some(c => c.url === "/assistant/skip")) throw new Error("3-way A: the picker must not Skip once the chat overlay already claimed Escape");
    if (window.astInspectorWin === null) throw new Error("3-way A: the inspector must NOT close once the chat overlay already claimed Escape");
    console.log("THREEWAY_CHAT_OWNS_OK true");

    // B) no chat overlay, picker + inspector open: the picker is registered
    // right after the (inert, no overlay) chat handler and owns Escape --
    // Skip fires, the inspector must defer and stay open.
    resetThreeWay();
    renderAssistantPicker([{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}]);
    openAstInspectorWindow();
    await flushMicrotasks();
    fetchCalls = [];
    fireKeydown({key: "Escape"});
    await flushMicrotasks();
    if (document.getElementById("ast-picker-wrap")) throw new Error("3-way B: the picker must act (Skip-close) when nothing claimed Escape first");
    if (!fetchCalls.some(c => c.url === "/assistant/skip")) throw new Error("3-way B: Skip did not fire");
    if (window.astInspectorWin === null) throw new Error("3-way B: the inspector must defer (stay open) once the picker already claimed Escape");
    console.log("THREEWAY_PICKER_OWNS_OK true");

    // C) no chat overlay, no picker: the inspector is the only real owner
    // left on the listener chain and must still close.
    resetThreeWay();
    openAstInspectorWindow();
    await flushMicrotasks();
    fireKeydown({key: "Escape"});
    if (window.astInspectorWin !== null) throw new Error("3-way C: the inspector must close Escape when it is the only remaining owner");
    console.log("THREEWAY_INSPECTOR_OWNS_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_inspector_out="$(node "$_ai_node" "$NVHTML_INSPECTOR" 2>&1)"
tmpl_inspector_rc=$?
rm -f "$_ai_node"
check_rc "inspector template script exits 0" 0 "$tmpl_inspector_rc"
check "template: percentile estimation from a known cumulative-bucket fixture" "PERCENTILE_MATH_OK true" "$tmpl_inspector_out"
check "template: turn grouping + duration computation from a fixture events list" "TURN_GROUPING_OK true" "$tmpl_inspector_out"
check "template: waterfall geometry (offsets/widths proportional, instants handled)" "WATERFALL_GEOMETRY_OK true" "$tmpl_inspector_out"
check "template: error events flag inline with the payload message as title" "ERROR_INLINE_OK true" "$tmpl_inspector_out"
check "template: gated (skip) shows the gate reason" "GATED_SKIP_OK true" "$tmpl_inspector_out"
check "template: gated (outcome none) shows the gate reason" "GATED_NONE_OK true" "$tmpl_inspector_out"
check "template: offline (fetch failure) shows a specific message with a retry hook" "OFFLINE_OK true" "$tmpl_inspector_out"
check "template: loading fetches metrics+traces once and renders percentile/counter rows + graph placeholder" "LOAD_METRICS_OK true" "$tmpl_inspector_out"
check "template (#460, cross-checked against the finalized AST-044-r1.html Option B mockup): the top section is a Latency block (legend chips + graph w/ p50/p95 markers) and a Per-area block (eventsTotal-bound vertical bar columns), not a flat text-row list" "METRICS_BARS_AND_MARKERS_OK true" "$tmpl_inspector_out"
check "template: turn list renders grouped turns with an error hook class" "TURNLIST_OK true" "$tmpl_inspector_out"
check "template: clicking a turn wires the waterfall render" "TURN_CLICK_WIRING_OK true" "$tmpl_inspector_out"
check "template (#460): waterfall carries a turn-context header (id/status/duration) above the spans, matching the mockup's .wbot .blab" "WATERFALL_TURNLAB_OK true" "$tmpl_inspector_out"
check "template (#393): fetches /assistant/traces?order=desc, and the truncated marker follows the endpoint's own flag" "TRUNCATED_MARKER_OK true" "$tmpl_inspector_out"
check "template (#330 Option B): opening the inspector builds the detached window, loads once, binds one keydown listener" "OPEN_BUILDS_AND_LOADS_OK true" "$tmpl_inspector_out"
check "template (#460): title bar carries the mockup's dot row (3 dots) and the grip's own drag label" "DOTS_AND_GRIP_OK true" "$tmpl_inspector_out"
check "template (#330 Option B): reopening while already open focuses (same window, raised z-index) instead of duplicating" "REOPEN_FOCUSES_OK true" "$tmpl_inspector_out"
check "template (#330 Option B): closing removes the window AND unbinds its keydown listener" "CLOSE_TEARS_DOWN_OK true" "$tmpl_inspector_out"
check "template (#330 Option B): reopening after a close fetches fresh data again" "REOPEN_AFTER_CLOSE_REFETCHES_OK true" "$tmpl_inspector_out"
check "template (#330 Option B): Esc closes the inspector window when it owns the keypress" "ESC_CLOSES_OK true" "$tmpl_inspector_out"
check "template (#330 Option B): Esc defers to an already-claimed event (defaultPrevented) instead of double-closing" "ESC_DEFERS_WHEN_ALREADY_CLAIMED_OK true" "$tmpl_inspector_out"
check "template (#330 Option B): non-Escape keydowns are ignored by the inspector's handler" "ESC_ONLY_OK true" "$tmpl_inspector_out"
check "template (review round 1, #330): chat overlay + picker + inspector all open -- the chat overlay (registered first) owns Escape, the other two do not act" "THREEWAY_CHAT_OWNS_OK true" "$tmpl_inspector_out"
check "template (review round 1, #330): picker + inspector open, no chat overlay -- the picker owns Escape, the inspector defers" "THREEWAY_PICKER_OWNS_OK true" "$tmpl_inspector_out"
check "template (review round 1, #330): inspector open alone -- it is the sole remaining owner and closes on Escape" "THREEWAY_INSPECTOR_OWNS_OK true" "$tmpl_inspector_out"
if [[ "$tmpl_inspector_rc" -ne 0 ]]; then echo "$tmpl_inspector_out" >&2; fi

check "template pins the ast-inspector-window class name in source (#330 Option B detached window)" "ast-inspector-window" "$(cat "$NVHTML_INSPECTOR")"
check_absent "template: AST-044's inspector placeholder-restyle note is gone (Option B is the FINAL pick, #330)" "a pending human choice on the issue, not" "$(cat "$NVHTML_INSPECTOR")"

# review round 1 (#330): the window's sizing must use the higher-specificity
# compound selector .note-window.ast-inspector-window, not a bare
# .ast-inspector-window rule -- .note-window{width:var(--colw);max-height:
# 70vh} is an EQUAL-specificity single-class rule declared LATER in source,
# so a bare .ast-inspector-window rule loses that cascade tie regardless of
# what it says (measured: ~19% under the finalized Option B geometry). What
# these two checks CAN prove (pure source-text matching, no CSS engine):
# the compound (higher-specificity, order-independent) selector carries the
# Option B sizing, and that exact declaration is not duplicated/shadowed by
# a second copy of itself elsewhere in the file. What they CANNOT prove: a
# real browser's computed cascade/layout (no CSS parser here), nor that
# some DIFFERENTLY-worded rule with equal-or-higher specificity (a
# different selector matching the same element) doesn't also apply --
# that would need an actual browser or a full CSS specificity calculator.
check "template (review round 1, #330; #460 third pass conforms width to the mockup's own stated 340px): inspector window sizing uses the higher-specificity compound selector .note-window.ast-inspector-window (wins the cascade regardless of source order against .note-window's own later, equal-specificity rule)" ".note-window.ast-inspector-window{width:min(340px,92vw);max-height:80vh}" "$(cat "$NVHTML_INSPECTOR")"
_aiw_sizing_decl_count="$(grep -c 'width:min(340px,92vw);max-height:80vh' "$NVHTML_INSPECTOR")"
if [[ "$_aiw_sizing_decl_count" -eq 1 ]]; then
    echo "ok   template (#460 third pass): the Option B sizing declaration (width:min(340px,92vw);max-height:80vh, conforming to the mockup's stated 340px) appears exactly once -- not duplicated/shadowed by a second copy"
else
    echo "FAIL template (#460 third pass): expected exactly 1 declaration of width:min(340px,92vw);max-height:80vh, found $_aiw_sizing_decl_count"
    fails=$((fails + 1))
fi

check "template pins the ast-metrics class name in source" '"ast-metrics"' "$(cat "$NVHTML_INSPECTOR")"
check "template pins the ast-metrics-row class name in source" '"ast-metrics-row"' "$(cat "$NVHTML_INSPECTOR")"
check "template pins the ast-metrics-graph class name in source" '"ast-metrics-graph"' "$(cat "$NVHTML_INSPECTOR")"
check "template (#460): pins the ast-metrics-block / ast-metrics-blab class names in source (Latency + Per-area side-by-side blocks, matching the mockup's .wtop)" '.ast-metrics-block{' "$(cat "$NVHTML_INSPECTOR")"
check "template (#460): pins the ast-metrics-marker-p50/p95 class names in source (percentile marker lines on the graph)" '.ast-metrics-marker-p50{' "$(cat "$NVHTML_INSPECTOR")"
check "template (#460): pins the ast-metrics-barcol / ast-metrics-barfill class names in source (per-area vertical bar columns, matching the mockup's .barcol/.barfill)" '.ast-metrics-barcol{' "$(cat "$NVHTML_INSPECTOR")"
check "template (#460): pins the aiw-dots class name in source (title-bar dot row from the finalized mockup)" '.aiw-dots{' "$(cat "$NVHTML_INSPECTOR")"
check "template (#460): pins the title-bar strip background (mockup .mB2 .wtitle's own #0d1a2c header, distinct from the window body)" 'background:#0d1a2c' "$(cat "$NVHTML_INSPECTOR")"
check "template (#460): pins the ast-waterfall-turnlab class name in source (turn-context header above the waterfall)" '.ast-waterfall-turnlab{' "$(cat "$NVHTML_INSPECTOR")"
check "template pins the ast-turnlist-row class name in source" '"ast-turnlist-row"' "$(cat "$NVHTML_INSPECTOR")"
check "template pins the ast-waterfall class name in source" '"ast-waterfall"' "$(cat "$NVHTML_INSPECTOR")"
check "template pins the ast-waterfall-error class name in source" "ast-waterfall-error" "$(cat "$NVHTML_INSPECTOR")"
check "template pins the ast-truncated class name in source (#393 truncation marker)" '"ast-truncated"' "$(cat "$NVHTML_INSPECTOR")"
