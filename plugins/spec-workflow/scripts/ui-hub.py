#!/usr/bin/env python3
"""ui-hub.py — local decision hub for the spec-workflow Iterative UI mode.

One long-lived page (http://127.0.0.1:<port>) the human keeps open; the agent
enqueues decision requests (self-contained HTML pages), the human answers in
place (the page POSTs back), the agent collects answers between iterations.
Stdlib only; state is plain files so everything survives restarts.

  ui-hub.py start [--port N]        # start the server in the background (idempotent)
  ui-hub.py status                  # RUNNING <url> pending=N answered=N | STOPPED
  ui-hub.py stop
  ui-hub.py ask <id> <title> <html-file> [--blocking]   # enqueue a decision card
  ui-hub.py answers [--consume]     # print answers as JSON lines; --consume archives them
  ui-hub.py serve [--port N]        # run the server in the foreground (internal)

State dir: $UI_HUB_STATE or <git root>/.claude/ui-hub (gitignore it).
Port: --port, else $UI_HUB_PORT, else 4747. Binds 127.0.0.1 only.
"""
import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def state_dir():
    env = os.environ.get("UI_HUB_STATE")
    if env:
        return Path(env)
    try:
        root = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    except Exception:  # noqa: BLE001
        root = os.getcwd()
    return Path(root) / ".claude" / "ui-hub"


S = state_dir()
INBOX, OUTBOX, ARCHIVE, HTML = S / "inbox", S / "outbox", S / "archive", S / "html"
PIDFILE, PORTFILE = S / "pid", S / "port"
DEFAULT_PORT = int(os.environ.get("UI_HUB_PORT", "4747"))

