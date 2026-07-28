"""Artifact path resolution for `GET /assistant/artifact/<task-id>`
(SPEC-ASSISTANT.md Sec12.2, AST-068, issue #343).

Sec12.2 requires a STREAMED, range-capable endpoint distinct from
`/file` (neural-view.py's existing brain-dir file server): `/file`
`read_bytes()`s the whole file into RAM before ever answering a Range
header (see its own `_send_ranged` docstring) -- fine for the small note
attachments it serves, unsuitable for the large media (video, 3D models)
a task's artifact can be. This module owns ONLY the safe resolution of a
task id to an absolute on-disk path; it never touches a socket or reads
file content -- the actual chunked, range-aware streaming lives in
neural-view.py's `Handler` (engine.py's own convention: "the engine
package stays HTTP-framework-agnostic", see its do_GET/`handle()`
division-of-labor comments). `engine.py`'s `_artifact` method is the only
caller.

Storage layout (flagged design call -- AST-068 is the FIRST task to
define this; no real task-kind executor exists yet, AST-070 is the one
that will produce real artifacts): every root's artifacts live under
`ARTIFACTS_DIR_REL` below, the SAME `.claude/assistant/` directory
`tasks.sqlite` already lives in (TASKS_DIR_REL in tasks.py) -- already
covered by local-state.manifest's whole-directory `ignore .claude/
assistant/` entry (Sec17 invariant 8: artifacts never committed to git),
so no manifest edit is needed for this task (verified: a new subdirectory
under an existing directory-level `ignore` entry needs no new line,
unlike issue #447's BASE_CAPABILITIES entries, which each needed their
own line because they are NEW top-level paths, not descendants of an
already-covered directory).

`tasks.artifact_path` (the column an executor's outcome dict populates,
Sec12.3) is stored and interpreted as a path RELATIVE to this root's
artifacts directory -- never an absolute path, never trusted verbatim.
Every failure mode below raises the SAME `ArtifactError`, collapsed by
`engine.py`'s `_artifact` to the SAME generic 404 regardless of which
one fired (issue #343 review: "treat it as a traversal surface" -- a
crafted task id or a not-yet-completed one must get no more signal back
than each other; distinguishing "task exists but has no artifact" from
"artifact path tried to escape the root" in the HTTP response would hand
an attacker a free oracle for probing the containment check itself).

Traversal defense (adversarial test list, all exercised in
section-assistant-artifacts.sh):
  1. A relative escape (`../../etc/passwd`) -- caught by the containment
     check below (mirrors neural-view.py's own `_within` helper exactly:
     `os.path.realpath` both sides, then equality or `startswith(parent
     + os.sep)` -- NOT `os.path.commonpath`, which admits a same-prefix
     sibling like `/root` vs `/rootevil` unless the separator is
     appended manually anyway; `_within`'s shape already gets this
     right, reused verbatim rather than reinvented).
  2. Absolute `artifact_path` (e.g. `/etc/passwd`) -- rejected BEFORE
     the join: `os.path.join(root, absolute)` silently DISCARDS `root`
     and returns the absolute path unchanged (a well-known Python
     footgun, not a hypothetical) -- letting that reach the containment
     check would make the check itself pointless for this one input
     shape.
  3. A same-name-prefix sibling directory escape (root
     `.claude/assistant/artifacts`, candidate resolving into a sibling
     `.claude/assistant/artifacts-evil/`) -- exactly what `startswith`
     WITHOUT the `+ os.sep` guard would wrongly admit; covered by
     reusing `_within`'s exact shape.
  4. A symlink inside the artifacts root pointing outside it --
     `os.path.realpath` resolves symlinks on BOTH sides before the
     containment compare, so a symlink escape is caught the same as a
     lexical relative one (a purely-lexical `os.path.normpath`-based
     check, the first draft of this module used, would NOT catch this --
     flagged and fixed before any test was written).
  5. A slash inside the task id itself (`/assistant/artifact/../x`) --
     rejected at the ROUTING layer in `engine.py._artifact`, before this
     module or the filesystem is ever touched: real task ids are
     `uuid.uuid4().hex` (tasks.py's `enqueue`), which never contain `/`.

Size cap (flagged design call): streaming never risks the whole-file-
in-RAM problem `/file` has regardless of artifact size, but an
unbounded response still ties up one server thread/socket indefinitely
for a single client. `MAX_ARTIFACT_BYTES` (2 GiB, generous for the video/
3D-model media Sec12.1 names, a judgment call not derived from any spec
number) is enforced by the streaming code in neural-view.py (which
already stats the file for Content-Length) as an honest 413, not
silently truncated or hung.
"""
import os

