#!/usr/bin/env bash
# section-assistant-chat.sh -- AST-023: T-key chat overlay (SPEC-ASSISTANT.md
# §8.6, §5, §8.3, §8.5, issue #320). Sourced by run-tests.sh; do not run
# standalone. Contract: the runner already defines set -uo pipefail and has
# sourced _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/
# fails/flaky before sourcing this file. This file assumes those are already
# in scope.
#
# Template-only: no engine change was needed for this task -- POST
# /assistant/chat's response already carries `chips` (turns.py's
# `_chips_from_recall`, wired since AST-013/#311, §8.3), and §8.5's
# auth-expired/adapter-error text is already the `error` field on a
# non-2xx response (engine.py's `_chat`). This section therefore only
# extracts and exercises the template's chat-overlay functions, the same
# "extract() + eval() named functions against a stubbed DOM+fetch" harness
# style as section-assistant-selection.sh / section-assistant-selection-
# memory.sh.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant chat overlay (AST-023: T-key chat overlay, SPEC-ASSISTANT.md §8.6, issue #320) =="

echo "-- template: T opens/Esc closes, send/queue/elapsed/chips/gated/offline/auth/last-X --"
NVHTML_CHAT="$PLUGIN/templates/neural-view.html"

_ac_node="$(mktemp).cjs"
cat >"$_ac_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
// #481: isChatLogAtBottom (below) reads the top-level CHAT_SCROLL_BOTTOM_
// SLACK_PX const -- same extractConst/defineConst pattern as section-
// assistant-stt.sh, since a direct eval() of a `const` doesn't leak a
// binding out to this scope the way a `function` declaration does.
function extractConst(name) {
    const re = new RegExp("const " + name + " = [^\\n]*\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find const " + name + " in template");
    return m[0];
}
function defineConst(name) {
    const src = extractConst(name).trim().replace(/^const\s+\S+\s*=\s*/, "").replace(/;$/, "");
    global[name] = eval("(" + src + ")");
}

// DOM stub, same shape as section-assistant-selection.sh's, extended with
// `value` (the chat input is a real <input>) and a `document.body` root
// the overlay is appended into (T's dialog is not scoped to voicebar).
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
        // #481: minimal scroll-position model for the ∞ show-last option --
        // scrollHeight is rows * a per-row pixel unit (40, a plausible
        // bubble height) so CHAT_SCROLL_BOTTOM_SLACK_PX's 4px slack is
        // clearly smaller than one row, letting "at bottom" vs "scrolled
        // up" tests actually distinguish rather than the slack accidentally
        // swallowing a whole row. clientHeight is a fixed fake viewport
        // (fits ~3 rows). scrollTop counts writes (_scrollWrites) so review
        // round 1 finding 2's "exactly one scroll write per rebuild" is a
        // real counterfactual-checkable assertion, not just a final-
        // position check that would pass even with N redundant writes.
        // Same "just enough to observe the production branch" spirit as
        // #480's focus()/activeElement stub.
        _scrollTop: 0,
        _scrollWrites: 0,
        get scrollTop(){ return this._scrollTop; },
        set scrollTop(v){ this._scrollTop = v; this._scrollWrites++; },
        get scrollHeight(){ return this._items.length * 40; },
        clientHeight: 120,
        // #480: a real disabled control silently refuses focus() -- mirror
        // just that half here, since it's the half production code
        // (focusChatInput, see the template) actually branches on. This
        // stub does NOT model the OTHER real-browser half (disabling the
        // currently-focused element auto-blurs it back to body) -- the
        // gated-overlay test below stands in for that manually (the
        // `document.activeElement = document.body;` line right after the
        // input gets disabled) rather than teaching the stub to do it.
        focus(){ if (!this.disabled) document.activeElement = this; },
        // Real DOM `.children` is a LIVE HTMLCollection: `length` is an
        // accessor with a getter and NO setter -- `el.children.length = 0`
        // throws a TypeError, it does not truncate. `_items` is the real
        // backing array; the Proxy wraps it so reads/iteration (map/find/
        // index access) forward normally, but any external `set` (the
        // exact "children.length = 0" bug shape) throws instead of
        // silently mutating -- appendChild/innerHTML= below mutate
        // `_items` directly (bypassing the proxy), which is how growth
        // and clearing are actually supposed to happen.
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
        setAttribute(k, v){ this[k === "class" ? "className" : k] = v; this["_attr_" + k] = v; },
        getAttribute(k){ return this["_attr_" + k] !== undefined ? this["_attr_" + k] : null; },
    };
    if (initialId) elements[initialId] = el;
    return el;
}
const bodyEl = mkEl(null);
bodyEl.classList._parent = bodyEl;
const document = {
    body: bodyEl,
    // #480: activeElement starts at body, same as a real page with nothing
    // focused yet -- the exact starting condition the issue's live repro
    // described (T pressed with activeElement still BODY).
    activeElement: bodyEl,
    getElementById(id) {
        return elements[id] || null;
    },
    createElement(_tag) {
        const el = mkEl(null);
        el.classList._parent = el;
        return el;
    },
};
global.window = global;

// AST-050 (#332): dispatchNextChat's success branch now calls
// speakReply(payload.text, newClientTurnId()) -- stub the voice-wiring
// dependencies it transitively needs (uiState.vdir for voiceDir/voiceOn,
// window.assistantGate for the §17.9 gate check, window.neuralVoice as
// the outbound adapter) so this harness's extracted dispatchNextChat
// doesn't ReferenceError. neuralSpeakCalls lets a couple of assertions
// below confirm the wire-up actually fires on a rendered reply.
let uiState = {};
window.assistantGate = { gated: false };
let neuralSpeakCalls = [];
window.neuralVoice = { speakChunks(chunks, onDone){ neuralSpeakCalls.push({chunks, onDone}); } };

let fetchCalls = [];
let statusResponse = null;
let statusThrows = false;
let historyResponse = { exchanges: [], warnings: [] };
let pendingChat = [];
global.fetch = async (url, opts) => {
    fetchCalls.push({url, opts});
    if (url === "/assistant/status") {
        if (statusThrows) throw new Error("network down");
        return { status: 200, json: async () => statusResponse };
    }
    if (url.indexOf("/assistant/history") === 0) {
        return { status: 200, json: async () => historyResponse };
    }
    if (url === "/assistant/chat") {
        return new Promise((resolve) => { pendingChat.push({url, opts, resolve}); });
    }
    return { status: 200, json: async () => ({}) };
};
function resolveChat(i, status, payload) {
    pendingChat[i].resolve({ status, json: async () => payload });
}
function chatFetchCalls() {
    return fetchCalls.filter(c => c.url === "/assistant/chat");
}
async function flush() {
    for (let i = 0; i < 6; i++) await new Promise(r => setImmediate(r));
}

