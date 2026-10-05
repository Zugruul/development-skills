---
tags: [review, quality, verification, process]
paths: []
strength: 1
source: "task-524"
confidence: direct
graduated: false
created: 2026-08-02
last-touched: 2026-08-02
---

# Two independent reviews, each allowed to fail the work

One review pass finds what the author already half-suspects. Two independent
passes, each briefed to REPRODUCE rather than read, and each required to end in
an explicit PASS or FAIL, find a different class of thing entirely.

Observed on a merged skill: a spec-compliance pass proved three "hard rules"
the design asserted but the code did not honor; a code-quality pass proved two
remote command injections reachable through ordinary operator flags. Both had
survived my own review and a green suite.

The part worth internalising: my FIXES for the first round introduced a worse
regression than the bugs they closed — the payload stopped working entirely —
and only the third round caught it. Plan for multiple rounds. A first-round
FAIL is the normal case.

Brief reviewers to run the code, not read the diff. "Proven by execution"
findings were the only ones that turned out to be both real and correctly
diagnosed; every finding that came from reading alone needed re-verification.
