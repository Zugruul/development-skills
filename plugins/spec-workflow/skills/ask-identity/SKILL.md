---
name: ask-identity
description: Ask one identity's brain (dev/reviewer/orchestrator, or any custom role with a .claude/identities/<role>/brain/ dir) a question grounded in what it has learned, without running a build iteration or touching the board. Use for '/spec-workflow:ask-identity <identity> <question>' — e.g. clicked from a neural-view "Talk" deep link, or any time you want a quick answer informed by one role's accumulated lessons instead of a full build-loop pass.
allowed-tools: Bash, Read
---

# Ask one identity's brain

ARGUMENTS: `<identity> <question...>` — the first token names the role
(`dev`, `reviewer`, `orchestrator`, or a repo-specific custom role like
`judge`/`player`), everything after it is the question, verbatim.

This is a **read-only consult**, not a build-loop iteration: no board writes,
no tests, no implementation work, no commits. If the question actually asks
for code changes, say what you'd need to do it properly (as a normal task)
instead of just doing it here.

## Steps

1. Confirm the brain exists: `.claude/identities/<identity>/brain/notes/`. If
   the directory is missing or empty, say so plainly — don't fabricate
   lessons that role hasn't learned yet — but you can still answer from
   general reasoning if useful, clearly labeled as not brain-grounded.
2. Recall relevant notes, using keywords pulled from the question:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/brain.sh" recall <identity> --keywords "<keyword1,keyword2,...>"
   ```
   `recall` matches note tags/paths against what you pass — it is not full-text
   search, so pick a handful of concrete nouns from the question, not the
   question itself. See the `brain` skill for the full contract.
3. If recall comes back empty (common for open-ended questions that don't
   land on any note's tags), fall back to a direct skim: read
   `.claude/identities/<identity>/DIRECTORY.md` or
   `.claude/identities/<identity>/brain/notes/*.md` — these brains are small
   (a handful to a few dozen notes), so reading them directly is cheap and
   more reliable than forcing a keyword match.
4. Answer using ONLY what that identity's brain actually says as grounding.
   Quote or paraphrase the specific note(s) you're drawing from. If the
   brain doesn't cover the question, say that explicitly — the point of
   asking a specific identity is its accumulated, repo-specific experience,
   not general knowledge dressed up as if it came from the brain.

Never write to a brain from here — minting/pruning/graduating is
orchestrator-only tooling reserved for actual retros (see the `brain`
skill). This skill only reads.
