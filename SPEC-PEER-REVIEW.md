# Peer review - shipped CLI providers and deferred HTTP proposal

Status: APPROVED for shipped peer review, registered as spec `peer` (taskPrefix
`PRV`). E0 supports OpenAI Codex and Anthropic Claude through local CLI provider
scripts. E1 HTTP dispatch is **unimplemented and deferred** pending explicit
future design. It is not a prerequisite or authorization mechanism for E0.

The binding decision is `docs/design/peer-egress-authority.md` (#529). It
supersedes the endpoint-authority assumptions of
`docs/design/compute-registry-plan-v3.md` and `docs/design/peer-E0.md`.
The original decision to group E0 and E1 in this document is retained as history;
it does not mean the proposed registry, status skill, or HTTP helper shipped.
Sections 7 and 8 preserve the historical proposal, not active implementation
guarantees. Section 6's provider flows remain unchanged.

## §1 Overview

The shipped `/peer-review` skill obtains a source-labeled review through a
human-selected, trusted local provider script. The two shipped providers invoke
the user-installed OpenAI Codex and Anthropic Claude CLIs. They receive the diff
in a prompt and can use local repository context; findings are reported, never
applied by the plugin. Review flags constrain intended file editing, not network
destinations.

E1's HTTP model-endpoint registry, status command, and synchronous dispatch helper
are unimplemented and deferred. Remote-compute's SSH-machine registry is a
different system and does not authorize peer HTTP requests.

## §2 Goals

- **G1** - From any repo, obtain an external review through the human-selected
  Codex or Claude provider, with structured findings or the existing raw fallback,
  without modifying reviewed files (§6).
- **G2** - Disclose external transmission, including possible repository context
  beyond the diff, and accurately describe authority: trusted local provider
  dispatch plus the user's CLI configuration. The former notebook HTTP goal is
  unimplemented and deferred with E1 (§7, §8).
- **G3** - Add no persistent process, daemon, heartbeat, or background service;
  review scripts run synchronously at the moment of use (§9).

## §3 Non-goals

- No peer HTTP dispatcher, HTTP endpoint registry, endpoint allowlist, or token
  management is shipped. E1 is unimplemented and deferred; no second registry is
  introduced to satisfy its historical prose.
- No registry service, heartbeat agent, TTL/staleness model, or capability-ceiling
  model (removed in the historical v3 proposal; do not rebuild speculatively).
- No asynchronous job-queue interface (`submit`/`collect`/`cancel`) in peer review.
  Remote-compute's separate SSH job system is outside this peer contract.
- No HTTP provider selection or `/compute-registry` administration/status skills.
  The shipped CLI provider picker in §6.12 remains supported.
- No auto-fix in `/peer-review`; a future opt-in `--fix` requires separate work.
- No plugin-enforced network isolation for the user's CLIs or trusted registry
  overrides. Provider review flags are not destination controls.
- ComfyUI / image/video/3D generation remains out of scope. The requirement for a
  future generation spec remains: *only ever dispatch pre-authored,
  repo-committed workflow templates, never dynamically constructed graphs*.
  Board issue #166 tracks the spike; this is not a third peer provider.
- No wiring of remote HTTP providers into `/peer-review` without a new explicit
  endpoint, authentication, redirect, and redaction design (§12).

## §4 Glossary

- **Peer review** - another vendor's assessment, selected by the human and labeled
  as external findings rather than silently merged into the orchestrator's judgment.
- **Codex / Claude** - the user-installed OpenAI `codex` and Anthropic `claude`
  CLIs. Review uses `codex exec --sandbox read-only` or
  `claude -p --permission-mode plan`; Codex model discovery is a separate CLI call.
- **Provider registry** - `plugins/peer-review/scripts/providers.tsv`, naming
  trusted local discovery/review scripts. Overrides are executable configuration,
  not a network destination allowlist or security sandbox.
- **Dispatch (shipped)** - registry lookup followed by execution of the selected
  local script, with arguments forwarded unchanged.
- **Transport authority** - the user's selected CLI and its configuration own
  authentication and transport; peer-review does not enforce their destinations.
- **SSH-machine registry** - remote-compute's user-local
  `~/.remote-compute/resources.yaml`, recording machines, pinned host identity,
  environments, and declared recipes. It is not a peer HTTP endpoint/token registry.
- **E1 registry / HTTP dispatch / status** - unimplemented, deferred historical
  proposals for `.claude/compute-registry.yaml`, HTTP POST to `chat/completions`,
  and GET `/models`. These names do not denote shipped peer controls.

## §5 Architecture

**E0 - shipped CLI review.** The standalone `plugins/peer-review` plugin reads
`scripts/providers.tsv`, presents the existing human provider picker, resolves
the diff, selects a model, and invokes the provider through
`provider-dispatch.sh`. Codex uses `list-models.sh` and `run.sh`/`peer-review.sh`;
Claude uses `list-claude-models.sh` and `claude-run.sh`/`claude-review.sh`.
The provider registry and `PEER_REVIEW_PROVIDERS_FILE` overrides are trusted
executable configuration: their script paths execute local code. They are not a
security sandbox; the plugin enforces no destination allowlist.

**Disclosure and authority.** Review material is sent to the selected provider's
cloud: OpenAI through Codex, or Anthropic through Claude. The CLI may read and send
repository context beyond the diff. The user's CLI configuration owns
authentication and transport, including any configured endpoint or intermediary;
the plugin does not validate or constrain that transport. Codex's
`--sandbox read-only` and Claude's `--permission-mode plan` protect intended
review edits, not network isolation. Findings remain source-labeled and are not
applied. Provider failures and raw fallback output are forwarded; there is no
plugin token-redaction guarantee. Users must keep secrets out of committed code
and review material they authorize for transmission.

**E1 - unimplemented and deferred.** There is no peer HTTP dispatcher and no
endpoint allowlist. The proposed `.claude/compute-registry.yaml`,
`/compute-registry status`, and HTTP helper never shipped. Their historical
schema, notebook setup, and timeout choices remain in the v3 design and backlog.
They are not instructions to create a new registry now.

**Remote-compute boundary.** `~/.remote-compute/resources.yaml` is the real
SSH-machine registry, not an HTTP model endpoint/token authority. SSH registration
does not authorize peer HTTP transmission, grant consent to send a diff, or
validate a model endpoint. A future backend must explicitly decide endpoint
authority, tokens/authentication, redirects, and redaction before it ships.

Existing commands, aliases, provider selection/defaults, empty-diff and error
behavior, model flags, and §6 flows remain unchanged. No new schema, API, service,
or HTTP implementation is introduced. House constraints remain Bash 3.2 and
stdlib-only Python for peer scripts, with ShellCheck verification.

## §6 `/peer-review` skill (E0)

- **§6.1** WHEN `/peer-review` is invoked with no arguments THE SYSTEM SHALL review the diff
  `git diff <mainBranch>...HEAD`, where `<mainBranch>` comes from repo config when available
  and falls back to `main`.
- **§6.2** THE SYSTEM SHALL invoke codex exclusively as `codex exec` with `--sandbox
  read-only`; no flag or argument path SHALL produce a write-capable sandbox.
- **§6.3** WHEN `--base <ref>`, `--staged`, or a PR number is given THE SYSTEM SHALL take the
  diff from `git diff <ref>...HEAD`, `git diff --staged`, or `gh pr diff <n>` respectively.
- **§6.4** IF the computed diff is empty THEN THE SYSTEM SHALL report "nothing to review"
  and exit 0 without invoking codex.
- **§6.5** THE SYSTEM SHALL request findings via `--output-schema` in the shape {file, line,
  severity, summary, failure scenario} plus an overall verdict, and render them under the
  label "External review — codex".
- **§6.6** IF the codex output fails to parse against the schema THEN THE SYSTEM SHALL print
  the raw output verbatim with a note that structured parsing failed, and SHALL NOT crash
  (known codex `--output-schema` rough edge, v3 Spec A).
- **§6.7** IF `codex` is not on `PATH` THEN THE SYSTEM SHALL fail with a nonzero exit and
  printed install instructions.
- **§6.8** IF codex authentication fails THEN THE SYSTEM SHALL surface codex's own stderr
  and SHALL NOT prompt for an API key in-conversation.
- **§6.9** THE SYSTEM SHALL NOT modify any file as part of a review (no auto-fix path
  exists in v1).
- **§6.10** THE SYSTEM SHALL state in the skill's user-facing doc that reviewing a diff via
  `codex exec` sends that diff to OpenAI's cloud.

## §7 Compute registry file + status (E1, historical)

**Unimplemented and deferred; superseded as current authority by #529.** The
following numbered criteria preserve the historical E1 proposal. They are not
active shipped guarantees or authorization to implement it. No code reads the
proposed `.claude/compute-registry.yaml`; no `/compute-registry status` ships.

- **§7.1 (historical)** Proposed reading providers exclusively from
  `.claude/compute-registry.yaml` with `schemaVersion` literal `1`, refusing other
  versions with an actionable error.
- **§7.2 (historical)** Proposed refusing a provider whose token was not an
  `${ENV_VAR}` reference, to keep literal secrets out of git.
- **§7.3 (historical)** Proposed failing with the variable name when the token's
  referenced environment variable was unset.
- **§7.4 (historical)** Proposed GET `<endpoint>/models` with bearer authentication
  and per-provider timeout, reporting reachable for 200 or the failure reason
  (timeout, connection refused, 401/403, other non-200). The proposal assumed
  `llama-server --api-key` also protected `/models`.
- **§7.5 (historical)** Proposed pointing unreachable-provider reports at a YAML
  template and `llama-server` launch-command reference.

The real remote-compute registry is user-local `~/.remote-compute/resources.yaml`
for SSH machines. SSH registration does not authorize HTTP model endpoints or
token transmission. Future E1 work must decide endpoint authority, token handling,
redirect policy, and redaction explicitly before a backend is enabled; neither
this historical schema nor SSH registration makes that decision.

## §8 Dispatch helper (E1, historical)

**Unimplemented and deferred; superseded as current authority by #529.** No peer
HTTP helper or enforcement of these criteria ships. The proposal is retained for
future design review, not as an active runtime promise.

- **§8.1 (historical)** Proposed `dispatch(provider_id, prompt, timeout_s)` posting
  to `<endpoint>/chat/completions` with a bearer token and returning response text,
  without a pre-flight health check.
- **§8.2 (historical)** Proposed rejecting unknown HTTP provider ids and listing
  known ids. The shipped CLI dispatcher has its own existing registry lookup and
  error behavior (§6.12), unchanged by this proposal.
- **§8.3 (historical)** Proposed a finite timeout, nonzero exit naming the provider,
  and no automatic retries.
- **§8.4 (historical)** Proposed surfacing a non-200 HTTP status and bounded body tail.
- **§8.5 (historical)** Proposed redacting resolved token values from all output,
  logs, and errors. The shipped CLI wrappers forward provider errors and raw
  fallback output; they do not implement this token-redaction control.

A new reviewed design must establish endpoints, authentication/tokens, redirects,
redaction and tests before any HTTP backend ships. No endpoint authority is chosen
here, and registration of an SSH machine cannot substitute for that decision.

## §6.11 Dynamic model selection

- **§6.11.0** THE SYSTEM SHALL resolve the diff (§6.1/§6.3/§6.4) BEFORE performing any model
  discovery. IF the diff is empty THEN model discovery SHALL NOT run — §6.4's existing
  guarantee ("codex is never invoked" on an empty diff) extends to `codex debug models`, not
  only `codex exec`.
- **§6.11.1** WHEN `/peer-review` is invoked with a non-empty diff THE SYSTEM SHALL discover
  available codex models by running `codex debug models`, filtering to entries with
  `visibility == "list"` AND `supported_in_api == true` AND a valid `slug` (non-empty string)
  and `priority` (integer, not boolean) — `display_name`/`description`, if missing or
  non-string, default to the `slug` and an empty string respectively rather than excluding the
  model — and sorting the eligible result by `priority` ascending.
- **§6.11.2** IF exactly one model is eligible THEN THE SYSTEM SHALL use it directly without
  asking. IF two or more models are eligible THEN THE SYSTEM SHALL present at most the
  top 4 (by §6.11.1's priority-ascending order) to the human via `AskUserQuestion` — which
  accepts 2–4 options — one option per model, recommending (first-listed, labeled
  "Recommended") the lowest-`priority` eligible model. No other recommendation heuristic (e.g.
  diff-size-aware weighting) is used.
- **§6.11.3** WHEN a model is chosen THE SYSTEM SHALL invoke `codex exec` with `-m <chosen
  slug>` in addition to the existing `--sandbox read-only --output-schema` flags (§6.2, §6.5).
  `-m` SHALL always be added strictly after `--sandbox read-only` is fixed in the constructed
  command — no model selection is capable of relaxing or altering the sandbox flag (§6.2 is
  unaffected by this addition).
- **§6.11.4** IF model discovery fails — `codex` is not on `PATH`, `codex debug models` exits
  nonzero, its output is not valid JSON, or zero models survive the §6.11.1 filter — THEN THE
  SYSTEM SHALL skip model selection entirely and invoke `codex exec` with no `-m` flag (the
  pre-PRV-004 default behavior). A discovery failure SHALL NOT block or fail the review.

## §6.12 Provider selection (CDX-053)

- **§6.12.0** THE SYSTEM SHALL NOT auto-detect which model is orchestrating the session to
  decide the review provider. `/peer-review` SHALL always ask via `AskUserQuestion`, decided by
  a human, because `/peer-review`'s value proposition (a genuinely independent second opinion)
  only holds if the reviewer is a different vendor than whoever is orchestrating — a fact that
  inverts depending on which CLI is driving the session and cannot be reliably inferred from the
  environment.
- **§6.12.1** THE SYSTEM SHALL maintain the set of reviewable providers as data (a registry:
  `plugins/peer-review/scripts/providers.tsv`, one row per provider — id, display name,
  model-discovery script, review script), never as a hardcoded if/else across skill prose or
  scripts. Adding a provider SHALL require exactly one new registry row; no script in the
  `peer-review` plugin may branch on a provider id.
- **§6.12.2** THE SYSTEM SHALL run provider selection BEFORE diff resolution (§6.1) and before
  any model discovery (§6.11.0). Provider selection is a registry read only — no external CLI
  is touched to enumerate providers — so it is strictly cheaper than the diff-emptiness check
  it precedes, and lets a human signal a provider preference before any other work happens.
- **§6.12.3** IF exactly one provider is registered THEN THE SYSTEM SHALL use it directly
  without asking. IF two or more are registered THEN THE SYSTEM SHALL present at most the first
  4 (registry order) via `AskUserQuestion` — one option per provider, `preview` the display
  name — regardless of each provider's availability (§6.12.4); an unavailable provider is still
  a valid, informative choice. This mirrors §6.11.2's model-picker capping/skip-if-1 pattern
  exactly, so a third provider needs no new selection logic.
- **§6.12.4** A provider registered with an empty review-script column SHALL be reported as
  unavailable (`"available": false` in `providers.sh`'s JSON) rather than omitted from the
  catalog. IF the human selects an unavailable provider THEN THE SYSTEM SHALL stop immediately
  — before diff resolution, before any model discovery — and show a message naming that
  provider's display name and stating its backend is not yet available, exiting nonzero. THE
  SYSTEM SHALL NOT attempt to execute a missing/absent script file.
- **§6.12.5** `provider-dispatch.sh <provider-id> <list-models|run> [-- <args>]` SHALL resolve a
  provider's registered script path relative to the registry file's own directory (not the
  dispatch script's), and SHALL exec it with `<args>` forwarded verbatim, with no
  provider-specific logic beyond the registry lookup itself.
- **§6.12.6** Selecting the `codex` provider SHALL reach the exact same `list-models.sh` →
  `AskUserQuestion` → `run.sh --model` flow already specified by §6.11, with zero behavior
  change from the pre-CDX-053 direct-invocation form — this is a regression gate, not merely a
  design goal.

## §9 Invariants

- A peer review does not modify reviewed files or apply findings. The shipped
  Codex review uses `--sandbox read-only`; Claude uses `--permission-mode plan`.
  These flags constrain intended review edits, not network isolation. Private
  temporary diff/output files are cleaned up by the wrappers.
- Secrets must not be committed to git. Authentication belongs to the user's CLI
  configuration; the plugin adds no credential store. Provider errors and raw
  fallback output are forwarded, so no plugin redaction guarantee is asserted.
- External transmission is disclosed for both OpenAI/Codex and Anthropic/Claude,
  including possible repository context beyond the diff. The user's CLI
  configuration owns transport; the plugin enforces no destination allowlist.
- Provider registry entries and overrides are trusted executable configuration,
  not a security sandbox. SSH-machine registration grants no peer HTTP authority.
- No persistent process, daemon, heartbeat, or background agent is installed by
  peer review; wrappers execute synchronously at the moment of use.
- External findings remain labeled with their source and are never presented as,
  or silently merged into, the orchestrator's own judgment.
- Scripts remain Bash 3.2-compatible / stdlib-only Python, `set -uo pipefail`, and
  ShellCheck-clean (house rule, SPEC.md §9).

## §10 Non-functional

- Shipped review performs local diff/registry work plus the selected provider's
  model discovery and review. No peer service is installed or started.
- Runtime tools are Bash, stdlib Python, git, the selected user-installed Codex or
  Claude CLI, and `gh` when reviewing a PR. No HTTP dispatcher dependency is added.
- The historical 5 s status and 120 s dispatch defaults belong to unimplemented,
  deferred E1. They are not enforced time bounds on shipped CLI reviews; the peer
  wrappers add no review timeout or network destination enforcement.

## §11 Testing strategy

Verification is local and hermetic. Run the full repository gate and, separately,
the complete peer suite (`bash plugins/peer-review/tests/run-tests.sh`),
`shellcheck -x plugins/peer-review/scripts/*.sh plugins/peer-review/tests/*.sh`,
peer manifest validation, and config validation for metadata corrections. The
default repository gate does not include the peer suite. No pipeline setup or
cloud test dependency is required.

- **E0** - fake Codex and Claude binaries, fixture git repositories, and fake `gh`
  exercise diff sources, provider routing, model selection/defaults, review flags,
  structured/raw output, error propagation, empty diffs, and missing/unknown
  providers. Tests never invoke a live review backend.
- **Authority contract** - semantic checks validate the effective pending #529
  delta before folding and the canonical spec afterward using the same assertions.
  Empty/missing delta content cannot exempt stale canonical claims. Mutation cases
  reject stale active registry invariants and missing or wrong disclosures.
- **E1** - unimplemented and deferred. Historical YAML fixtures, local HTTP status,
  timeout, authentication and token-redaction tests were a proposed test plan, not
  evidence of shipped controls. A future approved HTTP design must define its
  own offline enforcement tests before implementation.
- Real Codex/Claude, remote endpoints, SSH, notebook setup and deployment are not
  verified by hermetic tests. Any future manual checks are advisory and require
  authorization; no live checks are needed for this documentation correction.

## §12 Open questions

E1 is unimplemented and deferred. Historical choices below are preserved without
claiming their defaults were applied. The binding egress decision is #529.

| id | question | owner | decision or historical proposal | status |
|---|---|---|---|---|
| OQ-1 | Plugin placement? | user | Standalone `plugins/peer-review`; shipped skill has no board-workflow dependency. The original plan to house both skills did not implement the HTTP skill. | Decided for E0; E1 deferred |
| OQ-2 | HTTP dispatch default timeout? | user | Historical proposal: 120 s. | Unimplemented; deferred for future design |
| OQ-3 | HTTP status per-provider timeout? | user | Historical proposal: 5 s. | Unimplemented; deferred for future design |
| OQ-4 | Wire an HTTP provider into `/peer-review`? | user | Historical decision: not in v1. No standalone HTTP helper shipped either. | Deferred; explicit future design required |
| OQ-5 | Carry forward the ComfyUI requirement? | orchestrator | Recorded in §3 and board issue #166; a future generation spec must cite it. | Decided; unchanged |
| OQ-6 | What authorizes future HTTP destinations and token transmission? | user / future design owner | No endpoint authority chosen. Decide endpoints, tokens/authentication, redirects, redaction, and offline tests before shipping a backend. SSH registration is not authorization. | Open; E1 remains deferred |
