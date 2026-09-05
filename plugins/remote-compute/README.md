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
| `compute-top` | Terminal dashboard (stdlib curses), locally or over SSH, for what a compute machine is doing. Script: `scripts/remote-capabilities/_shared/compute-top.py`. |

## Capability bundles

`scripts/remote-capabilities/` — installable per-machine bundles: `comfyui/`
(ComfyUI txt2img dispatch), `slm-training/` (GPU check, training, GGUF export,
eval suite). Each carries a `capability.yaml` manifest.

## Tests

`bash plugins/remote-compute/tests/run-tests.sh` — hermetic (scripted fake ssh
transport, no network ever). The suite reaches into `plugins/spec-workflow`
for `config.py`/`validate-config.py`/fixtures — the same direction as the
plugin's declared dependency. `tests/e2e-remote-compute-manual.sh` is the
deliberately-unregistered manual end-to-end against a real machine.
spec-workflow keeps its own `section-compute-overlay.sh` proving the overlay
machinery with a hand-crafted `compute:` section (the contract seam's other
half).
