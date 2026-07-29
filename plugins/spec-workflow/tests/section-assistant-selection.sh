#!/usr/bin/env bash
# section-assistant-selection.sh -- AST-021: startup selection (silent
# single, picker w/ Skip, none-overlay) (SPEC-ASSISTANT.md sec7.2-sec7.4,
# sec17.9, issue #318). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant selection (AST-021: startup selection, SPEC-ASSISTANT.md sec7.2-sec7.4) =="

AS_SCRIPTS="$PLUGIN/scripts"

# as_repo <dir> <main> [alias...] -- a marker'd repo with a structurally
# valid, enabled assistant: section, main name plus any aliases (mirrors
# section-assistant-engine.sh's ae_repo, extended with aliases).
as_repo() {
    local dir="$1" main="$2"; shift 2
    local names_list="$main"
    if [[ $# -gt 0 ]]; then
        for a in "$@"; do
            names_list="$names_list, $a"
        done
    fi
    mkdir -p "$dir/.claude"
    printf '%s\n' '# neural-network' >"$dir/.claude/.neural-network"
    printf '%s\n' \
        'schemaVersion: 2' \
        'assistant:' \
        '    version: 1' \
        '    enabled: true' \
        "    names: [$names_list]" \
        '    systemPrompt: |' \
        "        You are $main." \
        '    llm:' \
        '        provider: openai' \
        '        model: gpt-5.6-sol' \
        '    capabilities:' \
        '        codex:' \
        '            enabled: true' \
        '            provisioning:' \
        '                bin: codex' \
        >"$dir/.claude/project.yaml"
}

echo "-- engine: outcome/candidates/select/skip/gated chat (no server) --"
_as_none="$(mktemp -d)"            # empty dir: no marker at all -- outcome none
_as_one="$(mktemp -d)"             # single candidate, an alias -- outcome one
_as_multi_a="$(mktemp -d)"
_as_multi_b="$(mktemp -d)"         # two candidates -- outcome multiple
as_repo "$_as_one" jarvis jay
as_repo "$_as_multi_a" jarvis
as_repo "$_as_multi_b" friday

sel_out="$(SCRIPTS_DIR="$AS_SCRIPTS" NONE="$_as_none" ONE="$_as_one" MA="$_as_multi_a" MB="$_as_multi_b" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

def status_of(e):
    _, payload, _ = e.handle("GET", "/assistant/status")
    return payload

# ---- outcome none: no candidates at all --------------------------------
e_none = engine.AssistantEngine(lambda: [("n", os.environ["NONE"])], os.environ["NONE"])
p = status_of(e_none)
print("NONE_OUTCOME", p["outcome"])
print("NONE_CANDIDATES", p["candidates"])
print("NONE_SELECTED", p["selected"])
print("NONE_GATED", p["gated"])

chat_code, chat_payload, _ = e_none.handle("POST", "/assistant/chat", body={"message": "hi"})
print("NONE_CHAT_CODE", chat_code)
print("NONE_CHAT_IS_RESOLUTION_ERROR", "no assistants discovered" in chat_payload.get("error", ""))

# ---- outcome one: silent single, alias-matched select ------------------
e_one = engine.AssistantEngine(lambda: [("a", os.environ["ONE"])], os.environ["ONE"])
p1 = status_of(e_one)
print("ONE_OUTCOME", p1["outcome"])
print("ONE_ASSISTANTS", p1["assistants"])
print("ONE_CANDIDATE_NAME", p1["candidates"][0]["name"])
print("ONE_CANDIDATE_ALIASES", p1["candidates"][0]["aliases"])
print("ONE_SELECTED_BEFORE", p1["selected"])
print("ONE_GATED_BEFORE", p1["gated"])

sel_code, sel_payload, _ = e_one.handle("POST", "/assistant/select", body={"name": "JAY"})
print("ONE_SELECT_CODE", sel_code)
print("ONE_SELECT_SELECTED", sel_payload["selected"])
print("ONE_SELECT_GATED", sel_payload["gated"])

p1b = status_of(e_one)
print("ONE_SELECTED_AFTER", p1b["selected"])
print("ONE_GATED_AFTER", p1b["gated"])

# ---- outcome multiple: unknown name 404s, skip gates chat ---------------
repos_multi = lambda: [("a", os.environ["MA"]), ("b", os.environ["MB"])]
e_multi = engine.AssistantEngine(repos_multi, os.environ["MA"])
pm = status_of(e_multi)
print("MULTI_OUTCOME", pm["outcome"])
print("MULTI_ASSISTANTS", pm["assistants"])
print("MULTI_NAMES", sorted(c["name"] for c in pm["candidates"]))
print("MULTI_GATED_BEFORE", pm["gated"])

bad_code, bad_payload, _ = e_multi.handle("POST", "/assistant/select", body={"name": "nope"})
print("MULTI_BAD_SELECT_CODE", bad_code)
print("MULTI_BAD_SELECT_LISTS_CANDIDATES", sorted(bad_payload["candidates"]))

# chat is NOT gated merely because nothing was selected yet (terminal-style
# --assistant flag resolution must keep working unaffected by this task --
# see section-assistant-terminal.sh two-candidate coverage).
prechat_code, prechat_payload, _ = e_multi.handle("POST", "/assistant/chat", body={"message": "hi", "assistant": "jarvis"})
print("MULTI_PRECHAT_CODE_NOT_GATED", prechat_code != 403)

skip_code, skip_payload, _ = e_multi.handle("POST", "/assistant/skip", body={})
print("MULTI_SKIP_CODE", skip_code)
print("MULTI_SKIP_SELECTED", skip_payload["selected"])
print("MULTI_SKIP_GATED", skip_payload["gated"])

pm2 = status_of(e_multi)
print("MULTI_STATUS_GATED_AFTER_SKIP", pm2["gated"])
print("MULTI_STATUS_SELECTED_AFTER_SKIP", pm2["selected"])

gated_chat_code, gated_chat_payload, _ = e_multi.handle("POST", "/assistant/chat", body={"message": "hi", "assistant": "jarvis"})
print("MULTI_GATED_CHAT_CODE", gated_chat_code)
print("MULTI_GATED_CHAT_ERROR_MENTIONS_GATE", "gate" in gated_chat_payload.get("error", "").lower())

# selecting again un-gates
resel_code, resel_payload, _ = e_multi.handle("POST", "/assistant/select", body={"name": "friday"})
print("MULTI_RESELECT_CODE", resel_code)
print("MULTI_RESELECT_SELECTED", resel_payload["selected"])
print("MULTI_RESELECT_GATED", resel_payload["gated"])
PY
)"
rc=$?
check_rc "assistant selection script exits 0" 0 "$rc"

echo "-- #462 (P2): durable session-selected chat fallback -- ANY caller that omits the assistant flag, not just dispatchNextChat's own client thread --"
# Unit test of the exact pure function _chat now calls, isolated from any
# provider/network concern (see its own docstring in engine.py for the
# full contract: explicit flag always wins, sole-candidate resolution is
# never disturbed, session-selected only fills in for the ambiguous 2+
# candidate/no-flag case).
_effflag_out="$(SCRIPTS_DIR="$AS_SCRIPTS" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant.engine import _effective_chat_flag

print("EXPLICIT_FLAG_WINS", _effective_chat_flag("jarvis", "friday", 2))
print("EXPLICIT_FLAG_WINS_EVEN_UNSELECTED", _effective_chat_flag("jarvis", None, 2))
print("SOLE_CANDIDATE_IGNORES_SELECTED", _effective_chat_flag(None, "stale-name", 1))
print("SOLE_CANDIDATE_NO_FLAG_NO_SELECTED", _effective_chat_flag(None, None, 1))
print("MULTI_NO_FLAG_FALLS_BACK_TO_SELECTED", _effective_chat_flag(None, "friday", 2))
print("MULTI_NO_FLAG_NO_SELECTED_STAYS_NONE", _effective_chat_flag(None, None, 2))
PY
)"
_effflag_rc=$?
check_rc "_effective_chat_flag unit script exits 0" 0 "$_effflag_rc"
check "an explicit flag always wins, unchanged, even with a different session selection" "EXPLICIT_FLAG_WINS jarvis" "$_effflag_out"
check "an explicit flag wins even with nothing selected this session" "EXPLICIT_FLAG_WINS_EVEN_UNSELECTED jarvis" "$_effflag_out"
check "a sole candidate ignores a stale/mismatched selected name -- that shortcut must keep resolving on its own" "SOLE_CANDIDATE_IGNORES_SELECTED None" "$_effflag_out"
check "a sole candidate with nothing selected and no flag stays a no-op (unchanged pre-462 behavior)" "SOLE_CANDIDATE_NO_FLAG_NO_SELECTED None" "$_effflag_out"
check "#462's actual fix: no flag + 2plus candidates falls back to the session's own selected assistant" "MULTI_NO_FLAG_FALLS_BACK_TO_SELECTED friday" "$_effflag_out"
check "no flag + 2plus candidates + nothing selected stays None -- falls through to the machine-local default exactly as before" "MULTI_NO_FLAG_NO_SELECTED_STAYS_NONE None" "$_effflag_out"