from assistant import tasks

ARTIFACTS_DIR_REL = os.path.join(".claude", "assistant", "artifacts")

# 2 GiB default -- see module docstring's "Size cap". ASSISTANT_ARTIFACT_MAX_BYTES
# overrides it (same env-override convention as DESIGN_REGISTRY_ROOT/UI_HUB_STATE
# elsewhere in this plugin) -- a real 2 GiB fixture file is not something a
# hermetic test can build; the override lets the 413 path be exercised against
# a small, fast fixture instead.
MAX_ARTIFACT_BYTES = int(os.environ.get("ASSISTANT_ARTIFACT_MAX_BYTES") or 2 * 1024 * 1024 * 1024)


class ArtifactError(Exception):
    """Every raise site below collapses to the identical generic 404 at
    the `engine.py` call site -- this exception intentionally carries no
    machine-distinguishable code, only a human-debugging `str()` (never
    shown to the client)."""


def _artifacts_root(root):
    return os.path.join(root, ARTIFACTS_DIR_REL)


def _within(child, parent):
    """Same shape as neural-view.py's own `_within` (its `/file/` route's
    traversal guard) -- reused here rather than reinvented so this
    codebase has ONE containment check, not two subtly different ones.
    `child`/`parent` are path strings; both realpath'd (resolves symlinks
    too, see module docstring point 4) before comparing."""
    try:
        c, p = os.path.realpath(child), os.path.realpath(parent)
        return c == p or c.startswith(p + os.sep)
    except Exception:  # noqa: BLE001 -- any path-resolution oddity fails closed, never raises
        return False


def resolve(root, task_id):
    """Returns `(absolute_path, size_bytes)` for a COMPLETED task's
    artifact. Raises `ArtifactError` for every dishonest-shortcut or
    not-actually-available case: no such task, task not yet completed,
    no `artifact_path` recorded, an absolute `artifact_path` (rejected
    before ever joining it -- see module docstring point 2), a path that
    resolves outside this root's artifacts directory (points 1/3/4), or
    a resolved path that is not a readable regular file. Never returns a
    guessed content type -- `mimetypes.guess_type` is the streaming
    code's job in neural-view.py (an HTTP-shaping concern, not a path-
    resolution one), keeping this module's one job exactly one job."""
    task = tasks.get_task(root, task_id)
    if task is None:
        raise ArtifactError("no such task")
    if task.get("state") != tasks.STATE_COMPLETED:
        raise ArtifactError("task not completed")
    rel = task.get("artifact_path")
    if not rel or not isinstance(rel, str):
        raise ArtifactError("task has no artifact")
    if os.path.isabs(rel):
        raise ArtifactError("artifact path must be relative")
    artifacts_root = _artifacts_root(root)
    candidate = os.path.join(artifacts_root, rel)
    if not _within(candidate, artifacts_root):
        raise ArtifactError("artifact path escapes artifacts root")
    if not os.path.isfile(candidate):
        raise ArtifactError("artifact file missing")
    try:
        size = os.path.getsize(candidate)
    except OSError as exc:
        raise ArtifactError(f"artifact unreadable: {exc}") from exc
    return candidate, size
