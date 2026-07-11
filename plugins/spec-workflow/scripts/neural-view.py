#!/usr/bin/env python3
"""neural-view.py — a live, JARVIS-style visualization of the identity brains,
aggregated across every spec-workflow repo on the machine.

The identities' brains are the workflow's memory: markdown notes ("neurons")
wired by weighted links ("synapses"), with an append-only activation log of
every recall. This is a read-only window into them — one long-lived page
(http://127.0.0.1:<port>) that draws every brain as a neural cluster and, as
recalls happen, lights the neurons up and pulses the synapses in real time.
Repos are laid out as "constellations": each repo is a labeled region on the
canvas containing its own role-clusters (dev/reviewer/orchestrator/...).

  neural-view.py start [--port N] [--dir ROOT] [--scan BASE]   # start (idempotent)
  neural-view.py status                # RUNNING <url> notes=N brains=N repos=N | STOPPED | STALE: ...
  neural-view.py stop [--force]        # --force also kills a zombie holding the port (see below)
  neural-view.py serve [--port N] [--dir ROOT] [--scan BASE]   # run in the foreground (internal)
  neural-view.py dev [--port N] [--dir ROOT] [--scan BASE]     # foreground + auto-restart on script
                                       # change; the page live-reloads via GET /version (dev only)

Stale-server detection: if the pidfile is missing/stale but the configured
port is still occupied, `status` reports STALE (never a bare STOPPED) and
`start` refuses to claim RUNNING (never a bare "never bound to port") —
both name the PID/command holding the port when discoverable (via `lsof`,
used only as optional enrichment; the free-vs-held check itself is a plain
stdlib bind attempt, no external tool required). `stop --force` kills the
pidfile-tracked server if any, AND kills a detected zombie holding the
configured port — but only when that process's own command line contains
"neural-view.py"; otherwise it reports the PID/command and refuses, since
this is the only remotely destructive path in an otherwise read-only tool.

Repo discovery (both apply; results are deduped and sorted by repo name):
  - --dir / $NEURAL_VIEW_DIR: that root is ALWAYS included, marker or not.
  - Scan base (--scan, else $NEURAL_VIEW_SCAN, else ~/Development): every
    immediate child directory that has a <child>/.claude/.neural-network
    marker FILE is included. Directories without the marker are ignored,
    even if they have brains — inclusion is explicit and cheap.
  - If neither yields anything (no flags/env at all, empty scan base), falls
    back to the git root of the cwd — the old single-repo default — and, as a
    side effect, creates that repo's own <root>/.claude/.neural-network
    marker if it's missing, so a bare `start` from inside a fresh repo opts
    it into every future multi-repo scan too, not just this one-off session.
  A discovered repo with no `.claude/identities/` brains yet still appears as
  an empty, labeled region on the canvas (nodes/edges: none) rather than being
  dropped — it shows the constellation is there, just not yet populated.

Brains live at <root>/.claude/identities/<role>/brain/ — notes/<slug>.md
(YAML-ish frontmatter + body + [[slug]] wikilinks), links.json, and
.activation.jsonl. Everything is read READ-ONLY; absent dirs/files just yield
an empty graph. Graph node ids are "<repo>/<role>/<slug>" (unique across repos);
/note/<repo>/<role>/<slug> addresses one; /events cursors are opaque and carry
a per-repo, per-role byte offset. POST /open/<repo>/<role>/<slug> opens that
note in a local viewer — Obsidian, else VS Code, else a terminal `cat`
(fixed fallback chain; preferred-viewer settings are a later feature).

GET /graph also returns repoRoles: {repo: [role, ...]} (alphabetical) — the
CANONICAL_ROLES (dev/orchestrator/reviewer) unioned with any role that has a
brain/ dir on disk, per repo. This lets the BRAINS panel show every anchored
repo with all three roles, dimmed/zero when a role has no notes yet, instead
of a role silently vanishing because it has no notes to contribute nodes.
It also returns roots: {repo: absoluteLocalPath} — the client's "Talk" panel
uses this as the `cwd` of a claude-cli://open deep link (see
https://code.claude.com/docs/en/deep-links) so a new session opens in the
right checkout regardless of GitHub repo/clone state.

GET /projects: {repo: {ok, statusCounts:{status:N}, inProgress:[title], inReview:[title]}}
or {repo: {ok:false, error}} — per-repo board state, read via THIS plugin's
board.sh (never `gh project` directly) with cwd=<repo root>, so it resolves
that repo's own .claude/project.yaml. Cached for $NEURAL_VIEW_PROJECTS_TTL
seconds (default 60), subprocess bounded by $NEURAL_VIEW_BOARD_TIMEOUT seconds
(default 12) so a hung `gh` never blocks other routes for long. A repo with
no .claude/project.yaml or .json is omitted entirely (not an error).

GET /sessions: [{repo, description, state, startedAt}] — best-effort local
Claude Code session discovery from ~/.claude/jobs/<id>/state.json (harness job
orchestration metadata: state/cwd/name/timestamps only — never the
conversation transcript). See discover_sessions() docstring for the full
investigation writeup. $NEURAL_VIEW_CLAUDE_DIR overrides ~/.claude (mainly for
tests); $NEURAL_VIEW_SESSION_RECENT_SECS overrides the "recent" window
(default 900s).

State dir (pid/port/log): $NEURAL_VIEW_STATE, else <git root>/.claude/neural-view.
Port: --port, else $NEURAL_VIEW_PORT, else 4748. Binds 127.0.0.1 only.
"""
import base64
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # import config (project.yaml reader) beside this script


def git_root():
    try:
        return subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    except Exception:  # noqa: BLE001
        return os.getcwd()


def state_dir():
    env = os.environ.get("NEURAL_VIEW_STATE")
    return Path(env) if env else Path(git_root()) / ".claude" / "neural-view"


S = state_dir()
PIDFILE, PORTFILE, REPOSFILE = S / "pid", S / "port", S / "repos.json"
DEFAULT_PORT = int(os.environ.get("NEURAL_VIEW_PORT", "4748"))
TEMPLATE = Path(__file__).resolve().parent.parent / "templates" / "neural-view.html"
VENDOR_DIR = Path(__file__).resolve().parent.parent / "templates" / "vendor"
# Explicit allowlist of servable vendor filenames — never derive the fs path
# from the request path directly (that's how ../ traversal happens).
VENDOR_FILES = {
    "three.module.min.js": "text/javascript; charset=utf-8",
    "three.core.min.js": "text/javascript; charset=utf-8",
}
WIKILINK = re.compile(r"\[\[([^\]]+)\]\]")
MARKER_NAME = ".neural-network"
MARKER_CONTENT = "# neural-view discovery marker — repos with this file are included in the aggregated neural view\n"


def ensure_marker(root):
    """Create <root>/.claude/.neural-network if missing, so a repo you start
    neural-view against (the single-repo cwd fallback — no --dir/--scan match)
    joins the aggregate on every future scan too, not just this one-off
    session. Best-effort: a read-only .claude/ or missing .claude/ dir must
    never fail `start` — same philosophy as board.sh/telemetry.py's cache
    writes."""
    try:
        claude_dir = Path(root) / ".claude"
        marker = claude_dir / MARKER_NAME
        if marker.is_file():
            return
        claude_dir.mkdir(parents=True, exist_ok=True)
        marker.write_text(MARKER_CONTENT)
    except OSError:
        pass
