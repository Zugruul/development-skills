# Compute resources — register machines, make them available to projects (v1)

Status: ACCEPTED — implementation started 2026-08-02. Companion issue: filed on the board
(remote-compute skill). This document is the reviewed, amended version of the
"neural-network compute resources" brief, reconciled against the repo's existing contracts.

## 1. Relationship to prior art (read this before extending)

Three prior tracks exist on paper; none in code. This design collides with none of them,
but the boundaries are deliberate and load-bearing:

- **`compute-registry-plan-v3.md`** (DRAFT, 2026-07-15) solved a *different problem*:
  synchronous HTTP dispatch to LAN LLM endpoints (llama-server). Its verdict — delete the
  registry service, heartbeat, capability-ceiling, async job adapters — stands for that
  problem and is honored here: this design has **no service, no daemon, no heartbeat, no
  TTL model, no selection layer**. What it keeps that v3 deleted (detached job state files,
  a cooperative lock) is kept only because the workload here is *hours-long detached
  training jobs over SSH*, which are async by nature — not because "room to grow back".
  v3's HTTP/LLM scope (peer spec E1, PRV-010..012, never seeded) remains a separate,
  unbuilt concern; if it is ever built it should read hosts from this registry rather than
  invent a second machine list.
- **`SPEC-ASSISTANT.md` §14 (E7, AST-080..083)** is the *assistant engine's* remote-compute
  capability layer: scoped SSH control plane, forced commands, ComfyUI tunnel, trace-event
  audit. This skill is the *human dev-workflow* layer — the human's orchestrator session
  operating machines the human owns, under the human's own key. It implements **none** of
  E7 and must not be cited as satisfying any §14 requirement. Planned convergence point:
  E7's §14.4 host allowlist MAY later be sourced from this registry (one machine list, two
  consumers). E7's job plane (§12.3/§12.4/§17.11, issue #507's resolver interplay) is where
  heavyweight job orchestration belongs; `dispatch` here stays deliberately file-based and
  minimal.
- **`SPEC-PEER-REVIEW.md` §7** and the `peer` spec invariant in `.claude/project.yaml`
  (egress limited to endpoints in `.claude/compute-registry.yaml`) reference a file that
  has never existed. Nothing breaks today (the peer-review skill dispatches only to the
  local `codex` CLI). RECONCILIATION ITEM: when peer E1 is seeded, amend §7 via
  `docs/spec-deltas/` to either point at this registry or keep its own endpoint file —
  do not leave two "compute registry" vocabularies live at once.
- **CDX-050 (#194)** waits on "the compute-registry work landing a mergeable skill" — its
  trigger was written against issue #166 (a research-only spike) and is unsatisfiable as
  written. The skill shipped by THIS design is the natural retarget: once merged, CDX-050
  should sweep `remote-compute` for dual-host compliance.

## 2. Skill surface and naming

One verb-based skill named **`remote-compute`** — matching epic E7's own name ("Remote
compute") so the board, the spec, and the skill share one vocabulary (naming decision
2026-08-02; the earlier working names `compute-resource(s)` and `neural-network-compute`
were dropped). The short config surfaces keep the short word: the project.local.yaml key
stays `compute:` and the user registry stays `~/.claude/compute/`. Verb pattern matches
`board`/`brain`/`checkpoint`:

```
/remote-compute register <nickname> [user@host]
/remote-compute enable <nickname> [--role <role>] | disable <nickname>
/remote-compute list | status [<nickname>] | probe <nickname>
/remote-compute exec <nickname> -- <cmd...>
/remote-compute lock <nickname> [--reason ...] | unlock <nickname> [--force]
/remote-compute dispatch <nickname> --workdir <dir> --cmd <cmd> [--env <name>]
/remote-compute job-status <id> | job-logs <id> | job-pull <id>
/remote-compute remove <nickname>
```

The brief's original two-command shape (`/remote-compute-resource-register`,
`/remote-compute-resource-allocate`) was folded into verbs: two extra top-level
skills would duplicate 90% of their doc text, split the roster, and still need the
supporting verbs somewhere. `register` and `enable` are the two headline verbs — and
`enable` (not "allocate") because the concept is AVAILABILITY, not allocation: telling
a project the resource exists and what it can do, capability-style (mirroring
`assistant.capabilities.<name>.enabled`), never granting exclusivity. Many projects may
enable the same machine; the machine-local cooperative lock serializes actual use.

