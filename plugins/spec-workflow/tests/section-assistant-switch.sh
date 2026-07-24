#!/usr/bin/env bash
# section-assistant-switch.sh -- AST-024: switch flow -- flush, reload,
# activation digest (SPEC-ASSISTANT.md §7.7/§7.8, issue #321). Sourced by
# run-tests.sh; do not run standalone. Contract: the runner already
# defines set -uo pipefail and has sourced _lib.sh (check/check_rc/
# check_absent) and set HERE/PLUGIN/FIX/fails/flaky before sourcing this
# file. This file assumes those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant switch flow (AST-024: flush/reload/digest, SPEC-ASSISTANT.md §7.7/§7.8) =="

ASW_SCRIPTS="$PLUGIN/scripts"

# asw_repo <dir> <main> -- mirrors section-assistant-selection-memory.sh's asm_repo.
asw_repo() {
    local dir="$1" main="$2"
    mkdir -p "$dir/.claude"
    printf '%s\n' '# neural-network' >"$dir/.claude/.neural-network"
    printf '%s\n' \
        'schemaVersion: 2' \
        'assistant:' \
        '    version: 1' \
        '    enabled: true' \
        "    names: [$main]" \
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

echo "-- engine: digest.py module (notes/exchanges since ts, tasks pending-E4) --"
_asw_digest_root="$(mktemp -d)"
asw_repo "$_asw_digest_root" jarvis

digest_out="$(ROOT="$_asw_digest_root" SCRIPTS_DIR="$ASW_SCRIPTS" python3 - <<'PY'
import os, sys, json
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import digest
from assistant.store import SessionStore

root = os.environ["ROOT"]

# no brain-events.jsonl / session.jsonl yet -- digest degrades cleanly
d0 = digest.digest(root, None)
print("EMPTY_SINCE", d0["sinceTs"])
print("EMPTY_NOTES", d0["notesMinted"])
print("EMPTY_EXCHANGES", d0["exchanges"])
print("EMPTY_TASKS", d0["tasks"])
print("EMPTY_TASKS_SOURCE", d0["tasksSource"])

events_path = os.path.join(root, ".claude", "brain-events.jsonl")
os.makedirs(os.path.dirname(events_path), exist_ok=True)
with open(events_path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"v": 1, "ts": "2020-01-01T00:00:00+00:00", "repo": "jarvis",
                          "role": "assistant", "type": "NoteMinted", "slug": "old-slug",
                          "strength": 1}) + "\n")
    fh.write(json.dumps({"v": 1, "ts": "2030-01-01T00:00:00+00:00", "repo": "jarvis",
                          "role": "assistant", "type": "NoteMinted", "slug": "new-slug",
                          "strength": 2}) + "\n")
    # a different role mint must not count toward this digest
    fh.write(json.dumps({"v": 1, "ts": "2030-01-01T00:00:00+00:00", "repo": "jarvis",
                          "role": "dev", "type": "NoteMinted", "slug": "dev-slug",
                          "strength": 1}) + "\n")
    # a non-mint event type must not count either
    fh.write(json.dumps({"v": 1, "ts": "2030-01-01T00:00:00+00:00", "repo": "jarvis",
                          "role": "assistant", "type": "LinkFormed", "key": "x~y"}) + "\n")
    fh.write("{not json\n")  # torn line -- tolerated, never raises

store = SessionStore(root)
store.append_exchange("hi (old)", "hello (old)")
d_unbounded = digest.digest(root, None)
print("UNBOUNDED_NOTE_SLUGS", sorted(n["slug"] for n in d_unbounded["notesMinted"]))
print("UNBOUNDED_EXCHANGES", d_unbounded["exchanges"])

