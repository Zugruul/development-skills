"""Machine-local default assistant store + §7.6 resolution order
(SPEC-ASSISTANT.md §6.3, §7.6, AST-007, issue #307).

Per §6.3 the machine-local default assistant name lives ONLY in neural-view's
own local state (never a tracked file); an ambiguous or missing stored
default fails resolution with a message listing candidates. Per §7.6 the
terminal's resolution order is: explicit flag -> sole discovered assistant ->
stored local default -> error listing candidates, and NAME matching covers
any name/alias.

State dir resolution mirrors neural-view.py's own `state_dir()`: the
`NEURAL_VIEW_STATE` env var if set, else `<git root>/.claude/neural-view`
(there is no per-repo `root` parameter here -- the store itself is
machine-local, not repo-local; setup.py's `set_default` passes an explicit
`state_dir` computed from ITS `root` argument, which is how the existing
`set-default` CLI verb keeps writing under `<root>/.claude/neural-view/`
unchanged).

Case handling: NAME matching (flag, stored default, alias lookup) is
case-insensitive (`str.strip().lower()` on both sides) -- convention chosen
so `--assistant Jarvis` and a stored `jarvis` both resolve without requiring
exact-case round-tripping through a config file a human hand-edited.

Library:
    read_default(state_dir=None) -> str | None
        The stored default name, or None if no default is stored yet.
        Raises DefaultStoreError (a clean message, never a raw OSError) if
        the state dir exists but the file can't be read (e.g. permissions).

    write_default(name, state_dir=None) -> str (the path written)
        Atomic tmp+rename write of `name` (stripped, one line). Raises
        DefaultStoreError -- with a clean message, never a raw OSError or
        traceback -- if the state dir can't be created/written to, or if
        `name` is empty.

    discover_candidate(root) -> (root, assistant_section) | None
        Single-repo discovery: a behavior-identical wrapper over
        assistant.discovery.classify_repo (AST-020) -- kind == "candidate"
        returns (root, section), anything else (no marker, no config,
        invalid section, disabled) silently returns None. AST-020 owns the
        one classification code path (with rejection reasons, for the full
        multi-repo discovery UX); this stays the minimal boolean-ish shape
        resolve_assistant()'s tests were written against.

    discover_candidates(roots) -> list[(root, assistant_section)]
        discover_candidate() mapped over `roots`, dropping non-candidates.

    resolve_assistant(candidates, flag=None, state_dir=None)
            -> (root, assistant_section)
        Implements §7.6's resolution order exactly:
          1. `flag` given: the (sole) candidate whose names/aliases match it
             (case-insensitively) -- ResolutionError if zero or 2+ match.
          2. Exactly one candidate overall: that one (the "sole assistant"
             shortcut), regardless of any stored default.
          3. Otherwise, the stored local default (`read_default`) is looked
             up among `candidates` by name/alias:
               - no default stored -> ResolutionError listing candidates.
               - default matches zero candidates (missing/stale) ->
                 ResolutionError listing candidates (§6.3 "missing").
               - default matches 2+ candidates (colliding names across
                 repos) -> ResolutionError listing the colliding matches
                 specifically (§6.3 "ambiguous").
        `candidates` itself empty -> ResolutionError with no candidates to
        list.

CLI: `default_store.py {read-default|write-default <name>|resolve} ...`
     -- a thin exercise surface over the library above (kept minimal: no
     new production caller needs it yet, setup.py wires directly to the
     library functions). See `_cli` below for exact flags.
"""
import os
import subprocess
import sys
import tempfile

_SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# see preflight.py's identical comment: force scripts/ to the FRONT of
# sys.path so `import config` never shadows against assistant/config.py.
if _SCRIPTS_DIR in sys.path:
    sys.path.remove(_SCRIPTS_DIR)
sys.path.insert(0, _SCRIPTS_DIR)

from assistant import discovery  # noqa: E402  AST-020: single classification code path

DEFAULT_FILE_NAME = "assistant-default"


class DefaultStoreError(Exception):
    """A clean, printable message -- read_default/write_default raise this
    instead of ever letting a raw OSError/traceback reach a caller."""


class ResolutionError(Exception):
    """§7.6 resolution failed -- message always lists the relevant
    candidates (§6.3)."""


# --- state dir ---------------------------------------------------------------

def _git_root():
    try:
        return subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except Exception:  # noqa: BLE001  -- mirrors neural-view.py's git_root()
        return os.getcwd()


def _default_state_dir():
    env = os.environ.get("NEURAL_VIEW_STATE")
    if env:
        return env
    return os.path.join(_git_root(), ".claude", "neural-view")


def _resolve_state_dir(state_dir):
    return state_dir if state_dir is not None else _default_state_dir()


# --- read/write ----------------------------------------------------------------

def read_default(state_dir=None):
    sd = _resolve_state_dir(state_dir)
    path = os.path.join(sd, DEFAULT_FILE_NAME)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise DefaultStoreError(f"cannot read local default from {path}: {e}")
    text = text.strip()
    return text or None


