# ui-design

Mock a UI before it is built, and let the human decide. The agent designs 2–4 genuinely different options at the target's real size, puts them on one page, and serves that page on a local **decision hub**. The human compares the options, picks one (or marks a favorite, ticks the aspects they like, pins notes to elements), and the answer comes straight back to the agent.

Every page is held to the same bar before the human sees it:

- **Accessibility, in both themes.** WCAG contrast (4.5:1, 3:1 for large text, placeholders included), real semantics (buttons, links, labels, alt text), 24×24 px targets (WCAG 2.5.8), input purpose on email and password fields (WCAG 1.3.5), and an [axe-core](https://github.com/dequelabs/axe-core) sweep over every option. The audit runs on load, on each theme switch and on each language switch; a failing page is fixed, never shown.
- **Testability.** Every interactive element carries a stable `data-testid`, which becomes the real implementation's end-to-end hook.
- **Internationalization when asked.** Text and attributes are keyed (`data-i18n`); English, Portuguese and Spanish plus any language the requirements name; the audit fails on hardcoded or missing strings.
- **True scale.** Each mockup is drawn inside the target's real canvas (a round watch face, a phone viewport, a default window).

The plugin is standalone. It knows no workflow, task tracker or other plugin, and posts nothing anywhere except the hub. Other skills may call it by name (`ui-design:ui-options`) with a design id, a title and the requirements, and act on the decision it returns.

## Skills

| Skill | Purpose |
| --- | --- |
| [ui-mode](skills/ui-mode/SKILL.md) | Show or toggle Iterative UI mode: whether UI decisions go to the human or the agent decides alone. |
| [ui-options](skills/ui-options/SKILL.md) | Mock the options, gate them, ask on the hub, collect the answer, iterate until the human commits, record the pick. |

## Clients

| | Claude Code | Codex | OpenCode |
| --- | --- | --- | --- |
| Install | `claude plugin install ui-design@development-skills` | `codex plugin add ui-design@development-skills` | a clone, then `./install-skills.sh opencode --global` |
| Waiting for the human's pick | `ui-hub.sh wait` in the background; its end wakes the agent | no wake: the agent reads `answers` between steps, then waits in the foreground | the same as Codex |
| "Way back to the agent" on the page | `claude --resume <id>` | `codex resume <id>` | left out: OpenCode gives its shell no session id |

The plugin has no hooks. A sandbox that turns the network off (Codex `workspace-write`) can stop the hub from listening: approve running `ui-hub.sh start` outside it. The hub's state folder is `.claude/ui-hub/` in every client; the name is only a path.

**Tested** (2026-11, isolated config folders): all three clients install the two skills, and Codex 0.165.0's shell receives `CODEX_THREAD_ID`. `ui-hub.sh wait` and the handler are tested with a stub `socat`. Not run: a real hub started from Codex or OpenCode.

## Scripts

| Script | What it does |
| --- | --- |
| `scripts/ui-mode.sh status\|on\|off` | The mode is ON unless `.claude/ITERATIVE_UI_OFF` exists in the main checkout (local, gitignored; every worktree sees the same flag). |
| `scripts/ui-hub.sh start\|status\|stop\|ask\|answers\|wait` | The decision hub on `http://127.0.0.1:4747` (`--port`, or `$UI_HUB_PORT`). State is plain files under `.claude/ui-hub/` in the main checkout (or `$UI_HUB_STATE`). |
| `scripts/design-registry.sh index\|find --tags\|pick` | Finds past designs by tag and records the final pick in the page's own `design-meta` block. |

The hub server is [socat](http://www.dest-unreach.org/socat/) listening on 127.0.0.1 only and running `scripts/src/hub-handler.sh` for each connection. socat is the one extra dependency: bash cannot accept TCP connections itself, and the `nc` variants differ between systems and serve one connection at a time.

## Requirements

`bash` 3.2 or later (the macOS default works; WSL on Windows), `jq`, `git`, `socat` for the hub, and a headless Chrome for the pre-serve accessibility gate. No Python.

## Files it writes in your repository

| Path | Tracked? |
| --- | --- |
| `docs/ui-options/<design-id>.html` | Yes: the options page, with its `design-meta` record. |
| `.claude/ui-hub/` | No: hub state. Add it to `.gitignore`. |
| `.claude/ITERATIVE_UI_OFF` | No: the local off switch. Add it to `.gitignore`. |

## Tests

```bash
bash plugins/ui-design/tests/run-tests.sh
shellcheck -x plugins/ui-design/scripts/*.sh plugins/ui-design/scripts/src/*.sh plugins/ui-design/tests/*.sh plugins/ui-design/tests/fixtures/stub-socat/socat
```

Hermetic: the hub's request handler is driven with raw HTTP on stdin, and a stub `socat` stands in for the listener, so no port is bound and no network is used.
