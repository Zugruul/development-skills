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
            toggle(c, force){
                const on = force === undefined ? !this._parent._classes.has(c) : !!force;
                if (on) this._parent._classes.add(c); else this._parent._classes.delete(c);
                return on;
            },
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
        // parentNode is set on appendChild below -- backs closest() (#411:
        // the caret-click handler walks up from ev.target via .closest()
        // exactly like real DOM, so the stub needs a real parent chain to
        // exercise it, not just the downward queryAll() the pre-#411 tests
        // relied on).
        appendChild(child){ this._items.push(child); child._parentNode = this; },
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
        closest(sel){
            let el = this;
            while (el) {
                if (matchesSel(el, sel)) return el;
                el = el._parentNode || null;
            }
            return null;
        },
        addEventListener(){},
        removeEventListener(){},
        setPointerCapture(){},
        releasePointerCapture(){},
    };
    if (initialId) elements[initialId] = el;
    return el;
}
// tokenized so compound selectors (".cl-entry.cl-has-body") match same as
// real CSS -- the pre-#411 stub only ever needed single-part selectors.
function matchesSel(el, sel) {
    const tokens = sel.match(/\.[\w-]+|\[[^\]]+\]/g) || [];
    if (tokens.length === 0) return false;
    return tokens.every((t) => {
        if (t[0] === ".") return !!(el.classList && el.classList.contains(t.slice(1)));
        if (t[0] === "[") return el.getAttribute && el.getAttribute(t.slice(1, -1)) !== null;
        return false;
    });
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
eval(extract("renderMdBody"));
eval(extract("chipHtml"));
eval(extract("wireWinDrag"));
eval(extract("parseChangelog"));
eval(extract("changelogEntryHtml"));
eval(extract("changelogVersionHtml"));
eval(extract("handleChangelogBodyClick"));
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

    // ---- #411: bulk caret is its own element, separate from the header
    // text's data-cl-section hit target, on BOTH the open (idx 0) and
    // collapsed (idx 1) version renders -- entry bodies always start
    // collapsed regardless of section state, so the caret always renders
    // "expand available" (▸) at initial render, same glyph convention as
    // the per-entry disclosure. ----
    for (const [html, label] of [[html0, "open version"], [html1, "collapsed version"]]) {
        if (!/<span class="cl-version-caret" data-cl-caret="cl-ver-\d+"[^>]*>▸<\/span>/.test(html)) {
            throw new Error(`${label}: expected a state-aware bulk caret (cl-version-caret + data-cl-caret, starting "▸" since all entries start collapsed): ` + html);
        }
        if (!/<span class="cl-version-text" data-cl-section="cl-ver-\d+"/.test(html)) {
            throw new Error(`${label}: expected the header TEXT to carry its own data-cl-section hit target, separate from the caret: ` + html);
        }
    }
    console.log("CARET_RENDER_SEPARATE_STATE_AWARE_OK true");

    // ---- #429: exactly ONE caret glyph element per version row. #411 split
    // the bulk entries-control (cl-version-caret) out of the header text
    // span, but left #405's original section-toggle disclosure glyph
    // (.cl-disclosure) still rendered INSIDE cl-version-text -- a second,
    // dead-looking glyph sitting right beside the live state-aware caret
    // (screenshot: "▸ ▾ v0.28.0"). The header TEXT keeps its section-toggle
    // CLICK behavior (data-cl-section) -- only the redundant glyph markup
    // goes. ----
    for (const [html, label] of [[html0, "open version"], [html1, "collapsed version"]]) {
        const headMatch = html.match(/<div class="cl-version-head">[\s\S]*?<\/div>(?=<div class="cl-version-body")/);
        if (!headMatch) throw new Error(`${label}: could not isolate cl-version-head markup: ` + html);
        const head = headMatch[0];
        const discCount = (head.match(/class="cl-disclosure"/g) || []).length;
        if (discCount !== 0) throw new Error(`${label}: expected exactly ONE caret glyph per version row (no leftover .cl-disclosure inside cl-version-head), found ${discCount} extra: ` + head);
        if (!/data-cl-section="cl-ver-\d+"/.test(head)) throw new Error(`${label}: header text must still carry data-cl-section (section-toggle click behavior preserved): ` + head);
    }
    console.log("ONE_CARET_PER_VERSION_ROW_OK true");

    // ---- #411: hand-built fake DOM exercising handleChangelogBodyClick
    // directly -- the innerHTML setter in this stub (like the real one)
    // just stores a string, it never parses markup into a live tree, so
    // exercising click behavior on "rendered" content requires building
    // the equivalent node structure by hand, same shape changelogVersionHtml
    // /changelogEntryHtml produce. ----
    function buildFakeVersionSection(secId, sectionOpen, entryBodyHiddenStates) {
        const section = document.createElement("section");
        section.className = "cl-version" + (sectionOpen ? " cl-open" : "");
        const head = document.createElement("div");
        head.className = "cl-version-head";
        const caret = document.createElement("span");
        caret.className = "cl-version-caret";
        caret.setAttribute("data-cl-caret", secId);
        caret.textContent = "▸";
        const text = document.createElement("span");
        text.className = "cl-version-text";
        text.setAttribute("data-cl-section", secId);
        text.setAttribute("aria-expanded", String(sectionOpen));
        const textDisc = document.createElement("span");
        textDisc.className = "cl-disclosure";
        textDisc.textContent = sectionOpen ? "▾" : "▸";
        text.appendChild(textDisc);
        head.appendChild(caret);
        head.appendChild(text);
        section.appendChild(head);
        const panel = document.createElement("div");
        panel.className = "cl-version-body";
        panel.id = secId;
        panel.hidden = !sectionOpen;
        const bodies = [];
        entryBodyHiddenStates.forEach((bodyHidden, i) => {
            const entry = document.createElement("div");
            entry.className = "cl-entry cl-has-body";
            const row = document.createElement("div");
            row.className = "cl-entry-row";
            const rowDisc = document.createElement("span");
            rowDisc.className = "cl-disclosure";
            rowDisc.textContent = bodyHidden ? "▸" : "▾";
            row.appendChild(rowDisc);
            const body = document.createElement("div");
            body.className = "cl-body";
            body.id = secId + "-body-" + i;
            body.hidden = bodyHidden;
            entry.appendChild(row);
            entry.appendChild(body);
            panel.appendChild(entry);
            bodies.push(body);
        });
        section.appendChild(panel);
        return { section, head, caret, text, textDisc, panel, bodies };
    }
    function fireClick(target) {
        handleChangelogBodyClick({ target });
    }

    // caret click on a COLLAPSED section: opens the section AND expands
    // every entry body, and flips the caret to the "collapse" glyph.
    {
        const f = buildFakeVersionSection("cl-ver-t1", false, [true, true]);
        fireClick(f.caret);
        if (f.panel.hidden) throw new Error("caret click on a collapsed section must open it");
        if (!f.bodies.every((b) => !b.hidden)) throw new Error("caret click must expand every entry body");
        if (f.textDisc.textContent !== "▾") throw new Error("opening the section via the caret must also flip the section's own disclosure glyph to ▾");
        if (f.text.getAttribute("aria-expanded") !== "true") throw new Error("opening the section via the caret must set aria-expanded=true on the header text");
        if (!f.section.classList.contains("cl-open")) throw new Error("opening the section via the caret must add cl-open to the section");
        if (f.caret.textContent !== "▾") throw new Error("caret must flip to the state-aware \"collapse\" glyph (▾) once everything is expanded");
    }
    console.log("CARET_COLLAPSED_SECTION_EXPANDS_ALL_OK true");

    // caret click when everything is ALREADY expanded: collapses all entry
    // bodies, flips the caret back to "expand", and never touches the
    // section's own open/hidden state (collapsing entries != collapsing
    // the section).
    {
        const f = buildFakeVersionSection("cl-ver-t2", true, [false, false]);
        fireClick(f.caret);
        if (!f.bodies.every((b) => b.hidden)) throw new Error("caret click on a fully-expanded version must collapse every entry body");
        if (f.panel.hidden) throw new Error("collapsing all entries via the caret must NOT collapse the section itself");
        if (f.caret.textContent !== "▸") throw new Error("caret must flip back to the state-aware \"expand\" glyph (▸) once everything is collapsed");
    }
    console.log("CARET_ALL_EXPANDED_COLLAPSES_ALL_OK true");

    // caret click on a MIXED state (some entries open, some not): expand
    // wins -- it expands the rest rather than collapsing what's open.
    {
        const f = buildFakeVersionSection("cl-ver-t3", true, [true, false]);
        fireClick(f.caret);
        if (!f.bodies.every((b) => !b.hidden)) throw new Error("caret click on a mixed-state version must expand the rest (expand wins), got hidden=" + JSON.stringify(f.bodies.map((b) => b.hidden)));
        if (f.caret.textContent !== "▾") throw new Error("caret must show the \"collapse\" glyph once the mixed state resolves to fully expanded");
        console.log("CARET_MIXED_STATE_EXPAND_WINS_OK true");
    }

    // header TEXT click still only toggles the section -- it must not
    // touch any entry-body state or the caret's own glyph, even when that
    // state is mixed.
    {
        const f = buildFakeVersionSection("cl-ver-t4", false, [true, false]);
        fireClick(f.text);
        if (f.panel.hidden) throw new Error("header text click must still open the section");
        if (f.bodies[0].hidden !== true || f.bodies[1].hidden !== false) throw new Error("header text click must NOT touch entry-body states: " + JSON.stringify(f.bodies.map((b) => b.hidden)));
        if (f.caret.textContent !== "▸") throw new Error("header text click must NOT touch the bulk caret's own glyph");
    }
    console.log("HEADER_TEXT_CLICK_SECTION_ONLY_OK true");

    // ---- #419: entry bodies render through the shared renderMdBody() —
    // the same one client-side markdown renderer used by the changelog
    // (note windows already get markdown server-side via render_body() in
    // neural-view.py, see the #419 dev commit message / report for why that
    // path isn't duplicated here) -- lists, bold, inline code must render
    // as real markup, not escaped plain text. ----
    {
        const mdEntry = {scope: "", desc: "markdown body test", hash: "abc1234",
            body: ["- item one", "- item two", "", "**bold** and `code` and plain text."]};
        const mdHtml = changelogEntryHtml(mdEntry);
        if (!mdHtml.includes("<li>item one</li>") || !mdHtml.includes("<li>item two</li>")) throw new Error("markdown body must render a bullet list: " + mdHtml);
        if (!mdHtml.includes("<strong>bold</strong>")) throw new Error("markdown body must render **bold**: " + mdHtml);
        if (!mdHtml.includes("<code>code</code>")) throw new Error("markdown body must render `code`: " + mdHtml);
    }
    console.log("BODY_MARKDOWN_RENDERS_OK true");

    // ---- #419 XSS discipline: commit bodies are attacker-influenceable
    // (git log --format is attacker-influenceable if a commit message is
    // crafted) -- renderMdBody must escape-at-sink (escape BEFORE any
    // markdown transform), so no raw tag ever reaches the DOM. ----
    {
        const evilEntry = {scope: "", desc: "injection test", hash: "abc1234",
            body: ["<img src=x onerror=alert(1)>"]};
        const evilHtml = changelogEntryHtml(evilEntry);
        if (evilHtml.includes("<img")) throw new Error("commit body markdown renderer must escape raw markup, not pass it through: " + evilHtml);
        if (!evilHtml.includes("&lt;img")) throw new Error("commit body markdown renderer must render the escaped form of injected markup: " + evilHtml);
    }
    console.log("BODY_MARKDOWN_ESCAPES_INJECTION_OK true");

    // ---- #419 review round 1: code spans must be inert to emphasis --
    // this repo's own commit bodies constantly carry snake_case
    // identifiers and glob patterns inside backticks (port_zombie,
    // section-*.sh); if emphasis substitution runs before code-span
    // extraction, the underscores/asterisks INSIDE the backticks get
    // eaten as em/strong markers instead of staying literal code text. ----
    {
        const snakeEntry = {scope: "", desc: "snake case in code span", hash: "abc1234",
            body: ["see `snake_case_inside_backticks` for details."]};
        const snakeHtml = changelogEntryHtml(snakeEntry);
        if (!snakeHtml.includes("<code>snake_case_inside_backticks</code>")) throw new Error("underscores inside a code span must not be read as _em_ markers: " + snakeHtml);
        if (snakeHtml.includes("<em>")) throw new Error("a code span containing underscores must never produce <em>: " + snakeHtml);

        const globEntry = {scope: "", desc: "glob star in code span", hash: "abc1234",
            body: ["matches `glob*star*inside` files."]};
        const globHtml = changelogEntryHtml(globEntry);
        if (!globHtml.includes("<code>glob*star*inside</code>")) throw new Error("asterisks inside a code span must not be read as *em* markers: " + globHtml);
        if (globHtml.includes("<em>")) throw new Error("a code span containing asterisks must never produce <em>: " + globHtml);
    }
    console.log("CODE_SPAN_INERT_TO_EMPHASIS_OK true");

    // ---- #419: one renderer, no divergent duplicate -- exactly one
    // renderMdBody() definition in the template, and changelogEntryHtml
    // is wired to call it (not a second parallel implementation). ----
    {
        const defCount = (html.match(/function renderMdBody\(/g) || []).length;
        if (defCount !== 1) throw new Error("expected exactly one renderMdBody() definition in the template, found " + defCount);
        const cehSrc = extract("changelogEntryHtml");
        if (!/renderMdBody\(/.test(cehSrc)) throw new Error("changelogEntryHtml must call the shared renderMdBody() function, not its own inline transform");
    }
    console.log("ONE_RENDERER_PINNED_OK true");

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
    check "render (#411): the bulk caret is its own element (cl-version-caret/data-cl-caret) separate from the header text's data-cl-section, and starts state-aware (▸, since entry bodies always start collapsed)" "CARET_RENDER_SEPARATE_STATE_AWARE_OK true" "$cl_tmpl_out"
    check "render (#429): exactly ONE caret glyph per version row -- no leftover .cl-disclosure inside cl-version-head beside the live cl-version-caret, header text still carries data-cl-section" "ONE_CARET_PER_VERSION_ROW_OK true" "$cl_tmpl_out"
    check "#411: caret click on a collapsed version opens the section AND expands every entry body, flipping the caret to the collapse glyph" "CARET_COLLAPSED_SECTION_EXPANDS_ALL_OK true" "$cl_tmpl_out"
    check "#411: caret click when every entry is already expanded collapses them all without touching the section's own open state" "CARET_ALL_EXPANDED_COLLAPSES_ALL_OK true" "$cl_tmpl_out"
    check "#411: caret click on a mixed state (some entries open, some not) expands the rest -- expand wins" "CARET_MIXED_STATE_EXPAND_WINS_OK true" "$cl_tmpl_out"
    check "#411: header TEXT click still only toggles the section -- it never touches entry-body state or the bulk caret's glyph" "HEADER_TEXT_CLICK_SECTION_ONLY_OK true" "$cl_tmpl_out"
    check "#419: entry bodies render through the shared renderMdBody() -- bullet list, **bold**, and \`inline code\` all become real markup" "BODY_MARKDOWN_RENDERS_OK true" "$cl_tmpl_out"
    check "#419: commit body markdown renderer escapes-at-sink -- <img onerror=...> in a commit body renders escaped, never as raw markup" "BODY_MARKDOWN_ESCAPES_INJECTION_OK true" "$cl_tmpl_out"
    check "#419 review round 1: code spans are inert to emphasis -- underscores/asterisks inside \`backticks\` (snake_case identifiers, glob*star*patterns) never get read as em/strong markers" "CODE_SPAN_INERT_TO_EMPHASIS_OK true" "$cl_tmpl_out"
    check "#419: exactly one renderMdBody() definition in the template, and changelogEntryHtml calls it (one renderer, no divergent duplicate)" "ONE_RENDERER_PINNED_OK true" "$cl_tmpl_out"
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
check "CHIP_VER_FALLBACK carries the chip-changelog clickable marker class (chipHtml's optional 3rd segment element) -- #441: built from NV_PLUGIN_VERSION, the server-injected real plugin version, not a client-side fallback number" 'const CHIP_VER_FALLBACK = [`v${NV_PLUGIN_VERSION}`,' "$(cat "$NVHTML_CL")"
check "CHIP_VER_FALLBACK's chip-changelog class is present" '"chip-changelog"];' "$(cat "$NVHTML_CL")"
# #441 review round 3: this pin used to target the async-probe CHIP_VER
# reassignment (now gone -- see the check_absent below); the same tooltip
# text lives on in CHIP_VER_FALLBACK itself, since the chip's version
# segment is correct (and carries this tooltip) from first paint now,
# never just after an async swap.
check "the version tooltip names semver.sh as the bump mechanism (matches what the changelog overlay documents)" 'bumped by semver.sh at every merge' "$(cat "$NVHTML_CL")"
check "CHIP_VER starts on the (already-correct, server-injected) fallback -- #441: no longer just a deterministic pre-probe placeholder, since NV_PLUGIN_VERSION is the real value from first paint" 'let CHIP_VER = CHIP_VER_FALLBACK;' "$(cat "$NVHTML_CL")"
check "CHIP_BRANCH is assigned with the chip-changelog clickable marker class" 'CHIP_BRANCH = [base.branch, "git branch the serving repo is on (read at server boot probe) — click to view the changelog", "chip-changelog"];' "$(cat "$NVHTML_CL")"
check "status chip click delegation opens/closes the changelog overlay via .chip-changelog" 'ev.target.closest(".chip-changelog")' "$(cat "$NVHTML_CL")"
check "changelog overlay reuses the note-window chrome family via the compound selector .note-window.changelog-window (same specificity-tie defense as .note-window.ast-inspector-window)" ".note-window.changelog-window{width:min(480px,92vw);max-height:80vh}" "$(cat "$NVHTML_CL")"
check "chipHtml() accepts an optional 3rd element (extra CSS class) per segment" 'map(([text, title, cls]) =>' "$(cat "$NVHTML_CL")"

echo "-- template: #441 -- the async /version probe no longer reassigns CHIP_VER from a plugin field (NV_PLUGIN_VERSION is already the real plugin version from first paint, server-injected -- nothing left for the probe to swap in); it still fills in CHIP_BRANCH, and the repaint guard is narrowed to branch-only --"
# shellcheck disable=SC2016  # single-quoted on purpose -- pinning literal
# template-literal ${...} source text, not a shell expansion.
check_absent "the /version probe no longer reassigns CHIP_VER from base.plugin -- that swap is gone" 'CHIP_VER = [`v${base.plugin}`' "$(cat "$NVHTML_CL")"
check_absent "the old plugin-version tooltip naming NV_VERSION as the template build is gone (NV_VERSION itself no longer exists)" 'this tab'"'"'s template build is' "$(cat "$NVHTML_CL")"
check "the /version repaint guard is narrowed to base.branch alone -- #441: the plugin-only repaint case is gone along with the CHIP_VER reassignment it used to guard" 'if(statusEl && !webglOK && base && base.branch){' "$(cat "$NVHTML_CL")"

echo "-- template (#411): version-row bulk caret is its own element/class, decoupled from the header text's section-only toggle, pinned in source --"
# shellcheck disable=SC2016  # single-quoted on purpose -- pinning the literal
# template source text (including its own template-literal ${...}), not a
# shell expansion.
check "the bulk caret is a dedicated element (cl-version-caret) carrying its own data-cl-caret bulk-toggle marker" 'class="cl-version-caret" data-cl-caret="${secId}"' "$(cat "$NVHTML_CL")"
# shellcheck disable=SC2016  # single-quoted on purpose -- same as above.
check "the header TEXT keeps data-cl-section (section-only toggle) on its own separate element (cl-version-text), not shared with the caret" 'class="cl-version-text" data-cl-section="${secId}"' "$(cat "$NVHTML_CL")"
check "the delegated click handler checks the bulk caret (data-cl-caret) before the section text (data-cl-section), since the caret sits inside the same header and must not fall through" 'const caretEl = ev.target.closest("[data-cl-caret]");' "$(cat "$NVHTML_CL")"
check "the caret bulk-toggle CSS gives it its own cursor/hover affordance, separate from the header text" '.cl-version-caret:hover{color:var(--cyan)}' "$(cat "$NVHTML_CL")"

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
