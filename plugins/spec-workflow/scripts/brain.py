#!/usr/bin/env python3
"""brain.py — per-identity zettel memory engine for the spec-workflow plugin.

Each identity (dev / reviewer / orchestrator / …) owns a PRIVATE brain under
`<identities-dir>/<role>/brain/`. Notes are atomic markdown zettels with simple
frontmatter; `[[slug]]` wikilinks connect them; link metadata (weight/fires/last)
lives in `links.json` so the notes stay clean markdown for humans.

STRICT ISOLATION: this engine only ever touches ONE role's brain per command
(recall/mint/graduate/prune operate on <role>; consult reads the OWNER's note and
logs to the OWNER while counting recurrence in the CONSUMER). Nothing here lets a
role read another role's brain implicitly — the orchestrator drives every call.

Python 3 standard library only (no pyyaml). Usage:

    brain.py <root> recall <role> --paths "a/b.sh,c/**" --keywords "yaml,merge" [--budget 600]
    brain.py <root> mint <role> <slug> --tags a,b --paths "x/**" --source "..." [--learned-from R --source-note S]
    brain.py <root> directory
    brain.py <root> consult <consumer-role> <owner-role> <slug>
    brain.py <root> prune <role> [--apply]
    brain.py <root> retro-mark
    brain.py <root> graduate <role> <slug>

`<root>` is the consumer repo root; identities live under `--dir` (default
`.claude/identities`).
"""

import argparse
import datetime
import json
import os
import re
import sys

WIKILINK = re.compile(r"\[\[([^\]]+)\]\]")
DEFAULT_STRENGTH = 1
DEFAULT_WEIGHT = 0.5
HOP_DECAY = 0.5
MAX_HOPS = 2
CHARS_PER_TOKEN = 4
# frontmatter keys in deterministic write order
KEY_ORDER = ["tags", "paths", "strength", "source", "learned-from", "source-note", "graduated", "created"]


# ---------------------------------------------------------------- small helpers
def today():
    return datetime.date.today().isoformat()


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def brain_dir(identities, role):
    return os.path.join(identities, role, "brain")


def notes_dir(identities, role):
    return os.path.join(brain_dir(identities, role), "notes")


def glob_to_regex(glob):
    """Translate a path glob to a regex. `**` crosses directories, `*`/`?` stay
    within a single segment; `**/` optionally matches zero leading dirs."""
    out = []
    i = 0
    n = len(glob)
    while i < n:
        c = glob[i]
        if glob.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def glob_match(path, glob):
    return glob_to_regex(glob).match(path) is not None


# ------------------------------------------------------------ frontmatter parse
def parse_note(text):
    """Return (frontmatter dict, body str). Hand-rolled — no yaml."""
    fm = {}
    body = text
    if text.startswith("---"):
        lines = text.split("\n")
        end = None
        for idx in range(1, len(lines)):
            if lines[idx].strip() == "---":
                end = idx
                break
        if end is not None:
            for line in lines[1:end]:
                if not line.strip() or ":" not in line:
                    continue
                key, _, rest = line.partition(":")
                fm[key.strip()] = _parse_scalar(rest.strip())
            body = "\n".join(lines[end + 1:])
            if body.startswith("\n"):
                body = body[1:]
    return fm, body


def _parse_scalar(rest):
    if rest.startswith("[") and rest.endswith("]"):
        return _split_list(rest[1:-1])
    low = rest.lower()
    if low == "true":
        return True
    if low == "false":
        return False
    if re.fullmatch(r"-?\d+", rest):
        return int(rest)
    return _unquote(rest)


def _split_list(inner):
    """Split a frontmatter list body on commas, ignoring commas inside quotes —
    so `"a,b", "c"` yields ['a,b', 'c'], not corrupted fragments."""
    items = []
    buf = []
    quote = None
    for ch in inner:
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            buf.append(ch)
        elif ch == ",":
            items.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
    tail = "".join(buf).strip()
    if tail:
        items.append(tail)
    return [_unquote(x) for x in items if x]


def _unquote(s):
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        return s[1:-1]
    return s


