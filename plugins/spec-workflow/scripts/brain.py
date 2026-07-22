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
    brain.py <root> prune <role> [--apply] [--force]
    brain.py <root> retro-mark
    brain.py <root> graduate <role> <slug>
    brain.py <root> graduate-check [role] [--threshold N]
    brain.py <root> verify-feed <role>
    brain.py <root> outcome <role> <slug> useful|dead_end|corrected [--task <ref>] [--note "<text>"]
    brain.py <root> explain <role> <slug>
    brain.py <root> path <role> <slug-a> <slug-b>

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
# frontmatter keys in deterministic write order. `seed-path`/`seed-commit`
# (GL-050) are an additive-only extension for kb-seed.py's provenance
# frontmatter (source path + commit SHA at seed time, distinguishing a
# seeded note from a retro-minted one whose `source` holds free text like
# "PR#N ..."); a note that never sets them renders identically to before.
KEY_ORDER = ["tags", "paths", "entities", "strength", "source", "confidence", "learned-from", "source-note",
             "seed-path", "seed-commit", "graduated", "created", "last-touched"]
CONFIDENCE_VALUES = ("direct", "inferred")
DEFAULT_CONFIDENCE = "inferred"


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


# ---------------------------------------------------------- outcome weighting
# SPEC-GRAPHIFY §7 R7.4/R7.5/R7.7. Reusable across GL-003 (recall ranking),
# GL-004 (status tallies), and GL-033 (report) -- ALL outcome-window reading
# goes through outcome_window_tallies() so the retro-clock semantics and the
# malformed-file tolerance live in exactly one place.
DEFAULT_OUTCOME_WINDOW = 3           # methodology.outcomeWindow
DEFAULT_OUTCOME_MULTIPLIER_STEP = 0.1  # methodology.outcomeMultiplierStep
_MIN_OUTCOME_MULTIPLIER = 0.1


def _load_retros(identities):
    """The retros.log clock as an ordered list of date strings (oldest
    first), one per `retro-mark`. [] when the file is missing or empty --
    the single place both the outcome window (_retro_window_cutoff) and
    recency decay (GL-010) read this file, so "no retro clock yet" means
    the exact same thing to both features."""
    rp = os.path.join(identities, "retros.log")
    if not os.path.isfile(rp):
        return []
    return [ln.strip() for ln in open(rp, encoding="utf-8") if ln.strip()]


def _retro_window_cutoff(identities, n):
    """The retros.log timestamp marking the start of the "last N retros"
    window (retros.log clock, NOT wall time) -- generalizes cmd_prune's
    3rd-from-last-retro cutoff to arbitrary N. None means fewer than N
    retros have EVER been marked, so there is no boundary yet and the whole
    history counts as within-window (nothing to exclude)."""
    retros = _load_retros(identities)
    if len(retros) < n:
        return None
    return retros[-n]


def _read_outcomes(identities, role):
    """Parse <brain>/outcomes.jsonl into a list of dicts, tolerating a
    malformed file (R7.7): a line that isn't valid JSON, isn't an object, has
    an unknown `outcome` value, is missing `slug`/`ts`/`outcome`, or has the
    WRONG TYPE for `slug`/`ts` (both must be str -- a non-str `ts` can't be
    compared against the retros.log cutoff string and a non-hashable `slug`
    can't key a tally dict; either would raise TypeError deep inside
    outcome_window_tallies if let through) is dropped and flips `malformed`
    True -- never raises. Task-ref grammar is NOT validated here: malformed
    refs exist by design at the write layer (cmd_outcome only qualifies `#N`
    shorthand, never rejects free text) and must still count toward tallies
    (GL-001 reviewer note)."""
    p = outcomes_path(identities, role)
    records = []
    malformed = False
    if not os.path.isfile(p):
        return records, malformed
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            malformed = True
            continue
        if not isinstance(obj, dict) or obj.get("outcome") not in OUTCOME_CHOICES:
            malformed = True
            continue
        if "slug" not in obj or "ts" not in obj:
            malformed = True
            continue
        if not isinstance(obj["slug"], str) or not isinstance(obj["ts"], str):
            malformed = True
            continue
        records.append(obj)
    return records, malformed


def outcome_window_tallies(identities, role, n=None, full_history=False):
    """Per-slug outcome tallies within the last N retros. Returns
    (tallies, malformed): tallies maps slug -> {"useful": k, "dead_end": k,
    "corrected": k} counted ONLY for outcomes at/after the window cutoff;
    malformed is True iff outcomes.jsonl had at least one bad line, in which
    case callers MUST disable weighting entirely for the run (R7.7) --
    treat as if no outcomes existed, warn once, never crash. Reused verbatim
    by GL-004 (status tallies, prune's dead_end rule) and GL-033 (report).

    full_history=True skips the retro-window cutoff entirely and tallies the
    ENTIRE outcomes.jsonl -- GL-004's prune rule is deliberately full-history
    (a note that was net-useful long ago but has since gone stale isn't what
    this signal is about; #248 explicitly calls for full history, not the
    window used by recall's ranking multiplier). `n` is ignored when
    full_history is True."""
    records, malformed = _read_outcomes(identities, role)
    cutoff = None if full_history else _retro_window_cutoff(identities, n if n is not None else DEFAULT_OUTCOME_WINDOW)
    tallies = {}
    for obj in records:
        ts = obj.get("ts") or ""
        if cutoff is not None and ts < cutoff:
            continue
        slug = obj["slug"]
        outcome = obj["outcome"]
        t = tallies.setdefault(slug, {"useful": 0, "dead_end": 0, "corrected": 0})
        t[outcome] += 1
    return tallies, malformed


