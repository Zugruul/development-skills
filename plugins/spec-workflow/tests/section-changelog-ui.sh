#!/usr/bin/env bash
# section-changelog-ui.sh -- #405: status-chip-driven changelog overlay.
# Sourced by run-tests.sh; do not run standalone. Contract: the runner
# already defines set -uo pipefail and has sourced _lib.sh (check/check_rc/
# check_absent/lifecycle_start/_rand_port) and set HERE/PLUGIN/FIX/fails/
# flaky before sourcing this file. This file assumes those are already in
# scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== changelog overlay (#405): chip click targets, parser, Escape ownership, GET /changelog =="
NVHTML_CL="$PLUGIN/templates/neural-view.html"

echo "-- template: parseChangelog()/render/open-close/Esc lifecycle (extract() + eval() harness, same style as section-assistant-inspector.sh) --"
_cl_node="$(mktemp).cjs"
cat >"$_cl_node" <<'NODEJS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");

function extract(name) {
    const re = new RegExp("(?:async )?function " + name + "\\([^)]*\\)\\{[\\s\\S]*?\\n\\}\\n");
    const m = html.match(re);
    if (!m) throw new Error("could not find function " + name + "() in template");
    return m[0];
}

// DOM stub -- same "getter-only children Proxy" shape as
// section-assistant-inspector.sh's, trimmed to what buildChangelogWindow()/
// wireWinDrag() actually touch.
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
        title: "",
        textContent: "",
        style: {},
        hidden: false,
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
        remove(){
            if (this._id && elements[this._id] === this) delete elements[this._id];
            for (const child of this._items || []) if (child && typeof child.remove === "function") child.remove();
        },
        get className(){ return [...this._classes].join(" "); },
        set className(v){ this._classes = new Set(v.split(" ").filter(Boolean)); },
        setAttribute(k, v){ this[k === "class" ? "className" : k] = v; this["_attr_" + k] = v; },
        getAttribute(k){ return this["_attr_" + k] !== undefined ? this["_attr_" + k] : null; },
        querySelector(sel){ return queryAll(this, sel)[0] || null; },
        querySelectorAll(sel){ return queryAll(this, sel); },
        addEventListener(){},
        removeEventListener(){},
        setPointerCapture(){},
        releasePointerCapture(){},
    };
    if (initialId) elements[initialId] = el;
    return el;
}
function matchesSel(el, sel) {
    if (sel[0] === ".") return !!(el.classList && el.classList.contains(sel.slice(1)));
    if (sel[0] === "[" && sel[sel.length - 1] === "]") return el.getAttribute && el.getAttribute(sel.slice(1, -1)) !== null;
    return false;
}
function queryAll(el, sel) {
    const out = [];
    for (const child of el._items || []) {
        if (matchesSel(child, sel)) out.push(child);
        out.push(...queryAll(child, sel));
    }
    return out;
}
const docBody = mkEl(null);
const document = {
    body: docBody,
    getElementById(id) { return elements[id] || null; },
    createElement(_tag) {
        const el = mkEl(null);
        el.classList._parent = el;
        return el;
    },
};
global.window = global;
global.noteWinZ = 70;

// keydown listener stub -- same "stub addEventListener, drive it with
// fireKeydown()" harness style as section-assistant-inspector.sh.
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

let fetchCalls = [];
let changelogText = null;   // set per-test; null -> reject (simulated network failure)
let changelogStatus = 200;
global.fetch = async (url) => {
    fetchCalls.push({url});
    if (url === "/changelog") {
        if (changelogText === null) throw new Error("network down");
        return { status: changelogStatus, ok: changelogStatus === 200, text: async () => changelogText };
    }
    return { status: 200, ok: true, text: async () => "" };
};

eval(extract("escapeHtml"));
eval(extract("chipHtml"));
eval(extract("wireWinDrag"));
eval(extract("parseChangelog"));
eval(extract("changelogEntryHtml"));
eval(extract("changelogVersionHtml"));
eval(extract("buildChangelogWindow"));
eval(extract("closeChangelogWindow"));
eval(extract("handleChangelogKeydown"));
eval(extract("openChangelogWindow"));

const flushMicrotasks = () => new Promise(r => setTimeout(r, 0));

