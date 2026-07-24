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
        },
        children: [],
        disabled: false,
        title: "",
        textContent: "",
        appendChild(child){ this.children.push(child); },
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
    createElement(_tag) {
        const el = mkEl(null);
        el.classList._parent = el;
        return el;
    },
};

// Static page furniture that really exists in the template's HTML at boot
// (the voice panel header/mic/direction buttons, the voicebar container
// the picker/overlay get appended into) -- pre-registered once, reset
// per-run() below, unlike the ast-* ids the selection functions create
// themselves each time.
// AST-022 (§7.5): ast-ask-again/ast-switcher are the ⚙ panel's static
// furniture (present in the HTML at boot, same as sect-voice etc above) --
// initAssistantSelection now unconditionally refreshes them, so they need
// to exist as real elements here too even though this section doesn't
// assert on them (section-assistant-selection-memory.sh does).
const STATIC_IDS = ["sect-voice", "voice-mic", "voice-in", "voice-out", "voice-both", "voicebar", "ast-ask-again", "ast-switcher"];
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

eval(extract("setVoiceHeaderName"));
eval(extract("gateVoiceAndChat"));
eval(extract("renderAssistantPicker"));
eval(extract("renderNoneOverlay"));
eval(extract("renderAssistantSwitcher"));
eval(extract("setAskAgainUi"));
eval(extract("initAssistantSelection"));

async function run(outcome, candidates) {
    // dynamic ids the selection functions create/remove themselves --
    // dropped so each run starts from "nothing rendered yet", exactly
    // like a fresh page boot.
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
    statusResponse = {outcome, candidates, selected: null, gated: outcome !== "one"};
    await initAssistantSelection();
}

(async () => {
    // ---- outcome one: silent auto-select + header name ----
    await run("one", [{name: "jarvis", aliases: ["jay"], root: "/r"}]);
    const autoSelect = fetchCalls.find(c => c.url === "/assistant/select");
    if (!autoSelect) throw new Error("outcome one did not auto-POST /assistant/select");
    if (JSON.parse(autoSelect.opts.body).name !== "jarvis") throw new Error("outcome one selected the wrong candidate");
    if (document.getElementById("sect-voice").textContent !== "Voice · jarvis") throw new Error("header did not get the main name: " + document.getElementById("sect-voice").textContent);
    if (document.getElementById("voice-mic").disabled) throw new Error("outcome one left voice-mic disabled");
    console.log("ONE_OK true");

    // ---- outcome multiple: picker rendered, rows wired, gated until a pick ----
    await run("multiple", [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}]);
    const picker = document.getElementById("ast-picker");
    if (!picker) throw new Error("outcome multiple did not render a picker");
    if (!picker.className.includes("ast-picker")) throw new Error("picker missing ast-picker class");
    if (picker.children.length !== 3) throw new Error("expected 2 rows + skip, got " + picker.children.length);
    const rows = picker.children.slice(0, 2);
    for (const r of rows) if (!r.className.includes("ast-picker-row")) throw new Error("picker row missing ast-picker-row class");
    const skipBtn = picker.children[2];
    if (!skipBtn.className.includes("ast-skip")) throw new Error("skip control missing ast-skip class");
    if (!document.getElementById("voice-mic").disabled) throw new Error("outcome multiple must gate voice before a pick");
    console.log("MULTIPLE_OK true");

    // picking a row selects + un-gates + sets header
    fetchCalls = [];
    await rows[0].onclick();
    const pickSelect = fetchCalls.find(c => c.url === "/assistant/select");
    if (!pickSelect || JSON.parse(pickSelect.opts.body).name !== "jarvis") throw new Error("picker row click did not select jarvis");
    if (document.getElementById("voice-mic").disabled) throw new Error("picking a candidate did not un-gate voice");
    console.log("PICK_OK true");

    // Skip disables voice
    await run("multiple", [{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}]);
    fetchCalls = [];
    await document.getElementById("ast-picker").children[2].onclick();
    const skipCall = fetchCalls.find(c => c.url === "/assistant/skip");
    if (!skipCall) throw new Error("Skip did not POST /assistant/skip");
    if (!document.getElementById("voice-mic").disabled) throw new Error("Skip did not gate voice-mic");
    console.log("SKIP_OK true");

    // ---- outcome none: red overlay + hover explainer + hard gate ----
    await run("none", []);
    const overlay = document.getElementById("ast-none-overlay");
    if (!overlay) throw new Error("outcome none did not render the overlay");
    if (!overlay.className.includes("ast-none-overlay")) throw new Error("overlay missing ast-none-overlay class");
    if (overlay.textContent !== "set up an assistant") throw new Error("overlay text mismatch: " + overlay.textContent);
    if (!overlay.title || overlay.title.indexOf("/setup-assistant") === -1) throw new Error("overlay hover title missing /setup-assistant explainer: " + overlay.title);
    if (!document.getElementById("voice-mic").disabled) throw new Error("outcome none did not gate voice-mic");
    console.log("NONE_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_out="$(node "$_as_node" "$NVHTML" 2>&1)"
tmpl_rc=$?
rm -f "$_as_node"
check_rc "template selection script exits 0" 0 "$tmpl_rc"
check "template: outcome one auto-selects + sets the header main name" "ONE_OK true" "$tmpl_out"
check "template: outcome multiple renders a picker with pinned class hooks" "MULTIPLE_OK true" "$tmpl_out"
check "template: picking a picker row selects and un-gates voice" "PICK_OK true" "$tmpl_out"
check "template: Skip gates voice off" "SKIP_OK true" "$tmpl_out"
check "template: outcome none renders the red overlay + hover explainer + hard gate" "NONE_OK true" "$tmpl_out"
if [[ "$tmpl_rc" -ne 0 ]]; then echo "$tmpl_out" >&2; fi

check "template pins the ast-picker class name in source" '"ast-picker"' "$(cat "$NVHTML")"
check "template pins the ast-none-overlay class name in source" '"ast-none-overlay"' "$(cat "$NVHTML")"
