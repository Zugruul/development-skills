#!/usr/bin/env python3
"""herdr_ctl.py -- the few Herdr sequences that are easy to get wrong by hand.

Thin over the `herdr` CLI: every verb shells out to it and reads its JSON.
The skills in this plugin call the CLI directly for one-shot commands and use
this script only where a wait, a retry or a safety check is needed:

  check                      am I inside Herdr, and which pane am I
  name NAME                  is NAME a valid, unused agent name
  label TEXT...              the hyphen-separated, no-space form of a workspace label
  worktree-plan ...          read-only checks + the exact `worktree create` line
  start ...                  `agent start`, retried while the pane is still busy
  prompt TARGET ...          one guarded `agent prompt`; never resubmits
  roster                     every live agent, where it runs and its state
  peek TARGET                state plus what is on the agent's screen
  listen TARGET...           wait until an agent blocks, finishes or disappears

Stdlib only, Python 3.9+. Exit codes: 0 ok, 1 herdr/git error, 2 usage or not
inside Herdr, 3 agent started but blocked, 4 prompt refused, 5 prompt sent but
not confirmed (never resend blindly), 6 a pre-creation check failed.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
SETTLED = ("idle", "done", "blocked")
INTERVAL = float(os.environ.get("HERDR_CTL_INTERVAL", "2"))


def herdr(*args):
    """Run one herdr command. Returns (exit code, parsed JSON or None, raw text)."""
    try:
        p = subprocess.run(["herdr", *args], capture_output=True, text=True)
    except OSError as e:
        return 127, None, str(e)
    raw = p.stdout if p.returncode == 0 else (p.stderr or p.stdout)
    try:
        data = json.loads(raw)
    except ValueError:
        data = None
    return p.returncode, data if isinstance(data, dict) else None, raw.strip()


def err_code(data):
    e = (data or {}).get("error")
    return e.get("code", "") if isinstance(e, dict) else ""


def err_text(data, raw):
    e = (data or {}).get("error")
    if isinstance(e, dict):
        return "%s: %s" % (e.get("code", "error"), e.get("message", ""))
    return raw or "no output"


def result(data):
    r = (data or {}).get("result")
    return r if isinstance(r, dict) else {}


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def require_herdr():
    if os.environ.get("HERDR_ENV") != "1":
        die("HERDR UNAVAILABLE: this agent is not running inside a Herdr pane (HERDR_ENV is not 1). "
            "Do not control Herdr from outside it.", 2)
    if not shutil.which("herdr"):
        die("HERDR UNAVAILABLE: the herdr binary is not on PATH.", 2)


def agents():
    rc, data, raw = herdr("agent", "list")
    if rc != 0:
        die("herdr agent list failed: " + err_text(data, raw))
    found = result(data).get("agents")
    return [a for a in found if isinstance(a, dict)] if isinstance(found, list) else []


def agent_get(target):
    """Returns the agent dict, or None when the target hosts no agent any more."""
    rc, data, raw = herdr("agent", "get", target)
    if rc != 0:
        if err_code(data) == "agent_not_found":
            return None
        die("herdr agent get %s failed: %s" % (target, err_text(data, raw)))
    a = result(data).get("agent")
    return a if isinstance(a, dict) else None


def screen(target, source, lines):
    rc, data, raw = herdr("agent", "read", target, "--source", source, "--lines", str(lines))
    if rc != 0:
        return "(could not read %s: %s)" % (source, err_text(data, raw))
    r = result(data)
    for key in ("text", "content", "output"):
        if isinstance(r.get(key), str):
            return r[key].rstrip()
    read = r.get("read")
    if isinstance(read, dict) and isinstance(read.get("text"), str):
        return read["text"].rstrip()
    return raw


def label(a):
    return a.get("name") or a.get("pane_id") or "?"


# --- verbs -----------------------------------------------------------------

def cmd_check(_):
    require_herdr()
    rc, _data, raw = herdr("--version")
    me = agent_get(os.environ.get("HERDR_PANE_ID", "")) if os.environ.get("HERDR_PANE_ID") else None
    print("HERDR OK version=%s workspace=%s tab=%s pane=%s name=%s" % (
        raw.replace("herdr ", "") if rc == 0 else "unknown",
        os.environ.get("HERDR_WORKSPACE_ID", "?"), os.environ.get("HERDR_TAB_ID", "?"),
        os.environ.get("HERDR_PANE_ID", "?"), (me or {}).get("name") or "-"))


def name_problem(name, live=None):
    if not NAME_RE.match(name):
        return ("NAME INVALID: %r must match [a-z][a-z0-9_-]{0,31} "
                "(lowercase letter first, then lowercase letters, digits, _ or -, 32 characters at most)." % name)
    taken = {a.get("name") for a in (agents() if live is None else live)}
    if name in taken:
        n = 2
        while "%s-%d" % (name[:29], n) in taken:
            n += 1
        return "NAME TAKEN: a live agent is already named %r. Free alternative: %s-%d" % (name, name[:29], n)
    return ""


def cmd_name(a):
    require_herdr()
    problem = name_problem(a.name)
    if problem:
        die(problem, 6)
    print("NAME OK %s" % a.name)


LABEL_MAX = 80


def label_from(text):
    """A workspace label is one hyphen-separated word group: letters, digits and hyphens, no spaces."""
    return re.sub(r"[^A-Za-z0-9]+", "-", text or "").strip("-")


def label_problem(text):
    if not re.match(r"^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$", text or ""):
        fixed = label_from(text)
        return ("label %r is not hyphen-separated letters and digits without spaces%s"
                % (text, " -- use %s" % fixed if fixed else ""))
    if len(text) > LABEL_MAX:
        return "label %r is longer than %d characters" % (text, LABEL_MAX)
    return ""


def cmd_label(a):
    """Offline. Prints the hyphen-separated, no-space form of a label."""
    out = label_from(" ".join(a.text))
    problem = label_problem(out)
    if problem:
        die(problem, 6)
    print("LABEL %s" % out)


def git(cwd, *args):
    p = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True)
    return p.returncode, p.stdout.strip()


def worktree_dir():
    path = os.environ.get("HERDR_CONFIG_PATH") or os.path.expanduser("~/.config/herdr/config.toml")
    section, found = "", ""
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("["):
                    section = line.strip("[] ")
                m = re.match(r'directory\s*=\s*"([^"]*)"', line)
                if section == "worktrees" and m:
                    found = m.group(1)
    except OSError:
        pass
    return os.path.expanduser(found or "~/.herdr/worktrees")


def cmd_worktree_plan(a):
    """Read-only. Prints the checks a human needs to approve a worktree, then the command."""
    require_herdr()
    cwd = os.path.abspath(a.cwd or os.getcwd())
    rc, data, raw = herdr("worktree", "list", "--cwd", cwd)
    if rc != 0:
        die("herdr worktree list failed: " + err_text(data, raw))
    src = result(data).get("source") or {}
    root = src.get("repo_root") or src.get("source_checkout_path")
    if not root:
        die("could not find the repository's primary checkout from %s" % cwd)
    trees = [w for w in result(data).get("worktrees") or [] if isinstance(w, dict)]
    problems, notes = [], []
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$", a.branch) or ".." in a.branch:
        problems.append("branch name %r is not a plain git branch name" % a.branch)
    for w in trees:
        if w.get("branch") == a.branch:
            problems.append("branch %s is already checked out at %s (workspace %s) -- open that one instead: "
                            "herdr worktree open --cwd %s --branch %s --no-focus"
                            % (a.branch, w.get("path"), w.get("open_workspace_id") or "none", root, a.branch))
    wlabel = a.label if a.label is not None else label_from(a.branch)
    problem = label_problem(wlabel)
    if problem:
        problems.append(problem)
    if a.path:
        path = os.path.abspath(os.path.join(root, os.path.expanduser(a.path)))
        notes.append("path: given explicitly")
    else:
        path = os.path.join(worktree_dir(), src.get("repo_name") or os.path.basename(root),
                            a.branch.replace("/", "-"))
        notes.append("path: Herdr's configured worktree directory (no --path given; "
                     "use the repository's own location rule instead when it has one)")
    if os.path.lexists(path):
        problems.append("destination %s already exists" % path)
    exists = git(root, "show-ref", "--verify", "--quiet", "refs/heads/" + a.branch)[0] == 0
    base = a.base
    if exists:
        notes.append("branch %s already exists; Herdr will check it out, the base is not used" % a.branch)
    elif not base:
        problems.append("no --base given and branch %s does not exist yet -- ask which ref to branch from" % a.branch)
    elif git(root, "rev-parse", "--verify", "--quiet", base + "^{commit}")[0] != 0:
        problems.append("base %s does not resolve to a commit in %s (fetch it first?)" % (base, root))
    else:
        notes.append("base %s = %s" % (base, git(root, "rev-parse", "--short", base + "^{commit}")[1]))
    dirty = git(root, "status", "--porcelain")[1]
    notes.append("primary checkout %s is %s (left untouched either way)" % (root, "dirty" if dirty else "clean"))
    print("WORKTREE PLAN")
    print("  repository: %s" % root)
    print("  branch:     %s" % a.branch)
    print("  base:       %s" % (base or "(existing branch)"))
    print("  path:       %s" % path)
    print("  label:      %s%s" % (wlabel, "" if a.label is not None else " (from the branch; no --label given)"))
    for n in notes:
        print("  note: %s" % n)
    if problems:
        for p in problems:
            print("  PROBLEM: %s" % p)
        print("DO NOT CREATE: fix the problems above first.")
        sys.exit(6)
    line = ["herdr", "worktree", "create", "--cwd", root, "--branch", a.branch]
    if base and not exists:
        line += ["--base", base]
    line += ["--path", path]
    line += ["--label", wlabel]
    line.append("--no-focus")
    print("COMMAND (run only after the user approved this worktree):")
    print("  " + " ".join(shquote(x) for x in line))


def shquote(s):
    return s if re.match(r"^[A-Za-z0-9_@%+=:,./~-]+$", s) else "'" + s.replace("'", "'\\''") + "'"


def cmd_start(a):
    """agent start, retried while the pane's shell is still starting, then wait for idle."""
    require_herdr()
    problem = name_problem(a.name)
    if problem:
        die(problem, 6)
    deadline = time.time() + a.timeout
    cmd = ["agent", "start", a.name, "--kind", a.kind, "--pane", a.pane]
    if a.agent_args:
        cmd += ["--"] + a.agent_args
    tries = 0
    while True:
        tries += 1
        rc, data, raw = herdr(*cmd)
        code = err_code(data)
        if rc == 0:
            break
        if code == "agent_not_ready":
            print("AGENT BLOCKED AT STARTUP name=%s pane=%s" % (a.name, a.pane))
            print("The agent is running but waiting at a startup dialog. Screen:")
            print(screen(a.name, "visible", 40))
            print("Show this to the user and ask how to answer; do not answer it yourself.")
            sys.exit(3)
        if code == "agent_pane_busy" and time.time() < deadline:
            # A pane just created by `worktree create` is still running its shell
            # startup files. Herdr decides when the prompt is there; just ask again.
            time.sleep(INTERVAL)
            continue
        die("herdr agent start failed after %d attempt(s): %s" % (tries, err_text(data, raw)))
    while True:
        cur = agent_get(a.name)
        status = (cur or {}).get("agent_status")
        if status in ("idle", "done"):
            print("AGENT READY name=%s pane=%s kind=%s status=%s attempts=%d" % (a.name, a.pane, a.kind, status, tries))
            return
        if status == "blocked":
            print("AGENT BLOCKED AT STARTUP name=%s pane=%s" % (a.name, a.pane))
            print(screen(a.name, "visible", 40))
            print("Show this to the user and ask how to answer; do not answer it yourself.")
            sys.exit(3)
        if time.time() >= deadline:
            die("agent %s started but is not idle yet (status=%s). Do not prompt it yet: "
                "check with `peek %s` first." % (a.name, status, a.name))
        time.sleep(INTERVAL)


