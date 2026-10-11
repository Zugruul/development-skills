# Design - ast/E7: Restricted remote compute (WSL/ComfyUI)

Grounded in SPEC-ASSISTANT.md sections 5a, 11, 12, 14, and 17; #347 owner
triage selects storm590x/WSL, superseding native Windows setup. AST-080 carries
the naming/target correction as a spec delta. Existing remote-compute controller
commands remain a separate, trusted human development surface.

## Components

- `assistant/remote_control.py`: restricted SSH client, local provisioning check,
  and explicit data-only skill installation; engine code stays in the plugin.
- `assistant/remote_control_server.py`: target forced-command entry point;
  validates a bounded versioned request and maps it to fixed operations only.
- `skills/remote-compute-control/`: installable SKILL.md and capability manifest
  template. Installation records the absolute plugin engine path in check/invoke
  argv; it does not copy Python code or enable the capability.
- Existing capability index/adapters/task queue: enablement, schema validation,
  argv invocation, availability, and async lifecycle, unchanged for legacy skills.
- Existing remote-compute registry and target compute-state helper: read-only
  registry interoperability and fixed catalog/status/cancel primitives, not the
  unrestricted controller transport or arbitrary shell recipes.
- AST-081 adds the ComfyUI tunnel/executor/reconciliation/artifact flow; AST-082
  integrates authoritative command events with existing trace retention/redaction;
  AST-083 verifies the end-to-end user experience after UI direction is resolved.

## Data Models

- Installed capability remains version 1. `provisioning.hosts` maps explicit
  nicknames to `{host, port, user, knownHosts, keys: {inspect, cancel}}`.
  Paths are absolute; keys are dedicated per operation class. Empty hosts deny all.
  This installed manifest is the policy authority, read for each invocation;
  no model parameter can supply a policy file, endpoint, key, or executable.
- Existing project provisioning overrides support check/TTL only. They do not
  override this host policy; documentation must say so. No widening of the
  existing generic override contract or dependence on the engine's cwd.
- A read-only registry import, if provided, copies only an explicitly selected
  registered resource's literal ssh host/user/port into a proposed policy entry;
  it never treats registration alone as permission, imports broad SSH settings,
  changes registry contents, invents pins/keys, or installs/enables anything.
- Wire request: one versioned, ASCII-safe encoded JSON token. Exact schemas for
  inventory, status(job_id), logs(job_id), cancel(job_id); identifiers and payload
  sizes bounded. Unknown versions/fields/operations and shell/subsystem requests
  are refused. Outputs are bounded data, never instructions or artifact paths.

## Interfaces / Contracts

- Client invocation takes only nickname, operation, and optional job identifier,
  validated through the capability parameter schema and again at the boundary.
  Local `check` verifies policy/key/pin prerequisites, not live server enforcement.
  Missing policy never falls back to a normal SSH shell or default identity.
- POSIX OpenSSH client uses isolated configuration (`-F /dev/null`), explicit
  dedicated identity, no agent/default certificate fallback, key authentication
  only, strict pinned host verification, no supplemental known-hosts commands or
  trust files, no PTY, no forwarding, no control-master reuse, and finite timeout.
  Host/user/port/path option boundaries are validated, including paths with spaces.
- Server class is a fixed admin-supplied argument in each key's authorized_keys
  forced command, never taken from the request. `inspect` permits inventory,
  status and bounded logs; `cancel` permits cancellation only. No shell, exec,
  install, launch, policy mutation, arbitrary file transfer, or subsystem API.
- Server deployment uses `restrict,command="... --class <class> ..."` with fixed
  absolute engine/helper/root paths. Document restrictive sshd/key setup, trusted
  admin-owned code/config and disabling alternative grants for these keys. The
  dispatcher does not claim to secure an unrestricted account/key or to sandbox
  other recipes. No live key/sshd changes occur as part of development tests.
- Reuse the trusted compute-state helper only with fixed allowlisted actions and
  validated request fields; never forward a client-selected helper action or
  executable. Log reads stay in the selected jobs root and reject path escapes,
  symlinks/nonregular files. Cancellation retains process-identity verification.

## Key Sequences

1. Human installs skill data into the assistant skills directory, preserving any
   existing installation unless an explicit safe update is requested. Human
   configures approved hosts, pins and dedicated keys, deploys restricted server
   keys, then separately enables the capability. No automatic network trust.
2. Invocation passes existing enablement/schema gates, loads current allowlist,
   selects the fixed class/key, builds literal SSH argv and sends one bounded
   request. The server independently checks class and schema before any effect.
   SSH failure/timeout/refusal is surfaced, never retried via broad credentials.
3. Future ComfyUI tasks use the same explicit trust authority but a separately
   designed tunnel/artifact class. No broad forwarding is enabled in AST-080 in
   anticipation of AST-081. Persist external IDs before recovery can resubmit;
   artifact destinations are constructed by the engine from its task ID.

## Decisions

- WSL-first POSIX control plane; no native PowerShell compute target.
- Separate restricted transport because the existing CLI intentionally executes
  trusted recipes through ordinary SSH configuration. Its semantics stay intact.
- Data-only installation with absolute engine argv avoids a new invoke flavor,
  trusted-context placeholder API, or accidental dependency on assistant cwd.
- Forced commands are the remote-key boundary; client-side quoting alone is not.
- Deterministic fixtures cover allowed operations and adversarial refusals. Local
  OpenSSH configuration expansion verifies actual option parsing; an isolated
  ephemeral sshd integration may be used when available. Never claim live host
  enforcement based on local policy checks or mocked SSH alone.

## Out of Scope

Native Windows SSH installation, autonomous key/host enrollment, OS sandboxing
of existing recipes, arbitrary remote shell, CI/pipeline setup, paid APIs, new
remote-compute CLI roles, and UI redesign are outside AST-080. ComfyUI execution,
audit persistence and chat-to-artifact E2E remain the separately sequenced tasks.
