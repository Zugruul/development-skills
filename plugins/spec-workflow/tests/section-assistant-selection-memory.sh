#!/usr/bin/env bash
# section-assistant-selection-memory.sh -- AST-022: server-side selection
# memory + ask-again setting + voice ⚙ switcher (SPEC-ASSISTANT.md §7.5,
# issue #319). Sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant selection memory (AST-022: server-side persistence, SPEC-ASSISTANT.md sec7.5) =="

ASM_SCRIPTS="$PLUGIN/scripts"

# asm_repo <dir> <main> [alias...] -- mirrors section-assistant-selection.sh's as_repo.
asm_repo() {
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

echo "-- engine: persistence across restart, askAgain, settings route --"
_asm_multi_a="$(mktemp -d)"
_asm_multi_b="$(mktemp -d)"
asm_repo "$_asm_multi_a" jarvis
asm_repo "$_asm_multi_b" friday
_asm_state="$(mktemp -d)"

mem_out="$(SCRIPTS_DIR="$ASM_SCRIPTS" MA="$_asm_multi_a" MB="$_asm_multi_b" STATE="$_asm_state" python3 - <<'PY'
import os, sys, json
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

repos = lambda: [("a", os.environ["MA"]), ("b", os.environ["MB"])]
state_dir = os.environ["STATE"]

def status_of(e):
    _, payload, _ = e.handle("GET", "/assistant/status")
    return payload

# ---- select persists across a fresh engine over the same state dir -----
e1 = engine.AssistantEngine(repos, state_dir)
sel_code, sel_payload, _ = e1.handle("POST", "/assistant/select", body={"name": "friday"})
print("SEL_CODE", sel_code)

e2 = engine.AssistantEngine(repos, state_dir)
p2 = status_of(e2)
print("RESTART_SELECTED", p2["selected"])
print("RESTART_GATED", p2["gated"])

# ---- skip persists too --------------------------------------------------
skip_code, skip_payload, _ = e2.handle("POST", "/assistant/skip", body={})
print("SKIP_CODE", skip_code)
e3 = engine.AssistantEngine(repos, state_dir)
p3 = status_of(e3)
print("RESTART_AFTER_SKIP_SELECTED", p3["selected"])
print("RESTART_AFTER_SKIP_GATED", p3["gated"])

# re-select so the rest of this run starts from a known selected state
e3.handle("POST", "/assistant/select", body={"name": "jarvis"})

# ---- settings route round-trip ------------------------------------------
get_code, get_payload, _ = e3.handle("GET", "/assistant/settings")
print("SETTINGS_GET_CODE", get_code)
print("SETTINGS_GET_DEFAULT", get_payload["askAgain"])

post_code, post_payload, _ = e3.handle("POST", "/assistant/settings", body={"askAgain": True})
print("SETTINGS_POST_CODE", post_code)
print("SETTINGS_POST_VALUE", post_payload["askAgain"])

get2_code, get2_payload, _ = e3.handle("GET", "/assistant/settings")
print("SETTINGS_GET_AFTER_POST", get2_payload["askAgain"])

bad_code, bad_payload, _ = e3.handle("POST", "/assistant/settings", body={"askAgain": "nope"})
print("SETTINGS_BAD_CODE", bad_code)

# ---- askAgain=true boots unselected but keeps the flag persisted --------
e4 = engine.AssistantEngine(repos, state_dir)
p4 = status_of(e4)
print("ASKAGAIN_BOOT_SELECTED", p4["selected"])
print("ASKAGAIN_BOOT_GATED", p4["gated"])
_, settings4, _ = e4.handle("GET", "/assistant/settings")
print("ASKAGAIN_BOOT_FLAG", settings4["askAgain"])

# a fresh selection made while askAgain is true still persists as
# "selected", but the NEXT boot discards it again because askAgain is
# still on -- only turning askAgain back off makes a selection stick.
e4.handle("POST", "/assistant/select", body={"name": "jarvis"})
e5 = engine.AssistantEngine(repos, state_dir)
p5 = status_of(e5)
print("ASKAGAIN_STILL_ON_RESELECT_NOT_REMEMBERED", p5["selected"])

# ---- atomic write: no leftover tmp files after a select -----------------
leftovers = [n for n in os.listdir(state_dir) if "tmp" in n.lower()]
print("NO_TMP_LEFTOVERS", leftovers == [])
PY
)"
rc=$?
check_rc "selection memory script exits 0" 0 "$rc"