def _outcome_multiplier(tally, step):
    """Seed-activation multiplier from one note's outcome tally (R7.4). Zero
    outcomes (empty tally) or a net-zero tally (equal useful vs. dead_end +
    corrected, including 0/0) returns EXACTLY 1.0 -- multiplying activation
    by the float 1.0 is exact, so this is the byte-identical-to-today
    invariant (G6) by construction, not by a tolerance check."""
    if not tally:
        return 1.0
    net = tally.get("useful", 0) - tally.get("dead_end", 0) - tally.get("corrected", 0)
    if net == 0:
        return 1.0
    return max(_MIN_OUTCOME_MULTIPLIER, 1.0 + step * net)


def _is_contested(tally):
    """R7.5: contested = at least one `useful` AND at least one
    `corrected`/`dead_end` within the window -- visible disagreement, never
    silently averaged into a neutral multiplier."""
    if not tally:
        return False
    return tally.get("useful", 0) >= 1 and (tally.get("dead_end", 0) + tally.get("corrected", 0)) >= 1


def _outcome_config(args):
    cfg = C.load_config(root=args.root, warn=False) or {}
    window = C.dig(cfg, "methodology.outcomeWindow")
    step = C.dig(cfg, "methodology.outcomeMultiplierStep")
    return (
        int(window) if window is not None else DEFAULT_OUTCOME_WINDOW,
        float(step) if step is not None else DEFAULT_OUTCOME_MULTIPLIER_STEP,
    )


# ---------------------------------------------------- outcome tallies + prune rule
# SPEC-GRAPHIFY §7 R7.6 (GL-004): status tallies + a full-history dead_end prune
# signal. K is the minimum full-history dead_end count (with zero useful) at
# which a note becomes a prune candidate under this rule.
DEFAULT_OUTCOME_DEADEND_PRUNE_THRESHOLD = 2  # methodology.outcomeDeadEndPruneThreshold


def _outcome_deadend_prune_threshold(args):
    cfg = C.load_config(root=args.root, warn=False) or {}
    k = C.dig(cfg, "methodology.outcomeDeadEndPruneThreshold")
    return int(k) if k is not None else DEFAULT_OUTCOME_DEADEND_PRUNE_THRESHOLD


def _format_tally(tally):
    """Compact `3✓ 1✗ 1⚠` (useful/dead_end/corrected) rendering of one note's
    full-history tally. Zero-count fields are omitted; an empty/None tally
    (the zero-outcome case) renders as "" so callers append nothing -- the
    byte-identical-to-today invariant for notes with no recorded outcomes."""
    if not tally:
        return ""
    parts = []
    if tally.get("useful"):
        parts.append("%d✓" % tally["useful"])
    if tally.get("dead_end"):
        parts.append("%d✗" % tally["dead_end"])
    if tally.get("corrected"):
        parts.append("%d⚠" % tally["corrected"])
    return " ".join(parts)


def _note_line(slug, fm, tally=None):
    """The single per-note bullet line shared by `directory` and `status` --
    directory always calls this with tally=None so its rendering is
    untouched by GL-004 (byte-identical by construction, not by a
    parallel-but-separate format string that could drift)."""
    tags = ", ".join(fm.get("tags", []) or [])
    flag = " _(graduated)_" if fm.get("graduated") else ""
    line = "- **%s**%s — [%s]" % (slug, flag, tags)
    tally_str = _format_tally(tally)
    if tally_str:
        line += " — %s" % tally_str
    return line


def _load_outcome_tallies_or_warn(identities, role, label):
    """outcome_window_tallies(full_history=True) with the shared R7.7
    malformed-file handling: warn once to stderr, return {} so the caller's
    rendering/candidacy logic is identical to a brain with no outcomes.jsonl
    at all. `label` names the command in the warning (status/prune)."""
    tallies, malformed = outcome_window_tallies(identities, role, full_history=True)
    if malformed:
        sys.stderr.write(
            "warning: %s is malformed — outcome tallies disabled for this %s\n"
            % (outcomes_path(identities, role), label)
        )
        return {}
    return tallies


# ------------------------------------------------------------ recency decay
# GL-010: a note untouched for K "grace" retros (methodology.
# recencyDecayGraceRetros) decays multiplicatively by `factor`
# (methodology.recencyDecayFactor) per retro elapsed BEYOND K -- measured on
# the retros.log clock (via _load_retros, shared with the outcome window),
# never wall time. Applied at SEED computation in cmd_recall, composing
# multiplicatively with strength and GL-003's outcome multiplier.
DEFAULT_RECENCY_DECAY_GRACE_RETROS = 3   # methodology.recencyDecayGraceRetros (K)
DEFAULT_RECENCY_DECAY_FACTOR = 0.85      # methodology.recencyDecayFactor


