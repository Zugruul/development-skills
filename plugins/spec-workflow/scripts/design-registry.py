#!/usr/bin/env python3
"""design-registry.py -- tag/discoverability/staleness registry for
Iterative UI mode's finalized designs (human-directed task, issue: designs
must be tagged, discoverable by tag, staleness-checked, and actually
followed). Stdlib only.

PROBLEM this closes: iterative-UI mode was enforced by PROSE only --
guard-board-move.sh and preflight.sh had zero references to it, so
finalized designs (AST-083's chat surface, AST-044's trace inspector,
AST-022's switcher, the voice-visualizer rounds) sat unapplied with no
mechanical signal anywhere.

Two metadata sources, merged (a design record can come from either or
both):
  1. AN EMBEDDED BLOCK inside a generated options page:
     `<script type="application/json" id="design-meta">{...}</script>`,
     written once by the ui-options skill at generation time (tags/round/
     createdDate) and updated once at pick time (finalizedOption/
     pickDate) via this script's own `pick` verb. Chosen over meta tags:
     one parseable JSON object beats N separate `<meta>` tags for a LIST
     field (tags), and a `<script type="application/json">` block is
     inert (never executed) and trivially extracted with a single regex
     -- no HTML parser dependency needed for a stdlib-only script.
  2. A SIDECAR file, `docs/ui-options/<designId>.meta.json` -- REQUIRED
     for two cases an embedded block cannot cover: (a) a LEGACY page that
     predates this task and has no block at all (retro-tagged here,
     never edited in place -- see "why sidecar, not in-place edit"
     below), and (b) a design with NO archived page at all (e.g. AST-044:
     landed via issue #330 per CHANGELOG.md, but no docs/ui-options/*.html
     was ever committed for it -- confirmed via `git log --all
     --diff-filter=A --name-only -- docs/ui-options/*`, which shows only
     6 files were EVER added, never one for AST-044). The sidecar is ALSO
     where `applied` state ALWAYS lives, even for a page WITH a block --
     "applied" is a separate, LATER event (the agent implementing the
     design in real code) from "picked" (the human choosing an option),
     and recording it means editing a small JSON sidecar rather than the
     large, already-committed mockup HTML a second time.

Why a sidecar for legacy pages, not an in-place HTML edit (flagged design
call): the 6 existing archived pages are large (55-70KB), hand-crafted
mockup HTML the ui-options skill's own audit already validated; splicing
a new script block into each via a text edit risks corrupting carefully
balanced markup for zero behavioral gain (the mockup itself doesn't need
to change, only its registry metadata does). A sidecar is a clean,
git-diffable, zero-risk file next to the page it describes.

Worktree visibility (real incident, 2026-07-28 -- a dev lane on the
trace-inspector task searched for its binding design, found nothing, and
concluded no design existed): `.claude/ui-hub/` is GITIGNORED scratch
state, and `ui-hub.py` writes it under `<its own invoking checkout's git
root>/.claude/ui-hub` -- so a page asked while running from the MAIN
checkout is invisible to a session running from a linked WORKTREE, whose
own `.claude/ui-hub/` is empty (worktrees never share an untracked
directory). This registry resolves `LIVE_HTML_DIR` against the repo's
SHARED root (`git rev-parse --path-format=absolute --git-common-dir`'s
parent -- the one git dir every worktree of a repo has in common, unlike
`--show-toplevel` which returns each worktree's own path) specifically so
a lane working inside its own task worktree can still find and read a
design that was asked from the main checkout. `docs/ui-options/` stays
resolved against the INVOKING checkout's own root (not the shared root)
because it is tracked and branch-relative: a design just backfilled on
this very branch has not merged into the main checkout yet, and treating
tracked files as shared-root-relative would make them invisible from the
worktree that is actively adding them. `ui-hub.py` itself still has the
matching write-side bug (a page asked from inside a worktree still lands
in that worktree's own gitignored scratch dir, not the shared one) --
out of scope here (this task is scripts+skills around the REGISTRY, not
the hub itself), flagged as a likely-related follow-up.

Hub-only finalized designs (requirement, this same incident): a
FINALIZED design whose only page lives in the gitignored hub, never
archived into tracked `docs/ui-options/`, is itself a version of the
same problem -- one accidental `git clean`/lost hub state away from
losing the finalized mockup entirely, and invisible to anyone not running
from wherever the hub happens to be. `pick` and `backfill` both now
auto-archive a hub-only page's current bytes into
`docs/ui-options/<id>[-r<N>].html` (see `_archive_path` -- same
round-aware naming as `_sidecar_path`, for the identical collision reason
its own docstring gives) the moment a design becomes finalized, and any
record `_format_record_line` still finds hub-only-and-finalized (e.g. an
existing sidecar declaring no page, or an explicit `page` that resolves
under the hub) prints an `ANOMALY=hub-only-not-archived` marker so it
surfaces in `index`/`find`/`staleness` output rather than staying a silent
gap.

Tag -> governed-paths mapping (flagged design call): HAND-MAINTAINED
(`TAG_PATH_MAP` below), never derived from a page's own declared paths.
This is a DECISION (which files a UI surface actually lives in), not a
FACT the filesystem can tell you -- the same house distinction issue
#447's BASE_CAPABILITIES registry already applies (a reviewed, static
list beats an auto-scanned one for anything that's a decision, not a
derivable fact). Today every mapped tag points at the SAME file
(`plugins/spec-workflow/templates/neural-view.html`) because that
template is genuinely one monolithic single-page app covering chat,
voice, the trace inspector, and the assistant switcher all at once (no
per-surface file split exists yet) -- so staleness is FILE-granularity,
not line-range, for v1. A future template split could sharpen this
without changing the registry's own shape.

Staleness anchor (flagged design call, genuinely two-way -- see the
`applied <id>`-verb docstring below for the reasoning): compares against
the APPLIED commit when one is recorded (the point after which an
unreviewed change to the governed paths is suspect), falling back to the
pick date only when a design is applied via a bare note (no commit hash
to anchor on). Comparing against the pick date UNCONDITIONALLY (the
literal, simpler reading) has a real paradox: the very commit that
APPLIES a finalized design is itself a change to the governed paths dated
after the pick -- so a design would read STALE the instant it's applied,
which defeats the whole point of the `applied` verb.

Verbs:
    index                    Scan both dirs (docs/ui-options/,
                              .claude/ui-hub/html/ when present) + sidecar
                              files; print every discovered design record
                              (id, round, tags, finalized state, page).
                              Stateless -- rescans on every call (this
                              codebase's consistent read-path posture,
                              e.g. capability_index.compile_index/
                              tasks.list_tasks) rather than maintaining a
                              separate cache file that could go stale.
    find --tags a,b           Every design matching ANY of the given tags
                               -- id, round, tags, finalized option (or
                               DRAFT/UNDECIDED), path, staleness.
    staleness [id]             FRESH / STALE (<what changed>) / UNAPPLIED
                               for one design (by id, optionally
                               `-r<N>`) or every finalized design.
    applied <id> <commit-or-note> [--date YYYY-MM-DD]
                               Records that a design was applied --
                               writes/updates its sidecar's `applied`
                               field. `commit-or-note`: a value that
                               matches a short/full git commit hash
                               pattern is treated as a commit (staleness
                               anchors on it); anything else is a plain
                               note (staleness falls back to pickDate).
    pick <id> <option> [--date YYYY-MM-DD]
                               Records the human's final option pick --
                               updates the page's embedded block in place
                               (finalizedOption/pickDate) if the design
                               has a page with a block, else the sidecar.
    backfill <id> --tags a,b [--page PATH] [--finalized OPT]
             [--pick-date DATE] [--applied-commit SHA]
             [--applied-note NOTE] [--created-date DATE] [--issue N]
                               One-shot: writes/updates a sidecar for a
                               LEGACY design (id has no embedded block).
                               Idempotent -- re-running with the same
                               arguments produces byte-identical output.
    for-issue <N>              Every design record whose `issue` field
                               (a board issue number, set by ui-options at
                               generation time or via `backfill --issue`)
                               matches N -- the mechanical-enforcement
                               query `design-registry-preflight.sh` reads
                               before a move to In review (issue #461).
"""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import date

