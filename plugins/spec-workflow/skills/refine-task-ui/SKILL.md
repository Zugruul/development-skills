---
name: refine-task-ui
description: Refine an existing board task's UI through the iterative-UI decision hub, then capture the finalized design as real screenshots and fold them + the resolved acceptance criteria back into the task's issue body. Use for the /refine-task-ui command with a task id — when a task's UI direction is still being iterated (or hasn't started) and the human wants concrete visual artifacts attached to the task, not just a hub link.
---

# Refine a task's UI, then attach the finalized design to the task

`ui-options` gets a human to a decision inside the hub. This skill is the step after: once that decision lands, turn it into something a future implementer (a dev agent or a human) can build against without reopening the hub — real screenshots, embedded in the task issue, next to a description that says exactly what to build.

Two things this is NOT:
- It does not replace `ui-options` — it calls it (or resumes an already-running round) rather than duplicating the mockup-building/serving logic.
- It does not implement the UI — it stops once the task's issue is refined; implementation is a normal build-loop task afterward.

## 0. Mode check

```bash
bash "../../scripts/ui-mode.sh" status
```
OFF → tell the human iterative UI is off and ask whether to turn it on for this refinement (`ui-mode.sh on`) or decide the UI yourself instead (skip this skill). Don't silently proceed either way.

## 1. Resolve the task and its round state

Take the task id/issue number from the argument. `board.sh show <issue#>` to read its body and comments — a task already run through `ui-options` will have `### UI selection` comments on it (round recaps, favorite/aspect picks, or a final `Use:`). Check `python3 "../../scripts/ui-hub.py` status`` for any open card matching this task.

- **No round has run yet** → invoke the `ui-options` skill to build round 1 from the task's spec/acceptance criteria. Then go to step 2 and wait.
- **A round is mid-exploration** (favorite/aspects/notes on file, no `Use:` yet) → synthesize the next round per `ui-options`'s own step-4 protocol (favorite + liked aspects → one refined variant + 1-2 alternatives; element notes → apply verbatim to the elements they target) and re-ask. Then go to step 2 and wait.
- **A round already ended in `Use: Option X (as-is, final)`** → skip straight to step 3, no new round needed.

## 2. Iterate until a final decision lands

This is the same loop `ui-options` runs — you are not inventing new protocol, just staying in it until it reaches a stopping point:

