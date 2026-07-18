---
tags: [board, process]
paths: []
strength: 1
source: "PR#187/#208 iteration, live-encountered"
graduated: false
created: 2026-07-18
---

board.sh comment N takes the body ONLY via stdin (heredoc or file redirect) -- there is no positional-arg form. Passing the text as a trailing argument (`board.sh comment N "text"`) silently ignores it and stdin reads empty, producing "GraphQL: Body cannot be blank (addComment)". Always use `board.sh comment N <<'EOF' ... EOF` or `board.sh comment N < file`. Related: [[board-comment-bodies-via-file]].
