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
