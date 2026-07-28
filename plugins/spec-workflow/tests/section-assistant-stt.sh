#!/usr/bin/env bash
# section-assistant-stt.sh -- AST-051: STT decision spec-delta + implementation
# (SPEC-ASSISTANT.md §13.2/§13.3/§17.9, docs/design/ast-E5.md, issue #333).
# Sourced by run-tests.sh; do not run standalone. Contract: the runner
# already defines set -uo pipefail and has sourced _lib.sh (check/check_rc/
# check_absent) and set HERE/PLUGIN/FIX/fails/flaky before sourcing this
# file. This file assumes those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant STT (AST-051: STT decision + implementation, SPEC-ASSISTANT.md §13.2/§13.3/§17.9, issue #333) =="

NVHTML_STT="$PLUGIN/templates/neural-view.html"
DELTA_STT_ROOT="$(cd "$PLUGIN/../.." && pwd)"
DELTA_STT="$DELTA_STT_ROOT/docs/spec-deltas/ast-051.md"
# Path fix-up (unrelated cross-branch fix-up, discovered while chasing
# sw/332-tts-wiring green post-rebase, not an AST-050 concern): the fold
# step (docs(spec): fold AST-051 + AST-061 deltas into SPEC-ASSISTANT)
# relocates an applied delta to docs/spec-deltas/applied/<name>.md (same
# convention section-kb-seed.sh already checks pending-or-applied for) --
# this test still only looked at the pending path, so it false-failed on
# main once AST-051's delta was folded.
DELTA_STT_APPLIED="$DELTA_STT_ROOT/docs/spec-deltas/applied/ast-051.md"

echo "-- spec delta: exists, registered before implementation, decision wording pinned --"
if [[ -f "$DELTA_STT" ]]; then
    DELTA_STT_BODY="$(cat "$DELTA_STT")"
elif [[ -f "$DELTA_STT_APPLIED" ]]; then
    DELTA_STT_BODY="$(cat "$DELTA_STT_APPLIED")"
else
    DELTA_STT_BODY=""
fi
check "ast-051 spec delta file exists" "sections:" "$DELTA_STT_BODY"
check "delta targets §13.2" "§13.2" "$DELTA_STT_BODY"
check "delta names task 333" "task: '333'" "$DELTA_STT_BODY"
check "delta records BOTH engines are shipped" "BOTH engines" "$DELTA_STT_BODY"
check "delta pins whisper as the DEFAULT" "the DEFAULT" "$DELTA_STT_BODY"
check "delta pins Web Speech as the zero-install alternative" "zero-install" "$DELTA_STT_BODY"
check "delta keeps the engine API text-in/text-out regardless of STT choice" "text-in/text-out regardless of the STT choice" "$DELTA_STT_BODY"
check "delta documents the whisper sidecar's assumed HTTP contract" "POST http://localhost:<sidecar-port>/transcribe" "$DELTA_STT_BODY"
check "delta documents the sidecar success response shape" '{"text": "<transcript>"}' "$DELTA_STT_BODY"
check "delta defers the sidecar capability itself (install/model/process) as follow-up scope" "Deferred (reported to the orchestrator to file as follow-up scope" "$DELTA_STT_BODY"
check "delta ties the deferred sidecar to E6/AST-060/061 provisioning" "AST-060/061" "$DELTA_STT_BODY"
check "delta records the honest-unavailable requirement" "whisper sidecar not available" "$DELTA_STT_BODY"
check "delta records the §17.9 hard gate applies to STT start" "STT cannot start while" "$DELTA_STT_BODY"

echo "-- template: settings panel gains an STT engine control, default whisper, persisted --"
NVHTML_STT_BODY="$(cat "$NVHTML_STT")"
check "settings panel: whisper option present" 'id="vs-stt-whisper"' "$NVHTML_STT_BODY"
check "settings panel: web-speech option present" 'id="vs-stt-webspeech"' "$NVHTML_STT_BODY"
check "settings panel: hint names whisper.cpp as local/default" "whisper.cpp is the default" "$NVHTML_STT_BODY"
check "settings panel: hint names Web Speech as needing no install" "needs no install" "$NVHTML_STT_BODY"
check "sttEngineChoice() defaults to whisper when unset" 'function sttEngineChoice(){' "$NVHTML_STT_BODY"
check "setSttEngineChoice persists via saveUiState (same path as the rest of the panel)" "function setSttEngineChoice(choice){" "$NVHTML_STT_BODY"

