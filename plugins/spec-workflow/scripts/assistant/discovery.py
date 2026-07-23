"""Multi-repo assistant discovery scan (SPEC-ASSISTANT.md §7.1, §6.1, §6.2,
AST-020, issue #317).

Per §6.1 the `assistant:` section of project.yaml is the SOLE authority for
assistant identity/enabled state; the `.neural-network` marker is a pure
discovery anchor and its CONTENT can never reject a repo (§6.2's grammar is
deliberately permissive -- see assistant.marker). This module is the one
classifier: `default_store.discover_candidate` (AST-007) delegates to
`classify_repo` below rather than re-implementing the same walk, so there is
exactly one classification code path in the codebase.

Fail-closed: `scan()` never lets an exception escape for a broken sibling
repo -- one repo with an unexpected failure must not take down discovery
for the others (neural-view aggregates many repos at once).

Library:
    Classification(kind, section, detail) -- kind is one of: "candidate",
        "no-marker", "marker-unreadable", "no-config", "config-invalid",
        "no-assistant-section", "section-invalid", "disabled". `section` is
        the parsed `assistant:` dict, set only when kind == "candidate".
        `detail` is a human-readable string for every non-candidate kind
        (e.g. the first validate_assistant() error), None for candidates.

    classify_repo(root) -> Classification
        Classifies a single repo root. Never raises: every failure mode
        (missing/unreadable marker, missing/unparseable config, missing/
        invalid/disabled assistant section) is a Classification, not an
        exception.

    ScanResult(repos, candidates, outcome) -- `repos` is
        [(root, Classification), ...] in the order given; `candidates` is
        [(root, section), ...] filtered to kind == "candidate"; `outcome`
        is "one" | "multiple" | "none" (§7.2-§7.4's branch selector).

    scan(roots) -> ScanResult
        Classifies each root in `roots` (already deduped by the caller).
        No exception from an individual root's classification is allowed to
        escape -- an unexpected failure classifying one root degrades that
        root to a "no-config" Classification (never a candidate) rather
        than aborting the whole scan.
"""
import collections
import os
import sys

_SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# see default_store.py's identical comment: force scripts/ to the FRONT of
# sys.path so `import config` never shadows against assistant/config.py.
if _SCRIPTS_DIR in sys.path:
    sys.path.remove(_SCRIPTS_DIR)
sys.path.insert(0, _SCRIPTS_DIR)

import config as project_config  # noqa: E402  scripts/config.py, the shared loader
from assistant import marker  # noqa: E402
from assistant.config import validate_assistant  # noqa: E402

MARKER_NAME = ".neural-network"

Classification = collections.namedtuple("Classification", ["kind", "section", "detail"])
ScanResult = collections.namedtuple("ScanResult", ["repos", "candidates", "outcome"])


def classify_repo(root):
    marker_path = os.path.join(root, ".claude", MARKER_NAME)
    if not os.path.isfile(marker_path):
        return Classification("no-marker", None, "no .neural-network marker present")

    try:
        marker.read_marker(marker_path)
    except OSError as e:
        # §6.2: marker CONTENT can never reject a repo -- unreadable bytes
        # still classify cleanly, never an exception out of this function.
        return Classification("marker-unreadable", None, f"cannot read marker: {e}")

    cfg_path = project_config.find_config(root)
    if cfg_path is None:
        return Classification("no-config", None, "no project.yaml/.yml/.json found")

    try:
        cfg = project_config.load_config(root=root, path=cfg_path, warn=False)
    except (project_config.ConfigError, OSError) as e:
        return Classification("config-invalid", None, f"cannot load config: {e}")

    section = (cfg or {}).get("assistant")
    if section is None:
        return Classification("no-assistant-section", None, "no 'assistant:' section in config")

    errs = validate_assistant(section)
    if errs:
        return Classification("section-invalid", None, errs[0])

    if section.get("enabled") is not True:
        return Classification("disabled", None, "assistant.enabled is not true")

    return Classification("candidate", section, None)


def scan(roots):
    repos = []
    candidates = []
    for root in roots:
        try:
            c = classify_repo(root)
        except Exception as e:  # noqa: BLE001  -- fail-closed: a broken sibling
            # root must never take down the whole scan; degrade to a clean
            # non-candidate classification instead of propagating.
            c = Classification("no-config", None, f"unexpected error classifying {root!r}: {e}")
        repos.append((root, c))
        if c.kind == "candidate":
            candidates.append((root, c.section))

    if len(candidates) == 1:
        outcome = "one"
    elif len(candidates) > 1:
        outcome = "multiple"
    else:
        outcome = "none"

    return ScanResult(repos=repos, candidates=candidates, outcome=outcome)