function resetChangelogWindow() {
    delete elements["changelog-window"];
    docBody._items.length = 0;
    global.__listeners.keydown = [];
    window.changelogWin = null;
    window.__changelogKeydown = null;
    fetchCalls = [];
    changelogText = null;
    changelogStatus = 200;
}

const FIXTURE = [
    "# Changelog",
    "",
    "<!-- GENERATED by plugins/spec-workflow/scripts/changelog.py -- do not edit by hand. -->",
    "",
    "## v0.30.1 — 2026-07-26",
    "",
    "### Fixes",
    "- **399:** voice-panel polish round 2 (#399) (`adb7735`)",
    "  > Human-directed live refinements: the caret is replaced.",
    "  > second body line.",
    "",
    "### Documentation",
    "- **design:** ast-E6 epic design doc (`a57e3bc`)",
    "",
    "## v0.30.0 — 2026-07-20",
    "",
    "### Features",
    "- add widget (`1234567`)",
    "",
].join("\n");

(async () => {
    // ---- parser: fixture -> versions/groups/entries/bodies, newest first ----
    const versions = parseChangelog(FIXTURE);
    if (versions.length !== 2) throw new Error("expected 2 versions, got " + versions.length);
    if (versions[0].version !== "0.30.1" || versions[0].date !== "2026-07-26") throw new Error("version 0 header mismatch: " + JSON.stringify(versions[0]));
    if (versions[1].version !== "0.30.0" || versions[1].date !== "2026-07-20") throw new Error("version 1 (older) header mismatch: " + JSON.stringify(versions[1]));
    if (versions[0].groups.length !== 2) throw new Error("expected 2 groups in v0.30.1, got " + versions[0].groups.length);
    if (versions[0].groups[0].name !== "Fixes" || versions[0].groups[1].name !== "Documentation") throw new Error("group names/order wrong: " + JSON.stringify(versions[0].groups.map(g => g.name)));
    const fixEntry = versions[0].groups[0].entries[0];
    if (fixEntry.scope !== "399") throw new Error("scoped entry scope mismatch: " + JSON.stringify(fixEntry));
    if (fixEntry.desc !== "voice-panel polish round 2 (#399)") throw new Error("scoped entry desc mismatch: " + JSON.stringify(fixEntry));
    if (fixEntry.hash !== "adb7735") throw new Error("scoped entry hash mismatch: " + JSON.stringify(fixEntry));
    if (fixEntry.body.length !== 2 || fixEntry.body[0] !== "Human-directed live refinements: the caret is replaced.") throw new Error("entry body lines mismatch: " + JSON.stringify(fixEntry.body));
    const docEntry = versions[0].groups[1].entries[0];
    if (docEntry.body.length !== 0) throw new Error("bodyless entry must have an empty body array: " + JSON.stringify(docEntry));
    const unscopedEntry = versions[1].groups[0].entries[0];
    if (unscopedEntry.scope !== "" || unscopedEntry.desc !== "add widget") throw new Error("unscoped entry parse mismatch: " + JSON.stringify(unscopedEntry));
    console.log("PARSER_STRUCTURE_OK true");

    // ---- CRLF input (Windows autocrlf checkout of CHANGELOG.md) must not
    // silently drop body lines: bodyRe alone (`^ {2}> (.*)$`, no trailing
    // \s*$ slack unlike versionRe/entryRe/groupRe) never matches a line
    // still carrying its trailing \r -- the fix splits on /\r?\n/ instead of
    // a bare \n so no line, of any kind, keeps a trailing \r. ----
    const crlfFixture = FIXTURE.split("\n").join("\r\n");
    const crlfVersions = parseChangelog(crlfFixture);
    if (crlfVersions.length !== 2) throw new Error("CRLF input: expected 2 versions, got " + crlfVersions.length);
    const crlfFixEntry = crlfVersions[0].groups[0].entries[0];
    if (crlfFixEntry.body.length !== 2) throw new Error("CRLF input: body lines must still parse, got " + JSON.stringify(crlfFixEntry.body));
    if (crlfFixEntry.body[0] !== "Human-directed live refinements: the caret is replaced.") throw new Error("CRLF input: body line content mismatch (stray \\r?): " + JSON.stringify(crlfFixEntry.body[0]));
    if (/\r/.test(crlfFixEntry.body[0]) || /\r/.test(crlfFixEntry.desc)) throw new Error("CRLF input: parsed fields must not carry a stray \\r");
    console.log("CRLF_INPUT_OK true");

    // ---- render: newest-expanded default (idx 0 open, others collapsed) ----
    const html0 = changelogVersionHtml(versions[0], 0);
    const html1 = changelogVersionHtml(versions[1], 1);
    // check the VERSION-level body's hidden attribute specifically (id="cl-ver-N") --
    // entries with a merge-description body render their own, independently
    // collapsed disclosure (id="cl-body-...", always hidden by default
    // regardless of which version they're in), so a blanket " hidden>"
    // substring check would false-positive on those.
    if (!html0.includes("cl-open") || html0.includes('id="cl-ver-0" hidden')) throw new Error("newest version must render expanded (cl-open, body not hidden): " + html0);
    if (html1.includes("cl-open") || !html1.includes('id="cl-ver-1" hidden')) throw new Error("non-newest version must render collapsed (hidden body, no cl-open): " + html1);
    if (!html0.includes("adb7735")) throw new Error("rendered version must include its entry hash");
    console.log("RENDER_DEFAULT_EXPANSION_OK true");

    // ---- open builds the window, fetches once, binds one keydown listener ----
    resetChangelogWindow();
    changelogText = FIXTURE;
    const win1 = await openChangelogWindow();
    await flushMicrotasks();
    if (!win1 || win1.id !== "changelog-window") throw new Error("openChangelogWindow did not build the window");
    if (docBody._items.indexOf(win1) === -1) throw new Error("window was not appended to document.body");
    if (window.changelogWin !== win1) throw new Error("window.changelogWin not set to the opened window");
    if (fetchCalls.filter(c => c.url === "/changelog").length !== 1) throw new Error("opening the window did not fetch /changelog exactly once");
    if ((global.__listeners.keydown || []).length !== 1) throw new Error("open must bind exactly one keydown listener, got " + (global.__listeners.keydown || []).length);
    const bodyEl = document.getElementById("changelog-body");
    if (!bodyEl.innerHTML.includes("adb7735")) throw new Error("successful fetch must render the parsed changelog into the body: " + bodyEl.innerHTML);
    console.log("OPEN_BUILDS_AND_LOADS_OK true");

    // ---- reopening while open focuses (same window, no re-fetch, no dup listener) ----
    const zBefore = win1.style.zIndex;
    fetchCalls = [];
    const win2 = await openChangelogWindow();
    if (win2 !== win1) throw new Error("reopening while open must return the SAME window, not a duplicate");
    if (Number(win2.style.zIndex) <= Number(zBefore)) throw new Error("reopening while open must raise z-index (focus)");
    if (fetchCalls.length !== 0) throw new Error("reopening an already-open window must not re-fetch");
    if ((global.__listeners.keydown || []).length !== 1) throw new Error("reopening while open must not bind a second keydown listener");
    console.log("REOPEN_FOCUSES_OK true");

    // ---- closing tears down both the window and its keydown listener ----
    closeChangelogWindow();
    if (window.changelogWin !== null) throw new Error("close must clear window.changelogWin");
    if (document.getElementById("changelog-window")) throw new Error("close must remove the window from the DOM");
    if ((global.__listeners.keydown || []).length !== 0) throw new Error("close must unbind the keydown listener");
    if (window.__changelogKeydown !== null) throw new Error("close must clear window.__changelogKeydown");
    console.log("CLOSE_TEARS_DOWN_OK true");

    // ---- fetch failure / non-2xx never leaves a broken/empty panel -- a
    // single explanatory line inside the overlay, not console-only (#405) ----
    resetChangelogWindow();
    changelogText = null;   // fetch() rejects
    await openChangelogWindow();
    await flushMicrotasks();
    let failBody = document.getElementById("changelog-body");
    if (!failBody.innerHTML.includes("changelog unavailable:")) throw new Error("fetch failure must render an explanatory 'changelog unavailable:' line: " + failBody.innerHTML);
    console.log("FETCH_FAILURE_SHOWS_MESSAGE_OK true");

    resetChangelogWindow();
    changelogText = "not found";
    changelogStatus = 404;
    await openChangelogWindow();
    await flushMicrotasks();
    failBody = document.getElementById("changelog-body");
    if (!failBody.innerHTML.includes("changelog unavailable:")) throw new Error("a non-2xx response must render the same explanatory message, not a broken/empty panel: " + failBody.innerHTML);
    console.log("HTTP_ERROR_SHOWS_MESSAGE_OK true");

    // ---- Escape ownership: closes when it owns the keypress ----
    resetChangelogWindow();
    changelogText = FIXTURE;
    await openChangelogWindow();
    await flushMicrotasks();
    let ev = fireKeydown({key: "Escape"});
    if (window.changelogWin !== null) throw new Error("Esc must close the changelog window when it owns the keypress");
    if (!ev.defaultPrevented) throw new Error("Esc must call preventDefault when the changelog window handles it");
    console.log("ESC_CLOSES_OK true");

    // ---- Escape defers when another handler already claimed it (same
    // ev.defaultPrevented ownership handshake as the AST-044 inspector,
    // #330) -- must NOT close and must NOT call preventDefault again ----
    resetChangelogWindow();
    changelogText = FIXTURE;
    await openChangelogWindow();
    await flushMicrotasks();
    handleChangelogKeydown({key: "Escape", defaultPrevented: true, preventDefault(){ throw new Error("must not preventDefault an already-claimed event"); }});
    if (window.changelogWin === null) throw new Error("Esc must NOT close the changelog window when ev.defaultPrevented is already true (another handler owns it)");
    console.log("ESC_DEFERS_WHEN_ALREADY_CLAIMED_OK true");

    // ---- non-Escape keys are ignored ----
    handleChangelogKeydown({key: "a", defaultPrevented: false, preventDefault(){ throw new Error("must not preventDefault a non-Escape key"); }});
    if (window.changelogWin === null) throw new Error("a non-Escape keydown must not close the changelog window");
    closeChangelogWindow();
    console.log("ESC_ONLY_OK true");

    // ---- #410 review fix: chipHtml must escape segment TEXT, not just the
    // title -- CHIP_VER/CHIP_BRANCH now both carry file-sourced strings
    // (plugin.json's version, the serving repo's git branch), so unescaped
    // text is an HTML-injection vector the instant either contains markup
    // (statusEl.innerHTML renders the chip's raw HTML string). ----
    const evilText = '<img src=x onerror=alert(1)>';
    const evilChipHtml = chipHtml([[evilText, "a plain tooltip", "chip-changelog"]]);
    if (evilChipHtml.includes("<img")) throw new Error("chipHtml must escape segment text -- raw markup reached the rendered chip: " + evilChipHtml);
    if (!evilChipHtml.includes("&lt;img")) throw new Error("chipHtml must render the escaped form of injected segment text: " + evilChipHtml);
    console.log("CHIP_TEXT_ESCAPED_OK true");
})().catch(e => { console.error("FAIL", e.message); process.exit(1); });
NODEJS
if command -v node >/dev/null 2>&1; then
    cl_tmpl_out="$(node "$_cl_node" "$NVHTML_CL" 2>&1)"
    cl_tmpl_rc=$?
    check_rc "changelog template script exits 0" 0 "$cl_tmpl_rc"
    check "parser: fixture changelog string -> versions/groups/entries/bodies, newest first" "PARSER_STRUCTURE_OK true" "$cl_tmpl_out"
    check "parser: CRLF input (Windows autocrlf checkout) still parses body lines, no stray \\r leaks into any field" "CRLF_INPUT_OK true" "$cl_tmpl_out"
    check "render: newest version expanded by default, older versions collapsed" "RENDER_DEFAULT_EXPANSION_OK true" "$cl_tmpl_out"
    check "open builds the detached window, fetches /changelog once, binds one keydown listener" "OPEN_BUILDS_AND_LOADS_OK true" "$cl_tmpl_out"
    check "reopening while open focuses (same window, raised z-index, no re-fetch, no dup listener)" "REOPEN_FOCUSES_OK true" "$cl_tmpl_out"
    check "closing removes the window AND unbinds its keydown listener" "CLOSE_TEARS_DOWN_OK true" "$cl_tmpl_out"
    check "fetch failure renders an explanatory 'changelog unavailable:' line, never a broken/empty panel" "FETCH_FAILURE_SHOWS_MESSAGE_OK true" "$cl_tmpl_out"
    check "a non-2xx response renders the same explanatory message" "HTTP_ERROR_SHOWS_MESSAGE_OK true" "$cl_tmpl_out"
    check "Esc closes the changelog window when it owns the keypress" "ESC_CLOSES_OK true" "$cl_tmpl_out"
    check "Esc defers to an already-claimed event (defaultPrevented) instead of double-closing -- same handshake as the AST-044 inspector (#330)" "ESC_DEFERS_WHEN_ALREADY_CLAIMED_OK true" "$cl_tmpl_out"
    check "non-Escape keydowns are ignored by the changelog window's handler" "ESC_ONLY_OK true" "$cl_tmpl_out"
    check "chipHtml escapes segment TEXT (not just the title) -- HTML-injection fix (#410 review): CHIP_VER/CHIP_BRANCH now carry file-sourced strings (plugin.json version, git branch)" "CHIP_TEXT_ESCAPED_OK true" "$cl_tmpl_out"
    if [[ "$cl_tmpl_rc" -ne 0 ]]; then echo "$cl_tmpl_out" >&2; fi
