# Runtime path inventory — task #274

Scope: the four shipped plugins at base `334d1ff`, with task #274 changes.
The companion [per-file coverage inventory](runtime-paths-274.tsv) records every
tracked file under `plugins/`, including hidden plugin metadata, skill references,
generated templates, browser scripts, remote capability payloads, and test fixtures.
The inventory contains 481 files (spec-workflow 387, remote-compute 52, peer-review 28, scaffold-project 14); see the TSV for exact membership.
Of these, 275 are verification files/fixtures and 192 are non-fixture scripts, skills, references, templates or payloads.
Each row names its disposition and the source family below. This is a bounded
source audit, not a static analyzer or a guarantee about arbitrary user commands.

Method: enumerate with `git ls-files plugins`, inspect the scripts and skill
instructions, search writes/renames/locks/temp allocation/subprocess redirections,
then follow path constructors, config defaults, and delegated writers. In
particular, a read of `.claude/tmp/similar-issues.json` is not evidence of a writer:
`find-task` and `create-inbound` actually pass a private `mktemp` file. Browser
storage and stdout are not repository files. Tests and evaluation fixtures are
listed but excluded from consumer defaults. No brain contents were read.

## Repository runtime families

Policy comes only from `scripts/local-state.manifest`; the descriptions here
explain coverage and are not a second renderer. Paths are relative to the consumer
root unless stated otherwise. `ignore` entries for derived files take precedence
over a containing `track` directory. Existing directory entries cover descendants.

