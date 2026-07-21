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
    brain.py <root> recall <role> --query "types:Action -subtypes:Attack classes:Warrior" [--limit N]
    brain.py <root> mint <role> <slug> --tags a,b --paths "x/**" --source "..." [--learned-from R --source-note S] [--entities "card:x,card:y"]
    brain.py <root> directory
    brain.py <root> entity-index
    brain.py <root> consult <consumer-role> <owner-role> <slug>
    brain.py <root> index <role> [--rebuild]
    brain.py <root> prune <role> [--apply]
    brain.py <root> retro-mark
    brain.py <root> graduate <role> <slug>
    brain.py <root> graduate-check [role] [--threshold N]
    brain.py <root> verify-feed <role>
    brain.py <root> outcome <role> <slug> useful|dead_end|corrected [--task <ref>] [--note "<text>"]

`<root>` is the consumer repo root; identities live under `--dir` (default
`.claude/identities`).
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config as C  # noqa: E402

WIKILINK = re.compile(r"\[\[([^\]]+)\]\]")
DEFAULT_STRENGTH = 1
DEFAULT_WEIGHT = 0.5
HOP_DECAY = 0.5
MAX_HOPS = 2
CHARS_PER_TOKEN = 4
DEFAULT_GRADUATION_THRESHOLD = 3  # methodology.graduationThreshold override in project.yaml
# frontmatter keys in deterministic write order
KEY_ORDER = ["tags", "paths", "entities", "strength", "source", "learned-from", "source-note", "graduated", "created"]


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
        elif key == "entities":
            lines.append("entities: [" + ", ".join(('"%s"' % e if "," in e else e) for e in v) + "]")
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


# ------------------------------------------------ unified brain-event feed (E2)
BRAIN_EVENT_SCHEMA_VERSION = 1
BRAIN_EVENTS_FILENAME = "brain-events.jsonl"


def _feed_repo(root):
    """Identify the repo an event belongs to: project.name, else root basename."""
    cfg = C.load_config(root=root, warn=False) or {}
    name = (cfg.get("project") or {}).get("name")
    if name:
        return name
    return os.path.basename(os.path.abspath(root)) or root


def emit_event(root, obj):
    """Append ONE JSON line to <root>/.claude/brain-events.jsonl (§8.1, §8.2).

    The line is written in a SINGLE os.write() to an O_APPEND file descriptor;
    on POSIX, concurrent appends of a whole line under PIPE_BUF (~4KB) are
    atomic, so parallel emitters never interleave or lose writes. Callers pass a
    payload carrying at least `role` and `type` (one of the §8.2 enum) plus
    slug/link-key/count fields — NEVER full note bodies. The v1 baseline fields
    `v`/`ts`/`repo` are filled here.

    The feed is NEVER load-bearing (§8.1.1): any failure prints a warning and
    returns False without raising, so the caller's real work completes normally.
    Returns True on a successful append.
    """
    try:
        event = {"v": BRAIN_EVENT_SCHEMA_VERSION, "ts": now_iso(), "repo": _feed_repo(root)}
        event.update(obj)
        line = json.dumps(event, sort_keys=True) + "\n"
        p = os.path.join(root, ".claude", BRAIN_EVENTS_FILENAME)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        fd = os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)
        return True
    except Exception as e:
        sys.stderr.write("warning: brain-event feed append failed: %s\n" % e)
        return False


# ----------------------------------------------------------------------- outcome
OUTCOME_SCHEMA_VERSION = 1
OUTCOMES_FILENAME = "outcomes.jsonl"
OUTCOME_CHOICES = ("useful", "dead_end", "corrected")
_BARE_TASK_REF_RE = re.compile(r"^#(\d+)$")


def outcomes_path(identities, role):
    return os.path.join(brain_dir(identities, role), OUTCOMES_FILENAME)


