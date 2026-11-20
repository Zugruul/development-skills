# Lane lines in the orchestrator report

The `task-lane`, `build-lanes`, `build-loop` and `review-lane` skills make you the orchestrator, so every report on the state of your lanes uses the fixed format of the `herdr` plugin: read "Orchestrator report" through the `herdr:orchestrate` skill (its `references/report.md`). That format decides the first line, the three sections, their order and where each agent goes. This file only adds lines **inside a lane's entry**, which that format allows.

Put them as nested lines of the entry, after its `prs:` block and before `verified:`, one fact per line, in this order, and leave out a line that does not apply:

| Line | Value | When |
| --- | --- | --- |
| `task:` | the task's source and id as given (`github 123`, `clickup 1k5a5ew4cde`), or `none` for a lane without a task | every lane |
| `gate:` | the gate result (`green`, `red: <what failed>`, `not run`) | once the lane has run it |
| `board:` | the task's board status as you read it yourself with the spec-workflow `board` skill | task lanes only |
| `skipped (no task):` | the steps left out for lack of a task | a done lane with task `none` |

The example is fenced only to show the source; the report itself is never inside a code fence.

```markdown
**🟢 DONE (1)**

- **codex-lane-123** · w2D · feat/123-add-parser
  - add the parser -> 3 commits
  - prs:
      ⚪ #812 draft   https://github.com/<owner>/<repo>/pull/812
  - task: github 123
  - gate: green
  - board: In review
  - verified: PR state, 3 commits, board status
  - claimed: ⚠ gate green
```

## The `prs:` block of a lane

The `herdr` plugin's format defines the block (one line per pull request: number, state, full bare URL); this plugin supplies what goes in it.

- List every pull request opened from the lane's branch, in the order they were opened, read with `gh pr list --head <lane branch> --state all --json number,url,state,isDraft` in the lane's checkout (read-only). A lane usually has one; a lane whose work was split or reopened has several, and all of them are listed.
- Use each `url` exactly as returned. State: `draft` when `isDraft`, otherwise `open`, `merged` or `closed` from `state`.
- A lane whose work reached the main branch without a pull request (pushed or squashed onto it) gets the format's `direct` row, after its pull requests. Take it from `herdr_ctl.py landed --cwd <lane checkout>` as the `herdr` reference describes; this plugin adds nothing to it. A lane whose pull request was merged has the `🟣 #N merged` row and no `direct` row.
- A pull request you read this way is verified. One that only the lane agent mentions is written from its report: with the URL it gave, or the number and state alone when it gave none, and its state belongs under `claimed:`.

## Notes

- The lines this plugin adds carry no emoji: the format's fixed marks (section dots, pull request dots, `⚠` on `claimed:`, `⚫`) are the only ones in a report.
- `verified:` and `claimed:` keep their meaning: a gate result you only read in the lane agent's own report is a claim; a board status you read yourself is verified.
- Take the task id from what you assigned to the lane, never by splitting its branch or label on hyphens.
- The build loop's agent is one entry; its line 2 names the iteration's task. The loop's own three groups (done, in progress, queued) are a longer finding and go after the report, in prose.
- A reviewer agent is one entry with `task:` of the lane it reviews; its findings go after the report, in prose.
