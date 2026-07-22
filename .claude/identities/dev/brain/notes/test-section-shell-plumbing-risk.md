---
tags: [tests, bash, quoting, heredoc, bash32]
paths: ["plugins/spec-workflow/tests/**"]
strength: 2
source: "PR-close #303 dev CONSULT confirmation"
graduated: false
created: 2026-07-22
---

In new-module tasks the real defect risk concentrates in the bash test-section plumbing, not the code under test. Confirmed hard gotcha (bash 3.2): an apostrophe inside a <<'PY' heredoc BODY breaks parsing when the whole heredoc is wrapped in a double-quoted command substitution x="$(... <<'PY' ... PY)" — 'unexpected EOF while looking for matching quote' even though the quoted delimiter should make the body literal. Repro: b="$(cat <<'PY'\n# the CLI's own thing\nPY\n)". Fix: no apostrophes in heredoc bodies inside $(), or move the text out. Also: double-quoted strings need no \x27 escapes; python -c helpers must shift-and-forward "$@".

Related: [[extend-house-fixture-style]] [[bool-before-int-guard]]