def render_note(fm, body):
    lines = ["---"]
    for key in KEY_ORDER:
        if key not in fm:
            continue
        v = fm[key]
        if key == "tags":
            lines.append("tags: [" + ", ".join(('"%s"' % t if "," in t else t) for t in v) + "]")
        elif key == "paths":
            lines.append("paths: [" + ", ".join('"%s"' % p for p in v) + "]")
        elif key in ("strength",):
            lines.append("%s: %d" % (key, v))
        elif isinstance(v, bool):
            lines.append("%s: %s" % (key, "true" if v else "false"))
        elif key in ("source",):
            lines.append('%s: "%s"' % (key, v))
        else:
            lines.append("%s: %s" % (key, v))
    lines.append("---")
    text = "\n".join(lines) + "\n"
    if body and not body.startswith("\n"):
        text += "\n"
    text += body
    if not text.endswith("\n"):
        text += "\n"
    return text


# ---------------------------------------------------------------------- storage
def load_notes(identities, role):
    """slug -> {fm, body} for every note in the role's brain."""
    d = notes_dir(identities, role)
    notes = {}
    if not os.path.isdir(d):
        return notes
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".md"):
            continue
        slug = fn[:-3]
        fm, body = parse_note(open(os.path.join(d, fn), encoding="utf-8").read())
        notes[slug] = {"fm": fm, "body": body}
    return notes


def links_path(identities, role):
    return os.path.join(brain_dir(identities, role), "links.json")


def load_links(identities, role):
    p = links_path(identities, role)
    if os.path.isfile(p):
        return json.load(open(p, encoding="utf-8"))
    return {}


def save_links(identities, role, links):
    p = links_path(identities, role)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump(links, open(p, "w", encoding="utf-8"), indent=2, sort_keys=True)


def log_event(identities, role, obj):
    p = os.path.join(brain_dir(identities, role), ".activation.jsonl")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "a", encoding="utf-8") as f:
        f.write(json.dumps(obj) + "\n")


# ------------------------------------------------------------------------- mint
def cmd_mint(identities, args):
    body = sys.stdin.read().rstrip("\n") + "\n"
    d = notes_dir(identities, args.role)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, args.slug + ".md")

    strength = DEFAULT_STRENGTH
    created = today()
    if os.path.isfile(path):
        old_fm, _ = parse_note(open(path, encoding="utf-8").read())
        strength = int(old_fm.get("strength", DEFAULT_STRENGTH)) + 1
        created = old_fm.get("created", created)

    fm = {
        "tags": _split(args.tags),
        "paths": _split(args.paths),
        "strength": strength,
        "source": args.source or "",
        "graduated": False,
        "created": created,
    }
    if args.learned_from:
        fm["learned-from"] = args.learned_from
    if args.source_note:
        fm["source-note"] = args.source_note

    open(path, "w", encoding="utf-8").write(render_note(fm, body))

    # auto-add links.json entries for [[wikilinks]] in the body (never reset existing)
    links = load_links(identities, args.role)
    added = 0
    for target in WIKILINK.findall(body):
        key = "%s->%s" % (args.slug, target.strip())
        if key not in links:
            links[key] = {"weight": DEFAULT_WEIGHT, "fires": 0, "last": None}
            added += 1
    save_links(identities, args.role, links)

    print("minted %s/%s (strength %d, %d new link(s))" % (args.role, args.slug, strength, added))


def _split(csv):
    if not csv:
        return []
    return [x.strip() for x in csv.split(",") if x.strip()]


