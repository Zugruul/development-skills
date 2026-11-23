---
name: orchestrate-code-reviews
description: Makes the current agent the orchestrator of a code review of a group of related pull requests inside Herdr - takes the orchestrator role, maps how the pull requests fit together (stacked, or pairs across repositories), puts one reviewer agent on a Herdr worktree per open pull request plus one cross-PR checker, has them check the existing review comments and look for new problems as drafts only, then has one agent per pull request post the replies and a single COMMENT review, verifies what was posted, and writes and posts a summary comment on each pull request. Use for '/herdr:orchestrate-code-reviews' followed by the pull request URLs and optional notes, 'review these PRs together', 'run a code review of this stack with reviewer agents'. Never approves, requests changes, merges or pushes. Requires running inside Herdr and a command-line client for the hosting service (gh for GitHub).
allowed-tools: Bash, AskUserQuestion
---

# Orchestrate a code review of related pull requests

`ctl` = `python3 "../../scripts/herdr_ctl.py"` (resolve the path relative to this `SKILL.md`). Run `python3 "../../scripts/herdr_ctl.py" check` first; if it prints `HERDR UNAVAILABLE`, say so and stop.

When you script several calls, define `ctl` as a shell function with the absolute path: `ctl() { python3 "<absolute path>/scripts/herdr_ctl.py" "$@"; }`. A variable holding `python3 <path>` is not split into words by zsh, so `$ctl check` fails there.

Treat the rest of the request as: the pull request URLs, and optional notes. The notes may carry the reviewer agent kind, a worktree, workspace or pane to use, **facts already confirmed** and **leads to verify**.

The pull requests are reviewed as one change: they may be stacked on each other or span several repositories, and a problem often shows only where two of them meet.

## Hard rules

They hold for you and for every agent you start, and go into every brief:

