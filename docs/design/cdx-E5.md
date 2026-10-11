# Design - cdx/E5: compatibility sweeps

Grounded in SPEC-CODEX-COMPAT.md sections 7-9, 10.3 and 11, and issue #194's
owner triage. CDX-050 now audits the four shipped remote-compute skills, not
the obsolete compute-registry/#166 trigger. Update that contract via a spec
delta; do not edit the canonical spec until the task merges.

## Components

- docs/compatibility-matrix.md: incremental per-host evidence matrix. This task
  contributes exactly remote-compute, compute-top, scan and ssh. It does not
  claim CDX-042's entire marketplace inventory is complete.
- Per-skill semantic audit: source-backed interaction, invocation, delegation
  and enforcement behavior for Claude Code and Codex, mapped to sections 7-9.
- Existing shared Python/Bash engine and hermetic tests: mechanical boundaries
  remain shared, without new host-specific runtime implementations.
- Follow-up issues: concrete gaps are deduplicated and filed separately by the
  orchestrator, linked from the matrix; no silent inline fixes in this audit.

## Interfaces / Contracts

Record the distinction among source-reviewed compatibility, locally tested
engine behavior, external manifest/linter results, and actual host installation
or live SSH evidence. Missing validators or unperformed live host checks remain
unverified, never converted into a parity claim.

Both hosts need a supported execution environment: WSL/Linux/macOS with the
required shell, Python and SSH tools. Native PowerShell is not a compute target;
a Windows-hosted agent needs a WSL bridge for these commands. An interactive
dashboard requires the human's TTY; non-TTY execution has a one-shot fallback.

The four skills do not spawn developer/reviewer roles or move Project statuses.
Mark genuinely inapplicable delegation/build-loop clauses N/A with reasons, not
as tested capabilities. Separate script enforcement from agent instructions:
human host-key acknowledgement and intent-versus-raw-command policy are not
proved merely by an accepted flag or a manifest. No reliance on host hooks or
allowed-tools as a cross-host security boundary.

## Key Sequences

1. Enumerate the actual four SKILL.md files and inspect every workflow.
2. Map each relevant section 7-9 clause to concrete source/tests and both hosts;
   record unsupported, unverified, or inapplicable cases explicitly.
3. Inspect bounded gaps, have the orchestrator deduplicate/file useful ones,
   and link their issue numbers in the matrix before closure.
4. Red-first documentation/coverage tests prove omitted rows, unsupported
   claims, and missing gap references do not silently pass; retain meaningful
   negative tests rather than broad whole-file keyword co-occurrence.

## Decisions

- Local tests only, per the current user instruction. Do not create, modify,
  rely on, or claim success from pipelines; section 10.1 infrastructure is not
  this task's scope. Correct the section 11 note's assumed evidence if needed.
- Keep the matrix incremental and clearly scoped; link it from README/AGENTS
  and the plugin README with a published fallback for installed plugin readers.
- Preserve existing runtime, schemas, commands, aliases, manifests, hooks,
  registration data and source skill behavior. This is an audit, not a rewrite.
- Record a paste-ready CDX-050 delta and narrow backlog correction for the
  replaced trigger. Keep broader compatibility requirements intact.

## Out Of Scope

Live installs, SSH writes/jobs, native PowerShell setup, generic manifest or
skill-lint infrastructure, marketplace-wide certification, new dispatch policy,
and fixing discovered gaps inline. Those belong to named follow-up tasks.