def _qualify_task_ref(root, ref):
    """Normalize a bare `#N` task ref to `<project.name>#N` (project.name from
    THIS repo's .claude/project.yaml, mirroring feedback.py's ref
    qualification). A ref already qualified by any project (has a prefix
    before the `#`) passes through unchanged; no-op if project.name is
    unset -- don't guess."""
    ref = ref.strip()
    if not ref:
        return None
    m = _BARE_TASK_REF_RE.match(ref)
    if not m:
        return ref
    cfg = C.load_config(root=root, warn=False) or {}
    name = C.dig(cfg, "project.name")
    if not name:
        return ref
    return "%s#%s" % (name, m.group(1))


def cmd_outcome(identities, args):
    """Record one outcome (useful/dead_end/corrected) for a recalled note,
    appended to <brain>/outcomes.jsonl (SPEC-GRAPHIFY §7 R7.1/R7.3). Atomic
    single os.write to an O_APPEND fd, same pattern as emit_event -- concurrent
    invocations never interleave or lose a line. Validates role and slug
    BEFORE writing anything; `corrected` additionally requires --note."""
    role = args.role
    bdir = brain_dir(identities, role)
    if not os.path.isdir(bdir):
        sys.exit("unknown role: %s (no %s)" % (role, bdir))

    note_path = os.path.join(notes_dir(identities, role), args.slug + ".md")
    if not os.path.isfile(note_path):
        sys.exit("no such note: %s/%s" % (role, args.slug))

    note_text = (args.note or "").strip() or None
    if args.outcome == "corrected" and not note_text:
        sys.exit(
            "usage: brain.sh outcome %s %s corrected --note \"<what was wrong>\" "
            "-- corrected requires --note so the retro has material to re-mint from"
            % (role, args.slug)
        )

    task_ref = _qualify_task_ref(args.root, args.task) if args.task else None

    obj = {
        "schemaVersion": OUTCOME_SCHEMA_VERSION,
        "ts": now_iso(),
        "slug": args.slug,
        "outcome": args.outcome,
        "task": task_ref,
        "note": note_text,
    }
    line = json.dumps(obj, sort_keys=True) + "\n"
    p = outcomes_path(identities, role)
    fd = os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)

    print("recorded outcome: %s/%s %s" % (role, args.slug, args.outcome))

    # RecallOutcome event (SPEC-GRAPHIFY §7 R7.2) -- only after outcomes.jsonl
    # has its line. Skip cleanly (no emit_event call, no directory created) when
    # the repo has no .claude/ root at all; otherwise reuse emit_event as-is,
    # which is itself never load-bearing (warns and returns on failure).
    if os.path.isdir(os.path.join(args.root, ".claude")):
        emit_event(args.root, {
            "role": role,
            "type": "RecallOutcome",
            "slug": args.slug,
            "outcome": args.outcome,
            "task": task_ref,
        })


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
    entities = _split(args.entities)
    if entities:
        fm["entities"] = entities
    if args.learned_from:
        fm["learned-from"] = args.learned_from
    if args.source_note:
        fm["source-note"] = args.source_note

    open(path, "w", encoding="utf-8").write(render_note(fm, body))

    # auto-add links.json entries for [[wikilinks]] in the body (never reset existing)
    links = load_links(identities, args.role)
    formed = []
    for target in WIKILINK.findall(body):
        key = "%s->%s" % (args.slug, target.strip())
        if key not in links:
            links[key] = {"weight": DEFAULT_WEIGHT, "fires": 0, "last": None}
            formed.append(key)
    save_links(identities, args.role, links)

    emit_event(args.root, {"role": args.role, "type": "NoteMinted", "slug": args.slug, "strength": strength})
    for key in formed:
        emit_event(args.root, {"role": args.role, "type": "LinkFormed", "key": key})

    print("minted %s/%s (strength %d, %d new link(s))" % (args.role, args.slug, strength, len(formed)))


