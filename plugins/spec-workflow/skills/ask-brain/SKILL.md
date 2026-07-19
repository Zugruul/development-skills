---
name: ask-brain
description: Ask a repo's identity brains collectively (every role that has a brain directory under .claude/identities/, not just one) a question grounded in what they've learned, without running a build iteration or touching the board. Use for '/spec-workflow:ask-brain' followed by the question text — e.g. clicked from a neural-view "Talk" deep link when you want the whole repo's accumulated knowledge rather than one specific identity (for that, use /spec-workflow:ask-identity instead).
allowed-tools: Bash, Read
---

# Ask the whole repo's brains

Treat the remainder of the user's request (after the command name) as the question, verbatim.

Read-only consult across every identity in this repo, not a build-loop
iteration: no board writes, no tests, no implementation work, no commits.

## Steps

1. List identities with a brain: any `.claude/identities/*/brain/notes/`
   directory that exists and isn't empty.
2. For each one, recall relevant notes using keywords pulled from the
   question:
   ```bash
   bash "../../scripts/brain.sh" recall <role> --keywords "<keyword1,keyword2,...>"
   ```
   (`recall` matches tags/paths, not free text — see the `brain` skill.) If a
   role's recall comes back empty, skim its
   `.claude/identities/<role>/DIRECTORY.md` or `brain/notes/*.md` directly
   instead of concluding it has nothing relevant — these brains are small.
3. Answer using the combined notes across all roles. When a lesson is
   specific to one identity's perspective (e.g. something only the reviewer
   would flag), say which role it came from rather than blending everything
   into one voice — that context is often the useful part of the answer.
4. If nothing in any brain bears on the question, say so rather than
   answering from general knowledge as if it were repo-grounded.
5. **Cross-identity correlation** (#163): collect the `entities:` frontmatter
   of every note recalled in step 2. If any are present, look each up in
   `.claude/identities/entity-index.json` (regenerate it first via
   `bash "../../scripts/brain.sh" entity-index` if the file is
   missing or looks stale — it's cheap and derived, never hand-edited). For
   an entity correlated into a role you haven't already recalled from,
   **consult** that role explicitly — the consumer is whichever role's
   recalled note triggered the correlation (that role is "asking" the
   owner):
   ```bash
   bash "../../scripts/brain.sh" consult <consumer-role> <owner-role> <slug>
   ```
   Fold the consulted note into the answer, attributed to its owner role like
   any other cross-role material (step 3) — `consult`'s own logging is the
   one sanctioned exception to "never write to a brain from here" (it writes
   a log line to the owner and a recurrence counter to the consumer, never
   note content).

Never write to a brain from here beyond that one sanctioned exception — this
skill otherwise only reads.
