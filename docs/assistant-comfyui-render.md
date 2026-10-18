# Assistant ComfyUI Rendering

`comfyui-render` runs a pre-authored API JSON workflow through a dedicated SSH
tunnel and publishes a PNG image through the existing assistant artifact endpoint.
The engine uses Python stdlib plus PyYAML; it does not run `comfy-run.py` as a
subprocess or create another registry. The graph format is the same API format
used by the human recipe and explicit importer in [remote-compute.md](remote-compute.md).

## Install and Provision

On WSL/POSIX, explicitly run:

```sh
python3 -I /absolute/plugin/scripts/assistant/comfyui_render.py install --assistant-root /absolute/assistant
```

Installation copies only SKILL.md and a version-1 capability manifest. It refuses
an existing destination, symlink parents and brace-containing binding paths before
writing skill data. Spaces are supported. The absolute interpreter binding keeps
its symlink identity for virtual environments; the plugin engine path is resolved.
Installation does not enable the capability, enroll a target, download models, or
modify keys/sshd. Enable `assistant.capabilities.comfyui-render.enabled: true`
separately after configuring the installed manifest.

Example additions to installed `provisioning` (retain generated check/TTL):

```yaml
hosts:
  storm590x:
    host: 192.0.2.10
    port: 22
    user: comfy_tunnel
    knownHosts: /home/operator/.ssh/comfy_known_hosts
    keys: {tunnel: /home/operator/.ssh/comfy_tunnel}
    comfyPort: 8188
workflows:
  image:
    template: /home/operator/workflows/image-api.json
    sha256: REPLACE_WITH_64_LOWERCASE_HEX_SHA256
    timeout: 600
    inputs:
      prompt: {node: '6', input: text, type: string, maxLength: 2048}
      seed: {node: '3', input: seed, type: integer, minimum: 0, maximum: 2147483647}
    output: {node: '9', field: images, index: 0, type: png, maxBytes: 16777216}
```

The example node IDs must match the operator's actual pinned API template. Compute
its digest with `sha256sum`. Supported literal types are string, integer, number
(an existing floating literal), and boolean. Strings require maxLength; numeric
bindings require minimum/maximum; an optional allowlist narrows any type. Only
existing scalar inputs can change. Links, node classes, topology, filename/path
inputs and output selection cannot be changed by model parameters. Unknown
policy fields, hosts, workflows, changed template hashes and invalid types refuse.
The declared output initially supports PNG images only. Timeout is 1..86400 seconds;
artifact size is at most 64 MiB. API responses are bounded to 4 MiB and queue/history
reconciliation to 256 entries. Larger/evicted histories can require manual inspection.

Installed provisioning owns host/workflow authority. Registry membership and
project provisioning check/TTL overrides do not grant access or replace it.
The worker reloads enablement, schema, fixed argv bindings, template and policy
for each operation. Recovery also verifies a digest binding the endpoint, workflow,
pins and dedicated key material. Rotation or edits while a job is active produce
an explicit refusal/orphan; never silently submit to the new endpoint.

## Dedicated Tunnel Grant

Use a **dedicated tunnel-only SSH account or a separate dedicated sshd listener**.
The account/listener must not also serve AST-080 inspect/cancel keys or human
shell/SFTP sessions: `MaxSessions 0` disables every shell/subsystem session in
its scope, not only the tunnel key. Do not put that restriction globally on an
existing mixed-use daemon or apply it to a shared user such as `leona`.

An administrator provisions the dedicated key's authorized_keys entry:

```text
restrict,port-forwarding,permitopen="127.0.0.1:8188" ssh-ed25519 PUBLIC_KEY
```

In the dedicated listener configuration, or a Match User block for ONLY the
dedicated tunnel account, apply:

```text
AllowTcpForwarding local
AllowStreamLocalForwarding no
MaxSessions 0
PermitTunnel no
PermitUserRC no
AllowAgentForwarding no
X11Forwarding no
GatewayPorts no
PasswordAuthentication no
KbdInteractiveAuthentication no
```

Keep all grants/configuration administrator-owned, remove alternative unrestricted
grants for that key, and verify the effective configuration. Bind ComfyUI only to
remote `127.0.0.1`; do not expose it on LAN. These instructions do not change the
existing control key grants. A forced command does not restrict forwarded HTTP
routes. The tunnel grants access to the **entire selected ComfyUI service**; it is
not route authorization or an OS sandbox. Trust the service, custom nodes, pinned
templates and accounts. Protect local loopback access on the controller too.
Local `check` verifies only prerequisites, never remote enforcement or bind state.

