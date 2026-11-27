"""AST-081: real queue/SQLite/native API/ephemeral OpenSSH lifecycle tests."""
import base64
import copy
import getpass
import hashlib
import importlib
import json
import os
from pathlib import Path
import queue
import signal
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock
from urllib.parse import parse_qs, urlsplit

import yaml

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from assistant import artifacts, capability_index, engine, observability, remote_audit, tasks

NAME = "comfyui-render"
SECRET = "AST081_PRIVATE_SENTINEL_9234"
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=")
GRAPH = {"1": {"class_type": "FixtureImage", "inputs": {"text": "fixture", "seed": 1, "model": "fixture.safetensors"}},
         "2": {"class_type": "SaveImage", "inputs": {"images": ["1", 0], "filename_prefix": "fixture"}}}
INFO = {"FixtureImage": {"input": {"required": {"text": ["STRING"], "seed": ["INT"], "model": [["fixture.safetensors"]]}}},
        "SaveImage": {"input": {"required": {"images": ["IMAGE"], "filename_prefix": ["STRING"]}}}}


def until(fn, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError("bounded condition did not become true")


def render_module():
    return importlib.import_module("assistant.comfyui_render")


class NativeFixture:
    """Wire-compatible queue/history, including old global interrupt semantics."""
    def __init__(self):
        self.pending, self.running, self.history = [], [], {}
        self.posts, self.deletes, self.interrupts, self.ws_connections = [], [], 0, 0
        self.drop_post = False
        self.before_post = lambda body: None
        self.before_delete = lambda ids: None
        self.info, self.image = copy.deepcopy(INFO), PNG
        self.filename = "fixture.png"
        self.events = []
        self.bad_accept = False
        self.slow_headers = False
        self.redirect = False
        self.info_delay = 0
        self.history_paths = []
        self.history_overrides = {}
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, body, mime="application/json"):
                body = json.dumps(body).encode() if mime == "application/json" else body
                self.send_response(200)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path.startswith("/ws?"):
                    owner.ws_connections += 1
                    key = self.headers["Sec-WebSocket-Key"]
                    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                    if owner.bad_accept:
                        accept = accept.swapcase()
                    self.send_response(101)
                    self.send_header("Upgrade", "websocket")
                    self.send_header("Connection", "Upgrade")
                    self.send_header("Sec-WebSocket-Accept", accept)
                    self.end_headers()
                    for event in owner.events:
                        body = json.dumps(event).encode()
                        header = bytes([0x81, len(body)]) if len(body) < 126 else b"\x81\x7e" + struct.pack("!H", len(body))
                        self.wfile.write(header + body)
                    self.wfile.flush()
                    return
                if self.path == "/object_info":
                    if owner.info_delay:
                        time.sleep(owner.info_delay)
                    if owner.redirect:
                        self.send_response(302)
                        self.send_header("Location", "http://192.0.2.1/never")
                        self.end_headers()
                        return
                    if owner.slow_headers:
                        try:
                            for byte in b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}":
                                self.connection.sendall(bytes([byte]))
                                time.sleep(.03)
                        except OSError:
                            pass
                        return
                    self.reply(owner.info)
                elif self.path == "/queue":
                    self.reply({"queue_running": owner.running, "queue_pending": owner.pending})
                elif self.path.startswith("/history"):
                    owner.history_paths.append(self.path)
                    url = urlsplit(self.path)
                    if url.path == "/history":
                        count = int(parse_qs(url.query).get("max_items", ["256"])[0])
                        self.reply(dict(list(owner.history.items())[-count:]))
                    elif url.path.startswith("/history/"):
                        prompt_id = url.path[len("/history/"):]
                        self.reply(owner.history_overrides.get(prompt_id,
                            {prompt_id: owner.history[prompt_id]} if prompt_id in owner.history else {}))
                    else:
                        self.send_error(404)
                elif self.path.startswith("/view?"):
                    self.reply(owner.image, "image/png")
                else:
                    self.send_error(404)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path == "/prompt":
                    owner.before_post(body)
                    owner.posts.append(body)
                    prompt_id = "backend-" + str(len(owner.posts))
                    owner.pending.append([1, prompt_id, body["prompt"], body["extra_data"], ["2"]])
                    if owner.drop_post:
                        self.connection.shutdown(socket.SHUT_RDWR)
                        self.connection.close()
                    else:
                        self.reply({"prompt_id": prompt_id, "number": 1, "node_errors": {}})
                elif self.path == "/queue":
                    owner.before_delete(body.get("delete", []))
                    owner.deletes.append(body)
                    owner.pending[:] = [p for p in owner.pending if p[1] not in body.get("delete", [])]
                    self.send_response(200)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                elif self.path == "/interrupt":
                    owner.interrupts += 1
                    owner.running.clear()  # old server ignores IDs and interrupts foreign work
                    self.reply({})
                else:
                    self.send_error(404)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def complete(self, failure=None):
        item = (self.pending or self.running)[0]
        self.pending.clear()
        self.running.clear()
        status = {"completed": True, "status_str": "success", "messages": []}
        if failure:
            status = {"completed": False, "status_str": "error", "messages": [["execution_error", {"exception_type": failure, "exception_message": SECRET}]]}
        self.history[item[1]] = {"prompt": item, "status": status,
            "outputs": {"2": {"images": [{"filename": self.filename, "subfolder": "", "type": "output", "artifact_path": SECRET}]}}}

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)


