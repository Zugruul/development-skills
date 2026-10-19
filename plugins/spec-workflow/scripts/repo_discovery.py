"""Shared, read-only immediate-child scan; callers own inclusion and dedup policy."""
from pathlib import Path

from config import CONFIG_DIR


def scan_anchored_repos(scan_base):
    """Return lexical child paths carrying the canonical anchor directory.

    Keep symlink spellings for the viewer's display names. Each caller decides
    how to deduplicate resolved paths and whether to include an explicit root.
    Unreadable bases or children are excluded without aborting other children.
    """
    base = Path(scan_base)
    try:
        children = sorted(base.iterdir()) if base.is_dir() else []
    except OSError:
        return []
    found = []
    for child in children:
        try:
            if child.is_dir() and (child / CONFIG_DIR).is_dir():
                found.append(child)
        except OSError:
            continue
    return found
