# UI decisions in the build loop (with the ui-design plugin)

Mocking UI options and getting the human's pick lives in the standalone **ui-design** plugin (skills `ui-design:ui-mode` and `ui-design:ui-options`). It knows nothing about boards, issues or tasks. This file is spec-workflow's side: when to use it, what to pass it, and the workflow steps around it (the issue channel, the design registry, the move-to-review guard). `build-next`, `implement-task` and `refine-task-ui` all follow it.

## 1. Is iterative UI on, and is ui-design installed?

```bash
bash "../../scripts/iterative-ui.sh"   # ON, or OFF with the reason
```

- **OFF** (`methodology.iterativeUI=false` in the project config, project-wide; or the per-clone `.claude/ITERATIVE_UI_OFF` flag) → decide the UI yourself, following the spec and existing conventions.
- **ON, but ui-design is not installed** → decide the UI yourself as well. ui-design is installed when its skills (`ui-design:ui-options`, `ui-design:ui-mode`) are available in this session — in Claude Code and Codex they are listed as installed plugin skills; with OpenCode or a skills-dir install, as `ui-options` / `ui-mode` skills from the ui-design plugin. Say once per session that installing the ui-design plugin (`claude plugin install ui-design@development-skills`) hands UI decisions to the human.
- **ON and installed** → steps 2–5 below.

Never reach into the ui-design plugin's folder (no script paths): use its skills by name. To toggle the per-clone flag, use the `ui-design:ui-mode` skill; if the human says they're going AFK / not watching / wants fewer questions, offer it (`off`). The project-wide switch is a repo change (edit `methodology.iterativeUI`), so confirm before touching it.

## 2. Before any UI-affecting work: earlier decisions

Run `python3 "../../scripts/design-registry.py" find --tags <the task's surfaces>` (e.g. `chat`, `trace-inspector`, `voice-visualizer` — see the registry's own tag vocabulary; this is spec-workflow's reader of the same `design-meta` blocks ui-design writes, plus the sidecars, `applied` state and staleness ui-design does not track).

- A **FINALIZED** match is BINDING: paste it into the dev brief and implement exactly what it says; do not reopen the decision.
- A **STALE** match (the governed UI surface changed since the design was picked) must be re-confirmed with the human before use.
- No match → ask ui-design (step 3).
- **When THIS task is the one that will actually apply a matched design** and the design's registered `issue` is unset or names a different issue (the decision was picked in one task, the real apply lands in a later one, e.g. issue #396/AST-022), update it before finishing: `python3 "../../scripts/design-registry.py" backfill <id> --tags <its tags> --issue <this-task-issue>`. That is what lets `design-registry-preflight.sh`'s mechanical guard gate the task doing the real work.

Never guess a UI when a finalized design already exists for its tags.

## 3. Ask ui-design

Invoke `ui-design:ui-options` with:

- **design id** = the task id (e.g. `AST-083`), so pages land at `docs/ui-options/<task-id>.html` and hub cards are `<task-id>-r<N>`;
- **title** = the task title, and the requirements = the task's spec and acceptance criteria;
- one extra key for its `design-meta` block: `"issue": <N>` — the board issue number this round is asked for, as a bare integer. ui-design keeps extra keys as given; spec-workflow's `design-registry-preflight.sh` (run by `board-queue.sh` and the `guard-board-move.sh` hook on a move to In review) reads it. A design without it is invisible to that guard.

Then, on the spec-workflow side:

- Post a short issue comment pointing at the hub (`bash "../../scripts/board.sh" comment N`): the issue stays the durable/remote channel, and a human may paste the copied selection there.
- Acknowledge each round on the issue (`board.sh comment N`: "Round 3 in the hub — B2 suggested"), and put your recommendation there, never as a badge on the page.
- Build the non-UI parts while waiting.

## 4. Collect the answer

At each iteration start, and before any UI-specific work, collect answers from both channels: the hub (through `ui-design:ui-options`, always scoped to the round id `<task-id>-r<N>`, never a bare consume) and the issue's `### UI selection` comments (`bash "../../scripts/board.sh" show N`). An `### A11y fixes requested` answer is partial feedback, not a decision; ui-options handles it.

**No selection and only UI work remains** → do not guess: re-ask blocking through ui-options (which keeps its one-shot watcher armed), comment a reminder on the issue, and stop the iteration (blocked-on-human; see `build-next` stop conditions). The armed wait, not a scheduled poll, is what resumes it.

## 5. After the final `Use:`

ui-design records the pick in the page. Implement exactly that option. Once the decision is actually implemented and merged, record it: `python3 "../../scripts/design-registry.py" applied <task-id> <commit-sha>` — this is what turns `UNAPPLIED` into a real, checkable state and lets the move-to-review guard pass. To fold screenshots and acceptance criteria back into the issue, use the `refine-task-ui` skill.