check "select persists: engine restart sees the same selection" "RESTART_SELECTED friday" "$mem_out"
check "select persists: restart is not gated" "RESTART_GATED False" "$mem_out"
check "skip persists: restart sees gated true" "RESTART_AFTER_SKIP_GATED True" "$mem_out"
check "skip persists: restart sees selected null" "RESTART_AFTER_SKIP_SELECTED None" "$mem_out"

check "settings GET defaults askAgain to false" "SETTINGS_GET_DEFAULT False" "$mem_out"
check "settings POST exits 200" "SETTINGS_POST_CODE 200" "$mem_out"
check "settings POST echoes the new value" "SETTINGS_POST_VALUE True" "$mem_out"
check "settings GET reflects the POSTed value" "SETTINGS_GET_AFTER_POST True" "$mem_out"
check "settings POST rejects a non-bool askAgain" "SETTINGS_BAD_CODE 400" "$mem_out"

check "askAgain=true: a fresh boot has no remembered selection" "ASKAGAIN_BOOT_SELECTED None" "$mem_out"
check "askAgain=true: a fresh boot is not gated merely by the setting" "ASKAGAIN_BOOT_GATED False" "$mem_out"
check "askAgain=true: the flag itself survives the restart" "ASKAGAIN_BOOT_FLAG True" "$mem_out"
check "askAgain=true: a selection made this boot is not remembered on the NEXT boot" "ASKAGAIN_STILL_ON_RESELECT_NOT_REMEMBERED None" "$mem_out"

check "atomic writes: no leftover tmp files after a select" "NO_TMP_LEFTOVERS True" "$mem_out"

rm -rf "$_asm_multi_a" "$_asm_multi_b" "$_asm_state"

echo "-- template: askAgain boot honoring + label/⌘K switch palette + toggle wiring (#399) --"
NVHTML_MEM="$PLUGIN/templates/neural-view.html"

_asm_node="$(mktemp).cjs"
cat >"$_asm_node" <<'NODEJS'
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
            // AST-021 restyle: renderAssistantPicker's keyboard nav toggles
            // .ast-picker-active per row -- see the identical stub in
            // section-assistant-selection.sh's harness.
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
        // AST-022 restyle: production rows are now built via innerHTML
        // templates (name/aliases/badge spans) instead of a bare
        // textContent assignment -- mirror real DOM's live textContent
        // (tag-stripped) so existing "row.textContent.includes(name)"
        // pins keep working against the new markup (stub-failure-semantics:
        // extend the harness, don't fork it).
        set innerHTML(v){ this._innerHTMLv = v; if(v === "") this._items.length = 0; this.textContent = v.replace(/<[^>]*>/g, ""); },
        get innerHTML(){ return this._innerHTMLv || ""; },
        disabled: false,
        title: "",
        textContent: "",
        appendChild(child){ this._items.push(child); },
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
const document = {
    getElementById(id) {
        return elements[id] || null;
    },
    createElement(_tag) {
        const el = mkEl(null);
        el.classList._parent = el;
        return el;
    },
};

// AST-021 restyle (Option C command palette, issue #318): #ast-picker-anchor
// is new static boot furniture renderAssistantPicker appends into -- see
// the identical comment in section-assistant-selection.sh's harness.
// #399: ast-switcher is gone (dock removed); ast-digest-panel/
// ast-digest-close are its digest-relocation replacement, wired by
// wireAssistantSwitchUi below.
const STATIC_IDS = ["sect-voice", "voice-stt", "voice-in", "voice-out", "voice-both", "voicebar", "ast-picker-anchor", "ast-ask-again", "ast-digest-panel", "ast-digest-close", "ast-digest", "voice-viz-name", "ast-switch-dropdown", "ast-switch-list", "ast-switch-hint"];
for (const id of STATIC_IDS) {
    const el = mkEl(id);
    el.classList._parent = el;
}
elements["ast-digest-panel"].hidden = true;
// #399: the switch dropdown ships hidden; open flips it (and refuses to
// double-open), so the stub must start from the real initial state.
elements["ast-switch-dropdown"].hidden = true;

