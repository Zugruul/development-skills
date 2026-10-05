---
tags: [tooling, scripts, dogfooding]
paths: ["**"]
strength: 1
source: "session-wide -- cached brain.py (0.25.0) missing the brain-events emitter that's already merged to repo main, silently dropped events for every mint/recall this session"
graduated: false
created: 2026-07-19
---

When THIS repo is the plugin source (dogfooding spec-workflow on itself), always invoke scripts from the repo's own `plugins/spec-workflow/scripts/` tree, never from `~/.claude/plugins/cache/.../<version>/scripts/` -- the installed marketplace cache can be a STALE, older release. Concretely hit this session: the cached brain.py (0.25.0) predates the brain-events.jsonl emitter (MEM-020/021, already merged to this repo's main) -- every mint/recall this session that used the cached path silently produced zero events (no error, no warning; the feed contract says emit failures never block, so nothing looked wrong). board.sh/telemetry.py/identity.sh happened to be byte-identical between cache and repo this time, so those calls were unaffected, but that's luck, not a guarantee -- verify with `diff <(md5 cache-script) <(md5 repo-script)` if in doubt, or just default to the repo path whenever cwd is inside the plugin's own source repo.

Related: [[trust-completion-signal-not-early-log-read]]
