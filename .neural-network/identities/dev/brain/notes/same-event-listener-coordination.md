---
tags: [javascript, events, races]
paths: ["plugins/spec-workflow/templates/neural-view.html"]
strength: 1
source: "#318 retro"
graduated: false
created: 2026-07-25
---

When two independent listeners on the same event type must coordinate "who owns this event", never have one infer the other's outcome by re-reading DOM/app state the other may already have mutated — that's a hidden race tied to registration order that passes in whichever order you happened to test. Use the event object itself as the coordination channel (defaultPrevented or a custom flag on the event): it survives dispatch regardless of listener order. Before writing ANY coordination fix between handlers, grep every addEventListener of that event type and sequence their registration/execution order. And when handed a prescribed fix: implement it as given, RUN it against the finding's own test, and diagnose the failure — verify the mechanism by execution, not by reading.
