#!/usr/bin/env python3
"""feedback.py — structured process feedback for the spec-workflow loop.

Feedback is a per-ITERATION process signal (what slowed this build-loop
iteration, which skill/protocol caused friction) — distinct from a retro
lesson (a per-PR insight minted into a role's brain). The feed is retro
INPUT: items routed `brain-note` are minted by the existing retro protocol
(`brain.py mint`), never by this script.

Config — `methodology.feedback` in `.claude/project.yaml`:
    feedback: true                    # shorthand for the defaults below
    feedback:                         # expanded form
        enabled: true
        feed: .claude/feedbacks/feed.yaml  # relative to repo root
        roles: [orchestrator]
        autoTriage: false             # routing creates board items -> explicit consent
Absent key = disabled. Unknown keys are rejected by validate-config.py.

The feed lives under `.claude/feedbacks/` (plural) — a tracked, orchestrator-
mediated archive: committed and pushed alongside code by default (opt out via
the repo's own .gitignore), and never read or written by dev/reviewer
subagents, same isolation as the identity brains. See the `feedback` skill
and plugin README for the archive statement; nothing in this module enforces
subagent access — that's a docs/process contract, not a runtime one.

Legacy-path migration guard: `.claude/feedback/` (singular) was the old,
gitignored home of the feed. WHEN the DEFAULT feed path is in effect (no
explicit `methodology.feedback.feed` override) AND the legacy path
`.claude/feedback/feed.yaml` exists AND the new default path does not, every
subcommand that touches the feed (emit/pending/route/status) refuses with a
migration message instead of silently starting a fresh, empty archive that
would orphan the old history. An explicit `feed` override bypasses the guard
entirely — the override is trusted at face value.

Feed format — `.claude/feedbacks/feed.yaml` is a sequence of `---`-separated
YAML documents, one per emitted record:

    schemaVersion: 1
    kind: loop-feedback
    ts: <quoted ISO 8601 string, an input — never datetime.now() in tested
        paths. `emit` normalizes an unquoted ts (which PyYAML re-types to a
        datetime/date object on load) back to this canonical quoted string
        form before the duplicate check and before dumping, so the feed
        never accumulates an unroutable, unquoted ts.>
    iteration:
        task: <task id>
        outcome: merged | in-review | blocked | abandoned
        reviewRounds: <int>
    source:
        role: <dev|reviewer|orchestrator|...>
        model: <full model id>
    items:
      - category: worked-well | friction | incident | recommendation
        area: board | briefing | review | merge | permissions | concurrency
              | testing | docs | brains | other
        component: <plugin path>            # optional
        severity: high | medium | low
        summary: <one line, project-agnostic>
        detail: <free text, MAY contain project specifics>   # optional
        evidence: [<project refs>]                            # optional
        generalized: <REQUIRED project-agnostic restatement — the ONLY text
                      allowed to leave the feed; '' marks the item local-only,
                      routable only as `ignore`>
        proposal: {target: ..., change: ...}                  # optional
        routing: {action: backlog|brain-note|graduate|upstream|ignore, ref: ...}
                                                                # filled at triage

Generalization contract (enforced at emit time; re-checked at triage): when
`generalized` is non-empty, neither it nor `summary` may contain the
iteration's own task id or an issue/PR reference — bare (`#<digits>`) OR
qualified (`<slug>#<digits>`, e.g. `comm-platform#71`) — restate
agnostically, or clear `generalized` to mark the item local-only. This is a
textual, not semantic, check: ordinary markdown like a `#1` heading in
`summary`/`generalized` also trips it — a safe failure mode (an over-eager
rejection, never a leak), but worth knowing if a clean-looking item bounces.

Qualified references: `items[].evidence[]` and `items[].routing.ref` are the
one place a task ref belongs (they are NOT bound by the generalization ban
above). A bare `#N` there is ambiguous once an archive spans multiple
projects, so `emit` and `route` normalize every bare `#N` in those two
fields to `<project.name>#N`, where `project.name` comes from THIS repo's
own `.claude/project.yaml` (the emitting project) — never from the record
itself. A ref already qualified by ANY project (`<slug>#N`, slug = a run of
word/hyphen characters immediately before the `#`, no intervening
whitespace) passes through verbatim — qualification never rewrites another
project's ref, and re-running it is a no-op (idempotent). `migrate-qualify`
applies the same normalization, surgically, to an existing feed file in
place.

`ts` also doubles as the record's identity for `route` — two records sharing
a `ts` make routing ambiguous, so `emit` rejects a `ts` that already exists
in the feed (the comparison is on the normalized string form, so a new
quoted ts collides with an existing legacy datetime-typed one for the same
instant). `route`'s own ts lookup normalizes each feed record's ts the same
way before comparing, so a legacy unquoted (datetime-typed) record already
sitting in an existing feed remains addressable by its CLI string without a
hand-edit.

Concurrency: the feed assumes a single writer (the orchestrator process,
serially) — there is no file locking. Concurrent `emit`/`route` calls against
the same feed can race.

Feed lifecycle: emit -> route -> archive. Once every item in a document has
been routed, `archive` moves that document out of the active feed and into
`.claude/feedbacks/archive/<YYYY-MM>.yaml` (month taken from the document's
own `ts`), keeping the active feed small while the archived record remains
on disk as queryable episodic history. Archiving never rewrites the moved
bytes through yaml.dump -- the document's raw text, exactly as it sat in the
feed, is appended to the archive file (see `cmd_archive` for why).

CLI:
    feedback.py <root> emit <record.yaml>                 # validate + append
    feedback.py <root> pending                            # unrouted items
    feedback.py <root> route <ts> <item-index> <action> <ref>
    feedback.py <root> status                             # one-line summary
    feedback.py <root> migrate-qualify                     # one-shot: qualify
                                                            # bare #N refs already
                                                            # in the feed (sw-089)
    feedback.py <root> archive                             # move fully-routed
                                                            # documents to
                                                            # .claude/feedbacks/
                                                            # archive/<YYYY-MM>.yaml
    feedback.py <root> archived [--since YYYY-MM]          # list archived
                                                            # items (same
                                                            # rendering as
                                                            # pending), filtered
                                                            # by month when
                                                            # --since is given
"""
import datetime
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brain  # noqa: E402
import config as C  # noqa: E402

