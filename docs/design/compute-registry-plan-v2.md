# Generic multi-machine compute registry + peer-review — design proposal (v2)

Status: SUPERSEDED by [compute-registry-plan-v3.md](compute-registry-plan-v3.md) — kept for
history. A Fable 5 agent explicitly briefed to hunt for overengineering found that Spec B
below, despite fixing v1's contradictions, still built a two-daemon distributed system
(persistent service, heartbeat protocol, TTL staleness, capability-intersection model, async
job adapter) to solve what amounts to "curl an HTTP endpoint on the LAN with a timeout." v3
guts Spec B down to that. Spec A (`/peer-review`) was unaffected and carries forward as-is.
Date: 2026-07-15.

## 0. What changed from v1, and why

v1 bundled a small, shippable skill with a multi-week infra project and asserted a security
model ("the token gate is the real access control") that didn't match the actual dataflow
(adapters dispatch straight to provider endpoints; the registry never sees the job). Two
independent review passes converged on the same core fixes:

1. **Split into two specs.** `/peer-review` needs no registry at all — ship it now. The
   registry is a separate, much larger effort with `/peer-review` as its first migration
   target, not its origin story.
2. **Fix the dispatch-auth contradiction** — see §3.4.
3. **Fix the heartbeat-endpoint trust bug** — see §3.3.
4. **State the threat model explicitly** instead of implying "secure" — see §3.2.
5. **Cut scope for registry v1**: 2 providers max, text/chat/code-review capability only.
   ComfyUI/image-gen is deliberately deferred to its own spec — see §3.6 and §5.
6. Explicitly record what was considered and rejected (Consul/etcd, Tailscale) so the next
   reviewer doesn't re-litigate it — see §3.7.

This doc is about to go to another Fable 5 review pass, this one explicitly briefed to push
back on overengineering — favor the boring, minimal thing that works over the general thing
that's impressive. If a piece below feels like infrastructure for infrastructure's sake, flag
it for cutting.

---

## Spec A — `/peer-review` (ship this first, standalone, no registry dependency)

Unchanged from v1's design, deliberately independent of everything in Spec B below:

- New skill, read-only reviewer. Never edits files (`codex exec --sandbox read-only` — the
  default sandbox, non-negotiable).
- Hardcoded to local `codex exec` for v1. No registry, no adapters, no network. If Spec B
  ships later, `/peer-review` can gain a second backend as a follow-up change, not a
  prerequisite.
- Scope: diff between current branch and the repo's main branch by default
  (`git diff <mainBranch>...HEAD`), overridable via `--base <ref>`, `--staged`, or a PR
  number via `gh pr diff`. Diff text is embedded directly in the prompt (matches OpenAI's own
  Codex-SDK code-review cookbook pattern); the backend also has read access to the rest of
  the repo for context since it runs locally with `codex exec`'s own file-read tools.
- Findings requested in a structured shape mirroring this session's own `ReportFindings` tool
  (file, line, severity, summary, failure scenario, overall verdict).
- **Known rough edge** (confirmed via `openai/codex` GitHub issues): `--output-schema` output
  is occasionally malformed when the model emits intermediate messages before its final
  answer. Fallback: if the JSON doesn't parse/validate, show the raw text verbatim instead of
  crashing.
- No auto-fix by default — consistent with this repo's `/code-review` (`--fix` is opt-in).
  Findings labeled "External review — codex", never silently merged into Claude's own
  judgment.
- Preflight: `command -v codex` missing → fail loud with install instructions. Auth failure →
  surface the backend's own stderr; never prompt the user to paste an API key into the
  conversation (auth is `codex login`, done once, out of band).
- One explicit disclosure worth a line in the actual spec: reviewing a diff via `codex exec`
  sends that diff to OpenAI's cloud. Fine for this repo (public-ish, no secrets in diffs by
  convention), but the skill's own doc should say so rather than leave it implicit.

**This spec alone is craft-spec-ready as-is.** Nothing below blocks it.

---

## Spec B — compute registry (separate spec, scoped down hard for v1)

### 3.1 v1 scope cap