echo "-- #462: real end-to-end proof -- a multi-candidate session selects an assistant, then POSTs /assistant/chat with NO assistant flag, and the RIGHT assistant answers (not the pre-462 resolution error) --"
STUB_CODEX="$FIX/stub-codex"
_as_e2e_a="$(mktemp -d)"
_as_e2e_b="$(mktemp -d)"
_as_e2e_state="$(mktemp -d)"
as_repo "$_as_e2e_a" jarvis
as_repo "$_as_e2e_b" friday

e2e_out="$(PATH="$STUB_CODEX:$PATH" CODEX_STUB_MODE=ok SCRIPTS_DIR="$AS_SCRIPTS" EA="$_as_e2e_a" EB="$_as_e2e_b" ESTATE="$_as_e2e_state" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine
from assistant.store import SessionStore

repos = lambda: [("a", os.environ["EA"]), ("b", os.environ["EB"])]
e = engine.AssistantEngine(repos, os.environ["ESTATE"])

# no machine-local default was ever written for this state dir -- pre-462,
# the chat call below (no explicit flag) would 400 with "no local default
# set and multiple assistants found", the exact error the human hit live.
sel_code, sel_payload, _ = e.handle("POST", "/assistant/select", body={"name": "friday"})
print("E2E_SELECT_CODE", sel_code)
print("E2E_SELECT_SELECTED", sel_payload["selected"])