class SSHFixture:
    """Dedicated local daemon, no live enrollment or machine configuration writes."""
    def __init__(self, target):
        self.tmp = tempfile.TemporaryDirectory(prefix=".ast081-", dir=Path.home())
        self.root = Path(self.tmp.name)
        for name in ("host", "key", "wrong"):
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.root / name)], check=True, capture_output=True)
        # The API keeps its listener open. SSH and tunnel ports cannot alias it.
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        (self.root / "authorized").write_text('restrict,port-forwarding,permitopen="127.0.0.1:%d" ' % target + (self.root / "key.pub").read_text())
        (self.root / "config").write_text("\n".join([
            "ListenAddress 127.0.0.1", f"Port {self.port}", f"HostKey {self.root / 'host'}",
            f"PidFile {self.root / 'pid'}", f"AuthorizedKeysFile {self.root / 'authorized'}",
            "StrictModes yes", "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no",
            "PermitRootLogin no", "AllowTcpForwarding local", "AllowStreamLocalForwarding no",
            "MaxSessions 0", "PermitTunnel no", "PermitUserRC no", "AllowAgentForwarding no",
            "X11Forwarding no", "GatewayPorts no", f"AllowUsers {getpass.getuser()}", "LogLevel VERBOSE", ""]))
        self.log = (self.root / "log").open("wb")
        self.proc = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(self.root / "config")], stdout=self.log, stderr=self.log, start_new_session=True)
        def ready():
            if self.proc.poll() is not None:
                raise AssertionError((self.root / "log").read_text())
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=.1):
                    return True
            except OSError:
                return False
        until(ready)
        pub = (self.root / "host.pub").read_text().split()
        (self.root / "pins").write_text(f"[127.0.0.1]:{self.port} {pub[0]} {pub[1]}\n")
        self.entry = {"host": "127.0.0.1", "port": self.port, "user": getpass.getuser(),
                      "knownHosts": str(self.root / "pins"), "keys": {"tunnel": str(self.root / "key")}, "comfyPort": target}

    def close(self):
        if self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
        self.proc.wait(timeout=5)
        self.log.close()
        self.tmp.cleanup()


@unittest.skipUnless(Path("/usr/sbin/sshd").exists(), "requires local ephemeral OpenSSH")
class TransportContracts(unittest.TestCase):
    def fixture(self):
        api = NativeFixture()
        self.addCleanup(api.close)
        ssh = SSHFixture(api.port)
        self.addCleanup(ssh.close)
        return api, ssh, importlib.import_module("assistant.comfyui_transport")

    def test_total_slow_drip_redirect_and_other_port_refused(self):
        api, ssh, transport = self.fixture()
        with transport.Tunnel(ssh.entry) as tunnel:
            api.slow_headers = True
            start = time.monotonic()
            with self.assertRaises(transport.TransportError):
                tunnel.request("/object_info", timeout=.2)
            self.assertLess(time.monotonic() - start, .8)
            api.slow_headers, api.redirect = False, True
            with self.assertRaises(transport.TransportError):
                tunnel.json("/object_info")
        other = NativeFixture()
        self.addCleanup(other.close)
        with transport.Tunnel({**ssh.entry, "comfyPort": other.port}) as tunnel:
            with self.assertRaises(transport.TransportError):
                tunnel.json("/object_info")

    def test_websocket_accept_is_case_sensitive(self):
        api = NativeFixture()
        self.addCleanup(api.close)
        ssh = SSHFixture(api.port)
        self.addCleanup(ssh.close)
        transport = importlib.import_module("assistant.comfyui_transport")
        api.events = [{"type": "progress", "data": {"prompt_id": "owned", "node": "1", "value": 1, "max": 2}}]
        api.bad_accept = True
        with transport.Tunnel(ssh.entry) as tunnel:
            self.assertEqual(tunnel.progress("a" * 32, "owned", {"1"}), [])