def _split(csv):
    if not csv:
        return []
    return [x.strip() for x in csv.split(",") if x.strip()]


# ------------------------------------------------------------- query (precise)
def _fm_field_values(fm, field):
    """Lowercased value set for a frontmatter field — treats list and scalar
    fields uniformly so a query term works the same whether the note stores
    e.g. `subtypes: [Attack, Axe]` or `subtypes: Axe`. `tags` is always the
    note's tag list regardless of any other meaning `field` might have."""
    if field == "tags":
        return set(t.lower() for t in (fm.get("tags", []) or []))
    v = fm.get(field)
    if v is None:
        return set()
    if isinstance(v, list):
        return set(str(x).lower() for x in v if str(x).strip())
    return {str(v).lower()} if str(v).strip() else set()


def _query_term_matches(fm, term):
    """One query term against one note's frontmatter.
    `word`            — `word` is one of the note's tags
    `field:value`     — `value` is present in frontmatter field `field`
    `field:v1,v2`     — OR within the field: v1 present OR v2 present
    A leading `-` on either form negates the whole term."""
    neg = term.startswith("-")
    if neg:
        term = term[1:]
    if not term:
        return True
    if ":" in term:
        field, _, valpart = term.partition(":")
        field = field.strip().lower()
        wants = set(v.strip().lower() for v in valpart.split(",") if v.strip())
        ok = bool(_fm_field_values(fm, field) & wants) if wants else True
    else:
        ok = term.lower() in _fm_field_values(fm, "tags")
    return (not ok) if neg else ok


def cmd_query(identities, args):
    """Precise boolean filter over frontmatter fields — the counterpart to
    `recall`'s fuzzy OR-activation. Terms are ANDed; `-term` negates a term;
    `field:v1,v2` ORs within one field. No link spreading, no token budget,
    no activation logging — this is exact search, not associative recall.
    Example: `--query "types:Action -subtypes:Attack classes:Warrior
    rarity:Majestic interacts-with:Axe"` — every AND'd term must hold; the
    comma-separated values inside one term are OR'd."""
    role = args.role
    notes = load_notes(identities, role)
    terms = (args.query or "").split()
    matches = []
    for slug in sorted(notes):
        fm = notes[slug]["fm"]
        if fm.get("graduated"):
            continue
        if all(_query_term_matches(fm, t) for t in terms):
            matches.append(slug)
    limit = args.limit if args.limit else len(matches)
    shown = matches[:limit]
    for slug in shown:
        fm = notes[slug]["fm"]
        label = fm.get("full-name") or fm.get("name") or slug
        print("%s — %s" % (slug, label))
    print("(%d match(es)%s)" % (len(matches), "" if len(matches) <= len(shown) else ", showing %d" % len(shown)))


# ----------------------------------------------------------------------- recall
def cmd_recall(identities, args):
    if getattr(args, "query", None):
        return cmd_query(identities, args)
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

    # (1b) hybrid seeding (MEM-032, SPEC-MEMORY §9.3): union in the top-K
    # embedding neighbors of the query text, when the role's index.sqlite3
    # sidecar exists. Absence of the sidecar falls through unchanged -- the
    # exact same code that ran before this feature existed -- so the
    # golden-identical-when-absent guarantee holds by construction.
    db_path = index_db_path(identities, role)
    if os.path.exists(db_path):
        query_text = " ".join(_split(args.keywords))
        if query_text:
            vectors = _embed_texts([query_text])
            if vectors is not None:
                for slug, _sim in _top_k_neighbors(db_path, vectors[0], args.k):
                    if slug not in notes:
                        continue
                    fm = notes[slug]["fm"]
                    act = 1.0 * (1 + int(fm.get("strength", DEFAULT_STRENGTH)) / 10)
                    if act > activation.get(slug, 0):
                        activation[slug] = act
                        events.append({"event": "seed", "note": slug,
                                       "activation": round(act, 4), "source": "embedding"})

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

    seeds = sum(1 for e in events if e["event"] == "seed")
    injected = sum(1 for e in events if e["event"] == "inject")
    emit_event(args.root, {"role": role, "type": "RecallPerformed",
                           "seeds": seeds, "injected": injected, "links_fired": len(traversed)})
    for key in sorted(traversed):
        emit_event(args.root, {"role": role, "type": "LinkFired", "key": key})

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
    emit_event(args.root, {"role": args.role, "type": "NoteGraduated", "slug": args.slug})
    print("graduated %s/%s" % (args.role, args.slug))


