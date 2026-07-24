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

echo "-- template: askAgain boot honoring + switcher + toggle wiring --"
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
        set innerHTML(v){ this._innerHTMLv = v; if(v === "") this._items.length = 0; },
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

const STATIC_IDS = ["sect-voice", "voice-mic", "voice-in", "voice-out", "voice-both", "voicebar", "ast-ask-again", "ast-switcher", "ast-digest"];
for (const id of STATIC_IDS) {
    const el = mkEl(id);
    el.classList._parent = el;
}

global.window = global;
let fetchCalls = [];
let statusResponse = null;
let settingsResponse = { askAgain: false };
global.fetch = async (url, opts) => {
    fetchCalls.push({url, opts});
    if (url === "/assistant/status") {
        return { json: async () => statusResponse };
    }
    if (url === "/assistant/settings") {
        return { json: async () => settingsResponse };
    }
    return { json: async () => ({}) };
};

eval(extract("setVoiceHeaderName"));
eval(extract("gateVoiceAndChat"));
eval(extract("renderAssistantPicker"));
eval(extract("renderNoneOverlay"));
// AST-024 (#321): renderAssistantSwitcher's row click now also calls
// renderAssistantDigest -- extracted here too so this harness keeps
// exercising the REAL production wiring rather than drifting into a
// simplified fork (stub-failure-semantics lesson: extend, don't fork).
eval(extract("renderAssistantDigest"));
eval(extract("renderAssistantSwitcher"));
eval(extract("setAskAgainUi"));
eval(extract("refreshAssistantSettingsUi"));
eval(extract("initAssistantSelection"));

async function run(outcome, candidates, selected, askAgain) {
    delete elements["ast-picker"];
    delete elements["ast-none-overlay"];
    for (const id of STATIC_IDS) {
        const el = elements[id];
        el.disabled = false;
        el.textContent = id === "sect-voice" ? "Voice" : "";
        el.children = [];
        el._classes = new Set();
    }
    fetchCalls = [];
    statusResponse = {outcome, candidates, selected: selected || null, gated: outcome !== "one" && !selected, askAgain: !!askAgain};
    await initAssistantSelection();
}

(async () => {
    // ---- remembered selection (askAgain false): no picker, applies directly ----
    await run("multiple", [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}], "friday", false);
    if (document.getElementById("ast-picker")) throw new Error("a remembered selection must not re-show the picker");
    if (document.getElementById("voice-mic").disabled) throw new Error("a remembered selection must un-gate voice");
    if (document.getElementById("sect-voice").textContent !== "Voice · friday") throw new Error("remembered selection did not set the header");
    console.log("REMEMBERED_OK true");

    // ---- askAgain true: server already reports selected=null on boot, picker still shows ----
    await run("multiple", [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}], null, true);
    if (!document.getElementById("ast-picker")) throw new Error("askAgain=true must still show the picker on boot");
    console.log("ASKAGAIN_PICKER_OK true");

    // ---- switcher renders candidates and marks the selected one -------------
    const sw = document.getElementById("ast-switcher");
    renderAssistantSwitcher([{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}], "friday");
    if (sw.children.length !== 2) throw new Error("switcher expected 2 rows, got " + sw.children.length);
    for (const r of sw.children) if (!r.className.includes("ast-switcher-row")) throw new Error("switcher row missing ast-switcher-row class");
    const selectedRow = sw.children.find(r => r.textContent.includes("friday"));
    if (!selectedRow || !selectedRow.className.includes("ast-switcher-selected")) throw new Error("selected candidate not marked in switcher");
    console.log("SWITCHER_OK true");

    // clicking a switcher row re-POSTs select
    fetchCalls = [];
    const jarvisRow = sw.children.find(r => r.textContent.includes("jarvis"));
    statusResponse = {outcome: "multiple", candidates: [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}], selected: "jarvis", gated: false, askAgain: true};
    await jarvisRow.onclick();
    const switchSelect = fetchCalls.find(c => c.url === "/assistant/select");
    if (!switchSelect || JSON.parse(switchSelect.opts.body).name !== "jarvis") throw new Error("switcher row click did not select jarvis");
    const refreshed = fetchCalls.find(c => c.url === "/assistant/status");
    if (!refreshed) throw new Error("switcher row click did not refresh status");
    console.log("SWITCHER_CLICK_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_mem_out="$(node "$_asm_node" "$NVHTML_MEM" 2>&1)"
tmpl_mem_rc=$?
rm -f "$_asm_node"
check_rc "template selection-memory script exits 0" 0 "$tmpl_mem_rc"
check "template: a remembered selection (askAgain false) skips the picker and applies" "REMEMBERED_OK true" "$tmpl_mem_out"
check "template: askAgain true still shows the picker on boot" "ASKAGAIN_PICKER_OK true" "$tmpl_mem_out"
check "template: switcher renders candidate rows and marks the selected one" "SWITCHER_OK true" "$tmpl_mem_out"
check "template: clicking a switcher row re-selects and refreshes status" "SWITCHER_CLICK_OK true" "$tmpl_mem_out"
if [[ "$tmpl_mem_rc" -ne 0 ]]; then echo "$tmpl_mem_out" >&2; fi

check "template pins the ast-ask-again class/id name in source" 'ast-ask-again' "$(cat "$NVHTML_MEM")"
check "template pins the ast-switcher class name in source" '"ast-switcher"' "$(cat "$NVHTML_MEM")"
check "template pins the ast-switcher-row class name in source" 'ast-switcher-row' "$(cat "$NVHTML_MEM")"