FAVICON = (b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">'
           b'<circle cx="16" cy="16" r="14" fill="#04070d"/>'
           b'<circle cx="16" cy="16" r="6" fill="#46e6ff"/></svg>')

REPOS = [("", Path(git_root()))]  # list of (repo_name, root); replaced by serve()

# GET /version — dev live-reload signal: `boot` changes on every server
# process, `template` on every template edit; `dev` is true only under the
# `dev` command, and the page only ever polls when it is.
BOOT_ID = f"{os.getpid()}-{int(time.time() * 1000)}"
# live viewer metrics, POSTed by each open tab about once a second
# (version/fps/dpr/frame-section timings). Read back via GET /metrics and
# surfaced by `neural-view.py status` so an agent can measure the page's real
# frame rate without screenshots. Keyed by a per-tab id; entries expire.
METRICS: dict = {}
METRICS_TTL = 30.0
GRAPH_CACHE = None   # {"at", "cost", "body"} — see the /graph handler
BODY_CACHE = None    # {"at", "cost", "bodies": {id: lowercased body text}} — see /search-body
DEV_MODE = os.environ.get("NEURAL_VIEW_DEV") == "1"

# GET /projects: per-repo board state, cached (see project_state()) so a slow/
# hung `gh` call is bounded and never re-invoked more than once per TTL.
PROJECTS_TTL = float(os.environ.get("NEURAL_VIEW_PROJECTS_TTL", "300"))
# After a rate-limited board read, no repo's board is re-fetched for this long
# (a global circuit breaker — retrying per-repo per-TTL while exhausted just
# burns more of the shared GraphQL budget); stale last-good data is served.
RATE_COOLDOWN = float(os.environ.get("NEURAL_VIEW_RATE_COOLDOWN", "900"))
BOARD_TIMEOUT = float(os.environ.get("NEURAL_VIEW_BOARD_TIMEOUT", "12"))
BOARD_SH = Path(__file__).resolve().parent / "board.sh"
PROJECTS_CACHE = {}          # repo name -> (fetched_at, result-dict-or-None)
PROJECTS_GOOD = {}           # repo name -> (fetched_at, last OK result) — served stale on failure
PROJECTS_LOCK = threading.Lock()
RATE_LIMIT_UNTIL = 0.0       # epoch: gh board reads are suspended until then (circuit breaker)

# GET /sessions: best-effort locally-discoverable Claude Code sessions.
SESSION_RECENT_SECS = float(os.environ.get("NEURAL_VIEW_SESSION_RECENT_SECS", "900"))


# ---------------------------------------------------------------------------
# Brain reading (all read-only)
# ---------------------------------------------------------------------------
def identities_dir(root):
    return Path(root) / ".claude" / "identities"


def iter_brains(root):
    """Yield (role, brain_dir) for every <root>/.claude/identities/<role>/brain."""
    d = identities_dir(root)
    if not d.is_dir():
        return
    for child in sorted(d.iterdir()):
        brain = child / "brain"
        if brain.is_dir():
            yield child.name, brain


def _coerce(val):
    v = val.strip().strip("\"'")
    low = v.lower()
    if low in ("true", "false"):
        return low == "true"
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v


def parse_frontmatter(raw):
    """A deliberately small YAML-ish parser (stdlib only): scalars, inline
    [a, b] lists, and block '- item' lists. Enough for the brain note schema."""
    fm, lines, i = {}, raw.splitlines(), 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#") or ":" not in line:
            i += 1
            continue
        key, _, val = line.partition(":")
        key, val = key.strip(), val.strip()
        if val == "":
            items, j = [], i + 1
            while j < len(lines) and lines[j].lstrip().startswith("- "):
                items.append(_coerce(lines[j].lstrip()[2:]))
                j += 1
            fm[key] = items
            i = j
            continue
        if val.startswith("[") and val.endswith("]"):
            inner = val[1:-1].strip()
            fm[key] = [_coerce(x) for x in inner.split(",") if x.strip()] if inner else []
        else:
            fm[key] = _coerce(val)
        i += 1
    return fm


def parse_note(text):
    fm, body = {}, text
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            fm = parse_frontmatter(text[3:end].strip("\n"))
            body = text[end + 4:].lstrip("\n")
    return fm, body


def _as_list(v):
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def _safe_slug(slug):
    return bool(slug) and "/" not in slug and "\\" not in slug and ".." not in slug


def _within(child, parent):
    """True iff resolved `child` is `parent` or below it (defense in depth against
    path traversal, on top of the _safe_slug reject)."""
    try:
        c, p = os.path.realpath(str(child)), os.path.realpath(str(parent))
        return c == p or c.startswith(p + os.sep)
    except Exception:  # noqa: BLE001
        return False


def read_note(brain, slug):
    if not _safe_slug(slug):
        return None
    notes_dir = brain / "notes"
    f = notes_dir / f"{slug}.md"
    if not _within(f, notes_dir) or not f.is_file():
        return None
    return parse_note(f.read_text(errors="replace"))


CANONICAL_ROLES = ("dev", "orchestrator", "reviewer")  # mirrors identity_lib.DEFAULTS keys