since_ts = "2025-01-01T00:00:00+00:00"
d_since = digest.digest(root, since_ts)
print("SINCE_ECHOED", d_since["sinceTs"])
print("SINCE_NOTE_SLUGS", sorted(n["slug"] for n in d_since["notesMinted"]))
store.append_exchange("hi (new)", "hello (new)")
d_since2 = digest.digest(root, since_ts)
# both real exchanges above were appended with a real current timestamp,
# which postdates since_ts (2025-01-01) -- so BOTH count, not just the one
# appended after this call. since_ts is a fixed point in the past, not a
# marker moved as the test runs.
print("SINCE_EXCHANGES", d_since2["exchanges"])

# a root that does not exist at all -- degrades to the same empty shape,
# never raises
d_missing_root = digest.digest(os.path.join(root, "does-not-exist"), None)
print("MISSING_ROOT_NOTES", d_missing_root["notesMinted"])
print("MISSING_ROOT_EXCHANGES", d_missing_root["exchanges"])
PY
)"
rc=$?
check_rc "digest.py script exits 0" 0 "$rc"
check "digest(): sinceTs=None echoes null" "EMPTY_SINCE None" "$digest_out"
check "digest(): no events file -> empty notesMinted" "EMPTY_NOTES []" "$digest_out"
check "digest(): no transcript -> 0 exchanges" "EMPTY_EXCHANGES 0" "$digest_out"
check "digest(): tasks always []" "EMPTY_TASKS []" "$digest_out"
check "digest(): tasksSource pending-E4" "EMPTY_TASKS_SOURCE pending-E4" "$digest_out"
check "digest(): since=None picks up both role-matched mints, not other roles/types" "UNBOUNDED_NOTE_SLUGS ['new-slug', 'old-slug']" "$digest_out"
check "digest(): since=None counts the one exchange so far" "UNBOUNDED_EXCHANGES 1" "$digest_out"
check "digest(): sinceTs is echoed back unchanged" "SINCE_ECHOED 2025-01-01T00:00:00+00:00" "$digest_out"
check "digest(): since a bound -- only the note minted strictly after it" "SINCE_NOTE_SLUGS ['new-slug']" "$digest_out"
check "digest(): since a bound -- counts every real exchange after it" "SINCE_EXCHANGES 2" "$digest_out"
check "digest(): a nonexistent root degrades to empty notes, never raises" "MISSING_ROOT_NOTES []" "$digest_out"
check "digest(): a nonexistent root degrades to 0 exchanges, never raises" "MISSING_ROOT_EXCHANGES 0" "$digest_out"
rm -rf "$_asw_digest_root"

echo "-- engine: /assistant/select switch flow -- lastActive, digest-on-change-only, worker registry untouched --"
_asw_a="$(mktemp -d)"
_asw_b="$(mktemp -d)"
asw_repo "$_asw_a" jarvis
asw_repo "$_asw_b" friday
_asw_state="$(mktemp -d)"

switch_out="$(SCRIPTS_DIR="$ASW_SCRIPTS" MA="$_asw_a" MB="$_asw_b" STATE="$_asw_state" python3 - <<'PY'
import os, sys, json, time
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import engine

repos = lambda: [("a", os.environ["MA"]), ("b", os.environ["MB"])]
state_dir = os.environ["STATE"]
root_b = os.environ["MB"]

e = engine.AssistantEngine(repos, state_dir)
e.start()
workers_before = list(e.workers)

# ---- initial select: no digest (nothing to switch FROM) -----------------
code, p1, _ = e.handle("POST", "/assistant/select", body={"name": "jarvis"})
print("INITIAL_CODE", code)
print("INITIAL_HAS_DIGEST", "digest" in p1)

# ---- same-name reselect: no digest (no change) ---------------------------
code, p2, _ = e.handle("POST", "/assistant/select", body={"name": "jarvis"})
print("RESELECT_HAS_DIGEST", "digest" in p2)

