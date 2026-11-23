# Review summary

The one format for the final summary of a reviewed pull request. The `orchestrate-code-reviews` skill writes one per pull request to a file, shows it to the user, and posts it as a pull request comment only when the user asks.

This is not the orchestrator report (`report.md`): that one shows the state of the agents; this one is the outcome of the review, written so it can stand alone as a pull request comment.

## Template

The block is fenced only to show the source.

````markdown
## Review: <what the pull request does, a few words>

Checked at commit [`<short sha>`](https://github.com/<owner>/<repo>/commit/<full sha>). <who covered what: how many reviewers and the area each took, by area, never by a person's name>. <how findings were verified: what was read, what was re-checked>. <whether tests ran: the command and result, or that they were not run and why; any other check that was made and how>.

**<N> findings:** <n> critical, <n> major, <n> minor. Each has an inline comment with how it was verified and a fix prompt.

| # | Severity | Finding | Where |
|---|---|---|---|
| 1 | 🔴 Critical | [<one-line title of the finding>](<URL of its inline comment>) | `<file>:<line>` |
| 2 | 🟠 Major | [<one-line title of the finding>](<URL of its inline comment>) | `<file>:<line>` |
| 3 | 🟡 Minor | [<one-line title of the finding>](<URL of its inline comment>) | `<file>:<line>` |

<details>
<summary>👀 Worth a look (not confirmed, not posted inline)</summary>

- **<the suspicion in one line>** (`<file>:<lines>`): <what was seen, why it was not confirmed, what would settle it>.

</details>

<details>
<summary>✅ Checked and found correct</summary>

<area>: <what was checked and holds>; <the next item>. <next area>: <what was checked and holds>.

</details>

<details>
<summary>🤖 Prompt for AI Agents (all findings)</summary>

```
You are fixing review findings on pull request #<number> (branch <head branch>). The review was done at commit <short sha>; the code may have changed since.

For EACH finding below, in order:
1. Verify it against the current code first: re-read the cited file and lines (they may have moved), follow the call chain named in the finding, and decide whether it is still a real problem. If it is not (already fixed, or the premise is wrong), skip it and record why.
2. Only if it is real: make the smallest fix that resolves it, following <the repository's rule files, by path, as the orchestrator found them>.
3. Add or update the tests named in the finding and run them the way the repository's own instructions say. Never loosen or skip a test to make it pass.
4. Commit the way the repository's own rules say.

At the end, report per finding: its number, fixed / skipped (with the reason) / partly fixed, and the commit.

Findings:

1. [<SEVERITY>] `<file>` lines <start>-<end>: <one-line title of the finding>
   Fix: <the self-contained fix prompt of that finding: what to change and where, which test to add or update>

2. [<SEVERITY>] `<file>` lines <start>-<end>: <one-line title of the finding>
   Fix: <...>
```

</details>
````

## Rules

1. **One summary per reviewed pull request**, with the findings posted on that pull request. A cross-PR finding is listed on the pull request that should change. A merged pull request has no summary; its proposed follow-ups are in the orchestrator's final report.
2. **The first paragraph answers four things**, in this order: the commit checked, who covered what, how findings were verified, whether tests ran. A check that did not happen is stated as not done, with the reason.
3. **The count line** gives the total and the three severities, zeros included, and matches the table.
4. **The table is numbered**, most severe first. Each finding's title is a link to its inline comment, with the URL as the hosting service returned it and as the orchestrator verified it; never a guessed address. `Where` is the file name and line. A finding that went into the review body instead of an inline comment links to the review.
5. **Three collapsed sections, always in this order:** what is worth a look but not confirmed, what was checked and found correct, and every fix prompt in one block. A section with nothing to say keeps its heading and says `None.`
6. **The fix prompts are the ones posted inline**, in the table's order and with its numbers, so the block can be handed to one agent as is. Step 2 of its preamble names the rule files of the repository under review, by path. Leave that clause out when the repository has none; never fill it with another repository's files or rules.
7. **Only the marks shown** (`🔴 Critical`, `🟠 Major`, `🟡 Minor`, and the three section marks), always next to their word.
8. **No personal data** and no AI signature or attribution line. Reviewers are named by the area they covered.
9. The template's `github.com/<owner>/<repo>` addresses stand for whatever the hosting service returned; use its real URLs.
