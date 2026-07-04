# Spec-writing guide — structure, interview bank, review checklist

## 1. Document structure

Number every section (`§1`, `§2.3`, …) — tasks and agent briefs cite them. Recommended skeleton (drop/merge sections that don't apply; keep the order):

```
§1  Overview            — 1 paragraph: what, for whom, why now
§2  Goals               — bulleted, each measurable or demonstrable
§3  Non-goals           — explicit exclusions; what a future reader must NOT build
§4  Glossary / domain   — terms, entities, and their relationships; one meaning each
§5  Architecture        — components, data flow, key technology choices + WHY each
§6+ Functional areas    — one § per area. Write each requirement in EARS notation so it
                          translates mechanically into a failing test:
                            ubiquitous:  THE SYSTEM SHALL <behavior>
                            event:       WHEN <trigger> THE SYSTEM SHALL <behavior>
                            state:       WHILE <state> THE SYSTEM SHALL <behavior>
                            unwanted:    IF <condition> THEN THE SYSTEM SHALL <behavior>
                            optional:    WHERE <feature enabled> THE SYSTEM SHALL <behavior>
                          ("WHEN a second claim for the same number arrives THE SYSTEM
                          SHALL reject it with 409", not "handles conflicts gracefully")
§N-3 Invariants         — the hard, never-violate rules (security, isolation, money,
                          data loss). Imperative and self-contained: these are copied
                          verbatim into specs[].invariants and every implementation brief
§N-2 Non-functional     — performance targets (numbers), scale, availability,
                          compliance/privacy, observability
§N-1 Testing strategy   — test pyramid for THIS project; what is merge-gating
§N   Open questions     — each with an owner and a default-if-unanswered
```

Practices: state decisions, not discussions (record the chosen option + one-line why); prefer tables/enums over prose for surfaces (endpoints, events, states); every FSM gets its states + transitions enumerated; anything "compatible with X" needs the exact compatible subset listed.

## 2. Interview question bank

Pick per round (≤4 via AskUserQuestion), skip what the brief already answers. Always offer 2–4 concrete options; put your recommended default first.

- **Problem/users:** Who uses this and what do they do today instead? What single outcome makes v1 a success?
- **Goals/non-goals:** Which of these plausible features are OUT of scope for v1? (list them) — non-goals are the highest-value answers you can get.
- **Domain:** What are the core entities? Which relationships are 1:1 vs 1:N? What must never happen (→ invariants)?
- **Constraints:** Stack fixed or open? Deploy target (self-host / cloud / both)? Compliance regimes (LGPD/GDPR/PCI)? Hard performance numbers?
- **Compatibility/integrations:** Must this match an existing API surface? Which exact subset? What external systems does it call / get called by?
- **Quality/testing:** What is merge-gating vs advisory? Coverage expectations for critical paths? Determinism requirements?
- **Delivery:** What must ship first to be useful? Any hard external deadlines/dependencies (credentials, hardware, approvals)?

## 3. Review checklist (Phase 4 gate)

All must pass before presenting to the user:

1. Every functional requirement is in EARS form and testable as written (an engineer could write the failing test from the sentence alone; the WHEN/IF clause is the test setup, the SHALL clause the assertion).
2. Every requirement maps to ≥1 backlog task, and every task cites its spec §s.
3. Non-goals section exists and is non-empty.
4. Invariants are imperative, self-contained, and independent of this document's context.
5. Epic order is buildable: no task depends on output of a later epic; guards (`blockedBy`) added where order is mandatory, not just preferred.
6. Task numbering leaves headroom in each epic's range for discovered work.
7. Every open question has an owner and a default; none are silently resolved.
8. No orphan sections: nothing specified that no epic will ever build (either add a task or move to non-goals).
9. Complexity: every task scored 1–10 (rubric in the seed-board skill); no task ≥8 survives unsplit, none > 13 points; estimates reflect testing effort, not just code.
10. A newcomer reading only this spec + backlog could start task 1 without asking anything.