The client isolates ambient SSH config, agent/certificate/default identities,
proxies, host trust and multiplexing. One literal local loopback forward reaches
the declared remote loopback port. Authentication and owned-listener evidence are
required before HTTP; child liveness is checked, and cleanup escalates from TERM
to KILL with bounded wait/reap. HTTP does not consult proxy environment variables
or follow redirects. Header/body reads have a total deadline including slow drip.
Native WebSocket reads bound headers/frames, validate the accept hash, handle
fragmented messages and ping, and ignore previews and unrelated prompt progress.
Optional WebSocket connection, handshake or stream failure falls back to native
queue/history polling; it does not itself orphan an otherwise observable prompt.

## Tasks, Audit and Recovery

Render parameters are `{host, operation: render, workflow, values, task_id: ""}`;
`values` is a JSON object encoded as a string. Cancellation uses `operation: cancel`,
the same host/workflow, `values: "{}"` and a task ID from the same assistant.
Name matching is case-insensitive; a changed longRunning flag cannot force inline
execution. Managed code validates the v1 schema and fixed argv binding, then uses
the native executor; direct CLI invoke refuses without engine-owned context.

Only validated descriptors enter the queue. Credential syntax and known credential
substrings in decoded values, including nested and embedded JSON strings, are
refused before queue/SQL and on fresh operation authority checks; generic skill events
omit values. No config, argv, graph, backend error or stdio snapshot is persisted.
This does not classify arbitrary private prose and does not alter ordinary chat.
Dependency failures identify bounded node/input names from actual `/object_info`.

The worker adds optional `recovery` JSON to tasks.sqlite under a serialized,
idempotent migration. Older rows remain readable with null recovery; generic
executor return dictionaries keep their old meaning. Only this kind uses Deferred
and context-aware reconciliation. Request UUID, immutable deadline, policy digest
and phase are committed before POST; backend prompt ID is committed before
submission acknowledgement. Deferred polling frees the worker for other tasks.
The existing root owner/heartbeat guards and single writer remain in use.

Each submit, status, cancel and transfer crosses `remote_audit.run` with committed
intent before transport and a terminal acknowledgement. A lost POST response audits
unknown and never triggers POST retry. Queue/history matches must prove exact
engine request/client ownership; zero or multiple matches orphan the task. Restart
recovery inspects a known backend ID with `/history/<prompt-id>` even when it has
left the latest 256 history entries. Bounded recent history and queue inspection
still detect conflicting ownership; malformed or oversized replies are refused.
When the backend ID is unknown, recovery remains limited to the bounded recent
history and queue window; unavailable ownership never authorizes resubmission. Restart
before POST, after POST or after acknowledgement never resubmits; trace pruning
cannot remove durable ownership. Native progress is a bounded observed node/count
sample, not an elapsed-time percentage or completion authority.

Cancellation may delete only an identified owned pending prompt. This adapter
never invokes global `/interrupt`. A race into running reports pending; an empty
delete receipt followed by absence remains unknown because completion/history
eviction is indistinguishable from deletion. No confirmed cancellation is claimed
from those observations. Deadline expiration attempts bounded safe pending deletion
and reports that remote running work may continue. Closing SSH is not GPU cancellation.

Owned successful history selects the declared remote `/view` resource. Filename,
subfolder and type never become local paths. The task ID alone determines
`artifacts/<task-id>.png`; transfer checks size/MIME/PNG markers and symlink/regular
file constraints, stages locally, and publishes exclusively. A recovered transfer
may inspect/download again and accept an identical existing task artifact, never
overwrite another task. Completion requires transfer and audit acknowledgement.
Existing destinations are opened without blocking and checked through the opened
descriptor before reading; FIFOs and other nonregular files fail the task while
leaving the worker available for subsequent work.
Audit failure after a remote effect preserves IDs with uncertainty; failed or
orphaned tasks require operator inspection and are not automatically retried.
There is no cross-database atomic transaction: a crash between effect and outcome
can leave incomplete audit history, and a published file may precede task completion.

## Verification Boundary

`--section comfyui-render` runs local native HTTP/WebSocket fixtures through real
ephemeral OpenSSH, engine queues and SQLite. It covers progress, image serving,
restarts, ambiguous receipts, failures, privacy, trust refusals and cleanup. The
fixture uses synthetic images and isolated keys/listeners; it does not prove a live
GPU, installed target enrollment or video/3D workflow. AST-083/#350 owns that evidence
and the human-approved UI flow. No paid API, UI change or pipeline is introduced.

Protocol references: [ComfyUI routes](https://docs.comfy.org/development/comfyui-server/comms_routes),
[messages](https://docs.comfy.org/development/comfyui-server/comms_messages),
[pinned server source](https://github.com/Comfy-Org/ComfyUI/blob/7f7fd918ed0815c5d5ef2ccfe44bfc8e72cfd217/server.py),
and [OpenSSH sshd_config](https://man.openbsd.org/sshd_config).