global.window = global;
let fetchCalls = [];
let statusResponse = null;
let settingsResponse = { askAgain: false };
let selectResponse = null;
global.fetch = async (url, opts) => {
    fetchCalls.push({url, opts});
    if (url === "/assistant/status") {
        return { json: async () => statusResponse };
    }
    if (url === "/assistant/settings") {
        return { json: async () => settingsResponse };
    }
    // #399: openAssistantSwitchPicker's palette row click POSTs here and
    // reads back `digest` -- selectResponse lets tests control that.
    if (url === "/assistant/select") {
        return { json: async () => selectResponse || {} };
    }
    return { json: async () => ({}) };
};

// AST-021 restyle: renderAssistantPicker binds/unbinds a real document-level
// keydown listener while the palette is open -- see the identical stub in
// section-assistant-selection.sh's harness for the full rationale.
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
// fireKeydown drives every currently-bound listener on one shared event
// object, real-Event style -- same helper section-assistant-selection.sh
// and section-assistant-inspector.sh already use for Esc ownership; here
// it also exercises the ⌘K/Ctrl+K binding (#399).
function fireKeydown(props) {
    const ev = Object.assign({ defaultPrevented: false, preventDefault(){ this.defaultPrevented = true; } }, props);
    for (const fn of [...(global.__listeners.keydown || [])]) fn(ev);
}
const flushMicrotasks = () => new Promise(r => setTimeout(r, 0));

eval(extract("setVoiceHeaderName"));
eval(extract("gateVoiceAndChat"));
// AST-021 restyle: isChatTypingTarget/unbindAssistantPickerKeys are real
// production helpers renderAssistantPicker now calls -- extracted here too
// so this stays the real wiring instead of a simplified fork.
eval(extract("isChatTypingTarget"));
eval(extract("unbindAssistantPickerKeys"));
eval(extract("renderAssistantPicker"));
eval(extract("renderNoneOverlay"));
// AST-024 (#321): renderAssistantPicker's row click now also calls
// renderAssistantDigest -- extracted here too so this harness keeps
// exercising the REAL production wiring rather than drifting into a
// simplified fork (stub-failure-semantics lesson: extend, don't fork).
eval(extract("renderAssistantDigest"));
eval(extract("escapeHtml"));
eval(extract("setAskAgainUi"));
eval(extract("refreshAssistantSettingsUi"));
eval(extract("initAssistantSelection"));
// #399: the label-as-selector dropdown + ⌘K/Ctrl+K quick switch that
// replaced the removed switcher/dock.
eval(extract("astShortcutKeys"));
eval(extract("renderShortcutKeycaps"));
eval(extract("unbindAssistantSwitchDropdownKeys"));
eval(extract("closeAssistantSwitchDropdown"));
eval(extract("openAssistantSwitchDropdown"));
eval(extract("toggleAssistantSwitchDropdown"));
eval(extract("quickSwitchAssistant"));
eval(extract("handleAssistantSwitchKeydown"));
eval(extract("wireAssistantSwitchUi"));

async function run(outcome, candidates, selected, askAgain) {
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
    // mirrors a real page reload's clean slate -- see the identical comment
    // in section-assistant-selection.sh's run().
    global.__listeners.keydown = [];
    window.__astPickerKeydown = null;
    fetchCalls = [];
    statusResponse = {outcome, candidates, selected: selected || null, gated: outcome !== "one" && !selected, askAgain: !!askAgain};
    await initAssistantSelection();
}

