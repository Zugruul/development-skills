---
name: whisper-sidecar
description: Installs, starts, stops, and health-checks the local whisper.cpp speech-to-text sidecar the assistant's voice input relies on when the whisper STT engine is selected. Use for local, private, offline speech transcription -- fully on-machine, no audio leaves the device.
---

> Materialized by `/setup-assistant`; refreshed on every scaffold -- edit the plugin copy, local edits are overwritten.

# whisper-sidecar

Manages the local whisper.cpp HTTP sidecar (`127.0.0.1:8737`) that the
neural-view voice panel's `whisper` STT engine talks to
(`docs/spec-deltas/applied/ast-051.md`). This capability owns install,
process lifecycle, and honest provisioning status -- it never performs
transcription itself; the already-shipped browser client (`neural-view.html`'s
`WhisperSttEngine`) talks to the sidecar's HTTP endpoint directly.

## Provisioning

`capability.yaml`'s `provisioning.check` runs `whisper_sidecar.py status`
(read-only, TTL-cached 30s): reports healthy only when the binary+model are
installed AND the server process is alive AND its port is accepting
connections. Any other state (not installed, not running, starting up,
stale pidfile, or an unrelated process occupying the configured port) is
reported unavailable with a specific, actionable reason -- never a generic
or silent failure (SPEC-ASSISTANT.md §13.2).

## Invoke actions

`invoke.exec` templates a single `action` param (schema-validated via an
allowlist -- `install | start | stop | status`):

- `install` -- fetches the `whisper-server` binary and a model into local
  state (`WHISPER_SIDECAR_STATE_DIR`, default `~/.claude/whisper-sidecar`).
  Idempotent; never runs implicitly from `status`/`start`.
- `start` -- spawns the (already-installed) server as a detached
  background process and waits for it to become healthy. Idempotent;
  refuses to touch a port held by an unrelated process.
- `stop` -- terminates the tracked process (SIGTERM, escalating to
  SIGKILL) and clears the pidfile. Idempotent.
- `status` -- same read-only check as provisioning, callable directly.

See `whisper_sidecar.py`'s module docstring for the full state machine and
every environment-variable override (state dir, port, install sources,
start timeout) hermetic tests use to avoid any real network access or
process leakage.
