# Generic multi-machine compute registry + peer-review — design proposal (v3)

Status: DRAFT — pre-craft-spec. Not yet on the board (no issue exists yet for this work).
Implementation not started. Supersedes
[compute-registry-plan-v2.md](compute-registry-plan-v2.md). Date: 2026-07-15.

## 0. What changed from v2, and why

v2 fixed v1's two real contradictions (dispatch bypassing the token gate, heartbeat-supplied
endpoint as a redirect vector) but a Fable 5 pass explicitly briefed to hunt for
overengineering pointed out that the fixes themselves had quietly hollowed out the heartbeat
service's purpose: once the endpoint only ever comes from the YAML and there's no
dispatch-selection layer (one provider per capability), the *only* information the entire
service+heartbeat+TTL apparatus still delivers is "is the notebook up right now?" — which a
synchronous health check at dispatch time answers just as well, more freshly, with one `curl`
instead of two daemons.

Verdict adopted here: **delete the registry service, the heartbeat agent, the
capability-ceiling/live-subset model, and the async job-adapter interface.** None of them
were paying for themselves at 2-machine, single-owner scale. What's left is a git-tracked
YAML, a status check, and a dispatch helper — described in full below. Nothing here is
"trimmed for v1 with room to grow back" — it's the actual shape of the problem at this scale.
If a second capability-sharing provider or a genuinely adversarial network shows up later,
that's a new design conversation with real evidence behind it, not a speculative buildout now.

Spec A (`/peer-review`) was never part of this critique and carries forward unchanged.

---

## Spec A — `/peer-review` (unchanged, ship first, standalone)

- New skill, read-only reviewer. Never edits files (`codex exec --sandbox read-only` — the
  default sandbox, non-negotiable).
- Hardcoded to local `codex exec`. No registry, no network, no dependency on Spec B.
- Scope: diff between current branch and the repo's main branch by default
  (`git diff <mainBranch>...HEAD`), overridable via `--base <ref>`, `--staged`, or a PR
  number via `gh pr diff`. Diff text embedded directly in the prompt; `codex exec` also has
  its own local file-read tools for repo context.
- Findings requested in a structured shape mirroring this session's own `ReportFindings` tool
  (file, line, severity, summary, failure scenario, overall verdict).
- **Known rough edge**: `--output-schema` output is occasionally malformed when the model
  emits intermediate messages before its final answer (confirmed via `openai/codex` GitHub
  issues) — fall back to showing raw text verbatim if the JSON doesn't parse, don't crash.
- No auto-fix by default, consistent with this repo's `/code-review` (`--fix` is opt-in).
  Findings labeled "External review — codex", never silently merged into Claude's own
  judgment.
- Preflight: `command -v codex` missing → fail loud with install instructions. Auth failure →
  surface the backend's own stderr, never prompt for an API key in-conversation.
- Disclosure the skill's own doc should state plainly: reviewing a diff via `codex exec`
  sends that diff to OpenAI's cloud.

**Craft-spec-ready as-is.**

---

## Spec B — remote LLM dispatch (gutted to match actual scale)

### 3.1 The whole system, in one sentence

A YAML file lists machines and how to reach them; a status command curls each one; a dispatch
helper curls the one you're using, with a timeout, and returns the text. That's it — no
service to start, no agent to install as a background process, no protocol beyond "HTTP
request with a bearer token."

### 3.2 The registry file — `.claude/compute-registry.yaml`

Durable, git-tracked, hand-edited directly (no admin interview flow needed for a file this
small — see §5).

```yaml
schemaVersion: 1
providers:
  - id: notebook-llama
    endpoint: http://192.168.1.42:8080/v1   # llama-server's OpenAI-compatible endpoint
    token: ${LLAMA_NOTEBOOK_TOKEN}           # env var reference, never inline
    capabilities: [chat, text-completion, code-review]
```

One provider in v1 (the llama.cpp notebook). `codex-local` is not in this file — Spec A calls
`codex exec` directly and has no reason to go through this layer.

### 3.3 Setup on the notebook — no agent, no persistence template