def cmd_prompt(a):
    """One guarded submission. Whatever happens afterwards, the text is sent at most once."""
    require_herdr()
    if a.file:
        with open(a.file, encoding="utf-8") as f:
            text = f.read().strip()
    else:
        text = (a.text or "").strip()
    if not text:
        die("nothing to send: pass --text or --file", 2)
    before = agent_get(a.target)
    if before is None:
        die("PROMPT REFUSED: no live agent %r (it may have exited; check `roster`)." % a.target, 4)
    status = before.get("agent_status")
    if status == "blocked":
        print("PROMPT REFUSED: %s is blocked at an approval or question. Screen:" % label(before))
        print(screen(a.target, "visible", 40))
        print("Ask the user how to answer it, then answer with `herdr agent send-keys` -- not with a prompt.")
        sys.exit(4)
    if status == "working" and not a.while_working:
        die("PROMPT REFUSED: %s is working. Wait for it (`listen %s`) or pass --while-working to steer it mid-turn."
            % (label(before), a.target), 4)
    rc, data, raw = herdr("agent", "prompt", a.target, text)
    if rc != 0:
        code = err_code(data)
        if code == "agent_blocked":
            die("PROMPT REFUSED: the agent became blocked; nothing was sent. Inspect it with `peek %s`." % a.target, 4)
        print("PROMPT UNCONFIRMED: herdr answered %s" % err_text(data, raw))
        print("The text may or may not have reached the agent. Run `peek %s` and read the screen "
              "before deciding anything. Do NOT send it again blindly." % a.target)
        sys.exit(5)
    # Submission was written. Look for evidence that a turn actually started.
    seq = before.get("state_change_seq")
    deadline = time.time() + a.confirm
    while time.time() < deadline:
        cur = agent_get(a.target) or {}
        if cur.get("agent_status") in ("working", "blocked") or cur.get("state_change_seq") != seq:
            print("PROMPT DELIVERED target=%s status=%s" % (label(cur) if cur else a.target, cur.get("agent_status")))
            return
        time.sleep(min(INTERVAL, 1))
    print("PROMPT UNCONFIRMED: the text was submitted but %s showed no activity within %ds." % (a.target, a.confirm))
    print("That does not prove it was not delivered. Run `peek %s` and read the screen. "
          "Do NOT send it again blindly." % a.target)
    sys.exit(5)


