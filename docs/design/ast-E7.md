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

## AST-082: Command Audit and Retention

Grounded in sections 10.1-10.3, 10.6-10.7, 12.3-12.4 and 14.3, plus the
owner's #349 clarification: success, refusal, failure, cancellation and artifact
transfer all require auditing; redact credentials and sensitive parameters before
persistence; pruning history must preserve active-job reconciliation metadata.

### Components and Authority

- An engine-owned remote audit boundary wraps each managed remote operation,
  including the existing restricted control skill. It is reusable by AST-081's
  submit/status/cancel/transfer operations, not a second transport or authority
  grant. Transfer coverage here tests this boundary; a real ComfyUI transfer is
  still AST-081 and cannot be called complete until it uses the boundary.
- The existing traces worker remains the only writer of traces.sqlite. Additive
  acknowledged writes may provide a bounded commit acknowledgement to background
  workers; ordinary emit callers retain their nonblocking legacy semantics.
- The task worker owns durable recovery state independently of traces. An audit
  context (assistant root, turn/task/correlation IDs, queue) is engine-created,
  never selected through model parameters, remote output or a manifest command.
- Existing named-capability enablement, schema validation and argv execution stay
  in force. Do not add a general shell, invoke flavor or context-placeholder API.
  Nonremote capabilities and the human remote-compute CLI retain their behavior.

### Audit Contract

- Each attempted managed operation has an engine-generated command ID and linked
  turn/task/span identifiers. Record intent before invoking its transport, then a
  terminal outcome distinguishing success, refusal, failure and cancellation (or
  pending/unknown cancellation when that is all the remote evidence supports).
  Validation/enablement/provisioning refusals also produce linked audit evidence.
- A worker must observe the intent's commit acknowledgement before remote effects.
  Queue overflow, writer failure or bounded acknowledgement timeout refuses the
  operation without using a broader credential or retrying the remote action.
  Chat threads only enqueue remote work and remain responsive.
- Audit persistence failure after an attempted effect is an uncertain outcome,
  never a reason to replay it. Surface a sanitized diagnostic and preserve the
  recovery identifiers already owned by the task. Crash windows and unavailable
  audit storage must be documented honestly, not reported as successful audit.
- Audit payloads are bounded, explicit structured operational metadata, not raw
  commands, environment/config snapshots, credential paths, workflow bodies,
  remote stdout/stderr, or exception strings. Unknown fields and sensitive
  parameters cannot become persistence fields just because they are JSON-safe.
  Construct/redact before enqueueing as well as before SQL persistence.
- Trace redaction cannot be defeated by a second copy in task payload/result/error
  or an adjacent generic skill event. Review the entire managed remote path and
  prevent these duplicate leaks. Preserve useful, nonsecret operation results and
  recovery IDs; do not solve redaction by silently disabling the capability.
- This contract covers engine-managed remote operations. Direct human diagnostic
  CLI calls and the separate human controller are not assistant trace producers;
  preserve their documented compatibility and name this distinction explicitly.

### Persistence and Verification

- Use existing age/size trace retention, including WAL checkpoint deferral. Audit
  events are prunable history, not a second recovery database or permanent log.
- Task ID, external job ID, ownership and the minimal nonsecret state needed for
  reconciliation remain in tasks.sqlite. Retention never prunes that state and
  reconciliation never requires an audit event still to exist. Existing tasks
  remain readable; no silent replay after pruning or restart.
- Tests drive the real engine/queue/writer boundary for successful commands,
  refusals, failures, timeout, cancellation and the future transfer wrapper.
  Prove commit-before-effect and no effect on audit-admission failure. Put secret
  sentinels in nested input, credentials, returned data and errors; inspect raw
  database/WAL bytes, not only redacted API output. Verify persisted nonsecret
  results remain usable and legacy capability behavior is unchanged.
- Deterministically prune audit rows by age and size while a task is active, then
  restart/reconcile from its durable IDs without resubmission. Include reader-held
  WAL contention and crash/incomplete-outcome coverage. No live target enrollment,
  paid provider calls, UI redesign or pipeline setup is part of these tests.

## AST-081: ComfyUI Rendering Lifecycle

