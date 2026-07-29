#!/usr/bin/env bash
# section-assistant-voice-tts.sh -- AST-050: TTS wiring (SPEC-ASSISTANT.md
# §13.1/§13.3, issue #332, docs/design/ast-E5.md). Sourced by run-tests.sh;
# do not run standalone. Contract: the runner already defines set -uo
# pipefail and has sourced _lib.sh (check/check_rc/check_absent) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# AST-050 does not touch engine.py itself (§13.2 keeps the engine text-in/
# text-out); it DOES call the real server-posting emitVoiceSpan() bridge
# AST-051 (#333) added (POST /assistant/voice-event -> engine.py's
# _emit_trace, single writer, no new table). speakReply() wires the
# EXISTING speechSynthesis pipeline (SpeechSynthSource/window.neuralVoice,
# built by the #395/#397/#399/#402 voice-panel series) into the chat
# overlay's reply path, reusing the same echo-guard
# (voiceSources.outbound.speaking) unchanged -- never a second speech
# stack. Same "extract() + eval() named functions against stubs" harness
# style as section-assistant-chat.sh / section-assistant-inspector.sh; the
# class-level extraction (SpeechSynthSource) below mirrors that same
# non-greedy "\n}\n" convention, which only matches a COLUMN-0 closing
# brace -- i.e. the function/class's own closing brace, never a nested
# (indented) one -- so it depends on the template's consistent
# indentation, exactly like every other extract() in this suite.
#
# Fix-up (post-AST-051 rebase, cross-branch collision review): AST-050 and
# AST-051 both originally defined a top-level `function emitVoiceSpan` --
# AST-051's is the real one (posts to the server); AST-050's page-local
# array pusher is renamed here to trackLocalVoiceSpan to avoid the two
# same-named functions silently shadowing one another on merge (051 hoists
# last -- its STT spans would otherwise scramble against 050's args).
# speakReply now calls BOTH: emitVoiceSpan() for the real trace record,
# trackLocalVoiceSpan() to keep window.assistantVoiceSpans (the inspector's
# own client-side merge, which the server-recorded span carries no turn_id
# for) working.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant voice TTS wiring (AST-050: TTS wiring, SPEC-ASSISTANT.md §13.1/§13.3, issue #332) =="

NVHTML_VOICE="$PLUGIN/templates/neural-view.html"

echo "-- template: speakReply gating, chunking, span emission (window.neuralVoice stubbed) --"
_av_node="$(mktemp).cjs"
cat >"$_av_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

global.window = global;
let uiState = { vdir: "out" };
window.assistantGate = { gated: false };
let neuralVoiceCalls = [];
window.neuralVoice = {
    speakChunks(chunks, onDone){ neuralVoiceCalls.push({chunks, onDone}); },
};
// emitVoiceSpan (AST-051, #333) posts to /assistant/voice-event -- stub
// fetch so speakReply's calls into it don't hit a real server.
let voiceEventPosts = [];
global.fetch = async (url, opts) => {
    if (url === "/assistant/voice-event") {
        voiceEventPosts.push({ url, body: JSON.parse((opts && opts.body) || "{}") });
    }
    return { status: 200, json: async () => ({ ok: true }) };
};

eval(extract("voiceDir"));
eval(extract("voiceOn"));
eval(extract("chunkSpeechText"));
eval(extract("emitVoiceSpan"));
eval(extract("trackLocalVoiceSpan"));
eval(extract("newClientTurnId"));
// #491 review finding 1: speakReply's echo-guard interlock now clears the
// live-STT pending bubble -- stubbed no-op here (the real function is
// exercised in section-assistant-voice-turn.sh's second harness).
global.sttRemovePendingBubble = () => {};
eval(extract("speakReply"));

function reset(){
    neuralVoiceCalls = [];
    voiceEventPosts = [];
    window.assistantVoiceSpans = [];
    window.assistantGate = { gated: false };
    uiState = { vdir: "out" };
}

