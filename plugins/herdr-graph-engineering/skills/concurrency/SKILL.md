---
name: concurrency
description: Teaches an orchestrator how to run many lanes and agents at once without them stepping on each other - spotting lanes that edit the same files, folding an ask into a running lane or starting a new one, merge order, merging origin/main into a running branch, version bumps across parallel pull requests, one writer per checkout, and how to honour a cap the user asks for. Pure guidance, no state. Use for '/herdr-graph-engineering:concurrency', 'how many agents should run', 'keep at most 3 agents', 'these lanes conflict', 'which PR merges first'.
---

# Concurrency: running many lanes at once

This skill is judgement only. It keeps no files, no state and no config, and it adds no rule the scripts enforce. Read it when several lanes run at once, when lanes may collide, or when the user asks about a cap. If invoked with an argument (`$ARGUMENTS`), treat it as the situation to reason about.

## No limit by default

An orchestrator has **no limit by default**: no maximum of open lanes, no maximum of running agents, no queue. Every idea the user gives becomes a lane and starts as soon as its worktree is approved. What keeps that safe is the judgement below, not a number.

## Lanes that edit the same files

The usual collision is not two agents in one checkout; it is several lanes on separate branches all editing the same few files. In this repository, parallel graph-engineering lanes repeatedly touched `scripts/panel.sh`, `scripts/status.sh`, `scripts/lane.sh`, `skills/orchestrate/SKILL.md`, the stub Herdr (`tests/fixtures/stub-herdr/herdr`) and `README.md`, plus every version file. Each lane was green on its own; the conflicts appeared at merge time.

Spot it **before** starting a lane:

- For every open lane branch: `git diff --stat <base>...<branch>`. The files listed are the lane's footprint.
- Read the new brief for the files it names or clearly implies (a panel change means `panel.sh` and `status.sh`; a new skill means `README.md` and the manifests).
- An overlap is not a reason to refuse. Decide, and say which, in the report: fold the ask into the running lane, start a new lane and note the expected conflict, or start it after the other lane's pull request merges.

## Fold into a running lane, or start a new one

- **Fold** when the ask changes the same behaviour the running lane is building, would touch the same lines, or would make the running lane's pull request wrong without it. Send it to the lane's implementer as a follow-up (with the `herdr:prompt` skill) and record it in the lane's report.
- **New lane** when the ask is reviewable on its own, could ship without the running lane, or the running lane is already in its gate or review. A pull request should stay one idea.
- Never fold into a lane whose pull request is already approved or under review; that invalidates the review.

## Merge order and merging main in

- The orchestrator never merges a pull request; the user does. It can suggest an order: the smallest, least-conflicting change first; the one the others build on before them.
- When `origin/main` moves while a lane is running, bring it in **before** that lane's gate and before its pull request is marked ready: `git fetch origin && git merge origin/main` on the lane branch, a merge commit, **never rebase** a branch that has a pull request or that other agents have seen. Resolve conflicts in the lane's checkout, then rerun the gate.
- After one parallel pull request merges, every other lane that overlaps it merges `origin/main` again and reruns its gate.

## Version bumps across parallel pull requests

Parallel pull requests each bump the plugin version. Give each lane **the next number not already taken** by an open branch (look at the version files on each open branch), not "current plus one". On a merge conflict in a version file, the later branch **keeps the higher number**; never go back down. Every place that carries the version moves together (both plugin manifests, the marketplace entry, any other version file the repository names).

## One writer per checkout

**One writer per checkout.** Only one agent edits a given worktree at a time. Two writers in one checkout interleave edits, commit each other's half-finished work and break each other's tests. A second implementer gets its own lane and worktree. Readers (reviewers, investigators) may share a checkout only if they do not write: no edits, no commits, no `git checkout` of another ref.

## A reviewer and an implementer on the same pull request

- The reviewer reviews a fixed commit. Give it the commit id; if the implementer pushes meanwhile, the review is of the old commit and says so.
- Do not let the implementer fix findings while the review runs. Wait for the review, then send the findings to the implementer as one follow-up.
- After the fixes, a new review (or a check of just the fixed findings) runs against the new commit.

## When the user asks for a cap

The user may say "keep at most N agents" (or N lanes). Then, for the rest of the session:

- Count running agents (or open lanes) before starting one. At the cap, the new work waits in a **queue** you hold in your own context, in the order it arrived.
- Say so: every report lists the queue (`queued: lane-a, lane-b`) and why it waits ("cap of 3 agents reached").
- When an agent finishes, start the next queued item and say so.
- The cap holds until the user lifts or changes it. Do not invent a cap yourself; you may suggest one when cost or attention calls for it.

## Cost and attention

Every running agent costs tokens and, sooner or later, asks the user something. Many agents at once means many questions at once, and the user becomes the bottleneck. Batch questions where possible, tell the user how many lanes are waiting on them, and when the questions pile up, suggest a cap rather than imposing one.
