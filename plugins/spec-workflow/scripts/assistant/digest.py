"""Activation digest (SPEC-ASSISTANT.md §7.8, AST-024, issue #321).

§7.8: WHEN an assistant becomes active THE SYSTEM SHALL present an
activation digest of its background activity since last active
(completed/failed tasks, minted notes), sourced from its trace events.

REALITY CHECK (documented, not silently diverged from -- see
docs/spec-deltas/AST-024.md for the paste-ready delta): §7.8 says "sourced
from its trace events", but `traces.sqlite` (§10.2) does not exist yet --
it is E4. This module builds the SAME response shape §7.8 promises from
what DOES exist today per assistant repo:

  - minted notes: `<root>/.claude/brain-events.jsonl` (brain.py's
    `emit_event`, already a per-repo, append-only, JSON-per-line feed --
    Sec8.1/8.2's `NoteMinted` events specifically), filtered to `role`
    (default "assistant", matching turns.py's `make_default_recall`
    default) and `ts` strictly after `since_ts`.
  - exchange count: `<root>/.claude/assistant/session.jsonl` (store.py's
    `SessionStore` transcript), counting records with `ts` strictly after
    `since_ts`.
  - tasks: v1 ALWAYS returns an empty list with `tasksSource:
    "pending-E4"` -- there is no per-assistant task queue trace to read
    yet (AST-024's brief is explicit: never fabricate task data). E4 swaps
    the real source in without changing this function's return shape.

`since_ts` is an ISO-8601 string (str(datetime.now(timezone.utc)
.isoformat()), the same format every `ts` field in this codebase already
uses -- see store.py's `_now_iso` / brain.py's `now_iso`) or None. None
means "no prior activation recorded for this assistant" -- v1 treats that
as "since the beginning of recorded history" (every minted note / exchange
on file), since there is nothing else to bound it by; it is NOT an error.

A malformed/unreadable event or transcript line degrades to "skipped",
never a crash or a raised exception -- this module is read-only digest
production for a UI panel, not a source of truth that must fail loudly
(same tolerant-parse discipline as `store.py`'s `SessionStore.history`).

Library:
    digest(root, since_ts, role="assistant") ->
        {"sinceTs": str | None, "notesMinted": [{"slug", "strength", "ts"}, ...],
         "exchanges": int, "tasks": [], "tasksSource": "pending-E4"}
"""
import json
import os
from datetime import datetime

from assistant.store import SessionStore

BRAIN_EVENTS_FILE_NAME = "brain-events.jsonl"


def _parse_ts(raw):
    """`datetime.fromisoformat` on a `ts` string, or None if `raw` is not a
    parseable ISO-8601 string -- never raises (a malformed `ts` degrades to
    "unknown", the same tolerant-parse treatment a torn transcript line
    gets in store.py's `history()`)."""
    if not isinstance(raw, str) or not raw.strip():
        return None
    try:
        return datetime.fromisoformat(raw)
    except ValueError:
        return None


def _after(ts_raw, since_dt):
    """True iff `since_dt` is None (no lower bound -- "since the beginning
    of recorded history", see module docstring), or `ts_raw` parses AND is
    strictly after `since_dt`. An unparseable `ts_raw` is excluded (never
    counted "after" an unknown time) rather than raising, EXCEPT under the
    no-lower-bound case where there is nothing to compare against and the
    record is simply included."""
    if since_dt is None:
        return True
    parsed = _parse_ts(ts_raw)
    return parsed is not None and parsed > since_dt


def _notes_minted_since(root, since_dt, role):
    path = os.path.join(str(root), ".claude", BRAIN_EVENTS_FILE_NAME)
    notes = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except (FileNotFoundError, OSError):
        return notes
    for raw in lines:
        stripped = raw.strip()
        if not stripped:
            continue
        try:
            event = json.loads(stripped)
        except ValueError:
            continue  # torn line (concurrent-append artifact) -- skip, never crash
        if not isinstance(event, dict):
            continue
        if event.get("type") != "NoteMinted":
            continue
        if role is not None and event.get("role") != role:
            continue
        if not _after(event.get("ts"), since_dt):
            continue
        notes.append({
            "slug": event.get("slug"),
            "strength": event.get("strength"),
            "ts": event.get("ts"),
        })
    return notes


def _exchanges_since(root, since_dt):
    result = SessionStore(root).history(n=None)
    return sum(1 for exch in result["exchanges"] if _after(exch.get("ts"), since_dt))


def digest(root, since_ts, role="assistant"):
    """Builds one activation digest for `root` (§7.8). See module docstring
    for the exact source-per-field mapping and the documented E4 seam."""
    since_dt = _parse_ts(since_ts)
    return {
        "sinceTs": since_ts,
        "notesMinted": _notes_minted_since(root, since_dt, role),
        "exchanges": _exchanges_since(root, since_dt),
        "tasks": [],
        "tasksSource": "pending-E4",
    }
