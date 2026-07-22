#!/usr/bin/env python3
"""kb-seed.py — knowledge-graph seeder (GL-050, SPEC-GRAPHIFY §17).

Explores a project's specs, backlogs, design docs, applied spec-deltas,
top-level docs (README/AGENTS/CLAUDE.md), top-level layout, git history
(stdlib `git log` parsing only — no live `gh` calls), and board epics
(read from `specs[].epics` in project.yaml, never a live board fetch), and
seeds/updates zettel notes in a `knowledge` identity brain
(`<identities>/knowledge/brain/`), reusing brain.py's note/link
serialization and shrink-guard machinery BY IMPORT rather than
reimplementing any of it.

Deterministic + idempotent + offline: two seed runs over unchanged sources
leave notes/, links.json, and DIRECTORY.md byte-identical (an unchanged
candidate is never rewritten). A changed source updates its note IN PLACE
on re-seed — same slug, bumped `strength`, refreshed `last-touched` — never
a new file, never a delete (matches brain.py's own re-mint semantics). A
seed run that would update more than `methodology.shrinkGuardFraction` of
the EXISTING knowledge notes in one invocation refuses, reusing
`brain._shrink_guard` verbatim (GL-005/SPEC-GRAPHIFY §13), unless --force.

Python 3 standard library + PyYAML only (via config.py). Usage:

    kb-seed.py <root> seed [--dir .claude/identities] [--role knowledge] [--force] [--dry-run]
"""
import argparse
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brain as B  # noqa: E402 -- reuse note/link serialization + shrink guard
import config as C  # noqa: E402

DEFAULT_ROLE = "knowledge"
MAX_OUTLINE_LINES = 12
GIT_LOG_LIMIT = 20
ROOT_DOC_NAMES = ("README.md", "AGENTS.md", "CLAUDE.md")


# --------------------------------------------------------------- rendering
def _slugify(s):
    s = re.sub(r"[^a-zA-Z0-9]+", "-", s).strip("-").lower()
    return s or "note"


def _outline(text, max_lines=MAX_OUTLINE_LINES):
    """Markdown `#` headers, in file order, capped at max_lines -- a cheap,
    fully deterministic summary of a doc without parsing prose."""
    heads = []
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("#"):
            heads.append(s)
        if len(heads) >= max_lines:
            break
    return heads


def _bulleted(items, empty="(none found)"):
    if not items:
        return empty
    return "\n".join("- %s" % i for i in items)


def _git_log_subjects(root, limit=GIT_LOG_LIMIT):
    try:
        out = subprocess.check_output(
            ["git", "-C", root, "log", "--pretty=%s", "-n", str(limit)],
            stderr=subprocess.DEVNULL)
    except Exception:
        return []
    return [ln for ln in out.decode("utf-8", "replace").splitlines() if ln.strip()]


def _current_commit(root):
    try:
        out = subprocess.check_output(
            ["git", "-C", root, "rev-parse", "HEAD"], stderr=subprocess.DEVNULL)
        return out.decode("utf-8", "replace").strip()
    except Exception:
        return "unknown"


# ------------------------------------------------------------ source discovery
def _spec_and_backlog_sources(root, spec):
    sid = spec.get("id")
    if not sid:
        return
    title = spec.get("title", "")
    sp = spec.get("specPath")
    if sp:
        fp = os.path.join(root, sp)
        if os.path.isfile(fp):
            text = open(fp, encoding="utf-8").read()
            body = "Spec `%s` (%s).\n\n%s\n" % (sp, title, _bulleted(_outline(text)))
            yield {"slug": "spec-%s" % sid, "tags": ["spec", sid], "paths": [sp],
                   "seed_path": sp, "body": body}
    bp = spec.get("backlogPath")
    if bp:
        fp = os.path.join(root, bp)
        if os.path.isfile(fp):
            text = open(fp, encoding="utf-8").read()
            body = "Backlog `%s` for spec `%s`.\n\n%s\n" % (bp, sid, _bulleted(_outline(text)))
            yield {"slug": "backlog-%s" % sid, "tags": ["backlog", sid], "paths": [bp],
                   "seed_path": bp, "body": body}


