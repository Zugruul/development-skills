#!/usr/bin/env bash
# section-neural-view-render-body.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== neural-view render_body (GFM pipe tables + italic) =="
NVRB_OUT="$(python3 - "$PLUGIN/scripts/neural-view.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("neural_view", sys.argv[1])
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)
body = """# Character Groups

| Name | Epithets |
| --- | --- |
| Raven | Aesir of *Chaos* |
| Odin | **All-Father** |

Some **bold** and _italic_ text.
"""
print(nv.render_body(body))
PY
)"
check "heading still renders as <h3>" "<h3>Character Groups</h3>" "$NVRB_OUT"
check "table renders a <table> element" "<table>" "$NVRB_OUT"
check "table header row renders <thead>" "<thead>" "$NVRB_OUT"
check "table body rows render <tbody>" "<tbody>" "$NVRB_OUT"
check "table header cells render <th>Name</th>" "<th>Name</th>" "$NVRB_OUT"
check "table data cells render <td>Raven</td>" "<td>Raven</td>" "$NVRB_OUT"
check "italic inside a table cell still renders (inline() runs on cell text)" "<em>Chaos</em>" "$NVRB_OUT"
check "bold inside a table cell still renders" "<strong>All-Father</strong>" "$NVRB_OUT"
check "bold in a paragraph still renders" "<strong>bold</strong>" "$NVRB_OUT"
check "underscore italic renders <em>italic</em>" "<em>italic</em>" "$NVRB_OUT"
check_absent "no literal pipe characters leak into the output" "|" "$NVRB_OUT"
check_absent "no literal hash characters leak into the output" "#" "$NVRB_OUT"

echo "== neural-view render_body (note media: images, links, code-span protection #289) =="
NVRB_MEDIA_OUT="$(python3 - "$PLUGIN/scripts/neural-view.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("neural_view", sys.argv[1])
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)
body = """Embed ![duck](assets/duck.png) and [trailer](assets/demo.mp4) and
[site](https://example.com/x) here.

Syntax examples stay literal: `![alt](path)` and `[label](file.mp4)` and `[[wl]]`.
"""
print(nv.render_body(body))
PY
)"
check "![img](path) renders an img.nm with data-src" '<img class="nm" data-src="assets/duck.png" alt="duck">' "$NVRB_MEDIA_OUT"
check "[link](relative) renders a file link (a.fl)" '<a class="fl" data-href="assets/demo.mp4">trailer</a>' "$NVRB_MEDIA_OUT"
check "[link](https) renders an external link with noopener" '<a class="ext" href="https://example.com/x" target="_blank" rel="noopener">site</a>' "$NVRB_MEDIA_OUT"
check "image markdown inside backticks stays literal code" '<code>![alt](path)</code>' "$NVRB_MEDIA_OUT"
check "link markdown inside backticks stays literal code" '<code>[label](file.mp4)</code>' "$NVRB_MEDIA_OUT"
check "wikilink inside backticks stays literal code" '<code>[[wl]]</code>' "$NVRB_MEDIA_OUT"
check_absent "no live file link leaks from the code-span examples" 'data-href="file.mp4"' "$NVRB_MEDIA_OUT"

echo "== neural-view render_body (note media: audio links #430) =="
NVRB_AUDIO_OUT="$(python3 - "$PLUGIN/scripts/neural-view.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("neural_view", sys.argv[1])
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)
body = "Listen: [narration](assets/demo-audio.wav) here.\n"
print(nv.render_body(body))
PY
)"
check "[label](path.wav) renders a file link (a.fl) -- client resolves it to an <audio> block" '<a class="fl" data-href="assets/demo-audio.wav">narration</a>' "$NVRB_AUDIO_OUT"

echo "== neural-view render_body (fenced mermaid blocks #430) =="
NVRB_MMD_OUT="$(python3 - "$PLUGIN/scripts/neural-view.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("neural_view", sys.argv[1])
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)
body = """Before text.

\x60\x60\x60mermaid
graph TD
  A --> B

  B --> C
\x60\x60\x60

After text.
"""
print(nv.render_body(body))
PY
)"
check "fenced mermaid block renders an .nmmd container" '<div class="nmmd" data-mmd="graph TD' "$NVRB_MMD_OUT"
check "mermaid block's blank line inside the fence does NOT fracture it into two blocks" $'A --&gt; B\n\n  B --&gt; C' "$NVRB_MMD_OUT"
check "surrounding prose still renders around the mermaid block" "<p>Before text.</p>" "$NVRB_MMD_OUT"
check "surrounding prose still renders around the mermaid block (after)" "<p>After text.</p>" "$NVRB_MMD_OUT"
check "mermaid source is duplicated into a hidden text-mode <pre><code> fallback" '<pre class="nmmd-src" hidden><code>graph TD' "$NVRB_MMD_OUT"

