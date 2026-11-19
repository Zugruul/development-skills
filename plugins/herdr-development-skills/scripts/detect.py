#!/usr/bin/env python3
"""detect.py -- which development-skills integrations can run here, right now.

Read-only and offline. Answers three questions for the current repository:

  1. Is Herdr usable (inside a Herdr pane, binary on PATH) and is the `herdr`
     plugin, whose skills every integration builds on, available?
  2. Which specialized plugins are enabled or at least installed
     (spec-workflow, peer-review, remote-compute)?
  3. Is each one configured for THIS repository, and with which settings?

From that it derives which integration skills are READY. Everything this
marketplace knows about the specialized plugins and Herdr together lives in
this plugin; the `herdr` plugin stays unaware of them.

usage: detect.py [--root DIR] [--json]
Exit code is 0 whenever detection ran, whatever it found. Stdlib only, 3.9+.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGINS_DIR = os.environ.get("HDS_PLUGINS_DIR") or os.path.dirname(os.path.dirname(HERE))
MARKERS = {  # one skill that proves the plugin's skills are linked into a skills directory
    "herdr": "orchestrate", "spec-workflow": "build-next",
    "peer-review": "peer-review", "remote-compute": "remote-compute",
}
SKILL_DIRS = (".claude/skills", ".agents/skills", ".opencode/skills")


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def git(root, *args):
    try:
        p = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)
    except OSError:
        return ""
    return p.stdout.strip() if p.returncode == 0 else ""


def primary_checkout(root):
    """The main worktree of root's repository (local state such as a pause flag lives there)."""
    common = git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if common and os.path.basename(common) == ".git":
        return os.path.dirname(common)
    return git(root, "rev-parse", "--show-toplevel") or root


def plugin_state(name, root, primary):
    """enabled (host settings say so) | available (installed or linked; enablement unknown) | absent."""
    home = os.path.expanduser("~")
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
    verdict, where = None, ""
    roots = [root] if primary == root else [primary, root]
    files = [os.path.join(cfg, "settings.json")]
    for r in roots:
        files += [os.path.join(r, ".claude", "settings.json"), os.path.join(r, ".claude", "settings.local.json")]
    for f in files:  # later files win, as in the host's own precedence
        enabled = load_json(f).get("enabledPlugins")
        for key, val in (enabled.items() if isinstance(enabled, dict) else []):
            if key.split("@")[0] == name and isinstance(val, bool):
                verdict, where = val, f
    path = ""
    sibling = os.path.join(PLUGINS_DIR, name)
    if os.path.isdir(os.path.join(sibling, "skills")):
        path = sibling
    else:
        installed = load_json(os.path.join(cfg, "plugins", "installed_plugins.json")).get("plugins")
        for key, entries in (installed.items() if isinstance(installed, dict) else []):
            if key.split("@")[0] != name or not isinstance(entries, list):
                continue
            for e in entries:
                p = e.get("installPath") if isinstance(e, dict) else None
                if isinstance(p, str) and os.path.isdir(os.path.join(p, "skills")):
                    path = p
    linked = ""
    for r in roots:
        for d in SKILL_DIRS:
            if os.path.isfile(os.path.join(r, d, MARKERS[name], "SKILL.md")):
                linked = os.path.join(r, d)
    if verdict is True:
        return {"state": "enabled", "why": "enabledPlugins in %s" % where, "path": path}
    if linked:
        return {"state": "enabled", "why": "skills linked in %s" % linked, "path": path}
    if verdict is False:
        return {"state": "absent", "why": "disabled in %s" % where, "path": path}
    if path:
        return {"state": "available", "why": "found at %s; could not confirm it is enabled for this host" % path, "path": path}
    return {"state": "absent", "why": "not enabled in settings, not installed, no skills linked", "path": ""}


