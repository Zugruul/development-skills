"""setup-assistant scaffold + settings editor (SPEC-ASSISTANT.md §6.4, §6.7,
§11.9; touchpoint §6.3). Backs the `setup-assistant` skill and its
`scripts/setup-assistant.sh` bash wrapper. Python stdlib + PyYAML (via
`config.py`, the shared loader) only.

Library:
    scaffold(root, names=None, provider=None, model=None) -> dict
        Idempotent, create-if-absent scaffold: `.claude/.neural-network`
        marker, `assistant:` section of `.claude/project.yaml` (per-leaf
        skip-if-present — never overwrites an existing value), empty brain
        dirs, and the persona `AGENTS.md` with its GENERATED skills block.
        Returns {"changed": bool, "errors": list[str]} — errors are from a
        best-effort post-scaffold validate_assistant() pass (non-fatal: a
        pre-existing malformed section is reported, never repaired here).

    apply_setting(root, mutator) -> (bool, list[str])
        Snapshot project.yaml, run `mutator(path)` (a `config.set_config`
        call), reload + validate_assistant(); on any error the file is
        restored byte-for-byte and the errors are returned (rc caller's to
        decide). On success returns (True, []).

    set_default(root, name) -> str
        Write the machine-local default assistant name into neural-view's
        own local-state dir (`.claude/neural-view/`, already gitignored via
        local-state.manifest — §6.3 touchpoint only; AST-007 builds the full
        store + ambiguity resolution). Returns the path written.

CLI: `setup.py <root> {scaffold|set-provider|set-model|enable-capability|
disable-capability|set-default|validate} [args...]`
"""
import contextlib
import fcntl
import os
import sys
import tempfile

_SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import config as project_config  # noqa: E402  scripts/config.py, the shared loader
from assistant.config import validate_assistant  # noqa: E402
from assistant import default_store  # noqa: E402  AST-007: single source of truth for the default store

# Verbatim match of neural-view.py's MARKER_CONTENT (§6.2) — duplicated
# rather than imported so this module never pulls in neural-view.py's
# server-process import weight. Keep in sync by hand; section-assistant-
# marker.sh and section-setup-assistant.sh both pin this exact string.
MARKER_NAME = ".neural-network"
MARKER_CONTENT = (
    "# neural-view discovery marker — repos with this file are "
    "included in the aggregated neural view\n"
)

def _load(root, path):
    """load_config, tolerating an empty/whitespace-only file (a freshly
    created project.yaml before its first key is written) as {} rather than
    config.py's ConfigError('top level must be a mapping') — a real parse
    error on non-empty malformed content still propagates."""
    if not os.path.exists(path) or not open(path, encoding="utf-8").read().strip():
        return {}
    return project_config.load_config(root=root, path=path, warn=False) or {}


# review r2 finding 1: a same-directory tmp-file + os.replace() swap (AST-004's
# brain.py._atomic_write pattern) so a reader/concurrent writer never observes
# a partially-written project.yaml; the cross-process flock below additionally
# serializes concurrent scaffold runs so two writers can't compute their "what's
# missing" leaf sets against each other's half-applied state.
def _atomic_write_text(path, text):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".setup-assistant-tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _lock_path(root):
    claude_dir = os.path.join(root, ".claude")
    os.makedirs(claude_dir, exist_ok=True)
    # realpath: two spellings of the same .claude dir must key to the same lock.
    return os.path.join(os.path.realpath(claude_dir), ".setup-assistant.lock")


@contextlib.contextmanager
def _project_yaml_lock(root):
    """Cross-process exclusive lock guarding the whole read-decide-write
    critical section against a concurrent setup-assistant invocation on the
    same root (review r2 finding 1)."""
    path = _lock_path(root)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
    except Exception:
        os.close(fd)
        raise
    try:
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _parse_text(text):
    """Parse in-memory YAML text (no file I/O) into a dict, tolerating an
    empty/whitespace-only document as {} the same way `_load` tolerates an
    empty file. A non-mapping top level also comes back as {} here — callers
    that need to detect that distinction (e.g. an `assistant:` leaf whose
    parent isn't a mapping) inspect the parsed structure themselves before
    calling this, not after."""
    if not text.strip():
        return {}
    import yaml  # local import: mirrors config.py's lazy PyYAML import
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as e:
        # review r3: a genuinely unparseable project.yaml must surface as the
        # SAME ConfigError config.py._parse() raises, not a raw yaml.YAMLError
        # -- only _cli()'s top-level try/except knows how to render ConfigError
        # into a clean "PREFLIGHT FAIL: ..." line.
        raise project_config.ConfigError(f"cannot parse project.yaml: {e}")
    return data if isinstance(data, dict) else {}


