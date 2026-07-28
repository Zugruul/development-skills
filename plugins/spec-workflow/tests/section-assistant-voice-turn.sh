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

echo "-- template: #448 -- ONE mic control at top level (voice-stt), #voice-mic's separate mode toggle is gone --"
check "voice-stt mic control exists in the voicebar header" 'id="voice-stt"' "$NVHTML_VT_BODY"
check "voice-stt starts unpressed" 'id="voice-stt" aria-pressed="false"' "$NVHTML_VT_BODY"
check "voice-stt sits in the same iconbtn/house style as the other voice buttons" 'class="iconbtn" id="voice-stt"' "$NVHTML_VT_BODY"
check_absent "#voice-mic no longer exists as a top-level button -- collapsed into voice-stt (#448, human hit it live: two nearly-identical mic buttons)" 'id="voice-mic"' "$NVHTML_VT_BODY"

echo "-- template: §17.9 gate -- voice-stt joins the same gated set the other voice buttons already disable through --"
check "gateVoiceAndChat disables voice-stt alongside in/out/both (#448: voice-mic dropped from this set, it no longer exists)" 'for(const id of ["voice-in","voice-out","voice-both","voice-stt"]){' "$NVHTML_VT_BODY"
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
# #452 (#454 P0 live-bug batch): this pin moved WITH the emission itself --
# stopStt() no longer touches spans at all (see #452's dedicated section
# below); the "ok" terminal span is now emitted from onSttText, only once
# the real outcome (a transcript) is actually known.
check "onSttText tracks the ok stt-end locally, turn_id-tagged, once the outcome is actually known" 'trackLocalVoiceSpan("stt-end", turnId, {status: "ok"});' "$NVHTML_VT_BODY"

echo "-- template: #452 (#454 P0 live-bug batch) -- stopStt() no longer touches spans at all; the terminal span is emitted exactly once, only when the outcome is known --"
check "stopStt()'s function body no longer contains an emitVoiceSpan call -- span emission moved entirely to onSttText/startStt's error path" "function stopStt(){" "$NVHTML_VT_BODY"
_stopStt_body="$(sed -n '/^function stopStt(){/,/^}/p' "$NVHTML_VT")"
check_absent "stopStt()'s own body never calls emitVoiceSpan (verified against JUST its extracted body, not the whole file, since emitVoiceSpan legitimately appears elsewhere)" "emitVoiceSpan(" "$_stopStt_body"
check_absent "stopStt()'s own body never touches window.__sttSpanId either -- it has nothing left to null out" "__sttSpanId" "$_stopStt_body"

echo "-- template: #454 (P0 live-bug batch) -- silence-timeout endpointing, named constant --"
check "STT_WEBSPEECH_SILENCE_MS is a named constant, not a magic number inline" "const STT_WEBSPEECH_SILENCE_MS = 1300;" "$NVHTML_VT_BODY"
check "WebSpeechSttEngine accumulates final segments into a buffer instead of finalizing on the first one" "if(text) this.buffer += (this.buffer ? \" \" : \"\") + text.trim();" "$NVHTML_VT_BODY"
check "a manual stop() flushes the buffered segment immediately rather than losing it" "if(this.silenceTimer) this._finalize();" "$NVHTML_VT_BODY"

echo "-- template: #451 (P0 live-bug batch) -- a failed voice turn must SAY why --"
check "reportSttFailure() exists" "async function reportSttFailure(message){" "$NVHTML_VT_BODY"
check "startStt's engine-error path calls reportSttFailure with the honest message" "reportSttFailure(String(err));" "$NVHTML_VT_BODY"
check "reportSttFailure auto-opens the overlay if it's closed (a pure STT failure never produces text, so queueOrSendChat never gets the chance to)" 'if(!document.getElementById("ast-chat-overlay")) await openChatOverlay();' "$NVHTML_VT_BODY"
check "reportSttFailure reuses the SAME red system-row treatment a failed /assistant/chat reply already gets" 'appendChatRow(log, "system", message, null);' "$NVHTML_VT_BODY"

