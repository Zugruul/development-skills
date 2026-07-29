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

echo "-- template: settings panel gains an STT engine control, default web-speech (#491), persisted --"
NVHTML_STT_BODY="$(cat "$NVHTML_STT")"
check "settings panel: whisper option present" 'id="vs-stt-whisper"' "$NVHTML_STT_BODY"
check "settings panel: web-speech option present" 'id="vs-stt-webspeech"' "$NVHTML_STT_BODY"
check "#491: hint names Web Speech as the default while the sidecar contract is unfinished" "Web Speech is the default" "$NVHTML_STT_BODY"
check "#491: hint says whisper returns as default once the sidecar capability lands" "#424" "$NVHTML_STT_BODY"
check "settings panel: hint names Web Speech as needing no install" "needs no install" "$NVHTML_STT_BODY"
check "sttEngineChoice() defaults to web-speech when unset (#491)" 'function sttEngineChoice(){' "$NVHTML_STT_BODY"
check "setSttEngineChoice persists via saveUiState (same path as the rest of the panel)" "function setSttEngineChoice(choice){" "$NVHTML_STT_BODY"

echo "-- template: STT engine abstraction -- two implementations, honest degrade --"
check "WebSpeechSttEngine class exists" "class WebSpeechSttEngine{" "$NVHTML_STT_BODY"
check "WebSpeechSttEngine degrades honestly when unavailable" "web-speech-unavailable" "$NVHTML_STT_BODY"
check "WhisperSttEngine class exists" "class WhisperSttEngine{" "$NVHTML_STT_BODY"
check "WhisperSttEngine surfaces the honest unavailable-sidecar message" "whisper sidecar not available -- install via the whisper capability" "$NVHTML_STT_BODY"
check "WhisperSttEngine's unavailable message offers the Web Speech alternative" "switch to Web Speech in Settings" "$NVHTML_STT_BODY"
check "sttEngines registry wires both engine names to their implementations" 'const sttEngines = { whisper: new WhisperSttEngine(), "web-speech": new WebSpeechSttEngine() };' "$NVHTML_STT_BODY"
check "#491: web-speech requests interim results for live STT feedback" "r.interimResults = true" "$NVHTML_STT_BODY"
check "#491: startStt threads the live-interim callback into the engine" "sttUpdatePendingBubble(live)" "$NVHTML_STT_BODY"
check "#491: startStt shows the pending bubble when capture starts, span-guarded" "sttShowPendingBubble(spanId);" "$NVHTML_STT_BODY"
check "#491: onSttText clears the pending bubble before the real row renders" "sttRemovePendingBubble();" "$NVHTML_STT_BODY"
check "#490: the mic dot is driven by capture truth every frame" "function syncCaptureDot(){" "$NVHTML_STT_BODY"
check "#490: drawViz syncs the capture dot each frame" "syncCaptureDot(); // #490" "$NVHTML_STT_BODY"
check "#491: pending-bubble style exists" ".ast-chat-pending{" "$NVHTML_STT_BODY"
check "#491 review finding 2: the dashed edge wins specificity over the user-row border shorthand" '.ast-chat-row[data-role="user"].ast-chat-pending{border-style:dashed}' "$NVHTML_STT_BODY"
check "#491 review finding 4: sttShowPendingBubble guards against a turn that ended during the overlay-open await" "if(spanId !== undefined && window.__sttSpanId !== spanId) return;" "$NVHTML_STT_BODY"

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
let queuedChatCalls = [];
global.queueOrSendChat = (text, turnId, source) => { queuedChatMessages.push(text); queuedChatCalls.push({text, turnId, source}); };
// #451 (#454 P0 live-bug batch): stubbed once, up front, since startStt's
// engine-error callback calls this unconditionally on any failure --
// several blocks below (whisper's async-after-stop failure included)
// trigger it well before the dedicated REPORTS_STT_FAILURE_OK test does.
let reportedFailures = [];
global.reportSttFailure = (msg) => { reportedFailures.push(msg); };
// #491: startStt/onSttText now drive the live-transcription pending
// bubble -- stubbed as recorders here (the REAL functions are exercised
// against the full chat DOM stub in section-assistant-voice-turn.sh's
// second harness; this harness has no chat overlay DOM), same pattern as
// reportSttFailure above.
let pendingBubbleCalls = [];
global.sttShowPendingBubble = async () => { pendingBubbleCalls.push(["show"]); };
global.sttUpdatePendingBubble = (t) => { pendingBubbleCalls.push(["update", t]); };
global.sttRemovePendingBubble = () => { pendingBubbleCalls.push(["remove"]); };