def workspaces():
    rc, data, _ = herdr("workspace", "list")
    out = {}
    for w in (result(data).get("workspaces") or []) if rc == 0 else []:
        if isinstance(w, dict) and isinstance(w.get("workspace_id"), str):
            out[w["workspace_id"]] = w
    return out


def cmd_roster(a):
    require_herdr()
    ws = workspaces()
    me = os.environ.get("HERDR_PANE_ID", "")
    rows = []
    for ag in agents():
        w = ws.get(ag.get("workspace_id"), {})
        if a.workspace and ag.get("workspace_id") != a.workspace:
            continue
        wt = w.get("worktree") if isinstance(w.get("worktree"), dict) else {}
        if a.repo and os.path.realpath(wt.get("repo_root") or "") != os.path.realpath(a.repo):
            continue
        rows.append({
            "name": ag.get("name") or "", "pane": ag.get("pane_id") or "", "tab": ag.get("tab_id") or "",
            "kind": ag.get("agent") or "", "status": ag.get("agent_status") or "unknown",
            "workspace": ag.get("workspace_id") or "", "label": w.get("label") or "",
            "cwd": ag.get("cwd") or "", "self": ag.get("pane_id") == me,
        })
    if a.json:
        print(json.dumps(rows, indent=1))
        return
    if not rows:
        print("no live agents" + (" match the filter" if a.workspace or a.repo else ""))
        return
    order = {"blocked": 0, "done": 1, "idle": 2, "working": 3}
    rows.sort(key=lambda r: (order.get(r["status"], 4), r["workspace"], r["pane"]))
    print("%-8s %-20s %-9s %-9s %-24s %s" % ("STATUS", "NAME", "PANE", "KIND", "WORKSPACE", "CWD"))
    for r in rows:
        print("%-8s %-20s %-9s %-9s %-24s %s" % (
            r["status"], (r["name"] or "(unnamed)") + (" *" if r["self"] else ""), r["pane"], r["kind"],
            ("%s %s" % (r["workspace"], r["label"]))[:24], r["cwd"]))
    blocked = [r for r in rows if r["status"] == "blocked"]
    if blocked:
        print("BLOCKED, waiting on a human: " + ", ".join(r["name"] or r["pane"] for r in blocked))
    print("(* = this agent. Target unnamed agents by pane id.)")


