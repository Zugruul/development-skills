#!/usr/bin/env python3
"""Tests for export_gguf.py's llama-server-based smoke test.

Context (issue #221): the smoke vehicle moved off llama-cli's CLI onto
llama-server's HTTP API. On the only real GPU box (storm590x),
llama-cli's `--json-schema`/`--json-schema-file` failed at sampler init
identically across three independent llama.cpp builds, and routing around it
via `--grammar-file` made llama-cli busy-loop its interactive "> " prompt
forever despite `-no-cnv` and stdin at EOF. llama-server has no in-process
grammar-sampler init path and no interactive REPL, so both failure modes are
structurally avoided.

Every subprocess and HTTP interaction here is mocked or uses only a real
loopback socket for port allocation — no GPU, no llama.cpp build, no network
call ever leaves this process. Run directly:

    python3 plugins/spec-workflow/scripts/remote-capabilities/slm-training/tests/test_export_gguf.py

or via unittest discovery:

    python3 -m unittest discover -s plugins/spec-workflow/scripts/remote-capabilities/slm-training/tests -p "test_*.py" -v
"""
import importlib.util
import json
import os
import socket
import subprocess
import sys
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.join(HERE, os.pardir, "export_gguf.py")

_spec = importlib.util.spec_from_file_location("export_gguf", MODULE_PATH)
export_gguf = importlib.util.module_from_spec(_spec)
sys.modules["export_gguf"] = export_gguf
_spec.loader.exec_module(export_gguf)


def make_executable(path):
    with open(path, "w") as f:
        f.write("#!/bin/sh\n")
    os.chmod(path, 0o755)


# ---------------------------------------------------------------------------
# resolve_llama_server
# ---------------------------------------------------------------------------


class ResolveLlamaServerTests(unittest.TestCase):
    def setUp(self):
        import tempfile

        self._tmp_ctx = tempfile.TemporaryDirectory()
        self.tmp = self._tmp_ctx.name
        self.addCleanup(self._tmp_ctx.cleanup)
        # HOME drives os.path.expanduser("~...") without touching that
        # function directly, so the real discovery code path runs unmodified.
        env_patch = mock.patch.dict(os.environ, {"HOME": self.tmp}, clear=False)
        env_patch.start()
        self.addCleanup(env_patch.stop)
        self.cwd = os.path.join(self.tmp, "cwd")
        os.makedirs(self.cwd)
        cwd_patch = mock.patch.object(os, "getcwd", return_value=self.cwd)
        cwd_patch.start()
        self.addCleanup(cwd_patch.stop)

    def test_uses_configured_llama_server_path_when_it_exists(self):
        server = os.path.join(self.tmp, "custom-llama-server")
        make_executable(server)
        result = export_gguf.resolve_llama_server({"llama_server": server})
        self.assertEqual(result, server)

    def test_derives_llama_server_from_deprecated_llama_cli_key(self):
        # llama-cli and llama-server ship from the same build/bin/ dir --
        # deriving the sibling binary keeps an old config working across the
        # #221 rename instead of breaking it outright.
        build_dir = os.path.join(self.tmp, "opt", "llama.cpp", "build", "bin")
        os.makedirs(build_dir)
        cli = os.path.join(build_dir, "llama-cli")
        server = os.path.join(build_dir, "llama-server")
        make_executable(cli)
        make_executable(server)
        result = export_gguf.resolve_llama_server({"llama_cli": cli})
        self.assertEqual(result, server)

    def test_llama_cli_key_ignored_when_derived_server_binary_is_missing(self):
        build_dir = os.path.join(self.tmp, "opt", "llama.cpp", "build", "bin")
        os.makedirs(build_dir)
        cli = os.path.join(build_dir, "llama-cli")
        make_executable(cli)  # no sibling llama-server
        result = export_gguf.resolve_llama_server({"llama_cli": cli})
        self.assertIsNone(result)

    def test_llama_server_key_takes_precedence_over_deprecated_llama_cli(self):
        server = os.path.join(self.tmp, "preferred-llama-server")
        make_executable(server)
        cli = os.path.join(self.tmp, "other-llama-cli")
        make_executable(cli)
        result = export_gguf.resolve_llama_server({"llama_server": server, "llama_cli": cli})
        self.assertEqual(result, server)

    def test_falls_back_to_default_path_under_home(self):
        default_dir = os.path.join(self.tmp, "llama.cpp", "build", "bin")
        os.makedirs(default_dir)
        server = os.path.join(default_dir, "llama-server")
        make_executable(server)
        result = export_gguf.resolve_llama_server({})
        self.assertEqual(result, server)

    def test_discovers_llama_cpp_prefixed_dir_in_cwd_when_default_missing(self):
        found_dir = os.path.join(self.cwd, "llama.cpp-custom", "build", "bin")
        os.makedirs(found_dir)
        server = os.path.join(found_dir, "llama-server")
        make_executable(server)
        result = export_gguf.resolve_llama_server({})
        self.assertEqual(result, server)

    def test_discovery_falls_back_to_bare_server_name(self):
        found_dir = os.path.join(self.cwd, "llama.cpp-alt", "build", "bin")
        os.makedirs(found_dir)
        server = os.path.join(found_dir, "server")  # older llama.cpp binary name
        make_executable(server)
        result = export_gguf.resolve_llama_server({})
        self.assertEqual(result, server)

    def test_returns_none_when_nothing_found(self):
        result = export_gguf.resolve_llama_server({})
        self.assertIsNone(result)