1. `python3 "../../scripts/ui-hub.py" answers --consume` (and check the issue's `### UI selection`/`### A11y fixes requested` comments — either channel can carry the answer).
2. An `### A11y fixes requested` answer is partial feedback, not a decision — fix exactly the ticked issues (re-run the a11y gate from `ui-options` step 1's headless-Chrome check before re-serving), re-`ask` the same round id, keep waiting.
3. Any other real UI feedback (favorite, liked aspects, element notes, no `Use:` yet) → apply it to a new round (mirroring the note-application discipline you'd use inside `ui-options` — an element note is scoped to the exact element it names, never generalized to the whole design) and re-serve. Before re-serving, re-run the a11y gate — a fix for one note can regress a different element or theme (a CSS rule scoped too broadly, a color reused in a context it wasn't tuned for); catch that now, not after the human re-opens the hub. **If a screenshot/computed-style check would resolve an ambiguous bug report faster than guessing from a static file read, use it** — an "icon looks blank" or "misaligned" note is a rendering claim, not just a spec change; verify what's actually on screen (browser automation / devtools, computed styles, `getBoundingClientRect`) before deciding whether it's a real bug or a legibility tweak, the same way you'd verify any other claim before fixing it.
4. `Use: Option X (as-is, final)` → the loop ends, go to step 3.

Acknowledge each round on the issue exactly like `ui-options` does (`board.sh comment N`: "Round K in the hub — <what changed>").

## 3. Capture the finalized design as real screenshots

Once a final `Use:` has landed, don't hand the human a static export of the raw HTML file — capture what actually renders, the same tool that caught (or would have caught) any layout bugs during iteration:

1. Load the served decision-hub page for this round (`http://127.0.0.1:<port>/decision/<round-id>`) in a real browser (the `chrome-devtools` MCP tools, or an equivalent headless-Chrome invocation).
2. Select the chosen option's tab.
3. Hide the decision-hub-only chrome before screenshotting — the header, the round recap, the tabbar, the option's own head bar (Annotate/Score/Favorite/Use buttons), and the aspect checkboxes are all scaffolding for the DECISION, not part of the product UI. Inject a scoped style (`display:none` on `.toggles, header, .recap, .hint, .tabbar, .option > .head, .aspects`) rather than screenshotting the whole page — the artifact should look like the real screen, not like a UI-options tool.
4. Capture every state the mockup actually models and that the implementer needs to see: both themes if the mockup supports a light/dark toggle, and every distinct view/mode the option exposes (e.g. a list/cards switcher, an empty state, an error state) — one screenshot per state, not just the default.
5. Save each screenshot under `docs/ui-options/screenshots/<task-id>/` (or a flat `docs/ui-options/screenshots/<task-id>-<state>.png` naming if the task has few states) inside the project repo — screenshots must live in the repo so they can be embedded via a stable URL in the next step, and so they survive the local dev hub disappearing.
6. Commit the screenshots (and any final mockup-file edits from step 2) as the orchestrator identity. This is a docs/artifact commit, not product code — direct-to-main is fine unless the task's own branch discipline says otherwise.

## 4. Fold the decision into the task's issue body

`board.sh edit-body <issue#> <file>` — write a refined body that preserves whatever original context the issue had (don't delete a bug's origin-task reference, a spec pointer, etc.) and adds:

- **A "UI decision — finalized" section** naming the chosen option.
- **Every captured screenshot, linked correctly for this repo's visibility** — check first: `gh repo view <owner>/<repo> --json isPrivate`.
  - **Public repo**: embed inline via `![alt](https://raw.githubusercontent.com/<owner>/<repo>/<default-branch>/docs/ui-options/screenshots/<path>.png)` — a plain relative path does NOT render on a GitHub issue (issues aren't repo-relative the way READMEs are), but the raw-content URL renders fine for anyone.
  - **Private repo**: `raw.githubusercontent.com` 404s on an unauthenticated `<img>` fetch (a private repo's raw CDN needs a token the browser's `<img>` tag never sends) — do NOT use the raw-content URL, it will look fine to you in the API response and then 404 for every actual viewer. Link instead via the plain `https://github.com/<owner>/<repo>/blob/<default-branch>/<path>` blob URL (a normal authenticated github.com page any repo-access viewer can open) and say plainly in the issue that it's a private repo so it won't preview inline, only link out. There is no CLI/API path to the drag-and-drop `user-attachments` upload flow that DOES preview inline on private repos — that requires the human to attach the file through the web UI themselves if true inline preview matters more than a working link.
- **REQUIRED, not optional — link the interactive mockup source file itself, not just its static screenshots.** Screenshots are a frozen rendering of one moment; the mockup HTML is the actual artifact (every option, every round, live theme toggle, the real markup/CSS an implementer can diff their build against). Every refined issue MUST include a direct blob link to the mockup file (`https://github.com/<owner>/<repo>/blob/<default-branch>/docs/ui-options/<file>.html`) alongside the screenshots — never screenshots alone. Since GitHub's blob view only shows HTML source (it does not execute the page), also tell the reader how to run it live: clone + open the file directly, or re-serve it locally the same way it was iterated on (`ui-hub.py start` + `ui-hub.py ask <id> "<title>" <path>`, then open the printed `http://127.0.0.1:<port>` URL). If earlier rounds exist as separate files (a round-1 exploration superseded by round 2), link those too for history — don't leave them orphaned once a later round supersedes them.
- **A concrete "key decisions to build against" list** — translate what's visually obvious in the screenshot into words a future implementer (who may never open the mockup HTML) needs: layout structure, which actions live where, state-dependent visuals (e.g. an auth-failed tile's desaturated avatar), persistence behavior for any toggle, anything the mockup's own annotations/element-notes captured that isn't visually self-evident from a screenshot alone.
- **Refined/expanded acceptance criteria** — concrete, checkable items a dev agent or human can build against directly, not just "matches the mockup." Preserve any AC the issue already had that's still valid; add what the finalized UI decision makes concrete (the specific component/page path if known, the specific actions/routes it wires to, explicit test/gate requirements per this repo's own standing rules).

Before posting, verify the refined body actually contains BOTH a screenshot link and a mockup-source-file link — a body with only screenshots is an incomplete refinement, not a smaller-but-valid one.

Post a closing comment on the issue (`board.sh comment <issue#>`) summarizing what was locked in and pointing at the refined body — the same way `ui-options` acknowledges each round, but this is the final acknowledgment: decision made, artifacts attached, ready to build.

## 5. Report

State: which task was refined, the final option chosen, how many rounds it took (if you ran any), what screenshots were captured (paths + states), and the issue URL. This skill's job ends here — do NOT proceed to implement the UI in the same turn unless the human explicitly asks; refining the task and building it are separate steps, same as any other spec-then-build workflow in this project.
