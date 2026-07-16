# Design — peer/E0: `/peer-review` skill
Grounded in: SPEC-PEER-REVIEW.md §5, §6, §9, §11. Amended for PRV-004 (§6.11, dynamic model
selection) — see the new Component/Interface/Decision entries below, marked "(PRV-004)".

## Components
- `scripts/diff-source.sh` — resolves the diff to review from the four sources (§6.1, §6.3)
  and preflights `codex` on `PATH` (§6.7). Pure/testable: given repo state + args, prints the
  diff to stdout (or nothing + exit 0 on empty diff, §6.4) and exits nonzero with an install
  message if `codex` is missing.
- `scripts/peer-review.sh` — orchestrates: calls `diff-source.sh`, invokes `codex exec
  --sandbox read-only --output-schema <schema>` with the diff embedded in the prompt (§6.2,
  §6.5), parses the result, falls back to raw text on schema-validation failure (§6.6),
  surfaces auth failures verbatim (§6.8).
- `schema/peer-review-findings.json` — the `--output-schema` JSON Schema: `{file, line,
  severity, summary, failure_scenario}[]` plus an overall verdict, mirroring `ReportFindings`'
  shape (§6.5).
- `skills/peer-review/SKILL.md` — the user-facing skill: argument parsing (`--base`,
  `--staged`, a PR number), wires the two scripts, renders output under "External review —
  codex" (§6.5), states the OpenAI-cloud disclosure (§6.10). (PRV-004) Also runs
  `list-models.sh`, presents its output via `AskUserQuestion`, and threads the pick through
  `run.sh --model <slug>`.
- `scripts/list-models.sh` (PRV-004) — discovers available codex models (`codex debug
  models`), filters to `visibility: list` + `supported_in_api: true`, sorts by `priority`
  ascending, emits `{"models":[...], "recommended":"<slug>"}` (§6.11). Nonzero exit (codex
  missing, discovery failed, zero eligible) is a "skip selection, don't block the review"
  signal to its caller, never a hard failure.

## Data models
- **Finding**: `{file: string, line: int|null, severity: enum(info|warn|error), summary:
  string, failure_scenario: string}`. `line` nullable — some findings are file-level, not
  line-anchored.
- **Review result**: `{findings: Finding[], verdict: string}` on the structured path, OR
  `{raw: string, parse_failed: true}` on the fallback path (§6.6) — the skill must handle
  both shapes when rendering.

## Interfaces / contracts
- `diff-source.sh [--base <ref>|--staged|--pr <n>]` → stdout: unified diff text, or empty +
  exit 0 (nothing to review, §6.4); exit 2 + stderr install message if `codex` missing (§6.7).
- `peer-review.sh <diff-text-file>` → stdout: rendered findings (structured or raw-fallback);
  exit 0 on a completed review (even with findings), nonzero only on preflight/auth failure.
- Every `codex exec` invocation MUST include `--sandbox read-only` — no code path constructs
  the command without it (§6.2, and SPEC §9 invariant: "a peer review NEVER writes"). (PRV-004)
  `-m <slug>` (model selection) is always added strictly after `--sandbox read-only` is fixed,
  so no model choice can influence the sandbox flag.
- (PRV-004) `list-models.sh` → stdout JSON (see above) + exit 0, or exit nonzero with nothing
  meaningful on stdout — the latter is a fallback signal, not an error the caller must surface
  to the human.

## Key sequences
1. `SKILL.md` parses args → calls `diff-source.sh` → gets diff text (or exits early on empty
   diff/missing codex).
2. `SKILL.md` calls `peer-review.sh` with the diff → it builds the prompt, shells out to
   `codex exec --sandbox read-only --output-schema ...`.
3. On success: parse JSON against the schema. Valid → render findings table under "External
   review — codex". Invalid/malformed → print raw stdout verbatim + a parse-failure note
   (§6.6), still exit 0 (a review happened, just unstructured).
4. On `codex` exiting nonzero (auth failure): surface its stderr verbatim, do not attempt to
   parse output, do not prompt for credentials (§6.8).

## Decisions
- **No shared adapter/registry code** — `/peer-review` calls `codex exec` directly (SPEC §5:
  "why codex directly and not via the registry"). E1's registry/dispatch code (PRV-010+) is
  architecturally unrelated; do not introduce a shared interface between them speculatively.
- **Schema-validation fallback, not a hard failure** — codex's `--output-schema` is known to
  occasionally emit malformed JSON (SPEC §6.6, confirmed via upstream GitHub issues); the
  skill must degrade to raw text, never crash or silently drop the review.
- **Diff embedded in the prompt, not just referenced** — matches the OpenAI Codex-SDK
  code-review cookbook pattern (SPEC §5); `codex exec` also has its own local file-read tools
  for repo context beyond the diff itself, since it runs locally.

## Out of scope for this epic
- The remote/llama.cpp dispatch path (`.claude/compute-registry.yaml`, `/compute-registry
  status`, the dispatch helper) — that's E1 (PRV-010/011/012), a fully independent vertical.
- Wiring the E1 remote provider into `/peer-review` as a backend option — explicitly deferred
  past v1 (SPEC §12 OQ-4, decided: not in v1).
- Auto-fix / `--fix` mode — explicitly out of scope (SPEC §3, §6.9).
- The peer-reviewer agent-identity work (board issue #171) — a separate, later task; this
  epic's output label is a plain string ("External review — codex"), not an identity lookup.