CATEGORIES = {"worked-well", "friction", "incident", "recommendation"}
AREAS = {"board", "briefing", "review", "merge", "permissions", "concurrency", "testing", "docs", "brains", "other"}
SEVERITIES = {"high", "medium", "low"}
OUTCOMES = {"merged", "in-review", "blocked", "abandoned"}
ACTIONS = {"backlog", "brain-note", "graduate", "upstream", "ignore"}

DEFAULTS = {
    "enabled": False,
    "feed": ".claude/feedbacks/feed.yaml",
    "roles": ["orchestrator"],
    "autoTriage": False,
}

LEGACY_FEED = ".claude/feedback/feed.yaml"

# Matches a bare OR qualified issue/PR ref for the generalization ban's report
# (e.g. "#12" or "some-repo#12" both hit, deliberately -- see the module
# docstring's generalization contract). Matches a BARE ref only for
# qualification (see _BARE_REF_RE below): the two serve different purposes
# and must not be conflated.
_ISSUE_REF_RE = re.compile(r"[\w-]*#\d+")

# A "bare" #N: not immediately preceded by a slug character, i.e. not already
# qualified by some project. `(?<![\w-])` is the boundary — a `#` glued to a
# word/hyphen character just before it is someone's `<slug>#N` and is left
# alone. Re-running qualification is therefore a no-op: once qualified, the
# ref no longer matches.
_BARE_REF_RE = re.compile(r"(?<![\w-])#(\d+)\b")
_SEP = "---\n"


def _yaml():
    try:
        import yaml
        return yaml
    except ImportError:
        sys.stderr.write(C.YAML_MISSING + "\n")
        sys.exit(1)