Two providers max: `codex-local` (already covered by Spec A, unchanged) and one HTTP-based
LLM provider (the llama.cpp notebook). Capability vocabulary limited to `chat`,
`text-completion`, `code-review` for v1. **ComfyUI/image/video/3D generation is explicitly
out of scope for v1** — see §3.6 for why and what has to be true before it's in scope. No
dispatch-preference logic beyond "one declared provider per capability" — if two providers
ever offer the same capability, that's a v2 problem, not v1's.

Rationale: the registry's actual job in v1 is proving the model (declare → heartbeat →
dispatch → collect) end to end on the lowest-risk backend. Generality across N providers and
M capabilities is not needed to prove that, and building it now is speculative.

### 3.2 Threat model (stated explicitly — v1 did not do this)

**Trusted home LAN.** This system defends against: accidental cross-talk (a typo'd endpoint
hitting the wrong box), an unauthorized process on the LAN registering itself as a fake
provider, and casual discovery. It does **not** defend against: a hostile actor already on
the LAN with packet-capture ability, or a compromised device actively attacking the registry
protocol. Given that, plain HTTP (not HTTPS/mTLS) is an *accepted* v1 tradeoff, not an
oversight — the token still gates registration, and diffs sent to the local llama.cpp
notebook stay on-LAN either way. If the LAN trust boundary ever changes (unmanaged devices,
guests on the same network, cloud-hosted providers), HTTPS becomes a hard requirement, not
optional — flag this trigger explicitly in the spec so it's not silently forgotten.

Explicitly **rejected for v1** (not because they're wrong, but because they're more than this
scope needs): mTLS with a private CA, Tailscale/WireGuard as the trust layer. Both are the
"more correct" answer for a system with untrusted networks or many more machines; for 2
boxes on one home LAN, they're overhead that doesn't pay for itself yet. Revisit if the
network stops being a single trusted LAN (see previous paragraph).

### 3.3 The registry file — `.claude/compute-registry.yaml`

Durable, git-tracked, hand-authored — same role as `.claude/project.yaml`.

```yaml
schemaVersion: 1
registry:
  endpoint: http://192.168.1.50:8765   # the registry service's LAN address — this machine
                                        # is the single source of truth for BOTH the durable
                                        # YAML and the live-state cache (see 3.4); no split
                                        # between "orchestrator" and "registry host" in v1

providers:
  - id: codex-local
    kind: cli-agent
    transport: local-exec
    command: codex exec
    capabilities: [code-review, text]      # ceiling
    auth: local

  - id: notebook-llama
    kind: llm-inference
    transport: http-openai-compatible
    endpoint: http://192.168.1.42:8080/v1  # AUTHORITATIVE — never overwritten by a heartbeat,
                                            # see the fix in 3.4
    capabilities: [chat, text-completion, code-review]   # ceiling
    token: ${LLAMA_NOTEBOOK_TOKEN}          # env var reference, never inline
```

**Fix from v1 review:** the registry service and the orchestrator are the same machine in
v1. This removes the ambiguity two reviewers flagged (is `state/registry.json` local to
which box, does a consumer read a file or query HTTP). Splitting them is a valid future
optimization (e.g. running the registry on a box that's more reliably always-on than a
laptop) but adds a real question — file vs. HTTP read path — that v1 doesn't need to answer.

### 3.4 Self-registration — heartbeat agent, with the trust fix applied

- `compute-registry serve` runs the local HTTP service (same pattern as `neural-view`'s local
  server).
- The llama.cpp notebook runs a heartbeat agent (`registry-agent.py`) that POSTs its live
  status periodically.
- Live state kept in a gitignored local cache (`state/registry.json`), separate from the
  committed YAML.
- Stale heartbeat past TTL → provider drops to `offline` automatically.

**Fix — heartbeat-endpoint trust (v1 bug):** the heartbeat payload does **not** include
`endpoint`. The registry always dispatches to the endpoint declared in
`compute-registry.yaml`, never to anything a heartbeat claims. A leaked token can get a
provider marked online/offline or its capabilities intersected down — it can never redirect
where jobs actually go. Heartbeat payload, endpoint removed:
```json
{
  "id": "notebook-llama",
  "capabilities": ["chat", "code-review"],
  "provisions": {"model": "qwen2.5-coder-32b-q4", "vram_free_gb": 6.2, "queue_depth": 0},
  "ts": 1234567890
}
```