echo "== neural-view render_body (mermaid XSS escaping #430) =="
NVRB_MMDXSS_OUT="$(python3 - "$PLUGIN/scripts/neural-view.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("neural_view", sys.argv[1])
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)
body = """\x60\x60\x60mermaid
graph TD
  A["<img src=x onerror=alert(1)>"] --> B
\x60\x60\x60
"""
print(nv.render_body(body))
PY
)"
check_absent "mermaid source with an embedded HTML tag never reaches the page unescaped" "<img src=x onerror=alert(1)>" "$NVRB_MMDXSS_OUT"
check "the same source is present, HTML-escaped" "&lt;img src=x onerror=alert(1)&gt;" "$NVRB_MMDXSS_OUT"

echo "== neural-view Handler._send (BrokenPipeError silence #379) =="
NVSEND_OUT="$(python3 - "$PLUGIN/scripts/neural-view.py" <<'PY' 2>&1
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("neural_view", sys.argv[1])
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)

class BrokenWfile:
    def write(self, data):
        raise BrokenPipeError(32, "Broken pipe")

stub = types.SimpleNamespace(
    wfile=BrokenWfile(),
    send_response=lambda *a, **k: None,
    send_header=lambda *a, **k: None,
    end_headers=lambda: None,
)
try:
    nv.Handler._send(stub, 200, {"ok": True})
    print("NO_EXCEPTION_RAISED")
except Exception as e:
    print("EXCEPTION_RAISED: " + repr(e))
PY
)"
check "no exception propagates for BrokenPipeError" "NO_EXCEPTION_RAISED" "$NVSEND_OUT"
check_absent "no traceback text leaks to output" "Traceback" "$NVSEND_OUT"

echo "== neural-view Handler._send (ConnectionResetError silence #379) =="
NVSEND_OUT2="$(python3 - "$PLUGIN/scripts/neural-view.py" <<'PY' 2>&1
import importlib.util, sys, types
spec = importlib.util.spec_from_file_location("neural_view", sys.argv[1])
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)

class ResetWfile:
    def write(self, data):
        raise ConnectionResetError(54, "Connection reset by peer")

stub = types.SimpleNamespace(
    wfile=ResetWfile(),
    send_response=lambda *a, **k: None,
    send_header=lambda *a, **k: None,
    end_headers=lambda: None,
)
try:
    nv.Handler._send(stub, 200, "plain text", "text/plain")
    print("NO_EXCEPTION_RAISED")
except Exception as e:
    print("EXCEPTION_RAISED: " + repr(e))
PY
)"
check "no exception propagates for ConnectionResetError" "NO_EXCEPTION_RAISED" "$NVSEND_OUT2"
check_absent "no traceback text leaks to output (reset)" "Traceback" "$NVSEND_OUT2"

echo "== neural-view render_index (#441): server-side plugin-version injection, kills the status-chip flash =="
# render_index() is TEMPLATE's bytes with NV_PLUGIN_PLACEHOLDER -- the
# QUOTED placeholder token `"__NV_PLUGIN_VERSION__"`, matching the exact
# shape it sits in inside a JS string literal (const v = "...";) --
# substituted for json.dumps() of plugin_version() (or of "dev" if that's
# None). The fix for the chip briefly showing a stale template-baked
# version before the async /version probe swapped in the real one. Unit-
# tested against a tiny fixture template (never the real ~9000-line one)
# with TEMPLATE and plugin_version monkeypatched, same "import as a
# module, stub the boundary" style section-neural-view-rescan.sh/section-
# assistant-terminal.sh use.
NVRI_OUT="$(python3 - "$PLUGIN/scripts/neural-view.py" <<'PY'
import importlib.util, sys, tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("neural_view", sys.argv[1])
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)

fixture_dir = Path(tempfile.mkdtemp())
fixture = fixture_dir / "fixture.html"
# two occurrences -- the real template currently has exactly one, but this
# fixture deliberately uses two so the assertions below catch a regression
# to a naive first-match-only replace() if this file, or a future template
# edit that reintroduces a second occurrence, ever needs it: a placeholder
# used more than once must never leave one occurrence stale.
fixture.write_text('const a = "__NV_PLUGIN_VERSION__";\nconst b = "__NV_PLUGIN_VERSION__";\n')
nv.TEMPLATE = fixture