# --------------------------------------------------------------- graduate-check
# PROPOSAL heuristic only — graduate-check never mutates a note (no strength/graduated
# writes); it surfaces candidates for a human to graduate at retro time (SPEC §8.3).
# Checked in tag-keyword order: hard-rule/contract-flavored tags win over
# mechanically-checkable ones; anything else (orchestration/process/communication
# lessons, or no matching tag) defaults to a ROLE.md rule — the broadest bucket for
# a behavioral lesson.
DESTINATION_RULES = [
    ("specs[].invariants entry", {"contract", "enforcement", "invariant", "security", "safety", "hard-rule"}),
    ("test-or-lint", {"testing", "test", "lint", "shellcheck", "portability", "ci"}),
]
DEFAULT_DESTINATION = "ROLE.md rule"


def propose_destination(tags):
    tagset = set(t.lower() for t in (tags or []))
    for destination, keywords in DESTINATION_RULES:
        if tagset & keywords:
            return destination
    return DEFAULT_DESTINATION


def graduation_threshold(args):
    if getattr(args, "threshold", None) is not None:
        return args.threshold
    cfg = C.load_config(root=args.root, warn=False) or {}
    return int((cfg.get("methodology") or {}).get("graduationThreshold", DEFAULT_GRADUATION_THRESHOLD))


def _graduate_check_role(identities, role, threshold):
    notes = load_notes(identities, role)
    rows = []
    for slug in sorted(notes):
        fm = notes[slug]["fm"]
        if fm.get("graduated"):
            continue
        strength = int(fm.get("strength", DEFAULT_STRENGTH))
        if strength < threshold:
            continue
        tags = fm.get("tags", []) or []
        rows.append((slug, strength, tags, propose_destination(tags)))
    return rows


def cmd_graduate_check(identities, args):
    threshold = graduation_threshold(args)
    if args.role:
        roles = [args.role]
    else:
        roles = []
        if os.path.isdir(identities):
            roles = sorted(r for r in os.listdir(identities) if os.path.isdir(notes_dir(identities, r)))

    for role in roles:
        rows = _graduate_check_role(identities, role, threshold)
        if not rows:
            print("no notes at/above threshold %d for %s" % (threshold, role))
            continue
        print("%s (threshold %d):" % (role, threshold))
        print("%-30s %-8s %-30s %s" % ("slug", "strength", "tags", "proposed destination"))
        for slug, strength, tags, dest in rows:
            print("%-30s %-8d %-30s %s" % (slug, strength, ", ".join(tags), dest))


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