# ----------------------------------------------------------------------- recall
def cmd_recall(identities, args):
    role = args.role
    notes = load_notes(identities, role)
    links = load_links(identities, role)
    paths = _split(args.paths)
    keywords = set(k.lower() for k in _split(args.keywords))

    activation = {}   # slug -> float
    events = []       # collected, written after link bumps

    # (1) seed
    for slug in sorted(notes):
        fm = notes[slug]["fm"]
        note_globs = fm.get("paths", []) or []
        tags = set(t.lower() for t in (fm.get("tags", []) or []))
        hit = any(glob_match(p, g) for p in paths for g in note_globs) or bool(tags & keywords)
        if hit:
            act = 1.0 * (1 + int(fm.get("strength", DEFAULT_STRENGTH)) / 10)
            if act > activation.get(slug, 0):
                activation[slug] = act
            events.append({"event": "seed", "note": slug, "activation": round(act, 4)})

    # (2) spread along outgoing links, up to MAX_HOPS, keeping the max per note
    frontier = [(s, activation[s]) for s in sorted(activation)]
    traversed = set()
    for _hop in range(MAX_HOPS):
        nxt = []
        for src, src_act in frontier:
            for key in sorted(links):
                if not key.startswith(src + "->"):
                    continue
                target = key.split("->", 1)[1]
                weight = float(links[key].get("weight", DEFAULT_WEIGHT))
                nact = src_act * HOP_DECAY * weight
                if key not in traversed:
                    traversed.add(key)
                    links[key]["fires"] = int(links[key].get("fires", 0)) + 1
                    links[key]["last"] = today()
                    events.append({"event": "hop", "note": target, "activation": round(nact, 4), "link": key})
                if nact > activation.get(target, 0):
                    activation[target] = nact
                    nxt.append((target, nact))
        frontier = nxt

    if traversed:
        save_links(identities, role, links)

    # (3) rank + emit within the token budget; graduated notes are not injected
    budget_chars = args.budget * CHARS_PER_TOKEN
    ranked = sorted(activation, key=lambda s: (-activation[s], s))
    out = []
    used = 0
    for slug in ranked:
        if slug not in notes:
            continue
        if notes[slug]["fm"].get("graduated"):
            continue
        act = activation[slug]
        sep = 1 if out else 0  # the "\n" that will join this block to the previous one
        block = _render_block(slug, notes[slug], act, budget_chars - used - sep)
        if block is None:
            break
        out.append(block)
        used += len(block) + sep
        events.append({"event": "inject", "note": slug, "activation": round(act, 4)})

    for ev in events:
        ev["ts"] = now_iso()
        ev["role"] = role
        log_event(identities, role, ev)

    text = "\n".join(out)
    print(text if text else "(no lessons recalled)")


def _render_block(slug, note, act, remaining):
    """Choose a tier by activation, downgrade until it fits; None if even a
    title won't fit. Blocks carry NO trailing newline — the caller joins with
    "\\n" and budgets that separator, so total output stays within the budget."""
    fm = note["fm"]
    strength = int(fm.get("strength", DEFAULT_STRENGTH))
    full = "### %s  [strength %d]\n%s" % (slug, strength, note["body"].strip())
    oneliner = "### %s\ntags: [%s] · paths: [%s]" % (
        slug, ", ".join(fm.get("tags", []) or []), ", ".join(fm.get("paths", []) or []))
    title = "- %s" % slug

    if act >= 1.0 and len(full) <= remaining:
        return full
    if act >= 0.25 and len(oneliner) <= remaining:
        return oneliner
    if len(title) <= remaining:
        return title
    return None


# -------------------------------------------------------------------- graduate
def cmd_graduate(identities, args):
    path = os.path.join(notes_dir(identities, args.role), args.slug + ".md")
    if not os.path.isfile(path):
        sys.exit("no such note: %s/%s" % (args.role, args.slug))
    fm, body = parse_note(open(path, encoding="utf-8").read())
    fm["graduated"] = True
    open(path, "w", encoding="utf-8").write(render_note(fm, body))
    print("graduated %s/%s" % (args.role, args.slug))


# -------------------------------------------------------------------- directory
def cmd_directory(identities, _args):
    roles = []
    if os.path.isdir(identities):
        for r in sorted(os.listdir(identities)):
            if os.path.isdir(notes_dir(identities, r)):
                roles.append(r)
    lines = ["# Identity brains — directory", "",
             "Titles + tags only (never bodies). Regenerated by `brain.py directory`.", ""]
    for role in roles:
        notes = load_notes(identities, role)
        lines.append("## %s" % role)
        if not notes:
            lines.append("_(no notes)_")
        for slug in sorted(notes):
            fm = notes[slug]["fm"]
            tags = ", ".join(fm.get("tags", []) or [])
            flag = " _(graduated)_" if fm.get("graduated") else ""
            lines.append("- **%s**%s — [%s]" % (slug, flag, tags))
        lines.append("")
    os.makedirs(identities, exist_ok=True)
    out = os.path.join(identities, "DIRECTORY.md")
    open(out, "w", encoding="utf-8").write("\n".join(lines).rstrip() + "\n")
    print("wrote %s (%d role(s))" % (out, len(roles)))


