"""Session transcript store (SPEC-ASSISTANT.md §4, §8.7, AST-014).

Per §8.7: THE SYSTEM SHALL append each exchange to the session transcript
(append-safe JSONL, fsync'd) so a crash loses at most the in-flight turn.
Per §4's glossary the assistant's local state lives at `<root>/.claude/
assistant/` (gitignored -- `scripts/local-state.manifest` already lists
`ignore\t.claude/assistant/`, AST-005); this module owns exactly two files
inside that directory:

  - `session.jsonl`  -- the TRANSCRIPT. Append-only, one JSON object per
    line, one line per exchange. NEVER rewritten in place: an exchange is
    written once with write -> flush -> os.fsync, and the fsync happens
    BEFORE `append_exchange` returns to the caller. That ordering is the
    entire durability contract: a crash after `append_exchange` returns
    can never lose that exchange (its bytes are already on stable
    storage), and a crash DURING the write can leave at most one torn
    trailing line -- a truncated/unparsable final line is an EXPECTED
    crash artifact, not a corruption, and `history()` tolerates it (skips
    it, records a warning, never raises).

  - `session-state.json` -- the rolling summary + turn window
    (turns.py's `session_state` shape: `{"summary", "turns",
    "turn_count"}`). Unlike the transcript this IS a read-modify-write
    cache (turns.py's `_advance_session_state` replaces it wholesale each
    turn), so it needs a different discipline: atomic tmp-file + `os.replace`
    (the same house pattern as `preflight.py`'s `_write_cache_atomic` and
    `default_store.py`'s `write_default` -- `tempfile.mkstemp` in the
    target directory, write, `os.replace`) so a reader never observes a
    half-written file, and a crash mid-save leaves the PREVIOUS state
    file intact (the new one never existed under its final name).

AST-032 (Sec8.2 "the rolling summary SHALL be size-capped and refreshed
every K turns") note: this module does NOT decide when/how to refresh the
summary -- that cadence (every `SUMMARY_REFRESH_EVERY_K_TURNS` turns, size
cap enforced twice: once by the summarizer's own cap_chars argument, once
again as defense-in-depth) already lives in `turns.py`'s
`_advance_session_state`/`run_turn`, wired synchronously on the request
thread by `engine.py`'s `_chat` (`load_state` -> `run_turn` -> `save_state`,
per-root locked -- see `engine.py`'s `_chat_locks` docstring). `save_state`
here is the ONLY place a refreshed summary is persisted, and it is already
atomic per the paragraph above -- no separate `refresh_summary` entry point
is needed in this module; adding one would create a second, divergent
refresh mechanism instead of reusing the one already proven by
`section-assistant-turns.sh`'s summary-refresh tests.

OQ2 default (documented, not built): one `assistant` session per repo --
`SessionStore` takes no session-id parameter and always addresses the same
two fixed filenames under `<root>/.claude/assistant/`. Multi-session
support is out of scope for this task.

Library:
    SessionStore(root, state_dir=None)
        .append_exchange(user_text, assistant_text, meta=None) -> dict
        .load_state() -> dict            # {"summary", "turns", "turn_count"}
        .save_state(session_state)       # atomic tmp+rename
        .history(n=None) -> {"exchanges": [...], "warnings": [...]}
"""
import json
import os
import tempfile
from datetime import datetime, timezone

STATE_DIR_REL = os.path.join(".claude", "assistant")  # §4 glossary; gitignored (local-state.manifest)
TRANSCRIPT_FILE_NAME = "session.jsonl"
STATE_FILE_NAME = "session-state.json"

_EMPTY_STATE = {"summary": "", "turns": [], "turn_count": 0}


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


