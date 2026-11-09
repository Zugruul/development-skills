#!/usr/bin/env python3
"""audit.py — board.sh audit's reconciliation logic (issue #76).

Reconciles reality (local git + gh) against the board:
  (a) open PRs whose body lacks a board-issue reference (any bare #N — a
      lighter-weight bar than guard-pr-create.sh's Closes/Fixes/<slug>#N,
      since this is a backstop catching drift from BEFORE the guard was
      adopted or in a repo not running it, not re-enforcing the guard's
      stricter closing-keyword contract).
  (b) local branches matching project.branchPattern with no In-progress
      board item for the branch's embedded <id>.
  (c) In-progress board items with no matching local branch.
  (d) work.type: local ONLY — merged main-branch commits (the last
      COMMIT_SCAN_WINDOW of them; review round 1 — the window is printed
      unconditionally, discrepancy or not, so a clean report never implies
      the whole history was checked when it wasn't) whose subject lacks a
      #N reference, excluding a documented allowlist of recognized
      orchestrator process-commit classes (retro(, spec(, feedback(,
      config:). Those commits are exempt from (d) but always counted and
      enumerated in the report -- never silently hidden.

Prints one line per discrepancy plus a summary; exits 1 if any discrepancy
was found, 0 otherwise (a clean report).

#564 reconciliation (the board must show the work that is running):
  (e) a live worktree (under <root>/.claude/worktrees/ or on a branchPattern
      branch) or an open PR for a task whose card is still before In progress
      -> In progress (--over-wip "audit: work is running": the work is already
      happening, the board must show it, so the WIP limit never blocks it).
  (f) In review: pr mode, an open PR that is not a draft; both modes, a live
      worktree or open PR whose task has review-round / review-round-start
      telemetry or a green `gate` telemetry event. The move itself still runs
      the gate / red-first preflights (from the worktree, so the right tree is
      checked); a refusal is printed as a NOTE, never forced.
  (g) QA: pr mode, a merged PR linked to the task; local mode, a commit on the
      main branch whose subject ends with "(#N)" (a squash merge) for a card in
      In progress / In review. Only if the two-pass review guard allows it,
      else "NOTE #N: merged but review evidence missing ...".
  (h) a live worktree or open PR with no linked issue -> board.sh ensure-issue;
      the printed issue is recorded in <root>/.claude/audit-links.json (branch ->
      issue) so the next run reuses it. A link is only ever: that record, the
      branch's own <id>, or a Closes/Fixes/Resolves #N in the PR body.
Every move goes through `board.sh move`; a failed move is a NOTE, the audit
continues. Without --fix the same plan is printed as WOULD FIX lines and the
exit is 1; with --fix the exit is 0 unless a fix failed.

Usage: audit.py <config-path> <board-id> <repo-root> <work-type> <prs-json-file>
                [--closed-file F] [--fix --board-sh PATH]
Reads the project-items JSON ({"items":[...]}, from gh_project_items_json)
on stdin.
"""
import datetime
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wip import normalized

OVER_WIP_REASON = "audit: work is running"
CLOSING_RE = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)", re.I)
TRAILING_REFS_RE = re.compile(r"\(((?:#\d+(?:,\s*)?)+)\)\s*$")

BARE_REF_RE = re.compile(r"#\d+")

# Recognized orchestrator process-commit classes (order = report order).
# Exempt from the (d) commit-subject scan, but always counted/enumerated.
PROCESS_PREFIXES = ("retro(", "spec(", "feedback(", "config:")
FOLLOWUP_PREFIXES = ("test(", "chore(", "docs(")

# (d)'s scan is capped, not exhaustive -- a repo with more history than this
# is silently under-scanned unless the cap itself is stated (review round
# 1). The note below is printed unconditionally in the work.type: local
# branch, discrepancy or not, so "AUDIT: clean" never implies "the whole
# history was checked" when it wasn't.
COMMIT_SCAN_WINDOW = 200


def has_ref(text):
    return bool(BARE_REF_RE.search(text or ""))


def branch_regex(pattern):
    r = re.escape(pattern)
    r = r.replace("<id>", r"(?P<id>\d+)").replace("<slug>", r"(?P<slug>[A-Za-z0-9._-]+)")
    return re.compile("^" + r + "$")


def local_branches(root):
    out = subprocess.run(
        ["git", "branch", "--format=%(refname:short)"],
        cwd=root, capture_output=True, text=True,
    ).stdout
    return [b.strip() for b in out.splitlines() if b.strip()]


