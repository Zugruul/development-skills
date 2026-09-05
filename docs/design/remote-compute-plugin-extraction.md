# Study: extracting remote-compute into its own plugin

Status: ACCEPTED WITH FIXES (adversarial review verdict: EXECUTE WITH FIXES — folded in below). Implemented on feat/neural-network-layout.

## Adversarial-review fixes folded in

1. **Standalone posture: remote-compute REQUIRES spec-workflow.** The skills invoke
   spec-workflow's `config.py` for overlay reads, `enable` refuses to run outside a
   `.neural-network` repo, and the `project.local.yaml` gitignore machinery is
   spec-workflow's. Declared explicitly in the new plugin's README, plugin.json
   description, and both SKILL.md files — no standalone re-engineering.
2. **Test split honestly stated**: the enable→config.py/validate-config.py round-trip
   integration test STAYS in spec-workflow (new `section-compute-overlay.sh`), invoking
   the new plugin's `remote-compute.py` cross-plugin (fine: declared dependency, same
   repo). The moved suite crafts its own minimal project.yaml inline instead of
   duplicating `valid.project.yaml`; the `compute/` + `stub-compute-transport/` fixtures
   move with it.
3. **Codex posture decided**: the two skills are CLI-driven and provider-agnostic —
   declared Codex-covered; `section-codex-skill-lint.sh` and `section-codex-plugin-json.sh`
   hardcoded plugin loops extended, `.agents` marketplace entry added deliberately.
4. **Registry/governance**: `.neural-network/project.yaml` gains a `docs:` entry for
   `plugins/remote-compute/**` → its README; gate extended with the new suite +
   `claude plugin validate` (CI's `plugins/*` globs pick it up automatically — the two
   surfaces diverge and that's now documented). No auto-semver for the new plugin (same
   as peer-review/scaffold-project).
5. **Lint parity in the new suite**: py_compile over all its `.py` (fixing the
   pre-existing gap — nothing byte-compiled remote-compute.py before), snippet-lint via
   spec-workflow's `snippet-lint.py`, and the "no `bash foo.py`" grep.
6. **CHANGELOG step dropped** (generated file); `remote-compute-plan.md`'s one hard path
   updated; SPEC-PEER-REVIEW's unrelated "remote-compute layer" naming noted in the new
   README to avoid confusion.

## Verdict

Feasible and low-risk. remote-compute is already near-standalone: stdlib+PyYAML only,
no imports from spec-workflow's scripts, no other skill references it, and its state
lives outside the plugin tree (`~/.remote-compute`, plus the `compute:` overlay in the
target repo's `.neural-network/project.local.yaml`). The one real seam is that
spec-workflow's config machinery (`config.py` overlay allowlist, `validate-config.py`,
the project-config schema) understands the `compute:` section — that seam should NOT
move; it becomes the documented cross-plugin contract.

## What moves (inventory)

| From (plugins/spec-workflow/…) | To (plugins/remote-compute/…) |
| --- | --- |
| `scripts/remote-compute.py` (1541 ln, stdlib+PyYAML, self-contained) | `scripts/remote-compute.py` |
| `scripts/remote-capabilities/` (whole tree: `_shared/compute-top.py`, `comfyui/`, `slm-training/`, `tests/test_export_gguf.py`; delete stray `*.pyc`) | `scripts/remote-capabilities/` |
| `skills/remote-compute/SKILL.md` | `skills/remote-compute/SKILL.md` — `../../scripts/…` relative paths keep working unchanged |
| `skills/compute-top/SKILL.md` | `skills/compute-top/SKILL.md` — same |
| `tests/section-remote-compute.sh` (761 ln) — MOST of it | new plugin's `tests/` (peer-review-style standalone runner + `_lib.sh`) |
| `tests/e2e-remote-compute-manual.sh` (manual, unregistered) | new plugin's `tests/` |
| `docs/remote-compute.md`, `docs/design/remote-compute-plan.md` | stay in repo-root `docs/` (repo-wide docs dir); update paths inside |