echo "-- template: STT engine abstraction -- two implementations, honest degrade --"
check "WebSpeechSttEngine class exists" "class WebSpeechSttEngine{" "$NVHTML_STT_BODY"
check "WebSpeechSttEngine degrades honestly when unavailable" "web-speech-unavailable" "$NVHTML_STT_BODY"
check "WhisperSttEngine class exists" "class WhisperSttEngine{" "$NVHTML_STT_BODY"
check "WhisperSttEngine surfaces the honest unavailable-sidecar message" "whisper sidecar not available -- install via the whisper capability" "$NVHTML_STT_BODY"
check "WhisperSttEngine's unavailable message offers the Web Speech alternative" "switch to Web Speech in Settings" "$NVHTML_STT_BODY"
check "sttEngines registry wires both engine names to their implementations" 'const sttEngines = { whisper: new WhisperSttEngine(), "web-speech": new WebSpeechSttEngine() };' "$NVHTML_STT_BODY"

echo "-- template: onSttText hook routes into the existing chat-send path --"
check "onSttText(text, turnId) exists -- AST-052 (#334) threads a turnId through for span correlation" "function onSttText(text, turnId){" "$NVHTML_STT_BODY"
check "onSttText forwards into queueOrSendChat (AST-052's future consumer, chat input today)" "queueOrSendChat(text)" "$NVHTML_STT_BODY"

echo "-- template: §17.9 hard gate -- STT cannot start with no assistant selected --"
check "startStt() checks window.assistantGate.gated before starting either engine" "if(window.assistantGate && window.assistantGate.gated) return false;" "$NVHTML_STT_BODY"

echo "-- template: §13.3 -- stt-start/stt-end spans carry the engine name over the existing trace path --"
check "emitVoiceSpan posts to the voice-event trace bridge" '"/assistant/voice-event"' "$NVHTML_STT_BODY"
check "startStt emits stt-start with the engine name" '"stt-start"' "$NVHTML_STT_BODY"
# #454 review round 2 MINOR 2: this used to read "stopStt emits stt-end
# with the engine name" and pass only because "stt-end" appears ANYWHERE
# in the whole template body (onSttText's and startStt's error-callback's
# own emissions) -- not because stopStt() itself emits anything. That
# directly contradicted #452's fix (below, and section-assistant-voice-
# turn.sh's matching scoped pin): stopStt() emits no span at all now.
# Retargeted to the same scoped-body check_absent that file already
# established, so the two files can no longer assert opposite things.
_stopStt_stt_body="$(sed -n '/^function stopStt(){/,/^}/p' "$NVHTML_STT")"
# #454 review round 2 correction 3: an EMPTY sed extraction would also
# pass the check_absent below (nothing to find "emitVoiceSpan" in) -- if
# stopStt()'s signature ever changes, this would silently stop checking
# anything instead of failing loudly. Assert non-empty first.
if [ -z "$_stopStt_stt_body" ]; then
    echo "FAIL stopStt() extraction is non-empty -- sed range /^function stopStt(){/,/^}/ found nothing in $NVHTML_STT (signature changed?)"
    fails=$((fails + 1))
else
    echo "ok   stopStt() extraction is non-empty"
fi
check_absent "stopStt()'s own body never calls emitVoiceSpan -- span emission moved entirely to onSttText/startStt's error path (#452)" "emitVoiceSpan(" "$_stopStt_stt_body"

echo "-- template behavior: extract() + eval() against a stubbed DOM/fetch/SpeechRecognition (section-assistant-chat.sh's harness style) --"
_ast_node="$(mktemp).cjs"
cat >"$_ast_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
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
// `class`/`const` are lexically scoped: a direct eval() of one at this
// scope does NOT leak a binding out to the surrounding scope the way a
// `function` declaration does (verified -- functions hoist through eval in
// sloppy mode, class/const do not). Force each into an EXPRESSION (wrap in
// parens) and assign the eval'd value onto `global` explicitly instead.
function defineClass(name) {
    global[name] = eval("(" + extractClass(name).trim() + ")");
}
function defineConst(name) {
    const src = extractConst(name).trim().replace(/^const\s+\S+\s*=\s*/, "").replace(/;$/, "");
    // wrap in parens: a bare "{...}" fed to eval() parses as a BLOCK
    // statement (object-literal-vs-block ambiguity), not an expression --
    // parens force expression context the same way defineClass needs them.
    global[name] = eval("(" + src + ")");
}

