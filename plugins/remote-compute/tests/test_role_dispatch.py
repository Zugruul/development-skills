"""Role selection against disposable targets using the real admission protocol."""
import contextlib
import copy
import importlib.util
import io
import itertools
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import yaml

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
REPO = SCRIPTS.parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


c = module("role_controller", SCRIPTS / "remote-compute.py")
config = module("role_config", REPO / "plugins/spec-workflow/scripts/config.py")


class RoleDispatchTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.project = self.root / "project with spaces"
        self.cfg = self.project / ".neural-network"
        self.cfg.mkdir(parents=True)
        self.calls = []
        self.resources = {}
        for nick in ("alpha", "beta", "gamma"):
            home = self.root / nick
            home.mkdir()
            self.resources[nick] = {"jobs": {"work": {
                "cmd": "mkdir -p \"$COMPUTE_JOB_DIR/outputs\"; printf '%s' '{value}' > \"$COMPUTE_JOB_DIR/outputs/value\"",
                "workdir": str(home), "env": "ready",
                "params": {"value": {"pattern": ".*", "default": nick}}}},
                "envs": {"ready": {"activate": "true"}},
                "policy": {"maxConcurrentJobs": 1}}
        env = patch.dict(os.environ, COMPUTE_HOME=str(self.root / "client"))
        env.start()
        self.addCleanup(env.stop)
        self.save()
        self.project_data(["beta", "alpha"])
        transport = patch.object(c, "ssh_run", side_effect=self.ssh)
        transport.start()
        self.addCleanup(transport.stop)
        self.distort = None
        self.offline = set()

    def save(self):
        c.save_registry({"schemaVersion": 1, "resources": self.resources})

    def project_data(self, aliases):
        data = {"schemaVersion": "2.0.0", "compute": {"resources": {
            nick: {"enabled": True, "roles": ["render"]} for nick in aliases}}}
        (self.cfg / "project.yaml").write_text(yaml.safe_dump(data, sort_keys=False))
        return data

    def target_env(self, nick):
        return dict(os.environ, HOME=str(self.root / nick),
                    REMOTE_COMPUTE_ROOT=str(self.root / nick / ".remote-compute"))

    def ssh(self, nick, payload, timeout=60):
        words = shlex.split(payload)
        action = words[3] if words[:2] == ["python3", "-c"] else "connect"
        self.calls.append((nick, action, timeout))
        if nick in self.offline:
            return 255, "", "fixture connection refused"
        result = subprocess.run(["bash", "-c", payload], env=self.target_env(nick),
                                capture_output=True, text=True, timeout=15)
        reply = (result.returncode, result.stdout.strip(), result.stderr.strip())
        return self.distort(nick, action, reply) if self.distort else reply

    def rpc(self, nick, action, **data):
        result = subprocess.run(["python3", str(SCRIPTS / "remote-capabilities/_shared/compute-state.py"),
                                 action, json.dumps(data)], env=self.target_env(nick),
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def invoke(self, arguments, root=True):
        args = list(arguments)
        if root:
            args += ["--root", str(self.project)]
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                rc = c.main(args)
            except SystemExit as exc:
                rc = exc.code
        return rc, out.getvalue()

    def run_role(self, *extra):
        return self.invoke(["run", "--role", "render", "work", "--job-id", "selected", *extra])

    def wait_job(self, nick, job="selected"):
        directory = self.root / nick / ".remote-compute/jobs" / job
        deadline = time.monotonic() + 5
        while not (directory / "exitcode").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual((directory / "exitcode").read_text().strip(), "0",
                         (directory / "job.log").read_text())
        return directory

    def test_lexical_selection_and_candidate_owned_rendering(self):
        for order in itertools.permutations(self.resources):
            with self.subTest(order=order):
                self.project_data(order)
                job = "j" + "-".join(order)
                rc, out = self.invoke(["run", "--role", "render", "work", "--job-id", job])
                self.assertEqual(rc, 0, out)
                self.assertIn("alpha", out)
                directory = self.wait_job("alpha", job)
                self.assertEqual((directory / "outputs/value").read_text(), "alpha")
        self.assertEqual({nick for nick, _, _ in self.calls}, {"alpha"})

    def test_overlay_whole_replacement_matches_shared_loader(self):
        for override in ({"resources": {}}, {}, {"resources": {"beta": {
                "enabled": True, "roles": ["render"]}}}):
            with self.subTest(override=override):
                (self.cfg / "project.local.yaml").write_text(yaml.safe_dump({
                    "compute": override, "unrelated": {"invalid-for-project": True}}))
                self.assertEqual(config.load_config(root=str(self.project), warn=False)["compute"], override)
                rc, out = self.run_role()
                self.assertEqual(rc, 0 if override.get("resources") else 2, out)
                if rc == 0:
                    self.assertEqual(c.load_job("selected")["resource"], "beta")
                    self.wait_job("beta")
        self.assertNotIn("alpha", {nick for nick, _, _ in self.calls})

    def test_invalid_relevant_yaml_and_absent_compute_fail_closed(self):
        invalid = [[], "bad", {"compute": None}, {"compute": []},
                   {"compute": {"resources": []}}, {"compute": {"resources": {"alpha": []}}},
                   {"compute": {"resources": {"alpha": {"enabled": "true", "roles": ["render"]}}}},
                   {"compute": {"resources": {"alpha": {"enabled": 1, "roles": ["render"]}}}},
                   {"compute": {"resources": {"alpha": {"enabled": True, "roles": "render"}}}},
                   {"compute": {"resources": {"alpha": {"roles": [4]}}}}, {}]
        for data in invalid:
            with self.subTest(data=data):
                (self.cfg / "project.yaml").write_text(yaml.safe_dump(data))
                rc, out = self.run_role()
                self.assertEqual(rc, 2, out)
                self.assertTrue(out.strip())
        self.project_data(["alpha"])
        for text in ("[]", "compute: [", "null"):
            (self.cfg / "project.local.yaml").write_text(text)
            self.assertEqual(self.run_role()[0], 2)
        self.assertEqual(self.calls, [])

    def test_enabled_exact_role_and_registered_exclusions_are_reported(self):
        data = self.project_data(["alpha", "beta", "missing"])
        data["compute"]["resources"]["alpha"]["enabled"] = False
        data["compute"]["resources"]["beta"]["roles"] = ["Render"]
        (self.cfg / "project.yaml").write_text(yaml.safe_dump(data))
        rc, out = self.run_role()
        self.assertEqual(rc, 2, out)
        for text in ("alpha", "beta", "missing", "disabled", "role", "registered"):
            self.assertIn(text, out)
        self.assertEqual(self.calls, [])

    def test_local_job_and_environment_incompatibility_skip_without_transport(self):
        original = copy.deepcopy(self.resources["alpha"])
        variants = [{"jobs": {}}, {"envs": {}}, {"envs": {"ready": {"activate": " "}}},
                    {"envs": {"ready": {"activate": "true", "verified": {"error": "import failed"}}}},
                    {"jobs": {"work": dict(original["jobs"]["work"], params={"required": {}})}}]
        for index, variant in enumerate(variants):
            with self.subTest(variant=variant):
                self.resources["alpha"] = dict(original, **variant)
                self.save()
                job = "compatible-%s" % index
                rc, out = self.invoke(["run", "--role", "render", "work", "--job-id", job])
                self.assertEqual(rc, 0, out)
                self.assertIn("SKIP alpha", out)
                self.assertEqual(c.load_job(job)["resource"], "beta")
                self.wait_job("beta", job)
        self.assertNotIn("alpha", {nick for nick, _, _ in self.calls})

    def test_target_busy_and_lock_refusals_allow_fallback(self):
        for locked in (False, True):
            with self.subTest(locked=locked):
                if locked:
                    self.rpc("alpha", "abort", id="held", token="other")
                    self.rpc("alpha", "lock", owner="other", holder="other", reason="manual")
                else:
                    self.rpc("alpha", "reserve", id="held", token="other", limit=1)
                job = "fallback-%s" % locked
                rc, out = self.invoke(["run", "--role", "render", "work", "--job-id", job])
                self.assertEqual(rc, 0, out)
                self.assertIn("LOCKED" if locked else "BUSY", out)
                self.wait_job("beta", job)
        self.assertNotIn(("alpha", "launch"), [(n, a) for n, a, _ in self.calls])

    def test_definite_foreign_id_refusal_does_not_create_recovery_access(self):
        job = "foreign-owned"
        release = self.root / "release-foreign"
        self.rpc("alpha", "reserve", id=job, token="foreign-token", owner="foreign-controller", limit=1)
        self.rpc("alpha", "launch", id=job, token="foreign-token", workdir=str(self.root / "alpha"),
                 cmd="printf 'foreign output\\n'; while [ ! -e %s ]; do sleep 0.05; done" % shlex.quote(str(release)))
        try:
            self.assertEqual(self.rpc("alpha", "status", id=job)["state"], "running")
            self.assert_definite_id_refusal(job, "job ID already exists: " + job)
            self.assertEqual(self.rpc("alpha", "status", id=job)["state"], "running")
        finally:
            release.touch()
            self.wait_job("alpha", job)

    def test_definite_historical_id_refusal_does_not_create_receipt(self):
        job = "previously-used"
        self.rpc("alpha", "reserve", id=job, token="foreign-token", owner="foreign-controller", limit=1)
        self.rpc("alpha", "abort", id=job, token="foreign-token")
        directory = self.root / "alpha/.remote-compute/jobs" / job
        for path in directory.iterdir():
            path.unlink()
        directory.rmdir()
        self.assert_definite_id_refusal(job, "job ID was previously used: " + job)

    def assert_definite_id_refusal(self, job, error):
        for named, role in itertools.product((True, False), repeat=2):
            with self.subTest(named=named, role=role), patch.dict(os.environ,
                    COMPUTE_HOME=str(self.root / ("refused-client-%s-%s" % (named, role)))):
                self.save()
                self.calls.clear()
                args = ["run" if named else "dispatch"]
                args += ["--role", "render"] if role else ["alpha"]
                args += ["work"] if named else ["--workdir", str(self.root / "alpha"), "--cmd", "true"]
                rc, out = self.invoke(args + ["--job-id", job], root=role)
                self.assertEqual(rc, 2, out)
                self.assertIn(error, out)
                self.assertFalse((Path(c.jobs_dir()) / (job + ".json")).exists(), out)
                self.assertEqual({n for n, _, _ in self.calls}, {"alpha"})
                self.assertEqual([a for _, a, _ in self.calls].count("reserve"), 1)
                self.assertNotIn("launch", [a for _, a, _ in self.calls])
                self.assertNotIn("job-status " + job, out)
                self.calls.clear()
                for verb in ("job-status", "job-logs", "job-cancel"):
                    recovery_rc, recovery_out = self.invoke([verb, job], root=False)
                    self.assertEqual(recovery_rc, 2, recovery_out)
                    self.assertIn("no job state", recovery_out)
                self.assertEqual(self.calls, [], "rejected invocation gained remote recovery access")

    def test_lock_refusal_allows_empty_and_multiline_holder_and_reason(self):
        texts = ("", "operator", "maintenance\nwaiting for replacement part", "\n")
        for index, (holder, reason) in enumerate(itertools.product(texts, repeat=2)):
            with self.subTest(holder=holder, reason=reason), patch.dict(os.environ,
                    COMPUTE_HOME=str(self.root / ("lock-client-%s" % index))):
                self.save()
                self.calls.clear()
                self.rpc("alpha", "lock", owner="foreign-controller", holder=holder, reason=reason, force=True)
                job = "lock-text-%s" % index
                rc, out = self.invoke(["run", "--role", "render", "work", "--job-id", job])
                self.assertEqual(rc, 0, out)
                self.assertIn("LOCKED: held by %s: %s" % (holder, reason), out)
                self.assertEqual(c.load_job(job)["resource"], "beta")
                self.wait_job("beta", job)
                self.assertNotIn(("alpha", "launch"), [(n, a) for n, a, _ in self.calls])

    def test_refusal_text_in_ambiguous_envelope_retains_unknown_receipt(self):
        for index, variant in enumerate(("ambiguous-id", "reserved-id", "wrong-code", "wrong-id",
                                        "ambiguous-lock", "reserved-lock", "empty", "malformed", "null-error")):
            with self.subTest(variant=variant):
                self.calls.clear()
                job = "uncertain-envelope-%s" % index
                error = "job ID already exists: %s (use a new ID for a retry)" % job
                reply, rc = {"error": error}, 2
                if variant == "ambiguous-id":
                    reply["ambiguous"] = True
                elif variant == "reserved-id":
                    reply["reserved"] = True
                elif variant == "wrong-code":
                    rc = 6
                elif variant == "wrong-id":
                    reply["error"] = "job ID already exists: different-id (use a new ID for a retry)"
                elif variant in ("ambiguous-lock", "reserved-lock"):
                    rc = 6
                    reply = {"error": "LOCKED: held by : maintenance\nwaiting for replacement part",
                             "ambiguous" if variant == "ambiguous-lock" else "reserved": True}
                elif variant == "empty":
                    reply = {}
                elif variant == "null-error":
                    reply = {"error": None}
                payload = "not JSON" if variant == "malformed" else json.dumps(reply)
                self.distort = lambda nick, action, real: (rc, payload, "") if action == "reserve" else real
                result, out = self.invoke(["run", "--role", "render", "work", "--job-id", job])
                self.assertEqual(result, rc, out)
                self.assertEqual(c.load_job(job)["phase"], "unknown")
                self.assertEqual({n for n, _, _ in self.calls}, {"alpha"})
                self.assertNotIn("launch", [a for _, a, _ in self.calls])
                self.assertEqual(self.rpc("alpha", "status", id=job)["state"], "reserved")
                self.rpc("alpha", "abort", id=job, token=c.load_job(job)["token"])

    def test_exhaustion_codes_and_connectivity_is_bounded(self):
        for nick in ("alpha", "beta"):
            self.rpc(nick, "reserve", id="held", token="other", limit=1)
        self.assertEqual(self.run_role()[0], 6)
        self.offline.add("alpha")
        rc, out = self.run_role()
        self.assertEqual(rc, 1, out)
        self.assertIn("fixture connection refused", out)
        self.assertTrue(all(timeout <= 15 for _, action, timeout in self.calls if action == "connect"))

    def test_pre_reservation_unreachable_and_local_locks_allow_fallback(self):
        self.offline.add("alpha")
        rc, out = self.run_role()
        self.assertEqual(rc, 0, out)
        self.wait_job("beta")
        self.assertNotIn(("alpha", "reserve"), [(n, a) for n, a, _ in self.calls])
        self.offline.clear()
        self.calls.clear()
        self.resources["alpha"]["state"] = {"lock": {"holder": "other", "reason": "manual"}}
        self.save()
        rc, out = self.invoke(["run", "--role", "render", "work", "--job-id", "local-lock"])
        self.assertEqual(rc, 0, out)
        self.assertIn("local-lock", out)
        self.wait_job("beta", "local-lock")
        self.assertNotIn(("alpha", "reserve"), [(n, a) for n, a, _ in self.calls])

    def test_local_capacity_check_never_reserves_busy_target(self):
        self.rpc("alpha", "reserve", id="held", token="other", limit=1)
        c._atomic_json(str(Path(c.jobs_dir()) / "held.json"), {
            "id": "held", "resource": "alpha", "remoteDir": "~/.remote-compute/jobs/held", "protocol": 1})
        rc, out = self.run_role()
        self.assertEqual(rc, 0, out)
        self.assertIn("local-capacity", out)
        self.wait_job("beta")
        self.assertNotIn(("alpha", "reserve"), [(n, a) for n, a, _ in self.calls])

    def test_ambiguous_reservation_never_tries_second_target(self):
        replies = [(255, "", "lost reply"), (6, "{}", ""),
                   (6, '{"error": null}', ""), (6, '{"error": "unrecognized"}', ""),
                   (6, '{"error": "BUSY: maxConcurrentJobs=1; active: held", "reserved": true}', ""),
                   (6, '{"error": "BUSY: maxConcurrentJobs=1; active: held", "ambiguous": true}', ""),
                   (0, '{"reserved": false}', ""), (0, '{"reserved": true, "id": "wrong"}', ""),
                   (0, "malformed", "")]
        for index, reply in enumerate(replies):
            with self.subTest(reply=reply):
                self.calls.clear()
                job = "ambiguous-%s" % index
                self.rpc("alpha", "policy", maxConcurrentJobs=20)
                self.resources["alpha"]["policy"]["maxConcurrentJobs"] = 20
                self.save()
                self.distort = lambda nick, action, real: reply if action == "reserve" else real
                rc, out = self.invoke(["run", "--role", "render", "work", "--job-id", job])
                self.assertNotEqual(rc, 0, out)
                self.assertEqual({n for n, _, _ in self.calls}, {"alpha"})
                for text in ("alpha", job, "inspect"):
                    self.assertIn(text, out)
                self.assertNotIn("launch", [a for _, a, _ in self.calls])

    def test_lost_launch_reply_retains_unknown_and_one_execution_even_exit6(self):
        for index, (code, payload) in enumerate(((255, "garbled"), (6, "garbled"), (6, "{}"),
                                                (6, '{"error": null}'), (0, '{"launched": false}'))):
            job = "lost-%s" % index
            self.calls.clear()
            self.distort = lambda nick, action, real: (code, payload, "lost launch") if action == "launch" else real
            rc, out = self.invoke(["run", "--role", "render", "work", "--job-id", job])
            self.assertEqual(rc, code or 1, out)
            self.wait_job("alpha", job)
            self.assertEqual(c.load_job(job)["phase"], "unknown")
            self.assertEqual({n for n, _, _ in self.calls}, {"alpha"})
            self.assertEqual([a for _, a, _ in self.calls].count("launch"), 1)
            self.assertIn("job-status " + job, out)

    def test_staging_and_explicit_launch_exit6_are_hard_stops(self):
        with patch.object(c, "rsync_argv", return_value=["bash", "-c", "exit 6"]):
            rc, out = self.run_role("--inputs", str(self.root))
        self.assertNotEqual(rc, 0, out)
        self.assertEqual(c.load_job("selected")["phase"], "failed-staging")
        self.assertEqual({n for n, _, _ in self.calls}, {"alpha"})
        self.calls.clear()
        self.distort = lambda nick, action, real: (6, '{"error": "BUSY: launch failed"}', "") if action == "launch" else real
        rc, out = self.invoke(["run", "--role", "render", "work", "--job-id", "launch6"])
        self.assertEqual(rc, 6, out)
        self.wait_job("alpha", "launch6")
        self.assertEqual({n for n, _, _ in self.calls}, {"alpha"})

    def test_adverse_selectors_and_global_ids_rejected_before_transport(self):
        cases = [["run", "--role"], ["run", "--role", "", "work"],
                 ["run", "--role", " ", "work"], ["run", "--role", "--root", "work"],
                 ["run", "--role", "render", "alpha", "work"],
                 ["run", "alpha", "work", "--role", "render"],
                 ["run", "--role", "render", "work", "--role", "render"],
                 ["run", "--role", "render", "work", "--root", str(self.project)],
                 ["run", "--role", "render", "work", "--typo", "x"],
                 ["run", "--role", "render", "work", "--job-id", "../bad"],
                 ["run", "--role", "render", "work", "--root", ""],
                 ["dispatch", "--role", "render", "alpha", "--workdir", "~", "--cmd", "true"]]
        for args in cases:
            with self.subTest(args=args):
                self.assertEqual(self.invoke(args)[0], 2)
        self.assertEqual(self.calls, [])

    def test_option_looking_values_are_data_and_quoting_survives(self):
        value = "--role --root $(touch SHOULD_NOT_EXIST); 'quoted'"
        rc, out = self.run_role("--param", "value=" + value, "--holder", "--role")
        self.assertEqual(rc, 0, out)
        directory = self.wait_job("alpha")
        self.assertEqual((directory / "outputs/value").read_text(), value)
        self.assertFalse((self.root / "alpha/SHOULD_NOT_EXIST").exists())
        self.assertEqual(c.load_job("selected")["holder"], "--role")

    def test_no_compatible_job_or_param_is_usage_error_without_transport(self):
        for res in self.resources.values():
            res["jobs"]["work"]["params"]["value"]["pattern"] = "[0-9]+"
        self.save()
        rc, out = self.run_role("--param", "value=not-a-number")
        self.assertEqual(rc, 2, out)
        self.assertIn("SKIP alpha", out)
        self.assertIn("SKIP beta", out)
        self.assertIn("pattern", out)
        self.assertEqual(self.calls, [])

    def test_raw_environment_selection_and_explicit_nickname_ignore_project(self):
        self.resources["alpha"]["envs"]["ready"]["verified"] = {"error": "broken"}
        self.save()
        rc, out = self.invoke(["dispatch", "--role", "render", "--env", "ready", "--workdir",
                               str(self.root / "beta"), "--cmd", "true", "--job-id", "raw"])
        self.assertEqual(rc, 0, out)
        self.wait_job("beta", "raw")
        self.assertEqual(c.load_job("raw")["resource"], "beta")
        (self.cfg / "project.yaml").write_text("compute: [broken")
        for cwd in (self.project, self.root):
            job = "named-" + cwd.name.replace(" ", "-")
            previous = os.getcwd()
            try:
                os.chdir(cwd)
                rc, out = self.invoke(["run", "alpha", "work", "--job-id", job], root=False)
            finally:
                os.chdir(previous)
            self.assertEqual(rc, 0, out)
            self.wait_job("alpha", job)
            previous = os.getcwd()
            try:
                os.chdir(cwd)
                rc, out = self.invoke(["dispatch", "gamma", "--workdir", str(self.root / "gamma"),
                                       "--cmd", "true", "--job-id", "raw-" + job], root=False)
            finally:
                os.chdir(previous)
            self.assertEqual(rc, 0, out)
            self.wait_job("gamma", "raw-" + job)

    def test_missing_project_and_existing_id_fail_before_transport(self):
        (self.cfg / "project.yaml").unlink()
        rc, out = self.run_role()
        self.assertEqual(rc, 2, out)
        self.assertIn("project.yaml", out)
        self.project_data(["alpha"])
        receipt = Path(c.jobs_dir()) / "selected.json"
        c._atomic_json(str(receipt), {"id": "selected", "sentinel": "original"})
        before = receipt.read_bytes()
        rc, out = self.run_role()
        self.assertEqual(rc, 2, out)
        self.assertEqual(receipt.read_bytes(), before)
        self.assertEqual(self.calls, [])

    def test_installed_combined_cli_uses_role_without_shared_config_module(self):
        prefix = self.root / "installed"
        rc, out = self.invoke(["install-cli", "--prefix", str(prefix)], root=False)
        self.assertEqual(rc, 0, out)
        shim = self.root / "ssh-shim"
        shim.write_text("#!/usr/bin/env python3\n" +
            "import os,subprocess,sys\nfrom pathlib import Path\n" +
            "assert 'BatchMode=yes' in sys.argv and 'StrictHostKeyChecking=yes' in sys.argv\n" +
            "nick=sys.argv[-2]\nhome=Path(os.environ['ROLE_TARGETS'])/nick\n" +
            "env=dict(os.environ,HOME=str(home),REMOTE_COMPUTE_ROOT=str(home/'.remote-compute'))\n" +
            "sys.exit(subprocess.call(['bash','-c',sys.argv[-1]],env=env))\n")
        shim.chmod(0o755)
        command = prefix / "bin/remote-compute"
        result = subprocess.run([str(command), "run", "--role", "render", "work", "--job-id", "installed"],
            cwd=self.project, env=dict(os.environ, COMPUTE_SSH_BIN=str(shim), ROLE_TARGETS=str(self.root)),
            capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.wait_job("alpha", "installed")
        for args in (["help"], ["controller", "--help"]):
            result = subprocess.run([str(command), *args], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--role", result.stdout)


if __name__ == "__main__":
    unittest.main()
