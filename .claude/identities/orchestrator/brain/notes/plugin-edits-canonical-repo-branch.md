---
tags: [process, repos, git]
paths: []
strength: 1
source: "session retro 2026-07-10: wrong-clone incident"
graduated: false
created: 2026-07-10
---

Three writable copies of this plugin exist on disk (this dev repo, the marketplace clone, the version cache) and all can push. A session anchored in a CONSUMER repo that needs to edit plugin code must first resolve THIS repo as the canonical workspace and branch before committing — the incident: edits landed in the marketplace clone and went straight to main, requiring a history rewind. Rule: plugin code changes ride feature branches in this repo; marketplace/cache copies are read-only artifacts to sync, never to edit.
