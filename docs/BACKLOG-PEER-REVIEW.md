# Backlog — spec `peer` (SPEC-PEER-REVIEW.md)

Task ids: `PRV-<number>`. Ranges: E0 = 001–009, E1 = 010–019. Points ≈ complexity (1–10
rubric, seed-board skill; no task ≥8 unsplit). Every task cites its spec §s; acceptance
criteria are the merge bar. E0 ships first and standalone; E1 has no dependency on E0
(no cross-epic guards needed). Within E1, PRV-011/PRV-012 are blockedBy PRV-010.

## E0 — `/peer-review` skill (§6)

### PRV-001 · Diff-source resolution + preflight — P0 · 3 pts · §6.1 §6.3 §6.4 §6.7
Tested script that resolves the diff to review (default `git diff <mainBranch>...HEAD`
with `main` fallback; `--base <ref>`; `--staged`; PR number via `gh pr diff`) and preflights
the `codex` binary.
**Acceptance:** fixture-git-repo tests cover all four diff sources and the mainBranch
fallback; empty diff → "nothing to review", exit 0, codex never invoked (§6.4); missing
`codex` on PATH → nonzero exit with printed install instructions (§6.7); PR path tested via
the fake-gh harness; shellcheck clean.
**DoD:** suite green; red tests committed before implementation.

### PRV-002 · Codex invocation + structured findings with raw fallback — P0 · 4 pts · §6.2 §6.5 §6.6 §6.8
Invoke `codex exec --sandbox read-only --output-schema` with the diff embedded in the
prompt; parse findings {file, line, severity, summary, failure scenario, verdict}; degrade
gracefully.
**Acceptance:** invocation is asserted to contain `--sandbox read-only` and no test or code
path can produce a write-capable sandbox (§6.2); fake-codex fixtures cover valid JSON
(rendered findings), malformed JSON (raw output verbatim + parse-failure note, exit 0, no
crash — §6.6), and auth-failure stderr (surfaced verbatim, no API-key prompt — §6.8);
findings rendered under "External review — codex" (§6.5).
**DoD:** suite green; no network in tests.

### PRV-003 · /peer-review SKILL.md + docs + disclosure — P1 · 3 pts · §6.9 §6.10 §12(OQ-1)
The user-facing skill: terse SKILL.md (house style) wiring PRV-001/PRV-002, argument parsing,
output rendering; placement `plugins/peer-review` (OQ-1, decided).
**Acceptance:** skill doc plainly states that reviewing sends the diff to OpenAI's cloud
(§6.10); no file-modifying step exists anywhere in the skill (§6.9); README tables updated.
**DoD:** suite green; skill listed in plugin README; `claude plugin validate` passes.

*(PRV-004–009 headroom for discovered E0 work.)*

## E1 — Remote LLM dispatch (§7 §8)

### PRV-010 · Registry file schema + loader/validation — P0 · 3 pts · §7.1 §7.2 §7.3
`.claude/compute-registry.yaml` (schemaVersion literal 1, providers: id/endpoint/token) and
a tested loader shared by status and dispatch.
**Acceptance:** fixture YAMLs cover: valid file parses; `schemaVersion: 2` → actionable
error (§7.1); inline-literal token → refusal naming the rule (§7.2); `${VAR}` reference with
unset env var → error naming the variable (§7.3); no `capabilities` key in the schema (spec
§5 decision) — an unknown key is tolerated but ignored.
**DoD:** suite green; loader is the only YAML-reading code path.

### PRV-011 · /compute-registry status skill — P1 · 3 pts · §7.4 §7.5 · blockedBy PRV-010
Reads the registry, GETs `<endpoint>/models` with bearer token and per-provider timeout
(default 5s, OQ-3 decided), reports reachable/unreachable + why; reference doc carries the
YAML template and the exact `llama-server --host 0.0.0.0 --port 8080 --api-key ...` launch
command plus the Windows Defender note.
**Acceptance:** stub HTTP server on a randomized port drives 200 → reachable, 401/403 and
500 → unreachable with reason, hang → timeout reason; bearer header asserted present (§7.4
decision); unreachable output points at the reference doc (§7.5); token value never appears
in any output; READMEs updated.
**DoD:** suite green.

### PRV-012 · Dispatch helper — P1 · 3 pts · §8.1–§8.5 §12(OQ-2) · blockedBy PRV-010
`dispatch(provider_id, prompt, timeout_s)` → POST `chat/completions`, bearer auth, returns
text; default timeout 120s (OQ-2, decided); documented manual invocation against the real
notebook (advisory, not merge-gating — spec §11, OQ-4 default keeps `/peer-review` wiring
out of v1).
**Acceptance:** stub-server tests cover success (text returned), unknown provider id →
error listing known ids (§8.2), timeout → nonzero + provider-naming message, no retry
(§8.3), non-200 → status + bounded body tail (§8.4); token-redaction asserted on every
error path (§8.5); no pre-flight GET before the POST (§8.1).
**DoD:** suite green.

*(PRV-013–019 headroom for discovered E1 work.)*