def _recency_decay_config(args):
    cfg = C.load_config(root=args.root, warn=False) or {}
    k = C.dig(cfg, "methodology.recencyDecayGraceRetros")
    factor = C.dig(cfg, "methodology.recencyDecayFactor")
    return (
        int(k) if k is not None else DEFAULT_RECENCY_DECAY_GRACE_RETROS,
        float(factor) if factor is not None else DEFAULT_RECENCY_DECAY_FACTOR,
    )


def _useful_touch_dates(identities, role):
    """slug -> latest `useful`-outcome date (YYYY-MM-DD), FULL history -- a
    useful outcome resets the recency-decay touch clock (GL-010) regardless
    of the outcomeWindow the outcome multiplier uses, since decay measures
    recency directly off the retro clock rather than a fixed window. Reuses
    _read_outcomes' malformed-line tolerance (bad lines dropped, never
    raises); callers combine the returned `malformed` flag with the one
    already computed for the outcome multiplier -- both read the same file,
    so they always agree."""
    records, malformed = _read_outcomes(identities, role)
    dates = {}
    for obj in records:
        if obj.get("outcome") != "useful":
            continue
        slug = obj["slug"]
        d = obj["ts"][:10]
        if d > dates.get(slug, ""):
            dates[slug] = d
    return dates, malformed


def _note_touch_date(slug, fm, links, useful_dates):
    """Latest date `slug` was touched: frontmatter last-touched (falling
    back to created, for notes minted before GL-010 that never got a
    last-touched stamp), any link's `last` where slug is source OR target,
    or the latest recorded `useful` outcome date. None only if the note
    somehow has neither created nor last-touched (mint always writes one)."""
    candidates = []
    touched = fm.get("last-touched") or fm.get("created")
    if touched:
        candidates.append(str(touched))
    for key, meta in links.items():
        src, _, target = key.partition("->")
        if slug != src and slug != target:
            continue
        last = meta.get("last")
        if last:
            candidates.append(str(last))
    useful = useful_dates.get(slug)
    if useful:
        candidates.append(useful)
    return max(candidates) if candidates else None


def _recency_decay_multiplier(retros, k, factor, touch_date):
    """Multiplicative decay: factor ** max(0, elapsed - k), where `elapsed`
    is the count of retros strictly AFTER `touch_date`. No retros.log (or a
    note with no resolvable touch date) means zero decay -- 1.0, the
    byte-identical default (AC5). At exactly K elapsed retros, overshoot is
    0 so the multiplier is still exactly 1.0 (no decay yet, per AC2)."""
    if not retros or touch_date is None:
        return 1.0
    elapsed = sum(1 for r in retros if r > touch_date)
    overshoot = elapsed - k
    if overshoot <= 0:
        return 1.0
    return factor ** overshoot


# ---------------------------------------------------------------- staleness
# GL-011 / SPEC-GRAPHIFY §8 R8.2, R8.5: a note renders `⟳ stale — re-verify`
# when any of its `paths` globs match a file changed by a git commit AFTER
# the note's `created` (or latest re-mint's `last-touched`, GL-010's field --
# reused as-is rather than adding a second timestamp) date. One batched git
# subprocess per recall regardless of note count (R8.2's "on-demand at
# recall time"); the underlying commit list is cached per (role, HEAD) so a
# second recall at the same HEAD costs zero subprocesses. Any failure -- no
# git binary, not a repo, a shallow clone missing the needed range -- must
# degrade to "no flags, exit 0, no warning" (R8.5): every helper below
# returns None/{} on failure instead of raising.
def _staleness_since_date(fm):
    return fm.get("last-touched") or fm.get("created")


def _staleness_cache_path(identities, role):
    return os.path.join(brain_dir(identities, role), ".staleness-cache.json")


def _read_staleness_cache(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_staleness_cache(path, head, since, commits):
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"head": head, "since": since, "commits": commits}, f)
    except OSError:
        pass


def _resolve_git_dirs(root):
    """Resolve (git_dir, common_dir) for `root` with NO subprocess.
    `git_dir` is where HEAD lives; `common_dir` is where shared refs/
    packed-refs live -- the same as `git_dir` for a plain repo (`.git` is a
    directory), but DIFFERENT for a linked worktree, where `.git` is a FILE
    containing `gitdir: <path>` (absolute or relative to `root`) pointing at
    a per-worktree dir under the main repo's `.git/worktrees/<name>/`; that
    dir's own `commondir` file (absolute or relative to it) names the shared
    dir holding `refs/`/`packed-refs`. None if `root` isn't a git repo, or
    `.git` is a form this doesn't recognize -- callers must treat None as
    "omit staleness" (R8.5), not raise."""
    git_path = os.path.join(root, ".git")
    if os.path.isdir(git_path):
        return git_path, git_path
    try:
        with open(git_path, encoding="utf-8") as f:
            first_line = f.readline()
    except OSError:
        return None
    if not first_line.startswith("gitdir:"):
        return None
    git_dir = first_line[len("gitdir:"):].strip()
    if not os.path.isabs(git_dir):
        git_dir = os.path.normpath(os.path.join(root, git_dir))
    common_dir = git_dir
    try:
        with open(os.path.join(git_dir, "commondir"), encoding="utf-8") as f:
            common = f.readline().strip()
        common_dir = common if os.path.isabs(common) else os.path.normpath(os.path.join(git_dir, common))
    except OSError:
        pass
    return git_dir, common_dir


