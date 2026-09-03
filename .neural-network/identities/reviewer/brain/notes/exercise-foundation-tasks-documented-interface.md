---
tags: [review, shared-library, shell]
paths: []
strength: 1
source: "task #129 (MEM-010) review"
graduated: false
created: 2026-07-16
---

For a foundation task whose output (a shared library/manifest) will be sourced or built upon by not-yet-started follow-up tasks, don't stop at 'does this task's own acceptance pass' -- actually run the delivered helpers yourself and probe for a shell-hygiene issue (e.g. file-scope `set -uo pipefail` leaking into a sourcing caller's shell) that won't show up in this task's own tests but will bite the very next task that depends on it.

Why: reviewing #129 (MEM-010), running scripts/lib/local-state.sh's documented sourcing interface (`. lib/local-state.sh`) and checking shell-option state before/after revealed it flips nounset+pipefail on in the caller -- invisible to MEM-010's own tests (which only exercise the file directly), but exactly the kind of surprise MEM-011 (the first real sourcing caller) would hit later. Flagging it now, before MEM-011 starts, is strictly cheaper than debugging it after two more tasks depend on the same file.

How to apply: when reviewing a shared-library/foundation task, actually exercise the delivered interface the way its own docs say future callers will use it (source it, call it from another script, etc.), not just the way this task's own tests happen to invoke it -- foundation-task defects are cheapest to catch before anything is built on top.
