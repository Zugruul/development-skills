#!/usr/bin/env bash
# section-neural-view-search-shortcut.sh -- issue #409: Cmd/Ctrl+L focuses
# the sidebar search input, with a platform keycap-chip affordance beside
# the search bar matching #399's ⌘K/Ctrl+K assistant-switch chips. Sourced
# by run-tests.sh; do not run standalone. Contract: the runner already
# defines set -uo pipefail and has sourced _lib.sh (check/check_rc/
# check_absent) and set HERE/PLUGIN/FIX/fails/flaky before sourcing this
# file. This file assumes those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== neural-view search shortcut: Cmd/Ctrl+L focus + keycap chips (issue #409) =="
NVHTML_SEARCHKEY="$PLUGIN/templates/neural-view.html"

_nvsk_node="$(mktemp).cjs"
cat >"$_nvsk_node" <<'NODEJS'
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
        get children(){ return this._items; },
        set innerHTML(v){ this._innerHTMLv = v; this.textContent = v.replace(/<[^>]*>/g, ""); },
        get innerHTML(){ return this._innerHTMLv || ""; },
        _focused: false,
        focus(){ this._focused = true; },
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
    getElementById(id) { return elements[id] || null; },
    createElement(_tag) {
        const el = mkEl(null);
        el.classList._parent = el;
        return el;
    },
};

// Static furniture this feature touches: the search input itself plus the
// two "modal, owns-keyboard" surfaces the shortcut must defer to -- the
// T-key chat overlay (#320) and the boot-time AST-021 picker (#318), same
// gating concept #399/quick-switch's own Cmd+K uses for its typing-target
// guard. Both start absent (not open), same as a fresh page load.
const STATIC_IDS = ["search-input", "search-kbd"];
for (const id of STATIC_IDS) {
    const el = mkEl(id);
    el.classList._parent = el;
}

global.window = global;
// Node >=22 ships its own read-only global `navigator` -- a plain
// `global.navigator = {...}` silently no-ops against it (non-strict-mode
// assignment to a getter-only accessor), so a real defineProperty is
// required to actually override it in this harness.
function setNavigator(platform){
    Object.defineProperty(global, "navigator", { value: { platform }, configurable: true });
}
setNavigator("MacIntel");
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
    const ev = Object.assign({ defaultPrevented: false, preventDefault(){ this.defaultPrevented = true; } }, props);
    for (const fn of [...(global.__listeners.keydown || [])]) fn(ev);
    return ev;
}

eval(extract("astShortcutKeys"));
eval(extract("focusSearchInput"));
eval(extract("isKeyboardOwnedByOverlay"));
eval(extract("handleSearchFocusKeydown"));
eval(extract("wireSearchShortcutUi"));

