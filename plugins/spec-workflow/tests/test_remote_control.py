"""AST-080: real adapter, helper and OpenSSH boundaries; no live target access."""
import base64
import copy
import fcntl
import getpass
import importlib.util
import json
import os
from pathlib import Path
import queue
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import venv
from unittest import mock

import yaml

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from assistant import adapters, capability_index as index, observability, tasks
from assistant import remote_control as client, remote_control_server as server

REPO = SCRIPTS.parents[2]
HELPER = REPO / "plugins/remote-compute/scripts/remote-capabilities/_shared/compute-state.py"
SERVER = SCRIPTS / "assistant/remote_control_server.py"
CLIENT = SCRIPTS / "assistant/remote_control.py"


def token(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")


def run(argv, **kwargs):
    return subprocess.run(list(map(str, argv)), capture_output=True, text=True,
                          timeout=15, **kwargs)


class Fixtures(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ast347-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = self.base / "compute"
        self.job = self.root / "jobs/demo"
        self.job.mkdir(parents=True)
        (self.job / "exitcode").write_text("0\n")
        (self.job / "job.log").write_text("synthetic job output\n")
        cap = self.root / "caps/demo"
        cap.mkdir(parents=True)
        (cap / ".installed.json").write_text(json.dumps({"description": "synthetic capability"}))
        self.paths = self.base / "keys with spaces"
        self.paths.mkdir()
        for name in ("inspect", "cancel", "known hosts"):
            (self.paths / name).write_text("fixture\n")
            (self.paths / name).chmod(0o600)
        self.policy = {"storm590x": {"host": "127.0.0.1", "port": 2222,
                       "user": getpass.getuser(), "knownHosts": str(self.paths / "known hosts"),
                       "keys": {c: str(self.paths / c) for c in ("inspect", "cancel")}}}

    def serve(self, op, job="", cls="inspect"):
        return server.execute(server.encode_request(op, job), cls, self.root, HELPER)

    def install(self):
        root = self.base / "assistant repo"
        root.mkdir()
        (root / ".neural-network").mkdir()
        (root / ".neural-network/project.yaml").write_text("assistant: {enabled: true}\n")
        skill = client.install(root)
        manifest = skill / "capability.yaml"
        data = yaml.safe_load(manifest.read_text())
        data["provisioning"]["hosts"] = self.policy
        manifest.write_text(yaml.safe_dump(data))
        return root, skill, manifest

    def test_wire_exact_schema_and_class_matrix(self):
        for cls in ("inspect", "cancel"):
            for op in ("inventory", "status", "logs", "cancel"):
                request = server.encode_request(op, "" if op == "inventory" else "demo")
                allowed = (cls == "cancel") == (op == "cancel")
                if allowed:
                    self.assertEqual(server.decode_request(request, cls)["operation"], op)
                else:
                    with self.assertRaisesRegex(server.Refusal, "class"):
                        server.decode_request(request, cls)
        bad = ["", "sh", "sftp", "scp -t /tmp", "x;y", "a\nb", "a b", "A" * 5000,
               token([]), token({}), token({"version": True, "operation": "inventory"}),
               token({"version": 2, "operation": "inventory"}),
               token({"version": 1, "operation": "launch", "cmd": "id"}),
               token({"version": 1, "operation": "inventory", "job_id": "demo"}),
               token({"version": 1, "operation": "status"}),
               token({"version": 1, "operation": "status", "job_id": "../escape"}),
               token({"version": 1, "operation": "cancel", "job_id": "demo", "class": "cancel"}),
               base64.urlsafe_b64encode(b'{"version":1,"version":1,"operation":"inventory"}').decode().rstrip("=")]
        for request in bad:
            with self.subTest(request=request[:100]), mock.patch.object(server, "bounded_run") as spawn:
                with self.assertRaises(server.Refusal):
                    server.execute(request, "inspect", self.root, HELPER)
                spawn.assert_not_called()

    def test_positive_helper_and_bounded_logs(self):
        self.assertEqual(self.serve("inventory")["data"]["capabilities"]["demo"]["description"], "synthetic capability")
        self.assertEqual(self.serve("status", "demo")["data"]["state"], "done")
        self.assertEqual(self.serve("logs", "demo")["data"]["text"], "synthetic job output\n")
        (self.job / "job.log").write_bytes(b"x" * 100000 + b"END")
        result = self.serve("logs", "demo")["data"]
        self.assertTrue(result["truncated"])
        self.assertLessEqual(len(result["text"]), 65536)
        self.assertTrue(result["text"].endswith("END"))

    def test_server_direct_isolated_entrypoint_and_untrusted_pythonpath(self):
        (self.base / "json.py").write_text("raise RuntimeError('ambient import executed')\n")
        env = dict(os.environ, PYTHONPATH=str(self.base), SSH_ORIGINAL_COMMAND=server.encode_request("status", "demo"))
        args = [sys.executable, "-I", SERVER, "--class", "inspect", "--root", self.root, "--helper", HELPER]
        ok = run(args, cwd=self.base, env=env)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertEqual(json.loads(ok.stdout)["data"]["state"], "done")
        for request in ("touch sentinel", server.encode_request("cancel", "demo"), token({"version": 1, "operation": "inventory", "exec": "id"})):
            result = run(args, env=dict(env, SSH_ORIGINAL_COMMAND=request), cwd=self.base)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refused", result.stderr.lower())
            self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertFalse((self.base / "sentinel").exists())

    def test_filesystem_refusals_before_helper(self):
        outside = self.base / "secret"
        outside.write_text("do not disclose")
        for relative, op in (("jobs/demo/job.log", "logs"), ("jobs/demo/job.log", "cancel"),
                             ("jobs/demo/record.json", "status"), ("jobs/demo/exitcode", "status"),
                             ("state.json", "cancel"), (".state.lock", "inventory"),
                             ("caps/demo/.installed.json", "inventory")):
            path = self.root / relative
            original = path.read_bytes() if path.exists() else None
            path.unlink(missing_ok=True)
            path.symlink_to(outside)
            with self.subTest(relative=relative, op=op), mock.patch.object(server, "bounded_run") as spawn:
                with self.assertRaises(server.Refusal):
                    self.serve(op, "" if op == "inventory" else "demo", "cancel" if op == "cancel" else "inspect")
                spawn.assert_not_called()
            path.unlink()
            if original is not None:
                path.write_bytes(original)
        (self.job / "job.log").unlink()
        os.mkfifo(self.job / "job.log")
        with self.assertRaises(server.Refusal):
            self.serve("logs", "demo")
        link = self.root / "jobs/link"
        link.symlink_to(self.job, target_is_directory=True)
        with self.assertRaises(server.Refusal):
            self.serve("status", "link")
        with self.assertRaises(server.Refusal):
            server.execute(server.encode_request("inventory"), "inspect", Path("relative"), HELPER)

    def live_job(self):
        child = subprocess.Popen(["/bin/sleep", "60"], start_new_session=True)
        def cleanup():
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=5)
        self.addCleanup(cleanup)
        spec = importlib.util.spec_from_file_location("compute_fixture", HELPER)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        (self.job / "exitcode").unlink(missing_ok=True)
        (self.job / "pid").write_text(str(child.pid))
        (self.job / "record.json").write_text(json.dumps({"phase": "running", "pid": child.pid,
              "processIdentity": helper.process_identity(child.pid), "processGroup": child.pid}))
        return child

    def test_cancel_positive_effect_and_fingerprint_refusal(self):
        child = self.live_job()
        path = self.job / "record.json"
        record = json.loads(path.read_text())
        path.write_text(json.dumps(dict(record, processIdentity="forged")))
        with self.assertRaises(server.Refusal):
            self.serve("cancel", "demo", "cancel")
        self.assertIsNone(child.poll())
        path.write_text(json.dumps(record))
        self.assertTrue(self.serve("cancel", "demo", "cancel")["data"]["cancelled"])
        self.assertEqual(child.wait(timeout=5), -signal.SIGTERM)
        self.assertEqual((self.job / "exitcode").read_text().strip(), "143")

    def test_subprocess_deadline_and_output_bound(self):
        start = time.monotonic()
        with self.assertRaisesRegex(server.Refusal, "timeout"):
            server.bounded_run([sys.executable, "-c", "import time; time.sleep(30)"], timeout=.1)
        self.assertLess(time.monotonic() - start, 3)
        with self.assertRaisesRegex(server.Refusal, "output"):
            server.bounded_run([sys.executable, "-c", "print('x'*200000)"], timeout=3)

    def test_locked_helper_is_bounded_without_effect(self):
        with (self.root / ".state.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with mock.patch.object(server, "HELPER_TIMEOUT", .15):
                with self.assertRaisesRegex(server.Refusal, "timeout"):
                    self.serve("inventory")
            self.assertFalse((self.root / "state.json").exists())

    def test_template_is_valid_and_install_cannot_follow_linked_parent(self):
        cap = index.load_capability(SCRIPTS.parent / "skills/remote-compute-control")
        self.assertIsInstance(cap, index.Capability)
        self.assertNotEqual(run(cap.provisioning["check"]).returncode, 0)
        root = self.base / "linked assistant"
        root.mkdir()
        outside = self.base / "outside"
        outside.mkdir()
        (root / ".claude").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(client.Refusal):
            client.install(root)
        self.assertEqual(list(outside.iterdir()), [])

    def test_policy_and_parameters_refuse_before_ssh(self):
        _, _, manifest = self.install()
        invalid_calls = [("unknown", "inventory", ""), ("-oProxyCommand=id", "inventory", ""),
                         ("storm590x", "exec", ""), ("storm590x", "status", ""),
                         ("storm590x", "inventory", "demo"), ("storm590x", "logs", "x\ny"),
                         ("storm590x", "cancel", "../x")]
        for args in invalid_calls:
            with self.subTest(args=args), mock.patch.object(client, "bounded_run") as spawn:
                with self.assertRaises(client.Refusal):
                    client.invoke(manifest, *args)
                spawn.assert_not_called()
        changes = [("host", "-option"), ("host", "host\nProxyCommand id"), ("host", "host;id"),
                   ("user", "-root"), ("port", True), ("port", 0), ("port", 65536),
                   ("knownHosts", "relative"), ("knownHosts", "/tmp/%h"),
                   ("knownHosts", "/tmp/$HOME"), ("knownHosts", "/tmp/a\nb")]
        for field, value in changes:
            policy = copy.deepcopy(self.policy)
            policy["storm590x"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(client.Refusal):
                client.build_ssh_argv(policy, "storm590x", "inventory")
        policy = copy.deepcopy(self.policy)
        policy["storm590x"]["keys"]["cancel"] = policy["storm590x"]["keys"]["inspect"]
        with self.assertRaises(client.Refusal):
            client.build_ssh_argv(policy, "storm590x", "inventory")
        (self.paths / "inspect").unlink()
        with mock.patch.object(client, "bounded_run") as spawn, self.assertRaises(client.Refusal):
            client.invoke(manifest, "storm590x", "inventory")
        spawn.assert_not_called()

    def test_real_ssh_config_spaces_ambient_isolation_and_key_disappearance(self):
        ambient = self.base / "ambient"
        (ambient / ".ssh").mkdir(parents=True)
        (ambient / ".ssh/config").write_text("Host *\n  IdentityFile /hostile/key\n  ProxyCommand touch HOSTILE\n  StrictHostKeyChecking no\n")
        env = dict(os.environ, HOME=str(ambient), SSH_AUTH_SOCK="/hostile/agent")
        argv = client.build_ssh_argv(self.policy, "storm590x", "status", "demo")
        for disappear in (False, True):
            if disappear:
                (self.paths / "inspect").unlink()
            self.assertEqual(argv[argv.index("-F") + 1], "/dev/null")
            result = run([argv[0], "-G", "-F", str(ambient / ".ssh/config"), *argv[1:]], env=env, cwd=ambient)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            values = dict(line.split(" ", 1) for line in lines)
            identities = [line[13:] for line in lines if line.startswith("identityfile ")]
            self.assertTrue(set(identities) <= {"none", str(self.paths / "inspect")}, identities)
            self.assertTrue(identities)
            for key, expected in {"identityagent": "none", "certificatefile": "none",
                 "identitiesonly": "yes", "stricthostkeychecking": "true", "batchmode": "yes",
                 "passwordauthentication": "no", "kbdinteractiveauthentication": "no",
                 "forwardagent": "no", "forwardx11": "no", "requesttty": "false",
                 "controlmaster": "false", "permitlocalcommand": "no", "stdinnull": "yes"}.items():
                self.assertEqual(values[key], expected, (key, values[key]))
            self.assertEqual(values["userknownhostsfile"], str(self.paths / "known hosts"))
            self.assertNotIn("-cert-", values["pubkeyacceptedalgorithms"])
            self.assertNotIn("proxycommand", values)
            self.assertFalse((ambient / "HOSTILE").exists())

    def test_data_only_install_real_adapter_and_current_policy(self):
        root, skill, manifest = self.install()
        self.assertEqual({p.name for p in skill.iterdir()}, {"SKILL.md", "capability.yaml"})
        self.assertEqual((root / ".neural-network/project.yaml").read_text(), "assistant: {enabled: true}\n")
        before = manifest.read_bytes()
        with self.assertRaises(client.Refusal):
            client.install(root)
        self.assertEqual(manifest.read_bytes(), before)
        cap = index.load_capability(skill)
        self.assertIsInstance(cap, index.Capability)
        self.assertTrue(cap.long_running)
        self.assertEqual(cap.invoke["exec"][:3], [os.path.abspath(sys.executable), "-I", str(CLIENT)])
        self.assertIn(str(manifest), cap.invoke["exec"])
        check = run(cap.provisioning["check"], cwd="/")
        self.assertEqual(check.returncode, 0, check.stderr)
        cfg = {"capabilities": {"remote-compute-control": {"enabled": True}}}
        disabled = index.compile_index(skill.parent, {"capabilities": {}}, embed_fn=lambda _: None)
        self.assertFalse(disabled.entries)
        with mock.patch.object(adapters, "invoke_cli") as spawn, self.assertRaises(index.CapabilityDisabledError):
            index.invoke_capability(skill.name, cap, {}, {}, cwd="/")
        spawn.assert_not_called()
        params = {"host": "unknown", "operation": "inventory", "job_id": ""}
        result = index.invoke_capability(skill.name, cap, params, cfg, cwd="/")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("allowlist", result.stderr)
        for params in ({"host": "storm590x", "operation": "inventory"},
                       {"host": "storm590x", "operation": "exec", "job_id": ""},
                       {"host": "storm590x", "operation": "inventory", "job_id": "", "key": "evil"}):
            with self.assertRaises(adapters.ParamValidationError):
                index.invoke_capability(skill.name, cap, params, cfg, cwd="/")
        data = yaml.safe_load(manifest.read_text())
        data["provisioning"]["hosts"] = {}
        manifest.write_text(yaml.safe_dump(data))
        result = index.invoke_capability(skill.name, cap, {"host": "storm590x", "operation": "inventory", "job_id": ""}, cfg, cwd="/")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("allowlist", result.stderr)

    def test_cli_install_preserves_symlink_venv_interpreter(self):
        environment = self.base / "python environment"
        venv.EnvBuilder(with_pip=False, system_site_packages=True, symlinks=True).create(environment)
        python = environment / "bin/python3"
        self.assertTrue(python.is_symlink())
        assistant = self.base / "venv assistant"
        assistant.mkdir()
        result = run([python, "-I", CLIENT, "install", "--assistant-root", assistant], cwd="/")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = assistant / ".claude/skills/remote-compute-control/capability.yaml"
        data = yaml.safe_load(manifest.read_text())
        for argv in (data["invoke"]["exec"], data["provisioning"]["check"]):
            with self.subTest(argv=argv):
                probe = run([argv[0], "-I", "-c", "import sys; print(sys.prefix)"], cwd="/")
                self.assertEqual(probe.returncode, 0, probe.stderr)
                self.assertEqual(probe.stdout.strip(), str(environment))
                self.assertEqual(argv[:3], [str(python), "-I", str(CLIENT.resolve())])
        data["provisioning"]["hosts"] = self.policy
        manifest.write_text(yaml.safe_dump(data))
        result = run(data["provisioning"]["check"], cwd="/")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cli_install_refuses_braced_bindings_before_writes(self):
        for binding in ("manifest", "interpreter", "engine"):
            for number, segment in enumerate(("{host}", "{skill_dir}", "{unknown}", "{", "}", "ordinary space")):
                with self.subTest(binding=binding, segment=segment):
                    fixture = self.base / f"binding-{binding}-{number}"
                    fixture.mkdir()
                    assistant = fixture / ("assistant-" + segment if binding == "manifest" else "assistant")
                    assistant.mkdir()
                    python, engine = Path(sys.executable), CLIENT
                    if binding == "interpreter":
                        environment = fixture / ("python-" + segment)
                        venv.EnvBuilder(with_pip=False, system_site_packages=True, symlinks=True).create(environment)
                        python = environment / "bin/python3"
                        self.assertTrue(python.is_symlink())
                    elif binding == "engine":
                        plugin = fixture / ("plugin-" + segment)
                        for relative in ("scripts/assistant/remote_control.py", "scripts/assistant/remote_control_server.py",
                                         "skills/remote-compute-control/SKILL.md", "skills/remote-compute-control/capability.yaml"):
                            target = plugin / relative
                            target.parent.mkdir(parents=True, exist_ok=True)
                            shutil.copyfile(SCRIPTS.parent / relative, target)
                        engine = plugin / "scripts/assistant/remote_control.py"
                    result = run([python, "-I", engine, "install", "--assistant-root", assistant], cwd="/")
                    if "{" in segment or "}" in segment:
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        self.assertIn(binding, result.stderr.lower())
                        self.assertIn("without braces", result.stderr.lower())
                        self.assertEqual(list(assistant.iterdir()), [], "refusal must precede all installer writes")
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        manifest = assistant / ".claude/skills/remote-compute-control/capability.yaml"
                        data = yaml.safe_load(manifest.read_text())
                        for argv in (data["invoke"]["exec"], data["provisioning"]["check"]):
                            self.assertEqual(argv[:3], [os.path.abspath(python), "-I", str(engine.resolve())])
                            self.assertIn(str(manifest), argv)
                        data["provisioning"]["hosts"] = self.policy
                        manifest.write_text(yaml.safe_dump(data))
                        check = run(data["provisioning"]["check"], cwd="/")
                        self.assertEqual(check.returncode, 0, check.stderr)


@unittest.skipUnless(Path("/usr/sbin/sshd").exists(), "isolated sshd unavailable")
class RealSSH(Fixtures):
    def test_real_forced_commands(self):
        with tempfile.TemporaryDirectory(prefix=".ast347-test-", dir=Path.home()) as directory:
            home = Path(directory)
            for name in ("host", "inspect", "cancel", "stranger"):
                result = run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", home / name])
                self.assertEqual(result.returncode, 0, result.stderr)
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            authorized = []
            for cls in ("inspect", "cancel"):
                command = f"{Path(sys.executable).resolve()} -I {SERVER} --class {cls} --root {self.root} --helper {HELPER}"
                authorized.append(f'restrict,command="{command}" ' + (home / (cls + ".pub")).read_text().strip())
            (home / "authorized_keys").write_text("\n".join(authorized) + "\n")
            (home / "sshd_config").write_text("\n".join([
                f"Port {port}", "ListenAddress 127.0.0.1", f"HostKey {home / 'host'}",
                f"PidFile {home / 'pid'}", f"AuthorizedKeysFile {home / 'authorized_keys'}",
                "StrictModes yes", "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no",
                "PermitRootLogin no", "PermitUserEnvironment no", "PermitUserRC no",
                "AllowTcpForwarding yes", "AllowAgentForwarding yes", "X11Forwarding yes",
                "Subsystem sftp internal-sftp",
                f"AllowUsers {getpass.getuser()}", "LogLevel VERBOSE", ""]))
            pub = (home / "host.pub").read_text().split()
            (self.paths / "known hosts").write_text(f"[127.0.0.1]:{port} {pub[0]} {pub[1]}\n")
            for cls in ("inspect", "cancel"):
                (self.paths / cls).write_bytes((home / cls).read_bytes())
            self.policy["storm590x"]["port"] = port
            with (home / "sshd.log").open("wb") as log:
                daemon = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(home / "sshd_config")],
                                          stdout=log, stderr=log, start_new_session=True)
                try:
                    for _ in range(60):
                        self.assertIsNone(daemon.poll(), (home / "sshd.log").read_text())
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=.1):
                                break
                        except OSError:
                            time.sleep(.05)
                    assistant, skill, manifest = self.install()
                    cap = index.load_capability(skill)
                    cfg = {"capabilities": {skill.name: {"enabled": True}}}
                    for op in ("inventory", "status", "logs"):
                        result = index.invoke_capability(skill.name, cap, {"host": "storm590x", "operation": op,
                             "job_id": "" if op == "inventory" else "demo"}, cfg, cwd="/")
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertTrue(json.loads(result.stdout)["ok"])
                    queued = index.run_capability_invoke_task({"name": skill.name, "capability": cap._asdict(),
                        "params": {"host": "storm590x", "operation": "inventory", "job_id": ""},
                        "skill_dir": str(skill), "assistant_cfg": cfg, "timeout": 20}, lambda *a, **kw: None)
                    self.assertEqual(queued["result"]["returncode"], 0)
                    self.assertNotIn("artifact_path", queued)
                    # The direct library call above stays compatible. Managed
                    # work must instead cross the real task and trace writers.
                    from assistant import remote_audit
                    config = {"version": 1, "enabled": True, "names": ["fixture"],
                              "systemPrompt": "Local SSH fixture",
                              "llm": {"provider": "openai", "model": "fixture"},
                              "capabilities": {"codex": {"enabled": True}, **cfg["capabilities"]}}
                    (assistant / ".neural-network/project.yaml").write_text(yaml.safe_dump({"assistant": config}))
                    task_queue, traces = queue.Queue(), queue.Queue()
                    stop = threading.Event()
                    writer = threading.Thread(target=observability.run_writer,
                        kwargs={"q": traces, "stop_event": stop, "poll_timeout": .01})
                    worker = threading.Thread(target=tasks.run_worker,
                        kwargs={"q": task_queue, "stop_event": stop, "traces_queue": traces,
                                "poll_timeout": .01, "executors": {remote_audit.KIND: remote_audit.run_task}})
                    writer.start()
                    worker.start()
                    try:
                        task_id = tasks.enqueue(task_queue, str(assistant), index.KIND,
                            {"name": skill.name.upper(), "capability": cap._asdict(), "assistant_cfg": cfg,
                             "params": {"host": "storm590x", "operation": "inventory", "job_id": ""}},
                            turn_id="real-ssh-turn")
                        deadline = time.monotonic() + 10
                        row = None
                        while time.monotonic() < deadline:
                            row = next((item for item in tasks.list_tasks(str(assistant))
                                        if item["id"] == task_id and item["state"] in {"completed", "failed"}), None)
                            if row:
                                break
                            stop.wait(.01)
                        self.assertIsNotNone(row, "managed SSH task did not finish")
                        self.assertEqual(row["state"], "completed", row)
                        self.assertEqual(row["kind"], remote_audit.KIND)
                        self.assertEqual(row["result"]["capabilities"]["demo"]["description"], "synthetic capability")
                        self.assertNotIn("artifact_path", row["result"])
                        events = [event for event in observability.query(str(assistant))
                                  if event["kind"].startswith("remote.command.")]
                        self.assertEqual([event["status"] for event in events], ["intent", "success"])
                        self.assertEqual({event["turn_id"] for event in events}, {"real-ssh-turn"})
                        self.assertEqual({event["parent_span_id"] for event in events}, {task_id})
                    finally:
                        stop.set()
                        worker.join(6)
                        writer.join(6)
                        self.assertFalse(worker.is_alive())
                        self.assertFalse(writer.is_alive())
                    inspect = client.build_ssh_argv(self.policy, "storm590x", "inventory")
                    cancel = client.build_ssh_argv(self.policy, "storm590x", "cancel", "demo")
                    sentinel = home / "SHELL_EXECUTED"
                    for argv, request in ((inspect, f"touch {sentinel}"), (inspect, server.encode_request("cancel", "demo")),
                                          (cancel, server.encode_request("inventory")), (inspect, "sftp"),
                                          (inspect, token({"version": 1, "operation": "inventory", "extra": "x"}))):
                        result = run([*argv[:-1], request])
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        self.assertIn("refused", result.stderr.lower())
                    self.assertFalse(sentinel.exists())
                    result = run([inspect[0], "-s", *inspect[1:-1], "sftp"])
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(json.loads(result.stdout)["ok"])
                    attack = ["/usr/bin/ssh", "-F", "/dev/null", "-i", str(home / "inspect"),
                              "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                              "-o", "StrictHostKeyChecking=yes", "-o", f'UserKnownHostsFile="{self.paths / "known hosts"}"',
                              "-p", str(port), "-l", getpass.getuser(), "127.0.0.1"]
                    result = run([attack[0], "-tt", *attack[1:], server.encode_request("inventory")])
                    self.assertIn("pty allocation request failed", result.stderr.lower())
                    # -W requests direct-tcpip: this exercises the key/sshd restriction.
                    result = run([attack[0], "-W", "127.0.0.1:22", *attack[1:]])
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("administratively prohibited", result.stderr.lower())
                    child = self.live_job()
                    value = client.invoke(manifest, "storm590x", "cancel", "demo")
                    self.assertTrue(value["data"]["cancelled"])
                    child.wait(timeout=5)
                    # An unrelated key cannot use password/agent fallback.
                    (self.paths / "inspect").write_bytes((home / "stranger").read_bytes())
                    with self.assertRaises(client.Refusal):
                        client.invoke(manifest, "storm590x", "inventory")
                    (self.paths / "inspect").write_bytes((home / "inspect").read_bytes())
                    wrong_pub = (home / "stranger.pub").read_text().split()
                    (self.paths / "known hosts").write_text(f"[127.0.0.1]:{port} {wrong_pub[0]} {wrong_pub[1]}\n")
                    with self.assertRaisesRegex(client.Refusal, "HOST IDENTIFICATION HAS CHANGED|Host key verification failed"):
                        client.invoke(manifest, "storm590x", "inventory")
                    (self.paths / "known hosts").write_text("")
                    with self.assertRaises(client.Refusal):
                        client.invoke(manifest, "storm590x", "inventory")
                finally:
                    if daemon.poll() is None:
                        os.killpg(daemon.pid, signal.SIGTERM)
                    daemon.wait(timeout=10)


def load_tests(loader, tests, pattern):
    suite = loader.loadTestsFromTestCase(Fixtures)
    suite.addTest(RealSSH("test_real_forced_commands"))
    return suite


if __name__ == "__main__":
    unittest.main(verbosity=2)
