---
tags: [process, feedback]
paths: ["**"]
strength: 2
source: "user directive 2026-07-19, session close-out"
graduated: false
created: 2026-07-08
---

Session end is an iteration boundary: when feedback is enabled, closing a session (user /clear, finish, goal cleared) REQUIRES (1) a kind: session-feedback document into .claude/feedbacks/feed.yaml -- session-level lessons per-iteration entries missed -- triaged, committed, pushed; then (2) the close-out report in the default format in .claude/identities/orchestrator/ROLE.md: merged-this-session, in-flight with lane+branch+SHAs+uncommitted-state+next-action, board state, warnings, closing line. The close-out is the only handoff a cleared successor gets.

Recurrence (session 2026-07-18/19, user directive): the dense technical close-out format alone is not what a LIVE user wants to read -- they explicitly asked for a separate, simple "Tasks completed this session" plain-language enumeration (one line per task, human-readable, no spec jargon), required at EVERY continue/stop checkpoint the loop offers, not just final close. Both formats now live in ROLE.md: the simple enumeration leads (for the live user), the dense technical format follows (for a cleared successor session's resumability).

Related: [[orchestrator-cd-prefix-own-commands]]