def build_graph(repos):
    """nodes = every note across every repo's brains; edges = each repo's
    links.json entries plus cross-brain consult edges derived from that repo's
    activation logs (consult never crosses a repo boundary). Node/edge ids are
    "<repo>/<role>[/<slug>]" so they stay unique across repos. `repos` in the
    payload lists every DISCOVERED repo (including brainless ones), so the
    client can still draw an empty labeled constellation for them.

    repoRoles: {repo: [role, ...]} sorted alphabetically, CANONICAL_ROLES
    unioned with whatever roles actually have a brain dir on disk (#75) --
    every anchored repo must show all three canonical roles in the BRAINS
    panel even before a role's brain/ dir has ever been created, and any
    future/custom role that DOES have a brain dir still shows up too."""
    nodes, edges, repo_roles = [], [], {}
    for name, root in repos:
        roles_here = set(CANONICAL_ROLES)
        for role, brain in iter_brains(root):
            roles_here.add(role)
            notes_dir = brain / "notes"
            if notes_dir.is_dir():
                for f in sorted(notes_dir.glob("*.md")):
                    fm, _ = parse_note(f.read_text(errors="replace"))
                    slug = f.stem
                    nodes.append({
                        "id": f"{name}/{role}/{slug}",
                        "repo": name,
                        "role": role,
                        "slug": slug,
                        "strength": int(fm.get("strength", 1) or 1),
                        "graduated": bool(fm.get("graduated", False)),
                        "tags": [str(t) for t in _as_list(fm.get("tags"))],
                        # Cheap, already-parsed frontmatter fields for the client's
                        # "Frontmatter" search scope — paths/source are short
                        # strings, unlike the note BODY (see GET /search-body for
                        # that; shipping bodies in /graph would bloat it badly at
                        # thousands-of-notes scale).
                        "paths": [str(p) for p in _as_list(fm.get("paths"))],
                        "source": str(fm.get("source", "") or ""),
                    })
            links = brain / "links.json"
            if links.is_file():
                try:
                    data = json.loads(links.read_text(errors="replace"))
                except Exception:  # noqa: BLE001
                    data = {}
                for key, meta in (data or {}).items():
                    if "->" not in key:
                        continue
                    src, dst = key.split("->", 1)
                    meta = meta if isinstance(meta, dict) else {}
                    edges.append({
                        "source": f"{name}/{role}/{src.strip()}",
                        "target": f"{name}/{role}/{dst.strip()}",
                        "weight": meta.get("weight", 0.5),
                        "fires": meta.get("fires", 0),
                        "last": meta.get("last", ""),
                        "repo": name,
                    })
        # cross-brain consult edges: consumer role reaches into another role's
        # brain, WITHIN this repo only.
        seen = set()
        for ev in read_events(name, root):
            if ev.get("event") != "consult":
                continue
            consumer, role = ev.get("consumer"), ev.get("role")
            if not consumer or not role or consumer == role:
                continue
            key = (consumer, role)
            if key in seen:
                continue
            seen.add(key)
            edges.append({"source": f"{name}/{consumer}", "target": f"{name}/{role}",
                           "type": "consult", "weight": 0.4, "repo": name})
        repo_roles[name] = sorted(roles_here)
    role_colors = {name: repo_role_colors(root) for name, root in repos}
    display_names = {name: repo_display_name(root, name) for name, root in repos}
    # Absolute local path per repo, for the client's "Talk" deep-link panel
    # (claude-cli://open?cwd=...) — the only thing that reliably resolves a
    # new session's working directory regardless of GitHub state.
    roots = {name: str(root) for name, root in repos}
    return {"nodes": nodes, "edges": edges, "repos": [name for name, _ in repos], "repoRoles": repo_roles,
            "roleColors": role_colors, "displayNames": display_names, "roots": roots}


def build_body_index(repos):
    """{note id: lowercased body text} across every repo/role — the note
    BODY, deliberately never shipped in /graph (would bloat that payload
    badly at thousands-of-notes scale). Only used by GET /search-body,
    which returns matching ids, never the bodies themselves."""
    bodies = {}
    for name, root in repos:
        for role, brain in iter_brains(root):
            notes_dir = brain / "notes"
            if not notes_dir.is_dir():
                continue
            for f in notes_dir.glob("*.md"):
                try:
                    _, body = parse_note(f.read_text(errors="replace"))
                except OSError:
                    continue
                bodies[f"{name}/{role}/{f.stem}"] = body.lower()
    return bodies


def repo_role_colors(root):
    """{role: cssColor} from the repo's own project config —
    delegation.identities.<role>.color (first entry carrying one, for the
    array/monorepo form). Optional everywhere: a missing config, disabled
    identities, or an absent color just falls back to the client's default
    palette. Read via config.py so v1/v2 normalization stays in one place."""
    cfgp = _repo_config_path(root)
    if cfgp is None:
        return {}
    try:
        import config as _config
        cfg = _config.load_config(path=str(cfgp), warn=False)
    except Exception:  # noqa: BLE001
        return {}
    delegation = cfg.get("delegation")
    idents = delegation.get("identities") if isinstance(delegation, dict) else None
    if not isinstance(idents, dict):
        return {}
    out = {}
    for role, spec in idents.items():
        for entry in (spec if isinstance(spec, list) else [spec]):
            color = entry.get("color") if isinstance(entry, dict) else None
            if isinstance(color, str) and color.strip():
                out[role] = color.strip()
                break
    return out


def repo_display_name(root, name):
    """The label shown for a repo in the HUD — project.displayName if the
    repo's config sets one (e.g. an npm scope or product name that differs
    from the checkout's folder name), else the folder-derived repo id
    unchanged. Display-only: node ids, /projects keys, and all matching
    logic keep using `name`, never this."""
    cfgp = _repo_config_path(root)
    if cfgp is None:
        return name
    try:
        import config as _config
        cfg = _config.load_config(path=str(cfgp), warn=False)
    except Exception:  # noqa: BLE001
        return name
    project = cfg.get("project")
    display = project.get("displayName") if isinstance(project, dict) else None
    return display.strip() if isinstance(display, str) and display.strip() else name


def _parse_lines(repo, role, blob, out):
    for line in blob.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        if isinstance(obj, dict):
            obj.setdefault("role", role)
            obj.setdefault("repo", repo)
            out.append(obj)


def read_events(repo, root):
    """Every .activation.jsonl line across one repo's brains, ts-ordered. Used
    by the graph (consult-edge derivation); NOT the delivery path (see
    read_events_since)."""
    evts = []
    for role, brain in iter_brains(root):
        f = brain / ".activation.jsonl"
        if f.is_file():
            _parse_lines(repo, role, f.read_text(errors="replace"), evts)
    evts.sort(key=lambda e: str(e.get("ts", "")))
    return evts


def _complete_end(f):
    """Byte offset just past the last COMPLETE line (last newline). A partial
    trailing line (writer mid-append) is excluded so we never read half a line."""
    if not f.is_file():
        return 0
    size = f.stat().st_size
    if size == 0:
        return 0
    with f.open("rb") as fh:
        pos = size
        while pos > 0:
            step = min(65536, pos)
            pos -= step
            fh.seek(pos)
            buf = fh.read(step)
            nl = buf.rfind(b"\n")
            if nl != -1:
                return pos + nl + 1
    return 0


def end_offsets(repos):
    """Per-repo, per-brain 'current end' — the token a fresh client starts from
    (skips backlog: only events appended AFTER this poll are ever delivered)."""
    return {name: {role: _complete_end(brain / ".activation.jsonl") for role, brain in iter_brains(root)}
            for name, root in repos}


def read_events_since(repos, offsets):
    """The delivery path. For each repo's each brain, seek to its stored byte
    offset and read only the NEW complete lines — completeness comes from
    append-only offsets, not from re-sorting a full re-read (which shifted
    indexes and dropped/replayed). Returns (events, new_offsets, bytes_read).
    Events are ts-sorted within this batch for display only. Defends against a
    truncated/rotated log (offset past EOF → restart that brain at 0) and
    against an unrecognized repo name in the token (treated as empty offsets)."""
    events = []
    new_offsets = {}
    bytes_read = 0
    for name, root in repos:
        repo_offsets = offsets.get(name) or {}
        repo_new = {}
        for role, brain in iter_brains(root):
            f = brain / ".activation.jsonl"
            if not f.is_file():
                repo_new[role] = 0
                continue
            start = repo_offsets.get(role, 0)
            size = f.stat().st_size
            if start < 0 or start > size:  # negative / rotated-shrunk offset — don't seek there, resync
                start = 0
            with f.open("rb") as fh:
                fh.seek(start)
                data = fh.read()
            nl = data.rfind(b"\n")
            if nl == -1:               # no complete line beyond the offset yet
                repo_new[role] = start
                continue
            consumed = data[:nl + 1]
            bytes_read += len(consumed)
            repo_new[role] = start + len(consumed)
            _parse_lines(name, role, consumed.decode("utf-8", "replace"), events)
        new_offsets[name] = repo_new
    events.sort(key=lambda e: str(e.get("ts", "")))
    return events, new_offsets, bytes_read


