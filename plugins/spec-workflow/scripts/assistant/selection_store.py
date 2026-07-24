"""Server-side selection MEMORY (SPEC-ASSISTANT.md §7.5, AST-022, issue
#319): persists an `AssistantEngine`'s startup selection to a small JSON
file under the engine's own `state_dir`, so a page reload, a second tab, or
a fresh `neural-view.py` process picks up the SAME `{selected, gated,
askAgain}` the previous engine instance had -- AST-021 kept this in-memory
only (one process = one selection, lost on restart by design; see
engine.py's `__init__` docstring for that task's own framing).

This is a DIFFERENT mechanism from `default_store` (SPEC-ASSISTANT.md §6.3,
AST-007): `default_store` holds the machine-local DEFAULT assistant NAME
used by §7.6's terminal resolution order (flag -> sole assistant -> stored
default -> error) when there are multiple candidates and nothing has been
explicitly picked for this boot; this module holds the CURRENT startup
SELECTION state (§7.2-§7.4 picker outcome) plus the "ask again on load"
setting (§7.5). The two are never merged: `default_store`'s file lives
alongside this one in the same state dir (both AST-007 and this task read
`NEURAL_VIEW_STATE`-derived dirs) but they are read/written independently
and answer different questions -- "what NAME resolves chat by default" vs.
"what did the LAST startup picker decide, and should it ask again".

Atomic tmp+rename write, matching `default_store.write_default`'s pattern
(mkstemp in the SAME directory as the final path, so the rename is on one
filesystem, then `os.replace`) -- a reader never observes a partially
written file.

Library:
    load(state_dir) -> {"selected": str | None, "gated": bool, "askAgain": bool}
        The persisted state, or the all-defaults shape
        ({"selected": None, "gated": False, "askAgain": False}) if nothing
        has been written yet, the file is unreadable, or its JSON is
        malformed -- corrupt/missing state degrades to "nothing selected
        yet", never a crash (mirrors default_store.read_default's
        FileNotFoundError -> None).

    save(state_dir, selected, gated, ask_again) -> str (the path written)
        Atomic tmp+rename write of the JSON state file.
"""
import json
import os
import tempfile

SELECTION_FILE_NAME = "assistant-selection.json"

_DEFAULTS = {"selected": None, "gated": False, "askAgain": False}


def _path(state_dir):
    return os.path.join(str(state_dir), SELECTION_FILE_NAME)


def load(state_dir):
    path = _path(state_dir)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (FileNotFoundError, OSError, ValueError):
        return dict(_DEFAULTS)
    if not isinstance(data, dict):
        return dict(_DEFAULTS)
    selected = data.get("selected")
    if not isinstance(selected, str) or not selected.strip():
        selected = None
    return {
        "selected": selected,
        "gated": bool(data.get("gated", False)),
        "askAgain": bool(data.get("askAgain", False)),
    }


def save(state_dir, selected, gated, ask_again):
    sd = str(state_dir)
    path = _path(sd)
    payload = {
        "selected": selected if isinstance(selected, str) and selected.strip() else None,
        "gated": bool(gated),
        "askAgain": bool(ask_again),
    }
    os.makedirs(sd, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".assistant-selection-tmp-", dir=sd)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return path