def _detect_root():
    """`DESIGN_REGISTRY_ROOT` overrides (hermetic tests point it at a
    fixture directory instead of the real repo -- the same override
    convention `ui-hub.py`'s `UI_HUB_STATE` already uses); otherwise the
    real git toplevel, falling back to cwd if this isn't a git repo at
    all (never raises). Always `realpath`d: macOS resolves `/tmp` to
    `/private/tmp`, and `git rev-parse --path-format=absolute` (used by
    `_shared_root` below) returns the REALPATH form -- an un-resolved
    `ROOT` (e.g. a raw `/tmp/...` `DESIGN_REGISTRY_ROOT` override, or a
    non-canonical `--show-toplevel`) mixed with a resolved `SHARED_ROOT`
    breaks `os.path.relpath`/`startswith` path math (a real bug this
    task's own worktree-visibility fixture caught: a hermetic test's
    `mktemp -d` path, un-resolved, produced garbage `../../../../..`
    relative paths against the resolved hub path). Canonicalizing both
    roots here keeps every downstream path comparison consistent."""
    env = os.environ.get("DESIGN_REGISTRY_ROOT")
    if env:
        return os.path.realpath(env)
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=False
    )
    toplevel = out.stdout.strip()
    return os.path.realpath(toplevel) if toplevel else os.path.realpath(os.getcwd())


