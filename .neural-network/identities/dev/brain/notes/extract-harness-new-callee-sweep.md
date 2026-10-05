---
tags: [tdd, tests, template, harness]
paths: ["plugins/spec-workflow/tests/** plugins/spec-workflow/templates/**"]
strength: 1
source: ""
confidence: direct
learned-from: 481
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

Trigger: a template function reached via a test file's extract()+eval() harness gains a new callee (helper function, top-level const) or a new parameter. Action: before considering the change done, `grep -rln 'extract("<fnname>")' plugins/spec-workflow/tests/*.sh` for EVERY function you touched — not just the file you're editing. Each match is an INDEPENDENT eval'd copy that needs the same new dependency extracted into it, or it ReferenceErrors only when that OTHER file's suite runs — invisible from a single-file test run, only surfacing at full-gate time. Proven twice in consecutive tasks: the focus()/activeElement extension and the scrollChatLogToBottom/isChatLogAtBottom helpers each broke the sibling voice-turn harness the same way.

Related: [[anonymous-listener-slice-eval]]