eval(extract("chatElapsedText"));
eval(extract("isChatTypingTarget"));
// #481 (review round 1, finding 1): appendChatRow's sticky-bottom check
// calls isChatLogAtBottom, which reads the top-level
// CHAT_SCROLL_BOTTOM_SLACK_PX const -- define the const, then the
// function, before extracting appendChatRow/renderChatLog (both call
// scrollChatLogToBottom) so eval-ing them doesn't ReferenceError.
defineConst("CHAT_SCROLL_BOTTOM_SLACK_PX");
eval(extract("isChatLogAtBottom"));
eval(extract("scrollChatLogToBottom"));
// 2026-07-29: appendChatRow enriches assistant rows through the notes
// renderer (chatEnrichObserver/enrichChatRowMarkdown) -- stubbed inert
// here; the render POST path is exercised against the live server, not
// this DOM stub.
global.chatEnrichObserver = () => false;
global.enrichChatRowMarkdown = () => {};
eval(extract("appendChatRow"));
eval(extract("renderChatLog"));
eval(extract("renderChatLastXToggle"));
// show-last persistence (2026-07-29): setChatLastX persists via uiState/
// saveUiState -- same stub contract other harnesses use.
if (typeof global.uiState === "undefined") global.uiState = {};
if (typeof global.saveUiState === "undefined") global.saveUiState = function(){ try{ localStorage.setItem("nv-ui", JSON.stringify(global.uiState)); }catch{} };
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
// #491 review finding 1: speakReply's echo-guard interlock now clears the
// live-STT pending bubble -- stubbed no-op here (the real function is
// exercised in section-assistant-voice-turn.sh's second harness).
global.sttRemovePendingBubble = () => {};
// barge-in (2026-07-29): speakReply arms/disarms the barge watcher --
// stubbed no-ops here (audio-level behavior is out of this harness's scope).
global.voiceBargeWatchStart = () => {};
global.voiceBargeWatchStop = () => {};
// speech sanitizer (2026-07-29): spoken text is cleaned of markdown/code
// syntax -- extract the REAL function so speakReply's chunking behavior
// stays exercised end-to-end (plain text passes through unchanged).
eval(extract("speechTextForReply"));
eval(extract("speakReply"));
eval(extract("dispatchNextChat"));
eval(extract("queueOrSendChat"));
// AST-083 (#459): chatInputKeydown now calls the shared sendChatInput()
// dispatch (also used by the composer's Send button) -- extract it first.
eval(extract("sendChatInput"));
eval(extract("chatInputKeydown"));
eval(extract("loadChatHistory"));
// #480: openChatOverlay's fix calls focusChatInput() -- extract it first.
eval(extract("focusChatInput"));
// 2026-07-29: openChatOverlay resolves the selected assistant's media
// context (setAssistantMediaCtx) from the status payload -- stubbed as a
// recorder here.
global.setAssistantMediaCtx = () => {};
// detach/dock (2026-07-29): openChatOverlay restores the persisted state
// via setChatDetached -- stubbed as a recorder; geometry/drag behavior is
// a real-browser concern, not this DOM stub's.
global.setChatDetached = () => {};
global.syncChatDockBodyClass = () => {};
// #485: tabs + status keep-in-step -- recorders here.
global.renderChatAssistantTabs = () => {};
global.startChatStatusSync = () => {};
eval(extract("openChatOverlay"));
if (typeof global.syncChatDockBodyClass === "undefined") global.syncChatDockBodyClass = () => {};
if (typeof global.stopChatStatusSync === "undefined") global.stopChatStatusSync = () => {};
if (typeof global.syncChatDockBodyClass === "undefined") global.syncChatDockBodyClass = () => {};
eval(extract("closeChatOverlay"));
eval(extract("handleAssistantChatKeydown"));

function resetChat() {
    if (elements["ast-chat-overlay"]) elements["ast-chat-overlay"].remove();
    delete elements["ast-chat-overlay"];
    delete elements["ast-chat-log"];
    delete elements["ast-chat-state"];
    delete elements["ast-chat-input"];
    delete elements["ast-chat-lastx"];
    delete elements["ast-chat-retry"];
    bodyEl._items.length = 0;
    document.activeElement = bodyEl;
    fetchCalls = [];
    pendingChat = [];
    statusThrows = false;
    statusResponse = {outcome: "one", candidates: [{name: "jarvis", aliases: [], root: "/r"}], selected: "jarvis", gated: false, askAgain: false};
    historyResponse = { exchanges: [], warnings: [] };
    window.assistantChat = { queue: [], inFlight: false, exchanges: [], lastX: 2, elapsedTimer: null, elapsedStart: 0 };
    uiState = {};
    window.assistantGate = { gated: false };
    neuralSpeakCalls = [];
    window.assistantVoiceSpans = [];
}

