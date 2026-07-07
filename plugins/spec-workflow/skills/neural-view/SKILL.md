---
name: neural-view
description: Start/stop/status for the live JARVIS-style visualization of the identity brains — notes as neurons, links as synapses, recalls lighting up in real time. Use with 'start', 'stop', or 'status' (default); bare invocation reports status + URL.
allowed-tools: Bash
---

# Neural view — the live window into the identity brains

One long-lived page (`http://127.0.0.1:4748`) that draws every identity's brain as a
neural cluster and lights the neurons up as recalls fire. The server reads the brains
READ-ONLY; keep the tab open and watch retrieval happen.

Run the action the user asked for (`status` if unspecified):

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/neural-view.py" start    # background server (idempotent)
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/neural-view.py" status   # RUNNING <url> notes=N brains=N repos=N | STOPPED
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/neural-view.py" stop
```

Report the script's output verbatim. On **start**/**status**, give the user the URL and
add: *open it and leave it open — recalls light up live as the identities read their
brains.* Options: `--port N` (default 4748), `--dir ROOT` (a brains root always included,
marker or not; default none), `--scan BASE` (scan base for marker-based multi-repo
discovery; default `~/Development`) — every immediate child of the scan base with a
`.claude/.neural-network` marker file is aggregated onto the same page as a labeled
"constellation", alongside `--dir` if given. With none of these set and an empty/absent
scan base, falls back to the git root of cwd (single-repo behavior).

The page needs no build step and makes zero external requests. If `status` says STOPPED,
`start` it. Nothing here mutates a brain — it is purely a viewer.