def _git_head_sha(root):
    """Resolve the current commit sha with NO subprocess -- a plain read of
    HEAD (and, for a symbolic ref, the ref file it points at -- checked in
    both the per-worktree and shared common dir, since a worktree's own
    branch ref is shared, falling back to the shared `packed-refs`).
    Filesystem-only so a cache-hit recall (same HEAD) truly costs zero
    subprocesses (AC4). None if `root` isn't a git repo, or for any layout
    `_resolve_git_dirs` doesn't understand -- callers must treat None as
    "omit staleness" (R8.5), not raise."""
    resolved = _resolve_git_dirs(root)
    if resolved is None:
        return None
    git_dir, common_dir = resolved
    try:
        head = open(os.path.join(git_dir, "HEAD"), encoding="utf-8").read().strip()
    except OSError:
        return None
    if not head.startswith("ref:"):
        return head or None
    ref = head[len("ref:"):].strip()
    for base in (git_dir, common_dir):
        try:
            return open(os.path.join(base, ref), encoding="utf-8").read().strip()
        except OSError:
            continue
    try:
        with open(os.path.join(common_dir, "packed-refs"), encoding="utf-8") as f:
            for line in f:
                if line.strip().endswith(" " + ref):
                    return line.split()[0]
    except OSError:
        pass
    return None


def _git_changed_files_since(root, since_date):
    """ONE subprocess: every commit at/after `since_date` in `root`'s history,
    as (date, [changed-path, ...]) tuples oldest-first (`--date=short` so
    per-note comparisons are plain string compares). None on any failure --
    no git binary, `root` not a repo, or a non-zero exit for any other
    reason -- which callers must turn into "omit the flag" (R8.5)."""
    cmd = ["git", "log", "--since=" + since_date, "--date=short",
           "--pretty=format:%x00%ad", "--name-only"]
    try:
        proc = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    commits = []
    for chunk in proc.stdout.split("\x00"):
        chunk = chunk.strip("\n")
        if not chunk:
            continue
        lines = chunk.split("\n")
        commits.append([lines[0].strip(), [f for f in lines[1:] if f.strip()]])
    return commits


def _stale_slugs(root, identities, role, notes):
    """slug -> True/False staleness for every note in `notes` that carries a
    non-empty `paths`. Computes over the WHOLE corpus (not just the notes a
    given recall will render) so the (role, HEAD) cache stays valid across
    recalls that query different path/keyword subsets."""
    candidates = {slug: notes[slug]["fm"] for slug in notes if notes[slug]["fm"].get("paths")}
    if not candidates:
        return {}
    since_dates = [d for d in (_staleness_since_date(fm) for fm in candidates.values()) if d]
    if not since_dates:
        return {}
    since = min(since_dates)

    head = _git_head_sha(root)
    if head is None:
        return {}

    cache_path = _staleness_cache_path(identities, role)
    cache = _read_staleness_cache(cache_path)
    commits = None
    if cache and cache.get("head") == head and cache.get("since", "") <= since:
        commits = cache.get("commits")
    if commits is None:
        commits = _git_changed_files_since(root, since)
        if commits is None:
            return {}
        _write_staleness_cache(cache_path, head, since, commits)

    result = {}
    for slug, fm in candidates.items():
        note_date = _staleness_since_date(fm)
        globs = fm.get("paths", []) or []
        stale = False
        if note_date:
            for date, files in commits:
                if date <= note_date:
                    continue
                if any(glob_match(f, g) for f in files for g in globs):
                    stale = True
                    break
        result[slug] = stale
    return result


# ------------------------------------------------------------------------- mint
def cmd_mint(identities, args):
    body = sys.stdin.read().rstrip("\n") + "\n"
    d = notes_dir(identities, args.role)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, args.slug + ".md")

    strength = DEFAULT_STRENGTH
    created = today()
    old_confidence = None
    if os.path.isfile(path):
        old_fm, _ = parse_note(open(path, encoding="utf-8").read())
        strength = int(old_fm.get("strength", DEFAULT_STRENGTH)) + 1
        created = old_fm.get("created", created)
        old_confidence = old_fm.get("confidence", DEFAULT_CONFIDENCE)

    # GL-012: confidence is additive and two-valued only (argparse `choices`
    # rejects anything else before we ever get here, exit 2, nothing
    # written). Omitting --confidence on a re-mint PRESERVES the existing
    # note's confidence (never a silent direct -> inferred downgrade); only
    # an explicit `--confidence inferred` on a currently-direct note performs
    # that downgrade, and it prints a notice when it does. A first-time mint
    # (or any note that resolves to inferred) writes no key at all -- missing
    # key IS the inferred default (AC1/AC2).
    if args.confidence is not None:
        new_confidence = args.confidence
        if old_confidence == "direct" and new_confidence == "inferred":
            sys.stderr.write("notice: downgrading %s/%s confidence direct -> inferred\n" % (args.role, args.slug))
    else:
        new_confidence = old_confidence if old_confidence is not None else DEFAULT_CONFIDENCE

    fm = {
        "tags": _split(args.tags),
        "paths": _split(args.paths),
        "strength": strength,
        "source": args.source or "",
        "graduated": False,
        "created": created,
        # GL-010: every mint -- first or re-mint (the strength-bump path) --
        # touches the note, resetting its recency-decay clock.
        "last-touched": today(),
    }
    if new_confidence == "direct":
        fm["confidence"] = "direct"
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