| ID | Source sites and path resolution | Policy and disposition |
| --- | --- | --- |
| SW-control | `skills/checkpoint/SKILL.md`, `checkpoint.py:checkpoint_path`, `ui-mode.sh`, `gate.sh`, `merge-mode.sh` | Existing ignore paths cover checkpoint/UI flags, gate-pass, lessons, and merge-requirements. Checkpoint resolves relative paths against the primary checkout. Custom checkpoint paths are consumer policy. |
| SW-board | `board.sh:_cache_put/_cache_drop/_cache_refresh_from_items`, `show`; `board-queue.sh:QUEUE_FILE/QUEUE_LOCK_DIR`, `_queue_lock_acquire`, `_wip_lock_acquire`, `_flush_*` | Existing ignore entries cover queue JSONL, comments-seen, board cache, WIP lock and `.flush*` siblings. **Added** `.claude/board-queue.lock/` (including pid) and `.claude/board-cache.json.tmp`. Comments-seen writes directly, so no invented `.tmp` path. The configurable test barrier directory (`BOARD_QUEUE_TEST_BARRIER_DIR`) is a fixture seam, not a runtime default. |
| SW-events | `telemetry.py:telemetry_path/record`, `telemetry_lock.py:telemetry_lock/append_jsonl`, `review_rounds.py` callers, `gate.sh` | Existing ignore telemetry JSONL/lock and lessons cover review/gate events. stdout-only metrics and diff-symbol extraction add no file. |
| SW-brain | `brain.py:brain_dir/notes_dir/links_path`, `_atomic_write`, `brain_lock`, `activation_path`, outcome/event writers, retro/directory/entity-index/consult operations; `kb-seed.py` | Existing tracked identities tree covers notes, links, activation/outcomes/consults, media, DIRECTORY, entity-index and retros.log; tracked brain-events covers per-writer shards. **Added ignore** persistent identities `.brain.lock` and `**/.brain-tmp-*` atomic siblings. These are exceptions, not a reason to ignore shared brains. Existing index.sqlite3 and staleness cache remain ignored; **added** exact SQLite journal/WAL/SHM siblings. SQLite currently uses its default rollback journal, with WAL/SHM reserved to the same derived database family. Legacy brain-events.jsonl is read as history, never appended; do not revive old `.claude` paths. |
| SW-feedback | `feedback.py:DEFAULTS`, `_shard_dir`, `emit`, `route`, `_atomic_write_bytes`, `archive` | Existing tracked `.neural-network/feedbacks/` covers feed YAML, writer shards and monthly archives. **Added ignore** `**/*.yaml.tmp-*` within that directory, covering feed/archive atomic siblings. Override feeds remain consumer responsibility. |
| SW-ui | `ui-hub.py:S/HTML/INBOX/OUTBOX/ARCHIVE`, `ensure_dirs/start/ask/answers`; `skills/ui-options` | Existing `.claude/ui-hub/` ignore covers pid, port, server.log, live HTML, incoming/outgoing decision JSON and consumed archives. There is no separate repository default called `decision-hub/`. UI_HUB_STATE overrides are caller-owned. |
| SW-neural | `neural-view.py:state_dir`, `ensure_dirs`, `ensure_process_name_link`, `ensure_marker`, `start/serve`; `assistant/default_store.py`, `selection_store.py`, `preflight.py` | Existing `.claude/neural-view/` covers pid/port/server.log, repos.json, interpreter symlink under bin, assistant default/selection/cache files and their atomic siblings. State defaults to the primary checkout. `.neural-network` discovery marker is a directory, not a file to blanket-ignore. NEURAL_VIEW_STATE is caller-owned. |
| SW-assistant | `assistant/store.py`, `tasks.py`, `observability.py`, `harness.py`, `artifacts.py`, `comfyui_render.py:_publish`, `remote_audit.py` via task/trace stores | Existing `.claude/assistant/` ignore covers session JSON/JSONL, tasks/traces SQLite and sidecars, task results/logs/audit descriptors/recovery records, artifacts and temporary publication files. `.harness-output.log` lives inside an isolated `harness-job-*` temporary workdir, not the consumer root. Engine media/chat output is tracked under identities; **added ignore** its `.publish-tmp-*` sibling used by `adapters.py:publish_files` on cross-device publication. |
| SW-setup | `assistant/setup.py:_lock_path/_atomic_write_text/_atomic_write_bytes`, `ensure_project_yaml_assistant`, `ensure_agents_md`, `ensure_base_capabilities` | Existing tracked project.yaml and identities cover durable config/persona memory; AGENTS.md is project source. Existing whisper-sidecar installation ignore covers copied files and their temp siblings. **Added ignore** `.claude/.setup-assistant.lock`, root `/.setup-assistant-tmp-*`, and `.neural-network/.setup-assistant-tmp-*`. Other setup temporary files fall inside already ignored installed skill/state directories. |
| SW-cap-installs | `assistant/remote_control.py:install`, `assistant/comfyui_render.py:install` | **Added explicit ignore** `.claude/skills/remote-compute-control/`, `.claude/skills/comfyui-render/` and their `.remote-control-*` / `.comfyui-*` staging directories. Installed manifests bind absolute machine interpreter/engine paths and user-reviewed host provisioning. They are local installations, not blanket ignores for user-authored skills. |
| SW-config | `config.py:set_value`, `init-config.sh`, `concurrency.sh`, `merge-mode.sh`, setup/migration/config skills and templates | Existing tracked project.yaml and specs directory cover workflow configuration and work plans. Legacy project.json remains accepted and is durable project config, not newly ignored. Explicit PROJECT_CONFIG, subproject fragments and migration backup destinations require consumer policy. Config schemas/templates themselves are shipped source, not runtime caches. |
| SW-docs | `handoff/SKILL.md`; `implement-task/references/design-and-deltas.md`; `refine-task-ui`, `ui-options`, `design-registry.py:_sidecar_path/_archive_path/_archive_live_page/_write_meta` | **Added track** docs/handoffs, docs/design, docs/spec-deltas (including applied), docs/ui-options (HTML, metadata JSON, screenshots). These are shared review/session artifacts. This repo's outside-block docs/handoffs ignore is deliberately preserved and produces the existing track-conflict warning. Configured paths.handoffDir/designDir/specDeltaDir and DESIGN_REGISTRY_ROOT remain consumer choices. |
| SW-worktrees | `implement-task/SKILL.md`, `build-next/references/concurrency.md`, `sync-configs.py:process_repo` | Existing `.claude/worktrees/` ignore covers implementation worktree remnants. Merge dance lock already ignored. Sync-configs uses `tempfile.mkdtemp(prefix="sync-configs-wt-")`, cleans through its finally path, and uses git's own metadata; no fixed consumer path to ignore. |
| SW-sync | `gitignore-sync.sh`, `preflight.sh`, `sync-configs.py:mem013_gitignore_detect/apply` | One manifest renderer writes only the managed block. Dry-run uses a private `${TMPDIR:-/tmp}/gitignore-sync.*` directory, cleans it on ordinary exits and handled INT/TERM/HUP, and reports read/render/compare/publish errors. Preflight captures validator/helper output in memory. **No** `tmp.*` ignore: that would conceal unrelated user files. Neither helper sweeps user temp files, nor promises SIGKILL/power-loss cleanup. |
| RC-overlay | `remote-compute.py:_project_cfg_path/_write_compute_section` | Existing ignore `.neural-network/project.local.yaml`; **added ignore** `.neural-network/.project.*` atomic staging siblings. This is the remote controller's repository-local default write. |
| SW-changelog | `changelog.py:generate`, `changelog.sh`; changelog skill | CHANGELOG.md is generated versioned project source. **Added ignore** `/CHANGELOG.md.tmp` from the Python writer. Shell generator uses private mktemp bucket/output files. `--output` destinations are caller-owned. |