def cmd_peek(a):
    require_herdr()
    cur = agent_get(a.target)
    if cur is None:
        die("no live agent %r (it exited, or the name was never set; check `roster`)." % a.target)
    print("AGENT name=%s pane=%s tab=%s kind=%s status=%s cwd=%s" % (
        cur.get("name") or "-", cur.get("pane_id"), cur.get("tab_id"), cur.get("agent"),
        cur.get("agent_status"), cur.get("cwd")))
    # Full-screen agents draw on the alternate screen: only `visible` shows it.
    print("--- screen (visible) ---")
    print(screen(a.target, "visible", a.lines))
    if a.history:
        print("--- history (recent-unwrapped; empty or stale for full-screen agents) ---")
        print(screen(a.target, "recent-unwrapped", a.history))


def cmd_listen(a):
    """Nothing notifies an orchestrator, so poll. Returns on the first thing worth a look."""
    require_herdr()
    deadline = time.time() + a.timeout
    seen = {}
    while True:
        events = []
        for t in a.targets:
            cur = agent_get(t)
            if cur is None:
                events.append((t, "gone", {}))
                continue
            status = cur.get("agent_status") or "unknown"
            seen[t] = status
            if status in SETTLED and not (a.only_blocked and status != "blocked"):
                events.append((t, status, cur))
        if events:
            for t, status, cur in events:
                print("EVENT target=%s name=%s pane=%s tab=%s status=%s" % (
                    t, cur.get("name") or "-", cur.get("pane_id") or "-", cur.get("tab_id") or "-", status))
                if status == "blocked":
                    print("--- %s is waiting on a human. Its screen: ---" % t)
                    print(screen(t, "visible", a.lines))
                    print("--- end of %s ---" % t)
                elif status == "gone":
                    print("    %s no longer hosts an agent (it exited or its pane closed)." % t)
            still = [t for t in a.targets if t not in {e[0] for e in events}]
            if still:
                print("STILL WORKING: " + ", ".join("%s=%s" % (t, seen.get(t, "?")) for t in still))
            return
        if time.time() >= deadline:
            print("LISTEN TIMEOUT after %ds: " % a.timeout + ", ".join("%s=%s" % (t, seen.get(t, "?")) for t in a.targets))
            print("Nothing blocked or finished yet. This says nothing about whether an earlier prompt arrived; "
                  "keep listening or `peek` -- never resend a prompt because of a timeout.")
            return
        time.sleep(INTERVAL)