Script surface (callable by other skills): `plugins/spec-workflow/scripts/remote-compute.py`
(all verbs above as argv, machine-readable line output, no interactivity — waiting/acking
is the calling agent's job, driven by SKILL.md).

## 3. Registration = convergence (consistent setup, every time)

`register` is **idempotent convergence to one declared end-state**, not a one-shot setup.
Running it on a new nickname sets the machine up; re-running it on an existing one
re-verifies everything and repairs drift. The end-state checklist (each item verified
live, never assumed):

1. `~/.ssh/config` has a `Host <nickname>` block (HostName/User; created or left intact).
2. Key auth works under `BatchMode=yes` (on failure: emit `NEEDS_KEY_AUTH` + the exact
   `ssh-copy-id user@host` line; the agent relays it, waits, re-runs register).
3. Host key present in `known_hosts` (fingerprint shown, human-acked before keyscan;
   recorded `hostKeyAccepted: keyscan|manual`).
4. Capability probe complete (GPU/VRAM/CUDA/driver, RAM, disks incl. DrvFs `slow` marks,
   default shell, configured envs verified by real imports) — every claim from real
   command output; per-step failures recorded verbatim as `{error: ...}`, never guessed.
5. Platform quirks recorded (WSL nvidia-smi path, zsh non-interactive PATH, icmpBlocked,
   macOS mps-not-cuda).
6. Remote job layout present: `~/.compute-jobs/` exists.
7. Power policy confirmed by the human (recorded `powerPolicyConfirmed`; the relevant
   per-platform instruction sheet is printed whenever a prerequisite check fails).

Registration is user-level only (`~/.claude/compute/resources.yaml`, machine-local, never
committed, never a repo file). It never touches any repo and never runs sudo — privileged
steps are printed for the human.

## 4. Availability (enable/disable) — via the machine-local overlay

`enable <nickname>` advertises a registered device to the current repo: re-probes live
(never from a stale snapshot), then rewrites the `compute:` section idempotently — in
**`.claude/project.local.yaml`**, a gitignored machine-local overlay, NOT the committed
`project.yaml`. Which machines a clone can reach is a property of the machine, not the
repository: committing availability would advertise one person's hardware to every clone.
`config.py load_config()` merges the overlay over the committed config for an explicit
allowlist of keys (`LOCAL_OVERLAY_KEYS`, today exactly `compute`); any other key in the
local file is deliberately ignored so a gitignored file can never silently override
committed configuration. A missing overlay file is the normal case, never an error.
The overlay path is registered in `local-state.manifest` (spec delta:
`docs/spec-deltas/524.md`).

The entry is a map keyed by alias (capability-style), non-exclusive; `disable` keeps the
entry with `enabled: false`, like a disabled capability. Only alias + informational
snapshot + roles are stored — no host, user, or secrets. Consumers MUST re-probe before
real dispatch; the snapshot is documentation, not truth.

```yaml
# .claude/project.local.yaml (gitignored)
compute:
    resources:
        gpubox:
            enabled: true
            roles: [training]
            probedAt: "2026-08-02T08:10:00Z"
            capabilities: {gpu: {...}, ramGB: 96, disks: [...], envs: [...]}
```

Config-surface cost (all landed with this design): `compute` property in
`project-config.schema.json` (every property described, per schema-lint; documents the
merged view), an optional strict block in `validate-config.py`, the overlay merge in
`config.py`, a `local-state.manifest` entry + README table row, no sync rule (the overlay
is per-machine — there is nothing to sync), no template entry (same precedent as
`work:`/`commit:`).

## 5. Registry descriptor (user registry, v1)

As in the brief (name/transport/ssh/platform+quirks/capabilities/envs/policy/state), with
`state.lock` = `{holder, reason, since}` or null. `~/.claude/compute/` layout:
`resources.yaml`, `jobs/<id>.json`. Overridable for tests and exotic setups via
`COMPUTE_HOME`, `COMPUTE_SSH_CONFIG`, `COMPUTE_SSH_BIN`/`COMPUTE_KEYSCAN_BIN`/
`COMPUTE_RSYNC_BIN` (the hermetic-test seam — a scripted fake transport).

## 6b. Layering — the engine never learns a domain

`scripts/remote-compute.py` is the generic engine (transport, registry, envs,
locks, jobs, dispatch). Domains live OUTSIDE it as bundles under
`scripts/remote-capabilities/<name>/`: a `capability.yaml`
(`{name, description, payload[], jobs{name: {description, cmd, params, env}}}`)
plus payload scripts. `install-capability` rsyncs payload to
`~/.compute-jobs/_caps/<name>/` and declares jobs as `<name>:<job>` through the
same machinery `add-job` uses; `{capdir}`/`{jobdir}` are the only engine-supplied
placeholders. Adding ComfyUI, a training rig, or an OCR service is a bundle, not
an engine edit — enforced by a test asserting the engine contains no
domain-specific code. This is also what keeps E7 alignment honest: a future
assistant-side capability can reuse a bundle without importing this engine.

## 6a. Declared jobs — dispatch by intent (capability-style)

`add-job` declares a NAMED job on a resource: `{description, workdir, cmd template,
env, params: {name: {pattern}}}` in the user registry. `jobs` lists the roster; `run`
validates every given param against its declared regex (default `[A-Za-z0-9._/-]+`),
substitutes values SHELL-QUOTED into the template (mirrors SPEC-ASSISTANT §11.5), runs
the sudo check on the rendered command, and dispatches through the same detached
machinery as `dispatch`. Unknown job / unknown param / missing param / pattern miss all
fail with exit 2 naming what IS declared — the honest-refusal shape of §11.8, so an
intent like "generate a 3d duck" either maps to a declared job or fails loudly; the
agent never improvises a raw command for an intent-level ask. ComfyUI carve-over
(v3 §3.6 / §14.2): a comfy job's template references a pre-authored API-format workflow
file; `scripts/remote-capabilities/comfyui/comfy-run.py` substitutes prompt text only, POSTs to the REMOTE loopback
(127.0.0.1 — never a LAN address), and pulls artifacts via /view into the job workdir.
Manual E2E: `tests/e2e-remote-compute-manual.sh` (network-touching, not in the gate).

## 6. Dispatch (minimal, file-recoverable)

`dispatch`: refuse if locked by someone else or payload contains sudo → take lock →
rsync inputs (`-az --partial`) → launch detached (`tmux new-session -d` else
`setsid nohup`), always via `bash -lc` with full paths, always writing `job.log`, `pid`,
`exitcode` under `~/.compute-jobs/<id>/` → record `~/.claude/compute/jobs/<id>.json`.
`job-status`/`job-logs`/`job-pull` recover from those files alone — no daemon, no
orchestrator state; killing the session loses nothing.

## 7. Hard rules (enforced in code where possible)

1. Key auth only; `BatchMode=yes` on every ssh invocation (transport hardcodes it);
   never prompt for, store, or transmit passwords.
2. Never run sudo, locally or remotely; sudo-containing remote payloads are rejected.
3. Probes are read-only; dispatch writes only in the declared workdir and `~/.compute-jobs/`.
4. Capability claims come from real probe output; failures recorded verbatim; never assumed.
5. No dispatch to a locked resource; `unlock --force` warns with prior holder context.
6. `~/.claude/compute/` and `.claude/project.local.yaml` are machine-local, never
   committed; they carry alias + snapshot only.
7. Health = TCP:22 (`nc -z`), never ping (Windows blocks ICMP; record `icmpBlocked`).

## 8. Per-platform setup sheets

Embedded in the skill and printed on prerequisite failure, exactly as in the brief:
Windows+WSL2 (mirrored networking, firewall rule, ext4-not-DrvFs, driver-on-Windows),
Linux (openssh-server, ufw, no-suspend), macOS (Remote Login, pmset, MPS/MLX probes).

## 9. Testing (hermetic gate)

`tests/section-remote-compute.sh`: probe parsers against captured fixtures (nvidia-smi, free,
df, system_profiler), registration convergence incl. NEEDS_KEY_AUTH stop/resume and
idempotent ssh-config alias, BatchMode-always asserted via fake-ssh argv capture, sudo
rejection, lock semantics, enable/disable writer idempotence on the overlay file (committed project.yaml
untouched), overlay merge + allowlist through config.py,
dispatch job-state recovery from files alone. No network in the gate; all remote calls go
through the scripted fake transport.
