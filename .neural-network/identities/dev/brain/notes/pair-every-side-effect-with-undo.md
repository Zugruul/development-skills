---
tags: [rollback, scripts, git]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#81 retro"
graduated: false
created: 2026-07-08
---

"Reversible?" is a PER-RULE question, not a per-script one: a rule list that mixes git-tracked text edits with direct filesystem ops (mv/rmdir/symlink) will eventually add one `git checkout -- .` can't undo. Enumerate every side effect a rule's apply() has outside git's view and pair each with its own explicit, tested undo — written in the SAME commit that introduces the effect.

Related: [[old-path-repo-wide-sweep]] [[behavioral-guard-is-spec-worthy]]
