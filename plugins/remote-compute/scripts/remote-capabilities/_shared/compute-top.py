#!/usr/bin/env python3
"""compute-top — a terminal dashboard for work dispatched to THIS machine.

Run it ON the compute machine (Linux, WSL, or macOS). It watches
~/.remote-compute/jobs/ — the directory remote-compute dispatches into — and shows
what is running now, what finished, and the full history, refreshing in place.

    python3 compute-top.py                 # live dashboard
    python3 compute-top.py --once          # print once and exit (pipe-friendly)
    python3 compute-top.py --interval 5    # refresh every 5s (default 2)
    python3 compute-top.py --dir ~/jobs    # watch a different directory

Keys (live mode):
    up/down or k/j   move the selection
    L, l or enter    open the selected job (log tail, exit code, duration, paths)
    esc or q         leave the log view (in the list, quit with ctrl-c)
    d                delete the selected job from history (asks first)
    D                delete ALL finished jobs (asks first)
    r                refresh now
    f                cycle filter: all -> running -> finished -> failed

In the log view: up/down and page-up/page-down scroll, g jumps to the top,
G to the end.

A job is a directory ~/.remote-compute/jobs/<id>/ holding job.log, pid, and exitcode.
Running means no exitcode file yet. Nothing here writes to a job while it runs;
deletion only ever removes a job directory you selected, and never one that is
still running.

stdlib only (curses) — nothing to install on the remote machine.
"""
import argparse
import curses
import os
import shutil
import sys
import time

FILTERS = ("all", "running", "finished", "failed")