# ---------------------------------------------------------------------------
# find_free_port
# ---------------------------------------------------------------------------


class FindFreePortTests(unittest.TestCase):
    def test_returns_a_genuinely_bindable_port(self):
        port = export_gguf.find_free_port()
        self.assertIsInstance(port, int)
        self.assertGreater(port, 0)
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", port))
        finally:
            s.close()


# ---------------------------------------------------------------------------
# wait_for_health
# ---------------------------------------------------------------------------


class WaitForHealthTests(unittest.TestCase):
    def test_returns_true_once_status_ok(self):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b'{"status": "ok"}'
        with mock.patch("urllib.request.urlopen", return_value=response):
            result = export_gguf.wait_for_health(8080, time.time() + 5)
        self.assertTrue(result)

    def test_returns_false_once_deadline_passes_without_ready(self):
        with mock.patch("urllib.request.urlopen", side_effect=export_gguf.urllib.error.URLError("refused")), \
             mock.patch("time.sleep", return_value=None):
            result = export_gguf.wait_for_health(8080, time.time() + 0.05)
        self.assertFalse(result)

    def test_treats_503_loading_body_as_not_ready_yet_not_a_crash(self):
        err = export_gguf.urllib.error.HTTPError("http://x/health", 503, "Loading model", None, None)
        with mock.patch("urllib.request.urlopen", side_effect=err), \
             mock.patch("time.sleep", return_value=None):
            result = export_gguf.wait_for_health(8080, time.time() + 0.05)
        self.assertFalse(result)


# ---------------------------------------------------------------------------
# post_completion
# ---------------------------------------------------------------------------


class PostCompletionTests(unittest.TestCase):
    def test_sends_prompt_json_schema_n_predict_and_zero_temperature_to_completion(self):
        captured = {}
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = json.dumps({"content": '{"ok": true}'}).encode("utf-8")

        def fake_urlopen(req, timeout=None):
            captured["url"] = req.full_url
            captured["method"] = req.get_method()
            captured["body"] = json.loads(req.data.decode("utf-8"))
            captured["timeout"] = timeout
            return response

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = export_gguf.post_completion(8080, "hello", {"type": "object"}, 64, 30)

        self.assertEqual(captured["url"], "http://127.0.0.1:8080/completion")
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(
            captured["body"],
            {"prompt": "hello", "json_schema": {"type": "object"}, "n_predict": 64, "temperature": 0},
        )
        self.assertEqual(result, {"content": '{"ok": true}'})


