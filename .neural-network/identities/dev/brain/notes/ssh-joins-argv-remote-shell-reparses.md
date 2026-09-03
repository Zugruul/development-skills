---
tags: [ssh, remote, shell-quoting, transport]
paths: ["plugins/spec-workflow/scripts/remote-compute.py"]
strength: 1
source: "task-524"
confidence: direct
graduated: false
created: 2026-08-02
last-touched: 2026-08-02
---

# ssh joins your command — the remote login shell re-parses it

`ssh host cmd arg1 arg2` does NOT pass an argv array. ssh joins everything
after the destination into ONE string and hands it to the remote LOGIN shell,
which parses it again. If that shell is zsh (or any shell whose word-splitting
differs from your assumption), a multi-word payload silently loses arguments.

Observed live: `free -g` reached the remote as `free` (the `-g` was eaten), so
the probe recorded RAM in KB and looked like a unit bug. `df -hPT ~ /mnt/*`
lost its flags the same way.

Fix: ship the payload as a single fully-quoted word —
`ssh ... host "bash -lc $(shlex.quote(payload))"`. Never rely on ssh preserving
argv boundaries.

Applies to any remote-execution transport, not just this repo.