Grounded in sections 11, 12, 14.2-14.4 and 17, and the owner clarification on
#348. AST-080's inspect/cancel grants and the human controller remain unchanged.
This extension implements the assistant job plane, not another machine registry.

### Components and Trust

- `assistant/comfyui_render.py` owns data-only installation, policy validation,
  task execution/reconciliation and artifact publication. Small sibling transport
  modules may separate bounded SSH/HTTP/WebSocket mechanics from this lifecycle.
  `skills/comfyui-render/` contains skill data, never a copied engine.
- Reuse the shipped ComfyUI API-workflow recipe format and the restricted SSH
  client's isolation rules. Existing bundles/importer supply pre-authored API
  workflows; no new registration, remote shell dispatcher or workflow generator.
  Human `comfy-run.py` invocation and existing capabilities remain compatible.
- Installed version-1 provisioning explicitly selects a host, pinned known-hosts
  file, dedicated tunnel key, loopback ComfyUI port and named workflow entries.
  Each workflow pins a local API JSON template by SHA-256, finite timeout,
  allowlisted typed literal inputs and one declared output selection. Unknown
  hosts/workflows/fields deny; model inputs cannot choose a path, graph, key,
  URL, executable, output destination or timeout. Reload authority for every
  remote operation; registration and check/TTL overrides grant no authority.
- The new key is tunnel-only: an administrator restricts its server-side grant
  to local forwarding to `127.0.0.1:<ComfyUI port>`, denies remote forwarding,
  PTY, agent/X11 forwarding, user rc and sessions/shell/subsystems. It is NOT an
  AST-080 inspect/cancel key. Document exact OpenSSH key AND sshd restrictions;
  a client check cannot certify those restrictions or the service's bind address.
  Scope session-denying sshd settings to a dedicated tunnel-only account or
  listener. Never apply `MaxSessions 0` to an existing shared login and thereby
  disable its human shell or AST-080 forced-command sessions.
- A tunnel grants access to the entire selected ComfyUI HTTP service. It is not
  a per-route authorization boundary or OS sandbox. The administrator must trust
  the service, custom nodes, templates and local account, keep ComfyUI bound only
  to loopback and protect controller-local loopback access. Do not advertise a
  forced-command restriction as restricting forwarded HTTP traffic.

### Interfaces and Durable State

- The enabled `comfyui-render` capability always queues managed background work,
  independent of casing or a changed `longRunning` flag. Version-1 schema/argv
  validation remains in force; a fixed plugin entry point handles the managed
  lifecycle. No model-selected executable or generic invoke flavor is added.
- Render inputs select host/workflow and bounded values. Cancellation selects
  an existing task in the SAME assistant, never an arbitrary backend prompt ID.
  Installation is data-only, refuses an existing destination, preserves venv
  interpreter identity, rejects literal binding braces and never auto-enables.
- Only allowlisted scalar values replace EXISTING literal workflow inputs, with
  exact type/range/length checks; links, node classes, connections and output
  paths cannot change. Check actual `/object_info` node/input/model availability
  before submission and return bounded actionable dependency identifiers, not
  raw node errors, workflow contents or server exception text.
- Reuse tasks.sqlite and its single writer/ownership guards. Additive recovery
  metadata may carry only validated engine-owned request UUID, backend prompt ID,
  deadline, endpoint/policy binding and submission phase. Persist the stable
  request identity BEFORE POST; persist a returned prompt ID before acknowledging
  submission. Neither traces nor remote marker paths are recovery authority.
- Use an opt-in deferred executor result for this task kind: a submitted job stays
  in progress and the existing periodic resolver advances it. Bounded polling
  releases the worker so another task, including cancellation, can run. Existing
  executors/resolvers and legacy database rows retain their current semantics.
  Reconciliation receives engine-owned context and can report validated progress
  and updated recovery state without accepting a root or task ID from payloads.

### Submission, Progress and Recovery

1. Validate enablement/policy/template/values, commit nonsecret recovery identity,
   then use AST-082 acknowledged intent/outcome for submit, status, cancel and
   transfer. No transport after audit admission failure. Exclude secret/config/
   workflow/argv/stdio copies from generic events, task queues and SQL/WAL as well
   as the dedicated audit events; refuse or sanitize credential-bearing values
   before persistence without changing unrelated chat behavior.
