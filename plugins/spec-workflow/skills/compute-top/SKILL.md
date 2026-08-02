---
name: compute-top
description: Shows what remote-compute work is queued, running, or finished on a compute machine -- a terminal dashboard (stdlib curses, nothing to install) that reads that machine's job directory, refreshes in place, opens each job's log and exit code, and lets the human prune history. Runs either on the machine itself or over SSH from elsewhere. Use for 'what is running on the GPU box', 'show the job history', 'is my training run still going', 'why did that job fail', or 'clean up old jobs'.
---

# compute-top

A terminal dashboard for work dispatched by [`remote-compute`](../remote-compute/SKILL.md).
It reads a machine's `~/.compute-jobs/` directory -- the place dispatch writes
`job.log`, `pid`, and `exitcode` for every job -- and shows what is running now,
what finished, and the whole history, refreshing in place.

Script: `../../scripts/remote-capabilities/_shared/compute-top.py` (Python
stdlib only, so there is nothing to install on the target machine).

## Which machine does it run on?

It reports on the machine whose job directory it reads, which is the machine
that RECEIVED the work. There are two ways to use it:

**On the compute machine itself** (sitting at the WSL/Linux/macOS box):

```bash
python3 ~/.compute-jobs/_tools/compute-top.py
```

**From another machine over SSH** -- the usual case, watching a GPU box from a
laptop:

```bash
ssh -t <alias> 'python3 ~/.compute-jobs/_tools/compute-top.py'
```

The `-t` is required: it allocates a terminal so the dashboard can draw and so
keystrokes reach it. Without a terminal the script detects the non-TTY and
prints a plain one-shot snapshot instead of drawing -- useful in a pipe, but
not interactive.

The orchestrator machine shows nothing unless it is itself a registered compute
resource that has received jobs. Reporting is per-machine by design, so with
two GPU boxes the human runs it twice, once per alias.

## Getting it onto a machine

`install-capability` ships bundle payloads, not this helper, so copy it once:

```bash
rsync -az -e "ssh -o BatchMode=yes" \
  "../../scripts/remote-capabilities/_shared/compute-top.py" \
  <alias>:.compute-jobs/_tools/
```

If `~/.compute-jobs/` does not exist yet, nothing has been dispatched to that
machine -- the directory is created by the first dispatch, and the script says
so rather than failing obscurely.

## Reading the output

Each row is one job: state, id, age, duration, exit code, log size. Duration is
wall time from start to exit for a finished job, and elapsed-so-far for a
running one. `running` means no
`exitcode` file has appeared yet; `failed` means a non-zero exit code. Payload
directories (`_caps`, `_tools`) are not jobs and are never listed.

```
/home/user/.compute-jobs — 34 job(s): 1 running, 32 done, 1 failed
running   train-run-042                age 12m03s   took 12m03s  exit -      log 4.3K
done      render-duck                  age 2h11m    took 25s     exit 0      log 285B
failed    render-broken-workflow       age 2h14m    took 1s      exit 2      log 345B
```

## Keys (interactive mode)

| Key | Action |
|---|---|
| up/down, `k`/`j` | move the selection |
| `L`, `l`, enter | open the job: log tail, duration, exit code, pid, paths |
| esc, `q` | leave the log view (in the list, quit with ctrl-c) |
| `f` | cycle filter: all -> running -> finished -> failed |
| `d` | delete the selected job from history (asks first) |
| `D` | delete ALL finished jobs (asks first) |
| `r` | refresh now |

Inside a job's log view, up/down and page-up/page-down scroll, `g` jumps to the
top, `G` to the end.

## Flags

- `--once` -- print one snapshot and exit. Also what happens automatically when
  stdout is not a terminal, so it is safe in pipes and scripts.
- `--interval N` -- refresh every N seconds (default 2).
- `--dir PATH` -- watch a different job directory (default `~/.compute-jobs`).

## Rules

- **Never delete a running job.** The script refuses `d` on one; do not work
  around that by removing the directory another way, because dispatch is still
  writing to it.
- Deletion removes a job directory and its log permanently, and there is no
  undo -- relay that when the human asks to clean up, and prefer `f` to filter
  the view over `D` to purge it.
- This is a READ tool for the human. To act on a job (check status, pull
  artifacts, cancel), use `remote-compute`'s `job-status`, `job-logs`, and
  `job-pull` -- those also update the orchestrator's own job state, which
  deleting a directory behind their back does not.
- When the human asks "what is running on <machine>", prefer the `--once` form
  through `remote-compute exec` and relay the table; only suggest the
  interactive form when they want to browse or prune, and tell them it needs
  their own terminal (a non-TTY host will silently fall back to a snapshot).