chat_code, chat_payload, _ = e.handle("POST", "/assistant/chat", body={"message": "hi"})
print("E2E_CHAT_CODE", chat_code)
print("E2E_CHAT_TEXT", chat_payload.get("text"))
print("E2E_CHAT_ERROR", chat_payload.get("error"))

friday_state = SessionStore(os.environ["EB"]).load_state()
jarvis_state = SessionStore(os.environ["EA"]).load_state()
print("E2E_FRIDAY_TURN_COUNT", friday_state.get("turn_count", 0))
print("E2E_JARVIS_TURN_COUNT", jarvis_state.get("turn_count", 0))
PY
)"
e2e_rc=$?
check_rc "#462 e2e script exits 0" 0 "$e2e_rc"
check "select succeeds" "E2E_SELECT_CODE 200" "$e2e_out"
check "select reports friday" "E2E_SELECT_SELECTED friday" "$e2e_out"
check "#462: chat with NO assistant flag succeeds (200), not the pre-462 400 resolution error" "E2E_CHAT_CODE 200" "$e2e_out"
check "the stub adapter's reply comes through" "E2E_CHAT_TEXT Hello from stub" "$e2e_out"
check_absent "the pre-462 resolution error never fires once a session selection exists" "no local default set" "$e2e_out"
check "#462: the turn landed against the SESSION-SELECTED assistant (friday), not by accident against the other candidate" "E2E_FRIDAY_TURN_COUNT 1" "$e2e_out"
check "the other candidate's session is untouched" "E2E_JARVIS_TURN_COUNT 0" "$e2e_out"

rm -rf "$_as_e2e_a" "$_as_e2e_b" "$_as_e2e_state"

check "none outcome: status carries outcome none" "NONE_OUTCOME none" "$sel_out"
check "none outcome: no candidates" "NONE_CANDIDATES []" "$sel_out"
check "none outcome: nothing selected" "NONE_SELECTED None" "$sel_out"
check "none outcome: status reports gated true (sec7.4 hard gate)" "NONE_GATED True" "$sel_out"
check "none outcome: chat still refuses cleanly (400, existing resolution error)" "NONE_CHAT_CODE 400" "$sel_out"
check "none outcome: chat error is the existing sec7.6 resolution message" "NONE_CHAT_IS_RESOLUTION_ERROR True" "$sel_out"

check "one outcome: status carries outcome one" "ONE_OUTCOME one" "$sel_out"
check "one outcome: assistants count is 1" "ONE_ASSISTANTS 1" "$sel_out"
check "one outcome: candidate main name is jarvis" "ONE_CANDIDATE_NAME jarvis" "$sel_out"
check "one outcome: candidate aliases carry jay" "ONE_CANDIDATE_ALIASES ['jay']" "$sel_out"
check "one outcome: nothing auto-selected by the engine itself (page drives the POST)" "ONE_SELECTED_BEFORE None" "$sel_out"
check "one outcome: not gated before any selection (sole assistant is not sec17.9's none-selected state)" "ONE_GATED_BEFORE False" "$sel_out"
check "select resolves an alias case-insensitively (JAY -> jarvis)" "ONE_SELECT_CODE 200" "$sel_out"
check "select response reports the resolved main name" "ONE_SELECT_SELECTED jarvis" "$sel_out"
check "select response reports gated false" "ONE_SELECT_GATED False" "$sel_out"
check "status reflects the selection afterward" "ONE_SELECTED_AFTER jarvis" "$sel_out"
check "status reflects not-gated afterward" "ONE_GATED_AFTER False" "$sel_out"