def parse_feedback_cfg(cfg):
    """methodology.feedback (bool shorthand or expanded dict) -> the four-key dict.
    Also returns whether `feed` was an explicit override (vs the default),
    since the legacy-path migration guard only applies to the default path."""
    raw = C.dig(cfg, "methodology.feedback") if cfg else None
    out = dict(DEFAULTS)
    feed_overridden = False
    if raw is True:
        out["enabled"] = True
    elif isinstance(raw, dict):
        for k in ("enabled", "feed", "roles", "autoTriage"):
            if k in raw:
                out[k] = raw[k]
        feed_overridden = "feed" in raw
    return out, feed_overridden


def _legacy_guard_error(root, fcfg, feed_overridden):
    """None if OK to proceed; else the migration error message.
    Only fires for the DEFAULT feed path: an explicit override is trusted
    as-is, never second-guessed against the legacy location."""
    if feed_overridden:
        return None
    new_path = os.path.join(root, fcfg["feed"])
    legacy_path = os.path.join(root, LEGACY_FEED)
    if os.path.exists(legacy_path) and not os.path.exists(new_path):
        return (
            f"ERROR: legacy feedback feed found at {LEGACY_FEED} but the new default "
            f"path {fcfg['feed']} does not exist — refusing to start a fresh feed and "
            f"orphan the archive. migration: `mv {os.path.dirname(LEGACY_FEED)} "
            f"{os.path.dirname(fcfg['feed'])}` and drop the `{os.path.dirname(LEGACY_FEED)}/` "
            "line from .gitignore."
        )
    return None


def _feed_path(root, fcfg):
    """Resolve the feed path, refusing to leave the repo root (defense in depth —
    validate-config.py already rejects absolute/../ paths, but a config that
    bypassed validation must not make this script write outside root either)."""
    joined = os.path.join(root, fcfg["feed"])
    root_real = os.path.realpath(root)
    feed_real = os.path.realpath(joined)
    if os.path.commonpath([root_real, feed_real]) != root_real:
        return None
    return joined


def _project_specific_refs(text, task_id):
    hits = []
    if task_id and task_id in text:
        hits.append(task_id)
    hits.extend(_ISSUE_REF_RE.findall(text))
    return hits


def _project_name(root):
    cfg = C.load_config(root, warn=False)
    return C.dig(cfg, "project.name") if cfg else None


def _normalize_ts(value):
    """Canonicalize a record's `ts` to an ISO-8601 `Z` string.

    PyYAML re-types an UNQUOTED ISO timestamp in a loaded record into a
    datetime.date(time) object; if that object were dumped as-is the feed
    line would come out unquoted and no CLI string passed to `route` could
    ever equal it again (the record becomes unroutable). Convert any
    datetime/date object to "%Y-%m-%dT%H:%M:%SZ" (UTC assumed for a naive
    datetime, converted for an aware one; a bare date gets midnight UTC).
    A value that is already a string (the quoted, well-formed case) passes
    through untouched -- this is a pure identity function for strings."""
    if isinstance(value, datetime.datetime):
        if value.tzinfo is not None:
            value = value.astimezone(datetime.timezone.utc)
        return value.strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(value, datetime.date):
        return value.strftime("%Y-%m-%dT00:00:00Z")
    return value


def _qualify_text(text, project_name):
    """Normalize every bare #N in `text` to `<project_name>#N`. Refs already
    qualified by any project pass through untouched. No-op if project_name
    is falsy (config missing a name -- don't guess)."""
    if not project_name or not isinstance(text, str) or "#" not in text:
        return text
    return _BARE_REF_RE.sub(lambda m: f"{project_name}#{m.group(1)}", text)


def _qualify_record_refs(rec, project_name):
    """In place: qualify bare refs in every item's evidence[] and
    routing.ref. Never touches summary/generalized -- those are banned from
    carrying refs at all, qualified or bare (see the generalization contract)."""
    if not project_name or not isinstance(rec, dict):
        return
    items = rec.get("items")
    if not isinstance(items, list):
        return
    for item in items:
        if not isinstance(item, dict):
            continue
        evidence = item.get("evidence")
        if isinstance(evidence, list):
            item["evidence"] = [_qualify_text(e, project_name) for e in evidence]
        routing = item.get("routing")
        if isinstance(routing, dict) and isinstance(routing.get("ref"), str):
            routing["ref"] = _qualify_text(routing["ref"], project_name)