# ---------------------------------------------------------------------- consult
def cmd_consult(identities, args):
    consumer, owner, slug = args.consumer, args.owner, args.slug
    path = os.path.join(notes_dir(identities, owner), slug + ".md")
    if not os.path.isfile(path):
        sys.exit("no such note: %s/%s" % (owner, slug))
    _fm, body = parse_note(open(path, encoding="utf-8").read())

    # recurrence count lives in the CONSUMER's brain
    cpath = os.path.join(brain_dir(identities, consumer), "consults.json")
    consults = {}
    if os.path.isfile(cpath):
        consults = json.load(open(cpath, encoding="utf-8"))
    ckey = "%s:%s" % (owner, slug)
    count = int(consults.get(ckey, 0)) + 1
    consults[ckey] = count
    os.makedirs(os.path.dirname(cpath), exist_ok=True)
    json.dump(consults, open(cpath, "w", encoding="utf-8"), indent=2, sort_keys=True)

    # log to the OWNER's activation log
    log_event(identities, owner, {"ts": now_iso(), "role": owner, "event": "consult",
                                  "note": slug, "consumer": consumer})

    print(body.rstrip())
    if count >= 2:
        print("\nRECURRENCE: consider minting into %s's brain (learned-from: %s)" % (consumer, owner))


# ------------------------------------------------------------------------ prune
def cmd_retro_mark(identities, _args):
    p = os.path.join(identities, "retros.log")
    os.makedirs(identities, exist_ok=True)
    with open(p, "a", encoding="utf-8") as f:
        f.write(today() + "\n")
    n = sum(1 for _ in open(p, encoding="utf-8"))
    print("retro #%d marked" % n)


def cmd_prune(identities, args):
    role = args.role
    notes = load_notes(identities, role)
    links = load_links(identities, role)

    retros = []
    rp = os.path.join(identities, "retros.log")
    if os.path.isfile(rp):
        retros = [ln.strip() for ln in open(rp, encoding="utf-8") if ln.strip()]
    cutoff = retros[-3] if len(retros) >= 3 else None  # created before this = old enough

    candidates = []
    for key in sorted(links):
        src, _, target = key.partition("->")
        meta = links[key]
        target_note = notes.get(target)
        # (a) target graduated or missing
        if target_note is None:
            candidates.append((key, "target missing"))
            continue
        if target_note["fm"].get("graduated"):
            candidates.append((key, "target graduated"))
            continue
        # (b) never fired and the source note is older than the last 3 retros
        if int(meta.get("fires", 0)) == 0 and cutoff is not None:
            src_note = notes.get(src)
            created = src_note["fm"].get("created", "") if src_note else ""
            if created and created < cutoff:
                candidates.append((key, "never fired, aged out"))

    if not candidates:
        print("no prune candidates")
        return
    for key, why in candidates:
        print("%s  (%s)" % (key, why))
    if args.apply:
        for key, _why in candidates:
            links.pop(key, None)
        save_links(identities, role, links)
        print("removed %d link(s)" % len(candidates))


# -------------------------------------------------------------------------- cli
def main(argv):
    p = argparse.ArgumentParser(prog="brain.py", description="Per-identity zettel memory engine.")
    p.add_argument("root", help="consumer repo root")
    p.add_argument("--dir", default=".claude/identities", help="identities dir (relative to root)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("recall")
    sp.add_argument("role")
    sp.add_argument("--paths", default="")
    sp.add_argument("--keywords", default="")
    sp.add_argument("--budget", type=int, default=600)
    sp.set_defaults(fn=cmd_recall)

    sp = sub.add_parser("mint")
    sp.add_argument("role")
    sp.add_argument("slug")
    sp.add_argument("--tags", default="")
    sp.add_argument("--paths", default="")
    sp.add_argument("--source", default="")
    sp.add_argument("--learned-from", dest="learned_from", default="")
    sp.add_argument("--source-note", dest="source_note", default="")
    sp.set_defaults(fn=cmd_mint)

    sp = sub.add_parser("directory")
    sp.set_defaults(fn=cmd_directory)

    sp = sub.add_parser("consult")
    sp.add_argument("consumer")
    sp.add_argument("owner")
    sp.add_argument("slug")
    sp.set_defaults(fn=cmd_consult)

    sp = sub.add_parser("prune")
    sp.add_argument("role")
    sp.add_argument("--apply", action="store_true")
    sp.set_defaults(fn=cmd_prune)

    sp = sub.add_parser("retro-mark")
    sp.set_defaults(fn=cmd_retro_mark)

    sp = sub.add_parser("graduate")
    sp.add_argument("role")
    sp.add_argument("slug")
    sp.set_defaults(fn=cmd_graduate)

    args = p.parse_args(argv)
    identities = os.path.join(args.root, args.dir)
    args.fn(identities, args)


if __name__ == "__main__":
    main(sys.argv[1:])