# ---- seed friday brain-events with a note BEFORE it is ever active ------
events_path = os.path.join(root_b, ".claude", "brain-events.jsonl")
os.makedirs(os.path.dirname(events_path), exist_ok=True)
with open(events_path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"v": 1, "ts": "2020-01-01T00:00:00+00:00", "repo": "friday",
                          "role": "assistant", "type": "NoteMinted", "slug": "first-ever",
                          "strength": 1}) + "\n")

# ---- real switch: jarvis -> friday, friday never active before ----------
code, p3, _ = e.handle("POST", "/assistant/select", body={"name": "friday"})
print("SWITCH1_CODE", code)
print("SWITCH1_SELECTED", p3["selected"])
print("SWITCH1_HAS_DIGEST", "digest" in p3)
print("SWITCH1_DIGEST_SLUGS", sorted(n["slug"] for n in p3["digest"]["notesMinted"]))
print("SWITCH1_TASKS_SOURCE", p3["digest"]["tasksSource"])

# worker registry identical object list -- a switch never touches it
print("WORKERS_UNCHANGED", e.workers == workers_before)
print("WORKERS_STILL_ALIVE", all(t.is_alive() for _, t, _ in e.workers))

# ---- switch back to jarvis; friday lastActive is now stamped ------------
code, p4, _ = e.handle("POST", "/assistant/select", body={"name": "jarvis"})
print("SWITCH2_HAS_DIGEST", "digest" in p4)

# a note minted in friday repo AFTER it went inactive
with open(events_path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"v": 1, "ts": "2099-01-01T00:00:00+00:00", "repo": "friday",
                          "role": "assistant", "type": "NoteMinted", "slug": "while-inactive",
                          "strength": 1}) + "\n")

# ---- switch to friday again: digest only shows the note minted SINCE it went inactive ----
code, p5, _ = e.handle("POST", "/assistant/select", body={"name": "friday"})
print("SWITCH3_DIGEST_SLUGS", sorted(n["slug"] for n in p5["digest"]["notesMinted"]))

# ---- persistence: a fresh engine over the same state_dir sees the same lastActive-derived digest ----
e2 = engine.AssistantEngine(repos, state_dir)
code, p6, _ = e2.handle("POST", "/assistant/select", body={"name": "jarvis"})
print("RESTART_SWITCH_HAS_DIGEST", "digest" in p6)

e.stop()
e2.stop()
PY
)"
rc=$?
check_rc "switch flow script exits 0" 0 "$rc"
check "initial select exits 200" "INITIAL_CODE 200" "$switch_out"
check "initial select carries no digest (nothing to switch from)" "INITIAL_HAS_DIGEST False" "$switch_out"
check "same-name reselect carries no digest (no change)" "RESELECT_HAS_DIGEST False" "$switch_out"
check "real switch exits 200" "SWITCH1_CODE 200" "$switch_out"
check "real switch selects the target" "SWITCH1_SELECTED friday" "$switch_out"
check "real switch carries a digest" "SWITCH1_HAS_DIGEST True" "$switch_out"
check "digest on first-ever activation includes prior history" "SWITCH1_DIGEST_SLUGS ['first-ever']" "$switch_out"
check "digest tasks section is honestly pending-E4" "SWITCH1_TASKS_SOURCE pending-E4" "$switch_out"
check "a switch never mutates the worker registry" "WORKERS_UNCHANGED True" "$switch_out"
check "both assistants' workers stay alive across a switch (§7.7 keep-both-running)" "WORKERS_STILL_ALIVE True" "$switch_out"
check "switching back to jarvis (first ever activation) carries a digest too" "SWITCH2_HAS_DIGEST True" "$switch_out"
check "digest strictly since last active excludes what happened before that switch" "SWITCH3_DIGEST_SLUGS ['while-inactive']" "$switch_out"
check "lastActive persists: a fresh engine's switch still produces a digest" "RESTART_SWITCH_HAS_DIGEST True" "$switch_out"

rm -rf "$_asw_a" "$_asw_b" "$_asw_state"