def write_default(name, state_dir=None):
    name = (name or "").strip()
    if not name:
        raise DefaultStoreError("cannot store an empty assistant name")
    sd = _resolve_state_dir(state_dir)
    path = os.path.join(sd, DEFAULT_FILE_NAME)
    try:
        os.makedirs(sd, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".assistant-default-tmp-", dir=sd)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(name + "\n")
            os.replace(tmp, path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except OSError as e:
        raise DefaultStoreError(f"cannot write local default to {path}: {e}")
    return path


# --- minimal discovery (AST-020 owns the full UX) -------------------------------

def discover_candidate(root):
    c = discovery.classify_repo(root)
    if c.kind != "candidate":
        return None
    return (root, c.section)


def discover_candidates(roots):
    out = []
    for root in roots:
        found = discover_candidate(root)
        if found is not None:
            out.append(found)
    return out


# --- §7.6 resolution -------------------------------------------------------------

def _names(section):
    raw = section.get("names") if isinstance(section, dict) else None
    return [n for n in (raw or []) if isinstance(n, str) and n.strip()]


def _matches_name(section, name):
    target = name.strip().lower()
    return any(n.strip().lower() == target for n in _names(section))


def _label(candidate):
    root, section = candidate
    names = _names(section)
    main = names[0] if names else "?"
    aliases = names[1:]
    suffix = f" (aliases: {', '.join(aliases)})" if aliases else ""
    return f"{main}{suffix} [{root}]"


def _list_candidates(candidates):
    return ", ".join(_label(c) for c in candidates)


def resolve_assistant(candidates, flag=None, state_dir=None):
    candidates = list(candidates)
    if not candidates:
        raise ResolutionError("no assistants discovered")

    if flag:
        matches = [c for c in candidates if _matches_name(c[1], flag)]
        if not matches:
            raise ResolutionError(
                f"no assistant named {flag!r} — candidates: {_list_candidates(candidates)}"
            )
        if len(matches) > 1:
            raise ResolutionError(
                f"assistant name {flag!r} is ambiguous — matches: {_list_candidates(matches)}"
            )
        return matches[0]

    if len(candidates) == 1:
        return candidates[0]

    default = read_default(state_dir)
    if not default:
        raise ResolutionError(
            "no local default set and multiple assistants found — "
            f"candidates: {_list_candidates(candidates)}"
        )

    matches = [c for c in candidates if _matches_name(c[1], default)]
    if not matches:
        raise ResolutionError(
            f"local default {default!r} matches no discovered assistant — "
            f"candidates: {_list_candidates(candidates)}"
        )
    if len(matches) > 1:
        raise ResolutionError(
            f"local default {default!r} is ambiguous — matches: {_list_candidates(matches)}"
        )
    return matches[0]


# --- CLI -----------------------------------------------------------------------

def _usage():
    sys.stderr.write(
        "usage: default_store.py read-default [--state-dir DIR]\n"
        "       default_store.py write-default <name> [--state-dir DIR]\n"
        "       default_store.py resolve [--root DIR]... [--flag NAME] [--state-dir DIR]\n"
    )


def _parse_common(rest):
    roots = []
    flag = None
    state_dir = None
    i = 0
    while i < len(rest):
        if rest[i] == "--root" and i + 1 < len(rest):
            roots.append(rest[i + 1]); i += 2
        elif rest[i] == "--flag" and i + 1 < len(rest):
            flag = rest[i + 1]; i += 2
        elif rest[i] == "--state-dir" and i + 1 < len(rest):
            state_dir = rest[i + 1]; i += 2
        else:
            i += 1
    return roots, flag, state_dir


def _cli(argv):
    if not argv:
        _usage()
        return 2
    verb, rest = argv[0], argv[1:]

    if verb == "read-default":
        _, _, state_dir = _parse_common(rest)
        try:
            value = read_default(state_dir)
        except DefaultStoreError as e:
            sys.stderr.write(f"STORE FAIL: {e}\n")
            return 1
        if value:
            print(value)
        return 0

    if verb == "write-default":
        if not rest or rest[0].startswith("--"):
            sys.stderr.write("usage: default_store.py write-default <name> [--state-dir DIR]\n")
            return 2
        name, tail = rest[0], rest[1:]
        _, _, state_dir = _parse_common(tail)
        try:
            path = write_default(name, state_dir=state_dir)
        except DefaultStoreError as e:
            sys.stderr.write(f"STORE FAIL: {e}\n")
            return 1
        print(path)
        return 0

    if verb == "resolve":
        roots, flag, state_dir = _parse_common(rest)
        candidates = discover_candidates(roots)
        try:
            root, section = resolve_assistant(candidates, flag=flag, state_dir=state_dir)
        except ResolutionError as e:
            sys.stderr.write(f"RESOLUTION FAIL: {e}\n")
            return 1
        names = _names(section)
        print(f"{root}\t{names[0] if names else ''}")
        return 0

    sys.stderr.write(f"default_store.py: unknown verb {verb!r}\n")
    _usage()
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