def _epic_sources(spec):
    sid = spec.get("id")
    if not sid:
        return
    for epic in (spec.get("epics") or []):
        eid = epic.get("id")
        if not eid:
            continue
        etitle = epic.get("title", "")
        ranges = epic.get("taskRanges") or []
        range_str = ", ".join("%s-%s" % (r[0], r[1]) for r in ranges if len(r) == 2) or "unspecified"
        body = "Epic %s — %s (spec %s, tasks %s).\n" % (eid, etitle, sid, range_str)
        yield {"slug": "epic-%s-%s" % (sid.lower(), eid.lower()), "tags": ["epic", sid],
               "paths": [], "seed_path": ".claude/project.yaml", "body": body}


def _design_doc_sources(root, cfg):
    design_dir = C.dig(cfg, "paths.designDir")
    if not design_dir:
        return
    dd = os.path.join(root, design_dir)
    if not os.path.isdir(dd):
        return
    for fn in sorted(os.listdir(dd)):
        if not fn.endswith(".md"):
            continue
        relpath = os.path.join(design_dir, fn)
        text = open(os.path.join(dd, fn), encoding="utf-8").read()
        body = "Design doc `%s`.\n\n%s\n" % (relpath, _bulleted(_outline(text)))
        yield {"slug": "design-%s" % _slugify(fn[:-3]), "tags": ["design"], "paths": [relpath],
               "seed_path": relpath, "body": body}


def _applied_delta_sources(root, cfg):
    delta_dir = C.dig(cfg, "paths.specDeltaDir")
    if not delta_dir:
        return
    applied = os.path.join(root, delta_dir, "applied")
    if not os.path.isdir(applied):
        return
    for fn in sorted(os.listdir(applied)):
        if not fn.endswith(".md"):
            continue
        relpath = os.path.join(delta_dir, "applied", fn)
        text = open(os.path.join(applied, fn), encoding="utf-8").read()
        fm, _body = B.parse_note(text)  # reuse brain.py's frontmatter parser -- no re-derive
        sections = fm.get("sections") or []
        sec_str = ", ".join(str(s) for s in sections) if isinstance(sections, list) else str(sections)
        body = ("Applied spec-delta `%s` (task %s, spec %s).\n\nSections: %s\n"
                % (relpath, fm.get("task", "?"), fm.get("spec", "?"), sec_str or "(none)"))
        yield {"slug": "spec-delta-%s" % _slugify(fn[:-3]), "tags": ["spec-delta", "applied"],
               "paths": [relpath], "seed_path": relpath, "body": body}


def _root_doc_sources(root):
    for name in ROOT_DOC_NAMES:
        fp = os.path.join(root, name)
        if not os.path.isfile(fp):
            continue
        text = open(fp, encoding="utf-8").read()
        body = "Project doc `%s`.\n\n%s\n" % (name, _bulleted(_outline(text)))
        yield {"slug": "doc-%s" % name.split(".")[0].lower(), "tags": ["doc"], "paths": [name],
               "seed_path": name, "body": body}


def _layout_source(root, cfg):
    entries = sorted(e for e in os.listdir(root) if not e.startswith("."))
    dirs = [e for e in entries if os.path.isdir(os.path.join(root, e))]
    project_name = (cfg.get("project") or {}).get("name") or os.path.basename(os.path.abspath(root))
    body = "Top-level layout of `%s`.\n\n%s\n" % (project_name, _bulleted(["%s/" % d for d in dirs]))
    return {"slug": "project-layout", "tags": ["layout"], "paths": [],
            "seed_path": "(directory listing)", "body": body}


def _git_history_source(root):
    subjects = _git_log_subjects(root)
    if not subjects:
        return None
    body = "Recent commit history (most recent first).\n\n%s\n" % _bulleted(subjects)
    return {"slug": "git-history", "tags": ["git-history"], "paths": [],
            "seed_path": "(git log)", "body": body}


