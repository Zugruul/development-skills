# herdr-development-skills

The integration layer between [Herdr](https://herdr.dev) and the other development skills in this marketplace. It checks which plugins and features are actually enabled and configured in the current environment and repository, and wires those into the [`herdr`](../herdr/README.md) plugin: board tasks and build-loop lanes run in Herdr worktree agents that an orchestrator listens to.

All knowledge of the specialized plugins lives here. The `herdr` plugin knows only Herdr; this plugin **requires it** and builds on its skills (`herdr:worktree`, `herdr:agent`, `herdr:prompt`, `herdr:listen`, `herdr:orchestrate`, `herdr:status`) instead of repeating Herdr commands.

## Install

```bash
claude plugin marketplace add Zugruul/development-skills
claude plugin install herdr-development-skills@development-skills   # installs herdr too
```

Install the specialized plugins you want wired in (`spec-workflow`, `peer-review`) the same way. None is required: an integration whose plugin is missing reports `UNAVAILABLE` or `LIMITED` with the reason, and the rest keep working. Without spec-workflow, a lane can still run work that has no task.

## Skills

| Skill | Purpose | Needs |
|---|---|---|
| `integrations` | Read-only report of which plugins are enabled, how spec-workflow is configured here, which integrations are `READY`, `LIMITED`, `PAUSED` or `UNAVAILABLE`, and how work without a task can be handled | - |
| `task-lane` | One piece of work in its own Herdr worktree agent: a board task (running `implement-task`, or one whole `build-next` iteration for it) or work described in plain words with no task | board tasks: spec-workflow, configured |
| `build-loop` | The build loop (`/loop` + `build-next`) in a separate Herdr agent while this one orchestrates; described work is handed to a single lane instead | spec-workflow, configured |
| `build-lanes` | Several pieces of work in parallel, one lane per Herdr worktree agent: board tasks within `methodology.maxInProgress`, plus described work with no task | board tasks: spec-workflow, configured |
| `review-lane` | A second agent next to a lane running `peer-review` on its diff; findings come back unapplied | peer-review |

Every skill also needs Herdr itself (the binary, and the agent running inside a Herdr pane) and the `herdr` plugin.

## How detection works

`scripts/detect.py [--root DIR] [--json]` is read-only and offline.

- **Plugins.** `enabled` when the host's `enabledPlugins` says so (user, project and local settings, later files winning) or the plugin's skills are linked into a project skills directory (`.claude/skills`, `.agents/skills`, `.opencode/skills`). `available` when the plugin is installed or sits next to this one but enablement could not be confirmed (Codex keeps that state where this script cannot read it). `absent` otherwise.
- **spec-workflow in this repository.** Looks for the project config and reads it through spec-workflow's own loader, so defaults and overlays match what the workflow itself sees: main branch, branch pattern, `maxInProgress`, `serialDelivery`, `autoMerge`, `work.type`, `work.checkout`, the `herdr` object, and the checkpoint flag in the primary checkout.
- **Features.** `READY`, `LIMITED` (the skill runs, but only for work without a task), `PAUSED` (the build loop's checkpoint flag is set) or `UNAVAILABLE`, each with its reasons.
- **Task source.** Which of the three ways to handle work without a task identifier are possible here (see below).

It reads files and cannot see a session, so the skills treat it as a hint and confirm the needed skills are listed before offering a feature.

## How a lane runs

For a board task (a lane without a task differs in step 1 and in what its agent is told, as described above):

1. The orchestrator reads the task and works out the lane: its names from `scripts/lane_name.py` (see "Lane names" below), base a freshly fetched main, path `<primary checkout>/.claude/worktrees/<task-id>` (where spec-workflow keeps task lanes).
2. `herdr:worktree` plans it, asks the user, and creates it with explicit `--cwd`, `--branch`, `--base`, `--path` and `--label`.
3. `herdr:agent` starts the lane agent and sends one prompt: run the spec-workflow skill on the assigned task, in this checkout, which already is the lane.
4. `herdr:listen` follows it. Anything the workflow requires a human for (checkout mode, consent before an autonomous merge, UI decisions) blocks the lane; the orchestrator shows the question to the user and relays the answer. It never answers for them.

With `build-lanes` the orchestrator is the only picker: it assigns one task per lane from the queue, so two lanes cannot start the same task. spec-workflow's own board admission and merge lock still apply inside each lane.

spec-workflow can also open the lanes it creates itself in Herdr (`herdr.enabled` in the project config). That setting is independent of this plugin and is what makes `build-loop`'s lanes visible as workspaces.

## Reports

The lane and loop skills make the agent the orchestrator, so it reports in the `herdr` plugin's fixed format (`NEEDS YOU`, `WORKING`, `DONE`). `references/report-lines.md` adds this plugin's own lines inside a lane's entry: `task:` (source and id, or `none`), `gate:`, `board:` and, for a finished lane without a task, `skipped (no task):`. It also says where a lane's pull requests come from for the format's `prs:` block: every pull request of the lane's branch, read with `gh`, one line each with number, state and full URL. The layout itself stays the `herdr` plugin's.

## Lane names

`scripts/lane_name.py` is the one place lane names are built; the skills call it and never assemble a name by hand.

| | Branch | Herdr workspace label (the lane's title in the sidebar) | Agent name |
| --- | --- | --- | --- |
| ClickUp task | `feat/<taskid>-<desc>` | `CU-<taskid>-<desc>` | `<kind>-lane-<taskid>` |
| GitHub issue | `feat/<taskid>-<desc>` | `GH-<taskid>-<desc>` | `<kind>-lane-<taskid>` |
| Jira issue (not a supported source yet) | `feat/<taskid>-<desc>` | `J-<taskid>-<desc>` | `<kind>-lane-<taskid>` |
| No task | `feat/<desc>` | `<desc>` | `<kind>-lane-<desc>` |

- `<desc>` is a lowercase kebab-case slug of the task title or the user's description, at most 40 characters.
- The tag comes from the `SOURCE_TAGS` mapping at the top of the script; a new source is one more line there.
- The task id is used as the source gives it and may contain hyphens (`ABC-123`), so nothing takes a branch or label apart by splitting on hyphens. `--json` returns the id, the slug and the tag as separate fields.
- The label has no spaces; the `herdr` plugin enforces that shape and knows nothing about tags or sources.
- The agent name starts with the agent kind (`claude-lane-1k5a5ew4cde`, `codex-lane-123`), because Herdr shows the kind only for unnamed agents. The id is lowercased for the name (`ABC-123` gives `claude-lane-abc-123`). A lane's reviewer is `<kind>-review-<taskid or desc>`.
- Herdr allows 32 characters of lowercase letters, digits, `-` and `_`. A longer name is shortened only after `-lane-`: the id or slug is cut and ends in four hex digits of the whole value, so `opencode-lane-fix-health-check-204` (34 characters) becomes `opencode-lane-fix-health-ch-5450`. The kind is never cut. A name already used by a live agent gets `-2`, `-3` through `--taken`.
- A tab keeps its agent's name as its label (`codex-lane-123`), which already has no spaces. Only the workspace label carries the tag.
- The lane branch rule is fixed and does not follow spec-workflow's `project.branchPattern`. spec-workflow's default pattern is the same rule (`feat/<id>-<slug>`); in a repository whose config says otherwise, `detect.py` prints a note, because that repository's board audit and PR guard will not recognise lane branches until its pattern is changed.

## Work without a task identifier

Not every request is a board task. "Change the health check to 204 and open a draft PR" has no issue behind it. When `task-lane`, `build-lanes` or `build-loop` is asked for a specific piece of work with no task identifier, or with a description instead of one, it neither guesses nor refuses. It asks one question with exactly three options (`references/task-source.md`):

| # | Option | What happens |
|---|---|---|
| 1 | Run the workflow without a task | The same lane (worktree, agent, brief, listen) runs from the description alone. Nothing is read from or written to the board; every step that needs a task is skipped and named as skipped in the final report |
| 2 | Create a task for it | spec-workflow's `create-inbound` skill searches for duplicates and files the task; the user sees the identifier, then the normal task lane runs on it |
| 3 | Provide the task identifier | The user names an existing task and the normal task lane runs on it |

- **Once per piece of work**, never once per skill hop: the answer travels with the piece (`build-lanes` hands it to `task-lane`). Several pieces in one request get one labelled question each, and the answers may differ.
- **No question when the answer is known**: an identifier was given, or the user already said which option they want. A standing answer ("no tasks for these, just run them") covers the rest of that request.
- **Only options that can work.** Options 2 and 3 need spec-workflow enabled, a board configured and the loop not paused. Where they cannot work, the skill says why and runs option 1 instead of showing dead options. `detect.py` prints this as the `TASK SOURCE` block.
- **A no-task brief is complete on its own**: goal, checkout, scope, what done means, what to report. With no issue body to fall back on, a description too thin for one of these gets a question to the user, not invented scope.
- **Skipped without a task**: reading the task, board status moves, issue comments, the task-state record, the gate record tied to a task's move to review, and linking the pull request to an issue. The project's checks still run and their result is reported.

A bare `build-loop` or `build-lanes` picks its own work from the board and asks nothing. `review-lane` needs a lane, not a task, so it never asks either; it reviews a no-task lane like any other.

If a repository refuses work that has no task (spec-workflow's optional pull-request guard does, for example), the lane agent stops and reports it, and the user is offered options 2 and 3 again.

## Proposed integrations (not implemented)

| Idea | Why it would help |
|---|---|
| Lane cleanup after merge | Close the Herdr workspace of a lane whose task reached QA or Ready, using spec-workflow's own lane removal |
| Task-state in the roster | Join spec-workflow's local task record (TODOs done and total per task) into the orchestrator's lane roster |
| Remote-compute lanes | Start lane agents on a saved Herdr SSH machine that is also a registered compute target |
| Handoff per lane | Have each lane write a spec-workflow handoff when the orchestrator stops, and collect the paths |

## Tests

```bash
bash plugins/herdr-development-skills/tests/run-tests.sh
```

Hermetic: a private `HOME` and throwaway repositories, no Herdr and no network. The suite reads `plugins/herdr` and `plugins/spec-workflow` (their skills, config loader and fixtures), mirroring the dependency direction. The checks on a configured repository need PyYAML, as spec-workflow's loader does, and are skipped with a note without it.
