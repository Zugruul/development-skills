#!/usr/bin/env bash
# section-assistant-voice-turn.sh -- AST-052: voice-driven turn UX
# (SPEC-ASSISTANT.md §13 end-to-end, docs/design/ast-E5.md "Key sequences"
# §3, issue #334). Sourced by run-tests.sh; do not run standalone. Contract:
# the runner already defines set -uo pipefail and has sourced _lib.sh
# (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky before
# sourcing this file. This file assumes those are already in scope.
#
# This task is pure STITCHING (per the design doc's sequence 3): mic
# capture -> STT (AST-051) -> text into the SAME chat call (AST-023) ->
# reply spoken via sequence 1 (AST-050) -> chat overlay mirrors the whole
# exchange. No new engine routes. This section covers the stitching glue
# that section-assistant-stt.sh / section-assistant-voice-tts.sh /
# section-assistant-chat.sh don't already own: the mic control itself, the
# overlay-auto-open choice, end-to-end turnId threading, and the
# STT/TTS echo-guard interlock.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant voice-driven turn UX (AST-052: full voice loop, SPEC-ASSISTANT.md §13, issue #334) =="

NVHTML_VT="$PLUGIN/templates/neural-view.html"
NVHTML_VT_BODY="$(cat "$NVHTML_VT")"

echo "-- template: a dedicated mic control sits near the IN/OUT bars, distinct from #voice-mic's mode toggle --"
check "voice-stt mic control exists in the voicebar header" 'id="voice-stt"' "$NVHTML_VT_BODY"
check "voice-stt starts unpressed" 'id="voice-stt" aria-pressed="false"' "$NVHTML_VT_BODY"
check "voice-stt sits in the same iconbtn/house style as the other voice buttons" 'class="iconbtn" id="voice-stt"' "$NVHTML_VT_BODY"

echo "-- template: §17.9 gate -- voice-stt joins the same gated set the other voice buttons already disable through --"
check "gateVoiceAndChat disables voice-stt alongside voice-mic/in/out/both" 'for(const id of ["voice-mic","voice-in","voice-out","voice-both","voice-stt"]){' "$NVHTML_VT_BODY"
check "voice-stt is disabled+reasoned when gated (title explains why)" "Voice is gated -- no assistant selected" "$NVHTML_VT_BODY"

echo "-- template: mic control wiring -- press to start/stop via the configured sttEngine --"
check "toggleSttListening() exists" "function toggleSttListening(){" "$NVHTML_VT_BODY"
check "toggleSttListening mints a fresh turn id per press" "const started = startStt(newClientTurnId());" "$NVHTML_VT_BODY"
check "setSttListening() drives the visible listening state" "function setSttListening(on){" "$NVHTML_VT_BODY"
check "voice-stt click wires to toggleSttListening" 'document.getElementById("voice-stt").onclick = ()=>{ toggleSttListening(); };' "$NVHTML_VT_BODY"

echo "-- template: IN bar wiring -- voice-stt drives the SAME real mic capture path Space-held press-to-speak uses --"
check "toggleSttListening sets window.voicePTT on start" "window.voicePTT = true;" "$NVHTML_VT_BODY"
check "toggleSttListening widens direction to both when it was out-only, so the IN bar is actually visible" 'uiState.vdir = "both"; saveUiState(); applyVoiceState();' "$NVHTML_VT_BODY"
check "toggleSttListening restores the user's chosen direction on stop" "uiState.vdir = window.__sttPrevVdir; window.__sttPrevVdir = null;" "$NVHTML_VT_BODY"

echo "-- template: #334 review round 2 (MAJOR 2) -- ONE teardown function, called from all four stop paths, releases voicePTT + restores voice direction alongside the visible listening flag (each check below is a single unique line -- no multi-line grep -F patterns, which OR their lines instead of requiring the whole block) --"
check "releaseSttCapture() exists as the shared teardown" "function releaseSttCapture(){" "$NVHTML_VT_BODY"
check "onSttText's auto-stop (the COMMON path) calls it, not just setSttListening(false) -- pinned via its adjacent unique comment, since the bare call line's indentation alone isn't unique enough to distinguish from the other three sites" "COMMON stop path, so it's the one most likely to leave voicePTT/vdir" "$NVHTML_VT_BODY"
check "startStt's engine-error path calls it too (6-space indent inside the engine.start() error callback -- the only call site nested that deep, so this exact line is unique)" "      releaseSttCapture();" "$NVHTML_VT_BODY"