**Security constraint, unchanged from v1:** the service only accepts heartbeats from `id`s
already declared in the YAML, authenticated by that provider's token — allowlist
confirmation, not open registration. Bind to the LAN interface only, never the internet.

### 3.5 Capability model — ceiling ∩ live subset (unchanged, both reviews called this sound)

1. **Ceiling** — declared once via `/compute-registry add`, written to the YAML. Maximum
   capabilities a provider is ever authorized to claim.
2. **Live subset** — each heartbeat, the agent probes what's actually true locally (e.g.
   `llama-server`'s own `/v1/models`) and reports that.

The registry intersects reported capabilities with the ceiling on every heartbeat; anything
outside the ceiling is dropped and logged, never trusted. Only the intersection is offered to
a consumer.

### 3.6 Adapter — one for v1 (`http-openai-compatible`), with the interface both reviews said was missing

v1 ships exactly one adapter: `http-openai-compatible`, talking to `llama-server`'s
OpenAI-compatible `/v1/chat/completions` endpoint. The `cli-agent` "adapter" is really just
Spec A's existing local `codex exec` call, unchanged — it does not need to conform to this
interface in v1 (no dispatch-through-registry for the local case yet; that's a real
follow-up, not done here to avoid touching working code speculatively).

Interface, revised to include what both reviews flagged as missing (cancel + timeout — cheap
to add now, expensive to retrofit into every future adapter):
```
health() -> bool
submit(job, timeout_s) -> job_id      # timeout is required, not optional
collect(job_id) -> result | pending | failed
cancel(job_id) -> bool
```

**Deliberately not building yet, and saying so instead of silently omitting it:** a
generic "ask the registry for capability X, get back whichever provider" dispatch-selection
layer. With exactly one HTTP provider in v1, "ask the registry" and "call
`http-openai-compatible` against `notebook-llama`" are the same operation. Building a
selection/preference-ordering layer for a fleet of one is exactly the kind of
premature-generality the next review pass should be checking for — add it when there's a
second provider offering the same capability, not before.

**Job-shape honesty:** `code-review` via `codex-local` (full repo read access) and
`code-review` via `notebook-llama` (prompt-text only, no repo access) are not the same job
in practice — the remote one is closer to "ask an LLM to critique this diff text" than "let
an agent investigate the change." The spec should not claim these are interchangeable; label
results by provider (already planned in Spec A) so this difference is visible, not hidden
behind a common capability name.

### 3.7 ComfyUI — explicitly out of scope for v1, requirements before it's in scope

Not building the `comfyui-http` adapter in v1. Reasons: a ComfyUI workflow graph is
effectively arbitrary Python execution, and neither review pass found the token-gating
sufficient mitigation for that (gates *who* can submit, not *what* an accepted workflow can
do). Before an image/video/3D-gen spec is written, it needs an explicit answer to: **only
pre-authored, repo-committed workflow templates are ever dispatched — no dynamically
constructed graphs from free text, ever.** That's a hard requirement for that future spec,
recorded here so it isn't rediscovered mid-review next time either.

### 3.8 Rejected alternatives (recorded so they aren't re-litigated)

- **Consul/etcd for service discovery** — the heartbeat+TTL+capability-reporting shape this
  registry needs is a subset of what these already do well. Rejected for v1: another daemon
  to run and understand, and "capability" isn't a first-class concept in either (would be
  modeled as tags, an abuse of the model). For 2 machines, the win doesn't cover the added
  moving part. Revisit if the provider count grows past what a single hand-rolled service
  comfortably tracks.
- **Tailscale/WireGuard as the trust layer** — see §3.2; deferred with the LAN threat model,
  not rejected outright.
- **mTLS with a private CA** — same as above, deferred with the threat model.
- **Splitting registry-service host from orchestrator** — deferred, see §3.3; adds a
  file-vs-HTTP read-path question v1 doesn't need to answer yet.
- **A generic dispatch-selection/preference-ordering layer** — deferred, see §3.6; premature
  with one provider per capability.