def validate_record(rec):
    """Return a list of error strings; empty = valid."""
    errs = []
    if not isinstance(rec, dict):
        return ["record must be a mapping"]
    if rec.get("schemaVersion") != 1:
        errs.append(f"schemaVersion must be 1 (got {rec.get('schemaVersion')!r})")
    if rec.get("kind") != "loop-feedback":
        errs.append(f"kind must be 'loop-feedback' (got {rec.get('kind')!r})")
    if not rec.get("ts"):
        errs.append("ts is required")

    task_id = ""
    it = rec.get("iteration")
    if not isinstance(it, dict):
        errs.append("iteration must be a mapping")
    else:
        task_id = it.get("task") or ""
        if not task_id:
            errs.append("iteration.task is required")
        if it.get("outcome") not in OUTCOMES:
            errs.append(f"iteration.outcome must be one of {sorted(OUTCOMES)} (got {it.get('outcome')!r})")
        if not isinstance(it.get("reviewRounds"), int) or isinstance(it.get("reviewRounds"), bool):
            errs.append("iteration.reviewRounds must be an integer")

    src = rec.get("source")
    if not isinstance(src, dict) or not src.get("role") or not src.get("model"):
        errs.append("source.role and source.model are required")

    items = rec.get("items")
    if not isinstance(items, list) or not items:
        errs.append("items must be a non-empty list")
        items = []
    for i, item in enumerate(items):
        w = f"items[{i}]"
        if not isinstance(item, dict):
            errs.append(f"{w} must be a mapping")
            continue
        if item.get("category") not in CATEGORIES:
            errs.append(f"{w}.category must be one of {sorted(CATEGORIES)} (got {item.get('category')!r})")
        if item.get("area") not in AREAS:
            errs.append(f"{w}.area must be one of {sorted(AREAS)} (got {item.get('area')!r})")
        if item.get("severity") not in SEVERITIES:
            errs.append(f"{w}.severity must be one of {sorted(SEVERITIES)} (got {item.get('severity')!r})")
        if not item.get("summary"):
            errs.append(f"{w}.summary is required")
        if "generalized" not in item:
            errs.append(f"{w}.generalized is required (use '' to mark the item local-only)")
        else:
            gen = item.get("generalized") or ""
            if gen:
                text = f"{item.get('summary', '')} {gen}"
                hits = _project_specific_refs(text, task_id)
                if hits:
                    errs.append(
                        f"{w}.generalized/summary contains project-specific reference(s) {hits} — "
                        "restate agnostically (drop issue/PR numbers and the task id), or clear "
                        "generalized to mark the item local-only"
                    )
        routing = item.get("routing")
        if routing is not None and (not isinstance(routing, dict) or routing.get("action") not in ACTIONS):
            errs.append(f"{w}.routing.action must be one of {sorted(ACTIONS)}")
    return errs


def _load_feed(path):
    if not os.path.exists(path):
        return []
    yaml = _yaml()
    with open(path) as fh:
        return [d for d in yaml.safe_load_all(fh) if d]


def _dump_all(docs):
    yaml = _yaml()
    return _SEP.join(yaml.safe_dump(d, sort_keys=False, default_flow_style=False, allow_unicode=True) for d in docs)


def _unrouted(rec):
    for i, item in enumerate(rec.get("items", [])):
        routing = item.get("routing")
        if not routing or not routing.get("action"):
            yield i, item