def encode_cursor(offsets):
    raw = json.dumps(offsets, separators=(",", ":"), sort_keys=True).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()  # no '=' → query-safe, unquoted


def decode_cursor(token):
    """A cursor token → {repo: {role: byte_offset}}, or None if absent/garbage/'0'
    (caller treats None as 'start from current end'). An unrecognized/malformed
    per-repo entry is dropped rather than failing the whole cursor (a repo that
    vanished from discovery just resyncs from 0 on its next appearance)."""
    if not token or token == "0":
        return None
    try:
        pad = "=" * (-len(token) % 4)
        d = json.loads(base64.urlsafe_b64decode(token + pad))
        if isinstance(d, dict):
            out = {}
            for repo, roles in d.items():
                if isinstance(roles, dict):
                    out[str(repo)] = {str(k): max(0, int(v)) for k, v in roles.items()}  # never a negative seek offset
            return out
    except Exception:  # noqa: BLE001
        pass
    return None


_TABLE_SEP_RE = re.compile(r"^\s*:?-{3,}:?\s*$")


def _table_row_cells(line):
    """Split a GFM pipe-table row into its cell texts. Leading/trailing pipes
    are optional in GFM (`a | b` and `| a | b |` both parse), so strip one of
    each before splitting rather than assuming the leading/trailing form."""
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [c.strip() for c in line.split("|")]


def render_body(body):
    """Tiny markdown → HTML: headings, paragraphs, [[wikilinks]], **bold**,
    *italic*/_italic_, `code`, GFM pipe tables.
    Deliberately minimal — stdlib only, and it preserves plain prose verbatim."""
    def inline(s):
        # escape wikilink labels exactly once (operate on raw text, escape each
        # piece), so a label with HTML-special chars isn't double-escaped.
        out, last = [], 0
        for m in WIKILINK.finditer(s):
            out.append(escape(s[last:m.start()]))
            slug = m.group(1).strip()
            out.append(f'<a class="wl" data-slug="{escape(slug, quote=True)}">{escape(slug)}</a>')
            last = m.end()
        out.append(escape(s[last:]))
        r = "".join(out)
        r = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", r)
        # italic after bold, so a stray "**" pair is already consumed and
        # can't be misread as two "*" italic markers.
        r = re.sub(r"\*([^*]+)\*", r"<em>\1</em>", r)
        r = re.sub(r"_([^_]+)_", r"<em>\1</em>", r)
        r = re.sub(r"`([^`]+)`", r"<code>\1</code>", r)
        return r

    def is_table(lines):
        return (len(lines) >= 2 and "|" in lines[0]
                and all(_TABLE_SEP_RE.match(c) for c in _table_row_cells(lines[1])))

    def render_table(lines):
        header = "".join(f"<th>{inline(c)}</th>" for c in _table_row_cells(lines[0]))
        rows = "".join(
            "<tr>" + "".join(f"<td>{inline(c)}</td>" for c in _table_row_cells(ln)) + "</tr>"
            for ln in lines[2:]
        )
        return f"<table><thead><tr>{header}</tr></thead><tbody>{rows}</tbody></table>"

    out = []
    for block in re.split(r"\n\s*\n", body.strip()):
        block = block.strip("\n")
        if not block:
            continue
        lines = block.splitlines()
        h = re.match(r"^(#{1,6})\s+(.*)$", block)
        if h:
            lvl = min(len(h.group(1)) + 2, 6)
            out.append(f"<h{lvl}>{inline(h.group(2).strip())}</h{lvl}>")
        elif all(ln.lstrip().startswith(("- ", "* ")) for ln in lines):
            items = "".join(f"<li>{inline(ln.lstrip()[2:])}</li>" for ln in lines)
            out.append(f"<ul>{items}</ul>")
        elif is_table(lines):
            out.append(render_table(lines))
        else:
            out.append(f"<p>{inline(block)}</p>")
    return "\n".join(out)


def note_payload(repos, repo, role, slug):
    """Looks up a note by (repo, role, slug). `repo` is matched against the
    discovered repo NAME (directory basename, per discover_repos()) — two
    scanned repos sharing a basename would silently shadow each other here
    (first match in discovery order wins); an accepted edge case, not expected
    across a developer's project directories."""
    for name, root in repos:
        if name != repo:
            continue
        for r, brain in iter_brains(root):
            if r != role:
                continue
            parsed = read_note(brain, slug)
            if parsed is None:
                return None
            fm, body = parsed
            links = []
            lf = brain / "links.json"
            if lf.is_file():
                try:
                    data = json.loads(lf.read_text(errors="replace"))
                except Exception:  # noqa: BLE001
                    data = {}
                for key, meta in (data or {}).items():
                    if "->" not in key:
                        continue
                    src, dst = (p.strip() for p in key.split("->", 1))
                    meta = meta if isinstance(meta, dict) else {}
                    if src == slug:
                        links.append({"target": dst, "weight": meta.get("weight", 0.5), "fires": meta.get("fires", 0), "dir": "out"})
                    elif dst == slug:
                        links.append({"target": src, "weight": meta.get("weight", 0.5), "fires": meta.get("fires", 0), "dir": "in"})
            return {"repo": repo, "role": role, "slug": slug, "frontmatter": fm, "bodyHtml": render_body(body), "links": links}
        return None
    return None


def note_file_path(repos, repo, role, slug):
    """Absolute Path of a note's markdown file, with the same (repo, role,
    slug) addressing and traversal guards as read_note(); None if absent."""
    if not _safe_slug(slug):
        return None
    for name, root in repos:
        if name != repo:
            continue
        for r, brain in iter_brains(root):
            if r != role:
                continue
            notes_dir = brain / "notes"
            f = notes_dir / f"{slug}.md"
            if _within(f, notes_dir) and f.is_file():
                return f
            return None
        return None
    return None


def _mac_app_installed(app):
    try:
        return subprocess.run(["open", "-Ra", app], capture_output=True, timeout=5).returncode == 0
    except Exception:  # noqa: BLE001
        return False


_VIEWER_CACHE = None  # detected once per process; installs don't change mid-run


def detect_viewer():
    """Which local viewer POST /open would use — "obsidian" | "vscode" |
    "terminal" | None. Fixed fallback chain for now; a preferred-viewer
    setting is a later feature. Cached so the detection subprocesses run at
    most once per server process (GET /viewer is called on every page load)."""
    global _VIEWER_CACHE
    if _VIEWER_CACHE is None:
        _VIEWER_CACHE = _detect_viewer_uncached() or "none"
    return None if _VIEWER_CACHE == "none" else _VIEWER_CACHE


def _detect_viewer_uncached():
    try:
        if sys.platform == "darwin":
            if _mac_app_installed("Obsidian"):
                return "obsidian"
            if _mac_app_installed("Visual Studio Code") or shutil.which("code"):
                return "vscode"
            return "terminal"  # osascript+Terminal are always present on macOS
        if shutil.which("obsidian"):
            return "obsidian"
        if shutil.which("code"):
            return "vscode"
        for term in ("x-terminal-emulator", "gnome-terminal", "konsole", "xterm"):
            if shutil.which(term):
                return "terminal"
    except Exception:  # noqa: BLE001
        return None
    return None


