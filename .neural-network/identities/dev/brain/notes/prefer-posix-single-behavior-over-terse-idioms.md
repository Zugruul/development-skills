---
tags: [shell, portability, ci]
paths: ["**"]
strength: 1
source: "PR#180 CDX-010 post-merge retro"
graduated: false
created: 2026-07-19
---

When a shell one-liner needs to survive multiple sed/awk/grep IMPLEMENTATIONS (not just versions of the same implementation), prefer constructs with a SINGLE POSIX-specified behavior over a shorter-but-ambiguous idiom -- even when the shorter version currently works fine in the one environment in front of you. Sed range addresses (`N,/regex/d`) are a classic offender: BSD and GNU sed disagree on whether the end-regex check applies on the range's own start line, which matters specifically when that start line ALSO happens to match the end pattern (e.g. stripping YAML frontmatter, whose own first line is `---`, the same string the closing delimiter uses). `awk`'s line-counter plus `tail -n +N` has no such ambiguity and is portable across GNU/BSD/busybox.

If you only have ONE sed/awk flavor to test against, that fact is itself a signal to actively AVOID the common-but-ambiguous idioms (sed ranges, `-i` with/without a suffix argument, `-E` vs `-r`) rather than trust "it worked here, ship it" -- brevity buys nothing and a broken merge costs a full review-and-fix round trip.

When authoring a portability fix specifically, put a comment in the diff stating WHICH TWO BEHAVIORS diverged and WHY -- this lets a re-reviewer verify the fix's reasoning, not just its shape, and saves every future reader from rediscovering the same platform gotcha from scratch.

Recurrence (CDX-010): `stripfm() { sed '1,/^---$/d; 1,/^---$/d' ... }` passed every local check (BSD sed, this repo's usual dev environment) but produced empty output on GNU sed (CI), cascading 41 downstream assertions to FAIL post-merge. Replaced with awk-line-number + tail, with a comment explaining the exact GNU/BSD divergence.

Related: [[pin-external-tool-versions-in-ci]]