else
    echo "SKIP changelog template script tests -- node not available"
fi
rm -f "$_cl_node"

echo "-- template: chip segments carry the clickable marker class + overlay class is pinned in source --"
# shellcheck disable=SC2016  # single-quoted on purpose -- pinning the literal
# template source text (including its own template-literal backticks), not a
# shell expansion.
check "CHIP_VER_FALLBACK carries the chip-changelog clickable marker class (chipHtml's optional 3rd segment element)" 'const CHIP_VER_FALLBACK = [`v${NV_VERSION}`,' "$(cat "$NVHTML_CL")"
check "CHIP_VER_FALLBACK's chip-changelog class is present" '"chip-changelog"];' "$(cat "$NVHTML_CL")"
check "CHIP_VER starts on the NV_VERSION-based fallback (deterministic pre-probe state, #410)" 'let CHIP_VER = CHIP_VER_FALLBACK;' "$(cat "$NVHTML_CL")"
check "CHIP_BRANCH is assigned with the chip-changelog clickable marker class" 'CHIP_BRANCH = [base.branch, "git branch the serving repo is on (read at server boot probe) — click to view the changelog", "chip-changelog"];' "$(cat "$NVHTML_CL")"
check "status chip click delegation opens/closes the changelog overlay via .chip-changelog" 'ev.target.closest(".chip-changelog")' "$(cat "$NVHTML_CL")"
check "changelog overlay reuses the note-window chrome family via the compound selector .note-window.changelog-window (same specificity-tie defense as .note-window.ast-inspector-window)" ".note-window.changelog-window{width:min(480px,92vw);max-height:80vh}" "$(cat "$NVHTML_CL")"
check "chipHtml() accepts an optional 3rd element (extra CSS class) per segment" 'map(([text, title, cls]) =>' "$(cat "$NVHTML_CL")"