echo "-- template: #453 (P0 live-bug batch) -- the session's selected assistant threads through into the chat dispatch --"
check "setVoiceHeaderName mirrors the current selection into window.__assistantSelected, the one choke point every selection change already runs through" "window.__assistantSelected = name || null;" "$NVHTML_VT_BODY"
check "dispatchNextChat threads it into the chat POST body's assistant field when known" "if(window.__assistantSelected) chatBody.assistant = window.__assistantSelected;" "$NVHTML_VT_BODY"

echo "-- template: #464 (P0, human hit it live) -- voice input required SHOUTING at normal speaking volume; fixed at the root, not by telling the human to raise a slider --"
# Investigated in the order the report demanded, real cause not guessed:
#   1. two CONCURRENT getUserMedia() captures on the same physical mic --
#      MicSource's own visualizer stream (echoCancellation/noiseSuppression/
#      autoGainControl all explicitly true) opening at the SAME time
#      WhisperSttEngine's own getUserMedia({audio:true})+MediaRecorder
#      capture (or the browser's internal Web Speech capture) is already
#      live -- CONFIRMED as the real cause and fixed in micHot() below.
#   2. the noise-suppression floor slider (vs-gate, default 34) -- verified
#      structurally scoped to MicSource.getBins() alone (the visualizer's
#      bar-height clamp), never read by either STT engine -- pinned below,
#      not a contributor.
#   3. echo-guard ducking (inBins.fill(0)) -- verified keyed strictly on
#      voiceSources.outbound.speaking (TTS playback), never on the user's
#      own speech or the recognition path -- not a contributor.
check "micHot() refuses the visualizer's own capture while STT is actively listening -- the #464 fix itself" "if(window.__sttListening) return false;" "$NVHTML_VT_BODY"
check "MicSource's own getUserMedia call is the ONLY explicit AGC/NS/EC request in the template -- confirms it's the visualizer's private stream, distinct from either STT engine's capture" "{audio:{echoCancellation:true, noiseSuppression:true, autoGainControl:true}}" "$NVHTML_VT_BODY"
# Structural check (item 2, required by #464's brief): the noise floor
# (voiceTune().gate / GATE) must be UNREACHABLE from either STT engine's
# own source -- scoped to just their class bodies, not the whole file,
# since "gate"/"GATE" legitimately appear elsewhere (visualizer, §17.9's
# unrelated assistantGate).
_webSpeechEngine_body="$(sed -n '/^class WebSpeechSttEngine{/,/^}/p' "$NVHTML_VT")"
_whisperEngine_body="$(sed -n '/^class WhisperSttEngine{/,/^}/p' "$NVHTML_VT")"
# #454 review round 2 correction 3: an EMPTY sed extraction would also
# pass the check_absent calls below (nothing to find "voiceTune" in) --
# if either class's signature ever changes, this would silently stop
# checking anything instead of failing loudly. Assert non-empty first.
if [ -z "$_webSpeechEngine_body" ]; then
    echo "FAIL WebSpeechSttEngine extraction is non-empty -- sed range /^class WebSpeechSttEngine{/,/^}/ found nothing in $NVHTML_VT (signature changed?)"
    fails=$((fails + 1))
else
    echo "ok   WebSpeechSttEngine extraction is non-empty"
fi
if [ -z "$_whisperEngine_body" ]; then
    echo "FAIL WhisperSttEngine extraction is non-empty -- sed range /^class WhisperSttEngine{/,/^}/ found nothing in $NVHTML_VT (signature changed?)"
    fails=$((fails + 1))
else
    echo "ok   WhisperSttEngine extraction is non-empty"
fi
check_absent "WebSpeechSttEngine's own body never reads the noise-suppression floor (voiceTune/GATE/vGate) -- the floor cannot gate recognition" "voiceTune" "$_webSpeechEngine_body"
check_absent "WhisperSttEngine's own body never reads the noise-suppression floor (voiceTune/GATE/vGate) -- the floor cannot gate recognition" "voiceTune" "$_whisperEngine_body"