check "multiple outcome: status carries outcome multiple" "MULTI_OUTCOME multiple" "$sel_out"
check "multiple outcome: assistants count is 2" "MULTI_ASSISTANTS 2" "$sel_out"
check "multiple outcome: both main names listed" "MULTI_NAMES ['friday', 'jarvis']" "$sel_out"
check "multiple outcome: not gated before Skip" "MULTI_GATED_BEFORE False" "$sel_out"
check "select with an unknown name 404s" "MULTI_BAD_SELECT_CODE 404" "$sel_out"
check "unknown-name select lists the real candidates" "MULTI_BAD_SELECT_LISTS_CANDIDATES ['friday', 'jarvis']" "$sel_out"
check "chat with an explicit --assistant flag is unaffected before any select/skip (terminal coverage regression guard)" "MULTI_PRECHAT_CODE_NOT_GATED True" "$sel_out"
check "skip exits 0" "MULTI_SKIP_CODE 200" "$sel_out"
check "skip response reports selected null" "MULTI_SKIP_SELECTED None" "$sel_out"
check "skip response reports gated true" "MULTI_SKIP_GATED True" "$sel_out"
check "status reflects gated true after skip" "MULTI_STATUS_GATED_AFTER_SKIP True" "$sel_out"
check "status reflects selected null after skip" "MULTI_STATUS_SELECTED_AFTER_SKIP None" "$sel_out"
check "chat refuses with a 403 once gated (sec17.9)" "MULTI_GATED_CHAT_CODE 403" "$sel_out"
check "gated chat error names the gate, not a resolution failure" "MULTI_GATED_CHAT_ERROR_MENTIONS_GATE True" "$sel_out"
check "selecting again ungates the session" "MULTI_RESELECT_CODE 200" "$sel_out"
check "reselect reports the newly selected name" "MULTI_RESELECT_SELECTED friday" "$sel_out"
check "reselect reports gated false" "MULTI_RESELECT_GATED False" "$sel_out"

rm -rf "$_as_none" "$_as_one" "$_as_multi_a" "$_as_multi_b"

echo "-- template: boot branching over /assistant/status (one/multiple/none) --"
NVHTML="$PLUGIN/templates/neural-view.html"

_as_node="$(mktemp).cjs"
cat >"$_as_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

