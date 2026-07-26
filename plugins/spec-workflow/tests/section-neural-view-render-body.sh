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