# ----------------------------------------------------------------- entity-index
def cmd_entity_index(identities, args):
    """Regenerate `<identities>/entity-index.json` -- a derived, whole-repo
    correlation index built purely from note frontmatter (SPEC: cross-identity
    correlation layer, #163). Never read by recall/query (role privacy is
    untouched); a query-time join for whole-brain consumers (ask-brain,
    neural-view) only. Symlinked notes (kw-* mirrors) attribute to their
    PHYSICAL home role only, so a mirrored note never double-counts."""
    roles = []
    if os.path.isdir(identities):
        for r in sorted(os.listdir(identities)):
            if os.path.isdir(notes_dir(identities, r)):
                roles.append(r)

    entities = {}  # key -> [(role, slug), ...]
    for role in roles:
        d = notes_dir(identities, role)
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".md"):
                continue
            path = os.path.join(d, fn)
            if os.path.islink(path):
                continue
            slug = fn[:-3]
            fm, _ = parse_note(open(path, encoding="utf-8").read())
            for key in fm.get("entities", []) or []:
                key = str(key).strip()
                if key:
                    entities.setdefault(key, []).append((role, slug))

    cfg = C.load_config(root=args.root, warn=False) or {}
    entity_kinds = (cfg.get("methodology") or {}).get("entityKinds") or {}

    out_entities = {}
    for key in sorted(entities):
        # set(): a note declaring the same entity key twice in its own
        # --entities list (e.g. "card:x,card:x") must contribute exactly one
        # (role, slug) entry, not two -- a duplicate here would both inflate
        # the notes[] count and make a genuinely-unambiguous home role look
        # ambiguous to the anchor check below (#163 review round 1).
        notes = sorted(set(entities[key]))
        kind = key.split(":", 1)[0]
        home_role = entity_kinds.get(kind) if isinstance(entity_kinds, dict) else None
        anchor = None
        if home_role:
            home_notes = [slug for (role, slug) in notes if role == home_role]
            if len(home_notes) == 1:
                anchor = "%s/%s" % (home_role, home_notes[0])
        out_entities[key] = {"anchor": anchor, "notes": [list(n) for n in notes]}

    os.makedirs(identities, exist_ok=True)
    out = os.path.join(identities, "entity-index.json")
    open(out, "w", encoding="utf-8").write(_render_entity_index(out_entities))
    print("wrote %s (%d entit%s)" % (out, len(out_entities), "y" if len(out_entities) == 1 else "ies"))


def _render_entity_index(out_entities):
    """Hand-formatted (not a plain json.dump indent=2): each [role, slug] pair
    stays on ONE line so the committed file reads like the design doc's
    example and diffs cleanly note-by-note. Deterministic: keys and note
    lists are both sorted by the caller before this runs."""
    keys = sorted(out_entities)
    if not keys:
        return '{\n  "generated-by": "brain.py entity-index",\n  "entities": {}\n}\n'
    lines = ["{", '  "generated-by": "brain.py entity-index",', '  "entities": {']
    for i, key in enumerate(keys):
        info = out_entities[key]
        end = "," if i < len(keys) - 1 else ""
        lines.append("    %s: {" % json.dumps(key))
        lines.append('      "anchor": %s,' % json.dumps(info["anchor"]))
        notes = info["notes"]
        if not notes:
            lines.append('      "notes": []')
        else:
            lines.append('      "notes": [')
            for j, n in enumerate(notes):
                nend = "," if j < len(notes) - 1 else ""
                lines.append("        %s%s" % (json.dumps(n), nend))
            lines.append("      ]")
        lines.append("    }%s" % end)
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


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

    emit_event(args.root, {"role": owner, "type": "ConsultPerformed",
                           "slug": slug, "consumer": consumer, "count": count})

    print(body.rstrip())
    if count >= 2:
        print("\nRECURRENCE: consider minting into %s's brain (learned-from: %s)" % (consumer, owner))


# ------------------------------------------------------------------- verify-feed
FOLD_EVENT_TYPES = {"LinkFormed", "LinkFired", "LinkPruned"}


