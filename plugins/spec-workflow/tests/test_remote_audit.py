"""AST-082: local engine/queue/SQLite audit contract; no live SSH or providers.

The reusable callback is deliberately NOT a transfer implementation. Its effect
checks an independently opened SQLite reader before returning fixture data.
"""
import importlib
import io
import itertools
import json
import queue
import random
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

import yaml

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from assistant import adapters, capability_index, engine, observability, remote_control, tasks

NAME = "remote-compute-control"
SECRET = "AST082_PRIVATE_SENTINEL_71a964"


def audit_module():
    return importlib.import_module("assistant.remote_audit")


def until(predicate, seconds=3):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        threading.Event().wait(.01)
    raise AssertionError("bounded condition did not become true")


class AuditFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ast082-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "assistant"
        self.root.mkdir()
        self.skill = remote_control.install(self.root)
        self.config = {"version": 1, "enabled": True, "names": ["fixture"],
                       "systemPrompt": "Local fixture", "llm": {"provider": "openai", "model": "fixture"},
                       "capabilities": {"codex": {"enabled": True}, NAME: {"enabled": True}},
                       "observability": {"traces": {"sqlite": {"enabled": True, "retainDays": 0, "maxMB": 0}}}}
        self.write_config()
        self.manifest = yaml.safe_load((self.skill / "capability.yaml").read_text())
        self.manifest["provisioning"]["check"] = ["true"]
        self.manifest["provisioning"]["hosts"] = {"storm590x": {
            "host": "localhost", "port": 22, "user": "fixture",
            "knownHosts": "/private/" + SECRET,
            "keys": {"inspect": "/private/" + SECRET, "cancel": "/cancel/" + SECRET}}}
        self.set_response({"id": "job-1", "state": "done", "exitcode": 0})
        self.eng = engine.AssistantEngine(lambda: [("fixture", str(self.root))], str(self.root / "state"))
        self.entry = capability_index.CapabilityIndexEntry(NAME, "Remote fixture", [], [], True, True, None)
        self.eng._on_capability_index_compiled(str(self.root), capability_index.CapabilityIndex([self.entry]))
        self.stops = []
        self.threads = []
        self.addCleanup(self.stop_workers)

    def write_config(self):
        marker = self.root / ".neural-network"
        marker.mkdir(exist_ok=True)
        (marker / "project.yaml").write_text(yaml.safe_dump({"assistant": self.config}))

    def set_response(self, data, operation="status", rc=0, stderr=""):
        # The installed manifest still uses the real argv adapter; only its
        # executable is a hermetic subprocess instead of a network client.
        result = {"version": 1, "ok": True, "operation": operation, "data": data}
        script = "import sys; print(%r); print(%r, file=sys.stderr); sys.exit(%d)" % (
            json.dumps(result), stderr, rc)
        self.manifest["invoke"]["exec"] = [sys.executable, "-c", script]
        (self.skill / "capability.yaml").write_text(yaml.safe_dump(self.manifest))

    def start_thread(self, target, **kwargs):
        stop = threading.Event()
        thread = threading.Thread(target=target, kwargs={"stop_event": stop, **kwargs})
        self.stops.append(stop)
        self.threads.append(thread)
        thread.start()
        return stop, thread

    def start_writer(self, **kwargs):
        return self.start_thread(observability.run_writer, q=self.eng.queues["traces"],
                                 poll_timeout=.01, retention_config=lambda root: {"retainDays": 0, "maxMB": 0},
                                 **kwargs)

    def start_tasks(self, **kwargs):
        executors = {capability_index.KIND: capability_index.run_capability_invoke_task}
        try:
            audit = audit_module()
        except ModuleNotFoundError:
            pass  # baseline engine tests still reach the actual legacy worker
        else:
            executors[audit.KIND] = audit.run_task
        return self.start_thread(tasks.run_worker, q=self.eng.queues["tasks"],
                                 traces_queue=self.eng.queues["traces"], executors=executors,
                                 poll_timeout=.01, **kwargs)

    def stop_workers(self):
        for stop in self.stops:
            stop.set()
        for thread in self.threads:
            thread.join(6)
            self.assertFalse(thread.is_alive(), "owned worker did not stop")

    def request(self, params=None, name=NAME):
        if params is None:
            params = {"host": "storm590x", "operation": "status", "job_id": "job-1"}
        hook = self.eng._capability_reply_hook_for(str(self.root), "turn-1", "inspect job", self.config)
        return hook("```capability\n" + json.dumps({"name": name, "params": params}) + "\n```",
                    {}, lambda *a, **k: {"text": "fixture followup"}, {})

    def finished_task(self):
        def finished():
            rows = tasks.list_tasks(str(self.root))
            return next((r for r in rows if r["state"] in ("completed", "failed", "orphaned")), None)
        return until(finished)

    def events(self):
        return observability.query(str(self.root), limit=1000)

    def remote_events(self):
        return [e for e in self.events() if e["kind"].startswith("remote.command.")]

    def assert_private_absent(self):
        # Include the live WAL and freed pages, not just decoded API values.
        for path in (self.root / ".claude/assistant").glob("*.sqlite*"):
            self.assertFalse(SECRET.encode() in path.read_bytes(), "secret persisted in " + str(path))
        for q in self.eng.queues.values():
            with q.mutex:
                self.assertFalse(SECRET in repr(list(q.queue)), "secret retained in queued work")

    def context(self, **kwargs):
        return audit_module().Context(root=str(self.root), traces_queue=self.eng.queues["traces"],
                                      turn_id="turn-1", task_id="task-1", **kwargs)


