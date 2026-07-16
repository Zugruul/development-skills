#!/usr/bin/env python3
"""local_state.py — reader for scripts/local-state.manifest, the single source of
truth for which plugin-written runtime paths are gitignored local state
(``ignore``) vs tracked shared memory (``track``) — SPEC-MEMORY.md §7.1/§7.4/§9.2.
Python stdlib only.

Manifest format: one ``<policy>\\t<path>`` record per line; ``#``-comment and
blank lines are ignored (see the manifest header).

Library:
    manifest_path() -> Path
    records(manifest=None) -> list[(policy, path)]   # manifest order
    paths(policy, manifest=None) -> list[str]
    ignore_paths(manifest=None) / track_paths(manifest=None) -> list[str]
    policy_of(path, manifest=None) -> str | None      # exact-match

CLI: ``python3 local_state.py <ignore|track>`` prints that policy's paths.
"""
import sys
from pathlib import Path

_MANIFEST = Path(__file__).resolve().parent.parent / "local-state.manifest"


def manifest_path():
    return _MANIFEST


def records(manifest=None):
    p = Path(manifest) if manifest else _MANIFEST
    out = []
    for raw in p.read_text().splitlines():
        if not raw or raw.startswith("#"):
            continue
        policy, _, path = raw.partition("\t")
        if path:
            out.append((policy, path))
    return out


def paths(policy, manifest=None):
    return [path for pol, path in records(manifest) if pol == policy]


def ignore_paths(manifest=None):
    return paths("ignore", manifest)


def track_paths(manifest=None):
    return paths("track", manifest)


def policy_of(path, manifest=None):
    for pol, p in records(manifest):
        if p == path:
            return pol
    return None


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("ignore", "track"):
        print("usage: local_state.py <ignore|track>", file=sys.stderr)
        sys.exit(2)
    print("\n".join(paths(sys.argv[1])))