echo "-- template: final transcript -> the SAME send path as typed chat, tagged voice --"
check "onSttText forwards into queueOrSendChat tagged voice, carrying the turn id" 'queueOrSendChat(text, turnId, "voice");' "$NVHTML_VT_BODY"
check "queueOrSendChat accepts turnId/source, defaulting source to typed" 'async function queueOrSendChat(text, turnId, source){' "$NVHTML_VT_BODY"

echo "-- template: overlay-sync -- a voice turn auto-opens the chat overlay if it's closed (AC: overlay mirrors the exchange even without T) --"
# #334 review round 2 (MAJOR 1): openChatOverlay() is now AWAITED here, not
# fire-and-forget -- closing the race where its own awaited loadChatHistory()
# (log.innerHTML = "" + a wholesale exchanges replace) could run AFTER
# dispatchNextChat had already appended the user's row, wiping it or
# silently discarding the completed exchange once the reply resolved.
check "queueOrSendChat auto-opens the overlay for a voice-sourced send when it's closed, AWAITING it before push/dispatch (closes the history-load race)" 'if(src === "voice" && !document.getElementById("ast-chat-overlay")) await openChatOverlay();' "$NVHTML_VT_BODY"

echo "-- template: reply turnId reuse -- dispatchNextChat threads the turn's own id into speakReply instead of always minting a fresh one --"
check "dispatchNextChat destructures {text, turnId} off the queue item" "const {text, turnId} = item;" "$NVHTML_VT_BODY"
check "dispatchNextChat reuses turnId for the reply, falling back to a fresh id for typed sends" "speakReply(payload.text, turnId || newClientTurnId());" "$NVHTML_VT_BODY"

echo "-- template: STT/TTS echo-guard interlock -- recognition pauses when a reply is about to speak --"
# #334 review round 2 (MAJOR 2): the interlock now calls releaseSttCapture()
# (not just setSttListening(false)) -- it must also release voicePTT and
# restore the voice direction, same as the other three stop paths.
check "speakReply pauses STT (stops recognition, releases the full capture state) if it's still listening when a reply starts" "if(window.__sttListening){ stopStt(); releaseSttCapture(); }" "$NVHTML_VT_BODY"

echo "-- template: span correlation -- startStt uses a passed turnId as the span id, joining window.assistantVoiceSpans --"
check "startStt(turnId) uses the turnId as the span id (same trick speakReply already applies)" "const spanId = window.__sttSpanId = turnId || Math.random().toString(36).slice(2);" "$NVHTML_VT_BODY"
check "startStt tracks stt-start locally, turn_id-tagged, joining the SAME array TTS spans use" 'trackLocalVoiceSpan("stt-start", spanId, {engine: engineName});' "$NVHTML_VT_BODY"
check "stopStt tracks stt-end locally, turn_id-tagged" 'trackLocalVoiceSpan("stt-end", window.__sttSpanId, {status: "ok"});' "$NVHTML_VT_BODY"

# NOTE: no NV_VERSION bump pin here -- #441 (already on main by the time this
# branch rebased) removed the NV_VERSION manual-bump convention entirely;
# section-neural-view-template.sh's single "NV_VERSION is gone entirely"
# guard covers every branch going forward, this one included.

echo "-- template behavior: extract() + eval() against a stubbed DOM/fetch/SpeechRecognition -- full voice-turn loop, hardened stubs (#431 lesson: mirror the real contract, nothing invented/omitted) --"
_avt_node="$(mktemp).cjs"
cat >"$_avt_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