class Admission(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ast081-engine-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = {"version": 1, "enabled": True, "names": ["fixture"], "systemPrompt": "fixture",
                       "llm": {"provider": "openai", "model": "fixture"},
                       "capabilities": {"codex": {"enabled": True}, NAME: {"enabled": True}}}
        (self.root / ".neural-network").mkdir()
        self.write_config()
        self.eng = engine.AssistantEngine(lambda: [("fixture", str(self.root))], str(self.root / "state"))
        entry = capability_index.CapabilityIndexEntry(NAME, "Render image", [], [], True, True, None)
        self.eng._on_capability_index_compiled(str(self.root), capability_index.CapabilityIndex([entry]))
        self.params = {"host": "gpu", "operation": "render", "workflow": "image", "values": '{"text":"fixture"}', "task_id": ""}

    def write_config(self):
        (self.root / ".neural-network/project.yaml").write_text(yaml.safe_dump({"assistant": self.config}))

    def request(self, params=None):
        hook = self.eng._capability_reply_hook_for(str(self.root), "turn-render", "render image", self.config)
        return hook("```capability\n" + json.dumps({"name": NAME.upper(), "params": params or self.params}) + "\n```", {}, lambda *a, **k: {"text": "followup"}, {})

    def test_always_managed_before_manifest_or_long_running_lookup(self):
        reply = self.request()
        self.assertIn("queued", reply["text"])
        item = self.eng.queues["tasks"].get_nowait()
        self.assertEqual(item["kind"], NAME)
        self.assertNotIn("capability", item["payload"])

    def test_generic_queue_and_trace_do_not_copy_secrets(self):
        params = {**self.params, "values": json.dumps({"text": "password=" + SECRET}), "private": SECRET}
        self.request(params)
        for name in ("tasks", "traces"):
            with self.eng.queues[name].mutex:
                self.assertNotIn(SECRET, repr(list(self.eng.queues[name].queue)))
        q = queue.Queue()
        tasks.enqueue(q, str(self.root), capability_index.KIND, {"name": NAME.upper(), "params": params, "assistant_cfg": {"token": SECRET}})
        item = q.get_nowait()
        self.assertEqual(item["kind"], NAME)
        self.assertNotIn(SECRET, repr(item))

    def test_known_credentials_inside_plain_prompt_refused_before_queue(self):
        self.config["capabilities"][NAME]["provisioning"] = {"token": SECRET}
        self.write_config()
        params = {**self.params, "values": json.dumps({"text": "draw the words " + SECRET})}
        self.request(params)
        with self.eng.queues["tasks"].mutex:
            self.assertNotIn(SECRET, repr(list(self.eng.queues["tasks"].queue)))
        q = queue.Queue()
        tasks.enqueue(q, str(self.root), NAME, {"params": params})
        self.assertNotIn(SECRET, repr(q.get_nowait()))

    def test_generic_engine_exception_does_not_persist_private_text(self):
        with mock.patch.object(self.eng, "capability_index_for", side_effect=RuntimeError(SECRET)):
            self.request()
        with self.eng.queues["traces"].mutex:
            self.assertNotIn(SECRET, repr(list(self.eng.queues["traces"].queue)))

    def test_trace_failure_unhashable_metadata_never_raises(self):
        class Broken:
            def put_nowait(self, item):
                raise RuntimeError("fixture")
        for value in ([], {}, {"x": 1}):
            observability.emit(Broken(), str(self.root), {"kind": "turn.start", "payload": {"kind": value}})

    def test_legacy_enqueue_unhashable_kind_keeps_never_raises_contract(self):
        self.assertIsNotNone(tasks.enqueue(queue.Queue(), str(self.root), [], {}))

    def test_escaped_known_credentials_refused_as_decoded_strings(self):
        for suffix in ('quote"end', 'slash\\end', 'unicode\u00e9'):
            secret = SECRET + suffix
            self.config["capabilities"][NAME]["provisioning"] = {"token": secret}
            self.write_config()
            params = {**self.params, "values": json.dumps({"text": "draw " + secret})}
            q = queue.Queue()
            tasks.enqueue(q, str(self.root), NAME, {"params": params})
            self.assertNotIn(SECRET, repr(q.get_nowait()))

    def test_legacy_database_migration_serializes_concurrent_openers(self):
        state = self.root / ".claude/assistant"
        state.mkdir(parents=True)
        with sqlite3.connect(state / "tasks.sqlite") as conn:
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute(tasks._SCHEMA_DDL)
        barrier = threading.Barrier(2)
        original = sqlite3.connect
        errors = []
        class Connection(sqlite3.Connection):
            def execute(self, sql, *args):
                if sql.startswith("ALTER TABLE tasks") and not self.in_transaction:
                    barrier.wait(3)
                return super().execute(sql, *args)
        def connect(*args, **kwargs):
            return original(*args, factory=Connection, **kwargs)
        def open_database():
            try:
                tasks._open_conn(str(self.root)).close()
            except Exception as exc:
                errors.append((type(exc).__name__, str(exc)))
        with mock.patch.object(tasks.sqlite3, "connect", side_effect=connect):
            threads = [threading.Thread(target=open_database) for _ in range(2)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(6)
                self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])