PROJECT_YAML_REL = os.path.join(".claude", "project.yaml")
BRAIN_NOTES_REL = os.path.join(".claude", "identities", "assistant", "brain", "notes")
AGENTS_MD_REL = "AGENTS.md"
STATE_DEFAULT_REL = os.path.join(".claude", "neural-view")  # already gitignored (manifest)
DEFAULT_FILE_NAME = "assistant-default"

GEN_START = "<!-- >>> spec-workflow generated: enabled skills (SPEC-ASSISTANT.md §11.9) -->"
GEN_END = "<!-- <<< spec-workflow generated: enabled skills (SPEC-ASSISTANT.md §11.9) -->"


# --- marker -----------------------------------------------------------------

def ensure_marker(root):
    """Create <root>/.claude/.neural-network if absent; leave untouched if present."""
    path = os.path.join(root, ".claude", MARKER_NAME)
    if os.path.exists(path):
        return False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(MARKER_CONTENT)
    return True


# --- project.yaml assistant: section -----------------------------------------

def _leaves(prefix, node):
    """Yield (dotpath, value) for every non-dict leaf of a nested dict."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from _leaves(f"{prefix}.{k}" if prefix else k, v)
    else:
        yield prefix, node


def _default_assistant_section(names, provider, model):
    provider = provider or "claude"
    model = model or "claude-sonnet-5"
    main_name = (names or ["assistant"])[0]
    return {
        "version": 1,
        "enabled": True,
        "names": list(names) if names else ["assistant"],
        "systemPrompt": (
            f"You are {main_name}, the local assistant for this repository's zettel brain."
        ),
        "llm": {"provider": provider, "model": model},
        "capabilities": {
            "claude-code": {"enabled": provider == "claude", "provisioning": {"bin": "claude"}},
            "codex": {"enabled": provider == "openai", "provisioning": {"bin": "codex"}},
        },
        "observability": {
            "metrics": {"prometheus": {"enabled": True, "host": "127.0.0.1", "port": 9464}},
            "traces": {"sqlite": {"enabled": True, "retainDays": 30, "maxMB": 500}},
        },
    }


def ensure_project_yaml_assistant(root, names=None, provider=None, model=None):
    """Create-if-absent .claude/project.yaml; insert every MISSING leaf of the
    default `assistant:` section (per-leaf: an already-present key, at any
    value including a falsy one, is left alone — §6.4/idempotence).

    review r2 fixes: the whole read-decide-write critical section runs under
    `_project_yaml_lock` (cross-process, guards concurrent scaffold runs) and
    all 13 leaves are composed into ONE in-memory text via `set_yaml_text`
    (pure, no disk I/O) before a SINGLE atomic write — never 13 separate
    read-modify-write disk cycles (finding 1: that was reproducibly
    torn-write-corruptible under concurrent scaffolds). A pre-existing
    `assistant:` key that isn't a mapping (e.g. a scalar) is refused up
    front with a specific message and the file is left COMPLETELY untouched
    — no partial insertion is ever attempted against a non-mapping value
    (finding 2).

    Returns (changed, errors) — errors is non-empty only on the refusal
    path above; `changed` is always False when errors is non-empty."""
    path = os.path.join(root, PROJECT_YAML_REL)
    defaults = _default_assistant_section(names, provider, model)

    with _project_yaml_lock(root):
        original = ""
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as fh:
                original = fh.read()

        cfg0 = _parse_text(original)
        existing_assistant = cfg0.get("assistant") if isinstance(cfg0, dict) else None
        if existing_assistant is not None and not isinstance(existing_assistant, dict):
            return False, [
                f"{path}: assistant: is a {type(existing_assistant).__name__}, not a "
                "mapping — refusing to scaffold onto it; fix or remove the existing "
                "key by hand, then re-run"
            ]

        text = original
        changed = False
        for dotpath, value in _leaves("assistant", defaults):
            cfg = _parse_text(text)
            if project_config.dig(cfg, dotpath) is not None:
                continue
            text = project_config.set_yaml_text(text, dotpath.split("."), project_config._yaml_literal(value))
            changed = True

        if not changed:
            return False, []

        # Snapshot/revert floor mirroring apply_setting(): the composed text
        # is validated BEFORE it is ever written — original is untouched on
        # disk this whole time, so an invalid composition is simply never
        # written rather than written-then-reverted.
        cfg_after = _parse_text(text)
        if not isinstance(cfg_after.get("assistant"), dict):
            return False, [f"{path}: scaffold composition did not produce a mapping "
                            "assistant: section — discarded, file untouched"]

        _atomic_write_text(path, text)
        return True, []


# --- brain dirs ---------------------------------------------------------------

def ensure_brain_dirs(root):
    path = os.path.join(root, BRAIN_NOTES_REL)
    existed = os.path.isdir(path)
    os.makedirs(path, exist_ok=True)
    return not existed


# --- persona AGENTS.md (§11.9 generated skills block) --------------------------

def _enabled_capabilities(root):
    path = os.path.join(root, PROJECT_YAML_REL)
    cfg = _load(root, path)
    caps = project_config.dig(cfg, "assistant.capabilities") or {}
    names = []
    if isinstance(caps, dict):
        for name, entry in caps.items():
            if isinstance(entry, dict) and entry.get("enabled") is True:
                names.append(name)
    return sorted(names)


def _skills_block(skill_names):
    if skill_names:
        body = "\n".join(f"- {n}" for n in skill_names)
    else:
        body = "(no capabilities enabled yet — see the `setup-assistant` skill)"
    return f"{GEN_START}\n{body}\n{GEN_END}"


def _replace_or_append_block(text, block):
    lines = text.split("\n")
    out = []
    i = 0
    replaced = False
    while i < len(lines):
        if lines[i].strip() == GEN_START:
            out.extend(block.split("\n"))
            replaced = True
            i += 1
            while i < len(lines) and lines[i].strip() != GEN_END:
                i += 1
            i += 1  # skip the END line itself
            continue
        if lines[i].strip() == GEN_END:
            i += 1  # orphaned END with no matching START: drop the stray delimiter
            continue
        out.append(lines[i])
        i += 1
    if replaced:
        return "\n".join(out)
    # Append: keep existing content (with any orphaned END dropped above —
    # `out`, not the original `text`, is the source of truth here), ensure
    # exactly one blank line then the block.
    base = "\n".join(out).rstrip("\n")
    if base:
        return base + "\n\n" + block + "\n"
    return block + "\n"


def _default_agents_md(main_name, block):
    return (
        f"# {main_name} — assistant persona\n\n"
        f"You are {main_name}, the local assistant for this repository's zettel brain.\n\n"
        f"{block}\n"
    )


def ensure_agents_md(root):
    """Create-if-absent persona AGENTS.md; always regenerate the marker-
    delimited enabled-skills block in place (§11.9), leaving any prose
    outside the markers untouched."""
    path = os.path.join(root, AGENTS_MD_REL)
    cfg_path = os.path.join(root, PROJECT_YAML_REL)
    cfg = _load(root, cfg_path)
    names = project_config.dig(cfg, "assistant.names") or ["assistant"]
    main_name = names[0] if names else "assistant"
    block = _skills_block(_enabled_capabilities(root))

    if not os.path.exists(path):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(_default_agents_md(main_name, block))
        return True

    with open(path, "r", encoding="utf-8") as fh:
        before = fh.read()
    after = _replace_or_append_block(before, block)
    if after != before:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(after)
        return True
    return False


# --- scaffold entrypoint -------------------------------------------------------

def scaffold(root, names=None, provider=None, model=None):
    changed = False
    changed |= ensure_marker(root)
    yaml_changed, yaml_errors = ensure_project_yaml_assistant(
        root, names=names, provider=provider, model=model
    )
    changed |= yaml_changed
    changed |= ensure_brain_dirs(root)
    changed |= ensure_agents_md(root)

    cfg_path = os.path.join(root, PROJECT_YAML_REL)
    cfg = _load(root, cfg_path)
    post_errors = validate_assistant(cfg.get("assistant") or {})
    return {"changed": changed, "errors": list(yaml_errors) + post_errors}


# --- settings editor ------------------------------------------------------------

def apply_setting(root, mutator):
    """Snapshot project.yaml, run mutator(path), validate; revert + return
    errors on failure, else (True, [])."""
    path = os.path.join(root, PROJECT_YAML_REL)
    if not os.path.exists(path):
        return False, [f"{path}: no project.yaml — run setup-assistant scaffold first"]
    with open(path, "r", encoding="utf-8") as fh:
        original = fh.read()
    mutator(path)
    cfg = _load(root, path)
    errors = validate_assistant(cfg.get("assistant") or {})
    if errors:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(original)
        return False, errors
    return True, []


def set_provider(root, provider):
    return apply_setting(root, lambda p: project_config.set_config(p, "assistant.llm.provider", provider))


def set_model(root, model):
    return apply_setting(root, lambda p: project_config.set_config(p, "assistant.llm.model", model))


def enable_capability(root, name):
    ok, errors = apply_setting(
        root, lambda p: project_config.set_config(p, f"assistant.capabilities.{name}.enabled", True)
    )
    if ok:
        ensure_agents_md(root)  # §11.9: keep the generated roster in sync with every flip
    return ok, errors


def disable_capability(root, name):
    ok, errors = apply_setting(
        root, lambda p: project_config.set_config(p, f"assistant.capabilities.{name}.enabled", False)
    )
    if ok:
        ensure_agents_md(root)  # §11.9: keep the generated roster in sync with every flip
    return ok, errors


def set_default(root, name):
    """§6.3 touchpoint: write the machine-local default assistant name into
    neural-view's existing local-state dir (never a tracked file). Wired to
    assistant.default_store (AST-007's single source of truth for the store
    + §7.6 ambiguity resolution) -- kept as a thin root->state_dir adapter so
    this CLI's `set-default <name>` surface stays byte-identical."""
    state_dir = os.environ.get("NEURAL_VIEW_STATE") or os.path.join(root, STATE_DEFAULT_REL)
    return default_store.write_default(name, state_dir=state_dir)