HUB_PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Decision hub</title>
<style>
:root{color-scheme:light dark;--accent:#4f6ef7;--border:#8884;--muted:#888}
body{font:15px/1.5 system-ui,sans-serif;margin:0 auto;padding:.5rem 1rem 2rem}
.top{display:flex;justify-content:space-between;align-items:flex-start;gap:1rem}
.sub{color:var(--muted);font-size:.78rem}
.sub b{color:inherit;font-weight:600}
#answered-box{position:relative;font-size:.78rem;color:var(--muted);flex-shrink:0}
#answered-box summary{cursor:pointer;list-style-position:inside}
#answered-box[open]>div{position:absolute;right:0;top:calc(100% + .3rem);z-index:90;width:min(480px,90vw);
  max-height:60vh;overflow:auto;background:Canvas;border:1px solid var(--border);border-radius:10px;padding:.6rem .8rem;box-shadow:0 8px 24px #0004}
.card{margin:1rem 0}
.card.blocking iframe{outline:2px solid var(--accent);outline-offset:-2px;border-radius:12px}
iframe{width:100%;height:88vh;border:0;display:block}
.done{border:1px solid var(--border);border-radius:12px;padding:.7rem 1rem;font-size:.88rem}
.done b{display:block;margin-bottom:.3rem}
.done pre{white-space:pre-wrap;background:#8881;border-radius:8px;padding:.6rem .8rem;font-size:.82rem}
.empty{color:var(--muted);text-align:center;padding:3rem 0}
details{margin-top:1.5rem}summary{cursor:pointer;color:var(--muted)}
</style></head><body>
<div class="top">
<div class="sub"><b>Decision hub</b> · keep this tab open — answers reach the agent automatically</div>
<details id="answered-box"><summary>Answered (<span id="ans-n">0</span>)</summary><div id="answered"></div></details>
</div>
<div id="pending"></div>
<script>
const seen = new Set(); let notifOk = false; let hubRev = null;
document.addEventListener('click', () => { if (!notifOk && 'Notification' in window) { Notification.requestPermission(); notifOk = true; } }, {once: true});
async function tick(){
  let st; try { st = await (await fetch('/api/state')).json(); } catch { return; }
  if (hubRev === null) hubRev = st.hubRev;
  else if (st.hubRev !== hubRev) { location.reload(); return; }   // hub itself was upgraded
  const p = document.getElementById('pending');
  document.title = (st.pending.length ? '('+st.pending.length+') ' : '') + 'Decision hub';
  const have = new Set([...p.querySelectorAll('.card')].map(c => c.dataset.id));
  for (const d of st.pending) {
    if (have.has(d.id)) continue;
    const c = document.createElement('div');
    c.className = 'card' + (d.blocking ? ' blocking' : ''); c.dataset.id = d.id;
    c.innerHTML = '<iframe src="/decision/' + encodeURIComponent(d.id) + '?rev=' + d.rev + '"></iframe>';
    c.dataset.rev = d.rev;
    p.prepend(c);
    if (!seen.has(d.id) && seen.size && 'Notification' in window && Notification.permission === 'granted')
      new Notification('Decision needed: ' + d.title);
  }
  for (const d of st.pending) {   // hot-reload a card whose page was regenerated
    const c = p.querySelector('.card[data-id="' + CSS.escape(d.id) + '"]');
    if (c && c.dataset.rev !== String(d.rev)) {
      c.dataset.rev = d.rev;
      c.querySelector('iframe').src = '/decision/' + encodeURIComponent(d.id) + '?rev=' + d.rev;
    }
  }
  st.pending.forEach(d => seen.add(d.id));
  for (const c of [...p.querySelectorAll('.card')])
    if (!st.pending.some(d => d.id === c.dataset.id)) c.remove();
  const a = document.getElementById('answered');
  document.getElementById('ans-n').textContent = st.answered.length;
  a.innerHTML = '';
  for (const d of st.answered.slice().reverse()) {
    const e = document.createElement('div'); e.className = 'card';
    e.innerHTML = '<div class="done"><b></b><pre></pre></div>';
    e.querySelector('b').textContent = d.title || d.id;
    e.querySelector('pre').textContent = d.selection;
    a.appendChild(e);
  }
  if (!st.pending.length) {
    if (!p.querySelector('.empty')) p.innerHTML = '<div class="empty">No decisions waiting — the agent is building. New cards appear here automatically.</div>';
  } else { const e = p.querySelector('.empty'); if (e) e.remove(); }
}
tick(); setInterval(tick, 2500);
</script></body></html>"""
HUB_REV = hashlib.md5(HUB_PAGE.encode()).hexdigest()[:8]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode() if not isinstance(body, str) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):  # quiet
        pass

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"):
            return self._send(200, HUB_PAGE, "text/html; charset=utf-8")
        if self.path == "/api/state":
            pending = sorted((json.loads(f.read_text()) for f in INBOX.glob("*.json")), key=lambda d: d["created"])
            for d in pending:  # rev = html mtime, so open tabs hot-reload a card when its page is regenerated
                f = HTML / f"{d['id']}.html"
                d["rev"] = int(f.stat().st_mtime) if f.is_file() else 0
            answered = sorted((json.loads(f.read_text()) for f in list(OUTBOX.glob("*.json")) + list((ARCHIVE / "answers").glob("*.json"))),
                              key=lambda d: d.get("answered", 0))
            return self._send(200, {"hubRev": HUB_REV, "pending": pending, "answered": answered[-20:]})
        if self.path == "/vendor/axe.min.js":
            f = Path(__file__).parent / "vendor" / "axe.min.js"
            if f.is_file():
                return self._send(200, f.read_bytes(), "text/javascript; charset=utf-8")
            return self._send(404, {"error": "axe.min.js not vendored"})
        if self.path.startswith("/decision/"):
            did = os.path.basename(self.path.split("?")[0])
            f = HTML / f"{did}.html"
            if f.is_file():
                return self._send(200, f.read_bytes(), "text/html; charset=utf-8")
            return self._send(404, {"error": "unknown decision"})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/answer":
            return self._send(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            did, selection = str(body["id"]), str(body["selection"])
        except Exception:  # noqa: BLE001
            return self._send(400, {"error": "expected JSON {id, selection}"})
        req_file = INBOX / f"{did}.json"
        meta = json.loads(req_file.read_text()) if req_file.is_file() else {"id": did}
        meta.update({"selection": selection, "answered": int(time.time())})
        if body.get("keep"):
            # partial feedback (e.g. "fix these a11y issues") — deliver to the agent
            # but keep the decision card pending so the human can still answer it
            (OUTBOX / f"{did}.fix-{int(time.time())}.json").write_text(json.dumps(meta, indent=1))
            return self._send(200, {"ok": True, "kept": True})
        (OUTBOX / f"{did}.json").write_text(json.dumps(meta, indent=1))
        if req_file.is_file():
            req_file.rename(ARCHIVE / "asked" / f"{did}.json")
        return self._send(200, {"ok": True})


def ensure_dirs():
    for d in (INBOX, OUTBOX, HTML, ARCHIVE / "asked", ARCHIVE / "answers"):
        d.mkdir(parents=True, exist_ok=True)


def pid_alive():
    try:
        pid = int(PIDFILE.read_text())
        os.kill(pid, 0)
        return pid
    except Exception:  # noqa: BLE001
        return None


def arg_port(args):
    return int(args[args.index("--port") + 1]) if "--port" in args else DEFAULT_PORT


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    args = sys.argv[2:]
    ensure_dirs()

    if cmd == "serve":
        port = arg_port(args)
        PORTFILE.write_text(str(port))
        PIDFILE.write_text(str(os.getpid()))
        ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

    elif cmd == "start":
        if pid_alive():
            print(f"RUNNING http://127.0.0.1:{PORTFILE.read_text().strip()}")
            return
        port = arg_port(args)
        log = open(S / "server.log", "ab")
        child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "serve", "--port", str(port)],
                                  stdout=log, stderr=log, start_new_session=True, env=os.environ)
        # child.poll() -- not pid_alive() -- is the correct liveness check
        # here: a crashed child (e.g. server_bind() failing because two
        # concurrent callers both probed the same free port and picked it
        # before either bound -- #55) becomes a zombie until WE reap it,
        # and os.kill(pid, 0) reports zombies as alive. child.poll() calls
        # waitpid() on our own direct child and sees the real exit status.
        for _ in range(20):
            time.sleep(0.15)
            if child.poll() is not None:
                break  # crashed -- fall through to FAILED below
            if pid_alive():
                # It's reached serve_forever() and written its pidfile.
                # bind() failure surfaces within microseconds of that, so
                # one more short beat is enough to catch a fast crash
                # without waiting out the full timeout on the happy path.
                time.sleep(0.15)
                if child.poll() is None:
                    print(f"RUNNING http://127.0.0.1:{port}")
                    return
                break
        # The child exited (or never came up). Report failure instead of
        # lying RUNNING, so a caller keeps talking to its OWN server (or
        # retries on a fresh port) rather than silently falling through
        # to whichever process actually holds this port.
        print(f"FAILED to start on port {port} -- see {S / 'server.log'}")
        sys.exit(1)

    elif cmd == "status":
        pid = pid_alive()
        if pid:
            print(f"RUNNING http://127.0.0.1:{PORTFILE.read_text().strip()} "
                  f"pending={len(list(INBOX.glob('*.json')))} answered={len(list(OUTBOX.glob('*.json')))}")
        else:
            print("STOPPED")
            sys.exit(1)

    elif cmd == "stop":
        pid = pid_alive()
        if pid:
            os.kill(pid, signal.SIGTERM)
            # Unlike start's own-child check (#55, where child.poll() is
            # required because a crashed direct child becomes a zombie
            # until WE reap it, and kill(pid, 0) reports zombies as
            # alive), stop's target is a DETACHED server started with
            # start_new_session=True -- it is not our child, there is no
            # zombie-until-reaped window, and kill(pid, 0) is the correct
            # liveness check here.
            for _ in range(20):
                time.sleep(0.15)
                if not pid_alive():
                    print("stopped")
                    return
            # Still alive after the bound: report truthfully instead of
            # claiming success. No auto-escalation to SIGKILL -- stop is
            # polite by design; forceful teardown is a separate decision
            # the caller should make explicitly.
            print(f"still running after SIGTERM -- kill {pid} yourself or retry")
            sys.exit(1)
        else:
            print("not running")

    elif cmd == "ask":
        did, title, html_file = args[0], args[1], args[2]
        (HTML / f"{did}.html").write_bytes(Path(html_file).read_bytes())
        (INBOX / f"{did}.json").write_text(json.dumps(
            {"id": did, "title": title, "blocking": "--blocking" in args, "created": int(time.time())}, indent=1))
        pid = pid_alive()
        url = f"http://127.0.0.1:{PORTFILE.read_text().strip()}" if pid else "(server STOPPED — run: ui-hub.py start)"
        print(f"asked '{did}' — hub: {url}")

    elif cmd == "answers":
        for f in sorted(OUTBOX.glob("*.json")):
            print(f.read_text().replace("\n", " "))
            if "--consume" in args:
                f.rename(ARCHIVE / "answers" / f.name)

    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