def cmd_emit(root, record_path):
    yaml = _yaml()
    try:
        with open(record_path) as fh:
            rec = yaml.safe_load(fh)
    except Exception as e:  # noqa: BLE001
        print(f"INVALID: cannot parse {record_path}: {e}")
        return 1

    if isinstance(rec, dict) and "ts" in rec:
        rec["ts"] = _normalize_ts(rec["ts"])

    cfg = C.load_config(root, warn=False)
    _qualify_record_refs(rec, C.dig(cfg, "project.name") if cfg else None)

    errs = validate_record(rec)
    if errs:
        for e in errs:
            print(f"INVALID: {e}")
        return 1

    fcfg, feed_overridden = parse_feedback_cfg(cfg)
    guard_err = _legacy_guard_error(root, fcfg, feed_overridden)
    if guard_err:
        print(guard_err)
        return 1
    feed_path = _feed_path(root, fcfg)
    if feed_path is None:
        print(f"ERROR: methodology.feedback.feed {fcfg['feed']!r} resolves outside the repo root — refusing to write")
        return 1
    existing = _load_feed(feed_path)
    if any(_normalize_ts(r.get("ts")) == rec.get("ts") for r in existing):
        print(f"INVALID: ts {rec.get('ts')!r} already exists in the feed — routing would become ambiguous; use a distinct ts")
        return 1

    os.makedirs(os.path.dirname(feed_path), exist_ok=True)
    doc_text = yaml.safe_dump(rec, sort_keys=False, default_flow_style=False, allow_unicode=True)
    exists = os.path.exists(feed_path) and os.path.getsize(feed_path) > 0
    with open(feed_path, "a") as fh:
        if exists:
            fh.write(_SEP)
        fh.write(doc_text)
    role = (rec.get("source") or {}).get("role") or "orchestrator"
    for i in range(len(rec.get("items", []))):
        brain.emit_event(root, {"role": role, "type": "FeedbackEmitted", "ts": rec.get("ts"), "idx": i})
    print(f"OK: emitted {len(rec.get('items', []))} item(s) -> {feed_path}")
    return 0


def cmd_pending(root):
    cfg = C.load_config(root, warn=False)
    fcfg, feed_overridden = parse_feedback_cfg(cfg)
    guard_err = _legacy_guard_error(root, fcfg, feed_overridden)
    if guard_err:
        print(guard_err)
        return 1
    feed_path = _feed_path(root, fcfg)
    if feed_path is None:
        print(f"ERROR: methodology.feedback.feed {fcfg['feed']!r} resolves outside the repo root")
        return 1
    for rec in _load_feed(feed_path):
        ts = rec.get("ts", "")
        for i, item in _unrouted(rec):
            print(f"{ts}\t{i}\t{item.get('category', '')}\t{item.get('severity', '')}\t{item.get('summary', '')}")
    return 0


def cmd_route(root, ts, idx_str, action, ref):
    if action not in ACTIONS:
        print(f"ERROR: unknown routing action {action!r} — must be one of {sorted(ACTIONS)}")
        return 1
    try:
        idx = int(idx_str)
    except ValueError:
        print(f"ERROR: item-index must be an integer (got {idx_str!r})")
        return 1

    cfg = C.load_config(root, warn=False)
    fcfg, feed_overridden = parse_feedback_cfg(cfg)
    guard_err = _legacy_guard_error(root, fcfg, feed_overridden)
    if guard_err:
        print(guard_err)
        return 1
    feed_path = _feed_path(root, fcfg)
    if feed_path is None:
        print(f"ERROR: methodology.feedback.feed {fcfg['feed']!r} resolves outside the repo root")
        return 1
    docs = _load_feed(feed_path)
    matches = [i for i, rec in enumerate(docs) if _normalize_ts(rec.get("ts")) == ts]
    if len(matches) > 1:
        print(f"ERROR: ambiguous ts {ts!r} — {len(matches)} records in the feed share it; "
              "fix the feed (unique ts per record) before routing")
        return 1
    if not matches:
        print(f"ERROR: no record with ts {ts!r} in {feed_path}")
        return 1

    rec = docs[matches[0]]
    items = rec.get("items", [])
    if not (0 <= idx < len(items)):
        print(f"ERROR: item index {idx} out of range for record {ts}")
        return 1
    prior = (items[idx].get("routing") or {}).get("action")
    ref = _qualify_text(ref, C.dig(cfg, "project.name") if cfg else None)
    items[idx]["routing"] = {"action": action, "ref": ref}
    with open(feed_path, "w") as fh:
        fh.write(_dump_all(docs))
    role = (rec.get("source") or {}).get("role") or "orchestrator"
    brain.emit_event(root, {"role": role, "type": "FeedbackRouted", "ts": _normalize_ts(rec.get("ts")), "idx": idx, "action": action})
    suffix = f" (was: {prior})" if prior else ""
    print(f"OK: routed {ts} item {idx} -> {action} {ref}{suffix}")
    return 0


