---
tags: [testing, e2e, integration]
paths: ["plugins/spec-workflow/tests/e2e-*.sh"]
strength: 1
source: "loop-feedback 2026-07-29"
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

Keep a class of self-skipping NON-hermetic e2e scripts (real browser, real sidecar processes, fake OS-level inputs like Chrome's fake-mic WAV) alongside but outside the hermetic suite registration. They catch integration contract breaks — wrong endpoint path, wrong media container, CORS — that per-function DOM-stub harnesses structurally cannot see; the hermetic suite stayed green for months while the voice pipeline could not transcribe at all.
