# Brief format

How the graph orchestrator writes the first prompt of every agent node. It is a recommended template, not a strict schema: keep its order and its plain headings, add a section when the work needs one, and leave out a section that would be empty. Nothing in it belongs to one repository or one task.

## Shape

1. **The role file's body**, with its placeholders filled (`{node}`, `{output_path}`, and `{run}`, the run id `lane.sh node --status running` printed): Objective, Start, Boundaries, Tools and sources, Output, Ask, End. Paste it as it is; do not shorten or reword the role's rules.
2. **`## Brief`**, written for this node:
   - **Where**: the checkout path, the branch and the base commit it starts from (`from origin/main <short sha>`), and where the relevant code lives (the plugin or package, the files or folders, the tests).
   - **Goal**: one short paragraph saying what should be true when the node is done, in the user's terms. Start from the node's `brief` in the lane file.
   - **Asks**: a numbered list of the concrete things to do, one per item, each checkable.
   - **Constraints from the user**: what they ruled in or out, in their words where possible. When the work rests on a premise (a tool supports something, a file exists, a behaviour is a bug), say what to do if it turns out false: stop and ask, with what was found.
   - **Gate**: the exact gate command the lane will run, so the agent runs the same one before it finishes.
   - **Notes**: small practical points that save a round trip (for example `GIT_PAGER=cat`, a slow test suite, a version bump convention to follow, where earlier similar changes are in `git log`).

Optional sections, added only when they have content, under `## Brief` or as their own `##` heading after it:

- **Inputs**: what earlier nodes produced (report or draft paths, commit ids), never pasted transcripts.
- **Out of scope**: what looks related but must not change.
- **Definition of done**: when the lane's done checks go beyond "the gate passes".
- **Role-specific parts**: for a `pr-reviewer`, the filled-in template and formats of `review-brief.md`; for a `reviewer`, the base ref to diff against; for a `planner`, the example patterns. These keep their own references and come after `## Brief`.

## Example

A generic example; the angle-bracket parts are filled per node.

```markdown
<the role file's body, placeholders filled>

## Brief
Checkout: <worktree path>, branch <lane branch> (from origin/main <short sha>). Code: <package or plugin path> (<main files>; tests: <test files>).

<One short paragraph: what is wrong or missing today, and what should be true afterwards.>

1. <First concrete change.>
2. <Second concrete change.>
3. <A doc or changelog update, if the repository expects one.>

Constraints from the user: <what they ruled in or out>. If <the premise the work rests on> turns out false, stop and ask with what you found.

Gate to pass before finishing:
<exact gate command>

Notes: use GIT_PAGER=cat. Bump the version per the repository's convention (see git log).
```

## Follow-ups and retries

A follow-up prompt to a running agent (a retry after a failed gate, a reviewer's findings, the user's answer to a question, scope the user added) is short and uses the same parts it needs: what changed or failed (the gate's last lines, the exact error, the findings file path), the numbered asks, and the gate command again when it matters. Do not resend the role body: the agent keeps its context.
