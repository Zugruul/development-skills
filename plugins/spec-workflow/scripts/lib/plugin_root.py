#!/usr/bin/env python3
"""plugin_root.py — shared plugin-root resolver for the spec-workflow
plugin's stdlib-Python scripts.

Precedence (SPEC-CODEX-COMPAT.md §5/§6.3/§6.4; docs/design/cdx-E0.md):
    1. $SPEC_WORKFLOW_PLUGIN_ROOT, if set — validated; invalid -> PluginRootError
       (never silently skipped).
    2. $CLAUDE_PLUGIN_ROOT, if set — same validation, same fail-loud behavior
       (Claude Code's existing fast path; unchanged for a valid value, now
       validated instead of blindly trusted).
    3. Script-relative discovery: starting from this file's own physical
       on-disk location (symlinks resolved via Path.resolve()), walk up
       ancestor directories until one contains .claude-plugin/plugin.json or
       .codex-plugin/plugin.json (the sentinel).
    4. No sentinel found -> PluginRootError.
Never falls back to the current working directory at any step.

Library:
    resolve_plugin_root() -> pathlib.Path
"""
import os
import sys
from pathlib import Path

_SENTINELS = (
    Path(".claude-plugin/plugin.json"),
    Path(".codex-plugin/plugin.json"),
)


class PluginRootError(RuntimeError):
    """Raised when no valid plugin root can be resolved."""


def _is_valid_root(path):
    return path.is_dir() and any((path / s).is_file() for s in _SENTINELS)


def _resolver_dir():
    return Path(__file__).resolve().parent


def resolve_plugin_root():
    for var in ("SPEC_WORKFLOW_PLUGIN_ROOT", "CLAUDE_PLUGIN_ROOT"):
        override = os.environ.get(var)
        if not override:
            continue
        root = Path(override)
        if _is_valid_root(root):
            return root.resolve()
        raise PluginRootError(
            "resolve_plugin_root: ${}='{}' is not a valid plugin root "
            "(missing .claude-plugin/plugin.json or "
            ".codex-plugin/plugin.json)".format(var, override)
        )

    resolver_dir = _resolver_dir()
    d = resolver_dir
    while True:
        if _is_valid_root(d):
            return d
        parent = d.parent
        if parent == d:
            break
        d = parent

    raise PluginRootError(
        "resolve_plugin_root: could not locate a plugin root (no "
        ".claude-plugin/plugin.json or .codex-plugin/plugin.json found "
        "above {}); set $SPEC_WORKFLOW_PLUGIN_ROOT or "
        "$CLAUDE_PLUGIN_ROOT".format(resolver_dir)
    )


if __name__ == "__main__":
    try:
        print(resolve_plugin_root())
    except PluginRootError as exc:
        print(exc, file=sys.stderr)
        sys.exit(1)