def spec_workflow_config(root, primary, plugin_path):
    out = {"configured": False, "file": "", "readable": False, "note": ""}
    candidates = [".neural-network/project.yaml", ".neural-network/project.json", ".claude/project.yaml", ".claude/project.json"]
    for c in candidates:
        if os.path.isfile(os.path.join(root, c)):
            out.update(configured=True, file=os.path.join(root, c))
            break
    if not out["configured"]:
        out["note"] = "no .neural-network/project.yaml in this repository (run the spec-workflow setup-project skill)"
        return out
    loader = os.path.join(plugin_path, "scripts", "config.py") if plugin_path else ""
    cfg = None
    if loader and os.path.isfile(loader):
        try:
            p = subprocess.run([sys.executable, loader, root, "json"], capture_output=True, text=True, timeout=30)
            cfg = json.loads(p.stdout) if p.returncode == 0 else None
            if cfg is None:
                out["note"] = "the spec-workflow config loader failed: " + (p.stderr.strip().splitlines() or ["no output"])[-1]
        except (OSError, ValueError, subprocess.TimeoutExpired) as e:
            out["note"] = "the spec-workflow config loader failed: %s" % e
    else:
        out["note"] = "spec-workflow's config loader was not found, so the settings below are unknown"
    if not isinstance(cfg, dict):
        return out

    def get(path, default=None):
        cur = cfg
        for part in path.split("."):
            cur = cur.get(part) if isinstance(cur, dict) else None
        return default if cur is None else cur

    flag = get("paths.checkpointFile", ".claude/CHECKPOINT")
    flag_path = flag if os.path.isabs(flag) else os.path.join(primary, flag)
    lanes = get("methodology.maxInProgress", 1)
    out.update(
        readable=True,
        mainBranch=get("project.mainBranch", "main"),
        branchPattern=get("project.branchPattern", ""),
        maxInProgress=lanes if isinstance(lanes, int) and not isinstance(lanes, bool) and lanes > 0 else 1,
        serialDelivery=bool(get("methodology.serialDelivery", False)),
        autoMerge=bool(get("methodology.autoMerge", False)),
        workType=get("work.type", "pr"),
        workCheckout=get("work.checkout", "worktree"),
        herdrEnabled=bool(get("herdr.enabled", False)),
        herdrTaskLanes=bool(get("herdr.worktrees.taskLanes", True)),
        hasBoard=bool(get("boards")),
        checkpointFile=flag_path,
        paused=os.path.lexists(flag_path),
    )
    return out


def detect(root):
    root = os.path.abspath(root)
    primary = primary_checkout(root)
    inside = os.environ.get("HERDR_ENV") == "1"
    binary = shutil.which("herdr") or ""
    herdr = {"inside": inside, "binary": binary, "ok": inside and bool(binary)}
    herdr["why"] = ("ok" if herdr["ok"] else
                    "not running inside a Herdr pane (HERDR_ENV is not 1)" if not inside else
                    "the herdr binary is not on PATH")
    plugins = {n: plugin_state(n, root, primary) for n in MARKERS}
    sw = plugins["spec-workflow"]
    cfg = spec_workflow_config(root, primary, sw["path"]) if sw["state"] != "absent" else {
        "configured": any(os.path.isfile(os.path.join(root, c)) for c in (".neural-network/project.yaml", ".neural-network/project.json")),
        "readable": False, "note": "", "file": ""}

    base = []  # reasons that stop every integration
    if not herdr["ok"]:
        base.append("Herdr: " + herdr["why"])
    if plugins["herdr"]["state"] == "absent":
        base.append("the herdr plugin is not available (%s) -- install herdr@development-skills" % plugins["herdr"]["why"])

    def build(extra_ok=True):
        why = list(base)
        if sw["state"] == "absent":
            why.append("the spec-workflow plugin is not available (%s)" % sw["why"])
        elif not cfg["configured"]:
            why.append("spec-workflow is not configured here: " + cfg["note"])
        elif cfg["readable"] and not cfg["hasBoard"]:
            why.append("spec-workflow's project config declares no board")
        if why:
            return {"state": "UNAVAILABLE", "why": why}
        if cfg.get("paused"):
            return {"state": "PAUSED", "why": ["the build loop is paused: %s exists (the spec-workflow checkpoint skill resumes it)" % cfg["checkpointFile"]]}
        notes = []
        if sw["state"] == "available":
            notes.append("spec-workflow is installed but not confirmed enabled: check its skills are listed in your session")
        if not cfg["readable"]:
            notes.append(cfg["note"])
        return {"state": "READY", "why": notes}

    features = {"task-lane": build(), "build-loop": build(), "build-lanes": build()}
    lanes = cfg.get("maxInProgress", 1) if cfg.get("readable") else None
    features["build-lanes"]["lanes"] = lanes
    if features["build-lanes"]["state"] == "READY" and lanes == 1:
        features["build-lanes"]["why"].append(
            "methodology.maxInProgress is 1: one lane at a time (the spec-workflow concurrency skill raises it)")
    pr = plugins["peer-review"]
    why = list(base)
    if pr["state"] == "absent":
        why.append("the peer-review plugin is not available (%s)" % pr["why"])
    features["review-lane"] = {"state": "UNAVAILABLE" if why else "READY", "why": why or (
        ["peer-review is installed but not confirmed enabled: check its skill is listed in your session"]
        if pr["state"] == "available" else [])}
    return {"root": root, "primaryCheckout": primary, "herdr": herdr, "plugins": plugins,
            "specWorkflow": cfg, "features": features}