(async () => {
    // ---- pure: elapsed-text ticking logic ----
    if (chatElapsedText(1000, 1000) !== "0s") throw new Error("elapsed 0s mismatch");
    if (chatElapsedText(1000, 4200) !== "3s") throw new Error("elapsed 3s mismatch: " + chatElapsedText(1000, 4200));
    console.log("ELAPSED_PURE_OK true");

    // ---- T opens outside inputs; not when focus is in an input ----
    resetChat();
    await handleAssistantChatKeydown({key: "t", target: {tagName: "DIV"}, preventDefault(){}});
    if (!document.getElementById("ast-chat-overlay")) throw new Error("T did not open the overlay");
    if (!document.getElementById("ast-chat-overlay").className.includes("ast-chat-overlay")) throw new Error("overlay missing ast-chat-overlay class");
    console.log("OPEN_OK true");

    resetChat();
    await handleAssistantChatKeydown({key: "t", target: {tagName: "INPUT"}, preventDefault(){}});
    if (document.getElementById("ast-chat-overlay")) throw new Error("T inside an input must not open the overlay");
    console.log("NO_OPEN_IN_INPUT_OK true");

    // ---- #480: T-key open leaves keyboard focus in the input, so the user can type immediately ----
    resetChat();
    await handleAssistantChatKeydown({key: "t", target: {tagName: "DIV"}, preventDefault(){}});
    const focusedInput = document.getElementById("ast-chat-input");
    if (document.activeElement !== focusedInput) throw new Error("T-key open must focus #ast-chat-input, activeElement was " + (document.activeElement && document.activeElement.id));
    console.log("TKEY_FOCUSES_INPUT_OK true");

    // ---- #480: the "t" that opened the overlay must never land in the input -- preventDefault fires, and the input stays empty ----
    resetChat();
    let tKeydownPrevented = false;
    await handleAssistantChatKeydown({key: "t", target: {tagName: "DIV"}, preventDefault(){ tKeydownPrevented = true; }});
    if (!tKeydownPrevented) throw new Error("T-key open must call preventDefault so the 't' character never reaches the input");
    if (document.getElementById("ast-chat-input").value !== "") throw new Error("input must stay empty -- the 't' that opened the overlay must not land in the composer, got " + JSON.stringify(document.getElementById("ast-chat-input").value));
    console.log("TKEY_PREVENTS_T_IN_INPUT_OK true");

    // ---- #480: re-pressing T on an already-open overlay re-focuses the input (acceptable per the AC; focusing an already-open overlay's input is fine) ----
    resetChat();
    await handleAssistantChatKeydown({key: "t", target: {tagName: "DIV"}, preventDefault(){}});
    const reopenInput = document.getElementById("ast-chat-input");
    document.activeElement = document.body;
    handleAssistantChatKeydown({key: "t", target: {tagName: "DIV"}, preventDefault(){}});
    if (document.activeElement !== reopenInput) throw new Error("re-pressing T on an already-open overlay must re-focus the input, activeElement was " + (document.activeElement && document.activeElement.id));
    console.log("TKEY_REOPEN_REFOCUSES_OK true");

    // ---- #480: a disabled (gated) input must never be stolen back into focus by a repeated T ----
    resetChat();
    statusResponse = {outcome: "multiple", candidates: [], selected: null, gated: true, askAgain: true};
    await handleAssistantChatKeydown({key: "t", target: {tagName: "DIV"}, preventDefault(){}});
    const gatedInput = document.getElementById("ast-chat-input");
    if (!gatedInput.disabled) throw new Error("setup: gated overlay must disable the input");
    // the stub has no auto-blur-on-disable (a real browser would already
    // have moved focus off gatedInput the instant it was disabled) -- reset
    // by hand so the assertion below is testing the repeated-T call, not a
    // stub gap.
    document.activeElement = document.body;
    handleAssistantChatKeydown({key: "t", target: {tagName: "DIV"}, preventDefault(){}});
    if (document.activeElement === gatedInput) throw new Error("re-pressing T must not focus a disabled (gated) input");
    console.log("TKEY_SKIPS_FOCUS_ON_DISABLED_INPUT_OK true");

    // ---- #480: focusChatInput() is a no-op (never throws, never touches focus) when #ast-chat-input doesn't exist ----
    resetChat();
    document.activeElement = document.body;
    focusChatInput();
    if (document.activeElement !== document.body) throw new Error("focusChatInput with no #ast-chat-input element must leave activeElement untouched, got " + (document.activeElement && document.activeElement.id));
    console.log("FOCUS_HELPER_MISSING_INPUT_NOOP_OK true");

    // ---- #480: queueOrSendChat's voice auto-open path also focuses the input, same as the T-key path ----
    resetChat();
    await queueOrSendChat("hello from voice", "turn-1", "voice");
    const voiceInput = document.getElementById("ast-chat-input");
    if (document.activeElement !== voiceInput) throw new Error("queueOrSendChat's voice auto-open must focus the input, activeElement was " + (document.activeElement && document.activeElement.id));
    console.log("VOICE_AUTOOPEN_FOCUSES_INPUT_OK true");
    resolveChat(chatFetchCalls().length - 1, 200, {text: "ok", chips: [], warnings: []});
    await flush();

    // ---- Esc closes ----
    resetChat();
    await handleAssistantChatKeydown({key: "t", target: {tagName: "DIV"}, preventDefault(){}});
    if (!document.getElementById("ast-chat-overlay")) throw new Error("setup: overlay did not open");
    handleAssistantChatKeydown({key: "Escape", target: {tagName: "DIV"}});
    if (document.getElementById("ast-chat-overlay")) throw new Error("Esc did not close the overlay");
    console.log("ESC_CLOSE_OK true");

    // ---- Enter dispatches POST with the message; reply renders with chips ----
    resetChat();
    await openChatOverlay();
    const input = document.getElementById("ast-chat-input");
    input.value = "hello";
    input.disabled = false;
    chatInputKeydown({key: "Enter", target: input, preventDefault(){}});
    const sendCalls = chatFetchCalls();
    if (sendCalls.length !== 1) throw new Error("Enter did not POST /assistant/chat, got " + sendCalls.length);
    if (JSON.parse(sendCalls[0].opts.body).message !== "hello") throw new Error("POST body did not carry the message");
    // elapsed state visible while the turn is in flight
    const stateWhileThinking = document.getElementById("ast-chat-state").textContent;
    if (!stateWhileThinking || stateWhileThinking.indexOf("s") === -1) throw new Error("elapsed state not shown while in flight: " + JSON.stringify(stateWhileThinking));
    console.log("ENTER_SEND_OK true");

    resolveChat(0, 200, {text: "hi there", chips: [{slug: "foo-bar", strength: 3}, {slug: "baz-qux", strength: null}], warnings: []});
    await flush();
    const log1 = document.getElementById("ast-chat-log");
    if (log1.children.length !== 2) throw new Error("expected 2 rows (user+assistant), got " + log1.children.length);
    if (log1.children[0].getAttribute("data-role") !== "user" || log1.children[0].textContent !== "hello") throw new Error("user row wrong");
    if (log1.children[1].getAttribute("data-role") !== "assistant" || log1.children[1].textContent !== "hi there") throw new Error("assistant row wrong");
    const chipsWrap = log1.children[1].children.find(c => c.className.includes("ast-chat-chips"));
    if (!chipsWrap) throw new Error("assistant row missing ast-chat-chips meta line");
    // #459 (Option A restyle, final slice -- human decision 2026-07-28):
    // recall chips are now a single quiet meta line, slugs joined with
    // " · " (middot), no per-item pill/span and no inline strength (that
    // would be expanded chip metadata -- explicitly out of scope; a
    // tooltip would be the place for it if ever wanted).
    if (chipsWrap.textContent !== "foo-bar · baz-qux") throw new Error("chips meta line text mismatch: " + JSON.stringify(chipsWrap.textContent));
    if (chipsWrap.children.length !== 0) throw new Error("chips meta line must not contain per-item child spans (quiet single-line treatment), got " + chipsWrap.children.length);
    if (document.getElementById("ast-chat-state").textContent !== "") throw new Error("elapsed state did not clear after the turn resolved");
    console.log("CHIPS_AND_CLEAR_OK true");

    // ---- AST-050 (#332): a rendered reply wires through speakReply ----
    if (neuralSpeakCalls.length !== 1) throw new Error("rendered reply should have called speakReply -> window.neuralVoice.speakChunks once, got " + neuralSpeakCalls.length);
    if (JSON.stringify(neuralSpeakCalls[0].chunks) !== JSON.stringify(["hi there"])) throw new Error("speakReply chunks mismatch: " + JSON.stringify(neuralSpeakCalls[0].chunks));
    console.log("VOICE_WIRED_OK true");

    // #453 (#454 P0 live-bug batch): the session's selected assistant
    // (window.__assistantSelected, mirrored by setVoiceHeaderName) must
    // thread through as engine.py's `assistant` flag on every chat
    // dispatch -- without it, a session with an assistant selected but no
    // MACHINE-level default and 2+ discovered candidates fell through to
    // a "no local default set" error even though the human had already
    // picked one and could see it in the voice-panel header.
    resetChat();
    await openChatOverlay();
    window.__assistantSelected = "megabrain";
    const selInput = document.getElementById("ast-chat-input");
    selInput.value = "with selection";
    selInput.disabled = false;
    chatInputKeydown({key: "Enter", target: selInput, preventDefault(){}});
    const selCall = chatFetchCalls()[chatFetchCalls().length - 1];
    if (JSON.parse(selCall.opts.body).assistant !== "megabrain") throw new Error("chat POST body must carry assistant: <selected> when window.__assistantSelected is set, got " + selCall.opts.body);
    console.log("SELECTED_ASSISTANT_THREADED_OK true");
    resolveChat(chatFetchCalls().length - 1, 200, {text: "ok", chips: [], warnings: []});
    await flush();

    // ---- backward compat: no selection known -> no `assistant` key at all (matches ENTER_SEND_OK above, asserted explicitly here too) ----
    // AST-083 (#459): openChatOverlay() now syncs window.__assistantSelected
    // from ITS OWN /assistant/status fetch every time it runs (see the
    // "who am I talking to" header, above) -- so the no-selection case must
    // be driven by the status STUB reporting no selection, not by presetting
    // the global and hoping openChatOverlay leaves it alone.
    resetChat();
    statusResponse.selected = null;
    await openChatOverlay();
    const noSelInput = document.getElementById("ast-chat-input");
    noSelInput.value = "no selection";
    noSelInput.disabled = false;
    chatInputKeydown({key: "Enter", target: noSelInput, preventDefault(){}});
    const noSelCall = chatFetchCalls()[chatFetchCalls().length - 1];
    const noSelBody = JSON.parse(noSelCall.opts.body);
    if ("assistant" in noSelBody) throw new Error("chat POST body must NOT carry an assistant key when nothing is selected (backward compat with the terminal's own flag/default resolution), got " + noSelCall.opts.body);
    console.log("NO_SELECTION_NO_ASSISTANT_KEY_OK true");
    resolveChat(chatFetchCalls().length - 1, 200, {text: "ok", chips: [], warnings: []});
    await flush();

    // ---- queued-while-thinking dispatch order ----
    resetChat();
    await openChatOverlay();
    queueOrSendChat("one");
    if (chatFetchCalls().length !== 1) throw new Error("first send should dispatch immediately");
    queueOrSendChat("two");
    if (chatFetchCalls().length !== 1) throw new Error("second send while thinking must queue, not dispatch: got " + chatFetchCalls().length);
    if (window.assistantChat.queue.length !== 1) throw new Error("queue should hold exactly the pending 'two'");
    const logQ = document.getElementById("ast-chat-log");
    if (logQ.children.length !== 1) throw new Error("only the dispatched 'one' bubble should render so far, got " + logQ.children.length);
    resolveChat(0, 200, {text: "reply1", chips: [], warnings: []});
    await flush();
    if (chatFetchCalls().length !== 2) throw new Error("queued 'two' did not dispatch after 'one' resolved");
    if (JSON.parse(chatFetchCalls()[1].opts.body).message !== "two") throw new Error("dispatch order wrong: expected 'two' second");
    resolveChat(1, 200, {text: "reply2", chips: [], warnings: []});
    await flush();
    const rows = logQ.children.map(c => [c.getAttribute("data-role"), c.textContent]);
    const expected = [["user","one"],["assistant","reply1"],["user","two"],["assistant","reply2"]];
    if (JSON.stringify(rows) !== JSON.stringify(expected)) throw new Error("final row order wrong: " + JSON.stringify(rows));
    console.log("QUEUE_ORDER_OK true");

    // ---- gated state (skip or none): refuses input, shows reason ----
    resetChat();
    statusResponse = {outcome: "multiple", candidates: [], selected: null, gated: true, askAgain: true};
    await openChatOverlay();
    if (!document.getElementById("ast-chat-input").disabled) throw new Error("gated overlay must disable input");
    const gatedText = document.getElementById("ast-chat-state").textContent;
    if (!gatedText || gatedText.toLowerCase().indexOf("skip") === -1) throw new Error("gated (skip) reason text missing: " + gatedText);
    if (fetchCalls.some(c => c.url.indexOf("/assistant/history") === 0)) throw new Error("gated overlay must not fetch history");
    console.log("GATED_SKIP_OK true");

    resetChat();
    statusResponse = {outcome: "none", candidates: [], selected: null, gated: true, askAgain: false};
    await openChatOverlay();
    const noneText = document.getElementById("ast-chat-state").textContent;
    if (!noneText || noneText.toLowerCase().indexOf("no assistant") === -1) throw new Error("gated (none) reason text missing: " + noneText);
    console.log("GATED_NONE_OK true");

    // ---- offline: /assistant/status fetch failure ----
    resetChat();
    statusThrows = true;
    await openChatOverlay();
    if (!document.getElementById("ast-chat-input").disabled) throw new Error("offline overlay must disable input");
    const offlineText = document.getElementById("ast-chat-state").textContent;
    if (!offlineText || offlineText.toLowerCase().indexOf("offline") === -1) throw new Error("offline message missing: " + offlineText);
    if (document.getElementById("ast-chat-retry").className.includes("ast-chat-hidden")) throw new Error("offline must show the retry affordance");
    console.log("OFFLINE_OK true");

    // ---- auth-expired: engine's §8.5 error text surfaced verbatim ----
    resetChat();
    await openChatOverlay();
    queueOrSendChat("hi");
    const authMsg = "codex authentication has expired or is missing -- run `codex login` and try again.";
    resolveChat(0, 502, {error: authMsg});
    await flush();
    const logA = document.getElementById("ast-chat-log");
    const sysRow = logA.children.find(c => c.getAttribute("data-role") === "system");
    if (!sysRow || sysRow.textContent !== authMsg) throw new Error("auth-expired text not surfaced verbatim: " + (sysRow && sysRow.textContent));
    console.log("AUTH_EXPIRED_OK true");

    // ---- last-X toggle (1-3) changes rendered count, purely client-side ----
    resetChat();
    historyResponse = { exchanges: [
        {ts: "t1", user: "a1", assistant: "b1", meta: {}},
        {ts: "t2", user: "a2", assistant: "b2", meta: {}},
        {ts: "t3", user: "a3", assistant: "b3", meta: {}},
        {ts: "t4", user: "a4", assistant: "b4", meta: {}},
    ], warnings: [] };
    await openChatOverlay();
    const logX = document.getElementById("ast-chat-log");
    if (logX.children.length !== 4) throw new Error("default lastX=2 should render 4 rows (2 exchanges), got " + logX.children.length);
    const fetchesBeforeToggle = fetchCalls.length;
    setChatLastX(1);
    if (logX.children.length !== 2) throw new Error("lastX=1 should render 2 rows, got " + logX.children.length);
    if (fetchCalls.length !== fetchesBeforeToggle) throw new Error("toggling lastX must not re-fetch, it re-renders the cached exchanges");
    const lastxWrap = document.getElementById("ast-chat-lastx");
    const activeBtn = lastxWrap.children.find(b => b.className.includes("ast-chat-lastx-active"));
    if (!activeBtn || activeBtn.textContent !== "1") throw new Error("lastX=1 button not marked active");
    setChatLastX(3);
    if (logX.children.length !== 6) throw new Error("lastX=3 should render 6 rows (3 of the 4 available exchanges), got " + logX.children.length);
    console.log("LASTX_OK true");

    // ---- #481: a fourth "∞" option renders after 1/2/3 ----
    resetChat();
    historyResponse = { exchanges: [
        {ts: "t1", user: "a1", assistant: "b1", meta: {}},
        {ts: "t2", user: "a2", assistant: "b2", meta: {}},
        {ts: "t3", user: "a3", assistant: "b3", meta: {}},
        {ts: "t4", user: "a4", assistant: "b4", meta: {}},
        {ts: "t5", user: "a5", assistant: "b5", meta: {}},
    ], warnings: [] };
    await openChatOverlay();
    const infWrap = document.getElementById("ast-chat-lastx");
    const infLabels = infWrap.children.map(b => b.textContent);
    if (JSON.stringify(infLabels) !== JSON.stringify(["1","2","3","∞"])) throw new Error("expected the show-last toggle to render [1,2,3,∞] in that order, got " + JSON.stringify(infLabels));
    console.log("INF_BUTTON_RENDERS_AFTER_123_OK true");

    // ---- #481: selecting ∞ shows ALL cached exchanges (more than 3 exist) ----
    const logInf = document.getElementById("ast-chat-log");
    setChatLastX("all");
    if (logInf.children.length !== 10) throw new Error("selecting ∞ should render all 5 cached exchanges (10 rows), got " + logInf.children.length);
    const infActive = infWrap.children.find(b => b.className.includes("ast-chat-lastx-active"));
    if (!infActive || infActive.textContent !== "∞") throw new Error("∞ button not marked active after selecting it, got " + (infActive && infActive.textContent));
    console.log("INF_SHOWS_ALL_OK true");

    // ---- #481: the numeric options keep slicing exactly as before, even after ∞ was active ----
    setChatLastX(2);
    if (logInf.children.length !== 4) throw new Error("switching back to lastX=2 after ∞ should render 4 rows (2 exchanges), got " + logInf.children.length);
    const numActive = infWrap.children.find(b => b.className.includes("ast-chat-lastx-active"));
    if (!numActive || numActive.textContent !== "2") throw new Error("lastX=2 button not marked active after switching back from ∞, got " + (numActive && numActive.textContent));
    console.log("NUM_AFTER_INF_OK true");

    // ---- #481: switching ∞ -> 2 -> ∞ re-renders correctly both ways ----
    setChatLastX("all");
    if (logInf.children.length !== 10) throw new Error("switching back to ∞ should again render all 10 rows, got " + logInf.children.length);
    console.log("INF_ROUNDTRIP_OK true");

    // ---- #481: ∞ must not be `slice(-Infinity)` in disguise -- it tracks the
    // LIVE exchanges cache, not a count fixed at the moment ∞ was selected.
    // (the fetch stub hands back `historyResponse` itself, not a JSON clone,
    // so `window.assistantChat.exchanges` IS `historyResponse.exchanges` --
    // pushing once here mutates both.) ----
    window.assistantChat.exchanges.push({user: "a6", assistant: "b6", chips: null});
    renderChatLog();
    if (logInf.children.length !== 12) throw new Error("∞ must track the live exchanges cache (12 rows for 6 exchanges), got " + logInf.children.length);
    console.log("INF_TRACKS_LIVE_CACHE_OK true");

    // ---- #481 (review round 1, finding 2): renderChatLog()'s rebuild snaps
    // to the bottom with exactly ONE scroll write -- not a write per row
    // (2 * 6 exchanges = 12) plus one more, the cost that scales with
    // history size ∞ makes newly reachable. A rebuild (toggling lastX,
    // loading history) is a deliberate user action, so it snaps
    // unconditionally regardless of where the human was scrolled. ----
    logInf.scrollTop = 0; // simulate the human having scrolled up through history
    logInf._scrollWrites = 0;
    renderChatLog();
    if (logInf._scrollWrites !== 1) throw new Error("renderChatLog() must write scrollTop exactly once per rebuild (suppressing the per-row scroll appendChatRow would otherwise do), got " + logInf._scrollWrites + " writes");
    if (logInf.scrollTop !== logInf.scrollHeight) throw new Error("renderChatLog() must land the log at the bottom, scrollTop=" + logInf.scrollTop + " scrollHeight=" + logInf.scrollHeight);
    console.log("REBUILD_SINGLE_SCROLL_SNAP_OK true");

    // ---- #481 (review round 1, finding 1): a LIVE append (dispatchNextChat)
    // while the human is scrolled UP reading older history must NOT yank
    // them back to the bottom -- sticky-bottom, not yank-to-bottom. The log
    // has 12 rows (scrollHeight=480) and clientHeight is a fixed 120, so
    // scrollTop=0 sits nowhere near the bottom (well outside the 4px slack)
    // -- this can genuinely fail if appendChatRow ever goes back to
    // scrolling unconditionally. ----
    logInf.scrollTop = 0; // simulate scrolled UP, reading old history
    const heightBeforeStayPut = logInf.scrollHeight;
    await queueOrSendChat("scroll me while reading history");
    resolveChat(chatFetchCalls().length - 1, 200, {text: "should not yank the view down", chips: [], warnings: []});
    await flush();
    if (logInf.scrollTop !== 0) throw new Error("a live append must NOT move the log while the human is scrolled up reading history (sticky-bottom, not yank-to-bottom), scrollTop=" + logInf.scrollTop);
    if (logInf.scrollHeight <= heightBeforeStayPut) throw new Error("setup: the new exchange should have grown scrollHeight past its pre-append value (" + heightBeforeStayPut + "), got " + logInf.scrollHeight);
    console.log("STICKY_SCROLL_STAYS_PUT_OK true");

    // ---- #481 (review round 1, finding 1): a LIVE append while the human
    // IS at the bottom still follows the newest message down ----
    logInf.scrollTop = logInf.scrollHeight; // already at the bottom
    const heightBeforeSnap = logInf.scrollHeight;
    await queueOrSendChat("scroll me while at the bottom");
    resolveChat(chatFetchCalls().length - 1, 200, {text: "should follow to the new bottom", chips: [], warnings: []});
    await flush();
    if (logInf.scrollTop !== logInf.scrollHeight) throw new Error("a live append must snap to the new bottom when the human was already at the bottom, scrollTop=" + logInf.scrollTop + " scrollHeight=" + logInf.scrollHeight);
    if (logInf.scrollHeight <= heightBeforeSnap) throw new Error("setup: the new exchange should have grown scrollHeight further past " + heightBeforeSnap + ", got " + logInf.scrollHeight);
    console.log("STICKY_SCROLL_SNAPS_AT_BOTTOM_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_chat_out="$(node "$_ac_node" "$NVHTML_CHAT" 2>&1)"
tmpl_chat_rc=$?
rm -f "$_ac_node"
check_rc "chat overlay template script exits 0" 0 "$tmpl_chat_rc"
check "template: pure elapsed-text ticking logic" "ELAPSED_PURE_OK true" "$tmpl_chat_out"
check "template: T opens the overlay outside inputs" "OPEN_OK true" "$tmpl_chat_out"
check "template: T does not open the overlay while focus is in an input" "NO_OPEN_IN_INPUT_OK true" "$tmpl_chat_out"
check "template (#480): T-key open focuses #ast-chat-input so the user can type immediately" "TKEY_FOCUSES_INPUT_OK true" "$tmpl_chat_out"
check "template (#480): the 't' that opened the overlay is prevented and never lands in the input" "TKEY_PREVENTS_T_IN_INPUT_OK true" "$tmpl_chat_out"
check "template (#480): re-pressing T on an already-open overlay re-focuses the input" "TKEY_REOPEN_REFOCUSES_OK true" "$tmpl_chat_out"
check "template (#480): re-pressing T must not steal focus onto a disabled (gated) input" "TKEY_SKIPS_FOCUS_ON_DISABLED_INPUT_OK true" "$tmpl_chat_out"
check "template (#480): focusChatInput() is a no-op when #ast-chat-input doesn't exist -- never throws, never steals focus" "FOCUS_HELPER_MISSING_INPUT_NOOP_OK true" "$tmpl_chat_out"
check "template (#480): queueOrSendChat's voice auto-open also focuses the input" "VOICE_AUTOOPEN_FOCUSES_INPUT_OK true" "$tmpl_chat_out"
check "template: Esc closes the overlay" "ESC_CLOSE_OK true" "$tmpl_chat_out"
check "template: Enter POSTs the message and shows the elapsed state" "ENTER_SEND_OK true" "$tmpl_chat_out"
check "template: reply renders with recall chips and clears the elapsed state" "CHIPS_AND_CLEAR_OK true" "$tmpl_chat_out"
check "template (AST-050, #332): a rendered reply wires through speakReply into the outbound adapter" "VOICE_WIRED_OK true" "$tmpl_chat_out"
check "template (#453, #454 P0): the session's selected assistant threads through as the chat POST body's assistant field" "SELECTED_ASSISTANT_THREADED_OK true" "$tmpl_chat_out"
check "template (#453, #454 P0): with no selection known, the chat POST body carries no assistant key at all -- backward compat with the terminal's own flag/default resolution" "NO_SELECTION_NO_ASSISTANT_KEY_OK true" "$tmpl_chat_out"
check "template: a send while thinking queues and dispatches FIFO in order" "QUEUE_ORDER_OK true" "$tmpl_chat_out"
check "template: gated (skip) refuses input and shows the reason" "GATED_SKIP_OK true" "$tmpl_chat_out"
check "template: gated (outcome none) refuses input and shows the reason" "GATED_NONE_OK true" "$tmpl_chat_out"
check "template: offline (status fetch failure) disables input and offers retry" "OFFLINE_OK true" "$tmpl_chat_out"
check "template: auth-expired error text is surfaced verbatim" "AUTH_EXPIRED_OK true" "$tmpl_chat_out"
check "template: last-X toggle (1-3) changes the rendered count client-side" "LASTX_OK true" "$tmpl_chat_out"
check "template (#481): a fourth ∞ option renders after 1/2/3" "INF_BUTTON_RENDERS_AFTER_123_OK true" "$tmpl_chat_out"
check "template (#481): selecting ∞ shows ALL cached exchanges" "INF_SHOWS_ALL_OK true" "$tmpl_chat_out"
check "template (#481): the numeric options keep slicing exactly as before after ∞ was active" "NUM_AFTER_INF_OK true" "$tmpl_chat_out"
check "template (#481): switching ∞ -> 2 -> ∞ re-renders correctly both ways" "INF_ROUNDTRIP_OK true" "$tmpl_chat_out"
check "template (#481): ∞ tracks the live exchanges cache, not a count fixed at selection time" "INF_TRACKS_LIVE_CACHE_OK true" "$tmpl_chat_out"
check "template (#481, review round 1 finding 2): renderChatLog()'s rebuild scrolls to the bottom with exactly one write" "REBUILD_SINGLE_SCROLL_SNAP_OK true" "$tmpl_chat_out"
check "template (#481, review round 1 finding 1): a live append while scrolled up reading history does not yank the view down (sticky-bottom)" "STICKY_SCROLL_STAYS_PUT_OK true" "$tmpl_chat_out"
check "template (#481, review round 1 finding 1): a live append while already at the bottom follows the newest message down" "STICKY_SCROLL_SNAPS_AT_BOTTOM_OK true" "$tmpl_chat_out"
if [[ "$tmpl_chat_rc" -ne 0 ]]; then echo "$tmpl_chat_out" >&2; fi

check "template pins the ast-chat-overlay class name in source" '"ast-chat-overlay"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-log class name in source" '"ast-chat-log"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-row class name in source" '"ast-chat-row"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-chips class name in source" '"ast-chat-chips"' "$(cat "$NVHTML_CHAT")"
# #459 (Option A restyle, final slice -- human decision 2026-07-28): recall
# chips are now a single quiet meta line inside the assistant bubble, not a
# row of bordered pills -- the per-item `ast-chat-chip` span is gone
# (joined text lives directly on the `.ast-chat-chips` container), so pin
# the new CSS shape (muted color, no border) instead of the old per-item
# class name.
check "template's ast-chat-chips rule is a quiet meta line: muted color, no per-item pill styling" '.ast-chat-chips{margin-top:.3rem;font-size:.55rem;color:var(--muted)}' "$(cat "$NVHTML_CHAT")"
check_absent "template no longer carries the bordered-pill ast-chat-chip rule (replaced by the quiet meta line)" '.ast-chat-chip{font-size:.55rem;border:1px solid var(--border)' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-input class name in source" '"ast-chat-input"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-state class name in source" '"ast-chat-state"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-lastx class name in source" '"ast-chat-lastx"' "$(cat "$NVHTML_CHAT")"

echo "-- template: AST-083 (#459) design elements -- Option A composer contract, labeled last-N selector, assistant-name header, source-level pins --"
check "composer input carries the design-mandated aria-label, pinned verbatim from the mockup" 'input.setAttribute("aria-label", "Message the assistant");' "$(cat "$NVHTML_CHAT")"
check "composer input carries placeholder text" 'input.placeholder = "Message the assistant' "$(cat "$NVHTML_CHAT")"
check "an explicit Send button exists (AST-023 had Enter-only), aria-label Send message" 'send.setAttribute("aria-label", "Send message");' "$(cat "$NVHTML_CHAT")"
check "459 flagged extension 1: the 1/2/3 control gets role=group" 'lastxWrap.setAttribute("role", "group");' "$(cat "$NVHTML_CHAT")"
check "459 flagged extension 1: the 1/2/3 control gets an accessible-name aria-label" 'lastxWrap.setAttribute("aria-label", "Number of recent exchanges shown");' "$(cat "$NVHTML_CHAT")"
check "459 flagged extension 1: the 1/2/3 control ALSO gets a visible label -- not just aria-label, since the human complained it visually read as tabs" 'lastxLabel.textContent = "Show last";' "$(cat "$NVHTML_CHAT")"
check "459 flagged extension 2: the chat header gets an assistant-name element" 'ast-chat-assistant-name' "$(cat "$NVHTML_CHAT")"
# #459 review (visual pass): the mockup's header is a cyan status dot
# THEN the label (.mk-side-hd's .mk-dot) -- the ship dropped the dot
# when the literal "ASSISTANT" text became the real name. Same idiom
# this app's own top #status bar already uses (#status .dot).
check "459 review: the chat header carries a status dot, same idiom as this app's own #status .dot" 'dotEl.className = "ast-chat-dot";' "$(cat "$NVHTML_CHAT")"

_ac2_node="$(mktemp).cjs"
cat >"$_ac2_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
// #481: same extractConst/defineConst pattern as the first script above --
// isChatLogAtBottom reads the top-level CHAT_SCROLL_BOTTOM_SLACK_PX const.
function extractConst(name) {
    const re = new RegExp("const " + name + " = [^\\n]*\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find const " + name + " in template");
    return m[0];
}
function defineConst(name) {
    const src = extractConst(name).trim().replace(/^const\s+\S+\s*=\s*/, "").replace(/;$/, "");
    global[name] = eval("(" + src + ")");
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
        // #480: same stub as the first script above -- a disabled control
        // silently refuses focus().
        focus(){ if (!this.disabled) document.activeElement = this; },
        _attrs: {},
        _items: [],
        get children(){
            return new Proxy(this._items, {
                set(_target, prop){
                    throw new TypeError("Cannot set property " + String(prop) + " of Array which has only a getter");
                },
            });
        },
        appendChild(child){ this._items.push(child); return child; },
        get innerHTML(){ return this._innerHTML || ""; },
        set innerHTML(v){ this._items.length = 0; this._innerHTML = v; this._attrs["data-chat-empty"] = undefined; },
        get id(){ return this._id; },
        set id(v){ this._id = v; if (v) elements[v] = this; },
        remove(){ if (this._id && elements[this._id] === this) delete elements[this._id]; },
        get className(){ return [...this._classes].join(" "); },
        set className(v){ this._classes = new Set(v.split(" ").filter(Boolean)); },
        setAttribute(k, v){ if (k === "class") { this.className = v; } this._attrs[k] = String(v); },
        getAttribute(k){ return this._attrs[k] !== undefined ? this._attrs[k] : null; },
    };
    el.classList._parent = el;
    if (initialId) elements[initialId] = el;
    return el;
}
const bodyEl = mkEl(null);
global.document = {
    body: bodyEl,
    activeElement: bodyEl,
    getElementById(id) { return elements[id] || null; },
    createElement(_tag) { return mkEl(null); },
};
global.window = global;
window.__assistantSelected = null;
window.neuralVoice = { speakChunks(){} };
window.__sttListening = false;

let fetchCalls = [];
let pendingChat = [];
global.fetch = async (url, opts) => {
    fetchCalls.push({ url, opts });
    if (url === "/assistant/status") return { status: 200, json: async () => ({ outcome: "one", candidates: [{name:"fab-io", aliases:[], root:"/r"}], selected: "fab-io", gated: false, askAgain: false }) };
    if (url.indexOf("/assistant/history") === 0) return { status: 200, json: async () => ({ exchanges: [], warnings: [] }) };
    if (url === "/assistant/chat") return new Promise((resolve) => { pendingChat.push({url, opts, resolve}); });
    return { status: 200, json: async () => ({}) };
};
function resolveChat(i, status, payload) { pendingChat[i].resolve({ status, json: async () => payload }); }
async function flush() { for (let i = 0; i < 6; i++) await new Promise(r => setImmediate(r)); }

let store = {};
let uiState = {};
global.localStorage = { getItem(){ return null; }, setItem(){}, removeItem(){} };
window.assistantChat = { queue: [], inFlight: false, exchanges: [], lastX: 2, elapsedTimer: null, elapsedStart: 0 };

// #481: appendChatRow's sticky-bottom check calls isChatLogAtBottom, which
// reads CHAT_SCROLL_BOTTOM_SLACK_PX -- define both before extracting
// appendChatRow/renderChatLog (which call scrollChatLogToBottom) so
// eval-ing them doesn't ReferenceError. This script doesn't exercise
// scroll behavior itself (see the first script's harness for that), it
// just needs the dependency chain to not throw.
defineConst("CHAT_SCROLL_BOTTOM_SLACK_PX");
eval(extract("isChatLogAtBottom"));
eval(extract("scrollChatLogToBottom"));
// 2026-07-29: appendChatRow enriches assistant rows through the notes
// renderer (chatEnrichObserver/enrichChatRowMarkdown) -- stubbed inert
// here; the render POST path is exercised against the live server, not
// this DOM stub.
global.chatEnrichObserver = () => false;
global.enrichChatRowMarkdown = () => {};
eval(extract("appendChatRow"));
eval(extract("renderChatLog"));
eval(extract("renderChatLastXToggle"));
// show-last persistence (2026-07-29): setChatLastX persists via uiState/
// saveUiState -- same stub contract other harnesses use.
if (typeof global.uiState === "undefined") global.uiState = {};
if (typeof global.saveUiState === "undefined") global.saveUiState = function(){ try{ localStorage.setItem("nv-ui", JSON.stringify(global.uiState)); }catch{} };
eval(extract("setChatLastX"));
eval(extract("buildChatOverlay"));
eval(extract("renderChatGated"));
eval(extract("renderChatOffline"));
eval(extract("chatElapsedText"));
eval(extract("startChatElapsed"));
eval(extract("stopChatElapsed"));
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
// barge-in (2026-07-29): speakReply arms/disarms the barge watcher --
// stubbed no-ops here (audio-level behavior is out of this harness's scope).
global.voiceBargeWatchStart = () => {};
global.voiceBargeWatchStop = () => {};
// speech sanitizer (2026-07-29): spoken text is cleaned of markdown/code
// syntax -- extract the REAL function so speakReply's chunking behavior
// stays exercised end-to-end (plain text passes through unchanged).
eval(extract("speechTextForReply"));
eval(extract("speakReply"));
eval(extract("dispatchNextChat"));
eval(extract("queueOrSendChat"));
eval(extract("sendChatInput"));
eval(extract("chatInputKeydown"));
eval(extract("loadChatHistory"));
// #480: openChatOverlay's fix calls focusChatInput() -- extract it first.
eval(extract("focusChatInput"));
// 2026-07-29: openChatOverlay resolves the selected assistant's media
// context (setAssistantMediaCtx) from the status payload -- stubbed as a
// recorder here.
global.setAssistantMediaCtx = () => {};
// detach/dock (2026-07-29): openChatOverlay restores the persisted state
// via setChatDetached -- stubbed as a recorder; geometry/drag behavior is
// a real-browser concern, not this DOM stub's.
global.setChatDetached = () => {};
global.syncChatDockBodyClass = () => {};
// #485: tabs + status keep-in-step -- recorders here.
global.renderChatAssistantTabs = () => {};
global.startChatStatusSync = () => {};
eval(extract("openChatOverlay"));
if (typeof global.syncChatDockBodyClass === "undefined") global.syncChatDockBodyClass = () => {};
if (typeof global.stopChatStatusSync === "undefined") global.stopChatStatusSync = () => {};
if (typeof global.syncChatDockBodyClass === "undefined") global.syncChatDockBodyClass = () => {};
eval(extract("closeChatOverlay"));

(async () => {
// ---- 459 flagged extension 2: WHO AM I TALKING TO -- an assistant with NO stored exchanges yet (the reported blank-panel bug) still names itself in the header ----
await openChatOverlay();
const nameEl = document.getElementById("ast-chat-assistant-name");
if (!nameEl || nameEl.textContent !== "fab-io") throw new Error("expected the chat header to name the selected assistant fab-io, got " + (nameEl && nameEl.textContent));
console.log("ASSISTANT_NAME_IN_HEADER_OK true");

// ---- 459 flagged extension 4: empty-state names the assistant instead of blank space ----
const log = document.getElementById("ast-chat-log");
const emptyRow = log.children.find(c => c.className === "ast-chat-empty");
if (!emptyRow || emptyRow.textContent.indexOf("fab-io") === -1) throw new Error("expected an empty-state row naming fab-io, got " + (emptyRow && emptyRow.textContent));
console.log("EMPTY_STATE_NAMES_ASSISTANT_OK true");

// ---- the Send button dispatches the same as Enter, and clears the empty state ----
const input = document.getElementById("ast-chat-input");
const send = document.getElementById("ast-chat-send");
input.value = "hello via send button";
input.disabled = false;
send.onclick();
const sendCalls = fetchCalls.filter(c => c.url === "/assistant/chat");
if (sendCalls.length !== 1) throw new Error("clicking Send must dispatch exactly one /assistant/chat POST, got " + sendCalls.length);
if (JSON.parse(sendCalls[0].opts.body).message !== "hello via send button") throw new Error("Send button did not carry the input's text");
if (input.value !== "") throw new Error("Send button must clear the input, same as Enter does");
console.log("SEND_BUTTON_DISPATCHES_OK true");

const logAfterSend = document.getElementById("ast-chat-log");
if (logAfterSend.children.length !== 1 || logAfterSend.children[0].className !== "ast-chat-row") throw new Error("the empty-state row must be cleared once a real turn starts, got " + logAfterSend.children.length + " children");
console.log("EMPTY_STATE_CLEARS_ON_SEND_OK true");
resolveChat(0, 200, {text: "hi", chips: [], warnings: []});
await flush();

console.log("ALL_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_ac2_out="$(node "$_ac2_node" "$NVHTML_CHAT" 2>&1)"
tmpl_ac2_rc=$?
rm -f "$_ac2_node"
check_rc "AST-083 chat-design template script exits 0" 0 "$tmpl_ac2_rc"
check "459 flagged extension 2: the chat header names the selected assistant even with no stored exchanges yet" "ASSISTANT_NAME_IN_HEADER_OK true" "$tmpl_ac2_out"
check "459 flagged extension 4: the empty-state row names the assistant instead of blank space (the reported fab-io bug)" "EMPTY_STATE_NAMES_ASSISTANT_OK true" "$tmpl_ac2_out"
check "the composer Send button dispatches identically to Enter and clears the input" "SEND_BUTTON_DISPATCHES_OK true" "$tmpl_ac2_out"
check "the empty-state placeholder row is cleared once a real turn starts (no lingering row)" "EMPTY_STATE_CLEARS_ON_SEND_OK true" "$tmpl_ac2_out"
check "the whole AST-083 chat-design template script completes" "ALL_OK true" "$tmpl_ac2_out"
if [[ "$tmpl_ac2_rc" -ne 0 ]]; then echo "$tmpl_ac2_out" >&2; fi

# ---- #485: per-assistant chat tabs -- REAL functions under test (review
# round 1, finding 6: the tab machinery previously had zero direct
# coverage; every other harness stubs it) ----
echo "-- template: #485 per-assistant tabs (real renderChatAssistantTabs/switchAssistantTo/status sync) --"
_ac3_node="$(mktemp).cjs"
cat >"$_ac3_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}
global.window = global;
const elements = {};
function mkEl(id){
    const el = {
        _id: id, _classes: new Set(), children: [], hidden: false, textContent: "", title: "",
        attrs: {}, dataset: {},
        classList: { add(c){ el._classes.add(c); }, remove(c){ el._classes.delete(c); },
            contains(c){ return el._classes.has(c); }, toggle(c, on){ if(on) el._classes.add(c); else el._classes.delete(c); } },
        setAttribute(k, v){ el.attrs[k] = String(v); },
        getAttribute(k){ return el.attrs[k] !== undefined ? el.attrs[k] : null; },
        appendChild(c){ el.children.push(c); return c; },
        set innerHTML(v){ if(v === "") el.children = []; el._html = v; },
        get innerHTML(){ return el._html || ""; },
    };
    if (id) elements[id] = el;
    return el;
}
mkEl("ast-chat-tabs"); mkEl("ast-chat-assistant-name"); mkEl("ast-chat-overlay"); mkEl("ast-chat-log");
global.document = {
    getElementById(id){ return elements[id] || null; },
    createElement(){ return mkEl(null); },
};
let fetchCalls = [];
let selectResponse = { ok: true, body: { selected: "friday", digest: null } };
global.fetch = async (url, opts) => {
    fetchCalls.push({url, opts});
    if (String(url) === "/assistant/select") return { ok: selectResponse.ok, json: async () => selectResponse.body };
    return { ok: true, json: async () => ({}) };
};
let historyLoads = 0;
global.loadChatHistory = async () => { historyLoads++; };
global.setVoiceHeaderName = (n) => { global.__headerName = n; };
global.gateVoiceAndChat = () => {};
global.renderAssistantDigest = () => {};
global.setAssistantMediaCtx = () => {};
global.uiState = {};
window.assistantChat = { queue: [{text: "stale queued"}], inFlight: false, switchGen: 0 };
window.__assistantSelected = "jarvis";
window.__assistantCandidates = [{name: "jarvis"}, {name: "friday"}];
eval(extract("renderChatAssistantTabs"));
eval(extract("switchAssistantTo"));
(async () => {
    // multi-candidate: one pill per assistant, active mirrors selection, name span hidden
    renderChatAssistantTabs();
    const wrap = elements["ast-chat-tabs"];
    if (wrap.hidden !== false) throw new Error("2 candidates must show the tab row");
    if (wrap.children.length !== 2) throw new Error("expected 2 tabs, got " + wrap.children.length);
    if (wrap.children[0].getAttribute("aria-pressed") !== "true") throw new Error("active tab must mirror window.__assistantSelected");
    if (wrap.children[1].getAttribute("aria-pressed") !== "false") throw new Error("inactive tab must not read pressed");
    if (elements["ast-chat-assistant-name"].hidden !== true) throw new Error("multi-candidate must hide the single-name span");
    console.log("TABS_RENDER_OK true");

    // single candidate: plain name stays, tab row hides
    window.__assistantCandidates = [{name: "jarvis"}];
    renderChatAssistantTabs();
    if (wrap.hidden !== true) throw new Error("single candidate must hide the tab row");
    if (elements["ast-chat-assistant-name"].hidden !== false) throw new Error("single candidate keeps the name span");
    console.log("TABS_SINGLE_NAME_OK true");

    // click-switch: POSTs /assistant/select, adopts the SERVER's echoed
    // selection, flushes the outgoing queue, bumps switchGen, reloads history
    window.__assistantCandidates = [{name: "jarvis"}, {name: "friday"}];
    renderChatAssistantTabs();
    await switchAssistantTo("friday");
    if (!fetchCalls.some(c => c.url === "/assistant/select")) throw new Error("switch must POST /assistant/select");
    if (window.__assistantSelected !== "friday") throw new Error("switch must adopt the server-echoed selection");
    if (window.assistantChat.queue.length !== 0) throw new Error("switch must flush the outgoing assistant's queued sends (§7.7)");
    if (window.assistantChat.switchGen !== 1) throw new Error("switch must bump switchGen so in-flight replies discard");
    if (historyLoads !== 1) throw new Error("switch must reload the incoming assistant's history exactly once, got " + historyLoads);
    console.log("TABS_SWITCH_FLOW_OK true");

    // failed select (404: renamed/disabled): selection must NOT become client-only state
    selectResponse = { ok: false, body: { error: "no assistant named ghost" } };
    fetchCalls = [];
    await switchAssistantTo("ghost");
    if (window.__assistantSelected === "ghost") throw new Error("a failed select must never set client-only selection (§7.5)");
    console.log("TABS_FAILED_SELECT_HONEST_OK true");

    // status sync: arms one interval, teardown clears it; baseline is loop-owned
    let intervals = [], cleared = [];
    global.setInterval = (fn, ms) => { intervals.push({fn, ms}); return intervals.length; };
    global.clearInterval = (id) => { cleared.push(id); };
    eval(extract("startChatStatusSync"));
    eval(extract("stopChatStatusSync"));
    window.__chatStatusTimer = null;
    window.__chatSyncBaseline = null;
    startChatStatusSync();
    if (intervals.length !== 1) throw new Error("sync must arm exactly one interval");
    if (window.__chatSyncBaseline !== "friday") throw new Error("sync baseline must seed from the current selection");
    startChatStatusSync();
    if (intervals.length !== 1) throw new Error("re-arming must be a no-op while armed");
    stopChatStatusSync();
    if (cleared.length !== 1 || window.__chatStatusTimer !== null) throw new Error("teardown must clear the interval");
    console.log("TABS_SYNC_LIFECYCLE_OK true");

    console.log("ALL_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_ac3_out="$(node "$_ac3_node" "$NVHTML_CHAT" 2>&1)"
tmpl_ac3_rc=$?
rm -f "$_ac3_node"
check_rc "#485 tabs script exits 0" 0 "$tmpl_ac3_rc"
check "#485: tabs render one pill per candidate, active mirrors the selection, name span hides" "TABS_RENDER_OK true" "$tmpl_ac3_out"
check "#485: single candidate keeps the plain name (no tab row)" "TABS_SINGLE_NAME_OK true" "$tmpl_ac3_out"
check "#485: a tab click POSTs /assistant/select, adopts the server echo, flushes the queue, bumps switchGen, reloads history" "TABS_SWITCH_FLOW_OK true" "$tmpl_ac3_out"
check "#485 (§7.5): a FAILED select never becomes client-only selection state" "TABS_FAILED_SELECT_HONEST_OK true" "$tmpl_ac3_out"
check "#485: the status sync arms once, re-arm is a no-op, teardown clears; baseline is loop-owned" "TABS_SYNC_LIFECYCLE_OK true" "$tmpl_ac3_out"
check "the whole #485 tabs script completes" "ALL_OK true" "$tmpl_ac3_out"
if [[ "$tmpl_ac3_rc" -ne 0 ]]; then echo "$tmpl_ac3_out" >&2; fi
