# Updating an already-installed remote-compute plugin

A merge changes repository source. Getting that change into an existing
installation requires checking each layer below. Use Bash on WSL/Linux/macOS
for remote-compute; native PowerShell is not a supported compute target.
Windows host plugin management and a WSL controller are separate installations.

| Layer | Update operation | Evidence to collect |
| --- | --- | --- |
| Reviewed source | Select a trusted commit or release | Repository, revision, manifest version, script hashes |
| Marketplace and installed cache | Host-specific refresh/update | Exact host/profile, marketplace source, installed path and files |
| Running host | Reload or start a new session after updating disk | Active skill path and changed skill content in that session |
| Standalone controller | `install-cli --prefix DIR` from reviewed source | Resolved command, copied source, command version |
| Target tools | `install-tools NICK` | Target command version, original identity/UUID, helper files |
| Capability payload and catalog | Separately reviewed bundle install, then client sync | Manifest, payload hashes, published jobs, local environments |
| Workload readiness | Inspect prerequisites and run a declared smoke job | Dependencies, services, models/dataset, job exit and expected output |

Matching version strings alone do not prove matching revisions. A source/cache
version is not the running host, standalone CLI, target tools, or payload/catalog
readiness. Record before/after evidence for the layers actually changed.

## Source and active host

First record the exact runtime/profile, OS account, working directory, installation
method (marketplace, local checkout, or linked skills), and active skill path shown
by the running host. Identify which configuration and marketplace source that host
uses. Read the manifest and changed skill/script in that path. Do not infer the
active installation from a checkout or from another CLI's empty listing.

For a reviewed checkout, record `git rev-parse HEAD` and `git status --short`
from its root. Select the intended trusted revision before using its installer;
do not install an unreviewed working tree. Plugin manifest and CLI versions may
differ. Keep the revision and file hashes as well as version numbers. For a
cached source without Git metadata, compare the relevant files against that
reviewed revision. Do not hand-edit managed plugin caches.

### Codex

Inspect the CLI associated with the intended host/profile first:

```bash
codex --version
codex plugin marketplace list
codex plugin list --marketplace development-skills --json
```

If the marketplace is absent, stop and reconcile the installation method and
profile with the desktop's active skill path. An empty CLI result does not prove
that the desktop has no plugin. Do not silently add a marketplace, remove a
plugin, or reinstall to resolve a discrepancy.

Once that source/profile is confirmed, the supported snapshot refresh is:

```bash
codex plugin marketplace upgrade development-skills
```