# ---------------------------------------------------------------------------
# run_smoke_for_file — the SmokeFileResult contract, server lifecycle
# ---------------------------------------------------------------------------


class RunSmokeForFileTests(unittest.TestCase):
    SCHEMA = {"type": "object", "required": ["ok"], "properties": {"ok": {"type": "boolean"}}}

    def _fake_proc(self, running=True, wait_raises_timeout_once=False):
        proc = mock.Mock()
        proc.poll.return_value = None if running else 1
        if wait_raises_timeout_once:
            proc.wait.side_effect = [subprocess.TimeoutExpired(cmd="llama-server", timeout=10), None]
        return proc

    def test_success_returns_smoke_file_result_contract_and_terminates_server(self):
        proc = self._fake_proc(running=True)
        with mock.patch.object(export_gguf.subprocess, "Popen", return_value=proc), \
             mock.patch.object(export_gguf, "find_free_port", return_value=54321), \
             mock.patch.object(export_gguf, "wait_for_health", return_value=True), \
             mock.patch.object(export_gguf, "post_completion", return_value={"content": '{"ok": true}'}):
            result = export_gguf.run_smoke_for_file(
                "/tmp/model.gguf",
                {"prompt": "p", "json_schema": self.SCHEMA, "max_tokens": 32},
                "/opt/llama.cpp/build/bin/llama-server",
            )
        # exact SmokeFileResult contract (the caller's config-surface type
        # for this bundle's export-gguf job, minus `file`, which the caller
        # in main() adds) -- must not gain or lose keys across the vehicle
        # switch.
        self.assertEqual(set(result.keys()), {"loaded", "constrainedOutputRaw", "parsedOk"})
        self.assertEqual(result, {"loaded": True, "constrainedOutputRaw": '{"ok": true}', "parsedOk": True})
        proc.terminate.assert_called_once()
        proc.kill.assert_not_called()

    def test_health_never_ready_returns_loaded_false_never_posts_still_terminates_server(self):
        proc = self._fake_proc(running=True)
        with mock.patch.object(export_gguf.subprocess, "Popen", return_value=proc), \
             mock.patch.object(export_gguf, "find_free_port", return_value=54321), \
             mock.patch.object(export_gguf, "wait_for_health", return_value=False), \
             mock.patch.object(export_gguf, "post_completion") as post:
            result = export_gguf.run_smoke_for_file(
                "/tmp/model.gguf",
                {"prompt": "p", "json_schema": self.SCHEMA, "max_tokens": 32},
                "/opt/llama.cpp/build/bin/llama-server",
            )
        self.assertEqual(result, {"loaded": False, "constrainedOutputRaw": "", "parsedOk": False})
        post.assert_not_called()
        proc.terminate.assert_called_once()

    def test_kills_process_when_terminate_does_not_stop_it_in_time_no_orphan(self):
        # The whole point of #221's fix: a server that won't die on its own
        # must never be left running (that's the busy-loop failure mode,
        # structurally impossible here because of this fallback).
        proc = self._fake_proc(running=True, wait_raises_timeout_once=True)
        with mock.patch.object(export_gguf.subprocess, "Popen", return_value=proc), \
             mock.patch.object(export_gguf, "find_free_port", return_value=54321), \
             mock.patch.object(export_gguf, "wait_for_health", return_value=False):
            export_gguf.run_smoke_for_file(
                "/tmp/model.gguf",
                {"prompt": "p", "json_schema": self.SCHEMA, "max_tokens": 32},
                "/opt/llama.cpp/build/bin/llama-server",
            )
        proc.terminate.assert_called_once()
        proc.kill.assert_called_once()

    def test_server_still_terminated_when_post_completion_raises(self):
        proc = self._fake_proc(running=True)
        with mock.patch.object(export_gguf.subprocess, "Popen", return_value=proc), \
             mock.patch.object(export_gguf, "find_free_port", return_value=54321), \
             mock.patch.object(export_gguf, "wait_for_health", return_value=True), \
             mock.patch.object(export_gguf, "post_completion", side_effect=OSError("connection reset")):
            result = export_gguf.run_smoke_for_file(
                "/tmp/model.gguf",
                {"prompt": "p", "json_schema": self.SCHEMA, "max_tokens": 32},
                "/opt/llama.cpp/build/bin/llama-server",
            )
        self.assertEqual(result, {"loaded": True, "constrainedOutputRaw": "connection reset", "parsedOk": False})
        proc.terminate.assert_called_once()

    def test_malformed_json_content_is_parsed_ok_false_not_a_crash(self):
        proc = self._fake_proc(running=True)
        with mock.patch.object(export_gguf.subprocess, "Popen", return_value=proc), \
             mock.patch.object(export_gguf, "find_free_port", return_value=54321), \
             mock.patch.object(export_gguf, "wait_for_health", return_value=True), \
             mock.patch.object(export_gguf, "post_completion", return_value={"content": "not json at all"}):
            result = export_gguf.run_smoke_for_file(
                "/tmp/model.gguf",
                {"prompt": "p", "json_schema": self.SCHEMA, "max_tokens": 32},
                "/opt/llama.cpp/build/bin/llama-server",
            )
        self.assertTrue(result["loaded"])
        self.assertFalse(result["parsedOk"])

    def test_content_missing_required_key_is_parsed_ok_false(self):
        proc = self._fake_proc(running=True)
        with mock.patch.object(export_gguf.subprocess, "Popen", return_value=proc), \
             mock.patch.object(export_gguf, "find_free_port", return_value=54321), \
             mock.patch.object(export_gguf, "wait_for_health", return_value=True), \
             mock.patch.object(export_gguf, "post_completion", return_value={"content": '{"unexpected": 1}'}):
            result = export_gguf.run_smoke_for_file(
                "/tmp/model.gguf",
                {"prompt": "p", "json_schema": self.SCHEMA, "max_tokens": 32},
                "/opt/llama.cpp/build/bin/llama-server",
            )
        self.assertFalse(result["parsedOk"])

    def test_spawns_llama_server_with_model_path_and_allocated_port(self):
        proc = self._fake_proc(running=True)
        with mock.patch.object(export_gguf.subprocess, "Popen", return_value=proc) as popen, \
             mock.patch.object(export_gguf, "find_free_port", return_value=54321), \
             mock.patch.object(export_gguf, "wait_for_health", return_value=True), \
             mock.patch.object(export_gguf, "post_completion", return_value={"content": "{}"}):
            export_gguf.run_smoke_for_file(
                "/tmp/model.gguf",
                {"prompt": "p", "json_schema": self.SCHEMA, "max_tokens": 32},
                "/opt/llama.cpp/build/bin/llama-server",
            )
        cmd = popen.call_args[0][0]
        self.assertEqual(cmd[0], "/opt/llama.cpp/build/bin/llama-server")
        self.assertIn("/tmp/model.gguf", cmd)
        self.assertIn("54321", cmd)

    def test_binary_fails_to_launch_returns_loaded_false_not_a_crash(self):
        with mock.patch.object(export_gguf.subprocess, "Popen", side_effect=OSError("not found")), \
             mock.patch.object(export_gguf, "find_free_port", return_value=54321):
            result = export_gguf.run_smoke_for_file(
                "/tmp/model.gguf",
                {"prompt": "p", "json_schema": self.SCHEMA, "max_tokens": 32},
                "/opt/llama.cpp/build/bin/llama-server",
            )
        self.assertEqual(result["loaded"], False)
        self.assertFalse(result["parsedOk"])


if __name__ == "__main__":
    unittest.main()