echo "-- template: #410 -- CHIP_VER swaps to the plugin semver once /version delivers a non-null plugin field, keeping the chip-changelog clickable marker class and mentioning the template build number in its tooltip --"
# shellcheck disable=SC2016  # single-quoted on purpose -- pinning the literal
# template source text (including its own template-literal backticks/${...}),
# not a shell expansion.
check "CHIP_VER is reassigned from the /version probe's plugin field, with the chip-changelog clickable marker class" 'CHIP_VER = [`v${base.plugin}`, `plugin release version' "$(cat "$NVHTML_CL")"
check "the plugin-version tooltip names semver.sh as the bump mechanism (matches what the changelog overlay documents)" 'bumped by semver.sh at every merge' "$(cat "$NVHTML_CL")"
# shellcheck disable=SC2016  # single-quoted on purpose -- pinning literal
# template-literal ${...} source text, not a shell expansion.
check "the plugin-version tooltip demotes NV_VERSION to naming the template build" 'this tab'"'"'s template build is ${NV_VERSION}' "$(cat "$NVHTML_CL")"
# shellcheck disable=SC2016  # single-quoted on purpose -- pinning literal
# template-literal ${...} source text, not a shell expansion.
check "the plugin-version segment still carries the chip-changelog clickable marker class" 'this tab'"'"'s template build is ${NV_VERSION} — click to view the changelog`, "chip-changelog"];' "$(cat "$NVHTML_CL")"
check "the /version repaint guard fires on either a non-null plugin OR a branch (not branch alone) -- #410 needs the plugin-only case to repaint too" 'if(statusEl && !webglOK && base && (base.plugin || base.branch)){' "$(cat "$NVHTML_CL")"