class QueueAdmission(Admission):
    def fill_tasks(self):
        self.eng.queues["tasks"] = queue.Queue(maxsize=1)
        self.eng.queues["tasks"].put_nowait({"occupied": True})

    def queued_events(self):
        with self.eng.queues["traces"].mutex:
            return [item["event"] for item in self.eng.queues["traces"].queue]

    def test_r2_render_and_cancel_queue_refusals_are_linked_and_private(self):
        self.fill_tasks()
        mod = render_module()
        for operation, expected in (("render", "submit"), ("cancel", "cancel")):
            with self.subTest(operation=operation):
                params = {**self.params, "operation": operation,
                          "values": json.dumps({"text": SECRET}) if operation == "render" else "{}",
                          "task_id": "a" * 32 if operation == "cancel" else ""}
                with mock.patch.object(mod, "Tunnel") as tunnel, mock.patch.object(observability, "emit_ack") as ack:
                    reply = self.request(params)
                tunnel.assert_not_called()
                ack.assert_not_called()
                self.assertIn("could not queue", reply["text"])
                self.assertEqual(self.eng.queues["tasks"].qsize(), 1)
                self.assertFalse((self.root / ".claude/assistant/tasks.sqlite").exists())
                events = self.queued_events()
                self.assertNotIn(SECRET, repr(events))
                outcomes = [e for e in events if e["kind"] == "remote.command.outcome"
                            and e["payload"].get("operation") == expected]
                self.assertEqual(len(outcomes), 1)
                event = outcomes[0]
                self.assertEqual(event["skill"], NAME)
                self.assertEqual(event["status"], "refused")
                self.assertEqual(event["turn_id"], "turn-render")
                self.assertEqual(event["parent_span_id"], "turn-render")
                self.assertEqual(event["session_id"], str(self.root.resolve()))
                self.assertRegex(event["span_id"], r"^[a-f0-9]{32}$")
                self.assertEqual(event["payload"], {"command_id": event["span_id"], "task_id": None,
                    "operation": expected, "host": "gpu", "reason": "queue_full"})
        events = self.queued_events()
        self.assertFalse(any(e["kind"] == "remote.command.intent" for e in events))
        self.assertEqual(len({e["span_id"] for e in events if e["kind"] == "remote.command.outcome"}), 2)
        stop = threading.Event()
        writer = threading.Thread(target=observability.run_writer,
            kwargs={"q": self.eng.queues["traces"], "stop_event": stop, "poll_timeout": .01})
        writer.start()
        try:
            until(lambda: len([e for e in observability.query(str(self.root))
                               if e["kind"] == "remote.command.outcome"]) == 2)
            for path in (self.root / ".claude/assistant").glob("traces.sqlite*"):
                self.assertNotIn(SECRET.encode(), path.read_bytes(), str(path))
        finally:
            stop.set()
            writer.join(3)
            self.assertFalse(writer.is_alive())

    def test_r2_full_trace_queue_refusal_is_best_effort_without_ack(self):
        self.fill_tasks()
        self.eng.queues["traces"] = queue.Queue(maxsize=1)
        self.eng.queues["traces"].put_nowait({"occupied": True})
        with mock.patch.object(observability, "emit", wraps=observability.emit) as emit, \
                mock.patch.object(observability, "emit_ack") as ack, \
                mock.patch.object(render_module(), "Tunnel") as tunnel:
            start = time.monotonic()
            reply = self.request()
            self.assertLess(time.monotonic() - start, .5)
        self.assertIn("could not queue", reply["text"])
        ack.assert_not_called()
        tunnel.assert_not_called()
        attempted = [call.args[2] for call in emit.call_args_list]
        self.assertTrue(any(e["kind"] == "remote.command.outcome" and e["status"] == "refused" for e in attempted))
        self.assertEqual(self.eng.queues["traces"].get_nowait(), {"occupied": True})
        self.assertFalse((self.root / ".claude/assistant/tasks.sqlite").exists())

    def test_r2_remote_control_queue_refusal_keeps_legacy_descriptor(self):
        self.fill_tasks()
        hook = self.eng._capability_reply_hook_for(str(self.root), "turn-control", "inspect job", self.config)
        reply = hook("```capability\n" + json.dumps({"name": remote_audit.NAME,
            "params": {"operation": "status", "host": "gpu", "job_id": "job-one"}}) + "\n```",
            {}, lambda *a, **k: {"text": "followup"}, {})
        self.assertIn("could not queue", reply["text"])
        outcomes = [e for e in self.queued_events() if e["kind"] == "remote.command.outcome"]
        self.assertEqual(len(outcomes), 1)
        event = outcomes[0]
        self.assertEqual((event["skill"], event["turn_id"], event["status"]),
                         (remote_audit.NAME, "turn-control", "refused"))
        self.assertEqual(event["payload"], {"command_id": event["span_id"], "task_id": None,
            "operation": "status", "host": "gpu", "job_id": "job-one", "reason": "queue_full"})