(async () => {
    // ---- remembered selection (askAgain false): no picker, applies directly ----
    await run("multiple", [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}], "friday", false);
    if (document.getElementById("ast-picker")) throw new Error("a remembered selection must not re-show the picker");
    if (document.getElementById("voice-stt").disabled) throw new Error("a remembered selection must un-gate voice");
    if (document.getElementById("voice-viz-name").textContent !== "friday") throw new Error("remembered selection did not render the name beside the bars (395)");
    console.log("REMEMBERED_OK true");

    // ---- askAgain true: server already reports selected=null on boot, picker still shows ----
    await run("multiple", [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}], null, true);
    if (!document.getElementById("ast-picker")) throw new Error("askAgain=true must still show the picker on boot");
    console.log("ASKAGAIN_PICKER_OK true");

    // ---- #399 (human refinement): the label IS the selector -- click (or
    // Cmd+K/Ctrl+K) toggles the compact #ast-switch-dropdown anchored at
    // the label. The boot-time AST-021 palette above stays untouched (it
    // still Skips/gates); the dropdown's close paths never skip and never
    // touch the gate. Clean slate first: no picker/keydown listeners left
    // over from the run()-based boot scenarios above.
    delete elements["ast-picker"];
    delete elements["ast-picker-wrap"];
    global.__listeners.keydown = [];
    window.__astPickerKeydown = null;
    window.__astSwitchKeydown = null;
    wireAssistantSwitchUi();
    if (!elements["voice-viz-name"].title.includes("K")) throw new Error("label tooltip must carry the platform shortcut");

    // label click fetches FRESH candidates and opens the dropdown: rows
    // rendered (current one marked), keycap chips in the hint, label
    // aria-expanded flipped
    fetchCalls = [];
    statusResponse = {outcome: "multiple", candidates: [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: ["fri"], root: "/b"}], selected: "jarvis", gated: false, askAgain: true};
    elements["voice-viz-name"].onclick();
    await flushMicrotasks();
    if (!fetchCalls.some(c => c.url === "/assistant/status")) throw new Error("label click did not fetch fresh /assistant/status");
    if (elements["ast-switch-dropdown"].hidden !== false) throw new Error("label click did not open the dropdown");
    const swList = elements["ast-switch-list"];
    if (swList.children.length !== 2) throw new Error("dropdown expected 2 rows, got " + swList.children.length);
    const selRow = swList.children.find(r => r.textContent.includes("jarvis"));
    if (!selRow || !selRow.className.includes("ast-switch-row-selected")) throw new Error("current assistant not marked selected in the dropdown");
    if (!elements["ast-switch-hint"].innerHTML.includes("ast-kbd")) throw new Error("dropdown hint must render keycap chips");
    if (!/\u2318|Ctrl/.test(elements["ast-switch-hint"].innerHTML)) throw new Error("keycap chips must show the platform modifier");
    if (elements["voice-viz-name"].getAttribute("aria-expanded") !== "true") throw new Error("label aria-expanded must be true while open");
    console.log("LABEL_OPENS_SWITCH_DROPDOWN_OK true");

    // picking a row selects, updates the label, closes the dropdown, and
    // reveals the relocated digest panel (AST-024, #321)
    fetchCalls = [];
    const fridayRow = swList.children.find(r => r.textContent.includes("friday"));
    selectResponse = {selected: "friday", gated: false, digest: {sinceTs: null, notesMinted: [], exchanges: 1, tasks: [], tasksSource: "pending-E4"}};
    await fridayRow.onclick();
    const switchSelect = fetchCalls.find(c => c.url === "/assistant/select");
    if (!switchSelect || JSON.parse(switchSelect.opts.body).name !== "friday") throw new Error("dropdown row click did not select friday");
    if (document.getElementById("voice-viz-name").textContent !== "friday") throw new Error("dropdown row click did not update the label beside the bars");
    if (elements["ast-switch-dropdown"].hidden !== true) throw new Error("dropdown did not close after a pick");
    if (elements["voice-viz-name"].getAttribute("aria-expanded") !== "false") throw new Error("label aria-expanded must reset on close");
    if (elements["ast-digest-panel"].hidden !== false) throw new Error("a real switch's digest must reveal the relocated panel");
    console.log("DROPDOWN_SELECT_OK true");

    // 2026-07-25 human refinement: Cmd+K QUICK-SWITCHES to the next
    // assistant (wrapping) -- no panel. selected=friday of [jarvis,friday]
    // -> Cmd+K selects jarvis.
    fetchCalls = [];
    statusResponse = {outcome: "multiple", candidates: [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}], selected: "friday", gated: false, askAgain: true};
    selectResponse = {selected: "jarvis", gated: false};
    fireKeydown({key: "k", metaKey: true});
    await flushMicrotasks();
    const cyc = fetchCalls.find(c => c.url === "/assistant/select");
    if (!cyc || JSON.parse(cyc.opts.body).name !== "jarvis") throw new Error("Cmd+K did not quick-switch to the next assistant, got: " + (cyc ? cyc.opts.body : "no select"));
    if (document.getElementById("voice-viz-name").textContent !== "jarvis") throw new Error("quick-switch did not update the label");
    if (elements["ast-switch-dropdown"].hidden !== true) throw new Error("quick-switch must not leave the panel open");
    console.log("CMDK_CYCLES_OK true");

    // wrap-around: selected=jarvis (index 0) -> Ctrl+K -> friday
    fetchCalls = [];
    statusResponse = {outcome: "multiple", candidates: [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}], selected: "jarvis", gated: false, askAgain: true};
    selectResponse = {selected: "friday", gated: false};
    fireKeydown({key: "K", ctrlKey: true, target: {tagName: "DIV"}});
    await flushMicrotasks();
    const cyc2 = fetchCalls.find(c => c.url === "/assistant/select");
    if (!cyc2 || JSON.parse(cyc2.opts.body).name !== "friday") throw new Error("Ctrl+K wrap did not select friday");
    console.log("CMDK_WRAPS_OK true");

    // single candidate: nothing to cycle -- falls back to opening the panel
    fetchCalls = [];
    statusResponse = {outcome: "multiple", candidates: [{name: "jarvis", aliases: [], root: "/a"}], selected: "jarvis", gated: false, askAgain: true};
    fireKeydown({key: "k", metaKey: true});
    await flushMicrotasks();
    if (fetchCalls.some(c => c.url === "/assistant/skip")) throw new Error("single-candidate Cmd+K must never skip");
    if (elements["ast-switch-dropdown"].hidden !== false) throw new Error("single-candidate Cmd+K should open the panel as the fallback");
    fireKeydown({key: "Escape"});
    console.log("CMDK_SINGLE_FALLBACK_OK true");

    // typing target suppresses the shortcut entirely
    fetchCalls = [];
    fireKeydown({key: "K", ctrlKey: true, target: {tagName: "INPUT"}});
    await flushMicrotasks();
    if (fetchCalls.length) throw new Error("Ctrl+K in a typing target must be inert");
    console.log("CTRLK_AND_TYPING_GUARD_OK true");

    // ArrowDown+Enter: highlight starts on the CURRENT assistant, one
    // arrow reaches the neighbor, Enter selects it. Opened via label CLICK
    // (2026-07-25: clicking opens the panel; ⌘K quick-switches instead).
    fireKeydown({key: "Escape"});
    statusResponse = {outcome: "multiple", candidates: [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}], selected: "jarvis", gated: false, askAgain: true};
    elements["voice-viz-name"].onclick();
    await flushMicrotasks();
    fetchCalls = [];
    selectResponse = {selected: "friday", gated: false};
    fireKeydown({key: "ArrowDown"});
    fireKeydown({key: "Enter"});
    await flushMicrotasks();
    const kbSelect = fetchCalls.find(c => c.url === "/assistant/select");
    if (!kbSelect || JSON.parse(kbSelect.opts.body).name !== "friday") throw new Error("ArrowDown+Enter did not select the next assistant, got: " + (kbSelect ? kbSelect.opts.body : "no select call"));
    console.log("DROPDOWN_KEYBOARD_SELECT_OK true");

    // Escape closes only the dropdown -- no skip, no gating (opened by click)
    statusResponse = {outcome: "multiple", candidates: [{name: "jarvis", aliases: [], root: "/a"}], selected: "friday", gated: false, askAgain: true};
    elements["voice-viz-name"].onclick();
    await flushMicrotasks();
    fetchCalls = [];
    fireKeydown({key: "Escape"});
    if (elements["ast-switch-dropdown"].hidden !== true) throw new Error("Escape did not close the dropdown");
    if (fetchCalls.some(c => c.url === "/assistant/skip")) throw new Error("Escape on the dropdown must never Skip");
    console.log("ESC_CLOSES_DROPDOWN_OK true");

    // the ⌘K keydown listener wired by wireAssistantSwitchUi is the only
    // one left once the dropdown's own (open-only) listener has unbound
    if ((global.__listeners.keydown || []).length !== 1) throw new Error("expected exactly the ⌘K listener left after the dropdown closed, got " + (global.__listeners.keydown || []).length);
    console.log("CMDK_LISTENER_SOLE_SURVIVOR_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_mem_out="$(node "$_asm_node" "$NVHTML_MEM" 2>&1)"
tmpl_mem_rc=$?
rm -f "$_asm_node"
check_rc "template selection-memory script exits 0" 0 "$tmpl_mem_rc"
check "template: a remembered selection (askAgain false) skips the picker and applies" "REMEMBERED_OK true" "$tmpl_mem_out"
check "template: askAgain true still shows the picker on boot" "ASKAGAIN_PICKER_OK true" "$tmpl_mem_out"
# #399: dock removed by human direction -- SWITCHER_OK/SWITCHER_CLICK_OK
# (the old #ast-switcher row list) are superseded by the label/⌘K palette
# coverage below, since the label IS the selector now.
check "template (#399): clicking the assistant-name label fetches fresh candidates and opens the anchored dropdown (rows, selected mark, keycaps, aria-expanded)" "LABEL_OPENS_SWITCH_DROPDOWN_OK true" "$tmpl_mem_out"
check "template (#399): picking a dropdown row selects, updates the label, closes, and reveals the relocated digest panel" "DROPDOWN_SELECT_OK true" "$tmpl_mem_out"
check "template (2026-07-25): Cmd+K quick-switches to the next assistant, panel stays closed" "CMDK_CYCLES_OK true" "$tmpl_mem_out"
check "template (2026-07-25): the quick-switch wraps past the last assistant" "CMDK_WRAPS_OK true" "$tmpl_mem_out"
check "template (2026-07-25): single candidate falls back to opening the panel, never skips" "CMDK_SINGLE_FALLBACK_OK true" "$tmpl_mem_out"
check "template (#399): a typing target suppresses the shortcut" "CTRLK_AND_TYPING_GUARD_OK true" "$tmpl_mem_out"
check "template (#399): ArrowDown+Enter select the neighbor of the current assistant" "DROPDOWN_KEYBOARD_SELECT_OK true" "$tmpl_mem_out"
check "template (#399): Escape closes only the dropdown -- never a Skip" "ESC_CLOSES_DROPDOWN_OK true" "$tmpl_mem_out"
check "template (#399): only the always-on ⌘K listener remains once the dropdown closes" "CMDK_LISTENER_SOLE_SURVIVOR_OK true" "$tmpl_mem_out"
if [[ "$tmpl_mem_rc" -ne 0 ]]; then echo "$tmpl_mem_out" >&2; fi

check "template pins the ast-ask-again class/id name in source" 'ast-ask-again' "$(cat "$NVHTML_MEM")"
check_absent "template no longer pins the removed ast-switcher class name (#399)" '"ast-switcher"' "$(cat "$NVHTML_MEM")"
check "template pins the ast-digest-panel id in source (digest relocation target, #399)" 'ast-digest-panel' "$(cat "$NVHTML_MEM")"
check "template pins the ast-digest-close id in source (click-to-dismiss, #399)" 'ast-digest-close' "$(cat "$NVHTML_MEM")"