## What stays in spec-workflow (the contract seam)

- `config.py` `LOCAL_OVERLAY_KEYS = ("compute",)` — the project.local.yaml overlay is
  generic config machinery; spec-workflow owns project.yaml's surface.
- `validate-config.py`'s `compute:` section validation + the schema's `compute` object —
  project-config schema is one file, one owner. Document in both places: "written by the
  remote-compute PLUGIN; spec-workflow only validates the shape."
- A slim `section-compute-overlay.sh` exercising the overlay machinery with a
  hand-crafted `compute:` section (spec-workflow's half of the seam). The
  enable→config.py round-trip INTEGRATION test lives in the remote-compute plugin's
  own suite — its tests may reach into spec-workflow (same direction as the declared
  plugin dependency), never the reverse.

Rationale: the alternative (schema fragment + validation owned by the new plugin) buys
purity at the cost of a cross-plugin schema-composition mechanism that doesn't exist
today. Not worth inventing for one key.

## New plugin skeleton (template: plugins/peer-review)

```
plugins/remote-compute/
  .claude-plugin/plugin.json     # name: remote-compute, version 0.1.0
  .codex-plugin/plugin.json
  README.md                      # distilled from docs/remote-compute.md
  scripts/ skills/ tests/        # as inventoried above (tests get own run-tests.sh + _lib.sh)
```

## Wiring checklist (each is a test-visible surface)

1. `.claude-plugin/marketplace.json` + `.agents/plugins/marketplace.json`: add entry #4.
   `section-codex-marketplace.sh` pins plugin count AND insertion-order names — update to
   `spec-workflow,scaffold-project,peer-review,remote-compute`.
2. Repo gate (`.neural-network/project.yaml` `commands.gate`) currently runs ONLY
   spec-workflow's suite/shellcheck/validate. Extend with the new plugin's
   `tests/run-tests.sh`, `shellcheck -x` over its `scripts/*.sh`+`tests/*.sh` (if any),
   and `claude plugin validate plugins/remote-compute` — otherwise the moved tests
   silently leave the gate.
3. `install-skills.sh` + `tests/section-host-portability.sh` iterate `plugins/*/skills/*`
   — pick the new plugin up automatically; no change, but verify all three hosts
   (`skills/install.sh`-equivalent checks) post-move.
4. spec-workflow `run-tests.sh` SECTIONS: remove `section-remote-compute.sh`, add the
   slim overlay section. spec-workflow `plugin.json` minor-bump; README/CHANGELOG refs.
5. Enabled-plugins: users with `spec-workflow@…` enabled do NOT get `remote-compute@…`
   automatically — the skills vanish for them until they enable the new plugin. Call out
   in CHANGELOG + README migration note. `local-state.manifest` has no compute entries
   (state is `$COMPUTE_HOME`, outside the repo) — nothing to migrate there.
6. Cross-references OUT of the moved skills: `remote-compute/SKILL.md` cites
   `docs/design/remote-compute-plan.md` and SPEC-ASSISTANT §14 disclaimers — paths from
   the new plugin root change (`../../../docs/…` unchanged actually: same depth). Verify
   with a link-check pass.

## Behavior changes

None intended. Same script CLIs, same skill names (`remote-compute`, `compute-top` —
no collision with any other plugin's skill names, so install-skills' `<plugin>-<skill>`
fallback never triggers), same `$COMPUTE_HOME` registry, same `compute:` overlay shape.

## Migration for existing users

- Re-enable: add `remote-compute@development-skills` to `enabledPlugins`.
- Nothing on-disk moves for them: `~/.remote-compute` and `project.local.yaml` are
  untouched; enabled `compute:` sections keep validating (seam stayed in spec-workflow).

## Delivery

Same branch (`feat/neural-network-layout`, rides PR #535) — per project owner's call.
RED→GREEN: wiring assertions first (marketplace count/names, codex loops, new-plugin
existence checks), then `git mv` the tree so history follows.