class EngineAuditTests(AuditFixture):
    def check_exact_key_prefix_compatibility(self, operation, backslash=False):
        protected = ["keys", "-keys", "--keys", "---keys", "123-keys", "9--keys",
                     "123-45-keys", '"keys"', "'keys'", '"ke\\u0079s"']
        safe = ["abc-keys", "9keys", "9_keys", "123-_keys", '"--keys"', "'123-keys'"]
        if backslash:
            protected = [r"\-password", r"\--keys", r"\a-password", r"\123-keys", r"\_a-keys"]
            safe = [r"\keys", r"\password", r"\abc_keys", r"\abc-abc-keys"]
        text = "\n".join(key + "=" + SECRET + " useful step" for key in protected)
        text += "\n" + "\n".join(key + "=public-value" for key in safe)
        data = ({"text": text, "truncated": False} if operation == "logs" else
                {"capabilities": {"demo": {"description": text}}})
        self.set_response(data, operation=operation)
        self.start_writer()
        self.start_tasks()
        self.request({"host": "storm590x", "operation": operation,
                      "job_id": "job-1" if operation == "logs" else ""})
        row = self.finished_task()
        self.assertEqual("completed", row["state"], row)
        self.assert_private_absent()
        rendered = (row["result"]["text"] if operation == "logs" else
                    row["result"]["capabilities"]["demo"]["description"])
        self.assertEqual(len(protected), rendered.count("useful step"))
        for key in safe:
            self.assertIn(key + "=public-value", rendered)
        self.stop_workers()
        self.assert_private_absent()

    def test_exact_key_prefix_log_compatibility(self):
        self.check_exact_key_prefix_compatibility("logs")

    def test_exact_key_prefix_catalog_compatibility(self):
        self.check_exact_key_prefix_compatibility("inventory")

    def test_backslash_prefix_log_compatibility(self):
        self.check_exact_key_prefix_compatibility("logs", backslash=True)

    def test_backslash_prefix_catalog_compatibility(self):
        self.check_exact_key_prefix_compatibility("inventory", backslash=True)

    def check_dashed_assignment_compatibility(self, operation):
        samples = ["password=" + SECRET, "-password=" + SECRET,
                   "--api-key=" + SECRET, "---password=" + SECRET,
                   "123-password=" + SECRET, "remote-api-key=" + SECRET,
                   '-"pass\\u0077ord"=' + SECRET,
                   '"password=' + SECRET, "'password=" + SECRET,
                   "--password='prefix\\'" + SECRET + "'"]
        text = "\n".join(sample + " useful step " + str(i) for i, sample in enumerate(samples))
        data = ({"text": text, "truncated": False} if operation == "logs" else
                {"capabilities": {"demo": {"description": text}}})
        self.set_response(data, operation=operation)
        self.start_writer()
        self.start_tasks()
        self.request({"host": "storm590x", "operation": operation,
                      "job_id": "job-1" if operation == "logs" else ""})
        row = self.finished_task()
        self.assertEqual("completed", row["state"], row)
        self.assert_private_absent()
        rendered = (row["result"]["text"] if operation == "logs" else
                    row["result"]["capabilities"]["demo"]["description"])
        for i in range(len(samples)):
            self.assertIn("useful step " + str(i), rendered)
        self.stop_workers()
        self.assert_private_absent()

    def test_dashed_assignment_log_compatibility(self):
        self.check_dashed_assignment_compatibility("logs")

    def test_dashed_assignment_catalog_compatibility(self):
        self.check_dashed_assignment_compatibility("inventory")

    def test_legacy_queue_item_is_normalized_before_insert_and_cannot_fallback(self):
        self.start_writer()
        with mock.patch.object(capability_index, "run_capability_invoke_task",
                               side_effect=AssertionError("managed task reached legacy fallback")) as legacy:
            self.start_tasks()
            self.eng.queues["tasks"].put_nowait({"action": "create", "id": "legacy-item",
                "root": str(self.root), "turn_id": "turn-1", "kind": capability_index.KIND,
                "payload": {"name": NAME.upper(), "assistant_cfg": {"password": SECRET},
                            "params": {"host": "storm590x", "operation": "status", "job_id": "job-1"}}})
            row = self.finished_task()
            self.assertEqual("completed", row["state"], row)
            self.assertEqual(audit_module().KIND, row["kind"])
            self.assertEqual("done", row["result"]["state"])
            legacy.assert_not_called()
        self.stop_workers()
        self.assert_private_absent()

    def test_remote_executor_without_engine_context_refuses_before_effect(self):
        audit = audit_module()
        payload = {"name": NAME.upper(), "capability": capability_index.load_capability(self.skill)._asdict(),
                   "params": {"host": "storm590x", "operation": "status", "job_id": "job-1"},
                   "assistant_cfg": self.config, "skill_dir": str(self.skill)}
        with mock.patch.object(capability_index, "invoke_capability") as invoke:
            with self.assertRaisesRegex(audit.AuditError, "engine-owned audit context.*task worker"):
                audit.run_task(payload, lambda *args, **kwargs: None)
            invoke.assert_not_called()

    def test_remote_outer_hook_exception_does_not_trace_raw_exception(self):
        self.start_writer()
        with mock.patch.object(capability_index, "resolve_by_name", side_effect=RuntimeError(SECRET)):
            reply = self.request()
        self.assertNotIn(SECRET, reply["text"])
        self.stop_workers()
        self.assert_private_absent()

    def test_remote_task_setup_exception_does_not_persist_raw_exception(self):
        original = tasks._transition

        def transition(conn, task_id, state, **kwargs):
            if state == "started":
                raise sqlite3.OperationalError(SECRET)
            return original(conn, task_id, state, **kwargs)

        self.start_writer()
        with mock.patch.object(tasks, "_transition", side_effect=transition), \
                mock.patch.object(adapters, "invoke_argv") as invoke:
            self.start_tasks()
            self.request()
            row = self.finished_task()
            self.assertEqual("failed", row["state"])
            self.assertNotIn(SECRET, row["error"])
            invoke.assert_not_called()
            until(lambda: any(e["status"] == "refused" for e in self.remote_events()))
        self.stop_workers()
        self.assert_private_absent()

    def test_remote_provisioning_reason_cannot_reenter_through_roster(self):
        index = capability_index.compile_index(str(self.skill.parent), self.config,
            provisioning_checker=lambda *args: (False, SECRET), embed_fn=lambda texts: [[1] for _ in texts])
        self.assertEqual(1, len(index.entries))
        self.assertFalse(index.entries[0].provisioned_ok)
        self.assertNotIn(SECRET, index.entries[0].unavailable_reason)

    def test_engine_start_registers_managed_executor_and_keeps_chat_responsive(self):
        entered, release = threading.Event(), threading.Event()
        original = adapters.invoke_argv

        def invoke(*args, **kwargs):
            entered.set()
            self.assertTrue(release.wait(3))
            return original(*args, **kwargs)

        # Index/distillation are unrelated to this test and must not load an
        # embedding model or provider. Real engine task/trace startup is intact.
        def idle(_source, stop_event, **_kwargs):
            stop_event.wait()

        with mock.patch.object(engine.distill, "run_worker", side_effect=idle), \
                mock.patch.object(capability_index, "run_worker", side_effect=idle), \
                mock.patch.object(adapters, "invoke_argv", side_effect=invoke):
            self.eng.start()
            try:
                self.request()
                self.assertTrue(entered.wait(2))
                hook = self.eng._capability_reply_hook_for(str(self.root), "turn-2", "hello", self.config)
                before = time.monotonic()
                self.assertIsNone(hook("still chatting", {}, None, {}))
                self.assertLess(time.monotonic() - before, .2)
                self.assertEqual(["remote.command.intent"], [e["kind"] for e in self.remote_events()])
            finally:
                release.set()
                self.eng.stop()

    def test_nested_invalid_params_redacted_before_any_queue_or_insert(self):
        self.config["privateCredential"] = SECRET
        params = {"host": "storm590x", "operation": "status", "job_id": "job-1",
                  "credentials": {"password": SECRET}, "root": "/private/" + SECRET}
        with mock.patch.object(adapters, "invoke_argv", side_effect=AssertionError("must not execute")) as invoke:
            self.request(params, name=NAME.upper())
            # Keep this check before worker startup: executor-only redaction fails.
            with self.eng.queues["traces"].mutex:
                trace_copy = repr(list(self.eng.queues["traces"].queue))
            with self.eng.queues["tasks"].mutex:
                task_copy = repr(list(self.eng.queues["tasks"].queue))
            with self.subTest(boundary="trace queue before worker"):
                self.assertFalse(SECRET in trace_copy, "raw nested remote params entered skill.request queue")
            with self.subTest(boundary="task queue before worker"):
                self.assertFalse(SECRET in task_copy, "raw nested remote params/config entered task queue")
            self.start_writer()
            self.start_tasks()
            self.finished_task()
            with self.subTest(boundary="SQLite and WAL"):
                self.assert_private_absent()
            with self.subTest(boundary="transport"):
                invoke.assert_not_called()
            until(lambda: self.remote_events())
            self.assertIn("refused", [e["status"] for e in self.remote_events()])

    def test_valid_request_never_persists_manifest_or_assistant_config(self):
        self.config["privateCredential"] = SECRET
        self.request()
        with self.eng.queues["tasks"].mutex:
            queued = list(self.eng.queues["tasks"].queue)
        self.start_writer()
        self.start_tasks()
        row = self.finished_task()
        self.assertEqual("completed", row["state"])
        self.assertFalse(SECRET in repr(queued), "manifest/config credentials entered queued task payload")
        self.assertNotIn("assistant_cfg", repr(queued))
        self.assertNotIn("knownHosts", repr(queued))
        self.assert_private_absent()

    def test_uppercase_and_long_running_false_stay_off_chat_thread(self):
        self.manifest["longRunning"] = False
        self.set_response({"id": "job-1", "state": "done", "exitcode": 0})
        with mock.patch.object(adapters, "invoke_argv") as invoke:
            reply = self.request(name=NAME.upper())
            invoke.assert_not_called()
        self.assertEqual(1, self.eng.queues["tasks"].qsize())
        self.assertIn("background", reply["text"])

    def test_ignored_uppercase_remote_directive_cannot_leak_adjacent_trace(self):
        hook = self.eng._capability_reply_hook_for(str(self.root), "turn-1", "hello", self.config)
        text = "```capability\n" + json.dumps({"name": NAME.upper(), "params": {"token": SECRET}}) + "\n```\nExample only."
        with mock.patch.object(adapters, "invoke_argv") as invoke:
            hook(text, {}, None, {})
            invoke.assert_not_called()
        self.assertTrue(self.eng.queues["tasks"].empty())
        self.assert_private_absent()

    def test_success_real_adapter_observes_committed_intent_and_linked_terminal(self):
        self.start_writer()
        original = adapters.invoke_argv
        observed = []

        def invoke(*args, **kwargs):
            intent = [e for e in self.remote_events() if e["kind"] == "remote.command.intent"]
            self.assertEqual(1, len(intent), "effect before committed intent")
            self.assertEqual("turn-1", intent[0]["turn_id"])
            self.assertTrue(intent[0]["payload"]["task_id"])
            observed.append(intent[0])
            return original(*args, **kwargs)

        with mock.patch.object(adapters, "invoke_argv", side_effect=invoke):
            self.start_tasks()
            self.request()
            row = self.finished_task()
        self.assertEqual("completed", row["state"], row)
        self.assertEqual(1, len(observed))
        terminal = until(lambda: [e for e in self.remote_events() if e["kind"] == "remote.command.outcome"])[0]
        self.assertEqual("success", terminal["status"])
        self.assertEqual(observed[0]["span_id"], terminal["span_id"])
        self.assertEqual(observed[0]["payload"]["command_id"], terminal["payload"]["command_id"])
        self.assertEqual(row["id"], terminal["payload"]["task_id"])

    def check_refusal(self, reason):
        self.eng._on_capability_index_compiled(str(self.root), capability_index.CapabilityIndex(
            [] if reason == "disabled" else [self.entry._replace(
                provisioned_ok=reason != "unprovisioned", unavailable_reason=SECRET)]))
        if reason == "disabled":
            self.config["capabilities"][NAME]["enabled"] = False
            self.write_config()
        self.start_writer()
        load = (mock.patch.object(capability_index, "load_capability", return_value=capability_index.CapabilityError(SECRET))
                if reason == "reload" else mock.patch.object(self.eng, "_repos_getter", return_value=[]))
        with load, mock.patch.object(adapters, "invoke_argv") as invoke:
            self.start_tasks()
            reply = self.request(name=NAME.upper())
            with self.subTest(boundary="reply"):
                self.assertNotIn(SECRET, reply["text"])
            until(lambda: any(e["status"] == "refused" for e in self.remote_events()))
            invoke.assert_not_called()
        self.assert_private_absent()

    def test_disabled_refusal_is_audited_without_effect(self):
        self.check_refusal("disabled")

    def test_unprovisioned_refusal_is_audited_without_diagnostic_leak(self):
        self.check_refusal("unprovisioned")

    def test_manifest_reload_refusal_is_audited_without_diagnostic_leak(self):
        self.check_refusal("reload")

    def test_cancel_actual_adapter_preserves_remote_evidence(self):
        self.set_response({"id": "job-1", "state": "cancelling", "pid": 123, "exitcode": None}, operation="cancel")
        self.start_writer()
        self.start_tasks()
        self.request({"host": "storm590x", "operation": "cancel", "job_id": "job-1"})
        row = self.finished_task()
        self.assertEqual("completed", row["state"])
        outcome = until(lambda: [e for e in self.remote_events() if e["kind"] == "remote.command.outcome"])[0]
        self.assertEqual("pending", outcome["status"])
        self.assertIn("cancelling", json.dumps(row["result"]))

    def test_inventory_preserves_safe_catalog_but_not_credentials(self):
        self.set_response({"capabilities": {"comfyui": {"description": "Local rendering", "active": True,
                                                       "token": SECRET, "path": "/private/" + SECRET}}}, operation="inventory")
        self.start_writer()
        self.start_tasks()
        self.request({"host": "storm590x", "operation": "inventory", "job_id": ""})
        row = self.finished_task()
        self.assertEqual("completed", row["state"])
        self.assertIn("comfyui", json.dumps(row["result"]))
        self.assertIn("Local rendering", json.dumps(row["result"]))
        self.assert_private_absent()

    def test_failure_and_timeout_never_persist_raw_diagnostics(self):
        self.start_writer()
        self.start_tasks()
        for exc in (adapters.AdapterError(SECRET), adapters.Timeout(SECRET)):
            with self.subTest(error=type(exc).__name__):
                before = len(tasks.list_tasks(str(self.root)))
                with mock.patch.object(adapters, "invoke_argv", side_effect=exc):
                    self.request()
                    until(lambda: len([r for r in tasks.list_tasks(str(self.root)) if r["state"] == "failed"]) > before)
                self.assert_private_absent()
        outcomes = until(lambda: [e for e in self.remote_events() if e["kind"] == "remote.command.outcome"])
        self.assertEqual({"failure"}, {e["status"] for e in outcomes})

    def test_useful_status_survives_unknown_output_and_credential_redaction(self):
        self.set_response({"id": "job-1", "state": "done", "exitcode": 0,
                           "credentials": {"password": SECRET}, "unknown": SECRET,
                           "root": "/private/" + SECRET, "artifact_path": "/private/" + SECRET}, stderr=SECRET)
        self.start_writer()
        self.start_tasks()
        self.request()
        row = self.finished_task()
        self.assertEqual("completed", row["state"])
        self.assertIn("done", json.dumps(row["result"]))
        self.assertIn("job-1", json.dumps(row["result"]))
        self.assertIsNone(row["artifact_path"])
        self.assert_private_absent()

    def test_logs_preserve_nonsecret_text_and_remove_credentials(self):
        self.set_response({"job_id": "job-1", "text": "step 4 complete\npassword=" + SECRET,
                           "truncated": False}, operation="logs")
        self.start_writer()
        self.start_tasks()
        self.request({"host": "storm590x", "operation": "logs", "job_id": "job-1"})
        row = self.finished_task()
        self.assertEqual("completed", row["state"])
        self.assertIn("step 4 complete", json.dumps(row["result"]))
        self.assert_private_absent()

    def check_uri_credentials_before_persistence(self, operation):
        authorities = [
            ("postgresql", "fixture:" + SECRET),
            ("redis", "fixture:" + SECRET),
            ("ssh", "fixture:" + SECRET),
            ("HTTPS", "fixture:" + SECRET),
            ("PostgreSQL", "fixture:" + SECRET),
            ("x+sql.v1-test", "fixture:" + SECRET),
            ("redis", ":" + SECRET),
            ("postgresql", "fixture%40name:" + SECRET + "%2F%40%3A"),
        ]
        safe = "step 4 complete; postgresql://localhost/example; ssh://fixture@localhost/example"
        text = safe + "\n" + "\n".join(scheme + "://" + userinfo + "@localhost/example"
                                         for scheme, userinfo in authorities)
        data = ({"job_id": "job-1", "text": text, "truncated": False} if operation == "logs" else
                {"capabilities": {"comfyui": {"description": text, "active": True}}})
        self.set_response(data, operation=operation)
        self.start_writer()
        self.start_tasks()
        self.request({"host": "storm590x", "operation": operation,
                      "job_id": "job-1" if operation == "logs" else ""})
        row = self.finished_task()
        self.assertEqual("completed", row["state"], row)
        self.assert_private_absent()
        result = row["result"]["text"] if operation == "logs" else row["result"]["capabilities"]["comfyui"]["description"]
        self.assertIn(safe, result)
        for scheme, _ in authorities:
            self.assertIn(scheme + "://[redacted]@localhost/example", result)
        self.assertEqual(len(authorities), result.count("[redacted]"))
        self.assertNotIn("fixture%40name", result, "encoded userinfo must be removed in full")

    def test_log_uri_credentials_redacted_before_queue_and_sqlite(self):
        self.check_uri_credentials_before_persistence("logs")

    def test_catalog_uri_credentials_redacted_before_queue_and_sqlite(self):
        self.check_uri_credentials_before_persistence("inventory")

    def check_escaped_credentials_before_persistence(self, operation):
        text = "useful step 7\n" + "\n".join([
            json.dumps({"password": 'prefix"' + SECRET, "message": "useful JSON field"}),
            "password='prefix\\'" + SECRET + "' useful single quote tail",
            '{"pass\\u0077ord":"' + SECRET + '","message":"useful decoded key"}',
            'prefix {"to\\u006ben":{"nested":["' + SECRET + '"]}} useful mixed tail',
            'password="prefix\\\\\\\"' + SECRET + '" useful escaped slash tail',
        ])
        data = ({"job_id": "job-1", "text": text, "truncated": False} if operation == "logs" else
                {"capabilities": {"comfyui": {"description": text, "active": True}}})
        self.set_response(data, operation=operation)
        self.start_writer()
        self.start_tasks()
        self.request({"host": "storm590x", "operation": operation,
                      "job_id": "job-1" if operation == "logs" else ""})
        row = self.finished_task()
        self.assertEqual("completed", row["state"], row)
        self.assert_private_absent()
        result = row["result"]["text"] if operation == "logs" else row["result"]["capabilities"]["comfyui"]["description"]
        for useful in ("useful step 7", "useful JSON field", "useful single quote tail",
                       "useful decoded key", "useful mixed tail", "useful escaped slash tail"):
            self.assertIn(useful, result)
        self.stop_workers()
        self.assert_private_absent()  # Check checkpointed pages as well as the live WAL.

    def test_escaped_log_credentials_are_redacted_before_persistence(self):
        self.check_escaped_credentials_before_persistence("logs")

    def test_escaped_catalog_credentials_are_redacted_before_persistence(self):
        self.check_escaped_credentials_before_persistence("inventory")

    def check_serialized_credentials(self, operation, escaped_url=False):
        message = ("postgresql://fixture:" + SECRET + "@localhost/db" if escaped_url else
                   json.dumps({"password": SECRET, "step": "useful nested step"}))
        text = json.dumps({"message": message, "step": "useful outer step",
                           "endpoint": "postgresql://localhost/public"})
        if escaped_url:
            text = text.replace("/", "\\/")
        data = ({"text": text, "truncated": False} if operation == "logs" else
                {"capabilities": {"comfyui": {"description": text}}})
        self.set_response(data, operation=operation)
        self.start_writer()
        self.start_tasks()
        self.request({"host": "storm590x", "operation": operation,
                      "job_id": "job-1" if operation == "logs" else ""})
        row = self.finished_task()
        self.assertEqual("completed", row["state"], row)
        self.assert_private_absent()
        rendered = row["result"]["text"] if operation == "logs" else row["result"]["capabilities"]["comfyui"]["description"]
        decoded = json.loads(rendered)
        self.assertEqual("useful outer step", decoded["step"])
        self.assertEqual("postgresql://localhost/public", decoded["endpoint"])
        if escaped_url:
            self.assertEqual("postgresql://[redacted]@localhost/db", decoded["message"])
        else:
            self.assertEqual({"password": "[redacted]", "step": "useful nested step"}, json.loads(decoded["message"]))
        self.stop_workers()
        self.assert_private_absent()

    def test_nested_serialized_json_log_credentials(self):
        self.check_serialized_credentials("logs")

    def test_nested_serialized_json_catalog_credentials(self):
        self.check_serialized_credentials("inventory")

    def test_json_escaped_url_log_credentials(self):
        self.check_serialized_credentials("logs", escaped_url=True)

    def test_structured_text_nesting_is_bounded_without_leaking_deep_credentials(self):
        data = {"password": SECRET}
        for _ in range(32):
            data = {"message": data}
        text = "useful prefix " + json.dumps(data) + " useful suffix"
        result = audit_module().redact_text(text)
        self.assertNotIn(SECRET, result)
        self.assertIn("[redacted: JSON depth limit]", result)
        self.assertTrue(result.startswith("useful prefix "))
        self.assertTrue(result.endswith(" useful suffix"))

    def check_r2_structured_text(self, operation, form):
        uri = "postgresql://fixture:" + SECRET + "@localhost/db"
        if form in {"array", "string"}:
            nested = json.dumps({"password": SECRET, "step": "useful inner"})
            text = "INFO " + json.dumps([nested] if form == "array" else nested) + " useful suffix"
        else:
            key = "/private/" + SECRET if form == "serialized-known" else uri
            value = {key: {"step": "ready"}}
            if form == "nested":
                value = {"message": value}
            elif form.startswith("serialized"):
                value = {"message": json.dumps(value)}
            elif form == "original-name":
                self.manifest["provisioning"]["hosts"]["storm590x"]["keys"]["inspect"] = "password"
                value = {"password": SECRET, "step": "ready"}
            text = json.dumps(value)
        data = ({"text": text, "truncated": False} if operation == "logs" else
                {"capabilities": {"comfyui": {"description": text}}})
        self.set_response(data, operation=operation)
        self.start_writer()
        self.start_tasks()
        self.request({"host": "storm590x", "operation": operation,
                      "job_id": "job-1" if operation == "logs" else ""})
        row = self.finished_task()
        self.assertEqual("completed", row["state"], row)
        self.assert_private_absent()
        rendered = row["result"]["text"] if operation == "logs" else row["result"]["capabilities"]["comfyui"]["description"]
        if form in {"array", "string"}:
            self.assertTrue(rendered.startswith("INFO "))
            self.assertTrue(rendered.endswith(" useful suffix"))
            decoded = json.loads(rendered[len("INFO "):-len(" useful suffix")])
            inner = json.loads(decoded[0] if form == "array" else decoded)
            self.assertEqual({"password": "[redacted]", "step": "useful inner"}, inner)
        else:
            decoded = json.loads(rendered)
            if form == "nested":
                decoded = decoded["message"]
            elif form.startswith("serialized"):
                decoded = json.loads(decoded["message"])
            if form == "original-name":
                self.assertEqual({"[redacted]": "[redacted]", "step": "ready"}, decoded)
            else:
                safe_key = "[redacted]" if form == "serialized-known" else "postgresql://[redacted]@localhost/db"
                self.assertEqual({safe_key: {"step": "ready"}}, decoded)
        self.stop_workers()
        self.assert_private_absent()

    def test_r2_top_uri_key_logs(self):
        self.check_r2_structured_text("logs", "top")

    def test_r2_top_uri_key_catalog(self):
        self.check_r2_structured_text("inventory", "top")

    def test_r2_nested_uri_key_logs(self):
        self.check_r2_structured_text("logs", "nested")

    def test_r2_nested_uri_key_catalog(self):
        self.check_r2_structured_text("inventory", "nested")

    def test_r2_serialized_uri_key_logs(self):
        self.check_r2_structured_text("logs", "serialized")

    def test_r2_serialized_uri_key_catalog(self):
        self.check_r2_structured_text("inventory", "serialized")

    def test_r2_serialized_known_key_logs(self):
        self.check_r2_structured_text("logs", "serialized-known")

    def test_r2_serialized_known_key_catalog(self):
        self.check_r2_structured_text("inventory", "serialized-known")

    def test_r2_original_field_name_classification_logs(self):
        self.check_r2_structured_text("logs", "original-name")

    def test_r2_original_field_name_classification_catalog(self):
        self.check_r2_structured_text("inventory", "original-name")

    def test_r2_prefixed_serialized_array_logs(self):
        self.check_r2_structured_text("logs", "array")

    def test_r2_prefixed_serialized_array_catalog(self):
        self.check_r2_structured_text("inventory", "array")

    def test_r2_prefixed_serialized_string_logs(self):
        self.check_r2_structured_text("logs", "string")

    def test_r2_prefixed_serialized_string_catalog(self):
        self.check_r2_structured_text("inventory", "string")

    def test_r2_embedded_json_scan_attempts_are_bounded(self):
        text = "INFO " + ("[invalid " * 300) + json.dumps([json.dumps({"password": SECRET})])
        result = audit_module().redact_text(text)
        self.assertTrue(result.startswith("INFO "))
        self.assertIn("[redacted: JSON scan limit]", result)
        self.assertNotIn(SECRET, result)

    def test_no_effect_if_trace_storage_fails(self):
        diagnostics = io.StringIO()
        with mock.patch.object(observability, "_open_conn", side_effect=sqlite3.OperationalError(SECRET)), \
                mock.patch.object(adapters, "invoke_argv", return_value=adapters.InvokeResult([], 0, "{}", "")) as invoke, \
                mock.patch("sys.stderr", diagnostics):
            self.start_writer()
            self.start_tasks()
            self.request()
            row = self.finished_task()
            with self.subTest(boundary="task state"):
                self.assertEqual("failed", row["state"])
            with self.subTest(boundary="effect"):
                invoke.assert_not_called()
            with self.subTest(boundary="error"):
                self.assertNotIn(SECRET, row["error"] or "")
            self.stop_workers()
        self.assertNotIn(SECRET, diagnostics.getvalue())

    def test_plain_chat_and_nonremote_capabilities_keep_legacy_behavior(self):
        hook = self.eng._capability_reply_hook_for(str(self.root), "turn-1", "hello", self.config)
        with mock.patch.object(capability_index, "resolve_by_name") as resolve:
            self.assertIsNone(hook("hello", {}, None, {}))
            resolve.assert_not_called()
        cap = capability_index.Capability(1, {}, [], {"exec": [sys.executable, "-c", "print('legacy')"]})
        result = capability_index.invoke_capability("local", cap, {}, {"capabilities": {"local": {"enabled": True}}})
        self.assertEqual("legacy", result.stdout.strip())
        self.assertTrue(result.argv)


