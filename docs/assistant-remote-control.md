# Restricted Assistant Remote Control (AST-080/082)

`remote-compute-control` lets an enabled assistant inspect installed capabilities,
read job status and bounded logs, and cancel an existing job on an explicitly
approved WSL target. The current target is storm590x/WSL. Native PowerShell is not
supported. The human `remote-compute` controller keeps its existing trusted recipe
and administration semantics; registering a machine there grants no assistant access.

## Install Skill Data in WSL

Run with the plugin checkout's absolute path, using a POSIX Python with PyYAML:

```bash
python3 -I /absolute/development-skills/plugins/spec-workflow/scripts/assistant/remote_control.py \
  install --assistant-root /absolute/assistant-repo
```

This explicit human action creates only `.claude/skills/remote-compute-control/`
containing `SKILL.md` and `capability.yaml`. It writes the absolute Python interpreter
path and resolved plugin engine path into the check/invoke argv. Interpreter symlinks
are preserved so a virtual environment retains its prefix and dependencies.
It does not copy engine code,
write dev-loop instructions, change project.yaml, enable a capability, register a
host, connect to SSH, or modify target configuration. Existing installations are
refused, including empty directories and symlinks. Run the installer from any cwd.

The absolute interpreter path (including a virtual environment's path), resolved
engine path, and target manifest path must contain neither `{` nor `}`. The installer
refuses these binding paths before creating directories or writing skill data, since
the existing capability adapter treats braces as placeholders. Use an assistant
directory, Python environment and plugin location without braces; ordinary spaces
remain supported. Generic adapter substitution behavior is unchanged.

Keep the installed manifest and the engine checkout trusted: they are executable
capability policy. Absolute engine paths must remain present. After moving/updating
the plugin, back up and review the installed data, install into a separate staging
assistant directory, compare the new argv/skill text, then explicitly update the
reviewed installation while retaining its host policy. No automatic replacement or
host-policy migration is provided. Keep private keys and pins outside the repo;
consider ignoring the installed directory if its machine-local paths are private.

Edit **the installed capability.yaml**, retaining generated check/invoke argv:

```yaml
provisioning:
  # Preserve the installer's check argv and ttlSeconds fields here.
  hosts:
    storm590x:
      host: 192.0.2.59
      port: 22
      user: assistant_compute
      knownHosts: /home/operator/.config/assistant-remote-control/known_hosts
      keys:
        inspect: /home/operator/.config/assistant-remote-control/inspect_ed25519
        cancel: /home/operator/.config/assistant-remote-control/cancel_ed25519
```

The address above is an example, not storm590x's discovered address. Entries require
exactly these fields. Only DNS names and IPv4 literals are supported. Paths must be
absolute ASCII paths; spaces work, but expansions (`~`, `$`, `%`), quotes, backslashes,
parent traversal and control characters are refused. Credentials and pins must be
regular single-link files, with no symlink ancestors; private keys require mode 0600
or stricter and separate files for the two classes. Use genuinely distinct keypairs,
never duplicate copies of an unrestricted key. The local check checks file and
policy prerequisites, not whether a private key is usable or the server enforces
its grant. Encrypted keys requiring a prompt/agent will fail closed at invocation.

`provisioning.hosts` is authoritative and reread on every invocation, even after
provisioning TTL caching. Empty or missing hosts deny all. Project provisioning
overrides currently support **check and TTL only**; a `hosts` override in project.yaml
does not change this policy. A human may consult an existing `resources.yaml` to copy
an approved literal host/user/port, but must separately verify pins and provision
dedicated keys. Nothing imports the registry automatically or uses its SSH options.

After server provisioning and verification below, separately enable:

```yaml
assistant:
  capabilities:
    remote-compute-control:
      enabled: true
```

Merge this entry with the assistant's existing config. Keep its provider capabilities
and other settings. Existing enablement/schema/argv gates are unchanged.

## Target Provisioning by an Administrator

The target needs POSIX OpenSSH and Python 3. The server is stdlib-only. The administrator
deploys two reviewed files through an existing trusted administration channel:

- `plugins/spec-workflow/scripts/assistant/remote_control_server.py`
- `plugins/remote-compute/scripts/remote-capabilities/_shared/compute-state.py`

For example, deploy them as `/opt/assistant-control/remote_control_server.py` and
`/opt/assistant-control/compute-state.py`. Make code, their ancestor directories,
sshd configuration and authorized keys administrator-owned and not writable by
the restricted account or workloads. Select an absolute existing compute root
(for example `/srv/assistant-compute`) with the usual `caps/`, `jobs/`, state and
lock files. The restricted account needs read access to catalog/job data and, for
cancel, access to signal those jobs and update their cancellation state. No sudo
is called. Existing job metadata and its producers must be trusted.

Use different dedicated public keys, each with a fixed command in an admin-owned
authorized_keys file. Replace the two public-key placeholders with actual keys:

```text
restrict,command="/usr/bin/python3 -I /opt/assistant-control/remote_control_server.py --class inspect --root /srv/assistant-compute --helper /opt/assistant-control/compute-state.py" ssh-ed25519 INSPECT_PUBLIC_KEY
restrict,command="/usr/bin/python3 -I /opt/assistant-control/remote_control_server.py --class cancel --root /srv/assistant-compute --helper /opt/assistant-control/compute-state.py" ssh-ed25519 CANCEL_PUBLIC_KEY
```

Keep these fixed deployment paths simple (no shell metacharacters or spaces in these
authorized_keys examples). OpenSSH invokes the fixed command through the account's
shell, so neither its startup configuration nor the fixed command may ingest
client-controlled code. Python **`-I` is required** to ignore PYTHONPATH, user-site
packages, and cwd import injection. No part of SSH_ORIGINAL_COMMAND is appended
to that shell command: the dispatcher reads it only as one encoded data token.

The account must have no alternative unrestricted grant for either dedicated key:
audit duplicate authorized_keys entries, AuthorizedKeysCommand, CA/certificate
authorization, and any server ForceCommand which could override these commands.
An unrestricted copy of the same key defeats this boundary. Human admin credentials
must stay separate and unavailable to the assistant. `restrict` disables forwarding,
PTY and user rc execution for the key; retain sshd defense in depth, for example:

```text
Match User assistant_compute
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthorizedKeysFile /etc/ssh/authorized_keys/%u
    PermitUserEnvironment no
    PermitUserRC no
    DisableForwarding yes
    PermitTTY no
    PermitTunnel no
```

Keep global `StrictModes yes`, review the effective configuration with `sshd -T`
including the appropriate `-C` connection criteria, and validate changes with
`sshd -t` before the administrator's normal deployment procedure. This document
does not change a live service. Pin the target host key using a separately trusted
fingerprint/channel; an unverified `ssh-keyscan` result alone is not enrollment.
Use `[host]:port` known_hosts entries for nondefault ports. The pin file must
contain only intentionally trusted keys and must not itself grant a broad CA.

## Operations and Failure Semantics

The installed capability takes three schema-validated parameters:

| Operation | Fixed Key Class | `job_id` | Result |
| --- | --- | --- | --- |
| `inventory` | `inspect` | Always `""` | Installed capability catalog |
| `status` | `inspect` | Existing job ID | Helper snapshot |
| `logs` | `inspect` | Existing job ID | Last 65,536 bytes, UTF-8 replacement decoding, truncation flag |
| `cancel` | `cancel` | Existing job ID | Identity-checked cancellation outcome |

The adapter requires every referenced placeholder, so inventory callers **must
supply `job_id: ""`**; this is not an omitted optional parameter. Other IDs match
`[A-Za-z0-9][A-Za-z0-9._-]{0,63}`. The capability path is the normal engine index
and adapters; the manifest is version 1 and `longRunning: true`. Managed remote work
always queues, even if that flag changes to false, so audit and network waits never
run on the chat thread.

For a direct human diagnostic after provisioning, from any cwd:

```bash
python3 -I /absolute/development-skills/plugins/spec-workflow/scripts/assistant/remote_control.py \
  check --manifest /absolute/assistant-repo/.claude/skills/remote-compute-control/capability.yaml
python3 -I /absolute/development-skills/plugins/spec-workflow/scripts/assistant/remote_control.py \
  invoke --manifest /absolute/assistant-repo/.claude/skills/remote-compute-control/capability.yaml \
  --host=storm590x --operation=inventory --job-id=
```

The client uses `/usr/bin/ssh`, `-F /dev/null`, dedicated IdentityFile plus the
`none` sentinel, IdentitiesOnly, no agent/cert algorithms, public-key-only auth,
strict private pins, no supplemental trust command/file, no proxy/local commands,
no stdin/PTY/forwarding/control reuse. It does not read generic remote-compute SSH
configuration. SSH has a 5-second connect timeout and a 15-second total client
deadline; helper calls have an 8-second total deadline, including lock waits.
Both output pipes together are limited to 131,072 bytes; oversized output refuses
instead of returning a partial JSON result. There is no automatic retry.

The wire token is unpadded base64url JSON (maximum 2,048 ASCII characters):
`{"version":1,"operation":"inventory"}` or the same with the exact `job_id`
field for status/logs/cancel. Both boundaries validate operation schemas. The
server chooses authority from its **fixed admin class argument**, never from
the token, and maps to only catalog/status/cancel helper actions or its log reader.
Unknown versions, duplicate/extra fields, shell/subsystem requests and cross-class
operations refuse before helper execution. No exec, install, launch, policy change,
file transfer, tunnel or arbitrary filesystem argument exists.

Success is `{"version":1,"ok":true,"operation":...,"data":...}`. Failure exits
nonzero and writes a bounded reason to stderr; the client also returns an `ok:false`
JSON diagnostic. Remote data never supplies an engine artifact path or a command.
Direct human diagnostic CLI/library calls retain this legacy result format and do
not produce assistant trace events. In the managed path, a nonzero exit or invalid
response fails the task with a sanitized error. Useful results contain projected
status/exit code, catalog names/descriptions, or redacted bounded logs; they do not
contain raw argv, stdout or stderr. A completed cancellation request still requires
reading its result: `cancelled` confirms cancellation, `cancelling` means pending,
and `unknown` is not confirmation. ComfyUI, tunnels and artifact sync remain AST-081;
no transport or artifact executor for those is added.

The low-level `invoke_capability`/adapter APIs, and a direct legacy
`run_capability_invoke_task` library call with a plain progress callback, remain
unaudited compatibility surfaces. They are not managed assistant entry points.
Both `tasks.enqueue` and the worker's create boundary normalize remote names to
`remote-command` before persistence; the worker supplies its own audit context.
Thus managed work cannot enter that legacy fallback. `remote_audit.run_task`
without the worker's context refuses with a sanitized, actionable error before
invocation. Nonremote executor signatures and defaults are unchanged.

Cancellation inherits compute-state's saved process-identity checks. A reused PID
or job with no fingerprint is not signalled. A timeout can leave the outcome
unknown, including a cancellation already applied: inspect status and seek human
direction before any new cancellation. Do not retry via a broader key or shell.

## Command Audit and Recovery

Each managed request receives an engine-generated command ID. `remote.command.intent`
and `remote.command.outcome` use indexed turn/span/parent identifiers and a task ID
in the payload. Outcomes distinguish success, refusal, failure, confirmed cancellation,
pending cancellation and unknown cancellation. Local enablement, schema, provisioning
and task-admission refusals are linked too; refusal before worker admission can have
an outcome without intent. All trace writes use the existing single writer.
`emit_ack` freezes a bounded JSON event before enqueueing and acknowledges only after
COMMIT, never after `queue.task_done`. Invalid acknowledged records cannot degrade
to a successful marker event. Its default deadline is two seconds.

A full queue, dead writer, storage error or acknowledgement timeout prevents the
operation. A timed-out intent can commit later; that does not authorize a late effect.
If terminal persistence fails after an effect, the task reports uncertainty and
retains its durable IDs. It must not replay. Unavailable audit storage also prevents
the engine from promising that the refusal itself reached traces.sqlite. A crash
after intent/effect but before terminal persistence can leave an incomplete trace.
These are explicit failure windows, not proof that nothing happened remotely.

Before remote task or adjacent skill events enter a queue, the engine projects only
operation, host nickname and job ID from the exact control parameter schema; invalid
or extra values become fixed refusal codes. It never stores the manifest, assistant
config, credential paths, workflows or raw diagnostics in that task. Unknown result
fields are excluded per operation; output never supplies a root, database/context or
artifact path. Logs and catalog descriptions retain useful text after redacting known
credential values and credential assignments, authorization tokens, URL passwords and
private-key blocks. JSON object keys and values are decoded and sanitized, including
serialized JSON strings and escaped URI separators. Sensitive fields are classified
using their original decoded names, before sanitizing the names themselves. Embedded
JSON objects, arrays and quoted strings in mixed logs receive the same treatment,
preserving useful surrounding text. Structured sanitization is bounded to 16 nesting
levels and each mixed-text scan to 256 decode attempts; deeper content or an unchecked
scan remainder becomes a redaction marker. Quoted assignments consume escaped quotes
completely, including single-quoted values. Redaction precedes truncation and
persistence. This policy does not globally redact user messages or unrelated
conversation. Arbitrary unlabelled
private prose is not universally classifiable; workloads should keep secrets out of
free-form output as well as their parameters.

Audit events use existing `retainDays`/`maxMB` retention, including deferral when a
reader pins the WAL. They are prunable history. Task IDs, external job IDs, ownership
and minimal reconciliation descriptors live in tasks.sqlite, which trace retention
never opens or prunes. Restart re-polls interrupted requests' known job IDs under a
fresh audited status command; it never repeats cancellation or the original action.
Missing IDs or unreconcilable jobs become orphaned. Failed uncertain tasks retain
their IDs for inspection but are not silently retried. Legacy task rows remain
readable; this change does not erase private data written by older releases.

AST-081 must call `remote_audit.run(report_progress.audit_context, operation, effect,
host=..., job_id=...)`. The task worker creates the context; never derive it from
model parameters, manifest commands or remote responses. Callers must retain existing
named-capability/host/schema gates, bind their approved transport, persist newly
allocated external IDs through `report_progress` before the callback returns, and
construct artifact destinations from the engine-owned task ID. The transfer test
invokes a local callback and verifies an already-committed intent; it does not
implement or certify real transfer. AST-081 must bind and test the actual executor.

The reusable transfer callback must return a nonnegative integer `bytes` count and
an explicit `state`. Only `done` or `completed` returns a successful receipt and
audits `success`; zero bytes is valid for an explicitly completed empty transfer.
`failed` audits `failure`; `cancelled` audits `cancelled`; `unknown` or `lost` audits
`unknown`. `queued`, `started`, `progress`, `running`, `reserved`, `pending` and
`cancelling` audit `pending`. All these non-success states raise a sanitized error
after outcome persistence, rather than letting a task report completion. Missing,
unrecognized or ill-typed states/counts are malformed receipts and audit `failure`.
No outcome triggers automatic replay. The caller must retain durable job IDs and
reconcile incomplete or unknown transfers; a byte count alone is not completion.

## Security Limits and Verification

Forced commands limit requests made with these keys, including a stolen key or
model-controlled request. They are not an OS sandbox or protection from a compromised
administrator, SSH daemon, engine checkout, policy author, unrestricted credential,
or malicious local process changing trusted metadata. The wrapper rejects linked
ancestors, symlinks, hardlinks, nonregular metadata/log files and oversized metadata
before invoking the helper. Log reads additionally walk directory descriptors with
O_NOFOLLOW and reject nonregular leaves. Helper metadata/lock access remains
path-based; trusted target writers are a prerequisite, not a claimed TOCTOU defense.
Catalog entries are bounded to 128. Log content and catalog values remain untrusted
data even though their containing files are trusted.

Run the integrated local tests from the repository:

```bash
bash plugins/spec-workflow/tests/run-tests.sh --section remote-control,remote-audit
bash plugins/spec-workflow/tests/run-tests.sh --section remote-audit
```

Tests cover refusal matrices, installed data through actual adapters from unrelated
cwd, disabled capabilities, fresh policy reads, helper cancellation effects and
lock timeouts, constrained logs, real `ssh -G` parsing with spaced paths, hostile
config isolation, and disappearing-key fallback. When `/usr/sbin/sshd` exists,
the suite creates ephemeral keys and a private home-directory fixture, binds only
loopback on a temporary port, uses StrictModes, and terminates/waits its own daemon.
The daemon allows forwarding so the forwarding refusal proves the key's `restrict`
grant. Shell, subsystem, PTY, wrong key/pin, cross-class and malformed requests are
tested alongside successful operations. Missing sshd is an explicit unittest skip;
startup/authentication failures with an installed sshd are failures, not skips.
No target enrollment or live sshd configuration is touched. These results prove
the fixture deployment only; verify each real deployment independently.
