# Design docs & spec deltas — formats

Contents: §1 per-epic design doc · §2 spec-delta files · §3 folding deltas into the spec.

## §1 Per-epic design doc — `<paths.designDir>/<spec-id>-<epic-id>.md` (default `docs/design/`)

Written by the ORCHESTRATOR before the first task of an epic starts (≤2 pages; ground every claim in spec §s). All dev-agent briefs for the epic cite it — it is what keeps independently delegated tasks architecturally coherent.

```markdown
# Design — <spec-id>/<epic-id>: <epic title>
Grounded in: SPEC §<a>, §<b>, …

## Components
<component> — <responsibility, owner package/module>          (one line each)

## Data models
<entity>: <fields + types + invariants>                        (tables/enums preferred)

## Interfaces / contracts
<API/event/function surface this epic exposes or consumes — exact names & shapes>

## Key sequences
<the 1–3 flows that cross components; numbered steps, note atomicity/idempotency points>

## Decisions
<decision> — <chosen option + one-line WHY>                    (record choices, not debates)

## Out of scope for this epic
<what later epics own — prevents drift>
```

Rule: if implementing a task would contradict the design doc, STOP — update the design doc first (and a spec delta if the contract changes), then continue. Never silently diverge.

## §2 Spec delta — `<paths.specDeltaDir>/<task-id>.md` (default `docs/spec-deltas/`)

Written by the DEV AGENT (instructed via the brief) whenever a task changes, extends, or corrects any contract in the spec — new endpoints/events, changed behavior, renamed fields, new invariants. No contract change → no delta file.

```markdown
---
task: <task-id>          # e.g. CP-012
spec: <spec id>          # specs[].id
sections: ["§7.2", "§12"] # every § this delta touches (or "new §N")
---

## §7.2 <section title> — MODIFIED
WHEN <trigger> THE SYSTEM SHALL <new behavior>     <- full replacement text for the changed
                                                      requirement(s), EARS form, final wording

## §12.4 — ADDED
<complete new subsection text, ready to paste into the spec>
```

Rules: each block carries the FINAL text (paste-ready, not a diff description); one delta file per task, extended if the task evolves; commit it with the task's branch so review sees the contract change next to the code.

## §3 Folding deltas (the living spec)

When a task's PR MERGES (the *In review* → *QA* transition in `build-next`), the orchestrator:
1. Opens the delta file; applies each block to `specPath` at the named § (replace MODIFIED text, insert ADDED text, keep numbering consistent).
2. Moves the delta to `<paths.specDeltaDir>/applied/<task-id>.md` (history without clutter).
3. Commits both together: `docs(spec): fold <task-id> delta into SPEC (§7.2, §12.4)`.

The invariant this buys: **the canonical spec always describes shipped reality**; pending deltas are exactly the contract changes still in flight. Never edit the spec directly for in-flight work — always via a delta.