# --- CLI -------------------------------------------------------------------

def _cli(argv):
    # review r2 finding 2: config.py's own CLI prints a clean PREFLIGHT FAIL
    # line on ConfigError (a genuinely malformed, non-empty project.yaml);
    # `_dispatch` below used to let that propagate as a raw traceback.
    try:
        return _dispatch(argv)
    except project_config.ConfigError as e:
        sys.stderr.write(f"PREFLIGHT FAIL: {e}\n")
        return 1
    except default_store.DefaultStoreError as e:
        # AST-007 advisory-scripts-catch-oserror: write_default() already
        # turns an OSError into this clean message -- never let it (or a raw
        # OSError) traceback out of the CLI.
        sys.stderr.write(f"STORE FAIL: {e}\n")
        return 1


def _dispatch(argv):
    if len(argv) < 2:
        sys.stderr.write(
            "usage: setup.py <root> {scaffold|set-provider|set-model|"
            "enable-capability|disable-capability|set-default|validate} [args...]\n"
        )
        return 2
    root, verb = argv[0], argv[1]
    rest = argv[2:]

    if verb == "scaffold":
        name = None
        provider = None
        model = None
        i = 0
        while i < len(rest):
            if rest[i] == "--name" and i + 1 < len(rest):
                name = rest[i + 1]; i += 2
            elif rest[i] == "--provider" and i + 1 < len(rest):
                provider = rest[i + 1]; i += 2
            elif rest[i] == "--model" and i + 1 < len(rest):
                model = rest[i + 1]; i += 2
            else:
                i += 1
        result = scaffold(root, names=[name] if name else None, provider=provider, model=model)
        print("changed" if result["changed"] else "unchanged")
        if result["errors"]:
            for e in result["errors"]:
                sys.stderr.write(f"WARNING: {e}\n")
            return 1  # review r2 finding 2: a refused/invalid composition is a real failure
        return 0

    if verb in ("set-provider", "set-model", "enable-capability", "disable-capability"):
        if not rest:
            sys.stderr.write(f"usage: setup.py <root> {verb} <value>\n")
            return 2
        fn = {
            "set-provider": set_provider,
            "set-model": set_model,
            "enable-capability": enable_capability,
            "disable-capability": disable_capability,
        }[verb]
        ok, errors = fn(root, rest[0])
        if ok:
            print("OK")
            return 0
        for e in errors:
            sys.stderr.write(f"REJECTED: {e}\n")
        return 1

    if verb == "set-default":
        if not rest:
            sys.stderr.write("usage: setup.py <root> set-default <name>\n")
            return 2
        path = set_default(root, rest[0])
        print(path)
        return 0

    if verb == "validate":
        cfg_path = os.path.join(root, PROJECT_YAML_REL)
        cfg = _load(root, cfg_path)
        errors = validate_assistant(cfg.get("assistant") or {})
        if errors:
            for e in errors:
                print(e)
            return 1
        print("VALID")
        return 0

    sys.stderr.write(f"setup.py: unknown verb {verb!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