echo "-- template: #448 (P1, human hit it live: \"why are there two buttons?\") -- ONE mic control, not two --"
check_absent "the top-level #voice-mic mode-toggle button markup is gone (aria-label pin, since \"voice-mic\" itself is already checked above)" 'aria-label="Microphone mode: press to speak' "$NVHTML_VT_BODY"
check_absent "the #voice-mic CSS block (.ptt/.always/.talking dot language) is gone -- dead rules for a removed element" '#voice-mic.always .micdot' "$NVHTML_VT_BODY"
check_absent "applyVoiceState() no longer touches a removed #voice-mic element" 'const micBtn = document.getElementById("voice-mic")' "$NVHTML_VT_BODY"
check "the settings panel's Press to speak / Mic always on pair is the ONLY surviving surface for mic mode -- confirmed genuinely redundant with the removed top-level toggle, both write the same uiState.micMode field" 'document.getElementById("vs-mic-ptt").onclick = ()=>{ uiState.micMode = "ptt"; saveUiState(); applyUiState(); };' "$NVHTML_VT_BODY"
check "Space-held press-to-speak still drives the real capture path (window.voicePTT unchanged) -- only the now-homeless .talking visual side effect was dropped, not the underlying mechanism" 'window.voicePTT = true;' "$NVHTML_VT_BODY"

echo "-- template: #449 (P2, human-directed) -- Inspect trigger moved into the settings panel; the detached inspector window itself is untouched (#460 just restyled it) --"
# Scoped extractions (not a multi-line grep -F pattern, which ORs its
# lines instead of requiring the whole block) -- voicebar-head's own
# markup range, and the settings panel's own markup range, checked
# independently so "moved FROM X TO Y" is asserted structurally rather
# than by a single fragile multi-line literal.
_voicebarHead_body="$(sed -n '/<div id="voicebar-head">/,/<div id="voice-viz">/p' "$NVHTML_VT")"
_voiceSettingsPanel_body="$(sed -n '/<div class="hud" id="voice-settings-panel"/,/^<div class="hud" id="rightbar">/p' "$NVHTML_VT")"
check_absent "the Inspect button no longer sits in voicebar-head" 'id="ast-inspect-open"' "$_voicebarHead_body"
check "the Inspect button now lives inside the settings panel as its own vs-row" '<span class="label">Inspector</span>' "$_voiceSettingsPanel_body"
check "the Inspect button itself, scoped to inside the settings panel now" 'id="ast-inspect-open"' "$_voiceSettingsPanel_body"
check "the Inspect button's identity (id, title, aria-label, aria-haspopup) is unchanged by the #449 move" 'id="ast-inspect-open" title="Open the metrics/trace inspector" aria-label="Open the metrics/trace inspector" aria-haspopup="true"' "$NVHTML_VT_BODY"
check "the click handler still targets the SAME function -- the detached window/open-close/one-window-max/Esc handshake is untouched by this move" 'document.getElementById("ast-inspect-open").onclick = () => { openAstInspectorWindow(); };' "$NVHTML_VT_BODY"

