---
name: remote-compute
description: Registers remote machines (SSH, key-only) as user-level compute resources and advertises their availability to projects, capability-style -- register probes GPU/RAM/disks/envs and converges the machine to a consistent, verified setup; enable writes a non-exclusive availability entry (with an informational snapshot) into the repo's gitignored project.local.yaml overlay, and many projects may enable the same machine. Also list/status/probe, one-off exec, cooperative lock/unlock, detached dispatch with file-recoverable job state, and per-platform setup sheets. Use for 'register this machine as a compute resource', 'make gpubox available to this project', 'dispatch a training run', or 'is the GPU box up'.
---

# remote-compute

Registers machines the human owns as compute resources (user-level registry
`~/.claude/compute/resources.yaml`, machine-local, never committed) and
advertises them to projects (a `compute:` section in `.claude/project.local.yaml`
— the gitignored machine-local overlay; alias + informational capability
snapshot only, never host/user/secrets, and never the committed project.yaml).
Availability is capability-style and NON-exclusive, mirroring how
`assistant.capabilities.NAME.enabled` works: many projects may enable the
same machine; the machine-local cooperative lock is what serializes actual
use, never the project declaration.

Design: `docs/design/remote-compute-plan.md`. This is the human
dev-workflow layer; it implements nothing of SPEC-ASSISTANT §14/E7 and must
never be cited as satisfying any §14 requirement.

All verbs go through the one script (run it with python3):

```bash
python3 "../../scripts/remote-compute.py" register gpubox testuser@192.0.2.17
python3 "../../scripts/remote-compute.py" enable gpubox --root "$(git rev-parse --show-toplevel)" --role training
python3 "../../scripts/remote-compute.py" list
python3 "../../scripts/remote-compute.py" exec gpubox -- nvidia-smi
python3 "../../scripts/remote-compute.py" dispatch gpubox --workdir "~/train" --cmd "python train.py" --env fab-training
python3 "../../scripts/remote-compute.py" job-status j20260802 ; # also: job-logs, job-pull
```

**Bare invocation** (no arguments given): run `list`, show the result, and ask
the human which verb they want. Never guess a nickname.

## register (converge, not one-shot)

`register` converges a machine to one declared end-state and is safe to re-run
any time — every run re-verifies the full checklist (ssh alias, key auth under
BatchMode, pinned host key, capability probe, remote `~/.compute-jobs/`
layout). Drive its stop-and-resume statuses like this:

- `UNREACHABLE` (exit 1): the machine is off/asleep or sshd is not listening.
  Print the matching platform sheet (`setup-sheet wsl2|linux|macos`) and relay
  it to the human; retry when they say it is up.
- `NEEDS_HOSTKEY_ACK` (exit 4): show the human the printed fingerprint, ask
  them to confirm it matches the machine, then re-run with `--accept-hostkey`.
  Never accept a host key the human has not acked.
- `NEEDS_KEY_AUTH` (exit 3): relay the printed `ssh-copy-id` line for the
  human to run themselves (it prompts for their password — this skill never
  handles passwords), then re-run register when they report success.