# --------------------------------------------------------------- link spread
def _spread_activation(links, seed_activation, max_hops=MAX_HOPS, mutate=False, on_cross=None):
    """Hop-spread activation over outgoing links from `seed_activation`, up
    to `max_hops`, keeping the max activation seen per note -- the same
    spreading-activation rule `cmd_recall` has always used, factored out so
    GL-020's `explain` (2-hop spread seeded on a single note) reuses it
    verbatim instead of duplicating the traversal. Returns
    (activation, traversed): `activation` is `seed_activation` merged with
    every note reached by the spread; `traversed` is the list of link keys
    crossed, in first-crossed order (deterministic: `sorted()` at each hop).

    `mutate=True` bumps `fires`/`last` on `links` in place the first time
    each key is crossed -- `cmd_recall`'s link-strengthening side effect.
    `mutate=False` (GL-020 `explain`) leaves `links` completely untouched:
    read-only interrogation must never strengthen the graph it inspects.
    `on_cross(key, target, activation)` -- when given -- fires once per
    first-crossing, in the same order, so a caller needing a log
    (`cmd_recall`'s `hop` events) can build it without re-deriving the
    traversal."""
    activation = dict(seed_activation)
    frontier = [(s, activation[s]) for s in sorted(activation)]
    traversed = []
    traversed_set = set()
    for _hop in range(max_hops):
        nxt = []
        for src, src_act in frontier:
            for key in sorted(links):
                if not key.startswith(src + "->"):
                    continue
                target = key.split("->", 1)[1]
                weight = float(links[key].get("weight", DEFAULT_WEIGHT))
                nact = src_act * HOP_DECAY * weight
                if key not in traversed_set:
                    traversed_set.add(key)
                    traversed.append(key)
                    if mutate:
                        links[key]["fires"] = int(links[key].get("fires", 0)) + 1
                        links[key]["last"] = today()
                    if on_cross:
                        on_cross(key, target, nact)
                if nact > activation.get(target, 0):
                    activation[target] = nact
                    nxt.append((target, nact))
        frontier = nxt
    return activation, traversed


# ----------------------------------------------------------------------- recall
def cmd_recall(identities, args):
    if getattr(args, "query", None):
        return cmd_query(identities, args)
    role = args.role
    notes = load_notes(identities, role)
    links = load_links(identities, role)
    paths = _split(args.paths)
    keywords = set(k.lower() for k in _split(args.keywords))

    # outcome weighting (SPEC-GRAPHIFY §7 R7.4/R7.5/R7.7): parsed ONCE per
    # invocation (§14 latency budget). A malformed outcomes.jsonl warns once
    # and disables weighting entirely for this run -- empty tallies means
    # _outcome_multiplier() returns 1.0 everywhere and _is_contested() is
    # always False, i.e. exactly today's behavior (never crash, exit 0).
    window, mult_step = _outcome_config(args)
    tallies, outcomes_malformed = outcome_window_tallies(identities, role, window)
    if outcomes_malformed:
        sys.stderr.write(
            "warning: %s is malformed — outcome weighting disabled for this recall\n"
            % outcomes_path(identities, role)
        )
        tallies = {}

    # recency decay (GL-010): parsed ONCE per invocation, same latency
    # budget as the outcome weighting above. A malformed outcomes.jsonl was
    # already warned about once (above) -- reuse that verdict instead of
    # parsing again and warning a second time for the exact same file.
    retros = _load_retros(identities)
    decay_k, decay_factor = _recency_decay_config(args)
    useful_dates = {} if outcomes_malformed else _useful_touch_dates(identities, role)[0]

    # staleness (GL-011): parsed ONCE per invocation over the whole corpus,
    # same latency budget as the two blocks above. Failure of any kind (no
    # git, non-repo, cache miss that also fails) degrades to {} -- every
    # note renders exactly as it did before this feature existed (R8.5).
    stale_map = _stale_slugs(args.root, identities, role, notes)

    def _decay(slug, fm):
        touch_date = _note_touch_date(slug, fm, links, useful_dates)
        return _recency_decay_multiplier(retros, decay_k, decay_factor, touch_date)

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
            act *= _outcome_multiplier(tallies.get(slug, {}), mult_step)
            act *= _decay(slug, fm)
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
                    act *= _outcome_multiplier(tallies.get(slug, {}), mult_step)
                    act *= _decay(slug, fm)
                    if act > activation.get(slug, 0):
                        activation[slug] = act
                        events.append({"event": "seed", "note": slug,
                                       "activation": round(act, 4), "source": "embedding"})

    # (2) spread along outgoing links, up to MAX_HOPS, keeping the max per note
    def _on_cross(key, target, nact):
        events.append({"event": "hop", "note": target, "activation": round(nact, 4), "link": key})

    activation, traversed_list = _spread_activation(links, activation, mutate=True, on_cross=_on_cross)
    traversed = set(traversed_list)

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
        tally = tallies.get(slug, {})
        contested = _is_contested(tally)
        stale = stale_map.get(slug, False)
        confidence = notes[slug]["fm"].get("confidence", DEFAULT_CONFIDENCE)
        block = _render_block(slug, notes[slug], act, budget_chars - used - sep,
                               contested=contested, stale=stale,
                               confidence=confidence, useful_count=tally.get("useful", 0))
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


