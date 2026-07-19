---
name: ask-identity
description: Ask one identity's brain (dev/reviewer/orchestrator, or any custom role with a brain directory under .claude/identities/) a question grounded in what it has learned, without running a build iteration or touching the board. Use for '/spec-workflow:ask-identity' with an identity name and a question — e.g. clicked from a neural-view "Talk" deep link, or any time you want a quick answer informed by one role's accumulated lessons instead of a full build-loop pass.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# Ask one identity's brain

Treat the remainder of the user's request (after the command name) as `<identity> <question...>`: the first token names the role (`dev`, `reviewer`, `orchestrator`, or a repo-specific custom role like `judge`/`player`), everything after it is the question, verbatim.

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
   bash "../../scripts/brain.sh" recall <identity> --keywords "<keyword1,keyword2,...>"
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

   **Cached notes are knowledge, not the answer.** Match the answer's scope
   to the QUESTION's scope, not to whatever note happens to exist:
   - Broad/open-ended question (e.g. "enumerate the weird interactions of
     X") → research the full scope the question implies (run the identity's
     own verification protocol across everything relevant); a cached note
     about one similar case informs the work but must not narrow the answer
     to just that case.
   - Specific question with exact preconditions → answer exactly those
     preconditions, even if a cached note covers a slightly different setup.
   Never surface a cached note verbatim as if it were the user's answer when
   its scope doesn't match what was asked.
5. **Human validation loop** — when the answer is a ruling or verifiable
   claim (any brain-grounded adjudication, not just card rulings), finish by
   asking through the host's structured-input facility: "Is this ruling
   correct?" with exactly three options: "It is" / "It is not" / "I'm unsure".
   (On Claude Code, this is the AskUserQuestion tool.) Then:
   - **It is** → mint (or re-mint) the identity's cached note for this
     answer with `CONFIDENCE: human-confirmed <date>` (bump strength on
     repeat confirmations).
   - **It is not** → mark any existing note `CONFIDENCE: disputed — do not
     answer from this note`, then re-run the identity's verification
     protocol from scratch against the primary sources; only re-mint once
     the correction is confirmed.
   - **I'm unsure** → mint/update with `CONFIDENCE:
     unsure-pending-confirmation` and note what external confirmation is
     needed; never graduate unconfirmed notes.
   If the identity defines its own validation protocol (e.g. the judge's
   `card-interaction-protocol`), follow that note's wording — it wins over
   this generic loop.

6. **Cross-identity awareness, never auto-consult** (#163, human decision —
   see `docs/design/cross-identity-correlation.md` §6.2, hard rule). If the
   recalled note(s) carry `entities:` and
   `.claude/identities/entity-index.json` shows another role holds notes
   correlated to the same entity, you may STATE that fact — "the `<role>`
   brain holds N note(s) about `<entity>`" — and point the user at
   `/spec-workflow:ask-identity <that-role> ...` or an explicit `consult`.
   You must NEVER pull that other brain's content into THIS answer yourself.
   Identities answer from their own notes only; they learn about another
   identity's knowledge only by the user (or the orchestrator) explicitly
   asking that identity, or via a logged `consult` followed by a
   provenance-stamped mint (`learned-from`/`source-note`) — never implicitly,
   never inside a single ask-identity turn. This boundary is intentionally
   stricter than `ask-brain`, which is whole-brain and may consult across
   roles on your behalf; `ask-identity` speaks for exactly one identity.

Writes to a brain from here are limited to the validation loop in step 5
(confidence-stamped mints/updates of the note backing the answer just
given). Everything else — pruning, graduating, retro minting, and any
cross-role consult — remains orchestrator-only tooling reserved for actual
retros or explicit user-directed consults (see the `brain` skill). No board
writes, no commits.