# case 1: plugin_version() resolves normally -- lands in BOTH occurrences
nv.plugin_version = lambda: "0.45.0"
html1 = nv.render_index().decode()
print("REAL_VERSION_SUBSTITUTED", html1.count('"0.45.0"') == 2)
print("PLACEHOLDER_GONE", "__NV_PLUGIN_VERSION__" not in html1)

# case 2: plugin_version() is None (plugin.json missing/unparseable) -- the
# placeholder degrades to "dev" server-side, not left raw for the client
nv.plugin_version = lambda: None
html2 = nv.render_index().decode()
print("NONE_DEGRADES_TO_DEV", html2.count('"dev"') == 2)
print("PLACEHOLDER_GONE_ON_NONE", "__NV_PLUGIN_VERSION__" not in html2)

# case 3 (#441 review round 2, MAJOR): a MALICIOUS plugin.json version --
# plugin.json is repo-controlled content, not trusted input -- must land
# on the served page ONLY as an inert, properly-escaped JS string, never
# as executable code. This is the exact injection class the #410 chipHtml
# review already fixed on the escaping path; substituting plugin_version()
# RAW here (rather than through json.dumps()) would have reopened it.
evil = '1.0" ; alert(1) ; "'
nv.plugin_version = lambda: evil
html3 = nv.render_index().decode()
print("RAW_EVIL_STRING_NEVER_APPEARS_UNESCAPED", evil not in html3)
print("EVIL_STRING_LANDS_PROPERLY_ESCAPED", html3.count('"1.0\\" ; alert(1) ; \\""') == 2)

# case 3b (#441 review round 3, MAJOR still half-open): json.dumps() alone
# defeats a JS-STRING-context breakout, but NOT an HTML-PARSER breakout --
# the HTML parser closes an inline <script> element the moment it sees the
# literal byte sequence "</script" ANYWHERE inside it, string literal or
# not, because it tokenizes the raw text of that script element before the
# JS parser ever runs. A version of `</script><script>...` therefore still
# executes even through json.dumps() alone (confirmed against a real
# served page in Chrome by the reviewer: a second <script> element
# appeared and ran). This is a SERVED-BYTES assertion, not a JS-eval one
# on purpose -- the new Function()-based harnesses (like case 3, below)
# never run an HTML parser, so they structurally cannot catch element-
# splitting.
script_evil = "</script><script>window.__PWNED=1;</script>"
nv.plugin_version = lambda: script_evil
html3b = nv.render_index().decode()
print("RAW_SCRIPT_CLOSE_NEVER_APPEARS", "</script>" not in html3b)
# 2 raw "</script>" in script_evil x 2 placeholder occurrences in the
# fixture (const a AND const b) = 4 escaped "<\/script>" total
print("ESCAPED_SCRIPT_CLOSE_SURVIVES", html3b.count("<\\/script>") == 4)

# case 4: TEMPLATE itself is missing -- render_index() returns None, same as
# the pre-#441 "template missing" placeholder-page fallback in do_GET
nv.TEMPLATE = fixture_dir / "does-not-exist.html"
print("MISSING_TEMPLATE_RETURNS_NONE", nv.render_index() is None)
PY
)"
check "a real plugin_version() substitutes into EVERY placeholder occurrence" "REAL_VERSION_SUBSTITUTED True" "$NVRI_OUT"
check "no raw placeholder survives a normal substitution" "PLACEHOLDER_GONE True" "$NVRI_OUT"
check "plugin_version() returning None (plugin.json missing/unparseable) degrades to \"dev\" server-side" "NONE_DEGRADES_TO_DEV True" "$NVRI_OUT"
check "no raw placeholder survives the None-degrades-to-dev path either" "PLACEHOLDER_GONE_ON_NONE True" "$NVRI_OUT"
check "a plugin.json version string containing a quote never appears on the page as raw, unescaped text (the injection break-out attempt fails)" "RAW_EVIL_STRING_NEVER_APPEARS_UNESCAPED True" "$NVRI_OUT"
check "the malicious version lands as a properly json.dumps()-escaped JS string literal instead" "EVIL_STRING_LANDS_PROPERLY_ESCAPED True" "$NVRI_OUT"
check "a plugin.json version containing \"</script>\" never appears on the served page as the raw, HTML-parser-breaking byte sequence (#441 review round 3: json.dumps() alone doesn't defend against this -- the HTML parser tokenizes on it regardless of JS string context)" "RAW_SCRIPT_CLOSE_NEVER_APPEARS True" "$NVRI_OUT"
check "the \"</script>\" sequence survives instead as the escaped, HTML-parser-inert \"<\\/script>\" form" "ESCAPED_SCRIPT_CLOSE_SURVIVES True" "$NVRI_OUT"
check "a missing TEMPLATE file makes render_index() return None, same fallback contract as before #441" "MISSING_TEMPLATE_RETURNS_NONE True" "$NVRI_OUT"