echo "== changelog overlay (#405): GET /changelog route =="
NV_CL="$PLUGIN/scripts/neural-view.py"
_clroot="$(mktemp -d)"
_clstate="$(mktemp -d)"
_clscan_empty="$(mktemp -d)"
_clcwd="$(mktemp -d)"   # plain (non-git) tmp dir used as the server's cwd -- git_root() falls back to os.getcwd() here, so CHANGELOG.md's presence/absence at this path drives the route deterministically without touching the real repo's own CHANGELOG.md
export NEURAL_VIEW_STATE="$_clstate" NEURAL_VIEW_SCAN="$_clscan_empty"
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on purpose -- expanded when eval'd
lifecycle_start "neural-view starts (changelog route fixture)" NEURAL_VIEW_PORT '(cd "$_clcwd" && python3 "$NV_CL" start --dir "$_clroot")'
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/changelog")"
check "GET /changelog is a friendly 404 when CHANGELOG.md is absent" "404" "$code"
body="$(curl -s "http://127.0.0.1:$NEURAL_VIEW_PORT/changelog")"
check "GET /changelog's 404 body is a friendly message, not a stack trace" "changelog not found" "$body"
printf '%s\n' "# Changelog" "" "## v1.2.3 — 2026-01-01" "" "### Features" "- **x:** thing (\`abc1234\`)" >"$_clcwd/CHANGELOG.md"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/changelog")"
check "GET /changelog is 200 once CHANGELOG.md exists at the repo root" "200" "$code"
body="$(curl -sf "http://127.0.0.1:$NEURAL_VIEW_PORT/changelog")"
check "GET /changelog serves the file's raw content" "v1.2.3" "$body"
# shellcheck disable=SC2016  # single-quoted on purpose -- pinning the literal
# CHANGELOG.md fixture line (including its backticked hash), not a shell
# expansion.
check "GET /changelog serves the file's raw content verbatim (entry line included)" 'thing (`abc1234`)' "$body"
ctype="$(curl -s -D - -o /dev/null "http://127.0.0.1:$NEURAL_VIEW_PORT/changelog" | tr -d '\r' | grep -i '^content-type:')"
check "GET /changelog content-type is text/plain" "text/plain" "$ctype"