def cmd_verify_feed(identities, args):
    """Fold LinkFormed/LinkFired/LinkPruned events for `role` and diff the
    result against the real `links.json` (§8.4). Only keys the fold has an
    opinion about are compared -- pre-feed-history links.json entries are
    expected drift, not a divergence. Only `fires` is diffed: no event type
    currently carries `weight`, so there is nothing to compare it against --
    if a future event payload adds `weight`, this function needs a matching
    comparison added explicitly, it will not start comparing it on its own."""
    role = args.role
    p = os.path.join(args.root, ".claude", BRAIN_EVENTS_FILENAME)
    folded = {}
    if os.path.isfile(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("role") != role or ev.get("type") not in FOLD_EVENT_TYPES:
                continue
            key = ev.get("key")
            if not key:
                continue
            etype = ev["type"]
            if etype == "LinkFormed":
                folded.setdefault(key, {"fires": 0})
            elif etype == "LinkFired":
                folded.setdefault(key, {"fires": 0})
                folded[key]["fires"] += 1
            elif etype == "LinkPruned":
                folded.pop(key, None)

    links = load_links(identities, role)
    divergences = []
    for key in sorted(folded):
        if key not in links:
            divergences.append("DIVERGENCE: key '%s' present in event fold, missing from links.json" % key)
            continue
        fold_fires = folded[key]["fires"]
        real_fires = int(links[key].get("fires", 0))
        if fold_fires != real_fires:
            divergences.append(
                "DIVERGENCE: key '%s' fires drift -- fold=%d links.json=%d" % (key, fold_fires, real_fires))

    if divergences:
        for line in divergences:
            print(line)
        sys.exit(1)
    print("verify-feed: %s clean (%d key(s) checked)" % (role, len(folded)))


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
        for key, why in candidates:
            emit_event(args.root, {"role": role, "type": "LinkPruned", "key": key, "reason": why})
        print("removed %d link(s)" % len(candidates))


# ------------------------------------------------------------------------ index
def index_db_path(identities, role):
    return os.path.join(brain_dir(identities, role), "index.sqlite3")


def _body_hash(body):
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def _embed_texts(texts):
    """Run the embeddings capability over `texts` (one per input list entry).

    Returns a list of JSON-decoded float vectors (order-preserved), or None
    if the capability is unavailable (missing, non-zero exit, or malformed
    output) -- callers must treat None as "leave rows untouched", per
    SPEC-MEMORY §9.1.1's absence-degrades-gracefully contract.

    Note bodies may themselves span multiple lines, but the wire contract is
    one-text-per-stdin-line; internal newlines are flattened to spaces so
    each text occupies exactly one line.
    """
    override = os.environ.get("BRAIN_EMBED_CMD")
    if override:
        cmd = override
        shell = True
    else:
        cap_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "capability.sh")
        cmd = ["bash", cap_path, "embed", "embeddings"]
        shell = False
    stdin_data = "\n".join(" ".join(t.split("\n")) for t in texts) + "\n"
    try:
        proc = subprocess.run(cmd, input=stdin_data, capture_output=True, text=True, shell=shell)
    except (OSError, FileNotFoundError):
        return None
    if proc.returncode != 0:
        return None
    lines = [ln for ln in proc.stdout.split("\n") if ln != ""]
    if len(lines) != len(texts):
        return None
    try:
        return [json.loads(ln) for ln in lines]
    except (ValueError, TypeError):
        return None


def _cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = sum(x * x for x in a) ** 0.5
    nb = sum(x * x for x in b) ** 0.5
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def _top_k_neighbors(db_path, query_vector, k):
    """Read-only scan of `notes` for the top-`k` (slug, similarity) pairs by
    cosine similarity, sorted desc then slug asc for deterministic tie-breaks."""
    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute("SELECT slug, vector FROM notes").fetchall()
    finally:
        conn.close()
    scored = [(slug, _cosine(query_vector, json.loads(vector))) for slug, vector in rows]
    scored.sort(key=lambda sv: (-sv[1], sv[0]))
    return scored[:k]