echo "-- neural-view render_index (#441 review round 2): the escaped substitution is genuinely inert when actually parsed as JS, not just string-matched --"
# Belt-and-suspenders on the injection fix above: actually PARSE the
# substituted line as JS (extract() + eval(), this file's own harness style
# further down) with a stub alert() that flips a flag if ever called, and
# assert (a) alert is never invoked and (b) the resulting string value
# equals the original malicious version verbatim (the escaping round-trips
# losslessly -- it doesn't just happen to avoid a literal quote-break).
NVRIX_OUT="$(python3 - "$PLUGIN/scripts/neural-view.py" <<'PY'
import importlib.util, sys, tempfile, json
from pathlib import Path

spec = importlib.util.spec_from_file_location("neural_view", sys.argv[1])
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)

fixture_dir = Path(tempfile.mkdtemp())
fixture = fixture_dir / "fixture.html"
fixture.write_text('const a = "__NV_PLUGIN_VERSION__";\n')
nv.TEMPLATE = fixture

evil = '1.0" ; alert(1) ; "'
nv.plugin_version = lambda: evil
html = nv.render_index().decode()
print(json.dumps(html))
PY
)"
_nvpv_esc_node="$(mktemp).cjs"
cat >"$_nvpv_esc_node" <<'NODEJS'
const html = JSON.parse(process.argv[2]);
const m = html.match(/^const a = (.*);$/m);
if (!m) throw new Error("could not find the substituted const line");
let alerted = false;
function alert(){ alerted = true; }
const value = eval(m[1]);   // parse the substituted RHS as a real JS expression
console.log("ALERT_NEVER_CALLED " + (alerted === false));
console.log("VALUE_ROUNDTRIPS_EXACTLY " + (value === "1.0\" ; alert(1) ; \""));
NODEJS
nvpv_esc_out="$(node "$_nvpv_esc_node" "$NVRIX_OUT" 2>&1)"
nvpv_esc_rc=$?
rm -f "$_nvpv_esc_node"
check_rc "the JS-parse harness for the escaped substitution exits 0" 0 "$nvpv_esc_rc"
check "actually parsing the substituted line as JS never invokes the injected alert()" "ALERT_NEVER_CALLED true" "$nvpv_esc_out"
check "the parsed string value equals the original malicious version byte-for-byte -- the escaping round-trips losslessly" "VALUE_ROUNDTRIPS_EXACTLY true" "$nvpv_esc_out"
if [[ "$nvpv_esc_rc" -ne 0 ]]; then echo "$nvpv_esc_out" >&2; fi

echo "-- neural-view plugin_version() reads the REAL plugin.json shape (a temp fixture repo, not the actual repo's plugin.json) --"
NVPV_OUT="$(python3 - "$PLUGIN/scripts/neural-view.py" <<'PY'
import importlib.util, sys, tempfile, json
from pathlib import Path

spec = importlib.util.spec_from_file_location("neural_view", sys.argv[1])
nv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nv)

root = Path(tempfile.mkdtemp())
plugin_dir = root / "plugins" / "spec-workflow" / ".claude-plugin"
plugin_dir.mkdir(parents=True)
(plugin_dir / "plugin.json").write_text(json.dumps({"version": "9.9.9"}))
nv.git_root = lambda: str(root)
print("REAL_VERSION_READ", nv.plugin_version() == "9.9.9")

# missing plugin.json -> None, never an exception
(plugin_dir / "plugin.json").unlink()
print("MISSING_FILE_RETURNS_NONE", nv.plugin_version() is None)

# unparseable JSON -> None, never an exception
(plugin_dir / "plugin.json").write_text("{not valid json")
print("UNPARSEABLE_RETURNS_NONE", nv.plugin_version() is None)

# non-string version field -> None, never a crash surfacing a number/list as a version string
(plugin_dir / "plugin.json").write_text(json.dumps({"version": 123}))
print("NON_STRING_VERSION_RETURNS_NONE", nv.plugin_version() is None)
PY
)"
check "plugin_version() reads the real semver out of plugin.json" "REAL_VERSION_READ True" "$NVPV_OUT"
check "a missing plugin.json returns None, never an exception" "MISSING_FILE_RETURNS_NONE True" "$NVPV_OUT"
check "unparseable JSON returns None, never an exception" "UNPARSEABLE_RETURNS_NONE True" "$NVPV_OUT"
check "a non-string version field returns None rather than surfacing the wrong-typed value" "NON_STRING_VERSION_RETURNS_NONE True" "$NVPV_OUT"
