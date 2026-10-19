# Design — mem/E1: local-state freshness and runtime inventory

Grounded in SPEC-MEMORY.md §7.1–§7.4, existing MEM-010/011/013 behavior, and task #274 with the owner comment of 2026-07-22. This follow-up adds detection to the established repair path; it does not introduce another path registry.

## Components

- `local-state.manifest` is the sole policy source for repository-relative runtime outputs: local/derived state is ignored, shared durable artifacts tracked. Existing directory entries cover descendants; specific derived exceptions may override a tracked directory.
- `gitignore-sync.sh` owns managed-block rendering and comparison. Its dry-run is the detection authority for both preflight and the existing mem013 sync rule. Apply remains an explicit repair operation.
- `validate-config.py` owns config validity. Preflight invokes it against the config path resolved by existing config.py logic; no second schema checker or automatic migration is added.
- `preflight.sh` coordinates cheap local checks in both normal and `--spec` modes. Its existing advisory/bootstrap API remains exit0 with actionable `PREFLIGHT FAIL` diagnostics; skill callers still stop on that line. Existing no-config, spec-presence, checkpoint, identity, cache and design advisories remain applicable.
- A committed audit document records the all-plugin skill/script sweep and each runtime writer's disposition. Tests remain hermetic and exercise the actual helpers.

## Interfaces and data

A missing or stale managed block emits `PREFLIGHT FAIL` with the actual target and a safely usable `gitignore-sync.sh` repair command. A helper failure is a failure to establish freshness, never a clean result. Compare stdout diff separately from diagnostics; a successful current check adds no output to the pre-existing successful preflight output. Invalid config prints actionable validator evidence and repair guidance; current valid configs do not gain a validator success transcript. Preserve supported legacy layouts and existing config selection/overlay semantics through the existing helpers.

Use `gitignore-sync.sh --dry-run <root>/.gitignore` for detection. Dry-run must not edit the target or leave temporary files after ordinary success, failure or handled interruption, including when TMPDIR points inside the consumer repository. Preserve non-managed bytes and the existing track-path warning policy. Surface comparison/read/write failures rather than swallowing them as no diff. Clean up only helper-owned temporary paths; do not sweep user files. SIGKILL/power-loss cleanup cannot be promised.

## Key sequences

1. Resolve root/config using existing code. Missing config retains bootstrap guidance. Invoke the existing validator; capture failed validation diagnostics without duplicating validation rules.
2. Ask the existing sync helper for its dry-run diff. Report stale/missing state or inability to inspect it, without repairing automatically. Preserve other preflight contracts and stop-condition wording.
3. Explicit sync/repair uses the same helper and manifest. An apply followed by preflight must be clean; repeated dry-run must be silent and leave target/tree unchanged. Existing mem013 detect/apply continues to use this authority.
4. Sweep every skill and script under all four plugins, including generated templates and remote capability payloads. Follow variable-derived paths and writes, not only literal `.claude` matches. Document source locations, default/resolved output path families, policy and coverage. Record read-only files and test-only fixtures in a coverage inventory so omitted files are visible.
5. Add each uncovered repository-owned default to the manifest with the correct policy, then regenerate this repo's managed block through the sync helper. Update exact-list tests and docs. Explicitly exclude external machine/user caches, caller-selected output locations, browser storage and ephemeral fixtures with evidence-based rationale; never hide unknown paths under a broad blanket ignore. Custom overrides remain consumer responsibility and must be documented.

## Decisions

- The issue's new validity/freshness requirements intentionally extend preflight while preserving its exit0 loader contract. No schema format change or semver-schema migration is needed.
- Preserve outside-block rules, even if this repo intentionally ignores a tracked default such as docs/handoffs; the existing warning contract explains the conflict. Do not silently unignore user content.
- The audit is a bounded source inventory at this change, not a new universal static analyzer or a claim that arbitrary user programs cannot write elsewhere. Include peer-review temp outputs, scaffold scripts/state, remote-compute controller/target state, UI-hub/neural-view state, handoffs, local locks/caches and temporary siblings.
- Test real missing/stale/current blocks, valid/invalid config in both modes, diff/helper failures, TMPDIR-in-repo cleanup, and repaired consumers via mem013. New behavioral tests must fail and be committed before implementation; retain focused existing integration-contract checks.

## Out of scope

No automatic edits during preflight, no broad user-file cleanup, no change to gate/closure/checkpoint/WIP/approval authority, no host fork, no remote execution, no UI decisions, no new configurable registry, and no migration of unrelated consumer repositories. The dev writes a pending §7 spec delta; canonical spec folding waits for merge.