def open_note_externally(path):
    """Open a note in the viewer detect_viewer() picked. Returns the viewer
    used or None if nothing launched. Launching a viewer reads the note but
    never mutates a brain, so the tool's read-only contract holds."""
    p = str(path)
    viewer = detect_viewer()
    try:
        if viewer == "obsidian":
            uri = "obsidian://open?path=" + urllib.parse.quote(p, safe="")
            if sys.platform == "darwin":
                subprocess.Popen(["open", uri])
            else:
                subprocess.Popen(["obsidian", uri])
            return "obsidian"
        if viewer == "vscode":
            if sys.platform == "darwin" and not shutil.which("code"):
                subprocess.Popen(["open", "-a", "Visual Studio Code", p])
            else:
                subprocess.Popen(["code", p])
            return "vscode"
        if viewer == "terminal":
            if sys.platform == "darwin":
                script = f'tell application "Terminal"\n  activate\n  do script "cat {shlex.quote(p)}"\nend tell'
                subprocess.Popen(["osascript", "-e", script])
                return "terminal"
            for term in ("x-terminal-emulator", "gnome-terminal", "konsole", "xterm"):
                if shutil.which(term):
                    subprocess.Popen([term, "-e", f"sh -c 'cat {shlex.quote(p)}; exec sh'"])
                    return "terminal"
    except Exception:  # noqa: BLE001
        return None
    return None


# ---------------------------------------------------------------------------
# Per-repo project/board state (GET /projects) and locally-discoverable
# Claude Code sessions (GET /sessions) — both best-effort, read-only, and
# never allowed to stall other routes: subprocess calls are time-boxed
# (BOARD_TIMEOUT) and results cached for PROJECTS_TTL. Since the server is a
# ThreadingHTTPServer, a slow /projects request occupies only its own request
# thread anyway — the timeout exists so that thread (and its cached slot)
# don't hang indefinitely on a wedged `gh`.
# ---------------------------------------------------------------------------
def _repo_config_path(root):
    for name in ("project.yaml", "project.json"):
        p = Path(root) / ".claude" / name
        if p.is_file():
            return p
    return None


_ANSI_RE = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
_QUEUE_RATE_LIMIT_RE = re.compile(r'RATE-LIMITED until (\S+)')
_RATE_LIMIT_RE = re.compile(r'API rate limit|rate limit already exceeded', re.IGNORECASE)
_RESET_TIME_RE = re.compile(
    r'[0-9]{4}-[0-9]{2}-[0-9]{2}T([0-9]{2}:[0-9]{2})(?::[0-9]{2})?Z?'
    r'|reset[a-z]*\D{0,10}([0-9]{1,2}:[0-9]{2})',
    re.IGNORECASE,
)


def _classify_board_failure(raw):
    """Turn board.sh's raw stderr/stdout into a human-readable, ANSI-free
    error. board.sh's `list`/`next`/`show`/`issues` gate on gh's own exit
    code (SPEC #77) so a gh failure never reaches a bare `json.load` and
    raises a Python traceback anymore -- but this stays defense-in-depth for
    any other text that slips through. board.sh's OWN rate-limit detection
    (a "RATE-LIMITED until <reset>" line, sourced from `gh api rate_limit`)
    is authoritative and checked first; a raw, un-queued "API rate limit"
    string (e.g. from a gh call this script invokes directly, outside
    board.sh) is a fallback. Anything else falls back to the last
    non-blank, ANSI-stripped line."""
    clean = _ANSI_RE.sub('', raw)
    m = _QUEUE_RATE_LIMIT_RE.search(clean)
    if m:
        when = m.group(1)
        if when == "unknown":
            when = "soon"
        return f"board unavailable: GitHub API rate limit (resets {when})"
    if _RATE_LIMIT_RE.search(clean):
        m2 = _RESET_TIME_RE.search(clean)
        when = (m2.group(1) or m2.group(2)) if m2 else "soon"
        return f"board unavailable: GitHub API rate limit (resets {when})"
    if "unknown owner type" in clean:
        # gh 2.54 masks a failed GraphQL owner-type lookup (most often an
        # exhausted GraphQL rate limit, sometimes auth) behind this message.
        return "board unavailable: gh could not resolve the project owner (usually the GraphQL rate limit — check `gh api rate_limit`)"
    for line in reversed(clean.strip().splitlines()):
        line = line.strip()
        if line:
            return f"board unavailable: {line}"
    return "board unavailable: board.sh list failed"


def _run_board_list(root):
    """Invoke THIS plugin's board.sh (never `gh project` directly) with
    cwd=root, so it resolves and reads THAT repo's own .claude/project.yaml —
    the only board-access path, per the plugin's invariant."""
    try:
        proc = subprocess.run([str(BOARD_SH), "list"], cwd=str(root), capture_output=True,
                               text=True, timeout=BOARD_TIMEOUT)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"board.sh list timed out after {BOARD_TIMEOUT}s"}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"board.sh invocation failed: {e}"}
    if proc.returncode != 0:
        raw = proc.stderr or proc.stdout or "board.sh list failed"
        return {"ok": False, "error": _classify_board_failure(raw)[:300]}
    status_counts, in_progress, in_review = {}, [], []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        status, title = parts[0], parts[3]
        status_counts[status] = status_counts.get(status, 0) + 1
        low = status.strip().lower()
        if low == "in progress":
            in_progress.append(title)
        elif low == "in review":
            in_review.append(title)
    return {"ok": True, "statusCounts": status_counts, "inProgress": in_progress, "inReview": in_review}


def _stale_copy(name, now, note):
    """Last-good board data marked stale (never None unless no good data yet).
    A transient gh failure must not blank a board the HUD showed seconds ago."""
    good = PROJECTS_GOOD.get(name)
    if good is None:
        return None
    fetched_at, result = good
    return dict(result, stale=True, staleForSecs=int(now - fetched_at), staleReason=note)


def project_state(name, root):
    """A repo's board state, cached for PROJECTS_TTL seconds. Returns None
    (caller omits the repo entirely, per the /projects contract) if the repo
    has no .claude/project.yaml or .json at all — a repo that never opted
    into the board should not even show a "board unavailable" badge.

    GraphQL-budget discipline (the board reads share the user's 5000/hr
    GraphQL quota with the build loops): long TTL, a global RATE_COOLDOWN
    circuit breaker after any rate-limited read (retrying per-repo per-TTL
    while exhausted only digs the hole deeper), and last-good data served
    stale — marked {stale, staleForSecs, staleReason} — instead of an error
    whenever a fetch fails or the breaker is open."""
    global RATE_LIMIT_UNTIL
    if _repo_config_path(root) is None:
        return None
    now = time.time()
    with PROJECTS_LOCK:
        cached = PROJECTS_CACHE.get(name)
        if cached is not None and (now - cached[0]) < PROJECTS_TTL:
            return cached[1]
        if now < RATE_LIMIT_UNTIL:
            served = _stale_copy(name, now, "rate-limit cooldown") or \
                {"ok": False, "error": "board unavailable: GitHub API rate limit (cooling down)"}
            PROJECTS_CACHE[name] = (now, served)
            return served
    result = _run_board_list(root)
    with PROJECTS_LOCK:
        if result.get("ok"):
            PROJECTS_GOOD[name] = (now, result)
            served = result
        else:
            err = str(result.get("error") or "")
            if _RATE_LIMIT_RE.search(err) or "rate limit" in err.lower() or "could not resolve the project owner" in err:
                RATE_LIMIT_UNTIL = now + RATE_COOLDOWN
            served = _stale_copy(name, now, err) or result
        PROJECTS_CACHE[name] = (now, served)
    return served