class ProjectionResponsivenessTests(unittest.TestCase):
    def check_legacy_output(self, texts):
        audit = audit_module()
        # Keep the pre-optimization matcher as a short-input behavioral oracle.
        legacy = re.compile(r'''(?<![A-Za-z0-9_\\])("(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|[A-Za-z_][A-Za-z0-9_-]*)\s*[:=]\s*''')
        with mock.patch.object(audit, "ASSIGNMENT", legacy):
            expected = [audit.redact_text(text) for text in texts]
        mismatches = [text for text, before in zip(texts, expected)
                      if audit.redact_text(text) != before]
        self.assertEqual([], mismatches[:10], str(len(mismatches)) + " legacy output regressions")

    def test_exact_key_prefixes_match_legacy_output(self):
        self.check_legacy_output(["".join(prefix) + "keys=" + SECRET + " useful suffix"
                                  for size in range(6)
                                  for prefix in itertools.product("-19_a", repeat=size)])

    def test_backslash_and_mixed_prefixes_match_legacy_output(self):
        rng = random.Random(34904)
        texts = []
        for _ in range(10000):
            prefix = "".join(rng.choice("\\-_19a.'\" ") for _ in range(rng.randrange(16)))
            texts.append(prefix + rng.choice(("keys", "password", "api-key", "_keys"))
                         + rng.choice(("=", ": ", '=\"', "='")) + SECRET)
        self.check_legacy_output(texts)

    def check_separator_responsiveness(self, operation):
        # A separate process bounds even a regex that holds the GIL. The barrier
        # starts a same-process heartbeat before projection can monopolize it.
        script = r'''
import json, sys, threading, time
sys.path.insert(0, sys.argv[1])
from assistant.remote_audit import project_result
operation = sys.argv[2]
measurements = []
for token in ("a-", "a_", "a.", "a+", "--", "1-", "1_a-", "a- "):
    text = token * (65536 // len(token))
    data = ({"text": text, "truncated": False} if operation == "logs" else
            {"capabilities": {"demo": {"description": text}}})
    barrier = threading.Barrier(2)
    done = threading.Event()
    results = []
    def project():
        try:
            barrier.wait(timeout=5)
            start = time.monotonic()
            result = project_result(operation, data)
            results.append((result, time.monotonic() - start))
        finally:
            done.set()
    worker = threading.Thread(target=project)
    worker.start()
    last = time.monotonic()
    gaps = []
    barrier.wait(timeout=5)
    while True:
        done.wait(.01)
        now = time.monotonic()
        gaps.append(now - last)
        last = now
        if done.is_set():
            break
    worker.join()
    assert len(results) == 1, "projection failed; see child stderr"
    result, seconds = results[0]
    rendered = (result["text"] if operation == "logs" else
                result["capabilities"]["demo"]["description"])
    assert rendered == text[:65536 if operation == "logs" else 2048]
    measurements.append({"token": token, "projection_seconds": seconds,
                         "heartbeat_max_gap_seconds": max(gaps)})
print(json.dumps(measurements), flush=True)
'''
        child = subprocess.run([sys.executable, "-c", script, str(SCRIPTS), operation],
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(0, child.returncode, child.stdout + child.stderr)
        measurements = json.loads(child.stdout)
        print(operation + " separator timings: " + child.stdout.strip(), flush=True)
        for measured in measurements:
            with self.subTest(operation=operation, token=measured["token"]):
                self.assertLess(measured["projection_seconds"], 2, measured)
                self.assertLess(measured["heartbeat_max_gap_seconds"], 2, measured)

    def test_log_separator_projection_stays_responsive(self):
        self.check_separator_responsiveness("logs")

    def test_catalog_separator_projection_stays_responsive(self):
        self.check_separator_responsiveness("inventory")


class AcknowledgementTests(AuditFixture):
    def check_legacy_ack_fields(self, mode):
        q = self.eng.queues["traces"]
        root = str(self.root)
        values = ["legacy-extra-field", 7, 1.5, True, False, None, [], ["legacy"], {}, {"done": True}]
        for number, value in enumerate(values):
            payload = {"bad": object()} if mode == "legacy-marker" else {"number": number}
            observability.emit(q, root, {"kind": "turn.start", "_ack": value, "payload": payload})
        malformed_ack = observability._CommitAck()
        if mode == "bad-ack":
            q.put_nowait({"root": root, "ack": malformed_ack,
                          "event": {"kind": "remote.command.intent", "payload": {"bad": object()}}})
        errors, thread_errors = [], []

        def submit():
            try:
                observability.emit_ack(q, root, {"kind": "remote.command.intent", "_ack": {"legacy": True}}, timeout=1)
            except Exception as exc:
                errors.append(exc)

        def writer(**kwargs):
            try:
                observability.run_writer(**kwargs)
            except Exception as exc:
                thread_errors.append(exc)

        submitter = threading.Thread(target=submit)
        submitter.start()
        original = observability._open_conn
        opens = []

        def open_conn(path):
            opens.append(path)
            if mode == "storage-failure" and len(opens) == 1:
                raise sqlite3.OperationalError("forced storage failure")
            return original(path)

        try:
            # Queue every peer before starting the real writer: one deterministic batch.
            until(lambda: q.qsize() == len(values) + 1 + (mode == "bad-ack"))
            with mock.patch.object(observability, "_open_conn", side_effect=open_conn):
                _, worker = self.start_thread(writer, q=q, poll_timeout=.01,
                    retention_config=lambda root: {"retainDays": 0, "maxMB": 0})
                submitter.join(2)
                self.assertFalse(submitter.is_alive())
                self.assertEqual([], thread_errors, "legacy extra field killed trace writer")
                self.assertTrue(worker.is_alive())
                if mode == "storage-failure":
                    self.assertEqual(1, len(errors))
                    self.assertIsInstance(errors[0], observability.AuditWriteError)
                    self.assertEqual([], self.events(), "failed batch falsely committed")
                else:
                    self.assertEqual([], errors, "good acknowledged peer was not admitted")
                    rows = self.events()
                    self.assertEqual(len(values) + 1, len(rows))
                    if mode == "legacy-marker":
                        self.assertTrue(all("_payload_error" in row["payload"] for row in rows[:-1]))
                    if mode == "bad-ack":
                        self.assertTrue(malformed_ack.done.is_set())
                        self.assertFalse(malformed_ack.committed)
                observability.emit(q, root, {"kind": "turn.end", "_ack": ["still ordinary"]})
                observability.emit_ack(q, root, {"kind": "remote.command.outcome"}, timeout=1)
                self.assertEqual(["turn.end", "remote.command.outcome"], [e["kind"] for e in self.events()[-2:]])
                self.assertEqual([], thread_errors)
        finally:
            submitter.join(2)

    def test_legacy_ack_fields_preserve_writer_and_acknowledged_peer(self):
        self.check_legacy_ack_fields("success")

    def test_legacy_ack_fields_preserve_malformed_payload_markers(self):
        self.check_legacy_ack_fields("legacy-marker")

    def test_legacy_ack_fields_do_not_mask_malformed_internal_ack(self):
        self.check_legacy_ack_fields("bad-ack")

    def test_legacy_ack_fields_preserve_storage_failure_cleanup(self):
        self.check_legacy_ack_fields("storage-failure")

    def test_ack_waits_for_commit_not_task_done(self):
        entered, release, finished = threading.Event(), threading.Event(), threading.Event()
        original = observability._flush
        errors = []

        def blocked(*args):
            entered.set()
            self.assertTrue(release.wait(3))
            return original(*args)

        def submit():
            try:
                observability.emit_ack(self.eng.queues["traces"], str(self.root),
                                       {"kind": "remote.command.intent", "payload": {"command_id": "test"}}, timeout=2)
            except Exception as exc:
                errors.append(exc)
            finally:
                finished.set()

        # Resolve the additive API before starting threads so baseline failure is clean.
        self.assertTrue(callable(getattr(observability, "emit_ack", None)), "commit acknowledgement API missing")
        with mock.patch.object(observability, "_flush", side_effect=blocked):
            self.start_writer()
            thread = threading.Thread(target=submit)
            thread.start()
            try:
                self.assertTrue(entered.wait(2))
                self.assertEqual(0, self.eng.queues["traces"].unfinished_tasks)
                self.assertFalse(finished.is_set(), "queue task_done falsely acknowledged COMMIT")
            finally:
                release.set()
                thread.join(3)
            self.assertFalse(thread.is_alive())
        self.assertEqual([], errors)
        self.assertEqual(1, len(self.remote_events()))

    def test_malformed_ack_payload_is_not_marker_success(self):
        self.assertTrue(callable(getattr(observability, "emit_ack", None)), "commit acknowledgement API missing")
        self.start_writer()
        with self.assertRaises(observability.AuditWriteError):
            observability.emit_ack(self.eng.queues["traces"], str(self.root),
                                   {"kind": "remote.command.intent", "payload": {"bad": object()}}, timeout=.2)
        self.assertEqual([], self.remote_events())

    def test_legacy_emit_remains_nonblocking_on_dead_or_full_queue(self):
        q = queue.Queue(maxsize=1)
        q.put_nowait({"held": True})
        before = time.monotonic()
        observability.emit(q, str(self.root), {"kind": "turn.start"})
        self.assertLess(time.monotonic() - before, .2)


class ReusableBoundaryTests(AuditFixture):
    def test_transfer_receipt_states_cannot_falsely_report_success(self):
        audit = audit_module()
        self.start_writer()
        cases = [("done", "success"), ("completed", "success"), ("failed", "failure"),
                 ("cancelled", "cancelled"), ("running", "pending"), ("queued", "pending"),
                 ("started", "pending"), ("progress", "pending"), ("reserved", "pending"),
                 ("pending", "pending"), ("cancelling", "pending"), ("unknown", "unknown"),
                 ("lost", "unknown"), ("INVALID", "failure"), (None, "failure"),
                 ({"password": SECRET}, "failure")]
        for state, expected in cases:
            with self.subTest(state=state):
                def effect():
                    self.assertEqual("intent", self.remote_events()[-1]["status"])
                    return {"bytes": 0, "state": state, "error": SECRET}

                callback = mock.Mock(side_effect=effect)
                if expected == "success":
                    self.assertEqual({"bytes": 0, "state": state}, audit.run(self.context(), "transfer", callback))
                else:
                    with self.assertRaises(audit.AuditError) as caught:
                        audit.run(self.context(), "transfer", callback)
                    self.assertNotIn(SECRET, str(caught.exception))
                    if expected in {"pending", "unknown", "cancelled"}:
                        self.assertIn("do not replay", str(caught.exception))
                callback.assert_called_once_with()
                self.assertEqual(expected, self.remote_events()[-1]["status"])
                self.assert_private_absent()

    def test_inventory_discards_fields_that_only_other_operations_accept(self):
        audit = audit_module()
        self.start_writer()
        result = audit.run(self.context(), "inventory", lambda: {
            "capabilities": {}, "id": SECRET, "text": SECRET, "state": "done", "bytes": 123}, host="storm590x")
        self.assertEqual({"capabilities": {}}, result)

    def test_malformed_status_cannot_become_success_with_requested_id(self):
        audit = audit_module()
        self.start_writer()
        for data in ({}, {"state": "made-up"}, {"state": "done", "id": "other-job"},
                     {"state": "done", "exitcode": "private"}):
            with self.subTest(data=data):
                with self.assertRaises(audit.AuditError):
                    audit.run(self.context(), "status", lambda: data, host="storm590x", job_id="job-1")
                self.assertEqual("failure", self.remote_events()[-1]["status"])

    def test_malformed_transfer_receipt_cannot_become_success(self):
        audit = audit_module()
        self.start_writer()
        with self.assertRaises(audit.AuditError):
            audit.run(self.context(), "transfer", lambda: {"bytes": -1}, host="storm590x", job_id="job-1")
        self.assertEqual("failure", self.remote_events()[-1]["status"])

    def test_transfer_callback_runs_only_after_sqlite_intent_and_ignores_private_context(self):
        audit = audit_module()
        self.start_writer()
        effects = []

        def effect():
            events = self.remote_events()
            self.assertEqual(["remote.command.intent"], [e["kind"] for e in events])
            effects.append(True)
            return {"bytes": 42, "state": "done", "artifact_path": "/private/" + SECRET,
                    "root": "/private/" + SECRET, "database": SECRET, "context": {"token": SECRET}}

        result = audit.run(self.context(), "transfer", effect, host="storm590x", job_id="job-1")
        self.assertEqual([True], effects)
        self.assertEqual(42, result["bytes"])
        self.assertNotIn("artifact_path", result)
        self.assertNotIn("root", result)
        self.assertEqual("success", self.remote_events()[-1]["status"])
        self.assert_private_absent()

    def test_admission_full_dead_writer_and_storage_failure_prevent_effect(self):
        audit = audit_module()
        for mode in ("full", "dead", "storage"):
            with self.subTest(mode=mode):
                self.eng.queues["traces"] = queue.Queue(maxsize=1)
                if mode == "full":
                    self.eng.queues["traces"].put_nowait({"held": True})
                effect = mock.Mock(return_value={"state": "done"})
                with mock.patch.object(observability, "_open_conn", side_effect=sqlite3.OperationalError(SECRET)):
                    if mode == "storage":
                        self.start_writer()
                    before = time.monotonic()
                    with self.assertRaises(audit.AuditError) as caught:
                        audit.run(self.context(timeout=.1), "status", effect, host="storm590x", job_id="job-1")
                    self.assertLess(time.monotonic() - before, 1)
                    self.assertNotIn(SECRET, str(caught.exception))
                    effect.assert_not_called()
                    self.stop_workers()

    def test_terminal_storage_failure_is_uncertain_and_never_replays_effect(self):
        audit = audit_module()
        original = observability._flush
        self.start_writer()
        calls = []

        def effect():
            calls.append(True)
            return {"id": "job-1", "state": "done"}

        def fail_terminal(conns, buffers):
            if any(ev["kind"] == "remote.command.outcome" for events in buffers.values() for ev in events):
                for conn, _ in conns.values():
                    conn.execute("PRAGMA query_only=ON")
            return original(conns, buffers)

        with mock.patch.object(observability, "_flush", side_effect=fail_terminal):
            with self.assertRaises(audit.AuditError) as caught:
                audit.run(self.context(timeout=.2), "status", effect, host="storm590x", job_id="job-1")
        self.assertIn("uncertain", str(caught.exception).lower())
        self.assertEqual([True], calls)
        self.assertEqual(["remote.command.intent"], [e["kind"] for e in self.remote_events()])

    def test_cancel_confirmed_pending_and_unknown_are_distinct(self):
        audit = audit_module()
        self.start_writer()
        for state, expected in (("cancelled", "cancelled"), ("cancelling", "pending"), ("unknown", "unknown")):
            with self.subTest(state=state):
                result = audit.run(self.context(), "cancel", lambda: {"id": "job-1", "state": state},
                                   host="storm590x", job_id="job-1")
                self.assertEqual(state, result["state"])
                self.assertEqual(expected, self.remote_events()[-1]["status"])

    def test_callback_exception_is_sanitized_and_linked(self):
        audit = audit_module()
        self.start_writer()
        with self.assertRaises(audit.AuditError) as caught:
            audit.run(self.context(), "status", mock.Mock(side_effect=RuntimeError(SECRET)),
                      host="storm590x", job_id="job-1")
        self.assertNotIn(SECRET, str(caught.exception))
        self.assertEqual("failure", self.remote_events()[-1]["status"])
        self.assert_private_absent()


class RetentionRecoveryTests(AuditFixture):
    def test_managed_restart_uses_audited_status_not_original_cancel(self):
        audit = audit_module()
        recorded = threading.Event()

        def interrupted(payload, progress):
            progress({"state": "running"}, external_job_id="job-1")
            recorded.set()
            raise SystemExit()

        _, worker = self.start_thread(tasks.run_worker, q=self.eng.queues["tasks"],
            traces_queue=self.eng.queues["traces"], executors={audit.KIND: interrupted}, poll_timeout=.01)
        task_id = tasks.enqueue(self.eng.queues["tasks"], str(self.root), audit.KIND,
            audit.prepare({"host": "storm590x", "operation": "cancel", "job_id": "job-1"}), turn_id="turn-1")
        self.assertTrue(recorded.wait(3))
        worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual("progress", tasks.get_task(str(self.root), task_id)["state"])
        self.start_writer()
        replay = mock.Mock(side_effect=AssertionError("must not repeat cancellation"))
        self.start_thread(tasks.run_worker, q=queue.Queue(), traces_queue=self.eng.queues["traces"],
            executors={audit.KIND: replay}, resolvers={audit.KIND: audit.resolve_task},
            repos_getter=lambda: [("fixture", str(self.root))], poll_timeout=.01)
        row = until(lambda: (r if (r := tasks.get_task(str(self.root), task_id))["state"] == "completed" else None))
        self.assertEqual("job-1", row["external_job_id"])
        self.assertEqual({"id": "job-1", "state": "done", "exitcode": 0}, row["result"])
        self.assertEqual(["status", "status"], [e["payload"]["operation"] for e in self.remote_events()])
        self.assertEqual(["intent", "success"], [e["status"] for e in self.remote_events()])
        replay.assert_not_called()

    def test_killed_worker_leaves_incomplete_intent_and_reconciles_durable_id(self):
        audit_module()
        marker = self.root / "effect-entered"
        script = r'''
import queue, sys, threading
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from assistant import observability, remote_audit, tasks
root, marker = sys.argv[2:]
tq, aq, stop = queue.Queue(), queue.Queue(), threading.Event()
writer = threading.Thread(target=observability.run_writer, args=(aq, stop), kwargs={"poll_timeout": .01})
writer.start()
def execute(payload, progress):
    progress({"state": "running"}, external_job_id="job-1")
    def effect():
        Path(marker).write_text(progress.task_id)
        threading.Event().wait()
    remote_audit.run(progress.audit_context, "status", effect, host="storm590x", job_id="job-1")
tasks.enqueue(tq, root, "crash-remote", {"host": "storm590x"}, turn_id="turn-1")
tasks.run_worker(tq, stop, executors={"crash-remote": execute}, traces_queue=aq, poll_timeout=.01)
'''
        with tempfile.TemporaryFile(mode="w+") as output:
            child = subprocess.Popen([sys.executable, "-c", script, str(SCRIPTS), str(self.root), str(marker)],
                                     stdout=output, stderr=output)
            try:
                until(lambda: marker.exists() or child.poll() is not None)
                output.seek(0)
                self.assertTrue(marker.exists(), output.read())
                task_id = marker.read_text()
                self.assertEqual(["remote.command.intent"], [e["kind"] for e in self.remote_events()])
            finally:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=3)
        self.assertIsNotNone(child.poll())
        calls = []

        def resolve(external, payload):
            calls.append((external, payload))
            return {"state": "completed", "result": {"state": "done"}}

        submit = mock.Mock(side_effect=AssertionError("crashed operation must not replay"))
        self.start_writer()
        self.start_thread(tasks.run_worker, q=queue.Queue(), traces_queue=self.eng.queues["traces"],
            executors={"crash-remote": submit}, resolvers={"crash-remote": resolve},
            repos_getter=lambda: [("fixture", str(self.root))], poll_timeout=.01)
        row = until(lambda: (r if (r := tasks.get_task(str(self.root), task_id))["state"] == "completed" else None))
        self.assertEqual("job-1", row["external_job_id"])
        self.assertEqual([("job-1", {"host": "storm590x"})], calls)
        submit.assert_not_called()

    def test_age_and_size_prune_active_history_then_restart_reconciles_without_resubmit(self):
        audit = audit_module()
        self.start_writer()
        active, release = threading.Event(), threading.Event()
        effects = []

        def execute(payload, progress):
            progress({"state": "running"}, external_job_id="job-1")
            audit.run(progress.audit_context, "status", lambda: effects.append("status") or {"state": "running"},
                      host="storm590x", job_id="job-1")
            active.set()
            self.assertTrue(release.wait(5))
            # Leave the actual task row in progress, as a stopped process does.
            raise SystemExit()

        task_stop, task_thread = self.start_thread(tasks.run_worker, q=self.eng.queues["tasks"],
            traces_queue=self.eng.queues["traces"], executors={"future-remote": execute}, poll_timeout=.01)
        task_id = tasks.enqueue(self.eng.queues["tasks"], str(self.root), "future-remote",
                                {"host": "storm590x", "operation": "status"}, turn_id="turn-1")
        try:
            self.assertTrue(active.wait(3))
            self.assertEqual("job-1", tasks.get_task(str(self.root), task_id)["external_job_id"])
            self.assertTrue(self.remote_events())
            # Stop only the traces worker, then use its public offline pruning
            # API: never introduce a concurrent second trace writer.
            self.stops[0].set()
            self.threads[0].join(3)
            self.assertFalse(self.threads[0].is_alive())
            conn = sqlite3.connect(observability._db_path(str(self.root)))
            conn.execute("UPDATE events SET ts='2000-01-01T00:00:00+00:00' WHERE kind='remote.command.intent'")
            conn.commit()
            conn.close()
            observability.prune(str(self.root), retain_days=1, max_mb=0)
            self.assertFalse(any(e["kind"] == "remote.command.intent" for e in self.events()))
            self.assertTrue(any(e["kind"] == "remote.command.outcome" for e in self.events()))
            observability.prune(str(self.root), retain_days=0, max_mb=.001)
            self.assertEqual([], self.events())
            self.assertEqual("progress", tasks.get_task(str(self.root), task_id)["state"])
        finally:
            task_stop.set()
            release.set()
            task_thread.join(3)
        self.assertFalse(task_thread.is_alive())
        polls = []

        def resolve(external, payload):
            polls.append((external, payload))
            return {"state": "completed", "result": {"id": external, "state": "done"}}

        self.start_thread(tasks.run_worker, q=queue.Queue(), traces_queue=self.eng.queues["traces"],
            executors={"future-remote": mock.Mock(side_effect=AssertionError("must not resubmit"))},
            resolvers={"future-remote": resolve}, repos_getter=lambda: [("fixture", str(self.root))], poll_timeout=.01)
        row = until(lambda: (r if (r := tasks.get_task(str(self.root), task_id))["state"] == "completed" else None))
        self.assertEqual("job-1", row["external_job_id"])
        self.assertEqual([("job-1", {"host": "storm590x", "operation": "status"})], polls)
        self.assertEqual(["status"], effects)

    def test_reader_held_wal_defers_size_prune_without_blocking_chat(self):
        audit = audit_module()
        self.start_writer()
        audit.run(self.context(), "status", lambda: {"state": "running"}, host="storm590x", job_id="job-1")
        self.stops[0].set()
        self.threads[0].join(3)
        conn, _ = observability._open_conn(str(self.root))
        reader = sqlite3.connect(observability._db_path(str(self.root)), isolation_level=None)
        try:
            reader.execute("BEGIN")
            reader.execute("SELECT * FROM events").fetchall()
            conn.execute("UPDATE events SET ts='2000-01-01T00:00:00+00:00' WHERE kind='remote.command.intent'")
            before = time.monotonic()
            observability._prune_conn(conn, str(self.root), 1, .001)
            self.assertLess(time.monotonic() - before, 1)
            self.assertEqual(["remote.command.outcome"], [e["kind"] for e in self.events()])
            hook = self.eng._capability_reply_hook_for(str(self.root), "other-turn", "hello", self.config)
            self.assertIsNone(hook("still chatting", {}, None, {}))
            reader.execute("ROLLBACK")
            observability._prune_conn(conn, str(self.root), 0, .001)
            self.assertEqual([], self.events())
        finally:
            reader.close()
            conn.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