def render(d):
    lines = ["INTEGRATIONS for %s" % d["root"]]
    if d["primaryCheckout"] != d["root"]:
        lines.append("  primary checkout: %s" % d["primaryCheckout"])
    lines.append("herdr: %s" % ("ok, inside Herdr" if d["herdr"]["ok"] else "NOT USABLE -- " + d["herdr"]["why"]))
    lines.append("PLUGINS")
    for name, p in d["plugins"].items():
        lines.append("  %-15s %-9s %s" % (name, p["state"], p["why"]))
    c = d["specWorkflow"]
    lines.append("SPEC-WORKFLOW IN THIS REPOSITORY")
    if not c["configured"]:
        lines.append("  not configured" + (": " + c["note"] if c.get("note") else ""))
    elif not c["readable"]:
        lines.append("  configured (%s), settings unknown: %s" % (c.get("file") or "config found", c.get("note") or "plugin not available"))
    else:
        lines.append("  config: %s" % c["file"])
        lines.append("  mainBranch=%s branchPattern=%s" % (c["mainBranch"], c["branchPattern"] or "(none)"))
        lines.append("  maxInProgress=%s serialDelivery=%s autoMerge=%s" % (
            c["maxInProgress"], str(c["serialDelivery"]).lower(), str(c["autoMerge"]).lower()))
        lines.append("  work.type=%s work.checkout=%s" % (c["workType"], c["workCheckout"]))
        lines.append("  herdr.enabled=%s herdr.worktrees.taskLanes=%s" % (
            str(c["herdrEnabled"]).lower(), str(c["herdrTaskLanes"]).lower()))
        lines.append("  checkpoint: %s" % ("PAUSED (%s)" % c["checkpointFile"] if c["paused"] else "clear"))
    lines.append("FEATURES")
    for name, f in d["features"].items():
        head = "  %-12s %s" % (name, f["state"])
        if name == "build-lanes" and f["state"] == "READY" and f.get("lanes"):
            head += " (up to %d lane%s)" % (f["lanes"], "" if f["lanes"] == 1 else "s")
        lines.append(head)
        for w in f["why"]:
            lines.append("      - %s" % w)
    lines.append("remote-compute has no Herdr integration; it is listed for completeness.")
    lines.append("This is a hint, not proof: a plugin counts only if its skills are listed in your session.")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="Which development-skills integrations can run in this repository.")
    ap.add_argument("--root", default=os.getcwd())
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    d = detect(a.root)
    print(json.dumps(d, indent=1) if a.json else render(d))


if __name__ == "__main__":
    main()