echo "-- selection_store: lastActive additive persistence + backward compat --"
_asw_store_dir="$(mktemp -d)"
store_out="$(SCRIPTS_DIR="$ASW_SCRIPTS" STATE="$_asw_store_dir" python3 - <<'PY'
import os, sys, json
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from assistant import selection_store

state_dir = os.environ["STATE"]

# a pre-AST-024 file with no lastActive key at all
with open(os.path.join(state_dir, "assistant-selection.json"), "w", encoding="utf-8") as fh:
    json.dump({"selected": "jarvis", "gated": False, "askAgain": False}, fh)
loaded = selection_store.load(state_dir)
print("LEGACY_LAST_ACTIVE", loaded["lastActive"])
print("LEGACY_SELECTED", loaded["selected"])

selection_store.save(state_dir, "jarvis", False, False, {"jarvis": "2020-01-01T00:00:00+00:00"})
loaded2 = selection_store.load(state_dir)
print("ROUNDTRIP_LAST_ACTIVE", loaded2["lastActive"])

# save() with no last_active argument at all -- defaults to {}
selection_store.save(state_dir, "jarvis", False, False)
loaded3 = selection_store.load(state_dir)
print("DEFAULT_LAST_ACTIVE", loaded3["lastActive"])

# a malformed lastActive value degrades to {} rather than crashing
with open(os.path.join(state_dir, "assistant-selection.json"), "w", encoding="utf-8") as fh:
    json.dump({"selected": "jarvis", "gated": False, "askAgain": False, "lastActive": "not-a-dict"}, fh)
loaded4 = selection_store.load(state_dir)
print("MALFORMED_LAST_ACTIVE", loaded4["lastActive"])
PY
)"
rc=$?
check_rc "selection_store lastActive script exits 0" 0 "$rc"
check "a pre-AST-024 file with no lastActive key loads as {}" "LEGACY_LAST_ACTIVE {}" "$store_out"
check "legacy load still reads selected fine" "LEGACY_SELECTED jarvis" "$store_out"
check "lastActive round-trips through save/load" "ROUNDTRIP_LAST_ACTIVE {'jarvis': '2020-01-01T00:00:00+00:00'}" "$store_out"
check "save() with no last_active arg defaults to {}" "DEFAULT_LAST_ACTIVE {}" "$store_out"
check "a malformed lastActive value degrades to {}, never crashes" "MALFORMED_LAST_ACTIVE {}" "$store_out"
rm -rf "$_asw_store_dir"

echo "-- template: switcher click renders the digest; empty digest renders ast-digest-empty --"
NVHTML_SWITCH="$PLUGIN/templates/neural-view.html"

_asw_node="$(mktemp).cjs"
cat >"$_asw_node" <<'NODEJS'
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
let selectResponse = null;
global.fetch = async (url, opts) => {
    fetchCalls.push({url, opts});
    if (url === "/assistant/status") {
        return { json: async () => ({outcome: "multiple", candidates: [], selected: null, gated: false, askAgain: false}) };
    }
    if (url === "/assistant/select") {
        return { json: async () => selectResponse };
    }
    return { json: async () => ({}) };
};

eval(extract("renderAssistantDigest"));
eval(extract("setVoiceHeaderName"));
eval(extract("gateVoiceAndChat"));
eval(extract("renderAssistantSwitcher"));
eval(extract("setAskAgainUi"));
eval(extract("refreshAssistantSettingsUi"));