2. Open isolated OpenSSH with strict pins, explicit dedicated identity and one
   loopback-only local forward to the fixed remote loopback endpoint. No ambient
   SSH config, agents, certificates, proxies, reuse or remote commands. Verify
   startup/child liveness and bound cleanup on EVERY path. HTTP and WebSocket
   connect only to that owned tunnel, with no environment proxy or redirects,
   bounded bytes/frames and total deadlines (including slow-drip responses).
3. Submit the pinned graph through native `/prompt`, with a stable engine-owned
   client/request identity in `client_id` and `extra_data`. Native `/ws` progress
   is accepted only for the owned prompt; project bounded node/count/stage data
   into task progress and linked traces, not previews or raw workflow/errors.
   Queue/history snapshots recover progress after disconnect; missing WebSocket
   events do not imply completion. No fabricated elapsed-time percentage.
4. A dropped POST response is ambiguous, not permission to POST again. Recover
   the original by exact request ownership in bounded `/queue` and `/history`
   responses, then bind its backend prompt ID. Do not rely on every deployed
   ComfyUI honoring caller-supplied `prompt_id`, or on that field deduplicating
   submissions. Zero/ambiguous matches or lost history become an honest orphan/
   unknown outcome, never a fresh render. Service restart never resets deadlines.
   Once the backend ID is known, inspect its bounded `/history/<prompt-id>` entry
   independently of the latest 256 history entries; retain queue/recent-history
   checks for conflicting ownership. Optional WebSocket failures retain polling.
5. Delete only an identified owned pending prompt via `/queue`'s explicit delete
   list. Do NOT call legacy/global `/interrupt`: older versions ignore supplied
   IDs, and check-then-interrupt can race another client. Running cancellation is
   reported unconfirmed/unsupported unless independently proven safe targeted
   backend semantics exist; no such guarantee is assumed in this initial adapter.
   Recheck queue/history, preserve ownership, and distinguish cancellation request
   from confirmation. Deadline expiration attempts safe pending deletion, reports
   that running work may continue, and never mistakes killing SSH for GPU cancel.
6. Confirm completion from owned history, distinguish execution failure/OOM and
   lost history, then stream the declared artifact via native `/view` over the
   SAME tunnel. Bounded backend filename/subfolder/type data select only the
   remote HTTP resource, never a local path. Construct the local relative path
   solely from the engine task ID and a trusted output type. Check size, type,
   symlinks and containment, publish atomically without overwriting another task,
   and report completion only after validated transfer and audit acknowledgement.
   Recovered completion repeats only safe inspection/download, never submission.

### Verification and Scope

Red-first tests cover live engine/queue/SQLite/audit integration, deferred polling,
restart before/after POST acknowledgement, lost response/history, cancellation
races with foreign work, finite deadline/OOM errors, schema/type/graph injection,
missing nodes/models, forged progress, hostile artifacts and privacy in SQL/WAL.
Exercise real ephemeral OpenSSH forwarding and native HTTP/WebSocket fixtures
locally, including pin mismatch, denied non-ComfyUI ports, child death and cleanup;
mocked argv alone does not prove a tunnel. Preserve inspect/cancel and generic
capability tests. Run the complete local gate; no pipeline is introduced.

AST-081 proves an image artifact flow without claiming a live GPU or 3D workflow.
AST-083/#350 owns installed video/3D evidence and the human-approved UI flow.
No live target enrollment, key/sshd edits, model downloads or paid API calls.

Protocol references (checked 2026-10-11):
- https://docs.comfy.org/development/comfyui-server/comms_routes
- https://docs.comfy.org/development/comfyui-server/comms_messages
- https://github.com/Comfy-Org/ComfyUI/blob/7f7fd918ed0815c5d5ef2ccfe44bfc8e72cfd217/server.py
- https://man.openbsd.org/sshd_config

The upstream server accepts client prompt IDs, but submission is not an
idempotency guarantee. Its legacy interrupt surface motivates the conservative
cancellation policy above; tests must include older behavior, not only HEAD.
