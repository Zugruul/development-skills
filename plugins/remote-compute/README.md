# remote-compute

Register remote machines you own (SSH, key-only, `BatchMode=yes` always) as
user-level compute resources, advertise their availability to projects, and
dispatch jobs and capability bundles to them. Extracted from the spec-workflow
plugin — design: `docs/design/remote-compute-plugin-extraction.md`; full user
guide: `docs/remote-compute.md` (repo root).

This plugin **requires the spec-workflow plugin**: `enable` advertises a
machine by writing the `compute:` section of a repo's gitignored
`.neural-network/project.local.yaml`, and reads go through spec-workflow's
`config.py`, which merges that overlay (`LOCAL_OVERLAY_KEYS`) and validates
its shape (`validate-config.py`, project-config schema). The gitignoring of
`project.local.yaml` is also spec-workflow's (`local-state.manifest` +
`gitignore-sync.sh`). Installing remote-compute without spec-workflow leaves
`enable` refusing to run (no `.neural-network` repo) and nothing able to read
what it writes — install both.

Not to be confused with SPEC-PEER-REVIEW.md's "remote-compute layer": that is
the peer-review plugin's own llama.cpp dispatch naming, with no code shared
with this plugin.

## Skills

| Skill | What it does |
| --- | --- |
| `remote-compute` | Register/probe/enable machines, install capability bundles, dispatch jobs, cooperative locking. Engine: `scripts/remote-compute.py` (stdlib + PyYAML; registry at `$COMPUTE_HOME`, default `~/.remote-compute` — machine-local, never committed). |
| `compute-top` | Terminal dashboard (stdlib curses), locally or over SSH, for what a compute machine is doing. Script: `scripts/remote-capabilities/_shared/compute-top.py`; on the box: `compute-top` (alias of `remote-compute top`). |
| `scan` | Re-finds registered machines whose DHCP address changed: sweeps the subnet for ssh, requires the pinned host key AND the `~/.remote-compute/.identity` stamp to agree, flags duplicate identities for the human to resolve (`--pick`), converges known_hosts + ssh alias + registry. Verbs: `scan`, `identity`. |
| `ssh` | Lists registered machines with ready-to-paste ssh one-liners (shell, dashboard, job table, GPU) and up/down. Verb: `connect`. |

## The on-machine command

`register` installs `scripts/remote-capabilities/_shared/remote-compute-remote.sh`
on every box as `~/.remote-compute/bin/remote-compute` (linked from `~/.local/bin`),
so `remote-compute top|jobs|running|log|status|cancel|caps|gpu|disk|paths|identity`
works the same at the keyboard and over ssh. It preserves the legacy `.identity`
nickname stamp and adds an immutable `.machine-id` UUID. `install-tools <nick>`
updates both the local helpers and controller, without renaming that identity.
`python3 scripts/remote-compute.py install-cli` installs a combined CLI on a
controller (WSL/Linux/macOS, Python 3.8+, PyYAML, SSH, rsync; Git for GitHub installs).
Bare invocation prints help only. Use `local <verb>` or `controller <verb>` when
local job IDs and registered machine names would otherwise be ambiguous.

## Capability bundles

`scripts/remote-capabilities/` — installable per-machine bundles: `comfyui/`
(ComfyUI txt2img dispatch), `slm-training/` (GPU check, training, GGUF export,
eval suite). Each carries a `capability.yaml` manifest. Run
`remote-compute capabilities list` to discover bundled capabilities and
`remote-compute capabilities install <nickname> <bundle-name>` to install one;
custom bundles can be installed by passing their local directory instead, or:

```bash
remote-compute capabilities install gpubox https://github.com/OWNER/REPO NAME --ref TAG
remote-compute capabilities install gpubox git@github.com:OWNER/REPO.git --all
remote-compute capabilities sync gpubox
```

GitHub sources must contain `capability.yaml` bundles. All discovered bundles
are validated before installation; each bundle upgrade is atomic, while `--all`
may stop after earlier bundles succeed. Resolved commit provenance is retained.
Other clients import the target catalog with `sync`; payloads need not be installed
again. Target environment activation declarations remain local to each controller.
Use `remote-compute capabilities installed [<nickname>]` to inspect installed
capabilities across all registered machines or one selected machine. See the
full controller command list with `python3 scripts/remote-compute.py --help`;
on a compute machine, `remote-compute help` covers both modes. Bare
`caps`/`capabilities` reports the local inventory; subcommands manage targets.
`installed` reads the client cache; use `sync` to refresh it and `doctor` to
check readiness. Installation does not install Python dependencies, model
weights, or services. Trusted job code is not sandboxed.

## Coordination and compatibility

New jobs reserve slots atomically on the target account, retain immutable IDs,
and persist recovery receipts before launch. `policy NICK --max-concurrent-jobs N`
sets the shared admission limit. Process fingerprints distinguish dead/reused
PIDs; cancellation never claims a live tracked process has stopped. Unknown
and pending jobs remain visible. `doctor [NICK] [--json]` diagnoses SSH, UUID,
versions, environments, catalog drift, and stale jobs without changing configuration.

Legacy registries, job receipts, payloads, local commands, and controller aliases
remain readable. Reinstall legacy bundles once to publish their catalog; then
other clients can sync it. Old controllers do not participate in the target
protocol: update every dispatching client for cross-client coordination.

## Tests

`bash plugins/remote-compute/tests/run-tests.sh` — hermetic (scripted fake ssh
transport, no network ever). The suite reaches into `plugins/spec-workflow`
for `config.py`/`validate-config.py`/fixtures — the same direction as the
plugin's declared dependency. `tests/e2e-remote-compute-manual.sh` is the
deliberately-unregistered manual end-to-end against a real machine.
spec-workflow keeps its own `section-compute-overlay.sh` proving the overlay
machinery with a hand-crafted `compute:` section (the contract seam's other
half).