// DOM stub -- same shape as section-assistant-chat.sh's (real Array-backed
// `.children` via a Proxy that forwards reads but throws on external
// mutation, the exact contract appendChild/innerHTML= rely on).
const elements = {};
function mkEl(initialId) {
    const el = {
        _id: initialId,
        _classes: new Set(),
        classList: {
            add(c){ this._parent._classes.add(c); },
            remove(c){ this._parent._classes.delete(c); },
            contains(c){ return this._parent._classes.has(c); },
            toggle(c, on){ if (on === undefined) on = !this.contains(c); if (on) this.add(c); else this.remove(c); return on; },
        },
        disabled: false,
        title: "",
        textContent: "",
        value: "",
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
        remove(){ if (this._id && elements[this._id] === this) delete elements[this._id]; },
        get className(){ return [...this._classes].join(" "); },
        set className(v){ this._classes = new Set(v.split(" ").filter(Boolean)); },
        setAttribute(k, v){ this[k === "class" ? "className" : k] = v; this["_attr_" + k] = String(v); },
        getAttribute(k){ return this["_attr_" + k] !== undefined ? this["_attr_" + k] : null; },
    };
    el.classList._parent = el;
    if (initialId) elements[initialId] = el;
    return el;
}
for (const id of ["voice-stt"]) mkEl(id);
const bodyEl = mkEl(null);
global.document = {
    body: bodyEl,
    getElementById(id) { return elements[id] || null; },
    createElement(_tag) { return mkEl(null); },
};
global.window = global;