def _format_header_line(slug, strength, confidence, useful_count, contested, stale):
    """Compose the self-describing full-tier recall header (GL-013 /
    SPEC-GRAPHIFY §8 R8.4): an optional `[confidence · tally]` bracket ahead
    of the slug, the existing `[strength N]` tag, then the existing
    contested/stale flags -- in this FIXED order, always. Each part is
    independently optional:
      - the confidence sub-part appears only when `confidence == "direct"`
        (key-absence/"inferred" is the silent default -- GL-012 -- so it
        never earns bracket space);
      - the tally sub-part appears only when `useful_count > 0`;
      - the whole bracket is omitted (not `"[]"`) when both sub-parts are
        empty.
    A call with confidence="inferred", useful_count=0, contested=False,
    stale=False reduces to EXACTLY the pre-GL-013 "slug  [strength N]"
    string -- byte-identical-when-quiet (G6). Extracted as one reusable
    helper (rather than inlined in `_render_block`) so GL-020's explain
    card can compose the same header without duplicating the glyph order."""
    bracket_parts = []
    if confidence == "direct":
        bracket_parts.append("direct")
    if useful_count:
        bracket_parts.append("%d× useful" % useful_count)
    prefix = "[%s] " % " · ".join(bracket_parts) if bracket_parts else ""

    marker = "  ⚠ contested" if contested else ""
    marker += "  ⟳ stale — re-verify" if stale else ""

    return "%s%s  [strength %d]%s" % (prefix, slug, strength, marker)


def _render_block(slug, note, act, remaining, contested=False, stale=False,
                   confidence=DEFAULT_CONFIDENCE, useful_count=0):
    """Choose a tier by activation, downgrade until it fits; None if even a
    title won't fit. Blocks carry NO trailing newline — the caller joins with
    "\\n" and budgets that separator, so total output stays within the budget.
    `contested` (R7.5) renders a "⚠ contested" marker in the full and
    one-liner tiers only; when False the marker is an empty string, so
    non-contested output is byte-identical to pre-GL-003 rendering (G6).
    `stale` (GL-011 / R8.2) renders a "⟳ stale — re-verify" marker in the
    same two tiers, same byte-identical-when-False guarantee.
    `confidence`/`useful_count` (GL-013 / R8.4) feed the FULL tier's header
    only, via `_format_header_line` -- the one-liner tier keeps flags-only
    (tags/paths already crowd that line) and the title tier is untouched, per
    the issue's tiering rule."""
    fm = note["fm"]
    strength = int(fm.get("strength", DEFAULT_STRENGTH))
    marker = "  ⚠ contested" if contested else ""
    marker += "  ⟳ stale — re-verify" if stale else ""
    header_line = _format_header_line(slug, strength, confidence, useful_count, contested, stale)
    full = "### %s\n%s" % (header_line, note["body"].strip())
    oneliner = "### %s%s\ntags: [%s] · paths: [%s]" % (
        slug, marker, ", ".join(fm.get("tags", []) or []), ", ".join(fm.get("paths", []) or []))
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
            lines.append(_note_line(slug, fm))
        lines.append("")
    os.makedirs(identities, exist_ok=True)
    out = os.path.join(identities, "DIRECTORY.md")
    open(out, "w", encoding="utf-8").write("\n".join(lines).rstrip() + "\n")
    print("wrote %s (%d role(s))" % (out, len(roles)))


def cmd_status(identities, args):
    """`status <role>` (SPEC-GRAPHIFY §7 R7.6, GL-004): per-note bullet lines
    for one role, same renderer as `directory`, each gaining a compact
    outcome tally when the note has recorded outcomes. A note with zero
    outcomes, or a role whose outcomes.jsonl is absent/malformed, renders its
    bullet line identically to `directory` -- see _note_line/_format_tally."""
    role = args.role
    notes = load_notes(identities, role)
    tallies = _load_outcome_tallies_or_warn(identities, role, "status")
    lines = ["# %s — status" % role, ""]
    if not notes:
        lines.append("_(no notes)_")
    for slug in sorted(notes):
        fm = notes[slug]["fm"]
        lines.append(_note_line(slug, fm, tallies.get(slug)))
    print("\n".join(lines))


# ------------------------------------------------------------------------ explain
def _explain_link_line(direction, other, meta):
    last = meta.get("last") or "never"
    return "%s %s  weight %s  fires %d  last %s" % (
        direction, other, meta.get("weight", DEFAULT_WEIGHT), int(meta.get("fires", 0)), last)