// DOM stub: just enough for the selection functions -- elements are plain
// objects tracked by id, classList/attr/textContent no-ops that record state.
const elements = {};
function mkEl(initialId) {
    const el = {
        _id: initialId,
        _classes: new Set(),
        classList: {
            add(c){ this._parent._classes.add(c); },
            remove(c){ this._parent._classes.delete(c); },
            contains(c){ return this._parent._classes.has(c); },
            // AST-021 restyle: renderAssistantPicker's keyboard nav toggles
            // .ast-picker-active per row -- real DOM's classList.toggle(c,
            // force) semantics (force omitted = flip; force given = set to
            // that boolean).
            toggle(c, force){
                const on = force === undefined ? !this._parent._classes.has(c) : !!force;
                if(on) this._parent._classes.add(c); else this._parent._classes.delete(c);
                return on;
            },
        },
        _items: [],
        // #387: children mirrors a real live HTMLCollection -- reads work,
        // any mutation (length=0, push) throws like a getter-only property,
        // so the stub reproduces real-browser failure semantics.
        get children(){
            return new Proxy(this._items, {
                set(){ throw new TypeError("Cannot set property length of HTMLCollection which has only a getter"); },
                get(o, k){ const v = o[k]; return typeof v === "function" ? v.bind(o) : v; },
            });
        },
        // AST-022 restyle: mirror real DOM's live textContent (tag-stripped)
        // now that switcher rows are built via innerHTML templates -- see
        // section-assistant-selection-memory.sh's identical stub for the
        // full rationale (stub-failure-semantics: extend, don't fork).
        set innerHTML(v){ this._innerHTMLv = v; if(v === "") this._items.length = 0; this.textContent = v.replace(/<[^>]*>/g, ""); },
        get innerHTML(){ return this._innerHTMLv || ""; },
        disabled: false,
        title: "",
        textContent: "",
        appendChild(child){ this._items.push(child); },
        // real elements created via createElement(...) only become
        // discoverable via getElementById() once given an id -- the
        // template code sets .id right after createElement, mirroring
        // that so a later getElementById("ast-picker") finds the SAME
        // object the template appended, not a fresh auto-vivified stub.
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
// getElementById mirrors real DOM semantics -- null for anything not
// present, no auto-vivification (renderNoneOverlay/renderAssistantPicker's
// own "already rendered?" guards rely on a real null, not a truthy stub).
const document = {
    getElementById(id) {
        return elements[id] || null;
    },
    createElement(tag) {
        const el = mkEl(null);
        el.classList._parent = el;
        // review round 1, finding 3: tagName lets a test confirm Skip is a
        // real <button> (native Tab focus + Enter/Space activation) rather
        // than a styled div needing its own hand-rolled key handling.
        el.tagName = String(tag || "").toUpperCase();
        return el;
    },
};

// Static page furniture that really exists in the template's HTML at boot
// (the voice panel header/mic/direction buttons, the voicebar container
// the picker/overlay get appended into) -- pre-registered once, reset
// per-run() below, unlike the ast-* ids the selection functions create
// themselves each time.
// AST-022 (§7.5): ast-ask-again is the ⚙ panel's static
// furniture (present in the HTML at boot, same as sect-voice etc above) --
// initAssistantSelection now unconditionally refreshes them, so they need
// to exist as real elements here too even though this section doesn't
// assert on them (section-assistant-selection-memory.sh does).
// AST-021 restyle (Option C command palette, issue #318): #ast-picker-anchor
// is new static boot furniture (top-center, under the search bar -- see the
// HTML comment beside it) that renderAssistantPicker looks up instead of
// appending into #voicebar; it needs to exist here for the same reason the
// other STATIC_IDS do.
// #399: ast-switcher is gone (dock removed) -- voice-viz-name (the label
// selector) is already a STATIC_ID above; nothing else to add here.
const STATIC_IDS = ["sect-voice", "voice-stt", "voice-in", "voice-out", "voice-both", "voicebar", "ast-picker-anchor", "ast-ask-again", "voice-viz-name"];
for (const id of STATIC_IDS) {
    const el = mkEl(id);
    el.classList._parent = el;
}

global.window = global;
let fetchCalls = [];
let statusResponse = null;
global.fetch = async (url, opts) => {
    fetchCalls.push({url, opts});
    if (url === "/assistant/status") {
        return { json: async () => statusResponse };
    }
    return { json: async () => ({}) };
};

// AST-021 restyle: renderAssistantPicker now binds/unbinds a real
// document-level keydown listener (Up/Down/Enter/Esc) while the palette is
// open -- Node has no browser addEventListener global, so this stub tracks
// listeners the same way the DOM would (add/remove by reference) and
// fireKeydown() below drives them like a real keypress would.
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
    // review round 1 (#318), finding 1: preventDefault() must actually flip
    // defaultPrevented, real-Event style -- handleAssistantChatKeydown and
    // onPickerKeydown coordinate "who owns this Escape" through that flag
    // (DOM dispatch runs every listener on the same event object, in
    // registration order, same as this loop below).
    const ev = Object.assign({ defaultPrevented: false, preventDefault(){ this.defaultPrevented = true; } }, props);
    for (const fn of [...(global.__listeners.keydown || [])]) fn(ev);
}

eval(extract("setVoiceHeaderName"));
eval(extract("gateVoiceAndChat"));
// AST-021 restyle: isChatTypingTarget (typing-target guard, shared with the
// T-key chat overlay) and unbindAssistantPickerKeys are both real
// production helpers renderAssistantPicker now calls -- extracted here too
// so this stays the real wiring instead of a simplified fork.
eval(extract("isChatTypingTarget"));
eval(extract("unbindAssistantPickerKeys"));
eval(extract("renderAssistantPicker"));
eval(extract("renderNoneOverlay"));
// #399: renderAssistantPicker's row click now also captures the select
// response and calls renderAssistantDigest -- extract it too (real
// production wiring, not a fork); no #ast-digest element is registered in
// STATIC_IDS here since this file doesn't assert on digest content, but
// the function's own `if(!el) return` guard makes that a harmless no-op.
eval(extract("renderAssistantDigest"));
// escapeHtml is used by renderAssistantPicker's row markup (name/aliases)
// -- extract it so this stays the real production wiring.
eval(extract("escapeHtml"));
eval(extract("setAskAgainUi"));
eval(extract("initAssistantSelection"));
// review round 1 (#318), finding 1: the T-key chat overlay's own Esc
// handler is bound at module scope unconditionally in production (not
// only while an overlay is open), so it and the picker's keydown handler
// can BOTH be live at once -- extract the real chat-overlay Esc plumbing
// too and bind it the same unconditional way, so this harness can catch a
// double-fire instead of only ever exercising the picker in isolation.
eval(extract("stopChatElapsed"));
if (typeof global.stopChatStatusSync === "undefined") global.stopChatStatusSync = () => {};
if (typeof global.syncChatDockBodyClass === "undefined") global.syncChatDockBodyClass = () => {};
eval(extract("closeChatOverlay"));
eval(extract("handleAssistantChatKeydown"));
global.assistantChat = { queue: [], inFlight: false, exchanges: [], lastX: 2, elapsedTimer: null, elapsedStart: 0 };
addEventListener("keydown", handleAssistantChatKeydown);

async function run(outcome, candidates) {
    // dynamic ids the selection functions create/remove themselves --
    // dropped so each run starts from "nothing rendered yet", exactly
    // like a fresh page boot.
    delete elements["ast-picker"];
    delete elements["ast-picker-wrap"];
    delete elements["ast-none-overlay"];
    for (const id of STATIC_IDS) {
        const el = elements[id];
        el.disabled = false;
        el.textContent = id === "sect-voice" ? "Voice" : "";
        el.children = [];
        el._classes = new Set();
    }
    // a real page boot only ever runs initAssistantSelection() once, so
    // there is never a stale keydown listener to worry about -- this test
    // harness re-boots several scenarios in one process, so it must clear
    // between them the same way a real reload would. handleAssistantChatKeydown
    // is the one exception: production binds it once, unconditionally, at
    // module load (never torn down) -- re-add it so every run() reflects
    // that same "always listening" reality instead of losing it on reset.
    delete elements["ast-chat-overlay"];
    global.__listeners.keydown = [];
    addEventListener("keydown", handleAssistantChatKeydown);
    window.__astPickerKeydown = null;
    fetchCalls = [];
    statusResponse = {outcome, candidates, selected: null, gated: outcome !== "one"};
    await initAssistantSelection();
}
const flushMicrotasks = () => new Promise(r => setTimeout(r, 0));

(async () => {
    // ---- outcome one: silent auto-select + header name ----
    await run("one", [{name: "jarvis", aliases: ["jay"], root: "/r"}]);
    const autoSelect = fetchCalls.find(c => c.url === "/assistant/select");
    if (!autoSelect) throw new Error("outcome one did not auto-POST /assistant/select");
    if (JSON.parse(autoSelect.opts.body).name !== "jarvis") throw new Error("outcome one selected the wrong candidate");
    if (document.getElementById("sect-voice").textContent !== "Voice") throw new Error("title must stay plain Voice (395): " + document.getElementById("sect-voice").textContent);
    if (document.getElementById("voice-viz-name").textContent !== "jarvis") throw new Error("name did not render beside the bars (395): " + document.getElementById("voice-viz-name").textContent);
    if (document.getElementById("voice-stt").disabled) throw new Error("outcome one left voice-stt disabled");
    console.log("ONE_OK true");

    // ---- outcome multiple: picker rendered, rows wired, gated until a pick ----
    await run("multiple", [{name: "jarvis", aliases: ["jay"], root: "/repo/a"}, {name: "friday", aliases: [], root: "/repo/b"}]);
    const picker = document.getElementById("ast-picker");
    if (!picker) throw new Error("outcome multiple did not render a picker");
    if (!picker.className.includes("ast-picker")) throw new Error("picker missing ast-picker class");
    if (picker.children.length !== 3) throw new Error("expected 2 rows + skip, got " + picker.children.length);
    const rows = picker.children.slice(0, 2);
    for (const r of rows) if (!r.className.includes("ast-picker-row")) throw new Error("picker row missing ast-picker-row class");
    const skipBtn = picker.children[2];
    if (!skipBtn.className.includes("ast-skip")) throw new Error("skip control missing ast-skip class");
    if (!document.getElementById("voice-stt").disabled) throw new Error("outcome multiple must gate voice before a pick");
    console.log("MULTIPLE_OK true");

    // ---- AST-021 restyle (Option C command palette, issue #318): the
    // picker now lives in a top-center card under #ast-picker-anchor, with
    // a header, structured rows (name/aliases/repo-path), and a keyboard
    // hint strip -- #ast-picker itself keeps the same DOM contract checked
    // above (pinned class hooks, 2 rows + skip).
    const wrap = document.getElementById("ast-picker-wrap");
    if (!wrap) throw new Error("palette wrap (#ast-picker-wrap) not rendered");
    if (!wrap.className.includes("ast-picker-wrap")) throw new Error("wrap missing ast-picker-wrap class");
    const anchor = document.getElementById("ast-picker-anchor");
    if (!anchor || anchor._items.indexOf(wrap) === -1) throw new Error("palette wrap not appended under #ast-picker-anchor");
    const hintRow = wrap._items[wrap._items.length - 1];
    if (!hintRow || !/navigate/i.test(hintRow.textContent) || !/select/i.test(hintRow.textContent) || !/esc/i.test(hintRow.textContent))
        throw new Error("keyboard hint row missing/incomplete: " + (hintRow && hintRow.textContent));
    const row0 = rows[0];
    if (!row0.innerHTML.includes("ast-picker-name")) throw new Error("row missing name span");
    if (!row0.innerHTML.includes("ast-picker-aliases") || !row0.textContent.includes("jay")) throw new Error("row missing/incorrect aliases: " + row0.innerHTML);
    if (!row0.innerHTML.includes("ast-picker-path") || !row0.textContent.includes("/repo/a")) throw new Error("row missing/incorrect repo path: " + row0.innerHTML);
    if (!row0.className.includes("ast-picker-active")) throw new Error("first row should start as the active row");
    console.log("PALETTE_STRUCTURE_OK true");

    // ---- keyboard nav: ArrowDown moves the active highlight, Enter selects it ----
    fireKeydown({key: "ArrowDown"});
    const row1 = rows[1];
    if (!row1.className.includes("ast-picker-active")) throw new Error("ArrowDown did not move the active highlight to row 2");
    if (row0.className.includes("ast-picker-active")) throw new Error("ArrowDown left the first row active too");
    fetchCalls = [];
    fireKeydown({key: "Enter"});
    await flushMicrotasks();
    const kbSelect = fetchCalls.find(c => c.url === "/assistant/select");
    if (!kbSelect || JSON.parse(kbSelect.opts.body).name !== "friday") throw new Error("Enter did not select the active (friday) row");
    if (document.getElementById("ast-picker-wrap")) throw new Error("palette did not close after a keyboard select");
    if (document.getElementById("voice-stt").disabled) throw new Error("keyboard select did not un-gate voice");
    // exactly ONE listener should remain: handleAssistantChatKeydown, bound
    // unconditionally at module load in production and never torn down --
    // see the identical note on the Esc-skip check below.
    if ((global.__listeners.keydown || []).length !== 1) throw new Error("picker keydown handler leaked after a keyboard select (expected only the chat handler left)");
    if (window.__astPickerKeydown) throw new Error("window.__astPickerKeydown was not cleared after a keyboard select");
    console.log("KEYBOARD_SELECT_OK true");

    // picking a row with the mouse still selects + un-gates + sets header
    await run("multiple", [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}]);
    const mouseRows = document.getElementById("ast-picker").children.slice(0, 2);
    fetchCalls = [];
    await mouseRows[0].onclick();
    const pickSelect = fetchCalls.find(c => c.url === "/assistant/select");
    if (!pickSelect || JSON.parse(pickSelect.opts.body).name !== "jarvis") throw new Error("picker row click did not select jarvis");
    if (document.getElementById("voice-stt").disabled) throw new Error("picking a candidate did not un-gate voice");
    console.log("PICK_OK true");

    // Skip disables voice
    await run("multiple", [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}]);
    fetchCalls = [];
    await document.getElementById("ast-picker").children[2].onclick();
    const skipCall = fetchCalls.find(c => c.url === "/assistant/skip");
    if (!skipCall) throw new Error("Skip did not POST /assistant/skip");
    if (!document.getElementById("voice-stt").disabled) throw new Error("Skip did not gate voice-stt");
    console.log("SKIP_OK true");

    // ---- Esc = Skip (keyboard escape hatch), and the picker's OWN listener
    // unbinds after (handleAssistantChatKeydown is bound unconditionally at
    // module load in production and never torn down, so exactly ONE
    // listener -- the chat one -- should remain, not zero). ----
    await run("multiple", [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}]);
    fetchCalls = [];
    fireKeydown({key: "Escape"});
    await flushMicrotasks();
    const escSkip = fetchCalls.find(c => c.url === "/assistant/skip");
    if (!escSkip) throw new Error("Esc did not POST /assistant/skip");
    if (!document.getElementById("voice-stt").disabled) throw new Error("Esc-skip did not gate voice-stt");
    if ((global.__listeners.keydown || []).length !== 1) throw new Error("picker keydown handler leaked after Esc-skip (expected only the chat handler left)");
    if (window.__astPickerKeydown) throw new Error("window.__astPickerKeydown was not cleared after Esc-skip");
    console.log("ESC_SKIP_OK true");

    // ---- review round 1 (#318), finding 1: Esc must not double-fire when
    // the T-key chat overlay is ALSO open on top of the picker -- the
    // overlay's own Esc handling should own that keypress (closing the
    // overlay), and the picker must NOT also skip from the same keypress. ----
    await run("multiple", [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}]);
    const chatOverlay = document.createElement("div");
    chatOverlay.id = "ast-chat-overlay";   // simulates T having opened it while the picker was up
    fetchCalls = [];
    fireKeydown({key: "Escape"});
    await flushMicrotasks();
    if (document.getElementById("ast-chat-overlay")) throw new Error("Esc did not close the chat overlay");
    if (fetchCalls.some(c => c.url === "/assistant/skip")) throw new Error("Esc double-fired: picker skipped even though the chat overlay owned this keypress");
    if (!document.getElementById("ast-picker-wrap")) throw new Error("picker must still be open -- Esc only closed the chat overlay, it did not skip");
    if (document.getElementById("voice-stt").disabled !== true) throw new Error("voice-stt gating must be unchanged (still gated, picker still pending)");
    console.log("ESC_NO_DOUBLE_FIRE_OK true");

    // ---- review round 1 (#318), finding 3: Skip is a real <button> (native
    // Tab focus + Enter/Space activation), not a styled div. ----
    await run("multiple", [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}]);
    const skipEl = document.getElementById("ast-picker").children[2];
    if (skipEl.tagName !== "BUTTON") throw new Error("Skip must be a real <button> for native keyboard activation, got <" + skipEl.tagName + ">");
    console.log("SKIP_IS_BUTTON_OK true");

    // ---- outcome none: red overlay + hover explainer + hard gate ----
    await run("none", []);
    const overlay = document.getElementById("ast-none-overlay");
    if (!overlay) throw new Error("outcome none did not render the overlay");
    if (!overlay.className.includes("ast-none-overlay")) throw new Error("overlay missing ast-none-overlay class");
    if (overlay.textContent !== "set up an assistant") throw new Error("overlay text mismatch: " + overlay.textContent);
    if (!overlay.title || overlay.title.indexOf("/setup-assistant") === -1) throw new Error("overlay hover title missing /setup-assistant explainer: " + overlay.title);
    if (!document.getElementById("voice-stt").disabled) throw new Error("outcome none did not gate voice-stt");
    console.log("NONE_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_out="$(node "$_as_node" "$NVHTML" 2>&1)"
tmpl_rc=$?
rm -f "$_as_node"
check_rc "template selection script exits 0" 0 "$tmpl_rc"
check "template: outcome one auto-selects + sets the header main name" "ONE_OK true" "$tmpl_out"
check "template: outcome multiple renders a picker with pinned class hooks" "MULTIPLE_OK true" "$tmpl_out"
# AST-021 restyle (Option C command palette, issue #318): top-center card
# under #ast-picker-anchor, structured rows (name/aliases/repo-path), a
# keyboard hint strip, and Up/Down/Enter/Esc wiring bound only while open.
check "template: palette wrap/header/hint + structured row content" "PALETTE_STRUCTURE_OK true" "$tmpl_out"
check "template: ArrowDown/Enter move the highlight and select via keyboard" "KEYBOARD_SELECT_OK true" "$tmpl_out"
check "template: picking a picker row selects and un-gates voice" "PICK_OK true" "$tmpl_out"
check "template: Skip gates voice off" "SKIP_OK true" "$tmpl_out"
check "template: Esc skips via keyboard and unbinds the listener after" "ESC_SKIP_OK true" "$tmpl_out"
check "template: Esc does not double-fire skip when the T-key chat overlay is also open (review round 1 finding 1)" "ESC_NO_DOUBLE_FIRE_OK true" "$tmpl_out"
check "template: Skip is a real button, not a div, for native keyboard activation (review round 1 finding 3)" "SKIP_IS_BUTTON_OK true" "$tmpl_out"
check "template: outcome none renders the red overlay + hover explainer + hard gate" "NONE_OK true" "$tmpl_out"
if [[ "$tmpl_rc" -ne 0 ]]; then echo "$tmpl_out" >&2; fi

check "template pins the ast-picker class name in source" '"ast-picker"' "$(cat "$NVHTML")"
check "template pins the ast-none-overlay class name in source" '"ast-none-overlay"' "$(cat "$NVHTML")"
check "template pins the ast-picker-anchor id in source" 'ast-picker-anchor' "$(cat "$NVHTML")"
check "template pins the ast-picker-wrap class name in source" 'ast-picker-wrap' "$(cat "$NVHTML")"
check "template pins the ast-picker-row class name in source" 'ast-picker-row' "$(cat "$NVHTML")"
check "template pins the ast-picker-active class name in source" 'ast-picker-active' "$(cat "$NVHTML")"
check "template pins the ast-picker-hint class name in source" 'ast-picker-hint' "$(cat "$NVHTML")"
check "template pins the ast-picker-name class name in source" 'ast-picker-name' "$(cat "$NVHTML")"
check "template pins the ast-picker-aliases class name in source" 'ast-picker-aliases' "$(cat "$NVHTML")"
check "template pins the ast-picker-path class name in source" 'ast-picker-path' "$(cat "$NVHTML")"
