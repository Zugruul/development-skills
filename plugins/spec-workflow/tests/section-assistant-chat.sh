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
eval(extract("appendChatRow"));
eval(extract("renderChatLog"));
eval(extract("renderChatLastXToggle"));
eval(extract("setChatLastX"));
eval(extract("buildChatOverlay"));
eval(extract("renderChatGated"));
eval(extract("renderChatOffline"));
eval(extract("startChatElapsed"));
eval(extract("stopChatElapsed"));
eval(extract("dispatchNextChat"));
eval(extract("queueOrSendChat"));
eval(extract("chatInputKeydown"));
eval(extract("loadChatHistory"));
eval(extract("openChatOverlay"));
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
    fetchCalls = [];
    pendingChat = [];
    statusThrows = false;
    statusResponse = {outcome: "one", candidates: [{name: "jarvis", aliases: [], root: "/r"}], selected: "jarvis", gated: false, askAgain: false};
    historyResponse = { exchanges: [], warnings: [] };
    window.assistantChat = { queue: [], inFlight: false, exchanges: [], lastX: 2, elapsedTimer: null, elapsedStart: 0 };
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

    resolveChat(0, 200, {text: "hi there", chips: [{slug: "foo-bar", strength: 3}], warnings: []});
    await flush();
    const log1 = document.getElementById("ast-chat-log");
    if (log1.children.length !== 2) throw new Error("expected 2 rows (user+assistant), got " + log1.children.length);
    if (log1.children[0].getAttribute("data-role") !== "user" || log1.children[0].textContent !== "hello") throw new Error("user row wrong");
    if (log1.children[1].getAttribute("data-role") !== "assistant" || log1.children[1].textContent !== "hi there") throw new Error("assistant row wrong");
    const chipsWrap = log1.children[1].children.find(c => c.className.includes("ast-chat-chips"));
    if (!chipsWrap) throw new Error("assistant row missing ast-chat-chips wrapper");
    const chip = chipsWrap.children.find(c => c.className.includes("ast-chat-chip"));
    if (!chip || chip.textContent !== "foo-bar [3]") throw new Error("chip text mismatch: " + (chip && chip.textContent));
    if (document.getElementById("ast-chat-state").textContent !== "") throw new Error("elapsed state did not clear after the turn resolved");
    console.log("CHIPS_AND_CLEAR_OK true");

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
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_chat_out="$(node "$_ac_node" "$NVHTML_CHAT" 2>&1)"
tmpl_chat_rc=$?
rm -f "$_ac_node"
check_rc "chat overlay template script exits 0" 0 "$tmpl_chat_rc"
check "template: pure elapsed-text ticking logic" "ELAPSED_PURE_OK true" "$tmpl_chat_out"
check "template: T opens the overlay outside inputs" "OPEN_OK true" "$tmpl_chat_out"
check "template: T does not open the overlay while focus is in an input" "NO_OPEN_IN_INPUT_OK true" "$tmpl_chat_out"
check "template: Esc closes the overlay" "ESC_CLOSE_OK true" "$tmpl_chat_out"
check "template: Enter POSTs the message and shows the elapsed state" "ENTER_SEND_OK true" "$tmpl_chat_out"
check "template: reply renders with recall chips and clears the elapsed state" "CHIPS_AND_CLEAR_OK true" "$tmpl_chat_out"
check "template: a send while thinking queues and dispatches FIFO in order" "QUEUE_ORDER_OK true" "$tmpl_chat_out"
check "template: gated (skip) refuses input and shows the reason" "GATED_SKIP_OK true" "$tmpl_chat_out"
check "template: gated (outcome none) refuses input and shows the reason" "GATED_NONE_OK true" "$tmpl_chat_out"
check "template: offline (status fetch failure) disables input and offers retry" "OFFLINE_OK true" "$tmpl_chat_out"
check "template: auth-expired error text is surfaced verbatim" "AUTH_EXPIRED_OK true" "$tmpl_chat_out"
check "template: last-X toggle (1-3) changes the rendered count client-side" "LASTX_OK true" "$tmpl_chat_out"
if [[ "$tmpl_chat_rc" -ne 0 ]]; then echo "$tmpl_chat_out" >&2; fi

check "template pins the ast-chat-overlay class name in source" '"ast-chat-overlay"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-log class name in source" '"ast-chat-log"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-row class name in source" '"ast-chat-row"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-chips class name in source" '"ast-chat-chips"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-chip class name in source" '"ast-chat-chip"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-input class name in source" '"ast-chat-input"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-state class name in source" '"ast-chat-state"' "$(cat "$NVHTML_CHAT")"
check "template pins the ast-chat-lastx class name in source" '"ast-chat-lastx"' "$(cat "$NVHTML_CHAT")"