let store = {};
global.localStorage = {
    getItem(k){ return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
    setItem(k, v){ store[k] = String(v); },
    removeItem(k){ delete store[k]; },
};
global.uiState = {};
function saveUiState(){ try{ localStorage.setItem("nv-ui", JSON.stringify(uiState)); }catch{} }

let fetchCalls = [];
global.fetch = async (url, opts) => {
    fetchCalls.push({ url, opts });
    if (url === "/assistant/status") return { status: 200, json: async () => ({ outcome: "one", candidates: [{name:"jarvis", aliases:[], root:"/r"}], selected: "jarvis", gated: false, askAgain: false }) };
    if (url.indexOf("/assistant/history") === 0) return { status: 200, json: async () => ({ exchanges: [], warnings: [] }) };
    return { ok: true, status: 200, json: async () => ({ ok: true }) };
};

(async () => {
// ---- §17.9 gate: disabled+reasoned ----
eval(extract("gateVoiceAndChat"));
gateVoiceAndChat(true);
if (elements["voice-stt"].disabled !== true) throw new Error("voice-stt must be disabled while gated");
if (elements["voice-stt"].title.toLowerCase().indexOf("gated") === -1) throw new Error("voice-stt's title must explain the gate reason when gated, got " + JSON.stringify(elements["voice-stt"].title));
gateVoiceAndChat(false);
if (elements["voice-stt"].disabled !== false) throw new Error("voice-stt must be enabled when not gated");
if (elements["voice-stt"].title.toLowerCase().indexOf("press to speak") === -1) throw new Error("voice-stt's title reverts to the normal hint when not gated, got " + JSON.stringify(elements["voice-stt"].title));
console.log("GATE_REASONED_OK true");

// ---- mic control: press starts listening via the configured sttEngine, wires the IN-bar capture path, press again stops early ----
window.assistantGate = { gated: false };
window.assistantVoiceSpans = [];
let queuedChatCalls = [];
global.queueOrSendChat = (text, turnId, source) => { queuedChatCalls.push({text, turnId, source}); };
eval(extract("emitVoiceSpan"));
eval(extract("trackLocalVoiceSpan"));
eval(extract("newClientTurnId"));
eval(extract("setSttListening"));
eval(extract("onSttText"));
function sttEngineChoice(){ return "web-speech"; }
let startedInstance = null;
global.window.SpeechRecognition = function () {
    startedInstance = this;
    this.start = () => {};
    this.stop = () => {};
};
class WebSpeechSttEngine{
    constructor(){ this.recog = null; }
    start(onResult, onError){
        const Ctor = window.SpeechRecognition || window.webkitSpeechRecognition;
        if (!Ctor) { onError("web-speech-unavailable"); return; }
        const r = this.recog = new Ctor();
        r.onresult = ev=>{ const res = ev.results[ev.results.length-1]; const text = res && res[0] && res[0].transcript; if (text) onResult(text.trim()); };
        r.onerror = ev=>{ onError("web-speech-error: " + ((ev && ev.error) || "unknown")); };
        r.start();
    }
    stop(){ if (this.recog){ this.recog.stop(); this.recog = null; } }
}
global.sttEngines = { "web-speech": new WebSpeechSttEngine() };
eval(extract("startStt"));
eval(extract("stopStt"));
function voiceDir(){ return ["in","out","both"].includes(uiState.vdir) ? uiState.vdir : "out"; }
function applyVoiceState(){}
// #334 review round 2 (MAJOR 2): the ONE teardown function all four stop
// paths (manual toggle, onSttText auto-stop, startStt's error path,
// speakReply's interlock) now call to release voicePTT/vdir together with
// the visible listening flag -- extracted before toggleSttListening (and
// before onSttText, eval'd above) since both call it.
eval(extract("releaseSttCapture"));
eval(extract("toggleSttListening"));

uiState.vdir = "out"; // the default -- OUT-only hides the IN bar by design
window.voicePTT = false;
toggleSttListening();
if (window.__sttListening !== true) throw new Error("toggleSttListening() must flip to listening on the first press");
if (elements["voice-stt"].classList.contains("listening") !== true) throw new Error("voice-stt must show the visible listening state");
if (window.voicePTT !== true) throw new Error("toggleSttListening must engage window.voicePTT -- the SAME real capture path Space-held press-to-speak drives (micHot() -> syncMic())");
if (uiState.vdir !== "both") throw new Error("an OUT-only direction must widen to both while listening, so the IN bar is actually visible, got " + uiState.vdir);
console.log("MIC_STARTS_AND_WIRES_IN_BAR_OK true");

const mintedTurnId = window.__sttSpanId;
if (!mintedTurnId) throw new Error("starting via the mic control must mint and record a turn id");

// ---- final transcript: auto-stop-on-final, forwards into queueOrSendChat tagged voice with the SAME turn id, restores direction ----
startedInstance.onresult({ results: [[{ transcript: "hello assistant " }]] });
if (queuedChatCalls.length !== 1) throw new Error("a final transcript must forward exactly once into queueOrSendChat, got " + queuedChatCalls.length);
if (queuedChatCalls[0].text !== "hello assistant") throw new Error("expected the trimmed transcript, got " + JSON.stringify(queuedChatCalls[0].text));
if (queuedChatCalls[0].source !== "voice") throw new Error("a voice-driven turn must tag source 'voice' so the overlay/turn pipeline knows its origin");
if (queuedChatCalls[0].turnId !== mintedTurnId) throw new Error("the transcript's turnId must be the SAME id startStt minted, got " + queuedChatCalls[0].turnId + " vs " + mintedTurnId);
console.log("FINAL_TRANSCRIPT_ROUTES_WITH_TURN_ID_OK true");

if (window.__sttListening !== false) throw new Error("onSttText must auto-stop listening on a final result (mic control's 'press again OR auto-on-final' contract)");
if (elements["voice-stt"].classList.contains("listening") !== false) throw new Error("voice-stt must clear its listening state after auto-stop");
console.log("AUTOSTOP_CLEARS_UI_OK true");

// #334 review round 2 (MAJOR 2): onSttText's auto-stop -- the COMMON stop
// path, not a manual second press -- must release the SAME capture state
// the mic control's start branch set: window.voicePTT (the real
// getUserMedia capture switch) and the widened voice direction, restored
// to what the user had before pressing the mic control. Asserted DIRECTLY
// on the auto-stop path itself (this used to only be exercised via a
// manual re-arm+press-again workaround below, which could never have
// caught this regression -- auto-stop only called setSttListening(false),
// leaving the mic capture hot with the listening dot off and the user's
// direction preference silently changed).
if (uiState.vdir !== "out") throw new Error("onSttText's auto-stop must restore the user's original voice direction, got " + uiState.vdir);
if (window.voicePTT !== false) throw new Error("onSttText's auto-stop must release window.voicePTT -- leaving it true keeps the real mic capture hot with the listening dot off");
console.log("AUTOSTOP_RESTORES_CAPTURE_STATE_OK true");

// ---- a manual second press (re-armed) also stops early and restores direction, same teardown, different trigger ----
toggleSttListening(); // re-arm
toggleSttListening(); // press again to stop early
if (uiState.vdir !== "out") throw new Error("stopping via a second press must restore the user's original direction, got " + uiState.vdir);
if (window.voicePTT !== false) throw new Error("stopping must release window.voicePTT");
console.log("STOP_RESTORES_DIRECTION_OK true");
delete global.window.SpeechRecognition;

// ---- span correlation: stt-start/stt-end for this turn joined window.assistantVoiceSpans under the SAME turn_id ----
const localStart = window.assistantVoiceSpans.find(e => e.kind === "stt-start" && e.turn_id === mintedTurnId);
const localEnd = window.assistantVoiceSpans.find(e => e.kind === "stt-end" && e.turn_id === mintedTurnId);
if (!localStart || !localEnd) throw new Error("both stt-start and stt-end must join window.assistantVoiceSpans tagged with the turn's id");
console.log("SPAN_CORRELATION_LOCAL_OK true");

console.log("ALL_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_vt_out="$(node "$_avt_node" "$NVHTML_VT" 2>&1)"
tmpl_vt_rc=$?
rm -f "$_avt_node"
check_rc "voice-turn template script exits 0" 0 "$tmpl_vt_rc"
check "voice-stt is disabled+reasoned when gated, re-enabled with the normal hint when not" "GATE_REASONED_OK true" "$tmpl_vt_out"
check "the mic control starts listening and wires the real IN-bar capture path" "MIC_STARTS_AND_WIRES_IN_BAR_OK true" "$tmpl_vt_out"
check "a final transcript routes into queueOrSendChat tagged voice, carrying the SAME turn id startStt minted" "FINAL_TRANSCRIPT_ROUTES_WITH_TURN_ID_OK true" "$tmpl_vt_out"
check "onSttText auto-stops listening and clears the visible UI state" "AUTOSTOP_CLEARS_UI_OK true" "$tmpl_vt_out"
check "onSttText's auto-stop (the common path) releases voicePTT and restores the prior voice direction, not just a manual second press" "AUTOSTOP_RESTORES_CAPTURE_STATE_OK true" "$tmpl_vt_out"
check "a manual second press stops early and restores the prior voice direction" "STOP_RESTORES_DIRECTION_OK true" "$tmpl_vt_out"
check "stt-start/stt-end join window.assistantVoiceSpans under the turn's shared id" "SPAN_CORRELATION_LOCAL_OK true" "$tmpl_vt_out"
check "the whole voice-turn template script completes" "ALL_OK true" "$tmpl_vt_out"
if [[ "$tmpl_vt_rc" -ne 0 ]]; then echo "$tmpl_vt_out" >&2; fi

echo "-- template behavior: full turn -- queueOrSendChat(voice) auto-opens a closed overlay and mirrors the exchange; the reply reuses the turn's id for speakReply (echo-guard interlock too) --"
_avt2_node="$(mktemp).cjs"
cat >"$_avt2_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

const elements = {};
function mkEl(initialId) {
    const el = {
        _id: initialId,
        _classes: new Set(),
        classList: {
            add(c){ this._parent._classes.add(c); },
            remove(c){ this._parent._classes.delete(c); },
            contains(c){ return this._parent._classes.has(c); },
        },
        disabled: false,
        title: "",
        textContent: "",
        value: "",
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
        remove(){ if (this._id && elements[this._id] === this) delete elements[this._id]; },
        get className(){ return [...this._classes].join(" "); },
        set className(v){ this._classes = new Set(v.split(" ").filter(Boolean)); },
        setAttribute(k, v){ this[k === "class" ? "className" : k] = v; this["_attr_" + k] = String(v); },
        getAttribute(k){ return this["_attr_" + k] !== undefined ? this["_attr_" + k] : null; },
    };
    el.classList._parent = el;
    if (initialId) elements[initialId] = el;
    return el;
}
const bodyEl = mkEl(null);
global.document = {
    body: bodyEl,
    getElementById(id) { return elements[id] || null; },
    createElement(_tag) { return mkEl(null); },
};
global.window = global;

let uiState = {};
window.assistantGate = { gated: false };
let neuralSpeakCalls = [];
window.neuralVoice = { speakChunks(chunks, onDone){ neuralSpeakCalls.push({chunks, onDone}); } };

let fetchCalls = [];
let pendingChat = [];
global.fetch = async (url, opts) => {
    fetchCalls.push({url, opts});
    if (url === "/assistant/status") return { status: 200, json: async () => ({ outcome: "one", candidates: [{name:"jarvis", aliases:[], root:"/r"}], selected: "jarvis", gated: false, askAgain: false }) };
    if (url.indexOf("/assistant/history") === 0) return { status: 200, json: async () => ({ exchanges: [], warnings: [] }) };
    if (url === "/assistant/chat") return new Promise((resolve) => { pendingChat.push({url, opts, resolve}); });
    return { status: 200, json: async () => ({}) };
};
function resolveChat(i, status, payload) { pendingChat[i].resolve({ status, json: async () => payload }); }
async function flush() { for (let i = 0; i < 6; i++) await new Promise(r => setImmediate(r)); }

eval(extract("chatElapsedText"));
eval(extract("isChatTypingTarget"));
eval(extract("appendChatRow"));
eval(extract("renderChatLog"));
eval(extract("renderChatLastXToggle"));
eval(extract("setChatLastX"));
eval(extract("buildChatOverlay"));
eval(extract("renderChatGated"));
eval(extract("renderChatOffline"));
eval(extract("startChatElapsed"));
eval(extract("stopChatElapsed"));
eval(extract("voiceDir"));
eval(extract("voiceOn"));
eval(extract("chunkSpeechText"));
eval(extract("emitVoiceSpan"));
eval(extract("trackLocalVoiceSpan"));
eval(extract("newClientTurnId"));
eval(extract("setSttListening"));
// #334 review round 2 (MAJOR 2): speakReply's echo-guard interlock now
// calls releaseSttCapture() (not just setSttListening(false)) -- extracted
// here too so the interlock test below doesn't ReferenceError. window.
// __sttPrevVdir stays undefined in this harness (falsy), so its restore
// branch is a no-op here, same as section-assistant-stt.sh's harness.
eval(extract("releaseSttCapture"));
let stopSttCalls = 0;
global.stopStt = () => { stopSttCalls++; };
eval(extract("speakReply"));
eval(extract("dispatchNextChat"));
eval(extract("queueOrSendChat"));
eval(extract("chatInputKeydown"));
eval(extract("loadChatHistory"));
eval(extract("openChatOverlay"));
eval(extract("closeChatOverlay"));

window.assistantChat = { queue: [], inFlight: false, exchanges: [], lastX: 2, elapsedTimer: null, elapsedStart: 0 };
window.assistantVoiceSpans = [];

(async () => {
// ---- overlay-sync: a voice send with the overlay CLOSED must still open it and mirror the exchange ----
// #334 review round 2 (MAJOR 1): queueOrSendChat is now ASYNC and AWAITS
// openChatOverlay() (which awaits loadChatHistory()) before push/dispatch
// -- fixing a race where the fire-and-forget open let dispatchNextChat's
// appendChatRow(user row) run immediately, only for the LATER-resolving
// history load to wipe it (log.innerHTML = "") or silently discard the
// completed exchange (window.assistantChat.exchanges = ...). Awaiting
// here is what a real caller does too (dispatched from an async event
// handler either way).
if (document.getElementById("ast-chat-overlay")) throw new Error("setup: overlay must start closed");
await queueOrSendChat("hello from voice", "shared-turn-1", "voice");
if (!document.getElementById("ast-chat-overlay")) throw new Error("a voice-sourced send with the overlay closed must auto-open it (AC: overlay mirrors the exchange)");
const log = document.getElementById("ast-chat-log");
if (!log || log.children.length !== 1 || log.children[0].getAttribute("data-role") !== "user" || log.children[0].textContent !== "hello from voice") throw new Error("the spoken prompt must render as a normal user row, identical to a typed message");
console.log("OVERLAY_AUTO_OPENS_AND_MIRRORS_USER_OK true");

// ---- reply reuses the turn's id for speakReply -- unifying stt and tts spans under one turn_id ----
const chatCall = fetchCalls.find(c => c.url === "/assistant/chat");
if (!chatCall) throw new Error("the voice-sourced text must dispatch through the SAME /assistant/chat call typed chat uses");
resolveChat(0, 200, {text: "hi, how can I help", chips: [], warnings: []});
await flush();
if (neuralSpeakCalls.length !== 1) throw new Error("the reply must speak via speakReply -> window.neuralVoice.speakChunks");
const ttsSpan = window.assistantVoiceSpans.find(e => e.kind === "tts-start");
if (!ttsSpan || ttsSpan.turn_id !== "shared-turn-1") throw new Error("the reply's tts-start span must carry the SAME turn_id the voice turn started with, got " + (ttsSpan && ttsSpan.turn_id));
console.log("REPLY_REUSES_TURN_ID_OK true");

// #334 review round 2 (MAJOR 1, required): assert overlay contents AFTER
// the reply resolves, not only right after the send -- the user row was
// present either way at send time; it's the two loss modes (the history
// repaint wiping it, or the later exchanges replace discarding the
// completed exchange) that only showed up once the round trip finished.
const logAfterReply = document.getElementById("ast-chat-log");
if (!logAfterReply || logAfterReply.children.length !== 2) throw new Error("the overlay must still show BOTH the user row and the assistant reply once the round trip completes, got " + (logAfterReply ? logAfterReply.children.length : "no log"));
if (logAfterReply.children[0].getAttribute("data-role") !== "user" || logAfterReply.children[0].textContent !== "hello from voice") throw new Error("the user row must survive the full round trip unchanged (loss mode 1: wiped by a racing history repaint)");
if (logAfterReply.children[1].getAttribute("data-role") !== "assistant" || logAfterReply.children[1].textContent !== "hi, how can I help") throw new Error("the assistant reply row must render after the user row");
if (window.assistantChat.exchanges.length !== 1 || window.assistantChat.exchanges[0].user !== "hello from voice") throw new Error("the completed exchange must be recorded, not silently discarded by a racing history load (loss mode 2)");
console.log("OVERLAY_SURVIVES_REPLY_RESOLUTION_OK true");

// ---- echo-guard interlock: recognition pauses if still listening when the reply starts speaking ----
window.assistantChat.exchanges = [];
window.assistantVoiceSpans = [];
neuralSpeakCalls = [];
stopSttCalls = 0;
window.__sttListening = true;
speakReply("another reply", "shared-turn-2");
if (stopSttCalls !== 1) throw new Error("speakReply must pause STT (call stopStt) when a reply starts while recognition is still listening, got " + stopSttCalls + " calls");
if (window.__sttListening !== false) throw new Error("speakReply's interlock must clear the listening flag (setSttListening(false)) after pausing");
if (neuralSpeakCalls.length !== 1) throw new Error("the reply must still speak after the interlock pauses recognition");
console.log("ECHO_GUARD_INTERLOCK_OK true");

// ---- typed chat (no turnId/source args) is entirely unaffected -- backward compatible ----
window.assistantChat = { queue: [], inFlight: false, exchanges: [], lastX: 2, elapsedTimer: null, elapsedStart: 0 };
fetchCalls = []; pendingChat = [];
queueOrSendChat("typed message");
const typedCall = fetchCalls.find(c => c.url === "/assistant/chat");
if (!typedCall || JSON.parse(typedCall.opts.body).message !== "typed message") throw new Error("typed chat (no turnId/source) must still dispatch exactly as before");
console.log("TYPED_CHAT_UNAFFECTED_OK true");
// resolve this dispatch (mirroring every other queueOrSendChat call in this
// harness) -- an unresolved fetch leaves dispatchNextChat's await hanging
// forever, which in turn NEVER calls stopChatElapsed(), which in turn never
// clears the real setInterval startChatElapsed() started -- a live Node
// timer, not a stub, since this harness evals the real implementation. That
// keeps the event loop alive and the process never exits on its own, even
// after every assertion above has already passed and printed.
resolveChat(0, 200, {text: "typed reply", chips: [], warnings: []});
await flush();

console.log("ALL_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_vt2_out="$(node "$_avt2_node" "$NVHTML_VT" 2>&1)"
tmpl_vt2_rc=$?
rm -f "$_avt2_node"
check_rc "voice-turn full-pipeline template script exits 0" 0 "$tmpl_vt2_rc"
check "a voice send with the overlay closed auto-opens it and mirrors the spoken prompt as a normal user row" "OVERLAY_AUTO_OPENS_AND_MIRRORS_USER_OK true" "$tmpl_vt2_out"
check "the reply's tts span reuses the turn's own id -- stt and tts spans correlate under one turn_id" "REPLY_REUSES_TURN_ID_OK true" "$tmpl_vt2_out"
check "the overlay still shows both the user row and the assistant reply after the round trip resolves -- the history-load race is closed, not just avoided at send time" "OVERLAY_SURVIVES_REPLY_RESOLUTION_OK true" "$tmpl_vt2_out"
check "speakReply's echo-guard interlock pauses STT if it's still listening when a reply starts" "ECHO_GUARD_INTERLOCK_OK true" "$tmpl_vt2_out"
check "typed chat (no turnId/source) is unaffected -- fully backward compatible" "TYPED_CHAT_UNAFFECTED_OK true" "$tmpl_vt2_out"
check "the whole voice-turn full-pipeline script completes" "ALL_OK true" "$tmpl_vt2_out"
if [[ "$tmpl_vt2_rc" -ne 0 ]]; then echo "$tmpl_vt2_out" >&2; fi