def _shared_root(root):
    """The repo's MAIN checkout root, even when `root` (the invoking
    checkout) is a linked worktree -- see the module docstring's "Worktree
    visibility" section. `git -C root rev-parse --path-format=absolute
    --git-common-dir` returns the ONE `.git` directory every worktree of a
    repo shares (a worktree's own `.git` is a stub file pointing back at
    it); its parent is the main checkout in the normal, non-bare case.
    Runs git with `-C root` rather than relying on process cwd so this
    also resolves correctly under `DESIGN_REGISTRY_ROOT` test overrides
    (hermetic tests point `root` at a real, disposable git worktree
    fixture). Falls back to `root` itself -- not a worktree, git
    unavailable, or an unrecognized `--git-common-dir` shape -- so a
    plain (non-worktree) clone is unaffected. `root` is expected to
    already be `realpath`d (see `_detect_root`); the candidate is
    `realpath`d too, so the two roots stay in the same canonical form."""
    out = subprocess.run(
        ["git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, text=True, check=False,
    )
    common_dir = out.stdout.strip()
    if not common_dir:
        return root
    candidate = os.path.dirname(common_dir.rstrip(os.sep))
    return os.path.realpath(candidate) if os.path.isdir(candidate) else root


ROOT = _detect_root()
SHARED_ROOT = _shared_root(ROOT)

UI_OPTIONS_DIR = os.path.join(ROOT, "docs", "ui-options")
LIVE_HTML_DIR = os.path.join(SHARED_ROOT, ".claude", "ui-hub", "html")

_META_BLOCK_RE = re.compile(
    r'<script[^>]*\bid="design-meta"[^>]*>(.*?)</script>', re.DOTALL
)

# Every tag this registry currently knows about, mapped to the file(s) it
# governs. Hand-maintained (see module docstring) -- add a line here
# whenever a new UI surface/tag is introduced.
TAG_PATH_MAP = {
    "chat": ["plugins/spec-workflow/templates/neural-view.html"],
    "chat-composer": ["plugins/spec-workflow/templates/neural-view.html"],
    "chat-instance": ["plugins/spec-workflow/templates/neural-view.html"],
    "trace-inspector": ["plugins/spec-workflow/templates/neural-view.html"],
    "voice-visualizer": ["plugins/spec-workflow/templates/neural-view.html"],
    "assistant-picker": ["plugins/spec-workflow/templates/neural-view.html"],
    "assistant-switcher": ["plugins/spec-workflow/templates/neural-view.html"],
    "artifact-panel": ["plugins/spec-workflow/templates/neural-view.html"],
}

# FAIL SAFE, not open (review round 2 MUST FIX): `TAG_PATH_MAP.get(tag, [])`
# used to hand an UNMAPPED tag zero governed paths, which made
# `compute_staleness` read "nothing mapped to check" and print FRESH -- the
# exact #447 decay shape, but in the direction that HIDES a problem (a typo'd
# or newly introduced tag silently drops its design out of every staleness
# warning, instead of loudly failing). Every tag mapped today points at the
# SAME file, so an unmapped tag defaults to that same file rather than to
# nothing -- if that default is ever wrong for a genuinely new UI surface,
# the FIX is to add a real TAG_PATH_MAP entry, not to silently check
# nothing.
_DEFAULT_GOVERNED_PATHS = ["plugins/spec-workflow/templates/neural-view.html"]

_COMMIT_RE = re.compile(r"^[0-9a-f]{7,40}$")


def _today():
    return date.today().isoformat()


def _sidecar_path(design_id, round_=1, root=ROOT):
    """`<id>.meta.json` for round 1 (backward-compatible with every
    single-round design already backfilled), `<id>-r<N>.meta.json` for
    round N>1 -- a real bug this task's own backfill run caught: without
    the round in the filename, three rounds of the SAME designId (e.g.
    voice-visualizer r1/r2/r3) all collided on one sidecar path, each
    backfill silently overwriting the previous round's record."""
    suffix = "" if round_ == 1 else f"-r{round_}"
    return os.path.join(root, "docs", "ui-options", f"{design_id}{suffix}.meta.json")


def _archive_path(design_id, round_=1, root=ROOT):
    """Tracked archive-copy path for a design page, under `docs/ui-options/`
    -- same round-aware naming as `_sidecar_path` (bare `<id>.html` for
    round 1, `<id>-r<N>.html` for round N>1), so archiving a hub-only page
    does not repeat the exact filename-collision bug `_sidecar_path`'s own
    docstring describes for multi-round designs."""
    suffix = "" if round_ == 1 else f"-r{round_}"
    return os.path.join(root, "docs", "ui-options", f"{design_id}{suffix}.html")


def _classify_page_source(page_rel, root=ROOT):
    """Given a page path relative to `root` (e.g. a sidecar's explicitly
    declared `page` field), says whether it resolves under the gitignored
    hub or the tracked archive dir. Returns None for anything else
    (unrecognized location -- never guessed at)."""
    if not page_rel:
        return None
    abs_path = os.path.normpath(os.path.join(root, page_rel))
    if abs_path.startswith(os.path.normpath(LIVE_HTML_DIR) + os.sep):
        return "hub"
    if abs_path.startswith(os.path.normpath(UI_OPTIONS_DIR) + os.sep):
        return "tracked"
    return None


def _locate_page(design_id, round_=1, root=ROOT):
    """Auto-detects a design's page when nothing declared one explicitly
    (a sidecar's own `page` field always wins over this -- callers only
    reach here when it is unset). Prefers a TRACKED archive copy over the
    ephemeral hub copy; the hub's own filename convention is always
    `<id>-r<N>.html` (`ui-hub.py`'s `ask <id>-r<N> ...` -- round baked
    into the round-qualified id itself, even for round 1). Returns
    (relpath-from-root, "tracked"|"hub") or (None, None)."""
    tracked_candidate = _archive_path(design_id, round_, root=root)
    if os.path.isfile(tracked_candidate):
        return os.path.relpath(tracked_candidate, root), "tracked"
    hub_candidate = os.path.join(LIVE_HTML_DIR, f"{design_id}-r{round_}.html")
    if os.path.isfile(hub_candidate):
        return os.path.relpath(hub_candidate, root), "hub"
    return None, None


def _archive_hub_page(design_id, round_, page_rel, page_source, root=ROOT):
    """Copies a hub-only page's current bytes into the tracked
    `docs/ui-options/` archive path -- the "archival is part of the flow"
    requirement, called from `pick` (a design just finalized) and
    `backfill` (a legacy design retro-finalized). No-op (returns None)
    when the page is not hub-sourced, there is no page, or a tracked copy
    already exists at the destination (never overwrites)."""
    if page_source != "hub" or not page_rel:
        return None
    dest_abs = _archive_path(design_id, round_, root=root)
    if os.path.isfile(dest_abs):
        return None
    src_abs = os.path.join(root, page_rel)
    with open(src_abs, "r", encoding="utf-8") as fh:
        content = fh.read()
    os.makedirs(os.path.dirname(dest_abs), exist_ok=True)
    with open(dest_abs, "w", encoding="utf-8") as fh:
        fh.write(content)
    return os.path.relpath(dest_abs, root)


def _read_json(path):
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")


def read_page_meta(html_path):
    """Extracts and parses the `<script id="design-meta">` JSON block
    from a generated options page. Returns `None` (never raises) for a
    missing file, a page with no block at all (every legacy page, by
    definition), or a block that fails to parse -- a malformed/absent
    block degrades to "no page-embedded metadata", never a crash."""
    try:
        with open(html_path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return None
    m = _META_BLOCK_RE.search(text)
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except ValueError:
        return None


def write_page_meta(html_path, meta):
    """In-place rewrite of the embedded block's JSON content (used by
    `pick`). Returns True if a block was found and rewritten, False if
    the page has none (caller falls back to the sidecar)."""
    with open(html_path, "r", encoding="utf-8") as fh:
        text = fh.read()
    m = _META_BLOCK_RE.search(text)
    if not m:
        return False
    new_block = f'<script type="application/json" id="design-meta">{json.dumps(meta, sort_keys=True)}</script>'
    text = text[: m.start()] + new_block + text[m.end():]
    with open(html_path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return True


def _iter_html_pages():
    """Yields (path, source) -- UI_OPTIONS_DIR (tracked) first, then
    LIVE_HTML_DIR (hub), so a tracked archive copy always wins as the
    base record when both exist for the same design+round (see
    `discover`)."""
    for d, source in ((UI_OPTIONS_DIR, "tracked"), (LIVE_HTML_DIR, "hub")):
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.endswith(".html"):
                yield os.path.join(d, name), source


def _iter_sidecars():
    if not os.path.isdir(UI_OPTIONS_DIR):
        return
    for name in sorted(os.listdir(UI_OPTIONS_DIR)):
        if name.endswith(".meta.json"):
            yield os.path.join(UI_OPTIONS_DIR, name)


def _record_key(meta):
    return (meta.get("designId"), meta.get("round", 1))


def _base_record(meta, page, page_source=None):
    return {
        "designId": meta.get("designId"),
        "round": meta.get("round", 1),
        "tags": list(meta.get("tags") or []),
        "createdDate": meta.get("createdDate"),
        "finalizedOption": meta.get("finalizedOption"),
        "pickDate": meta.get("pickDate"),
        "applied": meta.get("applied"),
        "page": page,
        "pageSource": page_source,
        # Which board issue this design belongs to (optional, string form --
        # matches telemetry.py/two-pass-review-preflight.sh's own "task" is
        # a plain issue-number string convention). Written into the embedded
        # block by the ui-options skill at generation time (it already knows
        # the issue number in context); historical/legacy designs predate
        # this field and simply have none -- `for-issue`/the mechanical
        # guard below can only enforce what a design actually declares.
        "issue": meta.get("issue"),
    }


def discover():
    """One pass over both html dirs + every sidecar -> (records, failures).
    `records` is the list of merged design records (never persisted --
    see module docstring's `index` entry). Order: page-embedded blocks
    first (so a page's own metadata is the base record), then sidecars
    merge IN (attaching to a matching page by id+round, or standing
    alone for a pageless design), with a sidecar's `applied` always
    winning if both a block and a sidecar declare one (the sidecar is
    the ALWAYS-current source for that field, per the module docstring).

    `failures` is the list of sidecar paths that EXIST but could not be
    parsed (review round 4, finding 1). _iter_sidecars() only ever
    yields paths that are real files on disk, so a None from _read_json
    here is always a parse failure (OSError/ValueError), never
    "missing" -- fail SAFE by recording it rather than silently
    `continue`-ing past a design that might be the one governing
    whatever a caller is asking about (a sidecar-only record, e.g. a
    legacy page with no embedded block, vanishes from `records`
    entirely on a parse failure, indistinguishable from "never
    registered" unless a caller checks `failures`). `cmd_for_issue` and
    `design-registry-preflight.sh` are the callers that actually act on
    this; every other verb below discards it -- deliberately: this
    finding's reproduction and the mechanical-enforcement contract are
    both specific to the for-issue/preflight path (see cmd_for_issue's
    own docstring)."""
    records = {}
    failures = []
    for html_path, source in _iter_html_pages():
        meta = read_page_meta(html_path)
        if not meta or not meta.get("designId"):
            continue
        key = _record_key(meta)
        if key in records and records[key].get("pageSource") == "tracked":
            continue  # a tracked archive copy already won this key -- never let the hub's ephemeral copy replace it
        records[key] = _base_record(meta, os.path.relpath(html_path, ROOT), source)

    for sidecar_path in _iter_sidecars():
        meta = _read_json(sidecar_path)
        if meta is None:
            failures.append(sidecar_path)
            continue
        if not meta.get("designId"):
            continue
        key = _record_key(meta)
        if key in records:
            if meta.get("applied") is not None:
                records[key]["applied"] = meta["applied"]
            # A sidecar attached to an EXISTING page-derived record may
            # also be the ONLY source of tags for a legacy page whose
            # embedded block (if the page even has one) is absent --
            # already handled since such a page never got INTO
            # `records` via read_page_meta in that case; this branch is
            # for a sidecar co-existing with a real block, applied-only.
        else:
            page = meta.get("page")
            if page is not None:
                page_source = _classify_page_source(page)
            else:
                page, page_source = _locate_page(meta["designId"], meta.get("round", 1))
            records[key] = _base_record(meta, page, page_source)

    return sorted(records.values(), key=lambda r: (r["designId"] or "", r["round"] or 0)), failures


def _matches_tags(record, wanted):
    return bool(set(record["tags"]) & set(wanted))


def _git_log_since_commit(paths, commit):
    """Short subject lines for every commit touching `paths` strictly
    after `commit` (never including `commit` itself -- `commit..HEAD`).
    Returns [] (never raises) if `commit` is not a valid ref in this
    repo, or nothing changed -- both read as "nothing to report", the
    caller's job to classify that as FRESH vs a resolution failure."""
    try:
        out = subprocess.run(
            ["git", "log", "--oneline", f"{commit}..HEAD", "--", *paths],
            cwd=ROOT, capture_output=True, text=True, check=False, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if out.returncode != 0:
        return []
    return [line for line in out.stdout.splitlines() if line.strip()]


def _git_log_since_date(paths, since_date):
    if not since_date:
        return []
    try:
        out = subprocess.run(
            ["git", "log", "--oneline", f"--since={since_date}", "--", *paths],
            cwd=ROOT, capture_output=True, text=True, check=False, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if out.returncode != 0:
        return []
    return [line for line in out.stdout.splitlines() if line.strip()]


def governed_paths(tags):
    paths = []
    for tag in tags:
        for p in TAG_PATH_MAP.get(tag, _DEFAULT_GOVERNED_PATHS):
            if p not in paths:
                paths.append(p)
    return paths


def compute_staleness(record):
    """Returns (state, detail) -- state in {"DRAFT", "UNAPPLIED",
    "STALE", "FRESH"}; `detail` is a list of short commit lines for
    STALE, `None` otherwise. See module docstring's "Staleness anchor"
    section for the applied-commit-vs-pick-date precedence.

    APPLIED-vs-DRAFT (review round 2 MUST FIX): a design can be APPLIED
    with the specific option unknown (the voice-visualizer rounds -- the
    commit that applied each round is on record, but which option letter
    it used is not, per the module docstring's backfill notes). That is a
    genuinely different state from NEVER DECIDED AT ALL, and the two must
    not collapse to the same "DRAFT" bucket: an applied design should
    still get real STALE/FRESH staleness checking against its `applied`
    commit, exactly like a finalized-and-applied one -- `finalizedOption`
    being unset does not mean nothing is known about this design's state
    in the codebase. Only a record with NEITHER a pick NOR an apply is a
    true DRAFT."""
    applied = record.get("applied")
    if not record.get("finalizedOption") and not applied:
        return "DRAFT", None
    if not applied:
        return "UNAPPLIED", None
    paths = governed_paths(record["tags"])
    if not paths:
        return "FRESH", None  # nothing mapped to check -- never a crash
    commit = applied.get("commit") if isinstance(applied, dict) else None
    if commit:
        changed = _git_log_since_commit(paths, commit)
    else:
        changed = _git_log_since_date(paths, record.get("pickDate"))
    if changed:
        return "STALE", changed
    return "FRESH", None


def _format_record_line(record):
    state, detail = compute_staleness(record)
    if state == "STALE" and detail:
        state_str = "STALE (" + "; ".join(detail[:3]) + (" ..." if len(detail) > 3 else "") + ")"
    else:
        state_str = state
    finalized = record.get("finalizedOption")
    if not finalized:
        finalized = "APPLIED (option unknown)" if record.get("applied") else "DRAFT/UNDECIDED"
    line = (
        f"{record['designId']} r{record['round']} "
        f"tags=[{','.join(record['tags'])}] "
        f"finalized={finalized} "
        f"page={record.get('page') or '(none)'} "
        f"staleness={state_str}"
    )
    if record.get("finalizedOption") and record.get("pageSource") == "hub":
        line += " ANOMALY=hub-only-not-archived"
    return line


def cmd_index(_args):
    records, _sidecar_failures = discover()
    if not records:
        print("design-registry: no designs discovered")
        return 0
    for r in records:
        print(_format_record_line(r))
    return 0


def cmd_find(args):
    wanted = [t.strip() for t in args.tags.split(",") if t.strip()]
    if not wanted:
        print("design-registry find: --tags must name at least one tag")
        return 2
    all_records, _sidecar_failures = discover()
    records = [r for r in all_records if _matches_tags(r, wanted)]
    if not records:
        print(f"design-registry: no design matches tags {wanted}")
        return 0
    for r in records:
        print(_format_record_line(r))
    return 0


def cmd_for_issue(args):
    """The mechanical-enforcement query (issue #461 / the "make it
    mechanical, not prose" fix): every design record whose `issue` field
    matches the given board issue number, as a plain string compare (same
    convention as telemetry.py/two-pass-review-preflight.sh's own `task`
    field -- a board issue number, never a spec taskId like `AST-083`).
    `design-registry-preflight.sh` is this verb's only real caller.

    Corrupt-sidecar contract (review round 4, finding 1 -- live
    reproduction: corrupt docs/ui-options/AST-069.meta.json, this verb
    used to print "no design registered for issue #344" at rc=0,
    indistinguishable from the genuinely-clean case). `discover()` can
    report sidecars it could not parse; a sidecar-only record vanishes
    from its `records` entirely on a parse failure, so we can no longer
    claim "nothing registered" with any confidence when that happens --
    doing so would silently un-register whatever enforcement the
    unreadable design was supposed to carry. So: any REAL matches found
    are always printed (never hidden), but the "no design registered"
    claim is suppressed whenever failures exist, a WARNING naming every
    unreadable sidecar is printed instead, and the exit code is 3 -- a
    THIRD state distinct from both 0 (clean) and a genuine crash
    (nonzero, but never 3). design-registry-preflight.sh reads rc=3
    specifically to BLOCK the move rather than take its ordinary
    fail-open crash path (that path is for "the tool itself is broken"
    and fails open ON PURPOSE; an unreadable sidecar is "the tool ran
    fine but found a specific record it can't trust", a different
    failure class entirely -- see that script's own comment)."""
    records, failures = discover()
    matches = [r for r in records if str(r.get("issue")) == str(args.issue)]
    for r in matches:
        print(_format_record_line(r))
    if failures:
        rels = ", ".join(os.path.relpath(f, ROOT) for f in failures)
        print(
            f"WARNING: {len(failures)} sidecar(s) unreadable ({rels}) -- "
            f"cannot confirm no design blocks issue #{args.issue}",
            file=sys.stderr,
        )
        return 3
    if not matches:
        print(f"design-registry: no design registered for issue #{args.issue}")
    return 0


def _resolve_id(id_arg, records):
    """Splits a trailing `-r<N>` off `id_arg` if present; otherwise
    matches the HIGHEST round found for that bare designId (the
    presumably-current one) -- lets every verb accept either
    `AST-083` or `AST-083-r2` (the exact-round form)."""
    m = re.match(r"^(.*)-r(\d+)$", id_arg)
    if m:
        return m.group(1), int(m.group(2))
    matching = [r for r in records if r["designId"] == id_arg]
    if not matching:
        return id_arg, None
    best = max(matching, key=lambda r: r["round"])
    return id_arg, best["round"]


def cmd_staleness(args):
    records, _sidecar_failures = discover()
    if args.id:
        design_id, round_ = _resolve_id(args.id, records)
        matching = [r for r in records if r["designId"] == design_id and r["round"] == round_]
        if not matching:
            print(f"design-registry: no such design {args.id!r}")
            return 1
        records = matching
    else:
        # Outstanding = anything with a real decision on record -- a pick
        # (finalizedOption) OR an apply (applied, even option-unknown).
        # Narrowing to finalizedOption only (the original filter) silently
        # dropped applied-but-undecided designs like voice-visualizer out
        # of every no-id `staleness` call, INCLUDING preflight.sh's own
        # WARN scan -- the exact collapse this fix closes.
        records = [r for r in records if r.get("finalizedOption") or r.get("applied")]
    if not records:
        print("design-registry: nothing to report")
        return 0
    for r in records:
        print(_format_record_line(r))
    return 0


def cmd_applied(args):
    records, _sidecar_failures = discover()
    design_id, round_ = _resolve_id(args.id, records)
    if round_ is None:
        round_ = 1
    sidecar_path = _sidecar_path(design_id, round_)
    existing = _read_json(sidecar_path) or {}
    matching = [r for r in records if r["designId"] == design_id and r["round"] == round_]
    base = matching[0] if matching else {"designId": design_id, "round": round_, "tags": [], "createdDate": None, "finalizedOption": None, "pickDate": None}
    merged = {**base, **existing}
    is_commit = bool(_COMMIT_RE.match(args.commit_or_note))
    merged["applied"] = {
        "commit": args.commit_or_note if is_commit else None,
        "note": None if is_commit else args.commit_or_note,
        "appliedDate": args.date or _today(),
    }
    merged.pop("page", None)  # sidecar never re-declares page unless it's pageless (see backfill)
    if not matching:
        candidate = os.path.join(UI_OPTIONS_DIR, f"{design_id}.html")
        merged["page"] = os.path.relpath(candidate, ROOT) if os.path.isfile(candidate) else None
    _write_json(sidecar_path, merged)
    print(f"design-registry: recorded applied for {design_id} r{round_}: {merged['applied']}")
    return 0


def cmd_pick(args):
    records, _sidecar_failures = discover()
    design_id, round_ = _resolve_id(args.id, records)
    if round_ is None:
        round_ = 1
    matching = [r for r in records if r["designId"] == design_id and r["round"] == round_]
    pick_date = args.date or _today()
    page_rel = matching[0]["page"] if matching else None
    page_source = matching[0].get("pageSource") if matching else None
    if page_rel:
        page_abs = os.path.join(ROOT, page_rel)
        meta = read_page_meta(page_abs)
        if meta is not None:
            meta["finalizedOption"] = args.option
            meta["pickDate"] = pick_date
            if write_page_meta(page_abs, meta):
                archived_rel = _archive_hub_page(design_id, round_, page_rel, page_source)
                note = f"; archived a tracked copy to {archived_rel} (was hub-only)" if archived_rel else ""
                print(f"design-registry: recorded pick for {design_id} r{round_} in page {page_rel}{note}")
                return 0
    # No page, the page has no block (e.g. a legacy hub page), or the
    # page-block write path above was skipped -- fall back to the
    # sidecar. Archive a hub-only page here too: a legacy page never gets
    # an embedded block written into it (see module docstring's "sidecar,
    # not in-place edit"), so this is the ONLY path AST-021/AST-044-style
    # designs (finalized long before this registry existed, page only
    # ever in the hub) go through when re-picked/backfilled.
    archived_rel = _archive_hub_page(design_id, round_, page_rel, page_source) if page_rel else None
    sidecar_path = _sidecar_path(design_id, round_)
    existing = _read_json(sidecar_path) or {}
    base = matching[0] if matching else {"designId": design_id, "round": round_, "tags": [], "createdDate": None, "applied": None}
    merged = {**base, **existing}
    merged.pop("pageSource", None)
    merged["finalizedOption"] = args.option
    merged["pickDate"] = pick_date
    if archived_rel:
        merged["page"] = archived_rel
    elif page_rel and "page" not in existing:
        merged["page"] = page_rel
    _write_json(sidecar_path, merged)
    note = f"; archived a tracked copy to {archived_rel} (was hub-only)" if archived_rel else ""
    print(f"design-registry: recorded pick for {design_id} r{round_} in sidecar (no page block){note}")
    return 0


def cmd_backfill(args):
    tags = [t.strip() for t in args.tags.split(",") if t.strip()]
    if not tags:
        print("design-registry backfill: --tags must name at least one tag")
        return 2
    page = args.page
    page_source = None
    if page is not None:
        page_source = _classify_page_source(page)
    else:
        page, page_source = _locate_page(args.id, args.round)
    archived_rel = None
    if args.finalized and page_source == "hub":
        archived_rel = _archive_hub_page(args.id, args.round, page, page_source)
        if archived_rel:
            page = archived_rel
    sidecar_path = _sidecar_path(args.id, args.round)
    record = {
        "designId": args.id,
        "round": args.round,
        "tags": tags,
        "createdDate": args.created_date,
        "finalizedOption": args.finalized,
        "pickDate": args.pick_date,
        "applied": None,
        "page": page,
        "issue": args.issue,
    }
    if args.applied_commit or args.applied_note:
        record["applied"] = {
            "commit": args.applied_commit,
            "note": args.applied_note,
            "appliedDate": args.applied_date,
        }
    _write_json(sidecar_path, record)
    note = f"; archived a tracked copy to {archived_rel} (was hub-only)" if archived_rel else ""
    print(f"design-registry: backfilled {args.id} -> {sidecar_path}{note}")
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="design-registry.py")
    sub = p.add_subparsers(dest="verb", required=True)

    sub.add_parser("index").set_defaults(func=cmd_index)

    sp = sub.add_parser("find")
    sp.add_argument("--tags", required=True)
    sp.set_defaults(func=cmd_find)

    sp = sub.add_parser("staleness")
    sp.add_argument("id", nargs="?")
    sp.set_defaults(func=cmd_staleness)

    sp = sub.add_parser("applied")
    sp.add_argument("id")
    sp.add_argument("commit_or_note")
    sp.add_argument("--date")
    sp.set_defaults(func=cmd_applied)

    sp = sub.add_parser("pick")
    sp.add_argument("id")
    sp.add_argument("option")
    sp.add_argument("--date")
    sp.set_defaults(func=cmd_pick)

    sp = sub.add_parser("backfill")
    sp.add_argument("id")
    sp.add_argument("--tags", required=True)
    sp.add_argument("--round", type=int, default=1)
    sp.add_argument("--page")
    sp.add_argument("--finalized")
    sp.add_argument("--pick-date", dest="pick_date")
    sp.add_argument("--created-date", dest="created_date")
    sp.add_argument("--applied-commit", dest="applied_commit")
    sp.add_argument("--applied-note", dest="applied_note")
    sp.add_argument("--applied-date", dest="applied_date")
    sp.add_argument("--issue")
    sp.set_defaults(func=cmd_backfill)

    sp = sub.add_parser("for-issue")
    sp.add_argument("issue")
    sp.set_defaults(func=cmd_for_issue)

    return p


def main(argv):
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