(async () => {
    global.__listeners.keydown = [];
    elements["search-input"]._focused = false;
    wireSearchShortcutUi();

    // ---- Cmd+L (metaKey) focuses the search input and preventDefault()s ----
    elements["search-input"]._focused = false;
    let ev = fireKeydown({key: "l", metaKey: true, target: {tagName: "DIV"}});
    if (!elements["search-input"]._focused) throw new Error("Cmd+L did not focus the search input");
    if (!ev.defaultPrevented) throw new Error("Cmd+L must preventDefault() so the browser's own address-bar focus does not also fire");
    console.log("CMDL_FOCUSES_OK true");

    // ---- Ctrl+L (ctrlKey) does the same, uppercase L too ----
    elements["search-input"]._focused = false;
    ev = fireKeydown({key: "L", ctrlKey: true, target: {tagName: "DIV"}});
    if (!elements["search-input"]._focused) throw new Error("Ctrl+L did not focus the search input");
    if (!ev.defaultPrevented) throw new Error("Ctrl+L must preventDefault()");
    console.log("CTRLL_FOCUSES_OK true");

    // ---- works from ANOTHER input/textarea too -- unlike the T-key/⌘K
    // shortcuts (which go inert on any typing target), Cmd/Ctrl+L is meant
    // to work "from anywhere", same as a browser's own address-bar focus.
    elements["search-input"]._focused = false;
    ev = fireKeydown({key: "l", metaKey: true, target: {tagName: "INPUT"}});
    if (!elements["search-input"]._focused) throw new Error("Cmd+L must still focus search when firing from another text input");
    if (!ev.defaultPrevented) throw new Error("Cmd+L from another input must still preventDefault()");
    console.log("CMDL_FROM_OTHER_INPUT_OK true");

    // ---- gated while the T-key chat overlay owns keyboard input ----
    elements["search-input"]._focused = false;
    const chatOverlay = document.createElement("div");
    chatOverlay.id = "ast-chat-overlay";
    ev = fireKeydown({key: "l", metaKey: true, target: {tagName: "DIV"}});
    if (elements["search-input"]._focused) throw new Error("Cmd+L must not fire while the T-key chat overlay is open");
    if (ev.defaultPrevented) throw new Error("a gated Cmd+L must not preventDefault() either -- it never acted");
    chatOverlay.remove();
    console.log("GATED_WHILE_CHAT_OVERLAY_OK true");

    // ---- gated while the boot-time AST-021 picker owns keyboard input ----
    elements["search-input"]._focused = false;
    const pickerWrap = document.createElement("div");
    pickerWrap.id = "ast-picker-wrap";
    ev = fireKeydown({key: "L", ctrlKey: true, target: {tagName: "DIV"}});
    if (elements["search-input"]._focused) throw new Error("Cmd/Ctrl+L must not fire while the boot picker is open");
    if (ev.defaultPrevented) throw new Error("a gated Ctrl+L must not preventDefault() either");
    pickerWrap.remove();
    console.log("GATED_WHILE_BOOT_PICKER_OK true");

    // ---- once the overlay/picker are gone again, the shortcut works ----
    elements["search-input"]._focused = false;
    fireKeydown({key: "l", metaKey: true, target: {tagName: "DIV"}});
    if (!elements["search-input"]._focused) throw new Error("Cmd+L must resume working once the gating overlay is gone");
    console.log("UNGATED_AFTER_CLOSE_OK true");

    // ---- Cmd/Ctrl+F is reserved -- must never focus/act ----
    elements["search-input"]._focused = false;
    ev = fireKeydown({key: "f", metaKey: true, target: {tagName: "DIV"}});
    if (elements["search-input"]._focused) throw new Error("Cmd+F must NOT be bound to search focus (reserved for a future feature)");
    if (ev.defaultPrevented) throw new Error("Cmd+F must be left completely alone -- no preventDefault()");
    console.log("CMDF_NOT_BOUND_OK true");

    // ---- keycap chip markup: platform-aware, same .ast-kbd class #399 uses ----
    if (!elements["search-kbd"].innerHTML.includes("ast-kbd")) throw new Error("search-kbd must render .ast-kbd keycap chips, same class the ⌘K chips use");
    if (!elements["search-kbd"].innerHTML.includes("L")) throw new Error("search-kbd chips must show the L keycap label");
    if (!/⌘/.test(elements["search-kbd"].innerHTML)) throw new Error("mac platform must render the ⌘ glyph, not \"Cmd\"");
    console.log("CHIP_MARKUP_MAC_OK true");

    // ---- non-mac platform renders Ctrl instead of ⌘ ----
    setNavigator("Win32");
    wireSearchShortcutUi();
    if (!/Ctrl/.test(elements["search-kbd"].innerHTML)) throw new Error("non-mac platform must render \"Ctrl\", not the mac glyph");
    console.log("CHIP_MARKUP_WIN_OK true");

    // ---- clicking the chip focuses the search input, same action as the shortcut ----
    elements["search-input"]._focused = false;
    elements["search-kbd"].onclick();
    if (!elements["search-input"]._focused) throw new Error("clicking the search-kbd chip must focus the search input");
    console.log("CHIP_CLICK_FOCUSES_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
nvsk_out="$(node "$_nvsk_node" "$NVHTML_SEARCHKEY" 2>&1)"
nvsk_rc=$?
rm -f "$_nvsk_node"
check_rc "search-shortcut template script exits 0" 0 "$nvsk_rc"
check "template: Cmd+L focuses the search input and preventDefault()s" "CMDL_FOCUSES_OK true" "$nvsk_out"
check "template: Ctrl+L (uppercase L) does the same" "CTRLL_FOCUSES_OK true" "$nvsk_out"
check "template: Cmd+L still works when fired from another text input" "CMDL_FROM_OTHER_INPUT_OK true" "$nvsk_out"
check "template: Cmd+L is gated while the T-key chat overlay is open" "GATED_WHILE_CHAT_OVERLAY_OK true" "$nvsk_out"
check "template: Cmd/Ctrl+L is gated while the boot picker is open" "GATED_WHILE_BOOT_PICKER_OK true" "$nvsk_out"
check "template: the shortcut resumes working once the gating overlay closes" "UNGATED_AFTER_CLOSE_OK true" "$nvsk_out"
check "template: Cmd/Ctrl+F is reserved -- never bound to search focus" "CMDF_NOT_BOUND_OK true" "$nvsk_out"
check "template: search-kbd renders platform-aware .ast-kbd chips (mac glyph)" "CHIP_MARKUP_MAC_OK true" "$nvsk_out"
check "template: search-kbd renders \"Ctrl\" on non-mac platforms" "CHIP_MARKUP_WIN_OK true" "$nvsk_out"
check "template: clicking the search-kbd chip focuses the search input" "CHIP_CLICK_FOCUSES_OK true" "$nvsk_out"
if [[ "$nvsk_rc" -ne 0 ]]; then echo "$nvsk_out" >&2; fi

check "template pins the search-kbd id in source" 'id="search-kbd"' "$(cat "$NVHTML_SEARCHKEY")"
check "template pins the search-kbd .ast-kbd chip class reuse in source" '#search-kbd .ast-kbd' "$(cat "$NVHTML_SEARCHKEY")"
check_absent "Cmd/Ctrl+F is never bound in source (reserved for a future feature)" '"f" && (ev.metaKey' "$(cat "$NVHTML_SEARCHKEY")"
check_absent "Cmd/Ctrl+F is never bound in source (uppercase form either)" 'key !== "f" && ev.key !== "F"' "$(cat "$NVHTML_SEARCHKEY")"