No broad `.claude/`, `.neural-network/`, `*.tmp`, `tmp.*`, `*.log`, or whole
identities-tree ignore was introduced. Existing user rules outside the managed
block are byte-preserved, including CRLF and a missing final newline.

## Explicit exclusions and delegated writes

| ID | Sources | Resolved outputs and reason no consumer manifest entry applies |
| --- | --- | --- |
| EXT-temp | `mktemp` in peer-review run/claude-run, provider review stdout/stderr, diff-source; spec-workflow board/init-config/seed-board/gate/changelog, find-task/create-inbound snippets; assistant claude/codex adapters and harness | Private platform temp files/directories (or TMPDIR). Provider outputs are returned to stdout; there is no fixed peer-review report in the consumer. Adapter homes/workdirs include CLI-owned caches and copied authentication and are cleaned by their wrappers. This audit does not extend #274's signal-cleanup guarantee to every unrelated wrapper. If a caller redirects output or sets TMPDIR inside a repo, they own that destination; generic temp-file ignores would hide arbitrary files. The sync helper is explicitly tested for this override. |
| EXT-cap | `capability.sh:resolve_dir/install_embeddings`, `lib/capability-embed.py`; `whisper_sidecar.py:state_dir/install/start` | Default `$HOME/.claude/capabilities/embeddings` contains venv/model/embed.py/manifest and `.part` downloads; whisper defaults to `$HOME/.claude/whisper-sidecar` with binary/model/pid/log. Neither is repo-relative. --dir, CAPABILITY_HOME and WHISPER_SIDECAR_STATE_DIR overrides are caller-owned, including examples installing into a repo. No implicit `.claude/capabilities/` repo ignore. |
| EXT-remote | `remote-compute.py:compute_home/registry_path/jobs_dir`, register/scan/install-cli/install-tools/capability install/sync; remote skills | Controller defaults to `~/.remote-compute/`: resources.yaml, registry/controller locks, controller ID, job receipts and `.job.*`/`.resources.*` staging. SSH config/known_hosts and `.kh-scan.*` temporary files are user-machine state. Target `~/.remote-compute/` contains identity, jobs, caps, tools/bin/controller packages/staging and policy. CLI launchers under ~/.local/bin and prefix/registry/home overrides are external or caller-selected. `job-pull` has an explicit destination. |
| EXT-target | `remote-capabilities/_shared/compute-state.py`, remote command and dashboard; both capability.yaml recipes; comfy-run/import and all slm-training payloads | Recipe outputs resolve `{jobdir}`/COMPUTE_JOB_DIR on the target: record.json, job.log, pid, exitcode, cancellation JSON, inputs/workdir; `.state.lock`, `.write-*`/`.exit-*`; API workflow JSON, Comfy images; trainer-state/adapters, train-summary, eval report, gpu report, GGUF/export summary and converter downloads/caches. Comfy import writes `.comfy-import-*` beside required --output and publishes exclusively. Offline/manual CLI --out/--output or cwd fallback are caller-chosen generated artifacts, not a universal consumer default to ignore (e.g. ignoring adapters/ would conceal source). Dashboard pruning deletes target job history; it adds no repository default. |
| EXT-scaffold | scaffold-project skill, package-json reference, all ten shell templates | Generates versioned scripts/ and package.json; consumer-specific manifests/env/build commands are project source. common.sh sets STATE_DIR to `/tmp/{{PROJECT_NAME}}`, mkdir pf; port-forward writes port-forward.pids there. PROJECT_STATE_DIR is an explicit override. minikube, kubectl, Docker and package build subprocesses own external cluster/images/tool caches or project-defined build outputs, not a fixed plugin runtime family. |
| SRC-docs | craft-spec and its spec-guide/host reference, setup-project host/GitHub references, setup-assistant persona, semver, migration instructions | Canonical specs (`SPEC.md`, `specs/<id>.md`, selected filename), docs/BACKLOG-<ID>.md, AGENTS.md/CLAUDE.md, settings/hook configuration, copied ROLE.md templates, plugin/package version metadata, and migration backup copies are durable generated project source. Their explicitly selected content/locations are reviewed and committed; adding blanket `specs/`, `docs/`, `scripts/` or configuration ignores would be wrong. Stable workflow memory directories have separate track entries above. Git commits/worktree metadata live in Git's administrative directory. |
| EXT-browser | templates/neural-view.html, templates/ui-options.html; scripts/vendor/axe.min.js and templates/vendor/* | localStorage (`nv-ui`, UI language/theme) is browser profile data; rendering/Three/Mermaid/axe operations are in-memory browser work. Server-side decision writes are SW-ui/SW-docs, not browser filesystem writes. Vendored JS and vendor README are shipped source, not runtime files. |
| READ | Guards/preflights, path/identity/config parsers, validation/schema/snippet linters, board selection/ranking/audit helpers, provider listings, capability discovery/provisioning and transport readers | Read local files, return stdout/HTTP/pipe output, or invoke named writers accounted for above; they introduce no additional default file family. preflight's assistant cache is explicitly SW-neural. Remote cancellation invokes EXT-target's writer and engine audit SW-assistant. |
| FIXTURE | Every tests/ and evals/ entry in the TSV; scripts/e0-smoke-manual.sh and assistant/gates.py | Hermetic fixture roots, fake CLI logs, temporary homes, target/payload tests and caller `--out` gate reports are verification artifacts. Not consumer runtime defaults. Python `__pycache__`/bytecode are interpreter build caches under the installed code tree; consumer source repos own language/tool ignores, not a cross-plugin blanket rule. |

## Findings and verification

The sweep adds 18 narrow ignore patterns and four tracked artifact directories.
The known `.staleness-cache.json` entry already existed; detection, rather than
another copy of that rule, prevents its next drift. The persistent `.brain.lock`
was already tracked in this repository; remove it from the Git index only,
without unlinking a potentially live lock inode. Future consumers should likewise
review and untrack already committed local state explicitly: ignore rules never
remove existing index entries.

Committed RED evidence: `26062dd` exercises actual helper/preflight behavior
(13 failures across eight methods) and initial manifest changes (four failures).
`1ea92c3` separately pins mem013 helper error propagation (one failing test method).
`d2854c7` and `b9ea59d` extend the manifest expectations for later verified
atomic-staging and durable-document findings before their implementation.
The legacy fixture's attempted `commands` overlay was corrected to `compute`
because config.py only overlays that allowlisted key; the test now exercises
invalid compute roles through the existing validator instead of inventing overlay
semantics. Direct invalid commands.gate remains covered in both modes.

`9d3c414` adds a failing unreadable-manifest case; the bash reader now propagates read/open failures instead of returning an empty successful policy list.

Tests cover missing/stale/current blocks, valid legacy config, invalid base and
local overlay config in both modes, silent successful validation, no automatic
repair, mem013 convergence, diff errors, malformed targets/markers, failed
publication, INT/TERM/HUP cleanup with TMPDIR inside the repo, byte preservation
and track warnings. Full required gate and independent spec/quality reviews are
owned by the task orchestrator before completion.