def cmd_explain(identities, args):
    """`explain <role> <slug>` (SPEC-GRAPHIFY §9 R9.1, GL-020): a full
    interrogation card for one note -- fixed section order: title, the exact
    GL-013 header (confidence + outcome tally + contested/stale, via
    `_format_header_line` -- the same helper `cmd_recall` calls, never a
    parallel format string that could drift), the full note body (no budget
    cap -- this is a targeted single-note view, unlike recall's tiered
    budget rendering), a community-membership placeholder seam (`community:
    (pending GL-030)` -- literal, until GL-030 computes real communities),
    every inbound/outbound link (weight/fires/last, sorted by weight desc
    then the OTHER note's slug asc), and the top 5 co-activated notes from a
    2-hop spread (`_spread_activation`, shared with `cmd_recall`) seeded
    ONLY on this note at activation 1.0.

    Read-only by construction: `mutate=False` on the spread call means
    `links` is never written to, and this function never calls
    `save_links`/`log_event`/`emit_event` -- unlike `recall`, which is the
    only path that strengthens the graph it visits."""
    role = args.role
    bdir = brain_dir(identities, role)
    if not os.path.isdir(bdir):
        sys.exit("unknown role: %s (no %s)" % (role, bdir))

    notes = load_notes(identities, role)
    if args.slug not in notes:
        sys.exit("no such note: %s/%s" % (role, args.slug))

    note = notes[args.slug]
    fm = note["fm"]
    links = load_links(identities, role)

    tallies, outcomes_malformed = outcome_window_tallies(identities, role, full_history=True)
    if outcomes_malformed:
        sys.stderr.write(
            "warning: %s is malformed — outcome tallies disabled for this explain\n"
            % outcomes_path(identities, role)
        )
        tallies = {}
    tally = tallies.get(args.slug, {})
    contested = _is_contested(tally)

    stale_map = _stale_slugs(args.root, identities, role, notes)
    stale = stale_map.get(args.slug, False)

    confidence = fm.get("confidence", DEFAULT_CONFIDENCE)
    strength = int(fm.get("strength", DEFAULT_STRENGTH))
    header = _format_header_line(args.slug, strength, confidence, tally.get("useful", 0), contested, stale)

    lines = ["# %s/%s" % (role, args.slug), "", header, "", note["body"].strip(), "",
             "community: (pending GL-030)", "", "## links"]

    outbound = []
    inbound = []
    for key, meta in links.items():
        src, _, target = key.partition("->")
        if src == args.slug:
            outbound.append((target, meta))
        elif target == args.slug:
            inbound.append((src, meta))
    outbound.sort(key=lambda p: (-float(p[1].get("weight", DEFAULT_WEIGHT)), p[0]))
    inbound.sort(key=lambda p: (-float(p[1].get("weight", DEFAULT_WEIGHT)), p[0]))

    if not outbound and not inbound:
        lines.append("(none)")
    else:
        for other, meta in outbound:
            lines.append(_explain_link_line("out", other, meta))
        for other, meta in inbound:
            lines.append(_explain_link_line("in ", other, meta))

    lines.append("")
    lines.append("## co-activated")
    # GL-020: seed the shared spread with ONLY this note at activation 1.0,
    # mutate=False so link fires/last are never bumped (read-only).
    coactivation, _traversed = _spread_activation(links, {args.slug: 1.0}, mutate=False)
    coactivation.pop(args.slug, None)
    ranked = sorted(coactivation, key=lambda s: (-coactivation[s], s))[:5]
    if not ranked:
        lines.append("(none)")
    else:
        for slug in ranked:
            lines.append("%s  %.4f" % (slug, coactivation[slug]))

    print("\n".join(lines))


# --------------------------------------------------------------------- path
def cmd_path(identities, args):
    """`path <role> <slug-a> <slug-b>` (SPEC-GRAPHIFY §9 R9.2, GL-021): BFS
    shortest link path between two notes over `links.json`.

    Links are UNDIRECTED for pathfinding -- the stored `from->to` direction
    in `links.json` is a mint-order artifact, not a traversal constraint, so
    a query can walk a stored edge in either direction.

    Unweighted shortest hops; deterministic tie-break: neighbors are
    expanded in sorted-slug order at every node, so equal-length paths
    resolve identically across runs. Read-only, like `explain`: `links` is
    only ever read, never passed through `_spread_activation`'s mutating
    path -- BFS path-finding is a different traversal from spreading
    activation, so this is a small dedicated BFS rather than a contortion of
    that shared helper."""
    role = args.role
    bdir = brain_dir(identities, role)
    if not os.path.isdir(bdir):
        sys.exit("unknown role: %s (no %s)" % (role, bdir))

    notes = load_notes(identities, role)
    for slug in (args.slug_a, args.slug_b):
        if slug not in notes:
            sys.exit("no such note: %s/%s" % (role, slug))

    if args.slug_a == args.slug_b:
        print(args.slug_a)
        return

    links = load_links(identities, role)
    adjacency = {}
    for key, meta in links.items():
        src, _, target = key.partition("->")
        weight = meta.get("weight", DEFAULT_WEIGHT)
        adjacency.setdefault(src, {})[target] = weight
        adjacency.setdefault(target, {})[src] = weight

    prev = {args.slug_a: None}
    queue = [args.slug_a]
    head = 0
    while head < len(queue):
        current = queue[head]
        head += 1
        if current == args.slug_b:
            break
        for neighbor in sorted(adjacency.get(current, {})):
            if neighbor not in prev:
                prev[neighbor] = current
                queue.append(neighbor)

    if args.slug_b not in prev:
        print("no path")
        return

    chain = []
    node = args.slug_b
    while node is not None:
        chain.append(node)
        node = prev[node]
    chain.reverse()

    lines = []
    for a, b in zip(chain, chain[1:]):
        weight = adjacency[a][b]
        lines.append("%s -> %s  weight %s" % (a, b, weight))
    print("\n".join(lines))


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


