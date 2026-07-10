---
name: ask-brain
description: Ask a repo's identity brains collectively (every role that has a .claude/identities/<role>/brain/, not just one) a question grounded in what they've learned, without running a build iteration or touching the board. Use for '/spec-workflow:ask-brain <question>' — e.g. clicked from a neural-view "Talk" deep link when you want the whole repo's accumulated knowledge rather than one specific identity (for that, use /spec-workflow:ask-identity instead).
allowed-tools: Bash, Read
---

# Ask the whole repo's brains

ARGUMENTS: `<question...>` — the question, verbatim.

Read-only consult across every identity in this repo, not a build-loop
iteration: no board writes, no tests, no implementation work, no commits.

## Steps

1. List identities with a brain: any `.claude/identities/*/brain/notes/`
   directory that exists and isn't empty.
2. For each one, recall relevant notes using keywords pulled from the
   question:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/brain.sh" recall <role> --keywords "<keyword1,keyword2,...>"
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

Never write to a brain from here — this skill only reads.