echo "== #410: GET /version's plugin field (one user-facing version -- the chip must match the changelog overlay's latest section) =="
body_v="$(curl -s "http://127.0.0.1:$NEURAL_VIEW_PORT/version")"
check "GET /version's plugin field is null when plugins/spec-workflow/.claude-plugin/plugin.json is absent under the serving repo root" '"plugin": null' "$body_v"
mkdir -p "$_clcwd/plugins/spec-workflow/.claude-plugin"
printf '%s\n' '{"name": "spec-workflow", "version": "9.9.9"}' >"$_clcwd/plugins/spec-workflow/.claude-plugin/plugin.json"
body_v="$(curl -s "http://127.0.0.1:$NEURAL_VIEW_PORT/version")"
check "GET /version's plugin field reflects plugin.json's version string" '"plugin": "9.9.9"' "$body_v"
printf '%s' 'not valid json{{{' >"$_clcwd/plugins/spec-workflow/.claude-plugin/plugin.json"
code_v="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$NEURAL_VIEW_PORT/version")"
check "GET /version stays 200 even when plugin.json is unparseable (never a 500/exception)" "200" "$code_v"
body_v="$(curl -s "http://127.0.0.1:$NEURAL_VIEW_PORT/version")"
check "GET /version's plugin field falls back to null when plugin.json is unparseable" '"plugin": null' "$body_v"
rm -rf "$_clcwd/plugins"
python3 "$NV_CL" stop >/dev/null