(async () => {
// ---- setting: default web-speech (#491, until #424 lands), toggle persists ----
// saveUiState() itself is a one-liner in the template (not extractable via
// the block-regex above); stub the SAME contract it has -- persist
// uiState to the nv-ui localStorage key -- rather than regex-splice it.
global.uiState = {};
function saveUiState(){ try{ localStorage.setItem("nv-ui", JSON.stringify(uiState)); }catch{} }
eval(extract("sttEngineChoice"));
eval(extract("applySttEngineUi"));
eval(extract("setSttEngineChoice"));

// #491: whisper's sidecar contract is unfinished (#424 -- the shipped
// client posts /transcribe, the sidecar serves /inference), so defaulting
// to it hands every fresh profile a voice path that CANNOT transcribe.
// Web Speech is the default until #424 lands; an explicit whisper choice
// still persists and wins.
if (sttEngineChoice() !== "web-speech") throw new Error("#491: default sttEngineChoice must be web-speech while the whisper sidecar contract (#424) is unfinished, got " + sttEngineChoice());
console.log("DEFAULT_WEBSPEECH_OK true");

setSttEngineChoice("whisper");
if (sttEngineChoice() !== "whisper") throw new Error("setSttEngineChoice(whisper) did not take effect");
if (elements["vs-stt-whisper"].getAttribute("aria-pressed") !== "true") throw new Error("vs-stt-whisper should be pressed after selecting whisper");
if (elements["vs-stt-webspeech"].getAttribute("aria-pressed") !== "false") throw new Error("vs-stt-webspeech should NOT be pressed after selecting whisper");
console.log("TOGGLE_APPLIES_OK true");

// persisted like the rest of the panel: reload uiState from localStorage the
// same way the template's own boot sequence does, and the choice must survive
const persisted = JSON.parse(localStorage.getItem("nv-ui") || "{}");
if (persisted.sttEngine !== "whisper") throw new Error("sttEngine was not persisted to the nv-ui localStorage key");
console.log("PERSIST_OK true");

setSttEngineChoice("web-speech");
if (sttEngineChoice() !== "web-speech") throw new Error("setSttEngineChoice(web-speech) did not take effect");
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
defineConst("STT_WEBSPEECH_LIVENESS_MS");
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
    startedInstance.onresult({ resultIndex: 0, results: [Object.assign([{ transcript: "Are you" }], { isFinal: true })] });
    if (resultCalls !== 0) throw new Error("a single final segment must not finalize the turn immediately -- that is the #454 truncation bug");
    if (scheduledTimers.size !== 1) throw new Error("a final segment must schedule exactly one silence timer, got " + scheduledTimers.size);
    if ([...scheduledTimers.values()][0].ms !== STT_WEBSPEECH_SILENCE_MS) throw new Error("the scheduled delay must be STT_WEBSPEECH_SILENCE_MS, got " + [...scheduledTimers.values()][0].ms);
    // speech resumes before the silence timeout elapses -- must EXTEND, not truncate
    startedInstance.onresult({ resultIndex: 0, results: [Object.assign([{ transcript: "there" }], { isFinal: true })] });
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
    // #491: interim (non-final) results feed the live transcription
    // bubble via onInterim -- streamed as they arrive, WITHOUT finalizing
    // the turn and WITHOUT touching the silence timer (#454's endpointing
    // keys off FINAL segments only; an interim mid-word must never
    // schedule or reset a finalize).
    let startedInstance = null;
    global.window.SpeechRecognition = function () { startedInstance = this; this.start = () => {}; this.stop = () => {}; };
    const engine = new WebSpeechSttEngine();
    let interims = [], resultCalls = 0;
    engine.start(() => { resultCalls++; }, () => {}, (live) => { interims.push(live); });
    startedInstance.onresult({ resultIndex: 0, results: [Object.assign([{ transcript: "hel" }], { isFinal: false })] });
    startedInstance.onresult({ resultIndex: 0, results: [Object.assign([{ transcript: "hello wor" }], { isFinal: false })] });
    if (interims.join("|") !== "hel|hello wor") throw new Error("interim segments must stream through onInterim as they arrive, got " + JSON.stringify(interims));
    if (scheduledTimers.size !== 0) throw new Error("an interim (non-final) segment must NOT arm the silence timer -- endpointing keys off finals only");
    if (resultCalls !== 0) throw new Error("interims must never finalize the turn");
    startedInstance.onresult({ resultIndex: 0, results: [Object.assign([{ transcript: "hello world" }], { isFinal: true })] });
    if (scheduledTimers.size !== 1) throw new Error("the final segment must still arm the silence timer");
    if (interims[interims.length - 1] !== "hello world") throw new Error("a final segment must refresh the live text with the accumulated buffer, got " + JSON.stringify(interims[interims.length - 1]));
    fireLatestTimer();
    if (resultCalls !== 1) throw new Error("silence after the final must finalize exactly once");
    console.log("WEBSPEECH_INTERIM_STREAMS_OK true");
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
    startedInstance.onresult({ resultIndex: 0, results: [Object.assign([{ transcript: "partial" }], { isFinal: true })] });
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

// ---- #474 (P0, issue #474): "talks non-stop, hears nothing at all" --
// four hypotheses to investigate (per-instance below), plus the hard
// liveness requirement regardless of which hypotheses confirm. ----
{
    // hyp 1 + hyp 4: a race where start() is called again before the
    // PREVIOUS native recognizer has actually finished stopping (the
    // browser's own SpeechRecognition.stop() is asynchronous) must never
    // let the stale instance's events corrupt the NEW session's buffer/
    // outcome -- and repeated start/stop cycles must never leak a live
    // handler that can still fire into shared state.
    let instanceA = null, instanceB = null;
    global.window.SpeechRecognition = function () {
        if (!instanceA) instanceA = this; else instanceB = this;
        this.start = () => {};
        this.stop = () => {};
    };
    const engine = new WebSpeechSttEngine();
    let resultsA = [];
    engine.start((text) => resultsA.push(text), () => {});
    // capture the handler reference up front (stop() does NOT null it --
    // see WEBSPEECH_LATE_RESULT_AFTER_STOP_SAME_GEN_OK's own comment for
    // why) so it can still be invoked below exactly as a real browser
    // would, delivering a queued event into a since-superseded session.
    const staleOnResult = instanceA.onresult;
    engine.stop(); // asks the native recognizer to stop -- NOT synchronous in a real browser
    let resultsB = [];
    engine.start((text) => resultsB.push(text), () => {});
    // instanceA's browser-side session is STILL delivering a queued event
    // even though JS already moved on to session B -- this is the race.
    staleOnResult({ results: [[{ transcript: "stale from A" }]] });
    if (resultsA.length !== 0 || resultsB.length !== 0) throw new Error("a stale instance's onresult must be a no-op, not deliver into either session's onResult -- got A=" + JSON.stringify(resultsA) + " B=" + JSON.stringify(resultsB));
    // session B still works normally afterward
    instanceB.onresult({ resultIndex: 0, results: [Object.assign([{ transcript: "from B" }], { isFinal: true })] });
    fireLatestTimer();
    if (resultsB.length !== 1 || resultsB[0] !== "from B") throw new Error("session B must still finalize normally after the stale A event was ignored, got " + JSON.stringify(resultsB));
    console.log("WEBSPEECH_STALE_INSTANCE_IGNORED_OK true");
    delete global.window.SpeechRecognition;
}
{
    // hyp 4, contrast case: stop() must clear this.recog (this engine
    // holds no lingering reference to the old instance)...
    let startedInstance = null;
    global.window.SpeechRecognition = function () { startedInstance = this; this.start = () => {}; this.stop = () => {}; };
    const engine = new WebSpeechSttEngine();
    engine.start(() => {}, () => {});
    engine.stop();
    if (engine.recog !== null) throw new Error("stop() must clear this.recog");
    // ...but deliberately does NOT null the old instance's own handlers --
    // a real SpeechRecognition can still deliver ONE more onresult for
    // audio already captured before stop() was called (stop() means
    // "capture nothing new", not "discard what's pending"), and that
    // legitimate late result (same generation, no start() since) must
    // still reach onResult normally rather than being silently dropped.
    let resultCalls = 0;
    engine.onResult = () => { resultCalls++; }; // _finalize reads this.onResult directly
    startedInstance.onresult({ resultIndex: 0, results: [Object.assign([{ transcript: "captured before stop" }], { isFinal: true })] });
    fireLatestTimer();
    if (resultCalls !== 1) throw new Error("a legitimate late result on the SAME generation (no new start() yet) must still deliver, got " + resultCalls + " calls");
    console.log("WEBSPEECH_LATE_RESULT_AFTER_STOP_SAME_GEN_OK true");
    delete global.window.SpeechRecognition;
}
{
    // hyp 2 (the primary reported bug shape): the browser's own
    // recognition SERVICE can end a continuous session on its own --
    // `onend` fires (per spec, the one guaranteed terminal event) but
    // NEITHER onerror NOR our own stop() was ever called. Previously
    // nothing listened for onend at all, so the mic control stayed
    // "listening" forever against a dead engine -- exactly "talks
    // non-stop, hears nothing at all".
    let startedInstance = null;
    global.window.SpeechRecognition = function () { startedInstance = this; this.start = () => {}; this.stop = () => {}; };
    const engine = new WebSpeechSttEngine();
    let gotError = null, resultCalls = 0;
    engine.start(() => { resultCalls++; }, (err) => { gotError = err; });
    // the service ends the session with no error and no manual stop
    startedInstance.onend();
    if (!gotError || gotError.indexOf("web-speech-ended") === -1) throw new Error("an unexpected onend (no manual stop, no prior onerror) must report an honest 'engine died' error, got " + gotError);
    if (resultCalls !== 0) throw new Error("onend must never call onResult");
    console.log("WEBSPEECH_ONEND_TREATED_AS_DEATH_OK true");
    delete global.window.SpeechRecognition;
}
{
    // onend firing AFTER onerror (the normal, spec-compliant sequence for
    // an errored session) must not double-report -- onerror already told
    // the caller.
    let startedInstance = null;
    global.window.SpeechRecognition = function () { startedInstance = this; this.start = () => {}; this.stop = () => {}; };
    const engine = new WebSpeechSttEngine();
    let errorCalls = 0;
    engine.start(() => {}, () => { errorCalls++; });
    startedInstance.onerror({ error: "network" });
    startedInstance.onend(); // spec-guaranteed to fire after onerror too
    if (errorCalls !== 1) throw new Error("onend after an already-reported onerror must not report a second error, got " + errorCalls + " calls");
    console.log("WEBSPEECH_ONEND_AFTER_ONERROR_NOT_DOUBLE_REPORTED_OK true");
    delete global.window.SpeechRecognition;
}
{
    // onend firing after a MANUAL stop() (the expected, healthy shutdown
    // path) must not be treated as a death either.
    let startedInstance = null;
    global.window.SpeechRecognition = function () { startedInstance = this; this.start = () => {}; this.stop = () => {}; };
    const engine = new WebSpeechSttEngine();
    let errorCalls = 0;
    engine.start(() => {}, () => { errorCalls++; });
    engine.stop(); // stop() does not null onend -- see WEBSPEECH_LATE_RESULT_AFTER_STOP_SAME_GEN_OK
    startedInstance.onend();
    if (errorCalls !== 0) throw new Error("onend after a deliberate stop() must never report an error, got " + errorCalls + " calls");
    console.log("WEBSPEECH_ONEND_AFTER_MANUAL_STOP_HONEST_OK true");
    delete global.window.SpeechRecognition;
}
{
    // liveness requirement (hard, regardless of hypothesis confirmation):
    // a bounded watchdog -- if the recognition service never shows ANY
    // sign of life (no onaudiostart, no onresult, no onerror, no onend)
    // within STT_WEBSPEECH_LIVENESS_MS of start(), the engine must be
    // declared dead outright rather than sit there "listening"
    // indefinitely -- this is the truly-silent case the issue also asks
    // about, where nothing native fires at all.
    global.window.SpeechRecognition = function () { this.start = () => {}; this.stop = () => {}; };
    const engine = new WebSpeechSttEngine();
    let gotError = null;
    engine.start(() => {}, (err) => { gotError = err; });
    if (![...scheduledTimers.values()].some(t => t.ms === STT_WEBSPEECH_LIVENESS_MS)) throw new Error("start() must arm a liveness watchdog of exactly STT_WEBSPEECH_LIVENESS_MS");
    const watchdogEntry = [...scheduledTimers.entries()].find(([, t]) => t.ms === STT_WEBSPEECH_LIVENESS_MS);
    scheduledTimers.delete(watchdogEntry[0]);
    watchdogEntry[1].fn();
    if (!gotError || gotError.indexOf("web-speech-dead") === -1) throw new Error("a fully silent engine (no native events at all) must be declared dead within the bounded watchdog window, got " + gotError);
    if (engine.recog !== null) throw new Error("the watchdog must clear this.recog once the engine is declared dead");
    console.log("WEBSPEECH_LIVENESS_WATCHDOG_OK true");
    delete global.window.SpeechRecognition;
}
{
    // the watchdog must NOT false-positive during ordinary silence once
    // the engine has proven it's alive (onaudiostart -- fires the moment
    // mic audio reaches the recognizer, well before any speech is heard).
    let startedInstance = null;
    global.window.SpeechRecognition = function () { startedInstance = this; this.start = () => {}; this.stop = () => {}; };
    const engine = new WebSpeechSttEngine();
    let gotError = null;
    engine.start(() => {}, (err) => { gotError = err; });
    startedInstance.onaudiostart();
    if ([...scheduledTimers.values()].some(t => t.ms === STT_WEBSPEECH_LIVENESS_MS)) throw new Error("onaudiostart must cancel the liveness watchdog -- proof of life arrived");
    if (gotError) throw new Error("a live engine sitting in ordinary silence must never be reported as dead, got " + gotError);
    console.log("WEBSPEECH_LIVENESS_CLEARED_BY_AUDIOSTART_OK true");
    delete global.window.SpeechRecognition;
}
{
    // hyp 3: investigate whether the silence-timeout endpointing can
    // finalize an EMPTY buffer and leave the engine stopped while the UI
    // still shows listening. Evidence this is NOT what happens: _finalize
    // never calls engine.stop()/clears this.recog, and never calls
    // onResult with empty text -- an empty finalize is a harmless no-op,
    // the engine keeps running exactly as before. RULED OUT.
    let startedInstance = null;
    global.window.SpeechRecognition = function () { startedInstance = this; this.start = () => {}; this.stop = () => {}; };
    const engine = new WebSpeechSttEngine();
    let resultCalls = 0;
    engine.start(() => { resultCalls++; }, () => {});
    // an onresult event carrying no usable transcript still arms the
    // silence timer (existing accumulation behavior) -- firing it must be
    // a no-op, and critically must NOT stop/clear the engine.
    startedInstance.onresult({ resultIndex: 0, results: [Object.assign([{ transcript: "" }], { isFinal: true })] });
    fireLatestTimer();
    if (resultCalls !== 0) throw new Error("an empty-buffer finalize must never call onResult");
    if (engine.recog !== startedInstance) throw new Error("hyp 3 is ruled out only if an empty finalize leaves the engine's recog untouched -- it must NOT stop/clear it");
    console.log("WEBSPEECH_HYP3_EMPTY_FINALIZE_RULED_OUT_OK true");
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
{
    // #474: "for BOTH engines" -- MediaRecorder (or its underlying mic
    // track) can die on its own, e.g. device unplugged/permission revoked
    // mid-capture, without ever reaching onstop. Previously nothing
    // listened for MediaRecorder's own `error` event, which left the mic
    // control "listening" against a dead recorder, the same silent-death
    // shape as WebSpeech's unhandled onend.
    let stoppedTracks = 0;
    // modern Node ships a built-in, non-writable `navigator` global (user-
    // agent info) -- a bare `global.navigator = {...}` silently no-ops
    // against it (unlike every OTHER stub in this harness), so getUserMedia
    // below would otherwise resolve against the REAL (mediaDevices-less)
    // navigator and always take the catch branch. Delete it first (it IS
    // configurable) so this stub actually takes effect -- needed here,
    // unlike the getUserMedia-throws test above, because THIS test needs
    // getUserMedia to actually SUCCEED.
    delete global.navigator;
    global.navigator = { mediaDevices: { getUserMedia: async () => ({ getTracks: () => [{ stop(){ stoppedTracks++; } }] }) } };
    let recorderInstance = null;
    global.MediaRecorder = function () { recorderInstance = this; this.state = "recording"; };
    global.MediaRecorder.prototype.start = function () {};
    global.MediaRecorder.prototype.stop = function () {};
    const engine = new WhisperSttEngine();
    let gotError = null, resultCalls = 0;
    await engine.start(() => { resultCalls++; }, (err) => { gotError = err; });
    recorderInstance.onerror({ error: { name: "InvalidStateError" } });
    if (!gotError || gotError.indexOf("whisper-recorder-error") === -1) throw new Error("MediaRecorder's own error event must be surfaced honestly, got " + gotError);
    if (resultCalls !== 0) throw new Error("a recorder error must never call onResult");
    if (stoppedTracks !== 1) throw new Error("a recorder error must release the mic stream (stop its tracks), got " + stoppedTracks);
    console.log("WHISPER_RECORDER_ERROR_OK true");
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
    startedInstance.onresult({ resultIndex: 0, results: [Object.assign([{ transcript: "final phrase" }], { isFinal: true })] });
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

// #474 (confirmed via reviewer-454's retroactive review of the merged #454
// batch, folded into this lane as a concrete instance of hypothesis 1):
// onSttText's `window.__sttSpanId === turnId` guard used to gate ONLY the
// span emission -- stopStt()/releaseSttCapture()/queueOrSendChat() ran
// UNCONDITIONALLY even for an ALREADY-SUPERSEDED turnId. Reachable via
// whisper's async /transcribe: start turn A, manually stop it (turn A's
// span closes, e.g. an honest no-speech/cancel) before the response
// arrives, start turn B -- then A's late response arrives and used to
// STOP B'S LIVE ENGINE, TEAR DOWN B'S CAPTURE STATE, and forward A's
// STALE text as if it were freshly spoken. Net: the user's live turn is
// silently killed ("talks, hears nothing") plus a ghost message sent on
// their behalf. A minimal fake WhisperSttEngine captures each start()
// call's own onResult callback so this ordering can be driven exactly.
{
    global.window.assistantGate = { gated: false };
    global.window.assistantVoiceSpans = [];
    fetchCalls = [];
    queuedChatMessages = [];
    queuedChatCalls = [];
    setSttEngineChoice("whisper");
    let stopCalls = 0;
    let capturedOnResults = [];
    global.sttEngines["whisper"] = {
        start(onResult, onError){ capturedOnResults.push(onResult); },
        stop(){ stopCalls++; },
    };
    const turnA = "turn-A-superseded";
    if (startStt(turnA) !== true) throw new Error("startStt must start turn A");
    const onResultA = capturedOnResults[capturedOnResults.length - 1];
    // turn A gets closed out from under it -- matches what
    // toggleSttListening's own no-speech manual-stop path does (clears
    // window.__sttSpanId once a turn is considered done) -- BEFORE A's
    // async transcription resolves.
    window.__sttSpanId = null;
    const turnB = "turn-B-live";
    if (startStt(turnB) !== true) throw new Error("startStt must start turn B");
    const onResultB = capturedOnResults[capturedOnResults.length - 1];
    stopCalls = 0; // isolate: only count stop() calls from THIS point on
    // A's delayed /transcribe response finally arrives -- for a now-STALE turn.
    onResultA("stale text from A");
    if (queuedChatMessages.length !== 0) throw new Error("a stale/superseded turn's late result must never reach queueOrSendChat, got " + JSON.stringify(queuedChatMessages));
    if (stopCalls !== 0) throw new Error("a stale turn's late result must NOT stop the engine -- turn B is live and must not be killed out from under the user, got " + stopCalls + " stop() call(s)");
    if (window.__sttSpanId !== turnB) throw new Error("a stale turn's late result must not touch the CURRENTLY active turn's span id, got " + window.__sttSpanId);
    console.log("STALE_TURN_RESULT_DROPPED_OK true");

    // turn B, the one actually still live, must still work completely normally.
    onResultB("hello from B");
    if (queuedChatCalls.length !== 1 || queuedChatCalls[0].text !== "hello from B" || queuedChatCalls[0].turnId !== turnB) throw new Error("the CURRENTLY active turn must still deliver normally once its own result arrives, got " + JSON.stringify(queuedChatCalls));
    console.log("LIVE_TURN_STILL_DELIVERS_OK true");
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
// #474: onSttText is ALWAYS invoked in production via the closure startStt
// wires up (`text=>{ onSttText(text, spanId); }`), where spanId is always
// a real, currently-active turn id -- calling it with no turnId at all
// (as this test used to) does not reflect any reachable production path,
// and with the stale-turn guard below now gating the WHOLE handler (not
// just span emission), a mismatched/absent turnId is correctly treated as
// stale and dropped. Set up the matching active span first, same as every
// other onSttText call site in this file.
window.__sttSpanId = "turn-routes-to-chat";
onSttText("transcribed text", "turn-routes-to-chat");
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
check "default sttEngineChoice is web-speech (#491, until #424 lands)" "DEFAULT_WEBSPEECH_OK true" "$tmpl_stt_out"
check "toggle applies to the settings-panel buttons" "TOGGLE_APPLIES_OK true" "$tmpl_stt_out"
check "toggle persists in the nv-ui localStorage key" "PERSIST_OK true" "$tmpl_stt_out"
check "switching back to web-speech works" "SWITCH_BACK_OK true" "$tmpl_stt_out"
check "Web Speech engine degrades honestly when unavailable" "WEBSPEECH_DEGRADE_OK true" "$tmpl_stt_out"
check "#454 (P0 live-bug batch): silence-timeout endpointing accumulates final segments across a mid-sentence pause into ONE turn, instead of truncating on the first" "WEBSPEECH_ENDPOINTING_ACCUMULATES_OK true" "$tmpl_stt_out"
check "#491: interim results stream through onInterim without touching endpointing" "WEBSPEECH_INTERIM_STREAMS_OK true" "$tmpl_stt_out"
check "#454: a manual stop (press again) flushes whatever's buffered immediately, never losing it" "WEBSPEECH_MANUAL_STOP_FLUSHES_OK true" "$tmpl_stt_out"
check "#454: a manual stop with nothing captured yet never calls onResult with empty text" "WEBSPEECH_EMPTY_STOP_NO_RESULT_OK true" "$tmpl_stt_out"
check "#474 hyp1/hyp4: a stale (pre-teardown) recognizer instance's events never corrupt the new session, and a new session finalizes normally afterward" "WEBSPEECH_STALE_INSTANCE_IGNORED_OK true" "$tmpl_stt_out"
check "#474 hyp4: stop() clears this.recog, but a legitimate late result on the SAME generation (captured before stop, no new start() since) still delivers -- the generation guard, not blanket nulling, is what distinguishes stale from legitimate" "WEBSPEECH_LATE_RESULT_AFTER_STOP_SAME_GEN_OK true" "$tmpl_stt_out"
check "#474 hyp2 (the reported bug shape): an unexpected onend (no manual stop, no prior onerror) reports an honest engine-died error instead of leaving the UI listening forever" "WEBSPEECH_ONEND_TREATED_AS_DEATH_OK true" "$tmpl_stt_out"
check "#474: onend after an already-reported onerror does not double-report" "WEBSPEECH_ONEND_AFTER_ONERROR_NOT_DOUBLE_REPORTED_OK true" "$tmpl_stt_out"
check "#474: onend after a deliberate stop() is never treated as a death" "WEBSPEECH_ONEND_AFTER_MANUAL_STOP_HONEST_OK true" "$tmpl_stt_out"
check "#474 liveness requirement: a fully silent engine (no native events at all) is declared dead within the bounded watchdog window" "WEBSPEECH_LIVENESS_WATCHDOG_OK true" "$tmpl_stt_out"
check "#474 liveness requirement: onaudiostart proves life and cancels the watchdog -- ordinary silence is never mistaken for death" "WEBSPEECH_LIVENESS_CLEARED_BY_AUDIOSTART_OK true" "$tmpl_stt_out"
check "#474 hyp3 investigated and RULED OUT: an empty-buffer silence-timeout finalize never stops/clears the engine and never calls onResult" "WEBSPEECH_HYP3_EMPTY_FINALIZE_RULED_OUT_OK true" "$tmpl_stt_out"
check "whisper engine surfaces an honest unavailable-sidecar state" "WHISPER_DEGRADE_OK true" "$tmpl_stt_out"
check "#474 (BOTH engines): MediaRecorder's own error event is surfaced honestly instead of leaving the engine dead-but-listening" "WHISPER_RECORDER_ERROR_OK true" "$tmpl_stt_out"
check "the §17.9 gate blocks STT start with no assistant selected" "GATE_BLOCKS_START_OK true" "$tmpl_stt_out"
check "a span's payload carries the engine name" "SPAN_ENGINE_NAME_OK true" "$tmpl_stt_out"
check "#452 (P0 live-bug batch): stopStt() alone, before the outcome is known, emits no terminal span at all -- the old eager-ok lying-span bug" "STOPSTT_ALONE_EMITS_NOTHING_OK true" "$tmpl_stt_out"
check "AST-052 (#334): startStt(turnId) uses turnId as the span id and both stt spans join window.assistantVoiceSpans tagged with it" "SPAN_CORRELATION_OK true" "$tmpl_stt_out"
check "#452: whisper's async-after-stop outcome (the exact reported bug shape) still produces exactly ONE terminal span, not a duplicate ok-then-error pair" "ASYNC_FAILURE_AFTER_STOP_SINGLE_SPAN_OK true" "$tmpl_stt_out"
check "#474 (reviewer-454 finding): a stale/superseded turn's late result is dropped outright -- never stops the CURRENTLY live engine, never touches its span id" "STALE_TURN_RESULT_DROPPED_OK true" "$tmpl_stt_out"
check "#474 (reviewer-454 finding): the currently active turn still delivers completely normally once its own result arrives" "LIVE_TURN_STILL_DELIVERS_OK true" "$tmpl_stt_out"
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