def cmd_index(identities, args):
    role = args.role
    notes = load_notes(identities, role)
    db_path = index_db_path(identities, role)
    os.makedirs(brain_dir(identities, role), exist_ok=True)

    conn = sqlite3.connect(db_path)
    try:
        if args.rebuild:
            conn.execute("DROP TABLE IF EXISTS notes")
        conn.execute(
            "CREATE TABLE IF NOT EXISTS notes ("
            "slug TEXT PRIMARY KEY, content_hash TEXT NOT NULL, "
            "vector TEXT NOT NULL, updated_at TEXT NOT NULL)"
        )

        existing_hashes = dict(conn.execute("SELECT slug, content_hash FROM notes"))

        changed = []
        for slug, note in notes.items():
            h = _body_hash(note["body"])
            if existing_hashes.get(slug) == h:
                continue
            changed.append((slug, h))

        if changed:
            vectors = _embed_texts([notes[slug]["body"] for slug, _h in changed])
            if vectors is None:
                sys.stderr.write(
                    "index: embeddings capability unavailable, skipping %d changed note(s)\n"
                    % len(changed)
                )
            else:
                updated_at = now_iso()
                conn.executemany(
                    "INSERT OR REPLACE INTO notes (slug, content_hash, vector, updated_at) "
                    "VALUES (?, ?, ?, ?)",
                    [(slug, h, json.dumps(vec), updated_at)
                     for (slug, h), vec in zip(changed, vectors)],
                )

        stale = [slug for slug in existing_hashes if slug not in notes]
        if stale:
            conn.executemany("DELETE FROM notes WHERE slug = ?", [(s,) for s in stale])

        conn.commit()
    finally:
        conn.close()


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
    sp.add_argument("--k", type=int, default=8,
                     help="top-K embedding neighbors to union into the seed set "
                          "when the role's index.sqlite3 sidecar exists (MEM-032)")
    sp.add_argument("--query", default="",
                     help="precise boolean filter (AND terms, '-' negates, "
                          "'field:v1,v2' ORs within a field) instead of fuzzy "
                          "activation recall — see cmd_query docstring")
    sp.add_argument("--limit", type=int, default=0,
                     help="cap --query results (0 = unlimited)")
    sp.set_defaults(fn=cmd_recall)

    sp = sub.add_parser("mint")
    sp.add_argument("role")
    sp.add_argument("slug")
    sp.add_argument("--tags", default="")
    sp.add_argument("--paths", default="")
    sp.add_argument("--entities", default="",
                     help="comma-separated kind:slug real-world entity keys this note is about "
                          "(e.g. card:gone-in-a-flash) -- consumed by entity-index, never by recall")
    sp.add_argument("--source", default="")
    sp.add_argument("--learned-from", dest="learned_from", default="")
    sp.add_argument("--source-note", dest="source_note", default="")
    sp.set_defaults(fn=cmd_mint)

    sp = sub.add_parser("directory")
    sp.set_defaults(fn=cmd_directory)

    sp = sub.add_parser("entity-index")
    sp.set_defaults(fn=cmd_entity_index)

    sp = sub.add_parser("consult")
    sp.add_argument("consumer")
    sp.add_argument("owner")
    sp.add_argument("slug")
    sp.set_defaults(fn=cmd_consult)

    sp = sub.add_parser("index")
    sp.add_argument("role")
    sp.add_argument("--rebuild", action="store_true")
    sp.set_defaults(fn=cmd_index)

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

    sp = sub.add_parser("graduate-check")
    sp.add_argument("role", nargs="?", default=None)
    sp.add_argument("--threshold", type=int, default=None)
    sp.set_defaults(fn=cmd_graduate_check)

    sp = sub.add_parser("verify-feed")
    sp.add_argument("role")
    sp.set_defaults(fn=cmd_verify_feed)

    sp = sub.add_parser("outcome")
    sp.add_argument("role")
    sp.add_argument("slug")
    sp.add_argument("outcome", choices=OUTCOME_CHOICES)
    sp.add_argument("--task", default="")
    sp.add_argument("--note", default="")
    sp.set_defaults(fn=cmd_outcome)

    args = p.parse_args(argv)
    identities = os.path.join(args.root, args.dir)
    args.fn(identities, args)


if __name__ == "__main__":
    main(sys.argv[1:])