let store = {};
global.localStorage = {
    getItem(k){ return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null; },
    setItem(k, v){ store[k] = String(v); },
    removeItem(k){ delete store[k]; },
};

const elements = {};
function mkEl(initialId) {
    const el = {
        _id: initialId,
        _classes: new Set(),
        classList: {
            add(c){ this._parent._classes.add(c); },
            remove(c){ this._parent._classes.delete(c); },
            contains(c){ return this._parent._classes.has(c); },
            toggle(c, on){ if (on) this.add(c); else this.remove(c); },
        },
        setAttribute(k, v){ this["_attr_" + k] = String(v); },
        getAttribute(k){ return this["_attr_" + k] !== undefined ? this["_attr_" + k] : null; },
        title: "",
    };
    el.classList._parent = el;
    if (initialId) elements[initialId] = el;
    return el;
}
for (const id of ["vs-stt-whisper", "vs-stt-webspeech"]) mkEl(id);
global.document = {
    getElementById(id) { return elements[id] || null; },
};
global.window = global;

let fetchCalls = [];
global.fetch = async (url, opts) => {
    fetchCalls.push({ url, opts });
    return { ok: true, status: 200, json: async () => ({ ok: true }) };
};

let queuedChatMessages = [];
global.queueOrSendChat = (text) => { queuedChatMessages.push(text); };
// #451 (#454 P0 live-bug batch): stubbed once, up front, since startStt's
// engine-error callback calls this unconditionally on any failure --
// several blocks below (whisper's async-after-stop failure included)
// trigger it well before the dedicated REPORTS_STT_FAILURE_OK test does.
let reportedFailures = [];
global.reportSttFailure = (msg) => { reportedFailures.push(msg); };

