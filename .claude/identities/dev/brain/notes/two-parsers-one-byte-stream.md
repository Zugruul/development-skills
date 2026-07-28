---
tags: [security, escaping, html, js]
paths: ["plugins/spec-workflow/scripts/neural-view.py", "plugins/spec-workflow/templates/**"]
strength: 1
source: "PR-close #441"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Escaping untrusted content for one output context is a half-open fix: HTML, JS, and any templating layer all read the same bytes, each with its own tokenizer. json.dumps closes a JS-string breakout, but the HTML parser tokenizes a literal closing-script sequence BEFORE the JS parser ever runs — needing its own escape (backslash the slash). When escaping, ask "what other parser sees these same bytes before mine does".