def claude_dir():
    env = os.environ.get("NEURAL_VIEW_CLAUDE_DIR")
    return Path(env) if env else Path.home() / ".claude"


def discover_sessions(repos):
    """Best-effort discovery of locally-active Claude Code sessions.

    Investigation finding: ~/.claude/jobs/<id>/state.json is background-job
    orchestration metadata the harness itself writes — state, cwd, a short
    job name/label, createdAt/updatedAt timestamps. It is NOT the conversation
    transcript (that lives under ~/.claude/projects/<hash>/*.jsonl and is
    never touched here). This function reads only state/cwd/name/createdAt;
    it deliberately never reads the job's `detail`/`output` fields, which can
    carry snippets of actual model output — metadata/mtimes only, per the
    privacy invariant.

    A job counts as an active "session" if its state is "working", or its
    state.json was modified within SESSION_RECENT_SECS (a recent-activity
    heuristic that also surfaces jobs that just finished). Its `cwd` is
    matched against a discovered repo by path prefix so the UI can badge the
    right region; a job whose cwd doesn't fall under any discovered repo
    still surfaces with repo=None rather than being dropped. If ~/.claude (or
    $NEURAL_VIEW_CLAUDE_DIR) has no jobs/ directory at all, returns []."""
    jobs_dir = claude_dir() / "jobs"
    out = []
    try:
        children = sorted(jobs_dir.iterdir()) if jobs_dir.is_dir() else []
    except OSError:
        return out
    now = time.time()
    repo_roots = [(name, os.path.realpath(str(root))) for name, root in repos]
    for child in children:
        sf = child / "state.json"
        try:
            if not sf.is_file():
                continue
            mtime = sf.stat().st_mtime
            data = json.loads(sf.read_text(errors="replace"))
        except Exception:  # noqa: BLE001
            continue
        if not isinstance(data, dict):
            continue
        state = data.get("state")
        if state != "working" and (now - mtime) > SESSION_RECENT_SECS:
            continue
        cwd = str(data.get("cwd") or "")
        cwd_real = os.path.realpath(cwd) if cwd else ""
        repo = None
        for name, rp in repo_roots:
            if cwd_real == rp or cwd_real.startswith(rp + os.sep):
                repo = name
                break
        out.append({
            "repo": repo,
            "description": str(data.get("name") or ""),
            "state": state,
            "startedAt": str(data.get("createdAt") or ""),
        })
    return out


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):  # quiet
        pass

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/" or path.startswith("/index"):
            if TEMPLATE.is_file():
                return self._send(200, TEMPLATE.read_bytes(), "text/html; charset=utf-8")
            return self._send(200, "<h1>neural-view</h1><p>template missing</p>", "text/html; charset=utf-8")
        if path == "/favicon.ico":
            return self._send(200, FAVICON, "image/svg+xml")
        if path.startswith("/vendor/"):
            # Strict allowlist: the requested name must be an exact key in
            # VENDOR_FILES (no path segments, no traversal, no arbitrary
            # extension) — the fs path is built from the allowlist entry, not
            # from the request, so "../" / encoded variants just miss the map.
            name = path[len("/vendor/"):]
            ctype = VENDOR_FILES.get(name)
            if ctype:
                f = VENDOR_DIR / name
                if f.is_file():
                    return self._send(200, f.read_bytes(), ctype)
            return self._send(404, {"error": "not found"})
        if path == "/graph":
            # Big corpora make build_graph expensive (measured: 39s scan /
            # 86MB payload at 180k notes) while every open tab re-polls —
            # serve a cached payload within a TTL so overlapping polls don't
            # keep the server scanning at 100% CPU. TTL scales with how long
            # the build actually took (min 15s, or 6x build time).
            global GRAPH_CACHE
            now = time.time()
            cached = GRAPH_CACHE
            if cached and now - cached["at"] < max(15.0, cached["cost"] * 6):
                return self._send(200, cached["body"], "application/json")
            t0 = time.time()
            body = json.dumps(build_graph(REPOS)).encode()
            GRAPH_CACHE = {"at": time.time(), "cost": time.time() - t0, "body": body}
            return self._send(200, body, "application/json")
        if path == "/search-body":
            # Full-text note-body search — the client's "Full text" search
            # scope. Body text is never shipped in /graph (payload-size
            # reasons, see build_graph's docstring), so a real body query
            # needs its own round trip. Same TTL-cache shape as /graph:
            # scanning is opt-in (only fires when the human enables the
            # "Full text" checkbox and searches), but re-reading every note
            # body on every keystroke/poll would still be wasteful.
            qs = urllib.parse.parse_qs(self.path.split("?", 1)[1] if "?" in self.path else "")
            q = (qs.get("q", [""])[0] or "").strip().lower()
            if not q:
                return self._send(200, {"ids": []})
            global BODY_CACHE
            now = time.time()
            cached = BODY_CACHE
            if not cached or now - cached["at"] > max(20.0, cached["cost"] * 6):
                t0 = time.time()
                bodies = build_body_index(REPOS)
                BODY_CACHE = {"at": time.time(), "cost": time.time() - t0, "bodies": bodies}
                cached = BODY_CACHE
            ids = [nid for nid, text in cached["bodies"].items() if q in text]
            return self._send(200, {"ids": ids})
        if path == "/events":
            token = ""
            q = self.path.split("?", 1)[1] if "?" in self.path else ""
            for kv in q.split("&"):
                if kv.startswith("since="):
                    token = kv[len("since="):]
            offsets = decode_cursor(token)
            if offsets is None:                    # first poll / bad token: start at end, skip backlog
                offsets = end_offsets(REPOS)
                return self._send(200, {"cursor": encode_cursor(offsets), "events": [], "bytesRead": 0})
            events, new_offsets, nbytes = read_events_since(REPOS, offsets)
            return self._send(200, {"cursor": encode_cursor(new_offsets), "events": events, "bytesRead": nbytes})
        if path == "/projects":
            out = {}
            for name, root in REPOS:
                state = project_state(name, root)
                if state is not None:
                    out[name] = state
            return self._send(200, out)
        if path == "/sessions":
            return self._send(200, discover_sessions(REPOS))
        if path == "/viewer":
            # which viewer POST /open would use, so the inspect panel can
            # label its "View in ..." button without launching anything.
            return self._send(200, {"viewer": detect_viewer()})
        if path == "/metrics":
            now = time.time()
            for k in [k for k, v in METRICS.items() if now - v.get("received", 0) > METRICS_TTL]:
                METRICS.pop(k, None)
            out = []
            for v in METRICS.values():
                d = dict(v)
                d["age"] = round(now - d.pop("received", now), 1)
                out.append(d)
            return self._send(200, {"clients": sorted(out, key=lambda d: d.get("age", 0))})
        if path == "/version":
            tmpl = TEMPLATE.stat().st_mtime_ns if TEMPLATE.is_file() else 0
            return self._send(200, {"boot": BOOT_ID, "template": tmpl, "dev": DEV_MODE})
        if path.startswith("/note/"):
            parts = path[len("/note/"):].split("/", 2)
            if len(parts) == 3 and parts[0] and parts[1] and parts[2]:
                payload = note_payload(REPOS, parts[0], parts[1], parts[2])
                if payload is not None:
                    return self._send(200, payload)
            return self._send(404, {"error": "unknown note"})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/metrics":
            try:
                n = min(int(self.headers.get("Content-Length", 0)), 4096)
                data = json.loads(self.rfile.read(n) or b"{}")
                cid = str(data.get("id", ""))[:16] or "anon"
                data["received"] = time.time()
                METRICS[cid] = data
            except Exception:  # noqa: BLE001 — malformed metrics are just dropped
                pass
            return self._send(200, {})
        if path.startswith("/open/"):
            parts = path[len("/open/"):].split("/", 2)
            if len(parts) == 3 and all(parts):
                f = note_file_path(REPOS, parts[0], parts[1], parts[2])
                if f is not None:
                    viewer = open_note_externally(f)
                    if viewer:
                        return self._send(200, {"opened": viewer, "path": str(f)})
                    return self._send(500, {"error": "no viewer available"})
            return self._send(404, {"error": "unknown note"})
        return self._send(404, {"error": "not found"})