def main():
    ap = argparse.ArgumentParser(prog="herdr_ctl.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="verb", required=True)
    sub.add_parser("check").set_defaults(fn=cmd_check)
    p = sub.add_parser("name"); p.add_argument("name"); p.set_defaults(fn=cmd_name)
    p = sub.add_parser("label"); p.add_argument("text", nargs="+"); p.set_defaults(fn=cmd_label)
    p = sub.add_parser("worktree-plan")
    p.add_argument("--branch", required=True); p.add_argument("--base"); p.add_argument("--path")
    p.add_argument("--cwd"); p.add_argument("--label"); p.set_defaults(fn=cmd_worktree_plan)
    p = sub.add_parser("start")
    p.add_argument("--name", required=True); p.add_argument("--kind", required=True)
    p.add_argument("--pane", required=True); p.add_argument("--timeout", type=int, default=90)
    p.add_argument("agent_args", nargs="*"); p.set_defaults(fn=cmd_start)
    p = sub.add_parser("prompt")
    p.add_argument("target"); p.add_argument("--text"); p.add_argument("--file")
    p.add_argument("--while-working", action="store_true"); p.add_argument("--confirm", type=int, default=10)
    p.set_defaults(fn=cmd_prompt)
    p = sub.add_parser("roster")
    p.add_argument("--workspace"); p.add_argument("--repo"); p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_roster)
    p = sub.add_parser("peek")
    p.add_argument("target"); p.add_argument("--lines", type=int, default=60)
    p.add_argument("--history", type=int, default=0); p.set_defaults(fn=cmd_peek)
    p = sub.add_parser("listen")
    p.add_argument("targets", nargs="+"); p.add_argument("--timeout", type=int, default=540)
    p.add_argument("--lines", type=int, default=40); p.add_argument("--only-blocked", action="store_true")
    p.set_defaults(fn=cmd_listen)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
