# remote-compute

Updating an existing installation? Follow the [installed-update guide](../../docs/remote-compute-updates.md)
for host/cache verification, standalone and target tools, and complete backup
and recovery of legacy custom catalogs. Tool updates do not update bundles.
If reading an installed package without the repository's root docs, use the
[published guide](https://github.com/Zugruul/development-skills/blob/main/docs/remote-compute-updates.md).

Register remote machines you own (SSH, key-only, `BatchMode=yes` always) as
user-level compute resources, advertise their availability to projects, and
dispatch jobs and capability bundles to them. Extracted from the spec-workflow
plugin — design: `docs/design/remote-compute-plugin-extraction.md`; full user
guide: `docs/remote-compute.md` (repo root).

This plugin **requires the spec-workflow plugin**: `enable` advertises a
machine by writing the `compute:` section of a repo's gitignored
`.neural-network/project.local.yaml`. Spec-workflow's `config.py` merges that
overlay (`LOCAL_OVERLAY_KEYS`); `validate-config.py` and the project-config schema
validate its shape. The gitignoring of
`project.local.yaml` is also spec-workflow's (`local-state.manifest` +
`gitignore-sync.sh`). Install both for project setup. The installed controller
needs no spec-workflow Python module to consume compute availability; role
selection still requires `.neural-network/project.yaml` at the chosen root.

Not to be confused with SPEC-PEER-REVIEW.md's "remote-compute layer": that is
the peer-review plugin's own llama.cpp dispatch naming, with no code shared
with this plugin.

## Skills

The [incremental compatibility matrix](../../docs/compatibility-matrix.md)
audits these four skills' Claude/Codex interaction and safety semantics,
distinguishing local tests from unverified live host/SSH execution and linking
separately filed gaps. Execution targets are WSL/Linux/macOS; Windows Codex
hosts need a WSL bridge and native PowerShell is unsupported. Interactive
dashboards need the human's TTY; agent non-TTY output is a snapshot.
This is a scoped CDX-050 contribution, not completion of CDX-042's whole
marketplace inventory. In an installed plugin without repository docs, use
the [published matrix](https://github.com/Zugruul/development-skills/blob/main/docs/compatibility-matrix.md).

| Skill | What it does |
| --- | --- |
| `remote-compute` | Register/probe/enable machines, install capability bundles, dispatch jobs by nickname or project role, cooperative locking. Engine: `scripts/remote-compute.py` (stdlib + PyYAML; registry at `$COMPUTE_HOME`, default `~/.remote-compute` — machine-local, never committed). |
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

## Project role dispatch

Use `run --role ROLE JOB [--root DIR]` or
`dispatch --role ROLE --workdir W --cmd C [--root DIR]` with the existing options.
Root defaults to cwd. The optional project.local.yaml compute value replaces the
whole project.yaml compute value, including empty overrides. Only explicitly
enabled, client-registered aliases with an exact case-sensitive role match are
eligible, in lexical order. Nickname commands read no project and need no enablement.

The controller reports skipped candidates with incompatible jobs, parameters or
named environments. Activation must be nonempty; recorded verification errors
exclude a candidate while missing legacy stamps remain supported. No hardware
probe, automatic catalog sync or environment installation is performed.

Existing target admission remains authoritative. Fallback is limited to local
busy/lock or bounded read-only connectivity failure before reservation, or an
explicit unambiguous target busy/lock reservation refusal. Uncertain reservation,
staging failure and every launch failure stop with target/job recovery advice;
unknown receipts must be inspected before manual retry. No candidates exits 2,
all busy exits 6, exhaustion including unreachable exits 1. This is serial
selection with no queue or automatic rerun. See the
[role dispatch guide](../../docs/remote-compute.md#selecting-a-machine-by-project-role)
or its [published copy](https://github.com/Zugruul/development-skills/blob/main/docs/remote-compute.md#selecting-a-machine-by-project-role).

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
remain readable. Publishing a legacy catalog requires a reviewed reinstall;
first follow the installed-update guide's complete backup and custom-source
comparison, because unlisted and unpreserved mutable files can be lost. Other clients can then
sync the catalog. Old controllers do not participate in the target
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

## Local repositories and runtime preservation

Local checkouts can use the same bundle selection as GitHub repositories:

```bash
remote-compute capabilities install gpubox /path/to/repository --all
remote-compute capabilities install gpubox /path/to/repository game-assets
```

Discovery validates all bundles before installation. Each bundle is replaced
individually; a batch can stop after earlier bundles succeeded. Local source
metadata records the resolved path, bundle path, Git commit and dirty state when
available. Installation takes a snapshot; it does not create a live symlink.

A manifest may declare `preservePaths: [runtime]` to retain named top-level
runtime roots through replacement. Names must be unique safe path components,
not symlinks, managed payload, capability.yaml or .installed.json. Runtime roots
are moved while the target coordination lock is held and retain their absolute
paths. An ordinary filesystem error rolls the replacement back. A process/host
crash can leave a previous-* staging backup requiring manual recovery; this is
not a crash-journaled transaction. Files not declared for preservation are
replaced. Purge deliberately deletes runtime state. Prefer --retire-remote when
switching a capability source, then install the new bundle.

Shell scripts are normalized to LF in installer staging so Windows checkouts can install runnable WSL/Linux launchers. Source files are not rewritten by installation.