# ------------------------------------------------------------------- shrink guard
DEFAULT_SHRINK_GUARD_FRACTION = 0.3  # methodology.shrinkGuardFraction override in project.yaml
SHRINK_GUARD_FLOOR = 5  # absolute floor (#249): guard only engages when removing MORE than this many items
SHRINK_GUARD_SAMPLE = 10


def _shrink_guard_fraction(args):
    cfg = C.load_config(root=args.root, warn=False) or {}
    frac = C.dig(cfg, "methodology.shrinkGuardFraction")
    return float(frac) if frac is not None else DEFAULT_SHRINK_GUARD_FRACTION


def _shrink_guard(kind, remove_keys, total_count, force, fraction):
    """Shared destructive-operation guard (SPEC-GRAPHIFY §13; lesson from
    graphify #2053/#2056/#2012): a single invocation of a brain-mutating
    command must never silently discard a disproportionate share of a
    brain's notes/links. Every destructive verb routes through this before
    writing anything. Returns True if the caller may proceed, False if the
    caller must abort having written nothing."""
    remove_count = len(remove_keys)
    if remove_count <= SHRINK_GUARD_FLOOR or total_count <= 0:
        return True
    if (remove_count / float(total_count)) <= fraction:
        return True
    pct = 100.0 * remove_count / total_count
    sample = list(remove_keys)[:SHRINK_GUARD_SAMPLE]
    if force:
        print("SHRINK GUARD OVERRIDDEN (--force): removing %d/%d %s (%.0f%%)" %
              (remove_count, total_count, kind, pct))
        for s in sample:
            print("  - %s" % s)
        return True
    print("SHRINK GUARD: refusing to remove %d/%d %s (%.0f%% > %.0f%% threshold, floor %d)" %
          (remove_count, total_count, kind, pct, 100.0 * fraction, SHRINK_GUARD_FLOOR))
    print("Would remove:")
    for s in sample:
        print("  - %s" % s)
    print("Nothing written. Re-run with --force to proceed anyway.")
    return False


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

    # outcome-rule candidates (SPEC-GRAPHIFY §7 R7.6, GL-004): a note that is
    # repeatedly dead_end and never useful, full history (not the retro
    # window recall's ranking multiplier uses -- #248 wants the whole
    # record, since a note this bad doesn't get a second chance to redeem
    # itself just because the window rolled forward). Note-level, so it's
    # reported alongside the existing link-level candidates but tracked
    # separately -- this rule is propose-only (see below), never wired into
    # --apply's removal path, so it can never trigger the shrink guard by
    # itself; --apply's existing link-removal path is unaffected.
    K = _outcome_deadend_prune_threshold(args)
    tallies = _load_outcome_tallies_or_warn(identities, role, "prune")
    note_candidates = []
    for slug in sorted(notes):
        t = tallies.get(slug)
        if not t:
            continue
        if t.get("dead_end", 0) >= K and t.get("useful", 0) == 0:
            note_candidates.append(
                (slug, "outcome rule: %d× dead_end, 0 useful (full history, threshold %d)"
                 % (t["dead_end"], K))
            )

    if not candidates and not note_candidates:
        print("no prune candidates")
        return
    for key, why in candidates:
        print("%s  (%s)" % (key, why))
    for slug, why in note_candidates:
        print("%s  (%s)" % (slug, why))
    if args.apply:
        if not candidates:
            # review round 1: link candidates is empty (only outcome-rule note
            # candidates exist, if any) -- skip the link-removal machinery
            # entirely. Running the shrink guard on an empty list, calling
            # save_links (which would CREATE links.json in a brain that never
            # had one), and printing "removed 0 link(s)" are all wrong here:
            # the outcome rule is propose-only and must never write anything.
            print("0 link candidate(s); outcome candidates are propose-only (nothing written)")
        else:
            fraction = _shrink_guard_fraction(args)
            keys = [key for key, _why in candidates]
            if not _shrink_guard("link(s)", keys, len(links), args.force, fraction):
                sys.exit(1)
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
    sp.add_argument("--confidence", choices=CONFIDENCE_VALUES, default=None,
                     help="direct (single concrete incident) or inferred (cross-item "
                          "generalization, the default when omitted)")
    sp.set_defaults(fn=cmd_mint)

    sp = sub.add_parser("directory")
    sp.set_defaults(fn=cmd_directory)

    sp = sub.add_parser("status")
    sp.add_argument("role")
    sp.set_defaults(fn=cmd_status)

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
    sp.add_argument("--force", action="store_true")
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

    sp = sub.add_parser("explain")
    sp.add_argument("role")
    sp.add_argument("slug")
    sp.set_defaults(fn=cmd_explain)

    sp = sub.add_parser("path")
    sp.add_argument("role")
    sp.add_argument("slug_a")
    sp.add_argument("slug_b")
    sp.set_defaults(fn=cmd_path)

    args = p.parse_args(argv)
    identities = os.path.join(args.root, args.dir)
    args.fn(identities, args)


if __name__ == "__main__":
    main(sys.argv[1:])