@unittest.skipUnless(Path("/usr/sbin/sshd").exists(), "requires local ephemeral OpenSSH")
class Lifecycle(Admission):
    def setUp(self):
        super().setUp()
        self.mod = render_module()
        self.api = NativeFixture()
        self.addCleanup(self.api.close)
        self.ssh = SSHFixture(self.api.port)
        self.addCleanup(self.ssh.close)
        self.skill = self.mod.install(self.root)
        self.manifest_path = self.skill / "capability.yaml"
        self.graph_path = self.root / "template.json"
        self.graph_path.write_text(json.dumps(GRAPH))
        self.manifest = yaml.safe_load(self.manifest_path.read_text())
        self.manifest["longRunning"] = False
        self.manifest["provisioning"]["hosts"] = {"gpu": self.ssh.entry}
        self.manifest["provisioning"]["workflows"] = {"image": {
            "template": str(self.graph_path), "sha256": hashlib.sha256(self.graph_path.read_bytes()).hexdigest(), "timeout": 30,
            "inputs": {"text": {"node": "1", "input": "text", "type": "string", "maxLength": 128},
                       "seed": {"node": "1", "input": "seed", "type": "integer", "minimum": 0, "maximum": 100}},
            "output": {"node": "2", "field": "images", "index": 0, "type": "png", "maxBytes": 100000}}}
        self.write_manifest()
        self.stops, self.threads = [], []
        self.addCleanup(self.stop_workers)

    def write_manifest(self):
        self.manifest_path.write_text(yaml.safe_dump(self.manifest))

    def worker(self, target, **kwargs):
        stop = threading.Event()
        thread = threading.Thread(target=target, kwargs={"stop_event": stop, **kwargs})
        self.stops.append(stop)
        self.threads.append(thread)
        thread.start()
        return stop, thread

    def start(self, writer=True):
        if writer:
            self.worker(observability.run_writer, q=self.eng.queues["traces"], poll_timeout=.01)
        return self.worker(tasks.run_worker, q=self.eng.queues["tasks"], traces_queue=self.eng.queues["traces"],
            executors={NAME: self.mod.run_task, "legacy": lambda p, r: {"result": {"state": "in_progress"}}},
            resolvers={NAME: self.mod.resolve_task}, repos_getter=lambda: [("fixture", str(self.root))],
            live_reconcile_interval=.2, poll_timeout=.01)

    def stop_workers(self):
        for stop in self.stops:
            stop.set()
        for thread in self.threads:
            thread.join(10)
            self.assertFalse(thread.is_alive())

    def row(self, terminal=False, task_id=None):
        return until(lambda: next((r for r in tasks.list_tasks(str(self.root)) if r["kind"] == NAME
            and (task_id is None or r["id"] == task_id) and (not terminal or r["state"] in {"completed", "failed", "orphaned"})), None))

    def events(self):
        return observability.query(str(self.root), limit=2000)

    def test_native_tunnel_submission_progress_and_atomic_artifact(self):
        def committed(body):
            row = self.row()
            self.assertEqual(row["recovery"]["request_id"], body["extra_data"]["assistant_request_id"])
            self.assertEqual(row["recovery"]["phase"], "posting")
            self.assertTrue(any(e["kind"] == "remote.command.intent" and e["payload"]["operation"] == "submit" for e in self.events()))
        self.api.before_post = committed
        self.start()
        self.request()
        until(lambda: self.api.posts)
        row = until(lambda: (r if (r := self.row())["external_job_id"] else None))
        self.assertEqual(row["state"], "progress")
        self.api.events = [{"type": "progress", "data": {"prompt_id": "foreign", "value": 99, "max": 100, "node": "1"}},
                           {"type": "progress", "data": {"prompt_id": row["external_job_id"], "value": 2, "max": 4, "node": "1", "private": SECRET}}]
        until(lambda: any(e["kind"] == "task.progress" and e["payload"].get("progress", {}).get("value") == 2 for e in self.events()))
        legacy = tasks.enqueue(self.eng.queues["tasks"], str(self.root), "legacy", {})
        until(lambda: (r := tasks.get_task(str(self.root), legacy)) and r["state"] == "completed")
        self.api.complete()
        row = self.row(True)
        self.assertEqual(row["state"], "completed", row)
        resolved, size = artifacts.resolve(str(self.root), row["id"])
        artifact = Path(resolved)
        self.assertEqual(size, len(PNG))
        self.assertEqual(artifact.read_bytes(), PNG)
        self.assertEqual(artifact.name, row["id"] + ".png")
        self.assertGreater(self.api.ws_connections, 0)
        events = self.events()
        self.assertTrue(any(e["kind"] == "remote.command.outcome" and e["status"] == "success" and e["payload"]["operation"] == "transfer" for e in events))
        self.assertFalse(any(e["payload"].get("progress", {}).get("value") == 99 for e in events))
        for path in (self.root / ".claude/assistant").glob("*.sqlite*"):
            self.assertNotIn(SECRET.encode(), path.read_bytes())

    def test_dropped_post_restart_and_trace_pruning_never_replays(self):
        self.api.drop_post = True
        stop, thread = self.start()
        self.request()
        until(lambda: self.api.posts)
        stop.set()
        thread.join(10)
        row = self.row()
        deadline = row["recovery"]["deadline"]
        submit_outcomes = [e for e in self.events() if e["kind"] == "remote.command.outcome" and e["payload"]["operation"] == "submit"]
        self.assertEqual([e["status"] for e in submit_outcomes], ["unknown"])
        # Prunable traces are not ownership authority.
        with sqlite3.connect(self.root / ".claude/assistant/traces.sqlite") as conn:
            conn.execute("DELETE FROM events")
        self.start(writer=False)
        until(lambda: self.row()["external_job_id"] == "backend-1")
        self.api.complete()
        row = self.row(True)
        self.assertEqual(row["state"], "completed", row)
        self.assertEqual(row["recovery"]["deadline"], deadline)
        self.assertEqual(len(self.api.posts), 1)

    def test_lost_history_is_orphaned_without_resubmission(self):
        self.start()
        self.request()
        until(lambda: self.api.posts)
        self.api.pending.clear()
        row = self.row(True)
        self.assertEqual(row["state"], "orphaned", row)
        self.assertEqual(len(self.api.posts), 1)

    def test_cancel_race_never_interrupts_foreign_running_work(self):
        self.start()
        self.request()
        until(lambda: self.api.posts)
        render = self.row()
        foreign = [2, "foreign-running", GRAPH, {"assistant_request_id": "foreign"}, ["2"]]
        self.api.running.append(copy.deepcopy(foreign))
        def race(ids):
            self.api.running.extend(self.api.pending)
            self.api.pending.clear()
        self.api.before_delete = race
        self.request({**self.params, "operation": "cancel", "task_id": render["id"], "values": "{}"})
        cancel = until(lambda: next((r for r in tasks.list_tasks(str(self.root)) if r["id"] != render["id"] and r["state"] == "completed"), None))
        self.assertEqual(cancel["result"]["state"], "cancelling")
        self.assertEqual(self.api.interrupts, 0)
        self.assertIn(foreign, self.api.running)
        self.assertEqual(self.api.deletes, [{"delete": ["backend-1"]}])
        self.assertEqual(self.row(task_id=render["id"])["state"], "progress")

    def test_empty_delete_receipt_is_unknown_and_unknown_task_refused(self):
        self.start()
        self.request()
        until(lambda: self.api.posts)
        render = self.row()
        self.request({**self.params, "operation": "cancel", "task_id": render["id"], "values": "{}"})
        cancel = until(lambda: next((r for r in tasks.list_tasks(str(self.root)) if r["id"] != render["id"] and r["state"] == "completed"), None))
        self.assertEqual(cancel["result"]["state"], "unknown")
        self.assertEqual(self.row(True, render["id"])["state"], "orphaned")
        self.request({**self.params, "operation": "cancel", "task_id": "a" * 32, "values": "{}"})
        until(lambda: any(r["state"] == "failed" for r in tasks.list_tasks(str(self.root))))
        self.assertEqual(len(self.api.deletes), 1)

    def test_deadline_checked_after_dependencies_before_post(self):
        self.manifest["provisioning"]["workflows"]["image"]["timeout"] = 1
        self.write_manifest()
        self.api.info_delay = 1.1
        self.start()
        self.request()
        row = self.row(True)
        self.assertEqual(self.api.posts, [])
        self.assertIn("deadline", row["error"])

    def test_recovery_refuses_changed_endpoint_and_multiple_owned_matches(self):
        stop, thread = self.start()
        self.request()
        until(lambda: self.api.posts)
        stop.set()
        thread.join(10)
        self.manifest["provisioning"]["hosts"]["gpu"]["comfyPort"] += 1
        self.write_manifest()
        self.start(writer=False)
        row = self.row(True)
        self.assertEqual(row["state"], "orphaned")
        self.assertIn("binding", row["error"])
        self.assertEqual(len(self.api.posts), 1)

    def test_ambiguous_post_ownership_is_not_replayed(self):
        self.api.drop_post = True
        stop, thread = self.start()
        self.request()
        until(lambda: self.api.posts)
        stop.set()
        thread.join(10)
        duplicate = copy.deepcopy(self.api.pending[0])
        duplicate[1] = "second-prompt"
        self.api.pending.append(duplicate)
        self.start(writer=False)
        self.assertEqual(self.row(True)["state"], "orphaned")
        self.assertEqual(len(self.api.posts), 1)

    def test_artifact_symlink_and_hostile_filename_refused(self):
        self.start()
        self.request()
        until(lambda: self.api.posts)
        row = self.row()
        directory = self.root / artifacts.ARTIFACTS_DIR_REL
        directory.mkdir(exist_ok=True)
        victim = self.root / "victim.png"
        victim.write_bytes(b"unchanged")
        (directory / (row["id"] + ".png")).symlink_to(victim)
        self.api.complete()
        self.assertNotEqual(self.row(True)["state"], "completed")
        self.assertEqual(victim.read_bytes(), b"unchanged")
        self.request()
        until(lambda: len(self.api.posts) == 2)
        self.api.filename = "../../victim.png"
        self.api.complete()
        until(lambda: all(r["state"] in {"failed", "orphaned"} for r in tasks.list_tasks(str(self.root))))
        self.assertEqual(victim.read_bytes(), b"unchanged")

    def test_terminal_audit_failure_preserves_identity_without_completion(self):
        original = observability.emit_ack
        def ack(q, root, event, **kwargs):
            if event["kind"] == "remote.command.outcome" and event["payload"]["operation"] == "submit":
                raise observability.AuditWriteError()
            return original(q, root, event, **kwargs)
        self.start()
        with mock.patch.object(observability, "emit_ack", side_effect=ack):
            self.request()
            row = self.row(True)
        self.assertEqual(row["state"], "failed")
        self.assertEqual(row["external_job_id"], "backend-1")
        self.assertEqual(row["recovery"]["phase"], "submitted")
        self.assertEqual(len(self.api.posts), 1)

    def test_escaped_credentials_absent_in_task_trace_and_wal(self):
        self.start()
        for suffix in ('quote"end', 'slash\\end', 'unicode\u00e9'):
            self.config["capabilities"][NAME]["provisioning"] = {"token": SECRET + suffix}
            self.write_config()
            params = {**self.params, "values": json.dumps({"text": "draw " + SECRET + suffix})}
            task_id = tasks.enqueue(self.eng.queues["tasks"], str(self.root), NAME, {"params": params})
            self.assertEqual(self.row(True, task_id)["state"], "failed")
        self.assertFalse(self.api.posts)
        for path in (self.root / ".claude/assistant").glob("*.sqlite*"):
            self.assertNotIn(SECRET.encode(), path.read_bytes())

    def test_malformed_recovery_is_orphaned_without_raw_error_or_replay(self):
        stop, thread = self.start()
        self.request()
        until(lambda: self.api.posts)
        stop.set()
        thread.join(10)
        with sqlite3.connect(self.root / ".claude/assistant/tasks.sqlite") as conn:
            conn.execute("UPDATE tasks SET recovery = ?", ("broken{",))
        self.start(writer=False)
        self.assertEqual(self.row(True)["state"], "orphaned")
        self.assertEqual(len(self.api.posts), 1)

    def test_fresh_enablement_and_policy_authority(self):
        stop, thread = self.start()
        self.request()
        until(lambda: self.api.posts)
        stop.set()
        thread.join(10)
        self.config["capabilities"][NAME]["enabled"] = False
        self.write_config()
        self.start(writer=False)
        self.assertEqual(self.row(True)["state"], "orphaned")
        self.assertEqual(len(self.api.posts), 1)

    def test_missing_models_actionable_and_no_post(self):
        self.api.info["FixtureImage"]["input"]["required"]["model"] = [["other.safetensors"]]
        self.start()
        self.request()
        row = self.row(True)
        self.assertEqual(row["state"], "failed")
        self.assertIn("FixtureImage.model", row["error"])
        self.assertEqual(self.api.posts, [])

    def test_typed_literals_hash_and_graph_guards(self):
        self.start()
        for value in ({"seed": True}, {"seed": 101}, {"text": ["2", 0]}, {"filename_prefix": "../../escape"}, {"text": "Bearer " + SECRET}):
            task_id = tasks.enqueue(self.eng.queues["tasks"], str(self.root), NAME, {"name": NAME, "params": {**self.params, "values": json.dumps(value)}})
            self.assertEqual(self.row(True, task_id)["state"], "failed")
            if value == {"seed": True}:
                outcome = until(lambda: next((e for e in self.events() if e["kind"] == "remote.command.outcome" and e["payload"]["task_id"] == task_id), None))
                self.assertEqual(outcome["status"], "refused")
        self.graph_path.write_text(json.dumps({**GRAPH, "3": GRAPH["1"]}))
        self.request()
        until(lambda: len(tasks.list_tasks(str(self.root))) == 6)
        until(lambda: all(r["state"] == "failed" for r in tasks.list_tasks(str(self.root))))
        self.assertEqual(self.api.posts, [])

    def test_oom_hostile_artifact_and_deadline(self):
        self.start()
        self.request()
        until(lambda: self.api.posts)
        self.api.complete("torch.OutOfMemoryError")
        row = self.row(True)
        self.assertEqual(row["state"], "failed")
        self.assertIn("out_of_memory", row["error"])
        self.api.pending.clear()
        self.request()
        until(lambda: len(self.api.posts) == 2)
        self.api.image = b"not an image " + SECRET.encode()
        self.api.complete()
        bad = until(lambda: next((r for r in tasks.list_tasks(str(self.root)) if r["id"] != row["id"] and r["state"] == "failed"), None))
        self.assertIsNone(bad["artifact_path"])
        self.manifest["provisioning"]["workflows"]["image"]["timeout"] = 1
        self.write_manifest()
        self.request()
        until(lambda: len(self.api.posts) == 3)
        self.api.running.extend(self.api.pending)
        self.api.pending.clear()
        expired = until(lambda: next((r for r in tasks.list_tasks(str(self.root)) if "deadline" in (r["error"] or "")), None))
        self.assertIn("may continue", expired["error"])
        self.assertEqual(self.api.interrupts, 0)

    def test_audit_admission_no_effect_and_binding_refusal(self):
        self.start(writer=False)
        self.request()
        self.assertEqual(self.row(True)["state"], "failed")
        self.assertEqual(self.api.posts, [])
        self.assertEqual(self.api.ws_connections, 0)
        with self.assertRaises(Exception):
            self.mod.install(self.root)
        braced = self.root / "{host}"
        braced.mkdir()
        with self.assertRaises(Exception):
            self.mod.install(braced)
        self.assertEqual(list(braced.iterdir()), [])

    def test_transport_real_pin_refusal_denied_port_and_child_cleanup(self):
        transport = importlib.import_module("assistant.comfyui_transport")
        with transport.Tunnel(self.ssh.entry) as tunnel:
            self.assertEqual(tunnel.json("/object_info"), INFO)
            child = tunnel.process
            child.kill()
            child.wait(timeout=2)
            with self.assertRaises(Exception):
                tunnel.json("/queue")
        self.assertIsNotNone(child.poll())
        wrong = (self.ssh.root / "wrong.pub").read_text().split()
        (self.ssh.root / "pins").write_text(f"[127.0.0.1]:{self.ssh.port} {wrong[0]} {wrong[1]}\n")
        with self.assertRaises(Exception):
            with transport.Tunnel(self.ssh.entry):
                self.fail("wrong host pin admitted")

    def paused_render(self):
        stop, thread = self.start()
        self.request()
        row = until(lambda: (r if (r := self.row())["external_job_id"] else None))
        stop.set()
        thread.join(10)
        self.assertFalse(thread.is_alive())
        return row

    def test_r1_fifo_artifact_rejected_without_blocking_worker(self):
        row = self.paused_render()
        self.api.complete()
        destination = self.root / artifacts.ARTIFACTS_DIR_REL / (row["id"] + ".png")
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.mkfifo(destination)

        def expired(signum, frame):
            raise AssertionError("FIFO destination blocked artifact publication")

        previous = signal.signal(signal.SIGALRM, expired)
        try:
            with self.mod.Tunnel(self.ssh.entry) as tunnel:
                signal.setitimer(signal.ITIMER_REAL, 1)
                with self.assertRaises(self.mod.RenderError):
                    self.mod._publish(tunnel, remote_audit.Context(str(self.root), self.eng.queues["traces"], task_id=row["id"]),
                        row["payload"]["params"], row["recovery"], self.manifest["provisioning"]["workflows"]["image"],
                        self.api.history[row["external_job_id"]])
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
        self.assertTrue(destination.is_fifo())
        self.assertFalse(list(destination.parent.glob("*.part")))
        self.start(writer=False)
        self.assertEqual(self.row(True)["state"], "failed")
        other = tasks.enqueue(self.eng.queues["tasks"], str(self.root), "legacy", {})
        until(lambda: (r := tasks.get_task(str(self.root), other)) and r["state"] == "completed")
        self.assertEqual(len(self.api.posts), 1)

    def test_r1_known_prompt_recovers_outside_recent_history(self):
        row = self.paused_render()
        self.api.complete()
        for number in range(256):
            foreign = copy.deepcopy(self.api.history[row["external_job_id"]])
            foreign["prompt"][1] = "foreign-" + str(number)
            foreign["prompt"][3] = {"assistant_request_id": "b" * 32, "client_id": "b" * 32}
            self.api.history[foreign["prompt"][1]] = foreign
        with self.mod.Tunnel(self.ssh.entry) as tunnel:
            self.assertNotIn(row["external_job_id"], tunnel.json("/history?max_items=256"))
            self.assertIn(row["external_job_id"], tunnel.json("/history/" + row["external_job_id"]))
        self.api.history_paths.clear()
        self.start(writer=False)
        completed = self.row(True)
        self.assertEqual(completed["state"], "completed", completed)
        self.assertIn("/history/" + row["external_job_id"], self.api.history_paths)
        path, size = artifacts.resolve(str(self.root), row["id"])
        self.assertEqual(Path(path).read_bytes(), PNG)
        self.assertEqual(size, len(PNG))
        self.assertEqual(len(self.api.posts), 1)

    def test_r1_targeted_history_validates_shape_ownership_and_ambiguity(self):
        row = self.paused_render()
        self.api.complete()
        prompt_id = row["external_job_id"]
        owned = copy.deepcopy(self.api.history[prompt_id])
        self.api.history.clear()
        foreign = copy.deepcopy(owned)
        foreign["prompt"][3] = {"assistant_request_id": "foreign", "client_id": "foreign"}
        self.api.history_overrides[prompt_id] = {prompt_id: foreign}
        with self.mod.Tunnel(self.ssh.entry) as tunnel:
            self.assertIsNone(self.mod.snapshot(tunnel, row["recovery"], prompt_id))
        for invalid in ([], {prompt_id: owned, "extra": owned}, {"wrong-id": owned}):
            with self.subTest(response=type(invalid).__name__):
                self.api.history_overrides[prompt_id] = invalid
                with self.mod.Tunnel(self.ssh.entry) as tunnel, self.assertRaises(self.mod.RenderError):
                    self.mod.snapshot(tunnel, row["recovery"], prompt_id)
        self.api.history_overrides[prompt_id] = {prompt_id: owned}
        duplicate = copy.deepcopy(owned)
        duplicate["prompt"][1] = "another-owned"
        self.api.history["another-owned"] = duplicate
        with self.mod.Tunnel(self.ssh.entry) as tunnel:
            self.assertIsNone(self.mod.snapshot(tunnel, row["recovery"], prompt_id))
        self.api.history_overrides[prompt_id] = {prompt_id: {**owned, "private": "x" * (4 * 1024 * 1024)}}
        with self.mod.Tunnel(self.ssh.entry) as tunnel, self.assertRaises(self.mod.TransportError):
            self.mod.snapshot(tunnel, row["recovery"], prompt_id)
        self.assertEqual(len(self.api.posts), 1)

    def nested_credential_params(self):
        secret = SECRET + 'quote"end'
        self.config["capabilities"][NAME]["provisioning"] = {"token": secret}
        self.write_config()
        for value in (json.dumps(secret), json.dumps({"caption": secret}), "draw " + json.dumps(secret)):
            self.assertNotEqual(remote_audit.redact_text(value, [secret]), value)
            yield {**self.params, "values": json.dumps({"text": value})}

    def test_r1_nested_credentials_refused_before_queue(self):
        for params in self.nested_credential_params():
            with self.subTest(value=params["values"]):
                self.request(params)
                envelope = self.eng.queues["tasks"].get_nowait()
                self.assertNotIn(SECRET, repr(envelope))
                self.assertEqual(envelope["payload"]["refusal"], "invalid_params")
        with self.eng.queues["traces"].mutex:
            self.assertNotIn(SECRET, repr(list(self.eng.queues["traces"].queue)))

    def test_r1_nested_credentials_refused_by_fresh_authority(self):
        for params in self.nested_credential_params():
            with self.subTest(value=params["values"]), self.assertRaises(self.mod.RenderError):
                self.mod.authority(self.root, params)
        self.assertEqual(self.api.posts, [])

    def test_r1_nested_credentials_absent_from_sql_and_wal(self):
        self.start()
        for params in self.nested_credential_params():
            with self.subTest(value=params["values"]):
                task_id = tasks.enqueue(self.eng.queues["tasks"], str(self.root), NAME, {"params": params})
                row = until(lambda: (r if (r := tasks.get_task(str(self.root), task_id))
                    and (r["external_job_id"] or r["state"] in {"failed", "orphaned"}) else None))
                for path in (self.root / ".claude/assistant").glob("*.sqlite*"):
                    self.assertFalse(SECRET.encode() in path.read_bytes(), "credential sentinel persisted in " + path.name)
                self.assertEqual(row["state"], "failed")
        self.assertEqual(self.api.posts, [])

    def test_r1_optional_ws_connection_failure_keeps_reconciling(self):
        transport = importlib.import_module("assistant.comfyui_transport")
        original = transport.Tunnel.progress
        sampled = threading.Event()
        def unavailable(tunnel, *args):
            sampled.set()
            with mock.patch.object(transport.socket, "create_connection", side_effect=ConnectionRefusedError("fixture WS refusal")):
                try:
                    return original(tunnel, *args)
                finally:
                    self.assertEqual(tunnel.sockets, [])
        with mock.patch.object(transport.Tunnel, "progress", unavailable):
            self.start()
            self.request()
            until(sampled.is_set)
            until(lambda: any(e["kind"] in {"task.reconcile_checked", "task.orphaned"} for e in self.events()))
            row = self.row()
            self.assertEqual(row["state"], "progress", row)
            self.assertEqual(self.api.pending[0][1], row["external_job_id"])
            self.api.complete()
            completed = self.row(True)
        self.assertEqual(completed["state"], "completed", completed)
        path, _ = artifacts.resolve(str(self.root), row["id"])
        self.assertEqual(Path(path).read_bytes(), PNG)
        self.assertEqual(len(self.api.posts), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