_EVIDENCE_KEY_RE = re.compile(r"^(\s*)evidence:\s*$")
_REF_KV_RE = re.compile(r"^(\s*)ref:(\s*)(.*)$")
_LIST_ITEM_RE = re.compile(r"^(\s*)-\s?(.*)$")


def _migrate_qualify_lines(lines, project_name):
    """Surgical, line-level pass over a feed file's raw text: qualify bare
    #N refs ONLY inside evidence[] list entries and `ref:` values (routing.ref)
    -- everything else (summary/generalized/detail/comments/blank lines/
    quoting) passes through byte-for-byte. Returns (new_lines, changed)."""
    out = []
    changed = False
    in_evidence = False
    evidence_indent = None
    for raw in lines:
        line = raw[:-1] if raw.endswith("\n") else raw
        if in_evidence:
            m_item = _LIST_ITEM_RE.match(line)
            if m_item and len(m_item.group(1)) >= evidence_indent:
                new_val = _qualify_text(m_item.group(2), project_name)
                if new_val != m_item.group(2):
                    changed = True
                out.append(f"{m_item.group(1)}- {new_val}\n")
                continue
            in_evidence = False

        m_ev = _EVIDENCE_KEY_RE.match(line)
        if m_ev:
            in_evidence = True
            evidence_indent = len(m_ev.group(1))
            out.append(raw if raw.endswith("\n") else raw + "\n")
            continue

        m_ref = _REF_KV_RE.match(line)
        if m_ref:
            new_val = _qualify_text(m_ref.group(3), project_name)
            if new_val != m_ref.group(3):
                changed = True
            out.append(f"{m_ref.group(1)}ref:{m_ref.group(2)}{new_val}\n")
            continue

        out.append(raw if raw.endswith("\n") else raw + "\n")
    return out, changed


def cmd_migrate_qualify(root):
    """One-shot (idempotent) migration: qualify every bare #N already sitting
    in evidence[]/routing.ref of an existing feed, via surgical text edits
    that preserve every other byte -- never a full YAML parse+redump, which
    would reformat the whole archive (sw-089)."""
    cfg = C.load_config(root, warn=False)
    project_name = C.dig(cfg, "project.name") if cfg else None
    if not project_name:
        print("ERROR: project.name is not set in .claude/project.yaml — cannot qualify refs")
        return 1
    fcfg, feed_overridden = parse_feedback_cfg(cfg)
    guard_err = _legacy_guard_error(root, fcfg, feed_overridden)
    if guard_err:
        print(guard_err)
        return 1
    feed_path = _feed_path(root, fcfg)
    if feed_path is None:
        print(f"ERROR: methodology.feedback.feed {fcfg['feed']!r} resolves outside the repo root")
        return 1
    if not os.path.exists(feed_path):
        print(f"OK: no changes — {feed_path} does not exist")
        return 0
    with open(feed_path) as fh:
        lines = fh.readlines()
    new_lines, changed = _migrate_qualify_lines(lines, project_name)
    if not changed:
        print(f"OK: no changes — {feed_path} already qualified")
        return 0
    with open(feed_path, "w") as fh:
        fh.writelines(new_lines)
    print(f"OK: qualified bare refs in {feed_path} (project={project_name})")
    return 0


_DOC_SEP_RE = re.compile(rb"(?m)^---[ \t]*\r?\n")
_MONTH_RE = re.compile(r"^(\d{4}-\d{2})")


def _split_feed_raw(raw_bytes):
    """Split a feed file's raw bytes into (byte_offset, raw_doc_bytes) per
    `---`-separated document, discarding the separator lines themselves.
    byte_offset is where the document's own text starts in the file -- used
    to report where a corrupt document sits without ever needing to parse
    the whole file to find out."""
    docs = []
    start = 0
    for m in _DOC_SEP_RE.finditer(raw_bytes):
        docs.append((start, raw_bytes[start:m.start()]))
        start = m.end()
    docs.append((start, raw_bytes[start:]))
    return docs


def _atomic_write_bytes(path, data):
    """Write `data` to `path` via a temp file in the same directory + os.replace,
    so a reader never observes a partially-written file and a crash mid-write
    leaves the original untouched."""
    d = os.path.dirname(path) or "."
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)