class SessionStore:
    """One session's persistence: transcript append + rolling state, both
    rooted at `<root>/.claude/assistant/` (or `state_dir` if given, mirroring
    the `state_dir` override every other assistant/*.py store accepts for
    tests -- e.g. `preflight.py`'s `_state_dir`, `default_store.py`'s
    `state_dir` param)."""

    def __init__(self, root, state_dir=None):
        self.root = root
        self._dir = state_dir or os.path.join(root, STATE_DIR_REL)
        self._transcript_path = os.path.join(self._dir, TRANSCRIPT_FILE_NAME)
        self._state_path = os.path.join(self._dir, STATE_FILE_NAME)

    # --- transcript ---------------------------------------------------------

    def append_exchange(self, user_text, assistant_text, meta=None):
        """Appends ONE exchange as a single JSON line. Durability contract
        (§8.7): write -> flush -> os.fsync happen BEFORE this returns, so a
        crash after return can never lose this exchange, and a crash during
        the write leaves at most this one line torn (tolerated by
        `history()`, never by this method -- a write error here still
        raises; only a KILL mid-write produces the tolerated artifact)."""
        os.makedirs(self._dir, exist_ok=True)
        record = {
            "ts": _now_iso(),
            "user": user_text,
            "assistant": assistant_text,
            "meta": meta or {},
        }
        line = json.dumps(record, sort_keys=True) + "\n"
        with open(self._transcript_path, "a", encoding="utf-8") as fh:
            fh.write(line)
            fh.flush()
            os.fsync(fh.fileno())
        return record

    def history(self, n=20):
        """Returns the last `n` exchanges (chronological order) plus any
        `warnings` for lines that could not be parsed.

        TAIL-READ APPROACH (v1, documented per AST-014's HOW): this reads
        the whole transcript file and slices the last `n` parsed records --
        acceptable at v1 because one repo's session transcript is small
        (one line per exchange, a normal session is dozens to low hundreds
        of exchanges, not millions) and simplicity here avoids a
        seek-from-end line-scanner that has to guess line boundaries
        without an index. If transcript size ever becomes a real problem a
        seek-based tail (read backwards in fixed-size chunks counting
        newlines, matching `tail -n`) can replace the body of this method
        without changing its signature or the tolerant-parse behavior
        below.

        A line that fails to parse (the expected artifact of a kill mid-
        write, per the class docstring) is skipped and recorded in
        `warnings` -- this method NEVER raises on a malformed transcript.
        `n <= 0` returns no exchanges (not an error); `n` larger than the
        transcript just returns everything available.
        """
        exchanges = []
        warnings = []
        try:
            with open(self._transcript_path, "r", encoding="utf-8") as fh:
                lines = fh.readlines()
        except FileNotFoundError:
            lines = []
        except OSError as e:
            # review r1: an unreadable transcript (permissions, mount) must
            # degrade to a warning like every other read failure -- an
            # uncaught PermissionError here dropped the whole HTTP response.
            warnings.append(f"{self._transcript_path}: unreadable ({e})")
            lines = []

        for lineno, raw in enumerate(lines, start=1):
            stripped = raw.strip()
            if not stripped:
                continue
            try:
                record = json.loads(stripped)
            except ValueError:
                warnings.append(f"session.jsonl:{lineno}: skipped unparsable line (torn write?)")
                continue
            if not isinstance(record, dict):
                warnings.append(f"session.jsonl:{lineno}: skipped non-object line")
                continue
            exchanges.append(record)

        if n is None:
            return {"exchanges": exchanges, "warnings": warnings}
        if n <= 0:
            return {"exchanges": [], "warnings": warnings}
        return {"exchanges": exchanges[-n:], "warnings": warnings}

    # --- rolling state --------------------------------------------------------

    def load_state(self):
        """Returns the persisted session_state, or the documented empty
        state (`{"summary": "", "turns": [], "turn_count": 0}` -- matches
        turns.py's shape) when nothing has been saved yet, or the state
        file is missing/unparsable/not-a-dict. Never raises."""
        try:
            with open(self._state_path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return dict(_EMPTY_STATE)
        if not isinstance(data, dict):
            return dict(_EMPTY_STATE)
        return data

    def save_state(self, session_state):
        """Atomically replaces `session-state.json` (tmp-file-then-
        os.replace, the same house pattern as `preflight.py`'s
        `_write_cache_atomic` / `default_store.py`'s `write_default`) --
        this IS a read-modify-write cache, so a reader must never observe a
        half-written file, and a crash mid-save must leave the PREVIOUS
        state intact rather than a torn one (unlike the transcript, which
        is append-only and tolerates a torn tail by design)."""
        os.makedirs(self._dir, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".assistant-session-state-tmp-", dir=self._dir)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(session_state, fh)
            os.replace(tmp, self._state_path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