(async () => {
    // ---- renderAssistantDigest with no payload leaves the element empty ----
    elements["ast-digest"].innerHTML = "";
    renderAssistantDigest(null);
    if (elements["ast-digest"].children.length !== 0) throw new Error("null digest must render nothing");
    console.log("NULL_DIGEST_OK true");

    // ---- an all-empty digest renders the ast-digest-empty placeholder row ----
    renderAssistantDigest({sinceTs: "2020-01-01T00:00:00+00:00", notesMinted: [], exchanges: 0, tasks: [], tasksSource: "pending-E4"});
    const emptyRow = elements["ast-digest"].children.find(r => r.className.includes("ast-digest-empty"));
    if (!emptyRow) throw new Error("empty digest must render an ast-digest-empty row");
    console.log("EMPTY_DIGEST_OK true");

    // ---- a populated digest renders one ast-digest-note row per note + exchanges ----
    renderAssistantDigest({sinceTs: "2020-01-01T00:00:00+00:00",
        notesMinted: [{slug: "some-note", strength: 3, ts: "2020-01-02T00:00:00+00:00"}],
        exchanges: 2, tasks: [], tasksSource: "pending-E4"});
    const noteRows = elements["ast-digest"].children.filter(r => r.className.includes("ast-digest-note"));
    if (noteRows.length < 2) throw new Error("expected at least a note row and an exchanges row, got " + noteRows.length);
    if (!noteRows.some(r => r.textContent.includes("some-note"))) throw new Error("digest did not render the minted note's slug");
    if (!noteRows.some(r => r.textContent.includes("2 exchanges"))) throw new Error("digest did not render the exchange count");
    console.log("POPULATED_DIGEST_OK true");

    // ---- switcher row click renders the digest carried on the select response ----
    const sw = elements["ast-switcher"];
    renderAssistantSwitcher([{name: "jarvis", aliases: [], root: "/a"}, {name: "friday", aliases: [], root: "/b"}], "jarvis");
    const fridayRow = sw.children.find(r => r.textContent.includes("friday"));
    selectResponse = {selected: "friday", gated: false, digest: {sinceTs: "2020-01-01T00:00:00+00:00",
        notesMinted: [{slug: "clicked-note", strength: 1, ts: "2020-01-02T00:00:00+00:00"}],
        exchanges: 0, tasks: [], tasksSource: "pending-E4"}};
    await fridayRow.onclick();
    const rowsAfterClick = elements["ast-digest"].children.filter(r => r.className.includes("ast-digest-note"));
    if (!rowsAfterClick.some(r => r.textContent.includes("clicked-note"))) throw new Error("switcher click did not render the select response's digest");
    console.log("SWITCH_CLICK_RENDERS_DIGEST_OK true");

    // ---- a select response with NO digest key (initial pick / same-name reselect) clears any stale row ----
    selectResponse = {selected: "friday", gated: false};
    await fridayRow.onclick();
    console.log("NO_DIGEST_RESPONSE_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
tmpl_switch_out="$(node "$_asw_node" "$NVHTML_SWITCH" 2>&1)"
tmpl_switch_rc=$?
rm -f "$_asw_node"
check_rc "template switch script exits 0" 0 "$tmpl_switch_rc"
check "template: a null digest renders nothing" "NULL_DIGEST_OK true" "$tmpl_switch_out"
check "template: an all-empty digest renders the ast-digest-empty placeholder" "EMPTY_DIGEST_OK true" "$tmpl_switch_out"
check "template: a populated digest renders note + exchange rows" "POPULATED_DIGEST_OK true" "$tmpl_switch_out"
check "template: clicking a switcher row renders the digest from the select response" "SWITCH_CLICK_RENDERS_DIGEST_OK true" "$tmpl_switch_out"
check "template: a digest-less select response does not crash the click handler" "NO_DIGEST_RESPONSE_OK true" "$tmpl_switch_out"
if [[ "$tmpl_switch_rc" -ne 0 ]]; then echo "$tmpl_switch_out" >&2; fi

check "template pins the ast-digest class/id name in source" '"ast-digest"' "$(cat "$NVHTML_SWITCH")"
check "template pins the ast-digest-note class name in source" 'ast-digest-note' "$(cat "$NVHTML_SWITCH")"
check "template pins the ast-digest-empty class name in source" 'ast-digest-empty' "$(cat "$NVHTML_SWITCH")"