def human_age(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm%02ds" % (seconds // 60, seconds % 60)
    if seconds < 86400:
        return "%dh%02dm" % (seconds // 3600, (seconds % 3600) // 60)
    return "%dd%02dh" % (seconds // 86400, (seconds % 86400) // 3600)


def human_size(n):
    for unit in ("B", "K", "M", "G"):
        if n < 1024 or unit == "G":
            return "%d%s" % (n, unit) if unit == "B" else "%.1f%s" % (n, unit)
        n /= 1024.0
    return "%dB" % n


def read_jobs(root):
    """One dict per job directory, newest first. Never raises on a job that is
    being written to right now — a half-created directory just reads as
    running with no log yet."""
    jobs = []
    try:
        names = os.listdir(root)
    except OSError:
        return jobs
    for name in names:
        d = os.path.join(root, name)
        if not os.path.isdir(d) or name.startswith("_"):
            continue  # payload/scratch dirs are not jobs
        job = {"id": name, "dir": d, "exitcode": None, "state": "running",
               "log_size": 0, "started": None, "finished": None, "pid": None}
        try:
            job["started"] = os.path.getmtime(d)
        except OSError:
            pass
        ec_path = os.path.join(d, "exitcode")
        try:
            with open(ec_path) as f:
                raw = f.read().strip()
            if raw:
                job["exitcode"] = int(raw.splitlines()[-1])
                job["state"] = "done" if job["exitcode"] == 0 else "failed"
                job["finished"] = os.path.getmtime(ec_path)
        except (OSError, ValueError):
            pass
        log_path = os.path.join(d, "job.log")
        try:
            job["log_size"] = os.path.getsize(log_path)
            job["started"] = min(job["started"] or 1e18, os.path.getctime(log_path))
        except OSError:
            pass
        try:
            with open(os.path.join(d, "pid")) as f:
                job["pid"] = f.read().strip().splitlines()[0]
        except (OSError, IndexError):
            pass
        jobs.append(job)
    jobs.sort(key=lambda j: j.get("started") or 0, reverse=True)
    return jobs


def tail(path, lines=200, max_bytes=200000):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                f.readline()  # drop the partial first line
            data = f.read()
    except OSError:
        return ["(no log yet)"]
    text = data.decode("utf-8", "replace").splitlines()
    return text[-lines:] or ["(log is empty)"]


def duration(job, now=None):
    """How long the job ran: wall time to its exit for a finished job, elapsed
    so far for a running one. None when we cannot tell (no start recorded)."""
    start = job.get("started")
    if not start:
        return None
    end = job.get("finished") or (now if now is not None else time.time())
    return max(0.0, end - start)


def matches(job, flt):
    if flt == "all":
        return True
    if flt == "running":
        return job["state"] == "running"
    if flt == "finished":
        return job["state"] in ("done", "failed")
    return job["state"] == "failed"


def summarize(jobs):
    run = sum(1 for j in jobs if j["state"] == "running")
    ok = sum(1 for j in jobs if j["state"] == "done")
    bad = sum(1 for j in jobs if j["state"] == "failed")
    return run, ok, bad


def render_once(root, stream=sys.stdout):
    jobs = read_jobs(root)
    run, ok, bad = summarize(jobs)
    stream.write("%s — %d job(s): %d running, %d done, %d failed\n"
                 % (root, len(jobs), run, ok, bad))
    now = time.time()
    for j in jobs:
        age = human_age(now - (j["started"] or now))
        dur = duration(j, now)
        dur_s = "-" if dur is None else human_age(dur)
        code = "-" if j["exitcode"] is None else str(j["exitcode"])
        stream.write("%-9s %-28s age %-8s took %-8s exit %-4s log %s\n"
                     % (j["state"], j["id"][:28], age, dur_s, code,
                        human_size(j["log_size"])))
    return 0


class Ui:
    def __init__(self, root, interval):
        self.root = root
        self.interval = interval
        self.sel = 0
        self.filter = "all"
        self.jobs = []
        self.detail = None      # job id when the log view is open
        self.scroll = 0
        self.message = ""

    # --- drawing ----------------------------------------------------------
    def draw_list(self, scr):
        h, w = scr.getmaxyx()
        jobs = [j for j in self.jobs if matches(j, self.filter)]
        self.sel = max(0, min(self.sel, len(jobs) - 1)) if jobs else 0
        run, ok, bad = summarize(self.jobs)
        head = " compute-top  %s " % self.root
        stat = " %d running · %d done · %d failed · filter:%s " % (run, ok, bad, self.filter)
        scr.addnstr(0, 0, head.ljust(w - len(stat)) + stat, w - 1, curses.A_REVERSE)

        cols = " %-9s %-28s %-9s %-9s %-6s %-8s" % (
            "STATE", "JOB", "AGE", "DURATION", "EXIT", "LOG")
        scr.addnstr(1, 0, cols.ljust(w - 1), w - 1, curses.A_BOLD)

        now = time.time()
        top = max(0, self.sel - (h - 5))
        row = 2
        for i, j in enumerate(jobs[top:], start=top):
            if row >= h - 2:
                break
            age = human_age(now - (j["started"] or now))
            dur = duration(j, now)
            dur_s = "-" if dur is None else human_age(dur)
            code = "-" if j["exitcode"] is None else str(j["exitcode"])
            line = " %-9s %-28s %-9s %-9s %-6s %-8s" % (
                j["state"], j["id"][:28], age, dur_s, code, human_size(j["log_size"]))
            attr = curses.A_REVERSE if i == self.sel else curses.A_NORMAL
            if j["state"] == "failed":
                attr |= curses.color_pair(1)
            elif j["state"] == "running":
                attr |= curses.color_pair(2)
            scr.addnstr(row, 0, line.ljust(w - 1), w - 1, attr)
            row += 1
        if not jobs:
            scr.addnstr(3, 2, "no jobs match filter '%s'" % self.filter, w - 3)

        foot = " up/down move · L/enter logs · d delete · D purge · f filter · r refresh · ctrl-c quit "
        if self.message:
            foot = " " + self.message + " "
        scr.addnstr(h - 1, 0, foot.ljust(w - 1), w - 1, curses.A_REVERSE)

    def draw_detail(self, scr):
        h, w = scr.getmaxyx()
        job = next((j for j in self.jobs if j["id"] == self.detail), None)
        if job is None:
            self.detail = None
            return
        code = "-" if job["exitcode"] is None else str(job["exitcode"])
        dur = duration(job)
        head = " %s · %s · took %s · exit %s · pid %s " % (
            job["id"], job["state"], "-" if dur is None else human_age(dur),
            code, job["pid"] or "-")
        scr.addnstr(0, 0, head.ljust(w - 1), w - 1, curses.A_REVERSE)
        scr.addnstr(1, 0, (" " + job["dir"]).ljust(w - 1), w - 1, curses.A_DIM)

        lines = tail(os.path.join(job["dir"], "job.log"), lines=2000)
        view = h - 4
        self.scroll = max(0, min(self.scroll, max(0, len(lines) - view)))
        for i, line in enumerate(lines[self.scroll:self.scroll + view]):
            scr.addnstr(2 + i, 0, line[:w - 1], w - 1)
        foot = " up/down + pgup/pgdn scroll · g top · G end · esc/q back · r refresh "
        scr.addnstr(h - 1, 0, foot.ljust(w - 1), w - 1, curses.A_REVERSE)

    # --- actions ----------------------------------------------------------
    def confirm(self, scr, prompt):
        h, w = scr.getmaxyx()
        scr.addnstr(h - 1, 0, (" " + prompt + " [y/N] ").ljust(w - 1), w - 1,
                    curses.A_REVERSE | curses.A_BOLD)
        scr.refresh()
        scr.nodelay(False)
        ch = scr.getch()
        scr.nodelay(True)
        return ch in (ord("y"), ord("Y"))

    def delete_selected(self, scr):
        jobs = [j for j in self.jobs if matches(j, self.filter)]
        if not jobs:
            return
        job = jobs[self.sel]
        if job["state"] == "running":
            self.message = "refusing to delete %s: it is still running" % job["id"]
            return
        if self.confirm(scr, "delete %s and its log?" % job["id"]):
            shutil.rmtree(job["dir"], ignore_errors=True)
            self.message = "deleted %s" % job["id"]

    def purge_finished(self, scr):
        done = [j for j in self.jobs if j["state"] in ("done", "failed")]
        if not done:
            self.message = "nothing finished to purge"
            return
        if self.confirm(scr, "delete ALL %d finished job(s)?" % len(done)):
            for j in done:
                shutil.rmtree(j["dir"], ignore_errors=True)
            self.message = "purged %d job(s)" % len(done)

    # --- loop -------------------------------------------------------------
    def run(self, scr):
        curses.curs_set(0)
        scr.nodelay(True)
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_RED, -1)
        curses.init_pair(2, curses.COLOR_GREEN, -1)
        last = 0.0
        while True:
            if time.time() - last >= self.interval:
                self.jobs = read_jobs(self.root)
                last = time.time()
            scr.erase()
            try:
                if self.detail:
                    self.draw_detail(scr)
                else:
                    self.draw_list(scr)
            except curses.error:
                pass  # terminal too small this frame; next redraw will fit
            scr.refresh()

            ch = scr.getch()
            if ch == -1:
                time.sleep(0.05)
                continue
            self.message = ""
            if self.detail:
                if ch in (ord("q"), 27, ord("h")):
                    self.detail, self.scroll = None, 0
                elif ch in (curses.KEY_DOWN, ord("j")):
                    self.scroll += 1
                elif ch in (curses.KEY_UP, ord("k")):
                    self.scroll = max(0, self.scroll - 1)
                elif ch == curses.KEY_NPAGE:
                    self.scroll += 20
                elif ch == curses.KEY_PPAGE:
                    self.scroll = max(0, self.scroll - 20)
                elif ch == ord("g"):
                    self.scroll = 0
                elif ch == ord("G"):
                    self.scroll = 10 ** 6
                elif ch == ord("r"):
                    last = 0.0
                continue
            if ch in (curses.KEY_DOWN, ord("j")):
                self.sel += 1
            elif ch in (curses.KEY_UP, ord("k")):
                self.sel = max(0, self.sel - 1)
            elif ch in (curses.KEY_ENTER, 10, 13, ord("l"), ord("L")):
                jobs = [j for j in self.jobs if matches(j, self.filter)]
                if jobs:
                    self.detail, self.scroll = jobs[self.sel]["id"], 10 ** 6
            elif ch == ord("d"):
                self.delete_selected(scr)
                last = 0.0
            elif ch == ord("D"):
                self.purge_finished(scr)
                last = 0.0
            elif ch == ord("f"):
                self.filter = FILTERS[(FILTERS.index(self.filter) + 1) % len(FILTERS)]
                self.sel = 0
            elif ch == ord("r"):
                last = 0.0


def main():
    ap = argparse.ArgumentParser(description="Watch work dispatched to this machine.")
    ap.add_argument("--dir", default="~/.remote-compute/jobs",
                    help="job directory to watch (default ~/.remote-compute/jobs)")
    ap.add_argument("--interval", type=float, default=2.0, help="refresh seconds")
    ap.add_argument("--once", action="store_true", help="print once and exit")
    args = ap.parse_args()
    root = os.path.expanduser(args.dir)
    if not os.path.isdir(root):
        print("no job directory at %s — nothing has been dispatched here yet "
              "(it is created on the first dispatch)" % root)
        return 1
    if args.once or not sys.stdout.isatty():
        return render_once(root)
    try:
        curses.wrapper(Ui(root, args.interval).run)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