def live_worktrees(root, pattern_rx, main_branch):
    """[(branch, path)] for linked worktrees that really exist and are task work."""
    out = subprocess.run(["git", "worktree", "list", "--porcelain"],
                         cwd=root, capture_output=True, text=True).stdout
    base = os.path.realpath(os.path.join(root, ".claude", "worktrees")) + os.sep
    found, path, branch, skip = [], None, None, False
    for line in out.splitlines() + [""]:
        if line.startswith("worktree "):
            path, branch, skip = line[9:], None, False
        elif line.startswith("branch refs/heads/"):
            branch = line[len("branch refs/heads/"):]
        elif line.startswith(("bare", "prunable")):
            skip = True
        elif not line.strip() and path:
            real = os.path.realpath(path)
            if (branch and not skip and branch != main_branch and os.path.isdir(real)
                    and real != os.path.realpath(root)
                    and (real.startswith(base) or (pattern_rx and pattern_rx.match(branch)))):
                found.append((branch, real))
            path, branch, skip = None, None, False
    return found


def iso_epoch(ts):
    try:
        return datetime.datetime.strptime(str(ts), "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        return 0


def telemetry_signals(root, work_norm):
    """task id (str) -> {'review': bool, 'gate': bool} from the local telemetry file."""
    sig = {}
    try:
        fh = open(os.path.join(root, ".claude", "telemetry.jsonl"))
    except OSError:
        return sig
    with fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not isinstance(rec, dict):
                continue
            t = sig.setdefault(str(rec.get("task")), {"review": False, "work_ts": 0})
            if rec.get("kind") in ("review-round", "review-round-start"):
                t["review"] = True
            elif rec.get("kind") == "transition" and normalized(str(rec.get("to") or "")) == work_norm:
                t["work_ts"] = max(t["work_ts"], iso_epoch(rec.get("ts")))
    return sig


def load_links(root):
    try:
        with open(os.path.join(root, ".claude", "audit-links.json")) as fh:
            data = json.load(fh)
        return {str(k): int(v) for k, v in data.items()} if isinstance(data, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def save_link(root, branch, number):
    data = load_links(root)
    data[branch] = number
    try:
        tmp = os.path.join(root, ".claude", "audit-links.json.tmp")
        with open(tmp, "w") as fh:
            json.dump(data, fh, sort_keys=True)
        os.replace(tmp, os.path.join(root, ".claude", "audit-links.json"))
    except OSError:
        print("WARN: could not record the link " + branch + " -> #" + str(number), file=sys.stderr)


def mark_comments_seen(root, number):
    """An issue this audit just filed has no human comments to read first."""
    path = os.path.join(root, ".claude", "board-comments-seen.json")
    try:
        try:
            with open(path) as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            data = {}
        data[str(number)] = True
        with open(path + ".tmp", "w") as fh:
            json.dump(data, fh)
        os.replace(path + ".tmp", path)
    except OSError:
        pass


def add_to_snapshot(snap_file, root, number):
    """Put a card this audit just filed into the shared snapshot, from the item-id cache that
    ensure-issue's own visibility poll refreshed (no extra board read)."""
    if not snap_file:
        return
    cache = os.environ.get("BOARD_CACHE_FILE") or os.path.join(root, ".claude", "board-cache.json")
    try:
        with open(cache) as fh:
            entry = (json.load(fh) or {}).get(str(number)) or {}
        with open(snap_file) as fh:
            snap = json.load(fh)
        if not entry.get("itemId"):
            return
        snap.setdefault("items", []).append({"id": entry["itemId"], "status": entry.get("status") or None,
                                             "content": {"number": number, "type": "Issue"}})
        if "totalCount" in snap:
            snap["totalCount"] = len(snap["items"])
        with open(snap_file + ".tmp", "w") as fh:
            json.dump(snap, fh)
        os.replace(snap_file + ".tmp", snap_file)
    except (OSError, ValueError):
        pass


def load_prs(path):
    try:
        with open(path) as fh:
            data = json.load(fh) or []
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def merged_commit_tasks(root, main_branch):
    """task number -> newest commit time of its squash-merge commit ('... (#N)') on the main branch.
    test(/docs(/chore( subjects are follow-ups, not the merge."""
    log = subprocess.run(["git", "log", main_branch, "--format=%ct %s", "-n", str(COMMIT_SCAN_WINDOW)],
                         cwd=root, capture_output=True, text=True).stdout
    found = {}
    for line in log.splitlines():
        ct, _, subject = line.partition(" ")
        if subject.startswith(PROCESS_PREFIXES + FOLLOWUP_PREFIXES) or "register work" in subject:
            continue
        m = TRAILING_REFS_RE.search(subject)
        if m:
            for n in re.findall(r"\d+", m.group(1)):
                found[int(n)] = max(found.get(int(n), 0), int(ct) if ct.isdigit() else 0)
    return found


class Fixer:
    def __init__(self, root, board_sh, apply, snap_file="", snap_token=""):
        self.root, self.board_sh, self.apply, self.snap_file = root, board_sh, apply, snap_file
        self.snap_token = snap_token
        self.changes = 0
        self.failures = 0

    def board(self, args, cwd=None, share_snapshot=False):
        """Run board.sh. Only `move` shares the audit's board snapshot (BOARD_AUDIT_SNAP_FILE), held
        under the WIP mutex the audit took once (see board.sh)."""
        env = dict(os.environ)
        env.pop("BOARD_AUDIT_SNAP_FILE", None)
        env.pop("BOARD_AUDIT_TOKEN", None)
        if share_snapshot and self.snap_file and self.snap_token:
            env["BOARD_AUDIT_SNAP_FILE"] = self.snap_file
            env["BOARD_AUDIT_TOKEN"] = self.snap_token
        r = subprocess.run(["bash", self.board_sh] + args, cwd=cwd or self.root,
                           capture_output=True, text=True, env=env)
        return r.returncode, r.stdout, r.stderr

    def move(self, num, frm, to, why, counted, cwd=None):
        if not self.apply:
            print(f"WOULD FIX #{num}: {frm} -> {to} ({why})")
            self.changes += 1
            return True
        args = ["move", str(num), to]
        if counted:
            args += ["--over-wip", OVER_WIP_REASON, "--over-wip-by", "audit"]
        rc, out, err = self.board(args, cwd, share_snapshot=True)
        if rc != 0:
            first = next((l for l in (err + out).splitlines() if l.strip()), "no output")
            print(f"NOTE #{num}: could not move {frm} -> {to} ({why}): {first}")
            self.failures += 1
            return False
        print(f"FIX #{num}: {frm} -> {to} ({why})")
        for line in out.splitlines():
            if line.strip():
                print("  " + line)
        self.changes += 1
        return True


def main():
    args = sys.argv[1:]
    config_path, board_id, root, work_type, prs_path = args[:5]
    rest = args[5:]
    fix = "--fix" in rest
    closed_path = rest[rest.index("--closed-file") + 1] if "--closed-file" in rest else ""
    board_sh = rest[rest.index("--board-sh") + 1] if "--board-sh" in rest else ""
    snap_file = rest[rest.index("--snap-file") + 1] if "--snap-file" in rest else ""
    snap_token = rest[rest.index("--token") + 1] if "--token" in rest else ""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import config as C
    
    cfg = C.load_config(path=config_path, warn=False) or {}
    project = cfg.get("project") or {}
    pattern = project.get("branchPattern")
    main_branch = project.get("mainBranch") or "main"
    boards = cfg.get("boards") or [{}]
    board = next((b for b in boards if b.get("id") == board_id), boards[0])
    flow = [str(x) for x in (board.get("statusFlow") or [])]
    fidx = {normalized(n): i for i, n in enumerate(flow)}

    items = (json.load(sys.stdin) or {}).get("items", [])
    status_of = {}
    for it in items:
        num = (it.get("content") or {}).get("number")
        if num is not None:
            status_of[num] = it.get("status") or ""

    prs = load_prs(prs_path)
    closed_prs = load_prs(closed_path) if closed_path else []
    pattern_rx = branch_regex(pattern) if pattern else None

    def branch_id(b):
        m = pattern_rx.match(b) if pattern_rx else None
        if m and "id" in m.groupdict():
            try:
                return int(m.group("id"))
            except ValueError:
                return None
        return None

    links = load_links(root)

    def link_of(branch, body=""):
        """The task a branch/PR belongs to, or None. Never guessed."""
        if branch in links:
            return links[branch]
        bid = branch_id(branch)
        if bid is not None and bid in status_of:
            return bid
        for m in CLOSING_RE.finditer(body or ""):
            if int(m.group(1)) in status_of:
                return int(m.group(1))
        return None

    print("== board audit ==")
    problems = []
    fixer = Fixer(root, board_sh, fix, snap_file, snap_token)
    fixing = bool(len(flow) > 3 and board_sh)
    if board_sh and len(flow) <= 3:
        print("NOTE: statusFlow has fewer than 4 statuses; the audit's reconciliation rules are skipped")

    # (e)-(h): reconcile reality with the board
    signals = {}  # task -> dict(worktree=(branch, path), pr=pr, merged=("pr", n, branch) | ("commit",))
    unlinked = []  # (description, branch, title, worktree-path or None)
    if fixing:
        tel = telemetry_signals(root, normalized(flow[1]))
        wts = live_worktrees(root, pattern_rx, main_branch)
        seen_branches = set()
        for pr in prs:
            br = ((pr.get("head") or {}).get("ref")) or ""
            n = link_of(br, pr.get("body") or "")
            wt = next((p for b, p in wts if b == br), None)
            if n is None:
                if br and br not in seen_branches:
                    unlinked.append((f"open PR #{pr.get('number')} (branch {br})", br,
                                     (pr.get("title") or br).replace("\n", " "), wt))
            else:
                signals.setdefault(n, {})["pr"] = (pr, br)
            seen_branches.add(br)
        for br, path in wts:
            if br in seen_branches:
                n = link_of(br)
                if n is not None:
                    signals.setdefault(n, {})["worktree"] = (br, path)
                continue
            seen_branches.add(br)
            n = link_of(br)
            if n is None:
                rel = os.path.relpath(path, root)
                unlinked.append((f"worktree {rel} (branch {br})", br, br, path))
            else:
                signals.setdefault(n, {})["worktree"] = (br, path)
        for pr in closed_prs:
            if not pr.get("merged_at"):
                continue
            br = ((pr.get("head") or {}).get("ref")) or ""
            n = link_of(br, pr.get("body") or "")
            if n is not None:
                signals.setdefault(n, {})["merged"] = (f"merged PR #{pr.get('number')}, branch {br}",
                                                       iso_epoch(pr.get("merged_at")))
        if work_type == "local":
            for n, ct in merged_commit_tasks(root, main_branch).items():
                if n in status_of and fidx.get(normalized(status_of[n]), -1) in (1, 2):
                    signals.setdefault(n, {}).setdefault("merged", ("merged: commit on main references #" + str(n), ct))
        # (h) work with no linked issue
        for desc, br, title, wt in unlinked:
            if not fix:
                print(f"WOULD FIX: {desc} has no issue -> board.sh ensure-issue")
                fixer.changes += 1
                continue
            rc, out, err = fixer.board(["ensure-issue", "--title", title, "--for-branch", br])
            num = out.strip().splitlines()[-1].strip() if out.strip() else ""
            if not num.isdigit():
                first = next((l for l in err.splitlines() if l.strip()), "no output")
                print(f"NOTE: {desc} has no issue and ensure-issue filed none: {first}")
                continue
            n = int(num)
            save_link(root, br, n)
            if re.search(r"created issue #" + num + r"\b", err):
                mark_comments_seen(root, n)
            print(f"FIX: {desc} had no issue -> #{n} (board.sh ensure-issue)")
            fixer.changes += 1
            if n not in status_of:
                status_of[n] = flow[0]  # just filed: the board puts it in the first status
                add_to_snapshot(snap_file, root, n)
            sig = signals.setdefault(n, {})
            if wt:
                sig["worktree"] = (br, wt)
            else:
                sig["pr"] = next(((pr, br) for pr in prs if ((pr.get("head") or {}).get("ref")) == br), None)
                if sig["pr"] is None:
                    del sig["pr"]
        # (e)/(f)/(g) status per task
        for n in sorted(signals):
            sig = signals[n]
            if n not in status_of:
                print(f"NOTE #{n}: has live work but is not on the board (board.sh adopt {n})")
                continue
            cur = status_of[n]
            ci = fidx.get(normalized(cur), -1)
            if ci < 0:
                continue
            wt = sig.get("worktree")
            pr = sig.get("pr")
            merged = sig.get("merged")
            t = tel.get(str(n), {})
            # a merge never overrides live work (rework, a task split over PRs), and only counts when it
            # is newer than the card's last move into work (unknown last move: it counts)
            if merged and not (wt or pr) and ci < 3 and merged[1] >= t.get("work_ts", 0):
                merged = merged[0]
                rc = subprocess.run(["bash", os.path.join(os.path.dirname(board_sh), "two-pass-review-preflight.sh"),
                                     "--root", root, "--task", str(n)], capture_output=True, text=True).returncode
                if rc != 0:
                    print(f"NOTE #{n}: merged but review evidence missing — record it or use --accepted-by-user")
                    continue
                if fixer.move(n, cur, flow[3], merged, False) and fix:
                    status_of[n] = flow[3]
                continue
            if not (wt or pr):
                continue
            ready_pr = pr is not None and not pr[0].get("draft")
            review_tel = t.get("review")
            if ci < 2 and (ready_pr or review_tel):
                if ready_pr:
                    why = f"open PR #{pr[0].get('number')} marked ready, branch {pr[1]}"
                else:
                    why = f"live worktree {os.path.relpath(wt[1], root)}, branch {wt[0]}; review started"
                if fixer.move(n, cur, flow[2], why, True, wt[1] if wt else None) and fix:
                    status_of[n] = flow[2]
                continue
            if ci < 1:
                if wt:
                    why = f"live worktree {os.path.relpath(wt[1], root)}, branch {wt[0]}"
                else:
                    why = f"open PR #{pr[0].get('number')}, branch {pr[1]}"
                if fixer.move(n, cur, flow[1], why, True) and fix:
                    status_of[n] = flow[1]

    in_progress = [n for n, st in status_of.items() if st == (flow[1] if len(flow) > 1 else "In progress")]

    # (a) open PRs missing a board-issue reference
    pr_missing = [pr.get("number") for pr in prs if not has_ref(pr.get("body") or "")]
    if pr_missing:
        problems.append(
            "open PR(s) without a board-issue reference in the body: "
            + ", ".join("#" + str(n) for n in pr_missing)
        )

    # (b)/(c) branch <-> In-progress reconciliation (needs a branchPattern)
    if pattern:
        rx = branch_regex(pattern)
        branch_ids = {}
        for b in local_branches(root):
            m = rx.match(b)
            if m and "id" in m.groupdict():
                try:
                    branch_ids[int(m.group("id"))] = b
                except ValueError:
                    pass

        alive = set(local_branches(root)) | {((pr.get("head") or {}).get("ref")) or "" for pr in prs}
        stale = [b for b in links if b not in alive]
        if stale and fix:
            for b in stale:
                links.pop(b)
            try:
                with open(os.path.join(root, ".claude", "audit-links.json.tmp"), "w") as fh:
                    json.dump(links, fh, sort_keys=True)
                os.replace(os.path.join(root, ".claude", "audit-links.json.tmp"),
                           os.path.join(root, ".claude", "audit-links.json"))
            except OSError:
                pass

        no_item = sorted(b for i, b in branch_ids.items() if i not in in_progress)
        if no_item:
            problems.append(
                "branch(es) matching branchPattern with no In-progress board item: "
                + ", ".join(no_item)
            )

        no_branch = sorted(i for i in in_progress if i not in branch_ids)
        if no_branch:
            problems.append(
                "In-progress board item(s) with no matching local branch: "
                + ", ".join("#" + str(i) for i in no_branch)
            )

    # (d) work.type: local ONLY -- merged main-commit-subject scan
    recognized_counts = {p: 0 for p in PROCESS_PREFIXES}
    if work_type == "local":
        log = subprocess.run(
            ["git", "log", main_branch, "--format=%H %s", "-n", str(COMMIT_SCAN_WINDOW)],
            cwd=root, capture_output=True, text=True,
        ).stdout
        commit_problems = []
        for line in log.splitlines():
            if not line.strip():
                continue
            sha, _, subject = line.partition(" ")
            matched_class = next((p for p in PROCESS_PREFIXES if subject.startswith(p)), None)
            if matched_class:
                recognized_counts[matched_class] += 1
                continue
            if not has_ref(subject):
                commit_problems.append(sha[:8] + " " + subject)
        if commit_problems:
            problems.append(
                "merged main commit(s) without a #N reference (local mode): "
                + "; ".join(commit_problems)
            )

    for p in problems:
        print("DISCREPANCY: " + p)
    if work_type == "local":
        print(f"commit scan window: last {COMMIT_SCAN_WINDOW} commits")
        print(
            "recognized orchestrator process-commit classes: "
            + ", ".join(f"{p} ({recognized_counts[p]})" for p in PROCESS_PREFIXES)
        )
    if fixing and fix:
        print(f"AUDIT --fix: {fixer.changes} change(s)")
        sys.exit(1 if fixer.failures else 0)
    if fixing:
        print(f"AUDIT: {fixer.changes} change(s) pending (run board.sh audit --fix)")
    if problems or fixer.changes:
        print(f"AUDIT: {len(problems) + (1 if fixer.changes else 0)} discrepancy class(es) found")
        sys.exit(1)
    print("AUDIT: clean")
    sys.exit(0)


main()