```bash
llama-server --host 0.0.0.0 --port 8080 --api-key "$LLAMA_NOTEBOOK_TOKEN"
```
Run it in a terminal, a `tmux` session, or however you'd normally keep a long-running process
alive on that machine — no bespoke registry-agent process, no systemd/launchd/Scheduled Task
template to author and maintain. Windows Defender's inbound-LAN allow rule for the port is
still a real one-time step (Windows blocks inbound by default), but it's the *only*
Windows-specific setup work — no Python-on-Windows requirement, since nothing custom runs on
that machine at all beyond `llama-server` itself.

### 3.4 Dispatch and status — two operations, both synchronous HTTP

```
GET  <endpoint>/models                          # status/health check — 200 = reachable
POST <endpoint>/chat/completions  (Authorization: Bearer <token>, timeout)
```

No `submit`/`collect`/`cancel` job-queue shape — llama.cpp's API is blocking
request/response, so the honest interface is one function: `review(diff_text, timeout_s) ->
text`. `/peer-review` (or any future skill) that wants to use this provider calls that
function directly against the one declared endpoint; there is no selection layer to write
because there's one provider to select from.

### 3.5 What was cut, and why it doesn't come back "later, if needed" by default

- **Registry service / heartbeat agent** — replaced by a synchronous health check at the
  moment of use, which is strictly more accurate than a heartbeat that can be stale by up to
  a TTL window, and requires nothing running when you're not using it.
- **Capability-ceiling ∩ live-subset model** — this defended against the provider machine
  lying to its own owner about what it offers. You wrote the YAML; if the model on the
  notebook changes, you edit the YAML line, the same action you'd take to update an endpoint.
- **Async adapter interface (submit/collect/cancel)** — imported an interface shaped for a
  fleet of heterogeneous batch backends onto a single synchronous HTTP API. There is no
  second adapter in scope to justify the shape.
- **Token rotation subcommand, `enable`/`disable`, `remove`** — all reduce to editing a
  ~10-line YAML file by hand. A subcommand that wraps "comment out a block" is not saving
  meaningful effort.
- **`registry.endpoint` top-level key, `schemaVersion` machinery beyond a literal 1, TTL /
  staleness tuning** — existed only in service of the deleted service.

### 3.6 ComfyUI — still explicitly out of scope

Unchanged reasoning from v2: a ComfyUI workflow graph is effectively arbitrary code
execution, and no mitigation lighter than "only ever dispatch pre-authored, repo-committed
workflow templates, never dynamically constructed graphs" was found sufficient. That
requirement carries forward to whatever future spec adds image/video/3D generation — it is
not weakened by this document's overall simplification; if anything, a same-shape "just curl
it" design for ComfyUI would be *wrong* given that risk, so ComfyUI is a deliberately
different, heavier future spec, not a drop-in third provider in this one.

## 4. `compute-registry` skill — trimmed to what's actually used day-to-day

```
/compute-registry status              # read the YAML, GET /models on each provider, report reachable/unreachable + why
/compute-registry add                 # short interview (id, endpoint, capabilities), appends the YAML block, prints the exact llama-server launch command for the target machine
```

Everything else from v2's list (`remove`, `enable`, `disable`, `serve`, `ping`, `doctor`,
`logs`, `token rotate`) is a hand-edit to the YAML or subsumed into `status` once there's no
service to operate or debug. `add`'s install-bundle idea survives in trimmed form — printing
the one-line `llama-server` command with the token filled in is still worth automating, since
it's the one step someone would otherwise have to reconstruct by hand.

## 5. Open items for the craft-spec interview

- Confirm Spec A and Spec B still run through craft-spec separately, or whether Spec B is now
  small enough to fold as a follow-up task inside Spec A's spec instead of a spec of its own
  — worth asking explicitly given how much smaller Spec B has become.
- Default request timeout for the dispatch call.
- Whether `/compute-registry add`'s interview is worth a skill at all versus just documenting
  "here's the YAML shape, copy this block" — it's a genuinely close call now that the file is
  this small.
- Confirm the ComfyUI hard requirement (§3.6) gets carried into that future spec's seed
  context when it's eventually written, so it isn't rediscovered again.