- Exit 0 prints `REGISTERED` plus a summary table — relay the table, and if it
  notes the power policy is unconfirmed, ask the human to confirm the machine
  never sleeps on AC (then it can be recorded in the registry's policy block).

Registration is user-level only — it never touches any repo.

## enable / disable (availability, not allocation)

Run inside a repo with `.claude/project.yaml` (pass `--root` explicitly).
`enable` re-probes the device live, then rewrites the `compute:` section
idempotently — a map keyed by alias with `{enabled, roles, probedAt,
capabilities}` — in `.claude/project.local.yaml` (gitignored machine-local
overlay, created if missing; the committed `project.yaml` is never touched).
Reads go through `config.py`, which merges the overlay's `compute` key over
the committed config. Tell the human the resource is now available to this project
(non-exclusive — other projects may enable it too) and that tasks can
reference it by alias or role. `disable` keeps the entry with
`enabled: false`, like a disabled capability. Snapshots are informational —
anything doing real work re-probes first.

## Hard rules (the script enforces these; do not work around them)

1. Key auth only; `BatchMode=yes` on every ssh call; never prompt for, store,
   or transmit passwords.
2. Never run sudo, locally or remotely — sudo payloads are rejected (exit 5);
   privileged steps are printed as instructions for the human.
3. Probes are read-only; dispatch writes only inside the declared workdir and
   `~/.compute-jobs/`.
4. Every capability claim comes from real probe output; failures are recorded
   verbatim in the registry, never guessed.
5. No dispatch to a resource locked by someone else (exit 6); `unlock --force`
   warns with the prior holder's context.
6. `~/.claude/compute/` is machine-local and never committed; the repo gets
   alias + snapshot only.

## declared jobs — dispatch by intent

A resource can declare NAMED jobs (`add-job`): a command template plus a regex
per `{param}` — the same stance as `capability.yaml` invoke (schema-validated
substitution into a pre-authored template; substituted values are always
shell-quoted; sudo templates rejected). When the human asks for an OUTCOME
("generate a 3d duck", "run a training epoch"):

1. Check which resources this project has enabled (`config.py ROOT get
   compute.resources`), then read each candidate's roster with `jobs NICKNAME`.
2. Pick the declared job that matches the intent and `run NICKNAME JOBNAME
   --param name=value`; follow with `job-status` / `job-logs` / `job-pull`.
3. If NO declared job matches, refuse honestly and name the nearest declared
   jobs (never improvise a raw command for an intent-level ask — `exec` and
   `dispatch --cmd` are for the human explicitly dictating a command).

## capability bundles (how domains plug in)

The engine is domain-agnostic: it knows machines, envs, jobs, and transport,
and nothing about any particular tool. A DOMAIN arrives as a **bundle** under
`scripts/remote-capabilities/<name>/` — a `capability.yaml` manifest
(`{name, description, payload[], jobs{}}`) plus the payload scripts its jobs
invoke. `install-capability <nick> <bundle-dir>` rsyncs the payload to
`~/.compute-jobs/_caps/<name>/` and declares the manifest's jobs as
`<name>:<job>`; `capabilities <nick>` lists what a machine has.

Adding a new domain means adding a bundle — never editing `remote-compute.py`.
Templates may use `{capdir}` (installed payload dir) and `{jobdir}`; every
other placeholder is a validated job param. Use both placeholders BARE — they
already expand to a safely quoted path (`"$HOME"/'...'`), so wrapping one in
your own quotes (`--out "{jobdir}/sub"`) produces broken nesting. Bundle command templates are
sudo-checked at install time.

The shipped `comfyui` bundle documents its own rules in its manifest; the one
that matters generally: a bundle must invoke PRE-AUTHORED artifacts and change
only input values, never compose executable structure (workflow graphs,
pipelines) from model output. A real end-to-end walkthrough lives in
`tests/e2e-remote-compute-manual.sh` (manual, network-touching — deliberately
not part of the hermetic gate).

## naming artifact jobs

For jobs that PRODUCE artifacts (images, video, models), let the capability
name the run: omit `--job-id` and the bundle's `jobIdSchema` builds one. The
shipped comfyui bundle uses `img-{model}-{seed}`, so a render lands as
`img-waiillustrioussdxl-v150-129381729381723211`.

The shape matters because artifacts outlive the session that made them:

- a stable **prefix** says what kind of run it was (`img-`, `vid-`),
- the **model slug** says which checkpoint produced it,
- the **seed last** makes a batch sort together and makes any single output
  reproducible from its id alone.

A bundle declares it in `capability.yaml`:

```yaml
jobIdSchema:
    template: "img-{model}-{seed}"
```

Any `{param}` of that job may appear in the template; values are slugified, so
the id is always filename- and shell-safe. An explicit `--job-id` always wins.
Recommend the schema-derived id when the human is generating artifacts, and
reserve hand-written ids for one-off experiments.

## dispatch and jobs

`dispatch` takes the cooperative lock, syncs `--inputs` (rsync), launches the
command detached on the remote (tmux, else setsid nohup) writing `job.log`,
`pid`, and `exitcode` under `~/.compute-jobs/JOBID/`, and records
`~/.claude/compute/jobs/JOBID.json` locally. State is recoverable from those
files alone — `job-status` works after any restart and releases the lock once
the job has an exitcode. `job-logs` tails the remote log; `job-pull` rsyncs
artifacts back.

## Watching work on the machine itself

`scripts/remote-capabilities/_shared/compute-top.py` is a terminal dashboard
the human runs ON the compute machine (stdlib only, no install):

```bash
python3 ~/.compute-jobs/_tools/compute-top.py        # live, refreshing
python3 ~/.compute-jobs/_tools/compute-top.py --once # one snapshot, pipe-friendly
```

Arrow keys navigate, enter opens a job's log tail with its exit code, `f`
filters (all/running/finished/failed), `d` removes one job from history (never
one that is still running), `D` purges finished jobs. Ship it alongside a
capability payload with the same rsync `install-capability` uses, or tell the
human the one-liner above once it is present.

## Rules

- Relay script output faithfully — especially LOCKED refusals, verbatim probe
  errors, and the setup sheets; they are written for the human.
- Prefer the verbs over hand-editing `~/.claude/compute/resources.yaml`: the
  script writes envs (`add-env`), jobs (`add-job`), capabilities
  (`install-capability`) and availability (`enable`). `policy.*` is the one
  block with no verb yet, so power-policy confirmation and
  `maxConcurrentJobs` are hand-edited today.
- A hand-edited `activate` line is still re-checked for sudo when a job
  dispatches, so editing the file cannot smuggle privileged commands past
  hard rule 2.
- `remove` unregisters only — it never touches the remote machine and leaves
  the ssh alias in place (say so when you use it).
