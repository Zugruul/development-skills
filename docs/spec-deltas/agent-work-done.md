---
task: 'agent-work-done'
spec: sw
sections: ["§work"]
---

## §work — Definition of AGENT work done (`work.done`)

New config: `work.done: {phase, instructions}` — at which delivery phase the agent considers ITS OWN work finished. Distinct from the task-level definition of done (what the TASK requires — acceptance criteria on the board item; the agent works toward that): `work.done` is the agent's true stop-gate for "my work is done".

`phase` (required when `work.done` is present) is a union: `code` | `pr-open` | `pr-review-requested` | `pr-validated` | `deployed-staging` | `deployed-production` | `custom`. `instructions` is free text — extra guidance on any preset phase (WHICH channel gets the review request, WHICH environment validates), and under `phase: custom` it IS the definition (required there, non-empty). The `pr-*` phases are config-invalid under `work.type: local` (local delivery never opens a PR). `deployed-*` means the deployment is VERIFIED, not just merged.

Absent == legacy behavior: the `work.type` + `methodology.autoMerge` flow decides where work stops (no semantic change for existing configs).

Surfaces: `validate-config.py` (shape, union, cross-checks, `work done: phase=…` summary line), `work-mode.sh done-phase` (prints the phase or `default`) / `done-instructions`, `schemas/project-config.schema.json` (hover-complete enum), skill wiring in implement-task §3 (the per-phase stop-gate protocol + §5's report line), build-next §Delivery mode, setup-project's setup ask, and `templates/project.example.yaml`. Tests: `tests/section-work-mode.sh` §work.done.