# ---------------------------------------------------------------------------
# CLI / lifecycle (mirrors ui-hub.py)
# ---------------------------------------------------------------------------
def ensure_dirs():
    S.mkdir(parents=True, exist_ok=True)


def pid_alive():
    try:
        pid = int(PIDFILE.read_text())
        os.kill(pid, 0)
        return pid
    except Exception:  # noqa: BLE001
        return None


SCRIPT_NAME = "neural-view.py"  # matched against a candidate's cmdline before it is ever killed


def configured_port():
    """The port a fresh `status`/`stop` call should check: whatever the last
    `serve` actually bound (PORTFILE), else the process's own default/env
    port. (`start`/`serve` use the port they were just asked to bind instead —
    see arg_port() — since PORTFILE may still hold a stale prior value.)"""
    if PORTFILE.is_file():
        try:
            return int(PORTFILE.read_text().strip())
        except Exception:  # noqa: BLE001
            pass
    return DEFAULT_PORT


def _port_is_free(port):
    """Stdlib-only free-vs-held check: attempt the same bind the real server
    would do (with SO_REUSEADDR, matching http.server's own socket options),
    and see whether it succeeds. No external tool required."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def _pid_holding_port(port):
    """Best-effort PID of whatever is LISTENing on `port`, via `lsof` when
    present — optional enrichment only; the free-vs-held decision above never
    depends on it. Returns None (still a valid "held, but PID unknown" state)
    if lsof is absent or its output can't be parsed."""
    lsof = shutil.which("lsof")
    if not lsof:
        return None
    try:
        proc = subprocess.run(
            [lsof, "-t", "-n", "-P", f"-iTCP:{port}", "-sTCP:LISTEN"],
            capture_output=True, text=True, timeout=3,
        )
    except Exception:  # noqa: BLE001
        return None
    for tok in proc.stdout.split():
        if tok.strip().isdigit():
            return int(tok)
    return None


def _pid_cmdline(pid):
    """Full command line for `pid` via `ps` (portable, stdlib-subprocess —
    not lsof, not psutil): needed to see the script-path argument, since a
    truncated/short command name would never show "neural-view.py". None if
    `ps` can't find/read it (already exited, wrong permissions, etc.)."""
    try:
        proc = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                               capture_output=True, text=True, timeout=3)
    except Exception:  # noqa: BLE001
        return None
    line = proc.stdout.strip()
    return line or None


def port_zombie(port):
    """None if `port` is free; else (pid_or_None, cmdline_or_None) for
    whatever holds it."""
    if _port_is_free(port):
        return None
    pid = _pid_holding_port(port)
    return pid, (_pid_cmdline(pid) if pid is not None else None)


def zombie_diagnosis(port, zombie):
    """Human-readable "port <p> held by ..." fragment — no leading verb/verdict
    (callers prepend "STALE:"/"FAILED to start:" as fits their context)."""
    pid, cmd = zombie
    if pid is None:
        return f"port {port} held by another process (PID unknown — install lsof for details)"
    who = f"PID {pid}" + (f" ({cmd})" if cmd else "")
    return f"port {port} held by {who}"


def arg_val(args, flag, default):
    return args[args.index(flag) + 1] if flag in args and args.index(flag) + 1 < len(args) else default


def arg_port(args):
    return int(arg_val(args, "--port", DEFAULT_PORT))


def raw_arg_dir(args):
    """--dir/$NEURAL_VIEW_DIR if explicitly given, else None (no default)."""
    return arg_val(args, "--dir", None) or os.environ.get("NEURAL_VIEW_DIR")


def raw_arg_scan(args):
    """--scan/$NEURAL_VIEW_SCAN if explicitly given, else None (caller defaults)."""
    return arg_val(args, "--scan", None) or os.environ.get("NEURAL_VIEW_SCAN")


def discover_repos(args):
    """Every repo to aggregate, as (name, root) sorted by name:
    - the explicit --dir/$NEURAL_VIEW_DIR root, if given — ALWAYS included,
      marker or not;
    - every immediate child of the scan base (--scan/$NEURAL_VIEW_SCAN, else
      ~/Development) that carries a <child>/.claude/.neural-network marker
      FILE. Children without the marker are ignored even if they have brains.
    Falls back to the git root of cwd if nothing was found at all (no flags,
    no env, empty/absent scan base) — the old single-repo default. Repo name
    is the directory basename; same-basename repos would collide, an accepted
    edge case (not expected across a developer's project directories).

    A scan base or child directory neural-view can't read (permission denied)
    is treated as absent/excluded rather than raising — one unreadable sibling
    must never take down discovery of the rest."""
    found = {}  # resolved path str -> Path, de-duplicated
    explicit = raw_arg_dir(args)
    if explicit:
        p = Path(os.path.abspath(explicit))
        found[str(p)] = p
    scan_base = raw_arg_scan(args) or str(Path.home() / "Development")
    sb = Path(scan_base)
    try:
        children = sorted(sb.iterdir()) if sb.is_dir() else []
    except OSError:
        children = []
    for child in children:
        try:
            if child.is_dir() and (child / ".claude" / MARKER_NAME).is_file():
                found.setdefault(str(child.resolve()), child)
        except OSError:   # e.g. permission denied traversing into `child`
            continue
    if not found:
        p = Path(git_root())
        found[str(p)] = p
        ensure_marker(p)  # the single-repo fallback opts this repo into every future scan too
    return sorted(((p.name, p) for p in found.values()), key=lambda t: t[0])