### 3.9 Cross-platform setup (kept from v1, with two gaps the review found now covered)

- **Registry service + heartbeat agent → Python 3, stdlib-only-by-default.** One named
  exception allowed if it becomes annoying in practice: a real, near-zero-dependency package
  (e.g. `python-dotenv`) instead of a hand-rolled `.env` parser — not a hard stdlib-purity
  rule, a default that can bend once, not a growing dependency list.
- **Claude Code-facing skills stay bash wrappers**, shelling out to the Python core — only
  matters on the machine actually running Claude Code (the orchestrator).

| Machine role | What's installed | Persistence | Notes |
|---|---|---|---|
| Orchestrator + registry host (this Mac) | `compute-registry serve` (Python), Claude Code skills | launchd (optional) | single machine in v1 — see §3.3 |
| llama.cpp notebook (Linux or Windows) | `llama-server`, `registry-agent.py`, Python 3 | systemd unit (Linux) / Scheduled Task (Windows) | `llama-server` must bind to the LAN interface (`--host 0.0.0.0`), default is localhost-only |

**Windows gaps found by review, now covered:**
1. Stock Windows has no Python 3 preinstalled — the install bundle must include installing it
   (and note the `python` vs `py` launcher inconsistency), not assume it's present.
2. Windows Defender Firewall blocks inbound connections by default — the install bundle must
   *add* an inbound LAN-scope allow rule for the agent's port, not just tell the user to "keep
   it firewalled" (that direction was backwards in v1 — the concern there was outbound
   internet exposure, but inbound-LAN needs an explicit allow, not a block).

Other gotchas, unchanged from v1: static IP per machine in the YAML (simpler than mDNS on a
home LAN, especially given Windows' inconsistent Bonjour support); `/compute-registry add`
generates the remote install bundle (agent script + right service template + one-line run
command with id+token filled in) so setting up machine #2 is copy-paste, not re-derivation.

## 4. `compute-registry` admin skill (v1 subcommand set, trimmed)

Same "one skill, many subcommands" convention as `spec-workflow:board`/`brain`/`auto-merge`.
Trimmed from v1's list to what a 2-provider, 1-adapter v1 actually needs — `logs` and `doctor`
kept because both reviews independently flagged this class of setup (multi-machine, tokens,
network reachability) as failing in boring, hard-to-diagnose ways:

```
/compute-registry status              # every declared provider, live/offline, capabilities, last heartbeat
/compute-registry add                 # interview — id, endpoint, capabilities (ceiling), token; writes YAML; emits remote install bundle
/compute-registry remove <id>
/compute-registry enable <id> / disable <id>   # toggle without deleting
/compute-registry serve [start|stop|status]
/compute-registry ping <id>           # on-demand health check, bypasses heartbeat-interval staleness
/compute-registry doctor              # service not running / no token set / port unreachable / stale heartbeat
/compute-registry logs [<id>]
```

**Cut from v1's list, deliberately:** `token rotate` — v1 review noted this needs a
propagation step to the remote agent that wasn't designed (rotating the orchestrator's
`.env` alone bricks the provider). Rotating a token in v1 is: `remove` the provider, `add` it
again with a fresh token, re-run the install bundle on the remote box. Manual, but honest
about what actually has to happen — a `rotate` subcommand implying one-step rotation would be
lying about the real cost until the propagation mechanism is actually designed.

On the provider machine, registration is the plain `registry-agent.py` script + an OS service
template — not a Claude Code skill, since that machine may not run Claude Code at all.

## 5. Open items for the craft-spec interview

- Confirm the Spec A / Spec B split holds — i.e., craft-spec runs *twice*, not once.
- Plugin placement: standalone `plugins/peer-review/` and `plugins/compute-registry/` vs.
  folded into `spec-workflow`.
- Heartbeat interval / staleness TTL defaults for Spec B.
- Whether provisioning the remote agent should itself be a skill
  (`/compute-registry install-agent <target>` via SSH) or stays a manual step — v1 leans
  manual given the install-bundle already makes it copy-paste.
- The trigger condition in §3.2 (LAN trust boundary changes → HTTPS becomes mandatory) should
  become an explicit acceptance-criterion note in Spec B, not just prose here.