def cmd_archive(root):
    """Move every feed document whose items are ALL routed (non-empty
    `routing.action`) into .claude/feedbacks/archive/<YYYY-MM>.yaml, month
    taken from the document's own `ts`. A document with zero items, or with
    at least one unrouted item, is left in the feed untouched.

    The moved bytes are the document's raw slice of the feed file exactly as
    it sat there -- never round-tripped through yaml.dump, which could
    silently reformat quoting/key order/wrapping and break the "byte-
    identical archive" contract. The feed is parsed only to decide routed/
    unrouted and to read `ts`.

    Every touched file (the feed, each archive file) is written via temp
    file + os.replace (atomic within that file). Archive files are written
    BEFORE the feed, so a write failure (e.g. an unwritable archive/ dir)
    aborts before the feed is ever touched. If ANY document in the feed
    fails to parse -- or a fully-routed document has a malformed/missing
    `ts` -- the whole operation aborts before any file is modified, and the
    byte offset of that document's start is reported.
    """
    cfg = C.load_config(root, warn=False)
    fcfg, feed_overridden = parse_feedback_cfg(cfg)
    guard_err = _legacy_guard_error(root, fcfg, feed_overridden)
    if guard_err:
        print(guard_err)
        return 1
    feed_path = _feed_path(root, fcfg)
    if feed_path is None:
        print(f"ERROR: methodology.feedback.feed {fcfg['feed']!r} resolves outside the repo root")
        return 1
    if not os.path.exists(feed_path):
        print(f"OK: no changes — {feed_path} does not exist")
        return 0
    with open(feed_path, "rb") as fh:
        raw = fh.read()
    if not raw.strip():
        print(f"OK: no changes — {feed_path} is empty")
        return 0

    yaml = _yaml()
    survivors = []       # raw bytes of documents staying in the feed, in order
    to_move = []         # (raw_bytes, month) for documents leaving the feed
    for offset, raw_doc in _split_feed_raw(raw):
        if not raw_doc.strip():
            continue
        try:
            rec = yaml.safe_load(raw_doc)
        except Exception:  # noqa: BLE001
            print(f"ERROR: corrupt feed document at byte offset {offset} in {feed_path} — aborting, no files modified")
            return 1
        if not isinstance(rec, dict):
            print(f"ERROR: corrupt feed document at byte offset {offset} in {feed_path} — aborting, no files modified")
            return 1

        items = rec.get("items")
        fully_routed = (
            isinstance(items, list) and len(items) > 0 and
            all(isinstance(it, dict) and (it.get("routing") or {}).get("action") for it in items)
        )
        if not fully_routed:
            survivors.append(raw_doc)
            continue

        ts_norm = _normalize_ts(rec.get("ts"))
        month_match = _MONTH_RE.match(ts_norm) if isinstance(ts_norm, str) else None
        if not month_match:
            print(
                f"ERROR: corrupt feed document at byte offset {offset} in {feed_path} — "
                "fully routed but ts is missing or malformed, aborting, no files modified"
            )
            return 1
        role = (rec.get("source") or {}).get("role") or "orchestrator"
        to_move.append((raw_doc, month_match.group(1), ts_norm, role, len(items)))

    if not to_move:
        print(f"OK: no changes — nothing fully routed to archive in {feed_path}")
        return 0

    archive_dir = os.path.join(os.path.dirname(feed_path), "archive")
    by_month = {}
    for raw_doc, month, _ts_norm, _role, _item_count in to_move:
        by_month.setdefault(month, []).append(raw_doc)

    try:
        os.makedirs(archive_dir, exist_ok=True)
        for month, raw_docs in by_month.items():
            archive_path = os.path.join(archive_dir, f"{month}.yaml")
            existing = b""
            if os.path.exists(archive_path) and os.path.getsize(archive_path) > 0:
                with open(archive_path, "rb") as fh:
                    existing = fh.read()
            new_block = _SEP.encode().join(raw_docs)
            new_content = (existing + _SEP.encode() + new_block) if existing else new_block
            _atomic_write_bytes(archive_path, new_content)
    except OSError as e:
        print(f"ERROR: failed writing archive under {archive_dir}: {e} — feed left untouched")
        return 1

    new_feed = _SEP.encode().join(survivors)
    _atomic_write_bytes(feed_path, new_feed)

    for _raw_doc, _month, ts_norm, role, item_count in to_move:
        brain.emit_event(root, {"role": role, "type": "FeedbackArchived", "ts": ts_norm, "itemCount": item_count})

    total_items = sum(item_count for _raw_doc, _month, _ts_norm, _role, item_count in to_move)
    months = sorted(by_month)
    print(f"OK: archived {len(to_move)} document(s), {total_items} item(s) -> {archive_dir} ({', '.join(months)})")
    return 0