def load_repos_file():
    """The repo list a running server persisted at boot (for status/counts
    without re-running discovery, which could drift from what's actually
    served if env vars changed since start)."""
    if REPOSFILE.is_file():
        try:
            data = json.loads(REPOSFILE.read_text())
            repos = [(str(name), Path(root)) for name, root in data]
            if repos:
                return repos
        except Exception:  # noqa: BLE001
            pass
    p = Path(git_root())
    return [(p.name, p)]


def counts(repos):
    total_notes = total_brains = 0
    for _, root in repos:
        brains = list(iter_brains(root))
        total_brains += len(brains)
        total_notes += sum(len(list((b / "notes").glob("*.md"))) for _, b in brains if (b / "notes").is_dir())
    return total_notes, total_brains


def main():
    global REPOS
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    args = sys.argv[2:]
    ensure_dirs()

    if cmd == "serve":
        port = arg_port(args)
        REPOS = discover_repos(args)
        httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)  # bind before pidfile
        PORTFILE.write_text(str(port))
        REPOSFILE.write_text(json.dumps([[name, str(root)] for name, root in REPOS]))
        PIDFILE.write_text(str(os.getpid()))
        httpd.serve_forever()

    elif cmd == "start":
        if pid_alive():
            print(f"RUNNING http://127.0.0.1:{PORTFILE.read_text().strip()}")
            return
        port = arg_port(args)
        child = [sys.executable, os.path.abspath(__file__), "serve", "--port", str(port)]
        explicit_dir = raw_arg_dir(args)
        if explicit_dir:
            child += ["--dir", os.path.abspath(explicit_dir)]
        explicit_scan = raw_arg_scan(args)
        if explicit_scan:
            child += ["--scan", os.path.abspath(explicit_scan)]
        log = open(S / "server.log", "ab")
        subprocess.Popen(child, stdout=log, stderr=log, start_new_session=True, env=os.environ)
        came_up = False
        for _ in range(30):
            time.sleep(0.1)
            if pid_alive():
                came_up = True
                break
        if came_up:
            print(f"RUNNING http://127.0.0.1:{port}")
        else:
            zombie = port_zombie(port)
            if zombie is not None:
                print(f"FAILED to start: {zombie_diagnosis(port, zombie)}, but no pidfile — "
                      f"likely a zombie {SCRIPT_NAME}; run '{SCRIPT_NAME} stop --force' or kill it "
                      f"yourself — see {S / 'server.log'} for details", file=sys.stderr)
            else:
                print(f"FAILED to start (never bound to port {port}) — see {S / 'server.log'}", file=sys.stderr)
            sys.exit(1)

    elif cmd == "status":
        if pid_alive():
            repos = load_repos_file()
            notes, brains = counts(repos)
            port = PORTFILE.read_text().strip()
            print(f"RUNNING http://127.0.0.1:{port} notes={notes} brains={brains} repos={len(repos)}")
            # live viewer metrics (posted by open tabs; see POST /metrics)
            try:
                import urllib.request
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=2) as r:
                    clients = json.loads(r.read()).get("clients", [])
                if not clients:
                    print("viewer: no metrics yet (no tab open, or tab pre-dates v0.25.6 — reload it)")
                for c in clients:
                    perf = (f" · sim {c['sim']} vis {c['vis']} draw {c['draw']} ms"
                            if all(k in c for k in ("sim", "vis", "draw")) else "")
                    print(f"viewer[{c.get('id','?')}]: v{c.get('v','?')} · {c.get('fps','?')} fps"
                          f" · dpr {c.get('dpr','?')}{perf}"
                          f" · notes {c.get('notes','?')} links {c.get('links','?')} · age {c.get('age','?')}s")
            except Exception as e:  # noqa: BLE001
                print(f"viewer: metrics unavailable ({e})")
        else:
            port = configured_port()
            zombie = port_zombie(port)
            if zombie is not None:
                print(f"STALE: {zombie_diagnosis(port, zombie)} but no pidfile — likely a zombie "
                      f"{SCRIPT_NAME}; run '{SCRIPT_NAME} stop --force' or kill it yourself")
            else:
                print("STOPPED")
            sys.exit(1)

    elif cmd == "stop":
        pid = pid_alive()
        if pid:
            os.kill(pid, signal.SIGTERM)
            print("stopped")
        else:
            print("not running")
        if "--force" in args:
            port = configured_port()
            zombie = None
            for _ in range(20):    # brief grace period for the kill above to release the port
                zombie = port_zombie(port)
                if zombie is None:
                    break
                time.sleep(0.1)
            if zombie is not None:
                zpid, zcmd = zombie
                if zpid is not None and zcmd and SCRIPT_NAME in zcmd:
                    os.kill(zpid, signal.SIGTERM)
                    print(f"killed zombie PID {zpid} holding port {port}")
                else:
                    print(f"refusing to kill {zombie_diagnosis(port, zombie)} — its command line does "
                          f"not look like {SCRIPT_NAME}; kill it yourself if that's intended")
                    sys.exit(1)

    elif cmd == "dev":
        # Foreground dev loop: serve with NEURAL_VIEW_DEV=1 and auto-restart
        # when a server-side source changes. The page polls /version (only in
        # dev mode) and reloads itself on a new boot id OR template mtime —
        # so a template edit is a browser live-reload (no restart needed; the
        # template is read per request) and a script edit is a server restart
        # followed by a browser live-reload. Ctrl-C stops everything.
        port = arg_port(args)
        pid = pid_alive()
        if pid:
            print("dev: stopping the background server first")
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.5)
        here = Path(__file__).resolve().parent
        watch = [Path(__file__).resolve(), here / "config.py", here / "board.sh", here / "paginate.sh"]

        def mtimes():
            return tuple(f.stat().st_mtime_ns if f.is_file() else 0 for f in watch)

        child_cmd = [sys.executable, os.path.abspath(__file__), "serve", "--port", str(port)]
        explicit_dir = raw_arg_dir(args)
        if explicit_dir:
            child_cmd += ["--dir", os.path.abspath(explicit_dir)]
        explicit_scan = raw_arg_scan(args)
        if explicit_scan:
            child_cmd += ["--scan", os.path.abspath(explicit_scan)]
        env = dict(os.environ, NEURAL_VIEW_DEV="1")

        def spawn():
            print(f"dev: serving http://127.0.0.1:{port} — watching {', '.join(f.name for f in watch)}; template edits live-reload the page")
            return subprocess.Popen(child_cmd, env=env)  # inherits the terminal, logs stream here

        def reap(proc):
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

        child = spawn()
        snap = mtimes()
        try:
            while True:
                time.sleep(1)
                now = mtimes()
                if now != snap:
                    snap = now
                    print("dev: change detected — restarting server")
                    reap(child)
                    child = spawn()
                elif child.poll() is not None:
                    print(f"dev: server exited (rc={child.returncode}) — waiting for a change to restart", file=sys.stderr)
                    while mtimes() == snap:
                        time.sleep(1)
                    snap = mtimes()
                    child = spawn()
        except KeyboardInterrupt:
            pass
        finally:
            if child.poll() is None:
                reap(child)
            print("\ndev: stopped")

    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