Codex can refresh configured installed plugin files during marketplace refresh.
Inspect the resulting installed path/content before reloading the host. Then
restart the desktop at a suitable stopping point and start a new chat; verify its
active skill path/content. If the cache remains old, report it and reconcile
host configuration. There is no `codex plugin update` verb in the CLI verified
for this task. `codex plugin add PLUGIN@MARKETPLACE` is an installation command;
it is not evidence that an already-installed desktop plugin was refreshed.
See [OpenAI's plugin packaging documentation](https://developers.openai.com/plugins/build/plugins).

### Claude Code

Inspect the marketplace and the plugin's Installed view in `/plugin`, including
its scope. Refresh the listing, then explicitly update this installed plugin:

```bash
claude plugin marketplace update development-skills
claude plugin update remote-compute@development-skills
```

Use `--scope user`, `--scope project`, or `--scope local` when needed to select
the existing installation; inspect current help for managed installations.
Verify the installed copy changed. Apply it with `/reload-plugins` where
supported, or restart/start a new session (the verified CLI help requires
restart). A listing refresh alone and an already-running session are not proof
of loaded changes. See [Claude Code's plugin update documentation](https://code.claude.com/docs/en/discover-plugins).

## Back up before replacement

Finish running and reserved jobs and pause dispatch from every cooperating
client. Also stop services or other writers using the affected files; an idle
job table alone does not establish a consistent backup. Record command paths,
versions, shell PATH files, installed sources, and all client environment/job
definitions. Keep backups outside the directories being updated.

Preserve the complete target `~/.remote-compute/`, including `.identity`,
`.machine-id`, `caps/` and each `.installed.json` catalog, `runtime/`, `jobs/`
and artifacts. Preserve each client's actual `$COMPUTE_HOME` (default
`~/.remote-compute/`), including `resources.yaml`, receipts, and configuration.
Keep the original custom bundle source, manifests, scripts, workflows, models,
datasets, and any assets outside these roots too. A manifest-only copy is
insufficient. Symlinks require backups of their external destinations as well.
Back up the selected standalone prefix's `share/remote-compute` and launcher,
target command symlinks, and any shell files that `install-tools` can modify.

The following recipe archives one existing root. Set `UPDATE_STATE_ROOT` to its
absolute path and `UPDATE_BACKUP_DIR` to a new, external absolute directory.
Run it separately for each root on the machine that owns it. Check available
space first. These variables are inputs, not literal placeholder arguments.

<!-- recipe: backup-state -->
```bash
set -eu
: "${UPDATE_STATE_ROOT:?Set the existing state/source root}"
: "${UPDATE_BACKUP_DIR:?Set a new backup directory outside that root}"
python3 - "$UPDATE_STATE_ROOT" "$UPDATE_BACKUP_DIR" <<'PY'
import sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:])
if not source.is_absolute() or not destination.is_absolute():
    raise SystemExit("Use absolute source and backup paths")
if not source.is_dir() or destination.exists() or destination.is_symlink():
    raise SystemExit("Source must exist and backup destination must be new")
source, resolved = source.resolve(), destination.resolve()
if resolved == source or source in resolved.parents:
    raise SystemExit("Backup destination must be outside the source root")
PY
mkdir -p "$UPDATE_BACKUP_DIR"
tar -cpf "$UPDATE_BACKUP_DIR/state.tar" -C "$UPDATE_STATE_ROOT" .
tar -tf "$UPDATE_BACKUP_DIR/state.tar" > "$UPDATE_BACKUP_DIR/contents.txt"
```

Verify archive contents, ownership/modes and representative file checksums by
extracting into an empty staging directory using the recovery recipe below.
Retain off-machine copies where appropriate. This portable tar recipe preserves
ordinary files, modes and symlinks; use a filesystem-aware backup for additional
ACLs, extended attributes, sparse files, or application consistency requirements.

## Standalone controller

Run `type -a remote-compute` and `command -v remote-compute` in the shell that
will dispatch work. Inspect symlink/launcher destinations and environment
overrides (`REMOTE_COMPUTE_CONTROLLER`, `REMOTE_COMPUTE_TOOLS`,
`REMOTE_COMPUTE_ROOT`) before comparing `remote-compute version` and
`remote-compute controller version`. Resolve aliases or stale PATH entries.

Set `REVIEWED_SOURCE` to the absolute **plugin** directory containing `scripts/`
and `UPDATE_PREFIX` to the intended installation prefix (normally `$HOME/.local`).
Run this recipe in Bash with those variables exported and the backup complete:

<!-- recipe: install-controller -->
```bash
set -eu
: "${REVIEWED_SOURCE:?Set the reviewed remote-compute plugin directory}"
: "${UPDATE_PREFIX:?Set the intended standalone prefix}"
python3 "$REVIEWED_SOURCE/scripts/remote-compute.py" install-cli --prefix "$UPDATE_PREFIX"
"$UPDATE_PREFIX/bin/remote-compute" version
"$UPDATE_PREFIX/bin/remote-compute" controller version
```

The installer replaces the copied tree at `PREFIX/share/remote-compute` and
rewrites `PREFIX/bin/remote-compute`. It does not update an existing copy merely
because its source changed. Repeating installation converges that copied tree;
locally added files inside it are removed. Never store custom state there.
With an ordinary prefix layout, it does not touch the registry, `caps/`,
`runtime/`, or job history. Do not select a prefix whose replacement paths
contain state you need to retain.

Compare the installed controller/scripts against the reviewed files, then use
`hash -r`, `type -a remote-compute`, and `command -v remote-compute` to confirm
normal shell resolution. Use the explicit prefix path until it resolves
correctly. Inspect `controller --help` and legacy local commands such as
`local status JOB_ID` for an existing completed job. No workload is required
just to verify installation.
Current installers normalize shell scripts to LF in staging, so account for
that documented conversion when comparing shell-file hashes with Windows source.

## Target tools

Choose an already-registered nickname and inspect its identity and tool version
before updating. From the reviewed controller, run `remote-compute identity NICK`
and inspect `remote-compute doctor NICK --json`. On the target, record
`command -v remote-compute`, `remote-compute version`, and the existing
`.identity` and `.machine-id`; verify the expected host/account before mutation.

After backup and quiescence, run `remote-compute install-tools NICK` from that
controller. It ships `_shared/` into target `~/.remote-compute/tools/`, copies
controller scripts under `controller/`, installs the target command under
`bin/`, links `remote-compute` and `compute-top` in `~/.local/bin`, and converges
PATH entries in `.zshenv`, `.profile`, `.bashrc` and an existing `.bash_profile`.
It preserves the original nickname and stable UUID, adding a UUID for a legacy
target that lacks one, and updates client tool metadata.

`install-tools` does not install/update bundles in `caps/`, publish their
catalogs, download models, or configure environments. Its copied controller may
contain bundled source templates; those are not installed capability payloads.
Rerun target version/path/identity checks and doctor after installation. Confirm
existing completed job logs/artifacts and custom payload checksums still match.
Target tool deployment spans multiple steps and is not one atomic transaction.
Update every dispatching client for shared admission coordination; old clients
remain readable but do not acquire the newer coordination guarantees.

## Legacy custom catalogs

`capabilities installed [NICK]` reports the client's cached installation records;
`caps` on the target reports its local inventory. `capabilities sync NICK`
imports published jobs but leaves environment activation client-configured.
Use `envs NICK` and `add-env` on each client as needed; a catalog may refer to an
environment name without supplying an activation command. Sync replaces jobs
belonging to a published bundle, preserves unrelated custom jobs, and removes
cached bundle declarations absent from the target catalog.

A legacy directory without `.installed.json` is not a published catalog. Sync
preserves its existing client jobs and reports the legacy state. Treat a
diagnostic recommendation to reinstall as a prompt for this review, not as
permission to overwrite custom files.

1. Keep the complete backups above, including the original catalog (or its
   absence), registry, manifest, scripts, and all mutable assets. Retrieve the
   original custom source and compare it against the installed directory,
   including local changes. If its origin or needed files cannot be recovered,
   leave the legacy installation in place and report the missing evidence.
2. Review `capability.yaml`, job commands, parameters, environment names and
   every file to retain. Do not reinstall the built-in `comfyui` over a custom
   same-name bundle. Use the reviewed custom directory, or a trusted GitHub
   bundle pinned with `--ref` to the reviewed commit; retain resolved provenance.
3. The installer stages the manifest and declared `payload` files, then replaces
   the `caps/NAME` directory under the target coordination lock. Current reviewed
   source can also carry forward explicitly declared `preservePaths`, as
   described below. Files neither supplied as payload nor explicitly preserved
   can disappear, including models, workflows, venvs, outputs and custom scripts.
   The predecessor is deleted after success; there is no retained rollback copy.
4. Decide how each file survives. Include immutable scripts/workflows as real
   files/directories under `payload` in the reviewed source. Absolute paths,
   parent traversal and symlinks are rejected. Payload files are checksummed:
   copying mutable state into the payload can cause later doctor drift warnings.
   For mutable assets, choose reviewed `preservePaths` with supporting source,
   or a separate runtime directory outside `caps/NAME`, with its own backup.
   For the latter, update and test custom code/config to use that path before
   reinstalling. There is no automatic relocation to an external runtime root;
   a venv or application with absolute paths may require recreation/reconfiguration.
5. Validate with `remote-compute capabilities validate /absolute/reviewed-bundle`.
   After the reviewed backup/relocation plan is verified, run
   `remote-compute capabilities install NICK /absolute/reviewed-bundle`.
   Supply `--env NAME` only for a reviewed default. Do not run this command with
   the example path unchanged. Validation checks structure, not workload readiness.
6. Compare the published `.installed.json`, payload hashes and intended jobs;
   run `capabilities sync NICK` separately from every registered client that needs
   the catalog. Verify `jobs NICK`, `envs NICK` and doctor on those clients.

### Reviewed runtime preservation and local repositories

Commit `b0d84d3` added `preservePaths` and local repository bundle selection.
Both pre-feature source and this feature's CLI report `0.2.0`; inspect the
reviewed commit and installed controller/helper files rather than using that
version string as a feature check. With older controllers, do not rely on
`preservePaths`: unknown manifest fields may be ignored, leaving the usual
replacement behavior. `remote_state` sends the controller's helper inline, so
updating only the target command cannot fix an older installing controller.

For example, merge this fragment into the reviewed custom manifest whose
`models/` and `runtime/` already live inside `caps/NAME`:

```yaml
payload: [custom.py, workflows]
preservePaths: [models, runtime]
```

The named top-level roots must be unique safe single path components, must not
be symlinks, and must not overlap the managed payload, `capability.yaml`, or
`.installed.json`. Existing roots are moved into the replacement directory
while the target lock is held, retaining their absolute paths (including venv
shebang paths). Missing roots are not created or provisioned. They are not
managed/checksummed payload; back up and verify their content separately.
The manifest and new jobs are still published together for client sync.

This option does not preserve everything automatically, relocate external
assets, or remove the need for a complete backup. Unlisted and unpreserved
content is still replaced. Ordinary filesystem failures attempt to move roots
back and restore the prior directory; a process/host crash can leave partially
moved roots and `previous-*` staging data. Preserve that evidence and recover
matching state before resuming writers; this is not a crash-journaled transaction.
Do not purge a capability to update it: purge deletes retained runtime too.

Current source also accepts
`remote-compute capabilities install NICK /absolute/reviewed-repository NAME`
or `--all` in place of `NAME`. Discovery validates bundles before installation;
each bundle installs separately, so a batch may partially succeed. Prefer the
single reviewed bundle when updating a legacy custom installation. Local source
is a snapshot, not a live symlink; provenance records the resolved directory,
bundle path, and Git revision/dirty state when available. Local repositories do
not accept `--ref`: select and review the local checkout first. Older controllers
can still take a direct bundle directory through the legacy `install-capability`
form, but must not be used for a manifest that depends on `preservePaths`.

Doctor is diagnostic. An installed bundle is not a ready workload, and a green
doctor cannot establish every model, dataset, credential or service prerequisite.
Inspect those explicitly. When available, use a suitable declared smoke job
with concrete validated parameter values and verify its exit code and output.
Missing models/dataset are not healed by a CLI update. Never invent an ad-hoc
raw dispatch for an outcome request, or claim an unreachable target was tested.

## Recovery

Restore trusted backup archives to a new staging directory first. Set
`UPDATE_STATE_ROOT` to the original live root, `UPDATE_BACKUP_DIR` to the chosen
backup and `UPDATE_RESTORE_DIR` to a new absolute path outside both. All paths
must be absolute. These recipes resolve parent symlinks and refuse relative
paths, destinations within protected roots, and existing destinations including
broken symlinks before creating directories.

<!-- recipe: restore-staging -->
```bash
set -eu
: "${UPDATE_STATE_ROOT:?Set the original live state/source root}"
: "${UPDATE_BACKUP_DIR:?Set the chosen backup directory}"
: "${UPDATE_RESTORE_DIR:?Set a new empty recovery destination}"
python3 - "$UPDATE_STATE_ROOT" "$UPDATE_BACKUP_DIR" "$UPDATE_RESTORE_DIR" <<'PY'
import sys
from pathlib import Path
live, backup, destination = map(Path, sys.argv[1:])
if not all(path.is_absolute() for path in (live, backup, destination)):
    raise SystemExit("Use absolute live, backup and recovery paths")
if destination.exists() or destination.is_symlink():
    raise SystemExit("Recovery destination must be new")
resolved = destination.resolve()
for protected in (live.resolve(), backup.resolve()):
    if resolved == protected or protected in resolved.parents:
        raise SystemExit("Recover outside the live root and backup directory")
PY
test -f "$UPDATE_BACKUP_DIR/state.tar"
mkdir -p "$UPDATE_RESTORE_DIR"
tar -xpf "$UPDATE_BACKUP_DIR/state.tar" -C "$UPDATE_RESTORE_DIR"
```

Compare restored files byte-for-byte, including original custom sources,
catalogs, registry, identity, workflows and mutable assets. With all writers
still stopped, preserve the failed installation separately and restore the
reviewed matching roots to their original locations. Restore catalog and
payload together, and restore affected client declarations from the same
checkpoint. Do not overlay an archive on a live tree: new files can survive an
overlay and leave mixed versions. A pre-publication restore correctly returns
the bundle to legacy status; do not immediately sync away restored declarations.

For controller-only rollback, reinstall from the prior reviewed source or restore
its copied tree and launcher together. For target tooling, also reconcile command
symlinks and backed-up shell PATH files. Neither installer is a package manager
with a general rollback command. Internal recovery handles ordinary replacement
errors (including runtime moves in current source), not crashes across all steps
or later workload failures.

Do not restore an old whole-state snapshot after new jobs have run without first
reconciling their receipts, reservations, artifacts and immutable IDs. Rolling
back tools cannot undo workload side effects, external downloads, or changes
outside the backup. Preserve newer job history before any such recovery.

## Verification evidence

As of 2026-10-11, read-only verification found the WSL and `storm590x` on-machine
commands still at `0.1.0`. The desktop advertised an active skill path under
`C:/Users/<user>/.codex/plugins/cache/development-skills/remote-compute/0.1.0/skills`;
its adjacent `.claude-plugin/plugin.json` also said `0.1.0`. Windows
`codex-cli 0.144.4` returned empty installed/available arrays for the named
marketplace, while its marketplace list contained only OpenAI marketplaces and
no `development-skills`. That discrepancy remains unresolved here. No host
update, target deployment, silent marketplace add, or production upgrade was
performed. A cache can remain older until the correct host operation occurs.

Host syntax above is based on read-only CLI help verification and the linked
official documentation, accessed 2026-10-11. Host refresh/reload behavior was
not exercised against a real installation by these tests.

The local `InstalledUpdateTests` in
[`test_hardening.py`](../plugins/remote-compute/tests/test_hardening.py) execute
the marked recipes in disposable HOME/COMPUTE_HOME/prefix directories, including
paths with spaces. They repeat real controller and target-tool installation,
substitute local Bash/rsync for transport, preserve legacy identity/jobs and
custom assets, exercise custom publication and sync, and recover complete
archives into staging with byte comparisons. This covers local installer and
recovery mechanics, not an actual historical binary upgrade or remote SSH.
The local repository rehearsal also preserves declared runtime bytes, inodes
and paths across repeated installs using the broker/publisher from `b0d84d3`;
the default-replacement rehearsal still demonstrates loss of unpreserved content.
No model downloads, live registry, auth files, or managed plugin caches are used.
macOS, live SSH, host reload and real model/dataset smoke jobs remain unverified.

Run locally from the repository root:

```bash
python3 plugins/remote-compute/tests/test_hardening.py InstalledUpdateTests -v
bash plugins/remote-compute/tests/run-tests.sh
```

Run suites sequentially. Repository integration and the full gate remain a
separate review responsibility; this guide does not change that gate.
