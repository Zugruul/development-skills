#!/usr/bin/env python3
"""neural-view.py — a live, JARVIS-style visualization of the identity brains.

The identities' brains are the workflow's memory: markdown notes ("neurons")
wired by weighted links ("synapses"), with an append-only activation log of
every recall. This is a read-only window into them — one long-lived page
(http://127.0.0.1:<port>) that draws every brain as a neural cluster and, as
recalls happen, lights the neurons up and pulses the synapses in real time.

  neural-view.py start [--port N] [--dir ROOT]   # start the server (idempotent)
  neural-view.py status                           # RUNNING <url> notes=N brains=N | STOPPED
  neural-view.py stop
  neural-view.py serve [--port N] [--dir ROOT]    # run in the foreground (internal)

Brains root: --dir, else $NEURAL_VIEW_DIR, else the git root, else cwd. Brains
live at <root>/.claude/identities/<role>/brain/ — notes/<slug>.md (YAML-ish
frontmatter + body + [[slug]] wikilinks), links.json, and .activation.jsonl.
Everything is read READ-ONLY; absent dirs/files just yield an empty graph.

State dir (pid/port/log): $NEURAL_VIEW_STATE, else <git root>/.claude/neural-view.
Port: --port, else $NEURAL_VIEW_PORT, else 4748. Binds 127.0.0.1 only.
"""
import json
import os
import re
import signal
import subprocess
import sys
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
PIDFILE, PORTFILE, DIRFILE = S / "pid", S / "port", S / "dir"
DEFAULT_PORT = int(os.environ.get("NEURAL_VIEW_PORT", "4748"))
TEMPLATE = Path(__file__).resolve().parent.parent / "templates" / "neural-view.html"
WIKILINK = re.compile(r"\[\[([^\]]+)\]\]")

BRAINS_ROOT = Path(git_root())  # replaced by serve()


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


def read_note(brain, slug):
    f = brain / "notes" / f"{slug}.md"
    if not f.is_file():
        return None
    return parse_note(f.read_text(errors="replace"))


def build_graph(root):
    """nodes = every note across ALL brains; edges = links.json entries plus
    cross-brain consult edges derived from the activation logs."""
    nodes, edges = [], []
    for role, brain in iter_brains(root):
        notes_dir = brain / "notes"
        if notes_dir.is_dir():
            for f in sorted(notes_dir.glob("*.md")):
                fm, _ = parse_note(f.read_text(errors="replace"))
                slug = f.stem
                nodes.append({
                    "id": f"{role}/{slug}",
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
                    "source": f"{role}/{src.strip()}",
                    "target": f"{role}/{dst.strip()}",
                    "weight": meta.get("weight", 0.5),
                    "fires": meta.get("fires", 0),
                    "last": meta.get("last", ""),
                })
    # cross-brain consult edges: consumer role reaches into another role's brain
    seen = set()
    for ev in read_events(root):
        if ev.get("event") != "consult":
            continue
        consumer, role = ev.get("consumer"), ev.get("role")
        if not consumer or not role or consumer == role:
            continue
        key = (consumer, role)
        if key in seen:
            continue
        seen.add(key)
        edges.append({"source": consumer, "target": role, "type": "consult", "weight": 0.4})
    return {"nodes": nodes, "edges": edges}


def read_events(root):
    """Every .activation.jsonl line across brains, ordered by timestamp so a
    freshly appended line always lands at the end (stable monotonic cursor)."""
    evts = []
    for role, brain in iter_brains(root):
        f = brain / ".activation.jsonl"
        if not f.is_file():
            continue
        for line in f.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:  # noqa: BLE001
                continue
            if isinstance(obj, dict):
                obj.setdefault("role", role)
                evts.append(obj)
    evts.sort(key=lambda e: str(e.get("ts", "")))  # stable: ties keep file order
    return evts


def render_body(body):
    """Tiny markdown → HTML: headings, paragraphs, [[wikilinks]], **bold**.
    Deliberately minimal — stdlib only, and it preserves plain prose verbatim."""
    def inline(s):
        s = escape(s)
        s = WIKILINK.sub(lambda m: f'<a class="wl" data-slug="{escape(m.group(1).strip())}">{escape(m.group(1).strip())}</a>', s)
        s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        return s

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


def note_payload(root, role, slug):
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
        return {"role": role, "slug": slug, "frontmatter": fm, "bodyHtml": render_body(body), "links": links}
    return None


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
        if path == "/graph":
            return self._send(200, build_graph(BRAINS_ROOT))
        if path == "/events":
            since = 0
            q = self.path.split("?", 1)[1] if "?" in self.path else ""
            for kv in q.split("&"):
                if kv.startswith("since="):
                    try:
                        since = max(0, int(kv[6:]))
                    except ValueError:
                        since = 0
            evts = read_events(BRAINS_ROOT)
            return self._send(200, {"cursor": len(evts), "events": evts[since:]})
        if path.startswith("/note/"):
            parts = path[len("/note/"):].split("/", 1)
            if len(parts) == 2 and parts[0] and parts[1]:
                payload = note_payload(BRAINS_ROOT, parts[0], parts[1])
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


def arg_dir(args):
    return arg_val(args, "--dir", os.environ.get("NEURAL_VIEW_DIR") or git_root())


def counts(root):
    brains = list(iter_brains(root))
    notes = sum(len(list((b / "notes").glob("*.md"))) for _, b in brains if (b / "notes").is_dir())
    return notes, len(brains)


def main():
    global BRAINS_ROOT
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    args = sys.argv[2:]
    ensure_dirs()

    if cmd == "serve":
        port, root = arg_port(args), os.path.abspath(arg_dir(args))
        BRAINS_ROOT = Path(root)
        httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)  # bind before pidfile
        PORTFILE.write_text(str(port))
        DIRFILE.write_text(root)
        PIDFILE.write_text(str(os.getpid()))
        httpd.serve_forever()

    elif cmd == "start":
        if pid_alive():
            print(f"RUNNING http://127.0.0.1:{PORTFILE.read_text().strip()}")
            return
        port, root = arg_port(args), os.path.abspath(arg_dir(args))
        log = open(S / "server.log", "ab")
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "serve", "--port", str(port), "--dir", root],
                         stdout=log, stderr=log, start_new_session=True, env=os.environ)
        for _ in range(30):
            time.sleep(0.1)
            if pid_alive():
                break
        print(f"RUNNING http://127.0.0.1:{port}")

    elif cmd == "status":
        if pid_alive():
            root = DIRFILE.read_text().strip() if DIRFILE.is_file() else git_root()
            notes, brains = counts(root)
            print(f"RUNNING http://127.0.0.1:{PORTFILE.read_text().strip()} notes={notes} brains={brains}")
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