def cmd_archived(root, since=None):
    cfg = C.load_config(root, warn=False)
    fcfg, feed_overridden = parse_feedback_cfg(cfg)
    guard_err = _legacy_guard_error(root, fcfg, feed_overridden)
    if guard_err:
        print(guard_err)
        return 1
    feed_path = _feed_path(root, fcfg)
    if feed_path is None:
        print(f"ERROR: methodology.feedback.feed {fcfg['feed']!r} resolves outside the repo root")
        return 1
    archive_dir = os.path.join(os.path.dirname(feed_path), "archive")
    if not os.path.isdir(archive_dir):
        return 0
    for name in sorted(os.listdir(archive_dir)):
        if not name.endswith(".yaml"):
            continue
        for rec in _load_feed(os.path.join(archive_dir, name)):
            ts = rec.get("ts", "")
            ts_norm = _normalize_ts(ts)
            month_match = _MONTH_RE.match(ts_norm) if isinstance(ts_norm, str) else None
            if since is not None and (month_match is None or month_match.group(1) < since):
                continue
            for i, item in enumerate(rec.get("items", [])):
                print(f"{ts}\t{i}\t{item.get('category', '')}\t{item.get('severity', '')}\t{item.get('summary', '')}")
    return 0


def cmd_status(root):
    cfg = C.load_config(root, warn=False)
    fcfg, feed_overridden = parse_feedback_cfg(cfg)
    guard_err = _legacy_guard_error(root, fcfg, feed_overridden)
    if guard_err:
        print(guard_err)
        return 1
    feed_path = _feed_path(root, fcfg)
    if feed_path is None:
        print(f"ERROR: methodology.feedback.feed {fcfg['feed']!r} resolves outside the repo root")
        return 1
    pending = sum(1 for rec in _load_feed(feed_path) for _ in _unrouted(rec))
    state = "enabled" if fcfg["enabled"] else "disabled"
    print(f"feedback: {state} feed={fcfg['feed']} pending={pending}")
    return 0


def _cli(argv):
    if len(argv) < 2:
        sys.stderr.write(
            "usage: feedback.py <root> {emit <record.yaml>|pending|route <ts> <idx> <action> <ref>"
            "|status|migrate-qualify|archive|archived [--since YYYY-MM]}\n"
        )
        return 2
    root, verb = argv[0], argv[1]
    if verb == "emit":
        if len(argv) < 3:
            sys.stderr.write("usage: feedback.py <root> emit <record.yaml>\n")
            return 2
        return cmd_emit(root, argv[2])
    if verb == "pending":
        return cmd_pending(root)
    if verb == "route":
        if len(argv) < 6:
            sys.stderr.write("usage: feedback.py <root> route <record-ts> <item-index> <action> <ref>\n")
            return 2
        return cmd_route(root, argv[2], argv[3], argv[4], argv[5])
    if verb == "status":
        return cmd_status(root)
    if verb == "migrate-qualify":
        return cmd_migrate_qualify(root)
    if verb == "archive":
        return cmd_archive(root)
    if verb == "archived":
        since = None
        rest = argv[2:]
        if rest:
            if len(rest) != 2 or rest[0] != "--since":
                sys.stderr.write("usage: feedback.py <root> archived [--since YYYY-MM]\n")
                return 2
            since = rest[1]
        return cmd_archived(root, since=since)
    sys.stderr.write(f"feedback.py: unknown verb {verb!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
