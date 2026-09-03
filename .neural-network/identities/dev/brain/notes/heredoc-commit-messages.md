---
tags: [git, shell]
paths: ["**"]
strength: 1
source: "#72 retro"
graduated: false
created: 2026-07-08
---

A backtick pair inside git commit -m "..." is command substitution — it silently eats words from the message. Any commit message containing backticks goes through -m "$(cat <<'EOF' ... EOF)" with the quoted delimiter.

Related: [[bash32-empty-array-set-u]]
