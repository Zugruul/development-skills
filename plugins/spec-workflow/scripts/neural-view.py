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
  neural-view.py status                                         # RUNNING <url> notes=N brains=N repos=N | STOPPED
  neural-view.py stop
  neural-view.py serve [--port N] [--dir ROOT] [--scan BASE]   # run in the foreground (internal)

Repo discovery (both apply; results are deduped and sorted by repo name):
  - --dir / $NEURAL_VIEW_DIR: that root is ALWAYS included, marker or not.
  - Scan base (--scan, else $NEURAL_VIEW_SCAN, else ~/Development): every
    immediate child directory that has a <child>/.claude/.neural-network
    marker FILE is included. Directories without the marker are ignored,
    even if they have brains — inclusion is explicit and cheap.
  - If neither yields anything (no flags/env at all, empty scan base), falls
    back to the git root of the cwd — the old single-repo default.
  A discovered repo with no `.claude/identities/` brains yet still appears as
  an empty, labeled region on the canvas (nodes/edges: none) rather than being
  dropped — it shows the constellation is there, just not yet populated.

Brains live at <root>/.claude/identities/<role>/brain/ — notes/<slug>.md
(YAML-ish frontmatter + body + [[slug]] wikilinks), links.json, and
.activation.jsonl. Everything is read READ-ONLY; absent dirs/files just yield
an empty graph. Graph node ids are "<repo>/<role>/<slug>" (unique across repos);
/note/<repo>/<role>/<slug> addresses one; /events cursors are opaque and carry
a per-repo, per-role byte offset.

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
import signal
import subprocess
import sys
import threading
import time
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


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
VENDOR_FILES = {"three.module.min.js": "text/javascript; charset=utf-8"}
WIKILINK = re.compile(r"\[\[([^\]]+)\]\]")
MARKER_NAME = ".neural-network"
FAVICON = (b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">'
           b'<circle cx="16" cy="16" r="14" fill="#04070d"/>'
           b'<circle cx="16" cy="16" r="6" fill="#46e6ff"/></svg>')

REPOS = [("", Path(git_root()))]  # list of (repo_name, root); replaced by serve()

# GET /projects: per-repo board state, cached (see project_state()) so a slow/
# hung `gh` call is bounded and never re-invoked more than once per TTL.
PROJECTS_TTL = float(os.environ.get("NEURAL_VIEW_PROJECTS_TTL", "60"))
BOARD_TIMEOUT = float(os.environ.get("NEURAL_VIEW_BOARD_TIMEOUT", "12"))
BOARD_SH = Path(__file__).resolve().parent / "board.sh"
PROJECTS_CACHE = {}          # repo name -> (fetched_at, result-dict-or-None)
PROJECTS_LOCK = threading.Lock()

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


def build_graph(repos):
    """nodes = every note across every repo's brains; edges = each repo's
    links.json entries plus cross-brain consult edges derived from that repo's
    activation logs (consult never crosses a repo boundary). Node/edge ids are
    "<repo>/<role>[/<slug>]" so they stay unique across repos. `repos` in the
    payload lists every DISCOVERED repo (including brainless ones), so the
    client can still draw an empty labeled constellation for them."""
    nodes, edges = [], []
    for name, root in repos:
        for role, brain in iter_brains(root):
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
    return {"nodes": nodes, "edges": edges, "repos": [name for name, _ in repos]}


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


def render_body(body):
    """Tiny markdown → HTML: headings, paragraphs, [[wikilinks]], **bold**.
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
        r = re.sub(r"`([^`]+)`", r"<code>\1</code>", r)
        return r

    out = []
    for block in re.split(r"\n\s*\n", body.strip()):
        block = block.strip("\n")
        if not block:
            continue
        h = re.match(r"^(#{1,6})\s+(.*)$", block)
        if h:
            lvl = min(len(h.group(1)) + 2, 6)
            out.append(f"<h{lvl}>{inline(h.group(2).strip())}</h{lvl}>")
        elif all(ln.lstrip().startswith(("- ", "* ")) for ln in block.splitlines()):
            items = "".join(f"<li>{inline(ln.lstrip()[2:])}</li>" for ln in block.splitlines())
            out.append(f"<ul>{items}</ul>")
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
        lines = (proc.stderr or proc.stdout or "board.sh list failed").strip().splitlines()
        return {"ok": False, "error": (lines[-1] if lines else "board.sh list failed")[:300]}
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


def project_state(name, root):
    """A repo's board state, cached for PROJECTS_TTL seconds. Returns None
    (caller omits the repo entirely, per the /projects contract) if the repo
    has no .claude/project.yaml or .json at all — a repo that never opted
    into the board should not even show a "board unavailable" badge."""
    if _repo_config_path(root) is None:
        return None
    now = time.time()
    with PROJECTS_LOCK:
        cached = PROJECTS_CACHE.get(name)
        if cached is not None and (now - cached[0]) < PROJECTS_TTL:
            return cached[1]
    result = _run_board_list(root)
    with PROJECTS_LOCK:
        PROJECTS_CACHE[name] = (now, result)
    return result


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
            return self._send(200, build_graph(REPOS))
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
        if path.startswith("/note/"):
            parts = path[len("/note/"):].split("/", 2)
            if len(parts) == 3 and parts[0] and parts[1] and parts[2]:
                payload = note_payload(REPOS, parts[0], parts[1], parts[2])
                if payload is not None:
                    return self._send(200, payload)
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
            print(f"FAILED to start (never bound to port {port}) — see {S / 'server.log'}", file=sys.stderr)
            sys.exit(1)

    elif cmd == "status":
        if pid_alive():
            repos = load_repos_file()
            notes, brains = counts(repos)
            print(f"RUNNING http://127.0.0.1:{PORTFILE.read_text().strip()} notes={notes} brains={brains} repos={len(repos)}")
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

    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
