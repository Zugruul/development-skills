# Design - remote-compute role dispatch (#525)

Grounded in: issue #525 OWNER comments (2026-08-02, 2026-10-11),
`docs/design/remote-compute-plan.md`, and the current remote-compute user guide.
This supplements the historical plan's no-selection v1 scope. It does not
implement SPEC-ASSISTANT section 14 or change explicit-name dispatch policy.

## Components

- Controller CLI: parse opt-in role selection, validate candidates, explain skips.
- Project compute reader: read only compute availability, without requiring an
  installed spec-workflow Python module in the standalone installed CLI.
- Existing launcher: render declared jobs, reserve target capacity, stage inputs,
  launch once, and retain the existing recoverable job receipt.
- Existing target protocol: the sole authority for shared-account admission.

## Data models

No registry, project, receipt, or target protocol schema change is required.
Project resources remain an alias-keyed map of `enabled` booleans and `roles`
string lists. Registry jobs and named environments remain client-configured.
The reader uses `.neural-network/project.yaml` and its optional sibling
`project.local.yaml`: when present, the local `compute` key replaces the whole
base `compute` value, exactly as spec-workflow's shared loader does. Missing
compute means no candidates, never all registered machines. Invalid relevant
YAML shapes fail closed with an actionable usage error. No files are rewritten.

## Interfaces / contracts

```text
remote-compute run --role ROLE JOB [--root DIR] [existing run options]
remote-compute dispatch --role ROLE --workdir W --cmd C [--root DIR] [existing dispatch options]
```

- `--root` defaults to the working directory, as for enable/disable. Require its
  `.neural-network/project.yaml`. Role matching is exact and case-sensitive.
- These selector-first forms are additive. Existing `run NICK JOB` and
  `dispatch NICK ...` neither read project config nor require enablement.
  Reject mixed selectors, blank/missing role values, duplicate selector/root
  options, and unknown options. Do not reinterpret option-looking param values.
- Sort eligible aliases lexically, independent of YAML insertion order. Only
  entries explicitly `enabled: true`, containing ROLE, and present in the local
  registry may be considered. Informational hardware snapshots are not evidence
  of job or environment readiness and must not trigger hardware probing.
- For `run`, require that candidate's declared job, valid parameters, and any
  referenced environment with a nonempty activation command. A recorded failed
  environment verification excludes that candidate; absence of a verification
  stamp alone does not break legacy registries. For raw dispatch, apply the same
  environment rule to `--env`; do not invent or infer the user's command.
- Validate global syntax/IDs before transport. Candidate-specific recipe/param
  incompatibility is a skip with a reason, not a launch. Render using only the
  selected candidate's recipe, paths, defaults and environment. Preserve quoting,
  sudo rejection, immutable IDs, and existing receipts/status/log/pull commands.

## Key sequences

1. Parse and validate the invocation and project data. Build ordered candidates
   from project availability plus the machine-local registry. Check local recipe
   and environment compatibility without executing work.
2. A bounded, read-only SSH reachability check may skip an unreachable candidate
   before any reservation. Keep pinned host keys and key-only SSH. The existing
   launcher may skip a local busy/locked candidate, or a target's explicit
   unambiguous capacity/lock refusal *during reservation*. Carry explicit launch
   phase/outcome information; a bare nonzero exit code is not a retry signal.
3. Once reservation might have succeeded, stop on every failure. In particular,
   malformed/lost reservation acknowledgements, staging errors, and all launch
   failures (including exit 6) must never dispatch to another candidate. A lost
   launch reply keeps the existing unknown receipt. Explain the selected target
   and job ID, and how to inspect it before manual retry. A successful dispatch
   ends selection immediately; no speculative parallel launch.

## Decisions

- Opt-in selection, not a scheduler: no queue, daemon, fairness, new lock, or
  automatic rerun. There is no promise that availability implies idle capacity.
- Config replacement semantics match the shared loader; test parity directly
  against it, including an empty local override. Only compute is consumed.
- Exhaustion reports per-candidate reasons. No eligible candidate is a usage
  error (2); all eligible candidates busy is locked (6); exhaustion including
  unreachable candidates is unreachable (1). Security/identity errors after a
  reservation attempt are hard stops, preserving the existing exit status.
- Verify with committed red tests, real disposable local target-protocol tests
  around admission/ambiguous launch, and the complete recorded local gate.
  Test the installed combined CLI as well as the source controller.
- Update README.md, AGENTS.md, the plugin README, skill, user guide and both help
  surfaces together. No formal registered spec is extended by this human CLI
  feature, so do not fabricate a SPEC-ASSISTANT delta or schema-version bump.

## Out of scope

Assistant audit/ComfyUI integration (#349/#348), fleet scheduling, live hardware
ranking, environment installation, registry sync, native PowerShell targets,
pipeline configuration, and rewriting unrelated historical documentation.
