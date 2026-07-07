---
name: ui-options
description: Iterative UI mode — presents 2-4 concrete UI design options on the local decision hub as toggle tabs (no scrolling) — favorite selector, likeable aspect chips, element-level annotations, a final 'Use this one', and a Review tab summarizing every pick before sending. Use when a task involves UI-affecting decisions and iterative UI mode is on.
---

# UI options page — delegate the UI decision to the human

The human, not the agent, picks UI direction when iterative UI mode is ON. You produce real options, they choose, work on everything else continues meanwhile.

**Delivery is the local decision hub ONLY — never a claude.ai Artifact.** Do not use the Artifact tool for options pages, even as a fallback, even if asked to "show" options: publish-to-artifact breaks the answer channel (`#send` can't POST back to `ui-hub.py`, so the selection never reaches the agent), renders inside a host page whose theming fights the template, and uploads the mockups to an external service. The one and only path is: write the page to `docs/ui-options/`, serve it with `ui-hub.py` (step 2), and give the human the `http://127.0.0.1:4747` hub URL. If the hub can't start, fix that (port in use → `$HUB start` is idempotent; report the error otherwise) — do not route around it with an artifact.

## Mode check (do this first)
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui-mode.sh" status    # prints ON, or OFF with the reason
```
`off` / `on` toggle it for this clone (local gitignored flag); `methodology.iterativeUI=false` in project.yaml is the project-wide kill switch.
OFF → decide the UI yourself following the spec and existing conventions; skip this skill.
If the human says they are going AFK, won't be watching, or sounds annoyed by UI questions — **offer to turn it off** (`ui-mode.sh off`).

## 1. Build the page
1. Design **2–4 genuinely different options** (not one option with color tweaks): different layout/navigation/density/visual language. Each option must be a self-contained inline HTML+CSS mockup of the actual screen/component the task needs.
2. `cp "${CLAUDE_PLUGIN_ROOT}/templates/ui-options.html" docs/ui-options/<task-id>.html` (create the dir), then edit it following the comments in the template: fill `__TASK_ID__`/`__TASK_TITLE__`/`__ISSUE_URL__`, and `__SESSION_ID__` with the value of `echo "$CLAUDE_CODE_SESSION_ID"` (gives the human a `claude --resume` way back into this session; if empty, replace the whole resume sentence with nothing — the issue comment channel always works). Options are tabs, not a scrolling grid: duplicate the OPTION `<section class="option panel">` per option, put each mockup in `.preview`, give each option **4–8 aspect chips** — short trait keywords a non-designer can react to (e.g. `dense layout`, `sidebar nav`, `rounded cards`, `muted palette`, `inline editing`) — **and** add a matching `<button class="tab" data-tab="__OPTION_ID__">` in `.tabbar`, right before the fixed `Review` tab button. The Review tab (last, never duplicated) summarizes every option's favorite/aspect/note picks live and holds Send/Copy — no separate bottom bar. Keep the "Iterative UI mode is ON / how to turn it off" hint intact, and keep the theme toggle (top right) intact.
3. **Both themes, contrast + a11y — machine-enforced.** The page has a light/dark toggle and the human may view either theme. Style every mockup from the template's theme vars (`var(--card)`, `var(--fg)`, `var(--muted)`, `var(--surface)`, `var(--accent)`, `var(--border)`) — never the `Canvas` keyword, never a hardcoded background with inherited text color. A deliberately single-theme mockup must hardcode both its background AND all its text colors, set `color-scheme` on its form controls, and style its `::placeholder`s explicitly (placeholder color otherwise follows the page theme and blends). Any text over a gradient/image background needs `data-bg="#rrggbb"` (approximate base color) on the element or an ancestor, or the audit flags it as unverifiable.
   Mockups must use REAL semantics, not lookalike divs: `<button>`/`<a href>` for anything clickable (or `role="button" tabindex="0"`), an accessible name on every form control (`<label for>`, `aria-label`, or `title` — placeholder alone fails), `alt` on every `<img>`.
   **Testability + input standards (also audited):** every interactive mockup element carries a stable `data-testid` (these become the real implementation's e2e hooks — name them like `a-email`, `b-submit`); email/password inputs declare `type` and `autocomplete` (`email` / `current-password` — WCAG 1.3.5); interactive targets measure ≥ 24×24 CSS px (WCAG 2.5.8, measured per option even on inactive tabs).
   The template's built-in audit runs on load, on every theme toggle, and on every language switch: the composited WCAG contrast checker (4.5:1, 3:1 large/bold, placeholders included) + the semantic checks above + **axe-core** (the industry-standard engine behind Lighthouse/aXe DevTools/jest-axe, vendored at `scripts/vendor/axe.min.js` and served by the hub at `/vendor/axe.min.js`; its color-contrast rule is off — the data-bg-aware checker owns contrast) swept across every option panel, including inactive tabs. Failures show a fixed red `⚠ A11Y FAILURES` banner + `window.__a11yIssues`.
   **Gate before serving (mandatory):** after `$HUB ask`, load the served page headless in BOTH themes (and each language if i18n) via the URL params — `http://127.0.0.1:<port>/decision/<id>?theme=light`, `?theme=dark` — with headless Chrome (`--dump-dom --virtual-time-budget=15000`) and check the DOM does NOT contain `a11y-report`. A page that shows the banner in any theme/language must be fixed and re-asked — never left as-is, never worked around by deleting or weakening the audit.
4. **i18n when asked.** If the task/spec calls for i18n, multiple languages, or names specific locales: fill the template's `I18N` dict with `en` + `pt` + `es` plus any language the spec names, mark every translatable mockup text with `data-i18n="key"` (text-only elements) and translatable attributes with `data-i18n-placeholder` / `data-i18n-aria`. The language toggle then appears automatically beside the theme toggle, and the audit enforces full coverage (hardcoded text, untranslated placeholders, and keys missing from any language all fail). Single-language tasks leave `I18N` empty — the toggle stays hidden.
5. Commit the page on the task branch.

## 2. Ask the human — decision hub first
The hub is one long-lived local page the human keeps open; cards appear there, answers come back automatically (no copy/paste). `HUB` = `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/ui-hub.py"`.
```bash
$HUB start                       # idempotent; prints RUNNING http://127.0.0.1:4747
$HUB ask <task-id>-r1 "<task-id>: <short question>" docs/ui-options/<task-id>.html
```
The first time in a session, tell the human the hub URL (once — it never changes). If only UI work remains, re-ask with `--blocking` so the card is flagged "agent is waiting on this".
Also post a short issue comment (`board.sh comment N`) pointing at the hub — the issue stays the durable/remote channel, and pasting the selection there works too.

## 3. Keep working, don't block
Continue every part of the task that does not commit to a UI option: domain logic, API, state, tests, plumbing, UI-agnostic scaffolding. Before UI-specific work (and at each iteration start), collect answers from both channels:
```bash
$HUB answers --consume           # JSON lines: {id, title, selection, ...}
bash "${CLAUDE_PLUGIN_ROOT}/scripts/board.sh" show N   # '### UI selection' comment
```
Answers whose selection starts with `### A11y fixes requested` are partial feedback, not a decision: the human ticked specific audit failures (plus an optional note) in the red bar and the card **stays pending** on the hub. Fix exactly those issues, re-run the gate, and re-`ask` the same id (the open card hot-reloads) — do not treat it as the UI selection and do not wait for it to be consumed as one.

## 4. Apply the selection — iterate until the human commits
- **`Use: Option X (as-is, final)`** → decision made: implement exactly that option. No further rounds.
- **`Element notes:` lines** are element-scoped instructions: `Option X [tag.class > tag "element text"]: <note>` — the bracket is the element's selector path inside that option's mockup, the quote its text. Apply each note to that exact element; never generalize it to the whole design.
- **Favorite and/or liked aspects (no "Use")** → the human is still exploring: build the next round. Synthesize their favorite + liked aspects into one variant, plus 1–2 alternatives that explore what their picks left ambiguous (e.g. they liked both `monospace styling` and a polished shell — one variant leans each way). Do **not** badge any option as "Suggested" in the page — the template shuffles option order and an endorsement biases the pick; state your recommendation (and why) in the issue-comment acknowledgment instead. Include a Round-1-style recap of what they picked. Enqueue as `<task-id>-r<N+1>`; repeat until a `Use:` arrives.
- **Conflicting aspects** → resolve visibly: show the resolution as the suggested variant, note the conflict in its subtitle.
- Acknowledge each round on the issue (`board.sh comment N`: "Round 3 in the hub — B2 suggested").
- **No selection and only UI work remains** → do NOT guess: re-ask `--blocking`, post a reminder comment, report the task blocked-on-human, and stop the iteration (see `build-next` stop conditions).
