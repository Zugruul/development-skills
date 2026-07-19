---
tags: [testing, tooling]
paths: ["plugins/spec-workflow/tests/*.sh"]
strength: 1
source: "PR#227 (CDX-014, #184) verification -- --section neural-view-sessions,capability-language produced a spurious unbound-variable failure; --section neural-view (broader substring) ran clean"
graduated: false
created: 2026-07-19
---

run-tests.sh's --section filter skips earlier section files that set up shared state a later section depends on (e.g. a shared $NV variable one neural-view section sets and a later neural-view section reads). A narrow --section filter (e.g. --section neural-view-sessions alone) can produce a spurious "unbound variable" failure that looks like a real regression but is purely a filter-ordering artifact. Either run the full unfiltered gate, or widen the filter to a substring that catches the dependency-setting sections too (e.g. --section neural-view, which matches every neural-view-* section by substring).

Related: [[trust-completion-signal-not-early-log-read]]
