#!/usr/bin/env python3
"""sync-configs.py — bring anchored repos' .claude/project.yaml up to this
plugin's current config surface, via a versioned, ordered sync-rule list.

Usage:
    sync-configs.py [--scan BASE] [--apply] [--feedback-value true|false]
    sync-configs.py --repo PATH [--apply] [--feedback-value true|false]

Discovery (no --repo): every immediate child of the scan base (--scan, else
~/Development) carrying a <child>/.claude/.neural-network marker file, EXCEPT
the repo this script itself lives in (that repo updates itself through its
own build loop, not this script).

Dry-run is the DEFAULT: without --apply, prints per-repo diffs/rule
decisions and changes nothing, locally or remotely.

Git safety protocol: reads the target repo's project.mainBranch. If the
repo's current branch is that main branch AND its working tree is fully
clean, edits/commits/pushes happen directly on the live checkout. Otherwise
(non-main branch, or ANY dirty tree — staged, unstaged, or untracked) the
live checkout is never touched: a temporary detached worktree is created
from origin/<mainBranch>, edited/committed/pushed there, then removed.

Every repo is validated (validate-config.py) BEFORE any edit (an already
INVALID config aborts that repo, reported, untouched) and AFTER edits (a
rule that produces an invalid config is rolled back, nothing is committed).

Commit identity: resolved per-target-repo via identity.sh run with cwd
inside that repo's working copy (per-clone resolution — a plugin-repo
identity roster.py answers for THAT repo, not for this script's own).
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MARKER_NAME = ".neural-network"
CONFIG_REL = os.path.join(".claude", "project.yaml")


# --- sync rules -----------------------------------------------------------
# Each rule: id, detect(text) -> bool, apply(text) -> new_text. Text rules
# operate on the in-memory project.yaml text; the ordered list is threaded
# through so later rules see earlier rules' edits. Directory-level rules
# (sw062) are handled separately since they touch the filesystem, not just
# config text.

class TextRule:
    def __init__(self, rule_id, detect, apply):
        self.id = rule_id
        self.detect = detect
        self.apply = apply


def rule_strip_schema_data_key():
    pat = re.compile(r"(?m)^\$schema:.*\n")

    def detect(text):
        return pat.search(text) is not None

    def apply(text):
        return pat.sub("", text)

    return TextRule("strip-schema-data-key", detect, apply)


def rule_ensure_feedback_key(value=True):
    val_str = "true" if value else "false"
    block_pat = re.compile(r"(?m)^methodology:\n((?:[ \t]+\S.*\n?)*)")

    def _block(text):
        return block_pat.search(text)

    def detect(text):
        m = _block(text)
        if not m:
            return False
        block = m.group(1)
        return re.search(r"(?m)^[ \t]+feedback:\s*\S", block) is None

    def apply(text):
        m = _block(text)
        block = m.group(1)
        indent_m = re.search(r"(?m)^([ \t]+)\S", block)
        indent = indent_m.group(1) if indent_m else "    "
        insertion = f"{indent}feedback: {val_str}\n"
        end = m.end(1)
        return text[:end] + insertion + text[end:]

    return TextRule("ensure-feedback-key", detect, apply)


TEXT_RULES = [rule_strip_schema_data_key]  # ensure-feedback-key added with the configured value in main()


# ensure-peer-reviewer-identity is not a pure TextRule -- its detect step
# needs filesystem access (the target repo's .claude/settings.json) to know
# whether the peer-review plugin is enabled there, so it is threaded through
# process_repo() directly rather than via TEXT_RULES/apply_text_rules().
PEER_REVIEWER_NAME_TEMPLATE = "Peer Reviewer (codex) - {name}"
PEER_REVIEWER_EMAIL_TEMPLATE = "{local}+peer_reviewer@{domain}"

_identities_line_pat = re.compile(r"(?m)^([ \t]+)identities:[ \t]*\n")
# Intentionally unscoped to the identities: block -- a "peer-reviewer:" key
# anywhere in project.yaml is not valid YAML shape for anything else this
# schema defines, so a false-positive match is not a realistic risk here.
_peer_reviewer_key_pat = re.compile(r"(?m)^[ \t]+peer-reviewer:\s*$")


def peer_review_plugin_enabled(repo_root):
    """True when repo_root/.claude/settings.json's enabledPlugins map has a
    truthy '<marketplace-agnostic> peer-review@<marketplace>' key."""
    settings_path = Path(repo_root) / ".claude" / "settings.json"
    if not settings_path.is_file():
        return False
    try:
        data = json.loads(settings_path.read_text())
    except (OSError, ValueError):
        return False
    enabled = data.get("enabledPlugins")
    if not isinstance(enabled, dict):
        return False
    return any(key.split("@", 1)[0] == "peer-review" and val for key, val in enabled.items())


def _find_identities_block(text):
    """Locate the delegation.identities: block -> (insert_offset, child_indent),
    or None if no identities: key is present anywhere in the text. Children are
    lines indented deeper than the identities: line itself; child_indent is the
    indent of the first child found, else the identities: indent plus 4 spaces."""
    m = _identities_line_pat.search(text)
    if not m:
        return None
    base_len = len(m.group(1))
    pos = m.end()
    child_indent = None
    while pos < len(text):
        nl = text.find("\n", pos)
        line_end = nl + 1 if nl != -1 else len(text)
        line = text[pos:line_end]
        if line.strip() == "":
            pos = line_end
            continue
        indent_len = len(line) - len(line.lstrip(" \t"))
        if indent_len <= base_len:
            break
        if child_indent is None:
            child_indent = line[:indent_len]
        pos = line_end
    if child_indent is None:
        child_indent = m.group(1) + "    "
    return pos, child_indent


def rule_ensure_peer_reviewer_identity(text, repo_root):
    """-> (new_text, applied: bool). Adds delegation.identities.peer-reviewer
    (default name/email templates, no models -- matching identity_lib.py's
    DEFAULTS) only when the target repo has peer-review enabled AND doesn't
    already declare a peer-reviewer role."""
    if not peer_review_plugin_enabled(repo_root):
        return text, False
    if _peer_reviewer_key_pat.search(text):
        return text, False
    block = _find_identities_block(text)
    if block is not None:
        insert_at, child_indent = block
        entry = (
            f"{child_indent}peer-reviewer:\n"
            f"{child_indent}    name: {PEER_REVIEWER_NAME_TEMPLATE}\n"
            f"{child_indent}    email: '{PEER_REVIEWER_EMAIL_TEMPLATE}'\n"
        )
        return text[:insert_at] + entry + text[insert_at:], True
    sep = "" if text.endswith("\n") else "\n"
    block_text = (
        f"{sep}delegation:\n"
        f"    identities:\n"
        f"        peer-reviewer:\n"
        f"            name: {PEER_REVIEWER_NAME_TEMPLATE}\n"
        f"            email: '{PEER_REVIEWER_EMAIL_TEMPLATE}'\n"
    )
    return text + block_text, True


def sw062_detect(repo_root):
    legacy = repo_root / ".claude" / "feedback"
    new = repo_root / ".claude" / "feedbacks"
    return legacy.is_dir() and not new.exists()


def sw062_apply(repo_root):
    """mv .claude/feedback -> .claude/feedbacks; drop its .gitignore line.
    Returns the list of repo-relative paths that changed/need staging."""
    legacy = repo_root / ".claude" / "feedback"
    new = repo_root / ".claude" / "feedbacks"
    shutil.move(str(legacy), str(new))
    changed = [os.path.join(".claude", "feedbacks")]
    gi = repo_root / ".gitignore"
    if gi.is_file():
        lines = gi.read_text().splitlines(keepends=True)
        kept = [ln for ln in lines if ln.strip() != ".claude/feedback/"]
        if kept != lines:
            gi.write_text("".join(kept))
            changed.append(".gitignore")
    return changed


def sw062_rollback(repo_root):
    """Undo sw062_apply()'s filesystem move so a post-edit INVALID never
    strands a half-migrated repo. `git checkout -- .` only restores tracked
    file CONTENTS (the .gitignore line); it does not know how to reverse a
    real `shutil.move` of an untracked-vs-tracked directory pair, so that
    part needs its own paired undo. Leaves the repo exactly as
    sw062_detect() would see it before sw062_apply() ran (legacy dir back,
    new dir gone) -- i.e. still detectable and re-appliable by a future run."""
    legacy = repo_root / ".claude" / "feedback"
    new = repo_root / ".claude" / "feedbacks"
    if new.exists() and not legacy.exists():
        shutil.move(str(new), str(legacy))


# --- git / process helpers ------------------------------------------------

def run(cmd, cwd=None, check=False):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=check)


def git(args, cwd):
    return run(["git"] + args, cwd=cwd)


def validate(config_path):
    """Returns (ok: bool, output: str)."""
    p = run([sys.executable, str(HERE / "validate-config.py"), str(config_path)])
    return p.returncode == 0, (p.stdout + p.stderr).strip()


def resolve_identity_flags(repo_root):
    """Resolve the target repo's orchestrator identity via identity.sh, cwd
    inside that repo. Returns a list of -c flags for `git commit`, or None
    if unresolved (caller falls back to no explicit identity)."""
    p = run(["bash", str(HERE / "identity.sh"), "orchestrator"], cwd=str(repo_root))
    out = p.stdout
    for line in out.splitlines():
        if line.startswith("flags: "):
            return shlex.split(line[len("flags: "):])
    return None


def find_config_path(repo_root):
    p = repo_root / CONFIG_REL
    if p.is_file():
        return p
    alt = repo_root / ".claude" / "project.json"
    return alt if alt.is_file() else None


def get_main_branch(repo_root, config_path):
    p = run([sys.executable, str(HERE / "config.py"), str(repo_root), "get", "project.mainBranch"])
    val = p.stdout.strip()
    return val or "main"


def is_self_repo(candidate, self_root):
    try:
        return candidate.resolve() == self_root
    except OSError:
        return False


def discover_repos(scan_base, self_root):
    found = {}
    sb = Path(scan_base).expanduser()
    try:
        children = sorted(sb.iterdir()) if sb.is_dir() else []
    except OSError:
        children = []
    for child in children:
        try:
            if not child.is_dir():
                continue
            if not (child / ".claude" / MARKER_NAME).is_file():
                continue
            rp = child.resolve()
            if is_self_repo(child, self_root):
                continue
            found.setdefault(str(rp), rp)
        except OSError:
            continue
    return sorted(found.values(), key=lambda p: p.name)


# --- per-repo processing ---------------------------------------------------

class RepoResult:
    def __init__(self, path):
        self.path = str(path)
        self.lines = [f"repo: {self.path}"]

    def add(self, line):
        self.lines.append(f"  {line}")

    def render(self):
        return "\n".join(self.lines)


def apply_text_rules(text, feedback_value):
    rules = [rule_strip_schema_data_key(), rule_ensure_feedback_key(feedback_value)]
    applied = []
    for r in rules:
        if r.detect(text):
            new_text = r.apply(text)
            if new_text != text:
                applied.append(r.id)
                text = new_text
    return text, applied


def process_repo(repo_root, args):
    result = RepoResult(repo_root)
    config_path = find_config_path(repo_root)
    if config_path is None:
        result.add("route: skipped-no-config")
        return result, False

    pre_ok, pre_out = validate(config_path)
    result.add(f"validate pre: {'VALID' if pre_ok else 'INVALID'}")
    if not pre_ok:
        result.add("route: skipped-invalid")
        result.add(pre_out.replace("\n", "\n  "))
        return result, False

    main_branch = get_main_branch(repo_root, config_path)
    current_branch = git(["branch", "--show-current"], repo_root).stdout.strip()
    status = git(["status", "--porcelain"], repo_root).stdout
    on_main_clean = (current_branch == main_branch) and status.strip() == ""

    original_text = config_path.read_text()
    new_text, applied = apply_text_rules(original_text, args.feedback_value)
    new_text, pr_applied = rule_ensure_peer_reviewer_identity(new_text, repo_root)
    if pr_applied:
        applied.append("ensure-peer-reviewer-identity")
    sw062_applies = sw062_detect(repo_root)
    if sw062_applies:
        applied.append("sw062-feedbacks-migration")

    if not applied:
        result.add("route: no-op")
        return result, False

    result.add(f"rules applied: {', '.join(applied)}")

    if not args.apply:
        result.add("route: dry-run")
        if new_text != original_text:
            result.add(f"[diff] {config_path.relative_to(repo_root)} would change ({len(new_text.splitlines())} lines)")
        if sw062_applies:
            result.add("[diff] .claude/feedback/ would move to .claude/feedbacks/; its .gitignore line would be dropped")
        return result, False

    worktree_dir = None
    if on_main_clean:
        work_dir = repo_root
        result.add("route: main")
    else:
        result.add("route: worktree")
        git(["fetch", "origin", main_branch], repo_root)
        worktree_dir = Path(tempfile.mkdtemp(prefix="sync-configs-wt-"))
        wt = git(["worktree", "add", "--detach", str(worktree_dir), f"origin/{main_branch}"], repo_root)
        if wt.returncode != 0:
            result.add(f"route: skipped-worktree-failed: {wt.stderr.strip()}")
            shutil.rmtree(worktree_dir, ignore_errors=True)
            return result, False
        work_dir = worktree_dir

    try:
        work_config_path = work_dir / config_path.relative_to(repo_root)
        work_text = work_config_path.read_text()
        work_new_text, _ = apply_text_rules(work_text, args.feedback_value)
        work_new_text, _ = rule_ensure_peer_reviewer_identity(work_new_text, work_dir)
        if work_new_text != work_text:
            work_config_path.write_text(work_new_text)
        changed_files = set()
        if work_new_text != work_text:
            changed_files.add(str(work_config_path.relative_to(work_dir)))
        if sw062_applies:
            changed_files.update(sw062_apply(work_dir))

        post_ok, post_out = validate(work_config_path)
        result.add(f"validate post: {'VALID' if post_ok else 'INVALID'}")
        if not post_ok:
            result.add("route: rolled-back-invalid")
            result.add(post_out.replace("\n", "\n  "))
            if sw062_applies:
                sw062_rollback(work_dir)
            git(["checkout", "--", "."], work_dir)
            return result, False

        git(["add"] + sorted(changed_files), work_dir)
        staged = git(["diff", "--cached", "--name-only"], work_dir).stdout.strip()
        if not staged:
            result.add("route: no-op")
            return result, False

        flags = resolve_identity_flags(work_dir) or []
        msg = f"chore(sync-configs): apply {', '.join(applied)}"
        commit_cmd = ["git"] + flags + ["commit", "-m", msg]
        c = run(commit_cmd, cwd=str(work_dir))
        if c.returncode != 0:
            result.add(f"commit: FAILED ({(c.stdout + c.stderr).strip()})")
            return result, False
        sha = git(["rev-parse", "HEAD"], work_dir).stdout.strip()
        result.add(f"commit: {sha}")

        if worktree_dir is None:
            push = git(["push", "origin", main_branch], work_dir)
        else:
            push = git(["push", "origin", f"HEAD:{main_branch}"], work_dir)
        if push.returncode == 0:
            result.add("push: ok")
        else:
            result.add(f"push: FAILED ({(push.stdout + push.stderr).strip()})")
            return result, False

        return result, True
    finally:
        if worktree_dir is not None:
            git(["worktree", "remove", "--force", str(worktree_dir)], repo_root)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scan", default=None, help="scan base (default ~/Development)")
    ap.add_argument("--repo", default=None, help="target exactly one repo (bypasses discovery)")
    ap.add_argument("--apply", action="store_true", help="write/commit/push (default: dry-run)")
    ap.add_argument("--feedback-value", choices=["true", "false"], default="true",
                     help="value written by ensure-feedback-key (default: true)")
    args = ap.parse_args(argv)
    args.feedback_value = args.feedback_value == "true"

    self_root = Path(run(["git", "rev-parse", "--show-toplevel"], cwd=str(HERE)).stdout.strip() or HERE)

    if args.repo:
        repos = [Path(args.repo).resolve()]
    else:
        scan_base = args.scan or str(Path.home() / "Development")
        repos = discover_repos(scan_base, self_root)

    print(f"mode: {'apply' if args.apply else 'dry-run (default; pass --apply to write/commit/push)'}")

    synced = noop = skipped = 0
    for repo_root in repos:
        result, did_sync = process_repo(repo_root, args)
        print(result.render())
        if did_sync:
            synced += 1
        elif any("skipped" in ln for ln in result.lines):
            skipped += 1
        else:
            noop += 1

    print(f"AGGREGATE repos={len(repos)} synced={synced} noop={noop} skipped={skipped} "
          f"mode={'apply' if args.apply else 'dry-run'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
