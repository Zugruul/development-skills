"""Real local regressions for the controller and target protocol; no network."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
SHARED = SCRIPTS / "remote-capabilities" / "_shared"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


c = module("controller", SCRIPTS / "remote-compute.py")


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = patch.dict(os.environ, COMPUTE_HOME=str(self.root / "client"))
        self.env.start()
        self.addCleanup(self.env.stop)
        c.save_registry({"schemaVersion": 1, "resources": {
            "gpu": {"policy": {"maxConcurrentJobs": 1}, "jobs": {}}}})

    def invoke(self, fn, *args):
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                return fn(*args)
            except SystemExit as exc:
                return exc.code

    def test_parameters_are_substituted_once(self):
        reg = c.load_registry()
        reg["resources"]["gpu"]["jobs"]["echo"] = {
            "cmd": "printf '%s\\n' {a} {b}", "workdir": "~",
            "params": {"a": {"pattern": "[^`$;|&<>]+"},
                       "b": {"pattern": "[^`$;|&<>]+"}}}
        c.save_registry(reg, touched="gpu")
        value = "x\nprintf REVIEW_EXECUTED\n#"
        with patch.object(c, "_launch_job", side_effect=lambda r, s, n, w, cmd, o: cmd):
            rendered = c.cmd_run(["gpu", "echo", "--param", "a={b}", "--param", "b=" + value])
        result = subprocess.run(["bash", "-c", rendered], text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout, "{b}\n" + value + "\n")

    def test_quoted_parameters_remain_literal(self):
        value = "hello'\nprintf REVIEW_EXECUTED\n#"
        rendered = c.render_command("printf '%s\\n' '{v}' \"{v}\" {v}", {"v": value}, {})
        result = subprocess.run(["bash", "-c", rendered], text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout, (value + "\n") * 3)

    def test_stale_save_preserves_other_fields(self):
        first, second = c.load_registry(), c.load_registry()
        first["resources"]["gpu"]["envs"] = {"new": {"activate": "true"}}
        c.save_registry(first, touched="gpu")
        second["resources"]["gpu"]["state"] = {"lock": {"holder": "second"}}
        c.save_registry(second, touched="gpu")
        self.assertIn("new", c.get_resource("gpu")["envs"])
        self.assertEqual(c.load_registry()["schemaVersion"], 1)

    def test_invalid_environment_does_not_leave_a_lock(self):
        with patch.object(c, "ssh_run", return_value=(0, "", "")):
            rc = self.invoke(c.cmd_dispatch, ["gpu", "--workdir", "~", "--cmd", "true", "--env", "missing"])
        self.assertEqual(rc, 2)
        self.assertFalse(c.get_resource("gpu").get("state", {}).get("lock"))

    def test_failed_input_transfer_never_launches(self):
        with patch.object(c, "remote_state", return_value=(0, {"reserved": True})) as rpc, \
                patch.object(c.subprocess, "run", return_value=subprocess.CompletedProcess([], 23)):
            rc = self.invoke(c.cmd_dispatch, ["gpu", "--workdir", "~", "--cmd", "true", "--inputs", "/missing"])
        self.assertNotEqual(rc, 0)
        self.assertNotIn("launch", [call.args[1] for call in rpc.call_args_list])
        self.assertIn("abort", [call.args[1] for call in rpc.call_args_list])
        self.assertFalse(c.get_resource("gpu")["state"]["lock"])

    def test_duplicate_local_id_preserves_history(self):
        c._atomic_json(str(Path(c.jobs_dir()) / "same.json"), {
            "id": "same", "resource": "other", "remoteDir": "~/jobs/same", "cmd": "original", "finishedAt": "old"})
        with patch.object(c, "ssh_run", return_value=(0, "", "")):
            rc = self.invoke(c.cmd_dispatch, ["gpu", "--workdir", "~", "--cmd", "true", "--job-id", "same"])
        self.assertNotEqual(rc, 0)
        self.assertEqual(c.load_job("same")["cmd"], "original")

    def test_manifest_rejects_escaping_paths(self):
        bundle = self.root / "bundle"
        bundle.mkdir()
        for name, payload in [("../..", []), ("demo", ["../secret"]), ("demo", ["/etc/passwd"])]:
            (bundle / "capability.yaml").write_text(yaml.safe_dump({
                "name": name, "payload": payload, "jobs": {"one": {"cmd": "true"}}}))
            with self.subTest(name=name, payload=payload), self.assertRaises(ValueError):
                c.validate_bundle(str(bundle))

    def test_manifest_rejects_symlink_escape(self):
        bundle = self.root / "bundle"
        bundle.mkdir()
        (self.root / "secret").write_text("private")
        (bundle / "payload").symlink_to(self.root / "secret")
        (bundle / "capability.yaml").write_text(yaml.safe_dump({
            "name": "demo", "payload": ["payload"], "jobs": {"one": {"cmd": "true"}}}))
        with self.assertRaises(ValueError):
            c.validate_bundle(str(bundle))

    def test_shipped_manifests_validate_without_migration(self):
        for name in ("slm-training", "comfyui"):
            self.assertEqual(c.validate_bundle(str(SCRIPTS / "remote-capabilities" / name))["name"], name)

    def test_unknown_options_are_errors(self):
        self.assertEqual(self.invoke(c.cmd_dispatch, ["gpu", "--workdir", "~", "--cmd", "true", "--en", "oops"]), 2)

    def test_capability_cli_preserves_env_option(self):
        with patch.object(c, "cmd_install_capability", return_value=0) as install:
            rc = c.cmd_capability_cli(["install", "gpu", "comfyui", "--env", "render"])
        self.assertEqual(rc, 0)
        self.assertEqual(install.call_args.args[0][-2:], ["--env", "render"])

    def test_cli_installer_preserves_local_commands_and_controller_help(self):
        prefix = self.root / "prefix with spaces"
        self.assertEqual(self.invoke(c.cmd_install_cli, ["--prefix", str(prefix)]), 0)
        command = prefix / "bin" / "remote-compute"
        for arguments, expected in [(["version"], "0.2.0"), (["controller", "--help"], "capabilities"),
                                    (["capabilities", "list"], "slm-training"), (["doctor", "--help"], "doctor")]:
            result = subprocess.run([str(command)] + arguments, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn(expected, result.stdout)

    def test_doctor_is_read_only_and_reports_unreachable(self):
        before = Path(c.registry_path()).read_bytes()
        with patch.object(c, "ssh_run", return_value=(255, "", "offline")):
            self.assertNotEqual(self.invoke(c.cmd_doctor, ["gpu"]), 0)
        self.assertEqual(before, Path(c.registry_path()).read_bytes())

    def test_ssh_endpoint_uses_effective_configuration(self):
        result = subprocess.CompletedProcess([], 0, "hostname example.invalid\nuser test\nport 2222\nproxyjump bastion\n", "")
        with patch.object(c.subprocess, "run", return_value=result):
            endpoint = c.ssh_endpoint("gpu")
        self.assertEqual(endpoint["port"], 2222)
        self.assertEqual(endpoint["proxyjump"], "bastion")

    def test_sync_replaces_bundle_jobs_but_preserves_custom_jobs(self):
        reg = c.load_registry()
        res = reg["resources"]["gpu"]
        res["jobs"] = {"demo:old": {"capability": "demo"}, "custom": {"cmd": "true"}}
        res["capabilities_installed"] = {"demo": {"version": 1}}
        c.save_registry(reg, touched="gpu")
        reply = {"capabilities": {"demo": {"manifest": {"name": "demo", "jobs": {"new": {"cmd": "true"}}}, "digest": "new"}}}
        with patch.object(c, "remote_state", return_value=(0, reply)):
            self.assertEqual(self.invoke(c.cmd_capability_sync, "gpu"), 0)
        self.assertEqual(set(c.get_resource("gpu")["jobs"]), {"custom", "demo:new"})

    def test_github_source_accepts_repository_urls_only(self):
        self.assertEqual(c.github_source("https://github.com/owner/repo.git"), "https://github.com/owner/repo.git")
        self.assertEqual(c.github_source("git@github.com:owner/repo.git"), "git@github.com:owner/repo.git")
        for url in ("https://github.com.evil.test/o/r", "file:///tmp/repo", "https://github.com/o/../r"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                c.github_source(url)

    def test_repository_discovery_can_select_one_or_all(self):
        repo = self.root / "bundles"
        for cap in ("one", "two"):
            directory = repo / "nested" / cap
            directory.mkdir(parents=True)
            (directory / "capability.yaml").write_text(yaml.safe_dump({"name": cap, "jobs": {"run": {"cmd": "true"}}}))
        self.assertEqual(len(c.discover_bundles(repo, all_bundles=True)), 2)
        self.assertEqual(c.validate_bundle(str(c.discover_bundles(repo, name="two")[0]))["name"], "two")
        with self.assertRaises(ValueError):
            c.discover_bundles(repo)


class TargetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, REMOTE_COMPUTE_ROOT=str(self.root))

    def rpc(self, action, data):
        p = subprocess.run(["python3", str(SHARED / "compute-state.py"), action, json.dumps(data)],
                           env=self.env, capture_output=True, text=True, timeout=10)
        self.assertTrue(p.stdout.strip(), p.stderr)
        return p.returncode, json.loads(p.stdout)

    def test_two_clients_share_one_admission_limit(self):
        processes = [subprocess.Popen(["python3", str(SHARED / "compute-state.py"), "reserve", json.dumps({
            "id": name, "token": name, "holder": name, "limit": 1})], env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for name in ("mac", "wsl")]
        codes = []
        for proc in processes:
            out, err = proc.communicate(timeout=10)
            self.assertTrue(out.strip(), err)
            codes.append(proc.returncode)
        self.assertEqual(sorted(codes), [0, 6])

    def test_reservation_is_idempotent_but_ids_are_not_reused(self):
        request = {"id": "same", "token": "one", "holder": "me", "limit": 2}
        self.assertEqual(self.rpc("reserve", request)[0], 0)
        self.assertEqual(self.rpc("reserve", request)[0], 0)
        self.assertNotEqual(self.rpc("reserve", dict(request, token="two"))[0], 0)

    def test_identity_is_stable_across_client_names(self):
        first = self.rpc("identity", {"nickname": "storm590x"})[1]
        second = self.rpc("identity", {"nickname": "gpu"})[1]
        self.assertEqual(first["machineId"], second["machineId"])
        self.assertEqual((self.root / ".identity").read_text().strip(), "storm590x")

    def test_dead_legacy_process_is_not_running(self):
        job = self.root / "jobs" / "gone"
        job.mkdir(parents=True)
        (job / "pid").write_text("99999999")
        proc = subprocess.run(["bash", str(SHARED / "remote-compute-remote.sh"), "status", "gone"],
                              env=self.env, capture_output=True, text=True)
        self.assertNotIn("state:     running", proc.stdout)

    def test_cancel_never_claims_a_live_process_finished(self):
        job = self.root / "jobs" / "stubborn"
        job.mkdir(parents=True)
        proc = subprocess.Popen(["python3", "-c", 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print("ready",flush=True); time.sleep(30)'],
                                stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            self.assertEqual(proc.stdout.readline().strip(), "ready")
            (job / "pid").write_text(str(proc.pid))
            result = subprocess.run(["bash", str(SHARED / "remote-compute-remote.sh"), "cancel", "stubborn", "--yes"],
                                    env=self.env, capture_output=True, text=True, timeout=10)
            self.assertTrue(result.returncode != 0 or proc.poll() is not None, result.stdout)
            if proc.poll() is None:
                self.assertFalse((job / "exitcode").exists())
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)
            proc.stdout.close()

    def test_local_cli_does_not_swallow_controller_arguments(self):
        proc = subprocess.run(["bash", str(SHARED / "remote-compute-remote.sh"),
                               "capabilities", "install", "gpu", "missing"],
                              env=self.env, capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0)


if __name__ == "__main__":
    unittest.main()