(async () => {
    // ---- chunkSpeechText: sentence-boundary split (§13.3 chunk-at-
    // sentence-boundary quirk workaround) ----
    const chunks = chunkSpeechText("First sentence. Second sentence! Third sentence? Fourth");
    if (JSON.stringify(chunks) !== JSON.stringify(["First sentence.", "Second sentence!", "Third sentence?", "Fourth"]))
        throw new Error("chunking mismatch: " + JSON.stringify(chunks));
    console.log("CHUNK_OK true");
    if (chunkSpeechText("   ").length !== 0) throw new Error("blank text should chunk to nothing");
    console.log("CHUNK_EMPTY_OK true");

    // ---- voiceOn: mirrors the header direction state (out/both = on) ----
    uiState.vdir = "out";
    if (!voiceOn()) throw new Error("voiceOn() should be true for direction=out");
    uiState.vdir = "both";
    if (!voiceOn()) throw new Error("voiceOn() should be true for direction=both");
    uiState.vdir = "in";
    if (voiceOn()) throw new Error("voiceOn() should be false for direction=in");
    console.log("VOICE_ON_DIR_OK true");

    // ---- newClientTurnId: distinct ids (engine returns none, §13.2) ----
    const id1 = newClientTurnId(), id2 = newClientTurnId();
    if (!id1 || !id2 || id1 === id2) throw new Error("newClientTurnId must mint distinct non-empty ids");
    console.log("TURN_ID_OK true");

    // ---- speakReply: no-op when voice is off ----
    reset();
    uiState.vdir = "in";
    speakReply("hello there.", "t1");
    if (neuralVoiceCalls.length !== 0) throw new Error("voice-off must not call speakChunks");
    if (window.assistantVoiceSpans.length !== 0) throw new Error("voice-off must not emit local spans");
    if (voiceEventPosts.length !== 0) throw new Error("voice-off must not POST /assistant/voice-event");
    console.log("NOOP_VOICE_OFF_OK true");

    // ---- speakReply: no-op when gated (§17.9, no assistant selected) ----
    reset();
    window.assistantGate = { gated: true };
    speakReply("hello there.", "t1");
    if (neuralVoiceCalls.length !== 0) throw new Error("gated must not call speakChunks");
    if (window.assistantVoiceSpans.length !== 0) throw new Error("gated must not emit local spans");
    if (voiceEventPosts.length !== 0) throw new Error("gated must not POST /assistant/voice-event");
    console.log("NOOP_GATED_OK true");

    // ---- speakReply: no-op on empty/blank text ----
    reset();
    speakReply("   ", "t1");
    if (neuralVoiceCalls.length !== 0) throw new Error("empty text must not call speakChunks");
    console.log("NOOP_EMPTY_OK true");

    // ---- speakReply: voice on + selected -> queues chunks, emits tts-start ----
    reset();
    speakReply("First sentence. Second sentence.", "turn-abc");
    if (neuralVoiceCalls.length !== 1) throw new Error("expected exactly one speakChunks call, got " + neuralVoiceCalls.length);
    if (JSON.stringify(neuralVoiceCalls[0].chunks) !== JSON.stringify(["First sentence.", "Second sentence."]))
        throw new Error("chunks passed to speakChunks mismatch: " + JSON.stringify(neuralVoiceCalls[0].chunks));
    if (window.assistantVoiceSpans.length !== 1) throw new Error("expected exactly one LOCAL span so far (tts-start)");
    const startEv = window.assistantVoiceSpans[0];
    if (startEv.kind !== "tts-start" || startEv.turn_id !== "turn-abc") throw new Error("tts-start local span shape wrong: " + JSON.stringify(startEv));
    if (startEv.chars !== "First sentence. Second sentence.".length) throw new Error("tts-start chars mismatch: " + JSON.stringify(startEv));
    // the REAL span, via emitVoiceSpan() -> POST /assistant/voice-event (AST-051's bridge)
    if (voiceEventPosts.length !== 1) throw new Error("expected exactly one /assistant/voice-event POST (tts-start), got " + voiceEventPosts.length);
    if (voiceEventPosts[0].body.kind !== "tts-start") throw new Error("voice-event POST kind mismatch: " + JSON.stringify(voiceEventPosts[0].body));
    if (voiceEventPosts[0].body.payload.spanId !== "turn-abc") throw new Error("voice-event POST spanId should carry the turn id: " + JSON.stringify(voiceEventPosts[0].body));
    console.log("SPEAK_START_OK true");

    // ---- onDone fires tts-end with the SAME turn id and a status, on BOTH the local array and the real bridge ----
    neuralVoiceCalls[0].onDone("end");
    if (window.assistantVoiceSpans.length !== 2) throw new Error("expected a second LOCAL span (tts-end) after onDone");
    const endEv = window.assistantVoiceSpans[1];
    if (endEv.kind !== "tts-end" || endEv.turn_id !== "turn-abc") throw new Error("tts-end local span shape wrong: " + JSON.stringify(endEv));
    if (endEv.status !== "end") throw new Error("tts-end status not forwarded to the local span: " + JSON.stringify(endEv));
    if (voiceEventPosts.length !== 2) throw new Error("expected a second /assistant/voice-event POST (tts-end), got " + voiceEventPosts.length);
    if (voiceEventPosts[1].body.kind !== "tts-end" || voiceEventPosts[1].body.status !== "end") throw new Error("voice-event tts-end POST shape wrong: " + JSON.stringify(voiceEventPosts[1].body));
    console.log("SPEAK_END_OK true");

    // ---- never-latch: an error status still resolves a tts-end span (local AND real bridge) ----
    reset();
    speakReply("Only one sentence.", "turn-err");
    neuralVoiceCalls[0].onDone("error");
    const errEnd = window.assistantVoiceSpans.find(e => e.kind === "tts-end");
    if (!errEnd || errEnd.status !== "error") throw new Error("error path must still emit a local tts-end span: " + JSON.stringify(window.assistantVoiceSpans));
    const errPost = voiceEventPosts.find(p => p.body.kind === "tts-end");
    if (!errPost || errPost.body.status !== "error") throw new Error("error path must still POST a tts-end voice-event: " + JSON.stringify(voiceEventPosts));
    console.log("NEVER_LATCH_ERROR_SPAN_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_voice_out="$(node "$_av_node" "$NVHTML_VOICE" 2>&1)"
tmpl_voice_rc=$?
rm -f "$_av_node"
check_rc "voice TTS wiring template script exits 0" 0 "$tmpl_voice_rc"
check "template: sentence-boundary chunking splits a multi-sentence reply" "CHUNK_OK true" "$tmpl_voice_out"
check "template: blank text chunks to nothing" "CHUNK_EMPTY_OK true" "$tmpl_voice_out"
check "template: voiceOn() mirrors the OUT/BOTH direction state" "VOICE_ON_DIR_OK true" "$tmpl_voice_out"
check "template: newClientTurnId mints distinct ids" "TURN_ID_OK true" "$tmpl_voice_out"
check "template: speakReply no-ops when voice is off (direction=in)" "NOOP_VOICE_OFF_OK true" "$tmpl_voice_out"
check "template: speakReply no-ops when gated (no assistant selected, §17.9)" "NOOP_GATED_OK true" "$tmpl_voice_out"
check "template: speakReply no-ops on empty/blank text" "NOOP_EMPTY_OK true" "$tmpl_voice_out"
check "template: speakReply queues chunks and emits a tts-start span" "SPEAK_START_OK true" "$tmpl_voice_out"
check "template: speakChunks onDone emits a matching tts-end span" "SPEAK_END_OK true" "$tmpl_voice_out"
check "template: an error status still resolves a tts-end span (echo guard never latches)" "NEVER_LATCH_ERROR_SPAN_OK true" "$tmpl_voice_out"
if [[ "$tmpl_voice_rc" -ne 0 ]]; then echo "$tmpl_voice_out" >&2; fi

echo "-- template: SpeechSynthSource.speakChunks -- echo guard spans the whole reply and never latches --"
_ss_node="$(mktemp).cjs"
cat >"$_ss_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extractClass(name) {
    const re = new RegExp("class " + name + "\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find class " + name + " in template");
    return m[0];
}

let pendingUtterances;
global.SpeechSynthesisUtterance = function(text){ this.text = text; this.onstart = null; this.onend = null; this.onerror = null; };
let cancelCalls = 0;
global.speechSynthesis = {
    speak(u){ pendingUtterances.push(u); },
    cancel(){ cancelCalls++; },
};

// `eval` of a bare `class Foo{...}` declaration does NOT leak a usable
// binding once eval() returns -- unlike function declarations, class
// declarations are lexically (block-)scoped to the eval's own transient
// scope. Assigning the extracted class EXPRESSION onto `global` sidesteps
// that (Node resolves bare identifiers against the global object too).
eval("global.SpeechSynthSource = " + extractClass("SpeechSynthSource"));

(async () => {
    // ---- normal sequence: speaking spans ALL chunks, drops once at the end ----
    pendingUtterances = [];
    let src = new SpeechSynthSource();
    let doneCalls = [];
    src.speakChunks(["a.", "b.", "c."], (status)=>doneCalls.push(status));
    if (pendingUtterances.length !== 3) throw new Error("expected 3 queued utterances, got " + pendingUtterances.length);
    if (!src.speaking) throw new Error("speaking must be true immediately after speakChunks");
    pendingUtterances[0].onend();
    if (!src.speaking) throw new Error("speaking must stay true after a NON-last chunk ends (no gap in the echo guard)");
    if (doneCalls.length !== 0) throw new Error("onDone must not fire before the LAST chunk ends");
    pendingUtterances[1].onend();
    if (!src.speaking) throw new Error("speaking must still be true after the second (still non-last) chunk ends");
    pendingUtterances[2].onend();
    if (src.speaking) throw new Error("speaking must drop once the LAST chunk ends");
    if (JSON.stringify(doneCalls) !== JSON.stringify(["end"])) throw new Error("onDone must fire exactly once, with status 'end': " + JSON.stringify(doneCalls));
    console.log("SEQUENCE_SPANS_WHOLE_REPLY_OK true");

    // ---- never-latch: an error on a NON-last chunk drops the guard immediately ----
    pendingUtterances = [];
    src = new SpeechSynthSource();
    doneCalls = [];
    src.speakChunks(["a.", "b.", "c."], (status)=>doneCalls.push(status));
    pendingUtterances[0].onerror();
    if (src.speaking) throw new Error("an error must drop the guard immediately, not wait for later chunks");
    if (JSON.stringify(doneCalls) !== JSON.stringify(["error"])) throw new Error("onDone must fire once with 'error': " + JSON.stringify(doneCalls));
    // later chunks resolving/erroring after the sequence already finished must not re-fire onDone
    pendingUtterances[1].onend();
    pendingUtterances[2].onerror();
    if (doneCalls.length !== 1) throw new Error("onDone must never fire more than once per sequence: " + JSON.stringify(doneCalls));
    console.log("NEVER_LATCH_ON_ERROR_OK true");

    // ---- never-latch: stop() mid-sequence (the page-hide path) resolves the guard ----
    pendingUtterances = [];
    src = new SpeechSynthSource();
    doneCalls = [];
    cancelCalls = 0;
    src.speakChunks(["a.", "b."], (status)=>doneCalls.push(status));
    src.stop();
    if (src.speaking) throw new Error("stop() must drop the guard immediately");
    if (cancelCalls !== 1) throw new Error("stop() must cancel the underlying speechSynthesis queue");
    if (JSON.stringify(doneCalls) !== JSON.stringify(["cancel"])) throw new Error("onDone must fire once with 'cancel': " + JSON.stringify(doneCalls));
    // a stray late callback (a chunk already in flight) must not re-fire onDone
    pendingUtterances[0].onend();
    if (doneCalls.length !== 1) throw new Error("a late callback after stop() must not re-fire onDone");
    console.log("NEVER_LATCH_ON_STOP_OK true");

    // ---- an empty chunk list resolves immediately without ever raising the guard ----
    src = new SpeechSynthSource();
    doneCalls = [];
    src.speakChunks([], (status)=>doneCalls.push(status));
    if (src.speaking) throw new Error("an empty chunk list must never raise the guard");
    if (JSON.stringify(doneCalls) !== JSON.stringify(["empty"])) throw new Error("empty chunk list must resolve onDone with 'empty': " + JSON.stringify(doneCalls));
    console.log("EMPTY_CHUNKS_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_ss_out="$(node "$_ss_node" "$NVHTML_VOICE" 2>&1)"
tmpl_ss_rc=$?
rm -f "$_ss_node"
check_rc "SpeechSynthSource.speakChunks template script exits 0" 0 "$tmpl_ss_rc"
check "template: speaking spans the whole chunked reply, not per-chunk gaps" "SEQUENCE_SPANS_WHOLE_REPLY_OK true" "$tmpl_ss_out"
check "template: an utterance error on any chunk drops the echo guard immediately (never latches)" "NEVER_LATCH_ON_ERROR_OK true" "$tmpl_ss_out"
check "template: stop() (the page-hide path) resolves the guard and cancels speech" "NEVER_LATCH_ON_STOP_OK true" "$tmpl_ss_out"
check "template: an empty chunk list never raises the guard" "EMPTY_CHUNKS_OK true" "$tmpl_ss_out"
if [[ "$tmpl_ss_rc" -ne 0 ]]; then echo "$tmpl_ss_out" >&2; fi

echo "-- template: chat-overlay wiring, page-hide never-latch hook, hook name pinned, trace-stream join --"
check "template pins the speakReply(text, turnId) hook signature (E5 owns it, E6's §12.5 announce calls it later)" "function speakReply(text, turnId)" "$(cat "$NVHTML_VOICE")"
check "template wires a rendered chat reply to speakReply (AST-023 overlay -> AST-050 TTS)" "speakReply(payload.text" "$(cat "$NVHTML_VOICE")"
check "template's page-hide path drops the echo guard via the same stop() never-latch route" "voiceSources.outbound.stop()" "$(cat "$NVHTML_VOICE")"
check "template binds handleVoicePageHide to the pagehide event" 'addEventListener("pagehide", handleVoicePageHide)' "$(cat "$NVHTML_VOICE")"
check "template joins §13.3 voice spans into the SAME trace stream the inspector renders (groupTurnsById)" "assistantVoiceSpans" "$(cat "$NVHTML_VOICE")"
check "speakReply routes both spans through the REAL emitVoiceSpan bridge (AST-051, #333), not a second writer" 'emitVoiceSpan("tts-start"' "$(cat "$NVHTML_VOICE")"
check "the template defines emitVoiceSpan exactly once (no re-introduced 050/051 name collision)" "1" "$(grep -c '^function emitVoiceSpan' "$NVHTML_VOICE")"
# issue #337 (AST-062) review: the "this branch adds no further engine.py
# changes vs origin/main" check that used to live here was a ONE-TIME PR
# review assertion for AST-050's own diff (proving AST-050 itself didn't
# sneak engine.py changes in beyond what AST-051 already added) -- valid
# only at AST-050's own merge time, which is long since settled history
# now that AST-050/2a8277a is on origin/main. Implemented as a live "git
# diff origin/main -- engine.py" on WHATEVER branch happens to be checked
# out, it silently became a permanent "no branch may ever touch engine.py
# again" gate -- which is false and directly contradicts
# docs/design/ast-E6.md's own plan ("engine.py -- E6 tasks ... route
# capability-invocation requests from turns.py through the index +
# adapters"). AST-062 (issue #337) is the first branch to need a
# legitimate engine.py change since AST-050 merged (threading
# unavailable_reason into `_roster_provider_for`'s roster dict) and was
# wrongly blocked by this stale, over-broad invariant. Removed rather than
# reimplemented scoped-to-AST-050, since that historical fact is already
# permanently recorded in origin/main and has nothing further to verify.