echo "-- template: #466 -- Inspect restyled to the mockup's .minivoice .inspect pill (AST-044-r1 Option B), not a plain .iconbtn --"
check "Inspect carries the new pill class, ported from this app's OWN .iconbtn.active look (near-identical cyan values to the mockup's pill) rather than invented values" 'class="iconbtn ast-inspect-pill" id="ast-inspect-open"' "$NVHTML_VT_BODY"
check "the pill class gives it a permanent (not state-toggled) cyan border/background/color treatment" '.ast-inspect-pill{color:var(--cyan);border-color:var(--cyan-dim);background:rgba(70,230,255,.08)}' "$NVHTML_VT_BODY"
check "the button carries the mockup's chevron, same label idiom -- Inspect with a trailing chevron" 'aria-haspopup="true">Inspect ▸</button>' "$NVHTML_VT_BODY"

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
// #454 (P0 live-bug batch): pulled in from section-assistant-stt.sh's
// harness -- needed here too so this file can eval the REAL
// WebSpeechSttEngine class (with its now-real endpointing) instead of a
// hand-rolled stub that predates the fix and would never exercise it (the
// #431 lesson this file's own header already cites: mirror the real
// contract, nothing invented/omitted).
function extractClass(name) {
    const re = new RegExp("class " + name + "\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find class " + name + " in template");
    return m[0];
}
function extractConst(name) {
    const re = new RegExp("const " + name + " = [^\\n]*\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find const " + name + " in template");
    return m[0];
}
function defineClass(name) {
    global[name] = eval("(" + extractClass(name).trim() + ")");
}
function defineConst(name) {
    const src = extractConst(name).trim().replace(/^const\s+\S+\s*=\s*/, "").replace(/;$/, "");
    global[name] = eval("(" + src + ")");
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
// #454 review round 2 MAJOR regression test: startStt's engine-error path
// calls reportSttFailure(...), which this harness does not eval (it lives
// in section-assistant-voice-turn.sh's SECOND harness, below) -- stubbed
// here the same way queueOrSendChat is, so the onerror path under test can
// actually run instead of ReferenceError-ing on a function this harness
// never defined.
let reportSttFailureCalls = [];
global.reportSttFailure = async (message) => { reportSttFailureCalls.push(message); };
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
// #454 (P0 live-bug batch): the REAL WebSpeechSttEngine class, not a
// hand-rolled stub -- so this "same journey" harness actually exercises
// the real silence-timeout endpointing, not a pre-fix stand-in that would
// never catch a regression here. setTimeout/clearTimeout are stubbed the
// same deterministic way section-assistant-stt.sh's harness drives them.
let scheduledTimers = new Map();
let nextTimerId = 1;
global.setTimeout = (fn, ms) => { const id = nextTimerId++; scheduledTimers.set(id, {fn, ms}); return id; };
global.clearTimeout = (id) => { scheduledTimers.delete(id); };
function fireLatestTimer(){
    const ids = [...scheduledTimers.keys()];
    if (!ids.length) throw new Error("fireLatestTimer: no timer scheduled");
    const id = ids[ids.length - 1];
    const entry = scheduledTimers.get(id);
    scheduledTimers.delete(id);
    entry.fn();
}
defineConst("STT_WEBSPEECH_SILENCE_MS");
defineClass("WebSpeechSttEngine");
global.sttEngines = { "web-speech": new WebSpeechSttEngine() };
eval(extract("startStt"));
eval(extract("stopStt"));
function voiceDir(){ return ["in","out","both"].includes(uiState.vdir) ? uiState.vdir : "out"; }
function applyVoiceState(){}
// #464: the real micHot(), not a hand-rolled stand-in -- this harness
// already tracks everything it reads (uiState.micMode, window.voicePTT,
// window.__sttListening via setSttListening, and voiceDir() above).
eval(extract("micHot"));
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

// ---- #464 (P0, human hit it live): micHot() must refuse the visualizer's
// own competing getUserMedia capture while STT is actively listening,
// even though voicePTT is true and vdir is "both" -- exactly the state
// this test is in right now. Before the fix, this returned true here,
// meaning the visualizer's independent capture WAS opening concurrently
// with STT's own capture on the same physical mic -- the root cause of
// "voice input requires shouting".
if (micHot() !== false) throw new Error("micHot() must return false while STT owns the mic (window.__sttListening), even with voicePTT/vdir both indicating the visualizer would otherwise want it -- this is the #464 two-consumers-one-device bug");
console.log("MIC_HOT_REFUSES_DURING_STT_OK true");

const mintedTurnId = window.__sttSpanId;
if (!mintedTurnId) throw new Error("starting via the mic control must mint and record a turn id");

// ---- final transcript: auto-stop-on-final, forwards into queueOrSendChat tagged voice with the SAME turn id, restores direction ----
// #454 (P0 live-bug batch): with the REAL WebSpeechSttEngine now wired in,
// a single final segment schedules the silence timer instead of finalizing
// immediately -- fire it to reach the same "turn actually finalized" point
// this test already asserts on.
startedInstance.onresult({ results: [[{ transcript: "hello assistant " }]] });
fireLatestTimer();
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
const noSpeechTurnId = window.__sttSpanId;
toggleSttListening(); // press again to stop early -- crucially, WITHOUT ever speaking (no onresult fired in between)
if (uiState.vdir !== "out") throw new Error("stopping via a second press must restore the user's original direction, got " + uiState.vdir);
if (window.voicePTT !== false) throw new Error("stopping must release window.voicePTT");
console.log("STOP_RESTORES_DIRECTION_OK true");

// #454 review round 2 MINOR 1: a turn started then manually stopped with
// NO speech ever captured used to leave its stt-start span permanently
// open -- neither onSttText's success emission nor startStt's error
// callback ever ran, so window.__sttSpanId (and the span itself) just
// hung forever, a null-duration open span same as the onerror bug above
// degraded the inspector. "cancelled without speaking" is a known,
// honest outcome; assert it is emitted, not left dangling.
const noSpeechEnd = window.assistantVoiceSpans.find(e => e.kind === "stt-end" && e.turn_id === noSpeechTurnId);
if (!noSpeechEnd) throw new Error("a turn manually stopped with no speech must still get a terminal stt-end span, not be left permanently open");
if (noSpeechEnd.status !== "no-speech") throw new Error("expected an honest no-speech status, got " + JSON.stringify(noSpeechEnd.status));
if (window.__sttSpanId !== null) throw new Error("window.__sttSpanId must be cleared once the no-speech terminal span is emitted, got " + window.__sttSpanId);
console.log("NO_SPEECH_STOP_EMITS_TERMINAL_SPAN_OK true");

// ---- #454 review round 2 MAJOR: an error mid-turn must not leave the
// silence timer armed. The reported bug shape: a segment is already
// buffered (the human said "Are you there?"), the browser then fires
// onerror (permission revoked mid-listen, a network hiccup, whatever) --
// the OLD onerror handler only forwarded the error message and never
// touched silenceTimer/buffer, so the timer armed by the earlier onresult
// was still live and fired ~1.3s later anyway, pushing the half-sentence
// through onResult -> onSttText -> queueOrSendChat. The human would see
// the honest red error row, then get answered for a stray partial
// utterance a moment later. Drives the REAL WebSpeechSttEngine (same
// reason the rest of this harness does): fire a segment, fire onerror,
// then try to advance past the silence window -- there must be nothing
// left to advance, and nothing must reach queueOrSendChat either.
toggleSttListening(); // start a fresh turn
queuedChatCalls = [];
startedInstance.onresult({ results: [[{ transcript: "Are you" }]] });
startedInstance.onerror({ error: "network" });
if (scheduledTimers.size !== 0) throw new Error("onerror must clear the armed silence timer, found " + scheduledTimers.size + " still scheduled -- the stale-timer-fires-after-error bug");
if (queuedChatCalls.length !== 0) throw new Error("no buffered segment may reach queueOrSendChat once the turn has errored, got " + queuedChatCalls.length + " call(s)");
if (reportSttFailureCalls.length !== 1) throw new Error("the error must still surface honestly via reportSttFailure, got " + reportSttFailureCalls.length + " call(s)");
console.log("ONERROR_CLEARS_ARMED_TIMER_OK true");
// stop the now-errored turn's listening state so it does not bleed into
// span-correlation assertions below, which key off the EARLIER turn's id.
if (window.__sttListening) toggleSttListening();
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
check "#464 (P0, human hit it live): micHot() refuses the visualizer's own competing capture while STT actively owns the mic" "MIC_HOT_REFUSES_DURING_STT_OK true" "$tmpl_vt_out"
check "a final transcript routes into queueOrSendChat tagged voice, carrying the SAME turn id startStt minted" "FINAL_TRANSCRIPT_ROUTES_WITH_TURN_ID_OK true" "$tmpl_vt_out"
check "onSttText auto-stops listening and clears the visible UI state" "AUTOSTOP_CLEARS_UI_OK true" "$tmpl_vt_out"
check "onSttText's auto-stop (the common path) releases voicePTT and restores the prior voice direction, not just a manual second press" "AUTOSTOP_RESTORES_CAPTURE_STATE_OK true" "$tmpl_vt_out"
check "a manual second press stops early and restores the prior voice direction" "STOP_RESTORES_DIRECTION_OK true" "$tmpl_vt_out"
check "#454 review round 2 MINOR 1: a turn manually stopped with no speech still gets an honest terminal stt-end span instead of hanging open" "NO_SPEECH_STOP_EMITS_TERMINAL_SPAN_OK true" "$tmpl_vt_out"
check "#454 review round 2 MAJOR: onerror clears the armed silence timer instead of letting a buffered segment fire late into queueOrSendChat" "ONERROR_CLEARS_ARMED_TIMER_OK true" "$tmpl_vt_out"
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
// AST-083 (#459): chatInputKeydown now calls the shared sendChatInput()
// dispatch -- extract it first (same fix as section-assistant-chat.sh's
// harness).
eval(extract("sendChatInput"));
eval(extract("chatInputKeydown"));
eval(extract("loadChatHistory"));
eval(extract("openChatOverlay"));
eval(extract("closeChatOverlay"));
eval(extract("reportSttFailure"));

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

// #451 (#454 P0 live-bug batch): a failed voice turn must SAY why. This is
// the exact reported scenario -- the human pressed the mic twice with
// NOTHING ever reaching the chat overlay, because a pure STT failure
// never produces a transcript, so it never reaches queueOrSendChat (the
// only OTHER auto-open trigger). Start from a closed overlay (mirroring
// what the human actually saw) and drive reportSttFailure() the same way
// startStt's engine-error callback does.
if (elements["ast-chat-overlay"]) elements["ast-chat-overlay"].remove();
delete elements["ast-chat-overlay"]; delete elements["ast-chat-log"];
if (document.getElementById("ast-chat-overlay")) throw new Error("setup: overlay must start closed for the STT-failure test");
await reportSttFailure("web-speech-unavailable: this browser has no SpeechRecognition support -- switch to whisper.cpp (if the sidecar is installed) or use a browser that supports Web Speech.");
if (!document.getElementById("ast-chat-overlay")) throw new Error("a pure STT failure (no transcript ever produced) must still auto-open the overlay -- otherwise the human sees nothing at all, the exact #451 bug");
const failLog = document.getElementById("ast-chat-log");
if (!failLog || failLog.children.length !== 1) throw new Error("expected exactly one row rendering the failure, got " + (failLog ? failLog.children.length : "no log"));
const failRow = failLog.children[0];
if (failRow.getAttribute("data-role") !== "system") throw new Error("an STT failure must render with the SAME 'system' role a failed /assistant/chat reply already gets (the red-row treatment), got " + failRow.getAttribute("data-role"));
if (failRow.textContent.indexOf("web-speech-unavailable") === -1) throw new Error("the row must show the actual honest engine message, not a generic one, got " + JSON.stringify(failRow.textContent));
console.log("STT_FAILURE_SURFACES_IN_OVERLAY_OK true");

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
check "#451 (P0 live-bug batch): a pure STT failure (no transcript ever produced) auto-opens the overlay and renders the honest message as a red system row -- the human's silent-failure bug" "STT_FAILURE_SURFACES_IN_OVERLAY_OK true" "$tmpl_vt2_out"
check "the whole voice-turn full-pipeline script completes" "ALL_OK true" "$tmpl_vt2_out"
if [[ "$tmpl_vt2_rc" -ne 0 ]]; then echo "$tmpl_vt2_out" >&2; fi