- Never mark a pull request ready, approve it, request changes, merge it or push to its branch. The only review event is `COMMENT`.
- No personal data (names, emails, phone numbers) in anything posted or reported.
- No AI signature or attribution lines anywhere.
- Never read secrets or credential files (environment files, package-manager or cloud credentials, key files, anything the repository's own rules mark as secret).
- Each repository's own rules apply to work in it (section 3).

## 1. Inputs first

Before anything else, check what you were given.

- **No URLs, or placeholders** (`<url>`, `PR-1`, an empty list): ask for the pull request URLs. Do not look for "the obvious ones" yourself.
- **Reviewer agent kind** not given: ask, and state the default in the question: your own kind (the `kind` of your row in `python3 "../../scripts/herdr_ctl.py" roster`). A different kind from the authors' gives a more independent read; that is the user's choice.

Ask both in one question when both are missing. Start nothing until the URLs are real.

## 2. Take the role

Follow `../orchestrate/SKILL.md` now, exactly as written: the role, the name, the skills it loads, the roster, and its rules for how an orchestrator works. This skill adds to it and repeats none of it.

One addition on the name: `orchestrator` is often already taken by a live agent. On `NAME TAKEN`, take `orchestrator-<what you coordinate>`, here `orchestrator-pr-review`, check it with `python3 "../../scripts/herdr_ctl.py" name orchestrator-pr-review`, and tell the user.

Make a scratch directory of your own outside every repository (your host's session scratch directory when it has one, otherwise `mktemp -d`). Briefs, drafts, the merged posting files and the summaries live there, never in a checkout.

## 3. Read the group

For each pull request, read its metadata with the hosting service's client, read-only (for GitHub, `gh pr view <url> --json number,url,title,author,state,isDraft,headRefName,headRefOid,baseRefName,headRepository,baseRepository,body`): repository, number, title, author, head branch, base branch, head commit, state, draft or not, and the pull requests its description links.

Then work out how the group fits together, before any review:

- which pull request is stacked on which (its base branch is another one's head branch);
- which are pairs across repositories (for example a producer and its consumer);
- which are already merged or closed.

**State this map in your first report**, with each pull request's number, owner, title and, for an open one, its head commit. It is the commit the review is made at.

- **A merged pull request is reference behaviour only.** It gets no worktree and no reviewer of its own: agents read it from the freshly fetched default branch (`git fetch origin <default branch>`, then read from `origin/<default branch>`). Read it, never comment on it, and open nothing for it. A fix that belongs in it goes into your final report as a proposed follow-up (file, line, change).
- **A pull request closed without merging:** say so and ask the user whether it is part of the review.
- **Draft pull requests** are reviewed like the others and stay drafts.

**Discover each repository's rule files** once per repository under review, from its default branch or an existing checkout: its agent instructions, its security rules, its testing and contribution documents, its pull request template (names vary: `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, a `SECURITY*` file, documents under `docs/`). Keep the list of paths you found per repository; it goes into every brief and every fix prompt for that repository. A repository with no such file gets "none found", not a guess. Do not copy one repository's rules into a brief for another.

## 4. Worktrees

One Herdr worktree per open pull request, on its head branch, based on the freshly fetched remote branch. Follow `../worktree/SKILL.md` for every step (location rule, read-only plan, creation); what follows only says which worktrees.

- **Reuse what the request names.** A worktree, workspace or pane the user named already exists: use it and create nothing in its place.
- **Reuse a worktree that already has the branch checked out.** Check `herdr worktree list --cwd <primary checkout>` first, and open it with `herdr worktree open` when it has no workspace.
- In a workspace you did not create alone, **leave every pane you did not create alone**: start no agent in it, send it no keys, never close it. Your agents get tabs of their own there.
- A reused checkout may not be at the pull request's head commit, and may hold someone's local work. Never pull, reset, stash or switch branches in it. Say what you found and ask the user; reviewers can read the head commit with `git show` without changing the checkout.
- For a new worktree: fetch the head branch first, then plan with `--branch <head branch> --base origin/<head branch>`. A pull request from a fork has its head in another repository: fetch the pull request's head ref the way the hosting service offers it, and say in the plan which ref you used.
- **Label every workspace you create so its sidebar entry says what it holds**: the pull request's number, who owns it, and a short description, in that order: `pr-<number>-<owner>-<short description>`, for example `pr-2609-<owner>-connection-pool-timeout`. `<owner>` is the login of the pull request's author; the description is two to four words from its title. Build it with `python3 "../../scripts/herdr_ctl.py" label <text>` and pass it as `--label` to the plan; never leave the label to be derived from the branch. Keep it under about 40 characters, since the sidebar cuts long titles and the number and owner must survive. When the group spans repositories, put the repository before the number (`pr-<repo>-<number>-<owner>-...`). The owner's login is for this label only: it does not go into comments, drafts or summaries.
- A workspace you reuse keeps the label it has: it is not yours to rename. Say in your first report which pull request it holds, and offer the rename (`herdr workspace rename <workspace id> <label>`) when its label does not show the number.
- Invoking this skill asks for these worktrees, so show the planned set (branch, base commit, path each) in your first report and create them. Ask first for anything the plan does not show as a plain creation (`DO NOT CREATE`, a dirty primary checkout, a repository Herdr does not trust).

## 5. Reviewers

Start the agents with `../agent/SKILL.md`, the kind from section 1:

- **One reviewer per open pull request**, in that pull request's worktree. Its name carries the role, the number, then the same short description as the label: `review-<number>-<short description>`, for example `review-2609-connection-pool`. The number comes second so it is still readable when the sidebar cuts the name. A name has at most 32 characters: shorten the description, never the number, and check it with `python3 "../../scripts/herdr_ctl.py" name <name>`.
- **One cross-PR checker** when the group has more than one pull request, named for the pull requests it spans (`review-cross-2609-2611`, or `review-cross-pr` when the numbers do not fit), in a tab of its own in the workspace of the pull request the others build on. It reads every worktree and the merged pull requests on the default branch.

Build each first prompt from `../../references/review-brief.md`: the template there, filled in for that agent, written to a file in your scratch directory and sent once with the `prompt` skill (`../prompt/SKILL.md`). Every brief carries:

- the hard rules above, word for word;
- the rule files of each repository the agent works in, by path, with the instruction to read them first and follow them;
- the map of the group, the head commit to review at, and for a stacked pull request the base it is reviewed against;
- the three steps of the review, the proof standard and the draft format, from the reference;
- the rules for a shared worktree, from the reference: more than one agent reads each checkout;
- the user's **facts already confirmed** and **leads to verify**, when the request has them, each under that label and in the user's words. A fact is context, not something to re-prove. A lead is a claim to check: one that turns out not to be real is reported with its evidence;
- the path of its draft file in your scratch directory, and "stop and ask in your own pane when you need a decision".

**Reviewers draft; they post nothing.** Several agents review one pull request (its own reviewer and the cross-PR checker), and one review per pull request needs a single poster. Each agent writes its replies, findings, unconfirmed items and checked-and-correct notes to its draft file and stops.

## 6. Listen

Follow all of them with `../listen/SKILL.md`, and report every time in the format of `../../references/report.md`. This skill adds these lines inside an agent's entry, after `prs:` and before `verified:`, leaving out what does not apply:

| Line | Value |
| --- | --- |
| `reviews:` | the pull request it reviews (`<owner>/<repo>#<number>`), or `cross-PR` |
| `draft:` | its draft file and what it holds (`3 findings, 1 reply, 2 unconfirmed`), once written |
| `posted:` | the URL of the review it submitted, once you have verified it (section 8) |
| `result:` | its result file, once written (section 9) |

The `prs:` block stays for pull requests an agent opened; reviewers open none. A reviewer's question goes to the user as the `orchestrate` skill says.

## 7. Merge the drafts, then post

When every draft is in, build one posting file per open pull request in your scratch directory from the drafts of all agents:

- A finding goes on the pull request that should change. A cross-PR finding links the other pull request and the exact line it conflicts with.
- **A finding two agents both found is posted once**: keep the version with the stronger proof and the better fix prompt.
- Unconfirmed items are not posted. They go to the summary's "Worth a look" section.
- A finding against a merged pull request is not posted anywhere; it becomes a proposed follow-up in your report.
- You merge and deduplicate. You do not add findings of your own or rewrite an agent's claim; a draft that looks wrong goes back to its agent as a question.

Then have **one agent per pull request**, its own reviewer, post from that file (the `prompt` skill, with the file's path). It:

1. **Re-checks every claim it posts on another agent's behalf** against the code at the head commit and against that draft's own unconfirmed section, and drops or rewords what does not hold. It reports each such deviation: which item, what it found, what it posted instead.
2. Posts the replies to existing review threads.
3. Submits **one `COMMENT` review** at the reviewed head commit holding every new finding as an inline comment, in the comment format of the brief reference. A finding on a line the hosting service will not accept an inline comment for goes in the review body with its file and line.
4. Reports the URL of the review and of each inline comment and reply.

On GitHub every reply in an existing review thread shows up in the timeline as a `COMMENTED` review entry of its own. So "one review per pull request" means one review for the **new** inline findings; the extra entries from replies are expected, not a mistake. Say so in your report.

If the pull request's head moved since the review started, do not post against the old commit silently: tell the user what changed and ask whether to re-check the affected findings first.

## 8. Verify what was posted

Links in your report come from the hosting service, not from an agent's message. After each poster settles, check through the API, read-only (for GitHub: `gh api repos/<owner>/<repo>/pulls/<number>/reviews` and the same path ending in `/comments`, filtered to the posting account, and `gh pr view`):

- the reviews and review comments by the posting account are the ones the posting file called for: one `COMMENT` review with the new findings, the replies, nothing else, no approval and no change request;
- the pull request's state and draft flag are what they were at the start;
- the worktree is clean and at the same commit: no temporary test file left, nothing committed, nothing pushed.

Report what does not match as it is. Do not delete or edit a posted comment on your own; ask the user.

## 9. Close down what you created

A finished review leaves nothing open: no worktree, no workspace and no agent window that exists only because of it. What stays is each agent's report back to you, as a file. The `orchestrate` skill says to leave your own panes and worktrees until the user agrees the work has landed; invoking this skill is that agreement for what this review created, once its comments are posted and verified. Say in your first report that the worktrees you create are removed at the end, so the user can ask to keep them; if they do, keep them.

Per pull request, after section 8 passed for it:

1. **Get the reviewer's report back.** Ask it (the `prompt` skill) to write its result file in your scratch directory and stop: what it posted, with the URLs; its deviations; whether tests ran; anything it left unfinished. Wait until the file is there and read it. After this the agent is no longer needed: questions about its work are answered from its draft and result files.
2. **Check the checkout is as it was found:** `git -C <worktree> status --porcelain` prints nothing, its commit is the one reviewed, and nothing is unpushed. Otherwise do not remove it: say what is there and ask the user.
3. **Close only what you created for this review:**
   - a worktree you created: `herdr worktree remove --workspace <workspace id>`, never with `--force` and never with `--trust-repository`. Then read `herdr worktree list --cwd <primary checkout>` and `herdr workspace list`: the worktree and its workspace must both be gone. Close a workspace that is still open with `herdr workspace close <workspace id>`, and delete the local branch the worktree made with `git branch -d` (never `-D`). A refusal is reported, not forced.
   - a tab you created in a workspace you reused: `herdr tab close <tab id>`. The workspace, its worktree and every other pane stay.
   - the cross-PR checker's tab last, when every pull request it drafted for is posted and verified.

**What is never closed here:** a worktree, workspace or pane you reused or did not create; a checkout with changes you cannot account for; an agent that is working, blocked or has an unanswered question; and everything belonging to a pull request whose posting failed or whose check in section 8 did not match, which stays open for the user to look at. If the review stops before posting, nothing closes without asking.

Report each agent as DONE before you close it; the report format then names it once as `done -> gone` and drops it. Your scratch directory stays: the drafts, the result files and the summaries are the record of the review. Give its full path in the final report.

## 10. Summary and final report

Write one summary per reviewed pull request **in the format of `../../references/review-summary.md` exactly**, to a file in your scratch directory, and show it to the user. It holds: the commit checked, who covered what, how findings were verified, whether tests ran; the count line by severity; the numbered table with each finding linked to its inline comment; then the collapsed sections for unconfirmed items, what was checked and found correct, and every fix prompt in one block. The fix prompts name that repository's own rule files from section 3 and nothing from another repository.

**Always post the summary as a pull request comment**, on every reviewed pull request, also when it has no findings, once section 8 passed for it: the table links the inline comments, so it goes up after they are posted and verified. Post it yourself from the file (for GitHub: `gh pr comment <url> --body-file <summary file>`) and then check through the API, read-only, that the summary comment by the posting account is there, once, with the file's content, and take its URL from the API. A merged pull request gets no summary, and neither does one closed during the review. Post nothing for a pull request whose posting or check in section 8 failed: say so instead. Give the summary file's full path as well.

End with a last orchestrator report (it may list no agent any more), then in prose:

- per pull request: the replies made and why, the findings posted with their verified links, the verified link of the summary comment, the poster's deviations, the leads that turned out not to be real with their evidence, and the unconfirmed items;
- per merged pull request: the proposed follow-ups (file, line, change);
- the cross-PR findings and a suggested merge order;
- what you verified in section 8 and what is only claimed, such as an agent's statement that it ran tests;
- what you closed in section 9, and what you left open and why, each with its path or workspace.
