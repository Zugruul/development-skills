---
name: scaffold-project
description: Scaffolds a new greenfield project's minikube dev-workflow scripts (start/stop/dev/build/port-forward/bootstrap) into a scripts/ folder, with every profile bound explicitly and package.json wired to run them. Use for 'scaffold a new project', 'set up minikube scripts for this project', or bootstrapping a fresh repo's local dev-workflow.
allowed-tools: Bash, Read, Write, Edit
---

# /scaffold-project — greenfield minikube dev-workflow scaffold

Generates a new project's local minikube dev-workflow (start/stop/dev/build/
port-forward/bootstrap scripts) from the templates in this skill's
`templates/scripts/` directory, fixed against the profile-collision bug found
independently in two hand-written projects (hearthbase, communication-gateway):
every earlier hand-rolled version called `minikube <verb>` with NO `-p`
flag, so the scripts silently operated on minikube's shared "minikube"
fallback profile instead of one tied to that project — one scaffolded
project's `stop.sh` could no-op while an unrelated project's stray profile
kept running, undetected, side by side.

## Non-negotiables (this is what the whole skill exists to guarantee)

1. **One profile variable, one place.** `common.sh` is the SINGLE source of
   truth: `MK_PROFILE="${MINIKUBE_PROFILE:-<project-name>}"`, defaulted from
   the project's own name (kebab-case) — never a fixed literal like
   `"minikube"` or a name borrowed from another project.
2. **Every `minikube <verb>` call passes `-p "$MK_PROFILE"` explicitly** —
   status, start, stop, ssh, delete, docker-env, addons enable, image load,
   mount. No exceptions, including in scripts you add beyond this skill's
   templates.
3. **Every `kubectl config use-context` uses `"$MK_PROFILE"`**, never the
   literal string `"minikube"`.
4. **A standalone bootstrap script that does NOT source `common.sh`** (e.g.
   because it may run before the rest of `scripts/` exists, or via a bare
   `curl | bash`) still gets its own independent
   `MK_PROFILE="${MINIKUBE_PROFILE:-<project-name>}"` default — see
   `templates/scripts/bootstrap-minikube.sh`.
5. **Every script lives under `scripts/`, never the repo root** — not even
   "just one quick script." A script that sources a sibling (`common.sh`)
   resolves it relative to its own location
   (`$(cd "$(dirname "$0")" && pwd)`), which only works when they're actually
   co-located.
6. **`package.json` is wired so every script is runnable via `pnpm <name>`** —
   see `references/package-json-scripts.md` for the exact entries to merge.

## Steps

1. **Determine the project name.** Prefer the target repo's `package.json`
   `name` field (strip any `@scope/` prefix) or its directory basename,
   kebab-cased. If genuinely ambiguous, ask the human — never guess silently,
   since this becomes the default minikube profile every script binds to.
2. **Create `<repo>/scripts/`** if it doesn't exist.
3. **Copy every file from `templates/scripts/`** into `<repo>/scripts/`,
   substituting `{{PROJECT_NAME}}` → the kebab-case project name from step 1
   everywhere it appears (default minikube profile, namespace, state dir).
   `chmod +x` every copied `.sh` file.
4. **Trim what the project doesn't need** — e.g. drop `build.sh` if the
   project has no service images to build locally, or `bootstrap-minikube.sh`
   if there's nothing cluster-wide to install yet. Don't leave a file whose
   `# CUSTOMIZE:` comment was never addressed and would silently no-op
   (`build.sh`/`port-forward.sh` ship with an empty `SERVICES`/
   `PORT_FORWARDS` array and a comment — fill them in or remove the script).
5. **Wire `package.json`** per `references/package-json-scripts.md`.
6. **Self-check before finishing** (this is the whole point — verify the bug
   class can't reappear):
   ```bash
   # every bare `minikube <verb>` call in scripts/ must carry -p
   grep -n 'minikube \(status\|start\|stop\|ssh\|delete\|docker-env\|addons\|image\|mount\)' scripts/*.sh \
       | grep -v -- '-p "\$MK_PROFILE"' \
       | grep -v -- '-p "$MK_PROFILE"'
   # ^ any line printed here is a missed -p flag — fix it before reporting done.

   # no operational script left in the repo root
   find . -maxdepth 1 -iname '*.sh' ! -path './node_modules/*'
   # ^ any file printed here (other than a project-specific top-level tool
   #   unrelated to this scaffold) should move into scripts/.
   ```
7. Report what was created, what was trimmed/customized, and confirm both
   self-checks came back clean.

## Reference implementation

`templates/scripts/` mirrors the corrected pattern from hearthbase's
`scripts/common.sh` (post-fix) — read it if you need to see the fully-fleshed
version this skeleton is deliberately simplified from (mongo topology
detection, disk-reclaim watchers, and a multi-service build catalog are
hearthbase-specific business logic, not part of this generic scaffold).