def discover_sources(root, cfg):
    """Every seedable source, in a fixed deterministic order (spec declaration
    order in project.yaml, then sorted filenames within each source kind)."""
    out = []
    for spec in (cfg.get("specs") or []):
        out.extend(_spec_and_backlog_sources(root, spec))
        out.extend(_epic_sources(spec))
    out.extend(_design_doc_sources(root, cfg))
    out.extend(_applied_delta_sources(root, cfg))
    out.extend(_root_doc_sources(root))
    out.append(_layout_source(root, cfg))
    git_source = _git_history_source(root)
    if git_source:
        out.append(git_source)
    return out


# ------------------------------------------------------------------- seeding
def _build_fm(tags, paths, seed_path, commit, created, strength, last_touched):
    return {
        "tags": tags,
        "paths": paths,
        "strength": strength,
        "source": "seed",
        "seed-path": seed_path,
        "seed-commit": commit,
        "created": created,
        "last-touched": last_touched,
    }


def _seed(root, identities, role, force, dry_run):
    cfg = C.load_config(root=root, warn=False) or {}
    commit = _current_commit(root)
    candidates = discover_sources(root, cfg)
    existing = B.load_notes(identities, role)
    total_existing = len(existing)

    to_write = {}
    created_slugs = []
    superseded_slugs = []
    unchanged = 0

    for c in candidates:
        slug = c["slug"]
        old = existing.get(slug)
        if old is None:
            fm = _build_fm(c["tags"], c["paths"], c["seed_path"], commit,
                            created=B.today(), strength=B.DEFAULT_STRENGTH, last_touched=B.today())
            to_write[slug] = (fm, c["body"])
            created_slugs.append(slug)
            continue
        old_fm, old_body = old["fm"], old["body"]
        if (old_body == c["body"] and old_fm.get("tags", []) == c["tags"]
                and old_fm.get("paths", []) == c["paths"]):
            unchanged += 1
            continue  # true no-op: never touch the file
        new_strength = int(old_fm.get("strength", B.DEFAULT_STRENGTH)) + 1
        created = old_fm.get("created", B.today())
        fm = _build_fm(c["tags"], c["paths"], c["seed_path"], commit,
                        created=created, strength=new_strength, last_touched=B.today())
        to_write[slug] = (fm, c["body"])
        superseded_slugs.append(slug)

    if superseded_slugs:
        fraction = B._shrink_guard_fraction(argparse.Namespace(root=root))
        if not B._shrink_guard("note(s)", superseded_slugs, total_existing, force, fraction):
            return 1

    if dry_run:
        print("DRY RUN: would create %d, update %d, leave %d unchanged" %
              (len(created_slugs), len(superseded_slugs), unchanged))
        return 0

    if to_write:
        d = B.notes_dir(identities, role)
        os.makedirs(d, exist_ok=True)
        links = B.load_links(identities, role)
        formed = 0
        for slug in sorted(to_write):
            fm, body = to_write[slug]
            path = os.path.join(d, slug + ".md")
            open(path, "w", encoding="utf-8").write(B.render_note(fm, body))
            for target in B.WIKILINK.findall(body):
                key = "%s->%s" % (slug, target.strip())
                if key not in links:
                    links[key] = {"weight": B.DEFAULT_WEIGHT, "fires": 0, "last": None}
                    formed += 1
        B.save_links(identities, role, links)
    else:
        formed = 0

    # DIRECTORY.md is fully derived from notes on disk -- regenerating it
    # after a no-op run reproduces byte-identical content (AC2), so this is
    # always safe to call.
    B.cmd_directory(identities, None)

    print("seeded %s: %d created, %d updated, %d unchanged, %d new link(s)" %
          (role, len(created_slugs), len(superseded_slugs), unchanged, formed))
    return 0


def cmd_seed(args):
    identities = os.path.join(args.root, args.dir)
    return _seed(args.root, identities, args.role, args.force, args.dry_run)


def main(argv):
    p = argparse.ArgumentParser(
        prog="kb-seed.py", description="Seed/update a knowledge identity brain from project sources (GL-050).")
    p.add_argument("root", help="consumer repo root")
    p.add_argument("--dir", default=".claude/identities", help="identities dir (relative to root)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("seed")
    sp.add_argument("--role", default=DEFAULT_ROLE)
    sp.add_argument("--force", action="store_true")
    sp.add_argument("--dry-run", dest="dry_run", action="store_true")
    sp.set_defaults(fn=cmd_seed)

    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
