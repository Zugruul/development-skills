# Generic multi-machine compute registry + peer-review — design proposal

Status: SUPERSEDED by [compute-registry-plan-v2.md](compute-registry-plan-v2.md) — kept for
history. v1 was reviewed by a Fable 5 agent (two passes) which found real contradictions
(dispatch bypasses the token gate; heartbeat-supplied `endpoint` is a redirect vector;
HTTP-vs-HTTPS unstated) and a scope concern (this is two specs, not one). v2 resolves those.
Date: 2026-07-15.

## 1. Origin / motivation

Started from a narrower ask: a `/peer-review` skill that spawns an OpenAI Codex CLI
(`codex exec`) agent to review the current diff as an independent, cross-vendor second
opinion (Claude reviewing its own diff shares Claude's own blind spots; a differently
trained model doesn't). Mid-design, the ask widened: the user is adding more machines to
their local network for extra processing power —

- a notebook running **llama.cpp** (`llama-server`, OpenAI-compatible HTTP API) — being set
  up right now, in parallel with this design
- a workstation running **ComfyUI** for image/video/3D generation

— and wants `/peer-review` (and future skills) to draw on *any* of these interchangeably,
with the ability to add more machines over time without rewriting skills. That reframes the
task: build a generic **compute registry + adapter** layer first, with `/peer-review` as its
first consumer, rather than a codex-specific skill.

No existing GitHub Project board issue covers this (board searched across all statuses,
`docs/BACKLOG.md`, `docs/BACKLOG-MEM.md` — no match). This is fresh scope.

## 2. Original `/peer-review` design (still valid as the first consumer)

- New skill, read-only reviewer. Never edits files (`codex exec --sandbox read-only` — this
  is the default sandbox and non-negotiable here regardless of which backend serves the
  request).
- Scope: diff between current branch and the repo's main branch by default
  (`git diff <mainBranch>...HEAD`), overridable via `--base <ref>`, `--staged`, or a PR
  number via `gh pr diff`. Diff text is embedded directly in the prompt (matches OpenAI's
  own Codex-SDK code-review cookbook pattern), not just file paths — the backend also has
  read access to the rest of the repo for context (callers, tests) if it needs it.
- Findings requested in a structured shape mirroring this session's own `ReportFindings`
  tool (file, line, severity, summary, failure scenario, overall verdict) so results render
  identically regardless of source.
- **Known rough edge** (confirmed via `openai/codex` GitHub issues): `codex exec
  --output-schema` output is occasionally malformed when the model emits intermediate
  messages before its final answer. Must have a fallback: if the JSON doesn't parse/validate,
  fall back to showing the raw text verbatim rather than crashing.
- No auto-fix by default — consistent with this repo's `/code-review` (`--fix` is opt-in).
  Findings are always labeled with *which* provider produced them (e.g. "External review —
  codex-local"), never silently merged into Claude's own judgment.
- Preflight: `command -v codex` missing → fail loud with install instructions, don't proceed.
  Auth failure → surface the backend's own stderr, never prompt the user to paste an API key
  into the conversation (auth is `codex login`, done once, out of band).

## 3. Generalized architecture: registry + adapters

### 3.1 The registry file — `.claude/compute-registry.yaml`

Durable, git-tracked, hand-authored — same role as `.claude/project.yaml`. Declares what
*should* exist, how to reach it, and (critically) a **capability ceiling** per provider —
see §3.3.

```yaml
schemaVersion: 1
registry:
  endpoint: http://192.168.1.50:8765   # the registry service's LAN address

providers:
  - id: codex-local
    kind: cli-agent
    transport: local-exec
    command: codex exec
    capabilities: [code-review, text]      # ceiling
    auth: local                            # already `codex login`'d on this machine

  - id: notebook-llama
    kind: llm-inference
    transport: http-openai-compatible
    endpoint: http://192.168.1.42:8080/v1
    capabilities: [chat, text-completion, code-review]   # ceiling
    token: ${LLAMA_NOTEBOOK_TOKEN}          # env var reference, never inline

  - id: workstation-comfyui
    kind: image-gen
    transport: comfyui-http
    endpoint: http://192.168.1.77:8188
    capabilities: [image, video, 3d]        # ceiling
    token: ${COMFYUI_TOKEN}
```

This file does **not** track live availability — that's the registry service's job (§3.2).

### 3.2 Self-registration — a small local registry service + heartbeat agent

- `compute-registry serve` runs a lightweight local HTTP service on one always-on box (same
  pattern this repo already uses for `neural-view`'s local server).
- Each remote machine runs a heartbeat agent (`registry-agent.py`) that POSTs its live status
  periodically to the registry service.
- Live state (online/offline, current capabilities, provisions) is kept in a **gitignored
  local cache** (e.g. `state/registry.json`), separate from the committed YAML — same
  separation this repo already uses elsewhere (board-queue, neural-view state) between
  durable config and local runtime state.
- A provider whose heartbeat goes stale past its TTL drops to `offline` automatically.

**Security constraint, from day one:** the service only accepts heartbeats from `id`s
already declared in `compute-registry.yaml`, authenticated by that provider's token — this
is allowlist confirmation, not open registration. Otherwise anything on the LAN could
register itself as a compute provider and receive dispatched jobs (this matters especially
for the ComfyUI adapter, where a workflow graph is effectively code execution). Bind the
service to the LAN interface only; never expose it to the internet.

### 3.3 Capability model — ceiling (declared) ∩ live subset (self-reported)

Two layers, deliberately not "the machine claims whatever it wants":

1. **Ceiling** — declared once by the human via `/compute-registry add`, written into
   `compute-registry.yaml`. The maximum capabilities a provider is ever authorized to claim.
2. **Live subset** — each heartbeat, the agent actually probes what's currently true locally
   (e.g. `llama-server`'s own `/v1/models` to see which model is loaded right now; ComfyUI's
   own `/object_info` to see which checkpoints/nodes are installed) and reports that.

The registry service intersects reported capabilities with the provider's ceiling on every
heartbeat — anything claimed outside the ceiling is dropped and logged as a warning, never
trusted. Only the intersection is ever offered to a consumer skill.

Heartbeat payload shape:
```json
{
  "id": "notebook-llama",
  "capabilities": ["chat", "code-review"],
  "provisions": {"model": "qwen2.5-coder-32b-q4", "vram_free_gb": 6.2, "queue_depth": 0},
  "endpoint": "http://192.168.1.42:8080/v1",
  "ts": 1234567890
}
```

### 3.4 Adapters — one per backend *shape*, not per skill

| Adapter | Talks to | Job shape |
|---|---|---|
| `cli-agent` | local subprocess (`codex exec`, future local CLIs) | run command, read stdout / last-message file |
| `http-openai-compatible` | `llama.cpp`'s `llama-server` (or anything OpenAI-compatible) | POST `/v1/chat/completions`, read response |
| `comfyui-http` | ComfyUI's `/prompt` API | POST workflow JSON, poll `/history`, fetch artifact via `/view` |

Each adapter exposes the same three operations: `health()`, `submit(job)`,
`collect(job_id) -> result`. Skills ask the registry for "a provider with capability X" and
get back whichever's alive; they never call a specific backend directly. `/peer-review`
becomes the first consumer of this layer, not a codex-specific skill. Future skills
(`/generate-image`, `/generate-video`, general LLM task offload) reuse the same layer.

### 3.5 Dispatch selection

Consumer asks: "who is `online` (heartbeat within TTL) AND `enabled` AND currently
advertising capability X?" → candidate list → preference order (e.g. prefer local `codex`
first, else lowest `queue_depth`, else declared order) → dispatch through that provider's
adapter.

## 4. Cross-platform setup (Windows / Linux / macOS mix)

Provider machines are not guaranteed to run Claude Code or even have bash (a Windows
ComfyUI box without WSL, for instance). Requiring WSL/Git Bash just to run a heartbeat
script is unnecessary friction, so:

- **Registry service + heartbeat agent → Python 3, stdlib only** (no pip deps — "have
  Python, run script"). Matches existing precedent in this repo (`brain.py`,
  `neural-view.py` are already Python for the same cross-platform reason).
- **Claude Code-facing skills stay bash wrappers**, same as every other skill in this repo —
  they shell out to the Python core. Only matters on whichever machine actually runs Claude
  Code (typically just the orchestrator).

| Machine role | What's installed | Persistence | Notes |
|---|---|---|---|
| Orchestrator (this Mac) | `compute-registry serve` (Python), Claude Code skills | launchd (optional) | owns the durable YAML + live-state cache |
| llama.cpp notebook (Linux or Windows) | `llama-server`, `registry-agent.py`, Python 3 | systemd unit (Linux) / Scheduled Task (Windows) | `llama-server` must bind to the LAN interface (`--host 0.0.0.0`), default is localhost-only |
| ComfyUI workstation (commonly Windows, GPU box) | ComfyUI (`--listen 0.0.0.0`), `registry-agent.py`, Python 3 | Scheduled Task | ComfyUI also defaults to localhost-only |

**Windows specifically:** skip Windows Services (needs NSSM or admin-heavy `sc create`); a
Scheduled Task set to run at logon needs no extra tooling on a stock install.

Gotchas to decide now, not discover later:
1. **Bind address** — both `llama-server` and ComfyUI default to localhost-only; opening
   them to the LAN also means they have no auth of their own — the registry's token-gated
   dispatch must be the real access control, and both ports should stay firewalled to
   LAN-only, never port-forwarded to the internet.
2. **Discovery** — a static IP (or reserved DHCP lease) per machine in
   `compute-registry.yaml` is simpler and more reliable on a home LAN than mDNS/`.local`
   hostnames (Windows mDNS support is inconsistent without Bonjour).
3. **Secrets on Windows** — no systemd-style `EnvironmentFile`; the Python agent should read
   a local `.env` file next to itself (hand-rolled parser, no dependency) so secret handling
   is identical across all three OSes.
4. **`/compute-registry add` should generate the remote install bundle** — after the
   interview (id, OS, endpoint), it prints/writes the exact copy-pasteable steps for *that*
   machine: the agent script, the right service template (systemd/launchd/Scheduled Task),
   and the one-line run command with id+token filled in. Otherwise "how do I set this up on
   machine #3" becomes a repeated manual translation exercise.

## 5. `compute-registry` admin skill (orchestrator side)

Following this repo's existing convention — one skill per feature area wrapping
subcommands via a script (see `spec-workflow:board`, `brain`, `auto-merge`, `ui-mode`,
`concurrency`) — rather than a separate skill per verb:

```
/compute-registry status              # view: every declared provider, live/offline, capabilities, last heartbeat, current load
/compute-registry add                 # administer: interview — id, kind, endpoint, capabilities (ceiling), token; writes compute-registry.yaml; emits remote install bundle
/compute-registry remove <id>         # administer: delete a provider entry + its cached state
/compute-registry enable <id>
/compute-registry disable <id>        # toggle without deleting — e.g. "comfyui box is being rebuilt this weekend"
/compute-registry serve [start|stop|status]   # the local registry HTTP service itself (same shape as neural-view's serve)
/compute-registry ping <id>           # on-demand health check of one provider, no job dispatched, bypasses heartbeat-interval staleness
/compute-registry token rotate <id>   # rotate the shared auth secret; never echoed to chat, written to local .env
/compute-registry doctor              # diagnose common misconfig: service not running, provider declared but no token set, port unreachable, stale heartbeat past TTL
/compute-registry logs [<id>]         # tail recent dispatch/heartbeat activity — "why didn't my job go to X"
```

On the provider machine side, registration is **not** a Claude Code skill (that machine may
not run Claude Code at all) — it's the plain `registry-agent.py` script plus an OS service
template from the install bundle. If a provider machine *does* also run Claude Code, an
optional thin wrapper (`/compute-registry agent start|stop|status`) could shell out to the
same script, but it's sugar, not a requirement.

## 6. Open items for the craft-spec interview

- Plugin placement: standalone `plugins/compute-registry/` (+ `plugins/peer-review/`
  consuming it) vs. folded into `spec-workflow`. Leaning standalone since neither has a
  board/task dependency.
- Default `/peer-review` scope: branch-vs-main diff (assumed default) vs. requiring an
  explicit `--base`/PR arg every time.
- `/peer-review` v1: plain relay of external findings vs. also adding an adversarial
  self-check pass on top (Claude sanity-checks each externally-reported finding before
  presenting it).
- Whether provisioning the remote heartbeat agent should itself be a skill
  (`/compute-registry install-agent <target>` that SSHes it into place) or stays a documented
  manual step for v1.
- Heartbeat interval / staleness TTL defaults.
- Exact capability vocabulary (controlled list, not free text) — starting set proposed:
  `code-review`, `text`, `chat`, `text-completion`, `image`, `video`, `3d`.