(async () => {
// ---- setting: default whisper, toggle persists ----
// saveUiState() itself is a one-liner in the template (not extractable via
// the block-regex above); stub the SAME contract it has -- persist
// uiState to the nv-ui localStorage key -- rather than regex-splice it.
global.uiState = {};
function saveUiState(){ try{ localStorage.setItem("nv-ui", JSON.stringify(uiState)); }catch{} }
eval(extract("sttEngineChoice"));
eval(extract("applySttEngineUi"));
eval(extract("setSttEngineChoice"));

if (sttEngineChoice() !== "whisper") throw new Error("default sttEngineChoice must be whisper, got " + sttEngineChoice());
console.log("DEFAULT_WHISPER_OK true");

setSttEngineChoice("web-speech");
if (sttEngineChoice() !== "web-speech") throw new Error("setSttEngineChoice(web-speech) did not take effect");
if (elements["vs-stt-webspeech"].getAttribute("aria-pressed") !== "true") throw new Error("vs-stt-webspeech should be pressed after selecting web-speech");
if (elements["vs-stt-whisper"].getAttribute("aria-pressed") !== "false") throw new Error("vs-stt-whisper should NOT be pressed after selecting web-speech");
console.log("TOGGLE_APPLIES_OK true");

// persisted like the rest of the panel: reload uiState from localStorage the
// same way the template's own boot sequence does, and the choice must survive
const persisted = JSON.parse(localStorage.getItem("nv-ui") || "{}");
if (persisted.sttEngine !== "web-speech") throw new Error("sttEngine was not persisted to the nv-ui localStorage key");
console.log("PERSIST_OK true");

setSttEngineChoice("whisper");
if (sttEngineChoice() !== "whisper") throw new Error("setSttEngineChoice(whisper) did not take effect");
console.log("SWITCH_BACK_OK true");

// #454 (P0 live-bug batch): WebSpeechSttEngine's silence-timeout
// endpointing uses real setTimeout/clearTimeout -- stub both so the tests
// below drive the timer deterministically (fire it manually) instead of
// waiting real milliseconds.
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

// ---- Web Speech engine: wires recognition events -> onResult, degrades honestly ----
defineClass("WebSpeechSttEngine");
defineConst("STT_WEBSPEECH_SILENCE_MS");
{
    // no SpeechRecognition ctor on this stubbed window at all
    delete global.SpeechRecognition;
    delete global.webkitSpeechRecognition;
    const engine = new WebSpeechSttEngine();
    let gotError = null;
    engine.start(() => { throw new Error("onResult must not fire when unavailable"); }, (err) => { gotError = err; });
    if (!gotError || gotError.indexOf("web-speech-unavailable") === -1) throw new Error("expected an honest web-speech-unavailable error, got " + gotError);
    console.log("WEBSPEECH_DEGRADE_OK true");
}
{
    // #454 (P0 live-bug batch): the browser fires a SEPARATE final
    // `onresult` per natural pause even in continuous mode -- "Are you"
    // <pause> "there" segments into two finals. The old code called
    // onResult() on the FIRST one, truncating the turn. Endpointing fix:
    // accumulate every segment and only finalize once the silence timeout
    // elapses with no new segment.
    let startedInstance = null;
    global.window.SpeechRecognition = function () {
        startedInstance = this;
        this.start = () => {};
        this.stop = () => {};
    };
    const engine = new WebSpeechSttEngine();
    let gotResult = null, resultCalls = 0;
    engine.start((text) => { gotResult = text; resultCalls++; }, () => {});
    startedInstance.onresult({ results: [[{ transcript: "Are you" }]] });
    if (resultCalls !== 0) throw new Error("a single final segment must not finalize the turn immediately -- that is the #454 truncation bug");
    if (scheduledTimers.size !== 1) throw new Error("a final segment must schedule exactly one silence timer, got " + scheduledTimers.size);
    if ([...scheduledTimers.values()][0].ms !== STT_WEBSPEECH_SILENCE_MS) throw new Error("the scheduled delay must be STT_WEBSPEECH_SILENCE_MS, got " + [...scheduledTimers.values()][0].ms);
    // speech resumes before the silence timeout elapses -- must EXTEND, not truncate
    startedInstance.onresult({ results: [[{ transcript: "there" }]] });
    if (resultCalls !== 0) throw new Error("a second segment arriving before the silence timeout must not have finalized yet either");
    if (scheduledTimers.size !== 1) throw new Error("the second segment must reset (not add to) the pending timer, got " + scheduledTimers.size + " pending");
    // the turn actually goes quiet now
    fireLatestTimer();
    if (resultCalls !== 1) throw new Error("the silence timeout must finalize the turn exactly once, got " + resultCalls + " calls");
    if (gotResult !== "Are you there") throw new Error("expected the ACCUMULATED transcript across both segments, got " + JSON.stringify(gotResult));
    console.log("WEBSPEECH_ENDPOINTING_ACCUMULATES_OK true");
    delete global.window.SpeechRecognition;
}
{
    // manual override (press-again): flushes whatever's buffered
    // immediately rather than losing it, then actually stops.
    let startedInstance = null;
    let nativeStopCalls = 0;
    global.window.SpeechRecognition = function () {
        startedInstance = this;
        this.start = () => {};
        this.stop = () => { nativeStopCalls++; };
    };
    const engine = new WebSpeechSttEngine();
    let gotResult = null, resultCalls = 0;
    engine.start((text) => { gotResult = text; resultCalls++; }, () => {});
    startedInstance.onresult({ results: [[{ transcript: "partial" }]] });
    engine.stop(); // manual stop BEFORE the silence timeout fires
    if (resultCalls !== 1) throw new Error("stop() must flush the buffered segment immediately, got " + resultCalls + " calls");
    if (gotResult !== "partial") throw new Error("expected the buffered text to be flushed on manual stop, got " + JSON.stringify(gotResult));
    if (nativeStopCalls !== 1) throw new Error("stop() must still stop the native recognizer, got " + nativeStopCalls + " calls");
    console.log("WEBSPEECH_MANUAL_STOP_FLUSHES_OK true");
    delete global.window.SpeechRecognition;
}
{
    // a manual stop with NOTHING captured yet must never call onResult
    // with empty text.
    global.window.SpeechRecognition = function () {
        this.start = () => {};
        this.stop = () => {};
    };
    const engine = new WebSpeechSttEngine();
    let resultCalls = 0;
    engine.start(() => { resultCalls++; }, () => {});
    engine.stop();
    if (resultCalls !== 0) throw new Error("stop() with nothing captured must never call onResult");
    console.log("WEBSPEECH_EMPTY_STOP_NO_RESULT_OK true");
    delete global.window.SpeechRecognition;
}

// ---- whisper engine: honest unavailable-sidecar state when unreachable ----
defineConst("STT_WHISPER_ENDPOINT");
defineConst("STT_WHISPER_UNAVAILABLE_MSG");
defineClass("WhisperSttEngine");
{
    global.navigator = { mediaDevices: { getUserMedia: async () => { throw new Error("denied"); } } };
    const engine = new WhisperSttEngine();
    let gotError = null;
    await engine.start(() => {}, (err) => { gotError = err; });
    if (!gotError || gotError.indexOf("whisper sidecar not available") === -1) throw new Error("expected honest whisper-unavailable message, got " + gotError);
    console.log("WHISPER_DEGRADE_OK true");
}

// ---- §17.9 hard gate + span emission ----
// AST-052 (#334): startStt/stopStt now also call trackLocalVoiceSpan
// (span-correlation, same client-local array TTS spans already join) and
// setSttListening (the mic control's visible state) -- both extracted
// here too so this harness's eval'd startStt/stopStt/onSttText don't
// ReferenceError; window.assistantVoiceSpans starts empty like the real
// boot sequence's. releaseSttCapture (review round 2): onSttText's auto-
// stop and startStt's error path both call it now -- global.uiState/
// saveUiState below already exist for it; window.__sttPrevVdir stays
// undefined in this harness (falsy), so its restore branch simply never
// fires here, same as a turn that never widened the direction.
window.assistantVoiceSpans = [];
eval(extract("onSttText"));
eval(extract("emitVoiceSpan"));
eval(extract("trackLocalVoiceSpan"));
eval(extract("setSttListening"));
eval(extract("releaseSttCapture"));
defineConst("sttEngines");
eval(extract("startStt"));
eval(extract("stopStt"));

global.window.assistantGate = { gated: true };
const startedWhileGated = startStt();
if (startedWhileGated !== false) throw new Error("startStt() must refuse to start while gated");
if (fetchCalls.some(c => c.url === "/assistant/voice-event")) throw new Error("a gated startStt() must never emit a voice-event span");
console.log("GATE_BLOCKS_START_OK true");

global.window.assistantGate = { gated: false };
setSttEngineChoice("web-speech");
global.window.SpeechRecognition = function () { this.start = () => {}; this.stop = () => {}; };
const startedUngated = startStt();
if (startedUngated !== true) throw new Error("startStt() must start when not gated");
const startEvent = fetchCalls.find(c => c.url === "/assistant/voice-event");
if (!startEvent) throw new Error("startStt() must POST a voice-event span");
const startBody = JSON.parse(startEvent.opts.body);
if (startBody.kind !== "stt-start") throw new Error("expected kind stt-start, got " + startBody.kind);
if (startBody.engine !== "web-speech") throw new Error("expected engine web-speech in the span, got " + startBody.engine);
console.log("SPAN_ENGINE_NAME_OK true");
delete global.window.SpeechRecognition;

// ---- AST-052 (#334) span correlation: passing a turnId to startStt uses
// it AS the span id (same trick speakReply already applies to tts spans),
// and both stt-start/stt-end join window.assistantVoiceSpans (local,
// turn_id-tagged) the same way TTS spans already do -- so groupTurnsById
// can merge a full stt+chat+tts turn under one id. ----
{
    global.window.assistantGate = { gated: false };
    global.window.assistantVoiceSpans = [];
    fetchCalls = [];
    setSttEngineChoice("web-speech");
    let startedInstance = null;
    global.window.SpeechRecognition = function () { startedInstance = this; this.start = () => {}; this.stop = () => {}; };
    const sharedTurnId = "turn-shared-abc";
    const startedWithTurnId = startStt(sharedTurnId);
    if (startedWithTurnId !== true) throw new Error("startStt(turnId) must start when not gated");
    const startEv = fetchCalls.find(c => c.url === "/assistant/voice-event");
    const startEvBody = JSON.parse(startEv.opts.body);
    if (startEvBody.payload.spanId !== sharedTurnId) throw new Error("startStt(turnId) must use turnId as the span id, got " + startEvBody.payload.spanId);
    const localStart = window.assistantVoiceSpans.find(e => e.kind === "stt-start");
    if (!localStart || localStart.turn_id !== sharedTurnId) throw new Error("stt-start must join window.assistantVoiceSpans tagged with turn_id");

    // #452 (#454 P0 live-bug batch): stopStt() ALONE, before the outcome
    // is known, used to eagerly emit "stt-end ok" here -- the exact
    // "lying span" bug (a failed transcription still rendered green in
    // the inspector). It must now emit NOTHING.
    stopStt();
    if (window.assistantVoiceSpans.some(e => e.kind === "stt-end")) throw new Error("stopStt() alone (outcome not yet known) must NOT emit a terminal span");
    if (fetchCalls.some(c => c.url === "/assistant/voice-event" && JSON.parse(c.opts.body).kind === "stt-end")) throw new Error("stopStt() alone must not POST a stt-end voice-event either");
    console.log("STOPSTT_ALONE_EMITS_NOTHING_OK true");

    // the REAL outcome (a transcript) arrives now -- exactly ONE stt-end,
    // "ok", tagged with the SAME turn_id, emitted only once success is
    // actually known.
    startedInstance.onresult({ results: [[{ transcript: "final phrase" }]] });
    fireLatestTimer();
    const endSpans = window.assistantVoiceSpans.filter(e => e.kind === "stt-end");
    if (endSpans.length !== 1) throw new Error("expected exactly ONE stt-end span for this turn, got " + endSpans.length);
    if (endSpans[0].turn_id !== sharedTurnId || endSpans[0].status !== "ok") throw new Error("stt-end must be status ok, tagged with the shared turn_id, got " + JSON.stringify(endSpans[0]));
    console.log("SPAN_CORRELATION_OK true");
    delete global.window.SpeechRecognition;
}

// #452 (#454 P0 live-bug batch): the EXACT reported bug shape -- whisper's
// transcription outcome is only known ASYNCHRONOUSLY, well after stop()
// has already returned (mediaRecorder.onstop -> POST /transcribe -> maybe
// fails). A minimal fake stands in for WhisperSttEngine (its own class
// needs getUserMedia/MediaRecorder, not worth restubbing just to prove
// startStt/stopStt's span-TIMING contract, which is engine-agnostic): its
// stop() does nothing synchronously, mirroring the real class's actual
// contract -- the async outcome arrives later via the SAME onError
// callback startStt registered.
{
    global.window.assistantGate = { gated: false };
    global.window.assistantVoiceSpans = [];
    fetchCalls = [];
    setSttEngineChoice("whisper");
    let registeredError = null;
    global.sttEngines["whisper"] = {
        start(onResult, onError){ registeredError = onError; },
        stop(){ /* real whisper: synchronous, no outcome yet */ },
    };
    const failTurnId = "turn-fail-async";
    if (startStt(failTurnId) !== true) throw new Error("startStt must start when not gated");
    stopStt();
    if (window.assistantVoiceSpans.some(e => e.kind === "stt-end")) throw new Error("stopStt() must not emit a terminal span while the async outcome is still pending");
    registeredError("whisper-http-500");
    const endSpans2 = window.assistantVoiceSpans.filter(e => e.kind === "stt-end");
    if (endSpans2.length !== 1) throw new Error("expected exactly ONE stt-end span once the async failure arrives, got " + endSpans2.length + " (this is the #452 duplicate/lying-span bug if not 1)");
    if (endSpans2[0].status !== "error" || endSpans2[0].turn_id !== failTurnId) throw new Error("the single terminal span must be status error, tagged with the turn id, got " + JSON.stringify(endSpans2[0]));
    console.log("ASYNC_FAILURE_AFTER_STOP_SINGLE_SPAN_OK true");
}

// #451 (#454 P0 live-bug batch): a failed voice turn must SAY why -- this
// used to only console.warn + set window.__lastSttError, both invisible to
// the human. Full overlay-rendering coverage lives in section-assistant-
// voice-turn.sh (needs the chat-overlay DOM this file doesn't stub); here
// we just prove startStt's error path CALLS reportSttFailure with the
// honest message.
{
    global.window.assistantGate = { gated: false };
    reportedFailures = []; // reset the shared tracking array (stubbed once, near the top)
    setSttEngineChoice("web-speech");
    delete global.window.SpeechRecognition; // -> web-speech-unavailable
    startStt("turn-report-fail");
    if (reportedFailures.length !== 1) throw new Error("startStt's engine-error path must call reportSttFailure exactly once, got " + reportedFailures.length);
    if (reportedFailures[0].indexOf("web-speech-unavailable") === -1) throw new Error("reportSttFailure must receive the honest engine error message, got " + JSON.stringify(reportedFailures[0]));
    console.log("REPORTS_STT_FAILURE_OK true");
}

// ---- onSttText -> queueOrSendChat (today's downstream, AST-052 owns the rest) ----
onSttText("transcribed text");
if (queuedChatMessages[queuedChatMessages.length - 1] !== "transcribed text") throw new Error("onSttText must forward into queueOrSendChat");
console.log("ONSTTTEXT_ROUTES_TO_CHAT_OK true");

// ---- AST-052 (#334): onSttText auto-stops listening on a final result --
// the mic control's "press again OR auto-on-final to stop" contract ----
{
    global.window.assistantVoiceSpans = [];
    fetchCalls = [];
    setSttEngineChoice("web-speech");
    global.window.SpeechRecognition = function () { this.start = () => {}; this.stop = () => {}; };
    startStt("turn-autostop");
    onSttText("final phrase", "turn-autostop");
    const endEv = fetchCalls.find(c => c.url === "/assistant/voice-event" && JSON.parse(c.opts.body).kind === "stt-end");
    if (!endEv) throw new Error("onSttText must auto-stop -- expected an stt-end span after a final result");
    if (window.__sttSpanId !== null) throw new Error("onSttText must clear __sttSpanId after auto-stopping");
    console.log("ONSTTTEXT_AUTOSTOPS_OK true");
    delete global.window.SpeechRecognition;
}

console.log("ALL_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_stt_out="$(node "$_ast_node" "$NVHTML_STT" 2>&1)"
tmpl_stt_rc=$?
rm -f "$_ast_node"
check_rc "STT template script exits 0" 0 "$tmpl_stt_rc"
check "default sttEngineChoice is whisper" "DEFAULT_WHISPER_OK true" "$tmpl_stt_out"
check "toggle applies to the settings-panel buttons" "TOGGLE_APPLIES_OK true" "$tmpl_stt_out"
check "toggle persists in the nv-ui localStorage key" "PERSIST_OK true" "$tmpl_stt_out"
check "switching back to whisper works" "SWITCH_BACK_OK true" "$tmpl_stt_out"
check "Web Speech engine degrades honestly when unavailable" "WEBSPEECH_DEGRADE_OK true" "$tmpl_stt_out"
check "#454 (P0 live-bug batch): silence-timeout endpointing accumulates final segments across a mid-sentence pause into ONE turn, instead of truncating on the first" "WEBSPEECH_ENDPOINTING_ACCUMULATES_OK true" "$tmpl_stt_out"
check "#454: a manual stop (press again) flushes whatever's buffered immediately, never losing it" "WEBSPEECH_MANUAL_STOP_FLUSHES_OK true" "$tmpl_stt_out"
check "#454: a manual stop with nothing captured yet never calls onResult with empty text" "WEBSPEECH_EMPTY_STOP_NO_RESULT_OK true" "$tmpl_stt_out"
check "whisper engine surfaces an honest unavailable-sidecar state" "WHISPER_DEGRADE_OK true" "$tmpl_stt_out"
check "the §17.9 gate blocks STT start with no assistant selected" "GATE_BLOCKS_START_OK true" "$tmpl_stt_out"
check "a span's payload carries the engine name" "SPAN_ENGINE_NAME_OK true" "$tmpl_stt_out"
check "#452 (P0 live-bug batch): stopStt() alone, before the outcome is known, emits no terminal span at all -- the old eager-ok lying-span bug" "STOPSTT_ALONE_EMITS_NOTHING_OK true" "$tmpl_stt_out"
check "AST-052 (#334): startStt(turnId) uses turnId as the span id and both stt spans join window.assistantVoiceSpans tagged with it" "SPAN_CORRELATION_OK true" "$tmpl_stt_out"
check "#452: whisper's async-after-stop outcome (the exact reported bug shape) still produces exactly ONE terminal span, not a duplicate ok-then-error pair" "ASYNC_FAILURE_AFTER_STOP_SINGLE_SPAN_OK true" "$tmpl_stt_out"
check "#451 (P0 live-bug batch): startStt's engine-error path calls reportSttFailure with the honest message" "REPORTS_STT_FAILURE_OK true" "$tmpl_stt_out"
check "onSttText routes transcript text into the existing chat-send path" "ONSTTTEXT_ROUTES_TO_CHAT_OK true" "$tmpl_stt_out"
check "AST-052 (#334): onSttText auto-stops recognition on a final result" "ONSTTTEXT_AUTOSTOPS_OK true" "$tmpl_stt_out"
check "the whole STT template script completes" "ALL_OK true" "$tmpl_stt_out"
if [[ "$tmpl_stt_rc" -ne 0 ]]; then echo "$tmpl_stt_out" >&2; fi

echo "-- engine.py: POST /assistant/voice-event -- gated off per §17.9, bridges into the existing trace path (no new writer) --"
AST_STT_SCRIPTS="$PLUGIN/scripts"
stt_repo() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude"
    printf "%s\n" "# neural-network" >"$dir/.claude/.neural-network"
    printf "%s\n" \
        "schemaVersion: 2" \
        "assistant:" \
        "    version: 1" \
        "    enabled: true" \
        "    names: [$main]" \
        "    systemPrompt: |" \
        "        You are $main." \
        "    llm:" \
        "        provider: openai" \
        "        model: gpt-5.6-sol" \
        "    capabilities:" \
        "        codex:" \
        "            enabled: true" \
        "            provisioning:" \
        "                bin: codex" \
        >"$dir/.claude/project.yaml"
}
_ast_stt_root="$(mktemp -d)"
stt_repo "$_ast_stt_root" jarvis
_ast_stt_state="$(mktemp -d)"

stt_out="$(SCRIPTS_DIR="$AST_STT_SCRIPTS" ROOT="$_ast_stt_root" STATE="$_ast_stt_state" python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine, observability

root = os.environ["ROOT"]
repos = lambda: [("a", root)]
state_dir = os.environ["STATE"]

# Every engine's worker threads are daemon=False (AST-010) -- an uncaught
# exception here (e.g. this section's own RED phase, where /assistant/
# voice-event does not exist yet and handle() returns None) must never skip
# e.stop()/e2.stop(), or those non-daemon threads park on stop_event.wait()
# forever and the whole test process hangs instead of failing fast. Both
# engines are therefore built and stopped under try/finally; os._exit at the
# very end is a last-resort belt-and-suspenders against ANY other lingering
# non-daemon thread this script did not anticipate.
e = engine.AssistantEngine(repos, state_dir)
e2 = engine.AssistantEngine(repos, state_dir + "-2")
try:
    e.start()
    e2.start()

    # ---- gated off (skip) refuses the span, same posture as /assistant/chat ----
    code_gated, payload_gated, _ = e.handle("POST", "/assistant/skip")
    code1, p1, _ = e.handle("POST", "/assistant/voice-event", body={"kind": "stt-start", "engine": "web-speech"})
    print("GATED_CODE", code1)
    print("GATED_HAS_ERROR", "error" in p1)

    # ---- unknown kind is a clean 400, never a silent no-op ----
    code2, p2, _ = e2.handle("POST", "/assistant/voice-event", body={"kind": "bogus-kind"})
    print("BAD_KIND_CODE", code2)

    # ---- a real stt-start/stt-end pair records with the engine name in payload ----
    code3, p3, _ = e2.handle("POST", "/assistant/voice-event", body={"kind": "stt-start", "engine": "whisper", "payload": {"span_id": "s1"}})
    code4, p4, _ = e2.handle("POST", "/assistant/voice-event", body={"kind": "stt-end", "engine": "whisper", "status": "ok", "payload": {"span_id": "s1"}})
    print("START_CODE", code3)
    print("END_CODE", code4)
    time.sleep(0.6)
    events = observability.query(root, limit=50)
    kinds = [ev["kind"] for ev in events]
    print("HAS_STT_START", "stt-start" in kinds)
    print("HAS_STT_END", "stt-end" in kinds)
    start_ev = next(ev for ev in events if ev["kind"] == "stt-start")
    print("START_MODALITY", start_ev.get("modality"))
    print("START_ENGINE_IN_PAYLOAD", start_ev.get("payload", {}).get("engine"))
    rc = 0
except Exception as exc:  # noqa: BLE001 -- deliberately broad, see docstring above
    print("SCRIPT_ERROR", repr(exc))
    rc = 1
finally:
    e.stop()
    e2.stop()
sys.stdout.flush()
os._exit(rc)
PY
)"
rc_stt=$?
check_rc "engine voice-event script exits 0" 0 "$rc_stt"
check "gated session refuses /assistant/voice-event with a 4xx" "GATED_CODE 403" "$stt_out"
check "gated refusal carries an error field" "GATED_HAS_ERROR True" "$stt_out"
check "an unrecognized kind is refused with a clean 400" "BAD_KIND_CODE 400" "$stt_out"
check "a real stt-start posts 200" "START_CODE 200" "$stt_out"
check "a real stt-end posts 200" "END_CODE 200" "$stt_out"
check "stt-start is actually recorded in traces.sqlite" "HAS_STT_START True" "$stt_out"
check "stt-end is actually recorded in traces.sqlite" "HAS_STT_END True" "$stt_out"
check "voice spans are tagged with the voice modality (not the turn/text default)" "START_MODALITY voice" "$stt_out"
check "the engine name rides in the span's payload" "START_ENGINE_IN_PAYLOAD whisper" "$stt_out"
if [[ "$rc_stt" -ne 0 ]]; then echo "$stt_out" >&2; fi
rm -rf "$_ast_stt_root" "$_ast_stt_state" "$_ast_stt_state-2"
