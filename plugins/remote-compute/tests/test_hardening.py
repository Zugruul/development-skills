"""Real local regressions for the controller and target protocol; no network."""
import contextlib
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
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
REPO = SCRIPTS.parents[2]
UPDATE_GUIDE = REPO / "docs/remote-compute-updates.md"


class InstalledUpdateTests(unittest.TestCase):
    """Exercise real installers with local transport and disposable user state."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home with spaces"
        self.home.mkdir()
        self.target = self.home / ".remote-compute"
        environment = dict(os.environ, HOME=str(self.home), COMPUTE_HOME=str(self.root / "client"),
                           REMOTE_COMPUTE_ROOT=str(self.target),
                           PATH=str(self.home / ".local/bin") + ":" + os.defpath)
        for key in ("REMOTE_COMPUTE_CONTROLLER", "REMOTE_COMPUTE_TOOLS", "BASH_ENV", "ENV"):
            environment.pop(key, None)
        self.environment = environment
        env_patch = patch.dict(os.environ, environment, clear=True)
        env_patch.start()
        self.addCleanup(env_patch.stop)
        c.save_registry({"schemaVersion": 1, "resources": {"fixture": {
            "envs": {"custom": {"activate": "true"}},
            "jobs": {"personal": {"cmd": "true", "workdir": "~"}},
            "policy": {"maxConcurrentJobs": 1}}}})
        self.seed(self.target, {
            ".identity": b"original-alias\n", ".machine-id": b"fixture-stable-id\n",
            "caps/comfyui/capability.yaml": b"name: comfyui\njobs:\n  original:\n    cmd: true\n",
            "caps/comfyui/custom.py": b"print('custom, never builtin')\n",
            "caps/comfyui/models/private.bin": b"\x00custom model\xff",
            "caps/comfyui/workflows/custom.json": b'{"nodes": []}\n',
            "caps/other/.installed.json": json.dumps({"manifest": {
                "name": "other", "jobs": {"check": {"cmd": "true"}}}, "files": {}}).encode(),
            "runtime/dataset.bin": b"\x00dataset\xff", "jobs/old/exitcode": b"0\n",
            "jobs/old/job.log": b"legacy log\n", "jobs/old/outputs/result.bin": b"artifact\x00"})

    def seed(self, root, files):
        for relative, content in files.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)

    def snapshot(self, root):
        return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}

    def guide(self):
        self.assertTrue(UPDATE_GUIDE.is_file(), "missing installed-update operational guide")
        return UPDATE_GUIDE.read_text(encoding="utf-8")

    def recipe(self, name, success=True, **variables):
        match = re.search(r"<!-- recipe: " + re.escape(name) + r" -->\s*```bash\n(.*?)\n```",
                          self.guide(), re.DOTALL)
        self.assertIsNotNone(match, "missing executable guide recipe: " + name)
        result = subprocess.run(["bash", "-eu", "-c", match.group(1)],
                                env=dict(self.environment, **{k: str(v) for k, v in variables.items()}),
                                cwd=self.root, capture_output=True, text=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def invoke(self, function, *args):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(function(*args), 0)

    def local_shell(self, nick, payload, **kwargs):
        self.assertEqual(nick, "fixture")
        result = subprocess.run(["bash", "-c", payload], env=self.environment,
                                capture_output=True, text=True, timeout=30)
        return result.returncode, result.stdout, result.stderr

    def local_rsync(self, *args):
        # Replace only the transport address; staging and publish run unchanged.
        self.assertTrue(args[-1].startswith("fixture:"), args)
        return ["rsync", "-a", *args[:-1], str(self.home / args[-1].split(":", 1)[1]) + "/"]

    def transport(self):
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(c, "ssh_run", side_effect=self.local_shell))
        stack.enter_context(patch.object(c, "rsync_argv", side_effect=self.local_rsync))
        return stack

    def test_guide_is_reachable_from_every_operational_entry(self):
        for relative in ("README.md", "AGENTS.md", "docs/remote-compute.md",
                         "plugins/remote-compute/README.md",
                         "plugins/remote-compute/skills/remote-compute/SKILL.md"):
            path = REPO / relative
            links = re.findall(r"\]\(([^)#]+)(?:#[^)]*)?\)", path.read_text(encoding="utf-8"))
            with self.subTest(entry=relative):
                self.assertTrue(any((path.parent / link).resolve() == UPDATE_GUIDE
                                    for link in links if "://" not in link), "missing update-guide link")

    def test_guide_distinguishes_layers_and_custom_recovery(self):
        guide = self.guide()
        for heading in ("Source and active host", "Standalone controller", "Target tools",
                        "Legacy custom catalogs", "Recovery", "Verification evidence"):
            self.assertIn("## " + heading, guide)
        for command in ("codex plugin marketplace list", "codex plugin marketplace upgrade development-skills",
                        "claude plugin update remote-compute@development-skills", "install-cli",
                        "install-tools", "capabilities sync", "doctor"):
            self.assertIn(command, guide)
        for source in ("https://developers.openai.com/plugins/build/plugins",
                       "https://code.claude.com/docs/en/discover-plugins"):
            self.assertIn(source, guide)
        for concept in ("payload", "runtime", "backup", "rollback", "COMPUTE_HOME", "0.1.0",
                        "PowerShell", "profile", "active skill path", "marketplace is absent",
                        "preservePaths", "b0d84d3", "local repository", "older controllers"):
            self.assertIn(concept, guide)

    def test_packaged_entry_points_have_a_published_guide_fallback(self):
        package = self.root / "plugin-cache/remote-compute/version"
        shutil.copytree(SCRIPTS.parent, package, ignore=shutil.ignore_patterns("__pycache__"))
        published = "https://github.com/Zugruul/development-skills/blob/main/docs/remote-compute-updates.md"
        self.assertFalse((package / "../../docs/remote-compute-updates.md").resolve().exists())
        for relative in ("README.md", "skills/remote-compute/SKILL.md"):
            with self.subTest(entry=relative):
                links = re.findall(r"\]\(([^)]+)\)", (package / relative).read_text(encoding="utf-8"))
                self.assertIn(published, links)

    def test_documented_controller_upgrade_repeats_without_touching_state(self):
        prefix = self.root / "prefix with spaces"
        before_target = self.snapshot(self.target)
        before_client = self.snapshot(Path(c.compute_home()))
        variables = dict(REVIEWED_SOURCE=SCRIPTS.parent, UPDATE_PREFIX=prefix)
        self.recipe("install-controller", **variables)
        installed = prefix / "share/remote-compute"
        (installed / "obsolete-fixture").write_text("must be replaced")
        (installed / "remote-compute.py").write_text("raise SystemExit('stale controller')\n")
        for _ in range(2):
            self.recipe("install-controller", **variables)
            self.assertEqual((installed / "remote-compute.py").read_bytes(),
                             (SCRIPTS / "remote-compute.py").read_bytes())
            self.assertFalse((installed / "obsolete-fixture").exists())
            for arguments in (["version"], ["controller", "version"], ["local", "status", "old"],
                              ["caps"], ["capabilities"], ["capabilities", "fixture"], ["jobs", "fixture"]):
                result = subprocess.run([str(prefix / "bin/remote-compute"), *arguments],
                                        env=self.environment, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(self.target), before_target)
        self.assertEqual(self.snapshot(Path(c.compute_home())), before_client)

    def test_target_tool_updates_preserve_custom_payloads_history_and_identity(self):
        protected = self.snapshot(self.target)
        registry = c.load_registry()["resources"]["fixture"]
        shared_source = self.root / "shared CRLF source"
        shutil.copytree(SHARED, shared_source, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        for script in shared_source.rglob("*.sh"):
            script.write_bytes(script.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
        source_before = self.snapshot(shared_source)
        self.assertTrue(any(b"\r\n" in data for name, data in source_before.items() if name.endswith(".sh")))
        with self.transport(), patch.object(c, "SHARED_TOOLS_DIR", str(shared_source)):
            for _ in range(2):
                self.invoke(c.cmd_install_tools, "fixture")
                self.assertEqual(self.snapshot(self.target / "tools"), {
                    name: data.replace(b"\r\n", b"\n") if name.endswith(".sh") else data
                    for name, data in source_before.items()})
                self.assertEqual(self.snapshot(shared_source), source_before)
                for relative, content in protected.items():
                    self.assertEqual((self.target / relative).read_bytes(), content, relative)
                current = c.get_resource("fixture")
                for key in ("envs", "jobs", "policy"):
                    self.assertEqual(current[key], registry[key])
                self.assertEqual(current["machineId"], "fixture-stable-id")
                for relative in (".profile", ".bashrc", ".zshenv"):
                    self.assertEqual((self.home / relative).read_text().count(c.PATH_MARKER), 1)
                self.assertEqual((self.target / "controller/remote-compute.py").read_bytes(),
                                 (SCRIPTS / "remote-compute.py").read_bytes())
                result = subprocess.run([str(self.home / ".local/bin/remote-compute"), "version"],
                                        capture_output=True, text=True, env=self.environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(c.VERSION, result.stdout)
        self.assertFalse((self.target / "caps/comfyui/.installed.json").exists())

    def test_backup_and_restore_reject_unsafe_paths_before_writing(self):
        backup = self.root / "good-backup"
        self.recipe("backup-state", UPDATE_STATE_ROOT=self.target, UPDATE_BACKUP_DIR=backup)
        through_link = self.root / "link-to-state"
        through_link.symlink_to(self.target, target_is_directory=True)
        broken = self.root / "broken"
        broken.symlink_to(self.root / "absent")
        existing = self.root / "existing"
        existing.mkdir()
        for recipe in ("backup-state", "restore-staging"):
            for destination in (Path(recipe + "-relative"), self.target / (recipe + "-nested"),
                                through_link / (recipe + "-linked"), broken, existing):
                with self.subTest(recipe=recipe, destination=str(destination)):
                    before = self.snapshot(self.target)
                    variables = dict(UPDATE_STATE_ROOT=self.target)
                    if recipe == "backup-state":
                        variables["UPDATE_BACKUP_DIR"] = destination
                    else:
                        variables.update(UPDATE_BACKUP_DIR=backup, UPDATE_RESTORE_DIR=destination)
                    self.recipe(recipe, success=False, **variables)
                    self.assertEqual(self.snapshot(self.target), before)
                    if destination not in (broken, existing):
                        self.assertFalse((self.root / destination).exists())
        with self.subTest(relative_source=True):
            self.recipe("backup-state", success=False, UPDATE_STATE_ROOT=self.target.relative_to(self.root),
                        UPDATE_BACKUP_DIR=self.root / "relative-source-backup")
            self.assertFalse((self.root / "relative-source-backup").exists())
        with self.subTest(relative_archive=True):
            self.recipe("restore-staging", success=False, UPDATE_STATE_ROOT=self.target,
                        UPDATE_BACKUP_DIR=backup.relative_to(self.root), UPDATE_RESTORE_DIR=self.root / "bad-restore")
            self.assertFalse((self.root / "bad-restore").exists())

    def test_reviewed_local_repository_preserves_declared_runtime_on_reinstall(self):
        repository = self.root / "reviewed repository"
        bundle = repository / "bundles/comfyui"
        bundle.mkdir(parents=True)
        manifest = {"name": "comfyui", "payload": ["custom.py", "workflows"],
                    "preservePaths": ["models", "runtime"],
                    "jobs": {"original": {"cmd": "python3 {capdir}/custom.py", "env": "custom"}}}
        (bundle / "capability.yaml").write_text(yaml.safe_dump(manifest))
        shutil.copytree(self.target / "caps/comfyui/workflows", bundle / "workflows")
        model = self.target / "caps/comfyui/models/private.bin"
        model_bytes, model_inode = model.read_bytes(), model.stat().st_ino
        launcher = self.target / "caps/comfyui/runtime/venv/bin/custom-tool"
        self.seed(self.target, {str(launcher.relative_to(self.target)):
                  ("#!" + str(launcher.parent / "python") + "\n# fixture\n").encode()})
        launcher.chmod(0o755)
        launcher_bytes, launcher_inode = launcher.read_bytes(), launcher.stat().st_ino
        with self.transport():
            for revision in ("first", "second"):
                (bundle / "custom.py").write_text("print(%r)\n" % revision)
                self.invoke(c.cmd_capability_cli, ["install", "fixture", str(repository), "comfyui"])
                self.assertEqual(model.read_bytes(), model_bytes)
                self.assertEqual(model.stat().st_ino, model_inode)
                self.assertEqual(launcher.read_bytes(), launcher_bytes)
                self.assertEqual(launcher.stat().st_ino, launcher_inode)
                self.assertEqual(launcher.stat().st_mode & 0o777, 0o755)
                self.assertEqual((self.target / "caps/comfyui/custom.py").read_bytes(),
                                 (bundle / "custom.py").read_bytes())
                published = json.loads((self.target / "caps/comfyui/.installed.json").read_text())
                self.assertEqual(published["manifest"], manifest)
                self.assertEqual(published["source"]["kind"], "local-directory")
                self.assertEqual(published["source"]["bundle"], "bundles/comfyui")
                self.assertFalse(any(path.startswith(("models/", "runtime/")) for path in published["files"]))
            self.invoke(c.cmd_capability_sync, "fixture")
            self.assertEqual(c.get_resource("fixture")["envs"]["custom"], {"activate": "true"})
            self.assertEqual(set(c.get_resource("fixture")["jobs"]),
                             {"personal", "comfyui:original", "other:check"})
            self.assertEqual(c.get_resource("fixture")["jobs"]["comfyui:original"]["cmd"],
                             manifest["jobs"]["original"]["cmd"])
            self.assertEqual((self.target / "jobs/old/job.log").read_bytes(), b"legacy log\n")

    def test_custom_publish_backup_and_staged_recovery_preserve_complete_state(self):
        original = self.root / "reviewed custom source"
        shutil.copytree(self.target / "caps/comfyui", original)
        # A reviewed payload includes workflows; mutable models stay outside caps.
        manifest = {"name": "comfyui", "payload": ["custom.py", "workflows"],
                    "jobs": {"original": {"cmd": "python3 {capdir}/custom.py", "env": "custom"}}}
        (original / "capability.yaml").write_text(yaml.safe_dump(manifest))
        registry_before = Path(c.registry_path()).read_bytes()
        client_before = self.snapshot(Path(c.compute_home()))
        target_before = self.snapshot(self.target)
        backup = self.root / "backup"
        for label, state in (("target", self.target), ("client", Path(c.compute_home())), ("source", original)):
            self.recipe("backup-state", UPDATE_STATE_ROOT=state, UPDATE_BACKUP_DIR=backup / label)
        shutil.copytree(self.target / "caps/comfyui/models", self.target / "runtime/comfyui/models")
        with self.transport():
            # Exercise the legacy install alias, actual staging and publication.
            self.invoke(c.main, ["install-capability", "fixture", str(original)])
            self.assertFalse((self.target / "caps/comfyui/models").exists())
            self.assertEqual((self.target / "runtime/comfyui/models/private.bin").read_bytes(),
                             target_before["caps/comfyui/models/private.bin"])
            self.assertEqual((self.target / "caps/comfyui/custom.py").read_bytes(),
                             target_before["caps/comfyui/custom.py"])
            published = json.loads((self.target / "caps/comfyui/.installed.json").read_text())
            self.assertEqual(published["manifest"], manifest)
            self.assertIn("workflows/custom.json", published["files"])
            self.invoke(c.cmd_capability_sync, "fixture")
            self.assertEqual(c.get_resource("fixture")["envs"]["custom"], {"activate": "true"})
            self.assertEqual(set(c.get_resource("fixture")["jobs"]),
                             {"personal", "comfyui:original", "other:check"})
        for label, expected in (("target", target_before), ("source", self.snapshot(original)),
                                ("client", client_before)):
            restore = self.root / ("restore-" + label)
            state = {"target": self.target, "client": Path(c.compute_home()), "source": original}[label]
            self.recipe("restore-staging", UPDATE_BACKUP_DIR=backup / label, UPDATE_RESTORE_DIR=restore,
                        UPDATE_STATE_ROOT=state)
            self.assertEqual(self.snapshot(restore), expected)
        self.assertEqual((self.root / "restore-client/resources.yaml").read_bytes(), registry_before)
        # Recovered target + client snapshots can be inspected without publishing.
        with patch.dict(os.environ, COMPUTE_HOME=str(self.root / "restore-client")):
            self.assertEqual(c.get_resource("fixture")["jobs"], {"personal": {"cmd": "true", "workdir": "~"}})


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
        target = self.root / "local-target"
        job = target / "jobs/waiting"
        job.mkdir(parents=True)
        (job / "record.json").write_text(json.dumps({"phase": "reserved", "expires": time.time() + 60}))
        result = subprocess.run([str(command), "local", "status", "waiting"], env=dict(os.environ, REMOTE_COMPUTE_ROOT=str(target)), text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("state:     reserved", result.stdout)

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

    def test_malformed_launch_reply_retains_recovery_receipt(self):
        def rpc(nick, action, request):
            if action == "launch":
                return 1, {"error": "bad response", "ambiguous": True}
            return 0, {"reserved": True}
        with patch.object(c, "remote_state", side_effect=rpc):
            self.assertNotEqual(self.invoke(c.cmd_dispatch, ["gpu", "--workdir", "~", "--cmd", "true", "--job-id", "uncertain"]), 0)
        self.assertEqual(c.load_job("uncertain")["phase"], "unknown")
        self.assertNotIn("finishedAt", c.load_job("uncertain"))

    def test_github_install_records_resolved_commit_for_every_bundle(self):
        def git(argv, **kwargs):
            if "clone" in argv:
                for name in ("one", "two"):
                    directory = Path(argv[-1], name)
                    directory.mkdir(parents=True)
                    (directory / "capability.yaml").write_text(yaml.safe_dump({"name": name, "jobs": {"run": {"cmd": "true"}}}))
            return subprocess.CompletedProcess(argv, 0, "a" * 40 if "rev-parse" in argv else "", "")
        with patch.object(c.subprocess, "run", side_effect=git), patch.object(c, "cmd_install_capability", return_value=0) as install:
            self.assertEqual(self.invoke(c.cmd_github_install, ["gpu", "https://github.com/o/r", "--all", "--ref", "v1"]), 0)
        self.assertEqual(install.call_count, 2)
        for call in install.call_args_list:
            self.assertEqual(call.kwargs["provenance"]["commit"], "a" * 40)

    def test_automatic_named_job_retries_have_distinct_ids(self):
        reg = c.load_registry()
        reg["resources"]["gpu"]["jobs"]["named"] = {"cmd": "true", "workdir": "~", "jobIdSchema": {"template": "artifact"}}
        c.save_registry(reg)
        with patch.object(c, "_launch_job", side_effect=lambda *args: args[-1]["--job-id"]):
            first = c.cmd_run(["gpu", "named"])
            second = c.cmd_run(["gpu", "named"])
        self.assertNotEqual(first, second)
        self.assertTrue(first.startswith("artifact-"))

    def test_revoked_host_keys_are_not_discovery_trust(self):
        known = self.root / "known_hosts"
        known.write_text("@revoked example.invalid ssh-ed25519 REVOKED\nexample.invalid ssh-ed25519 TRUSTED\n")
        with patch.object(c, "known_hosts_path", return_value=str(known)):
            self.assertEqual(c._known_host_keys("example.invalid"), {("ssh-ed25519", "TRUSTED")})

    def test_cli_rejects_misspelled_mutation_options_without_network(self):
        for arguments in (["register", "gpu", "test@example.invalid", "--accept-hostkeys"],
                          ["lock", "gpu", "--reasn", "test"],
                          ["unlock", "gpu", "--fore"], ["enable", "gpu", "--rot", "/tmp"],
                          ["remove-capability", "gpu", "demo", "--purge-remot"]):
            with self.subTest(arguments=arguments), patch.object(c, "ssh_run") as ssh:
                self.assertEqual(self.invoke(c.main, arguments), 2)
                ssh.assert_not_called()

    def test_controller_dispatch_recovers_real_target_exit_code(self):
        target = self.root / "target"
        target.mkdir()
        environment = dict(os.environ, REMOTE_COMPUTE_ROOT=str(target / ".remote-compute"), HOME=str(target))
        def ssh(nick, payload, **kwargs):
            result = subprocess.run(["bash", "-c", payload], env=environment, capture_output=True, text=True, timeout=15)
            return result.returncode, result.stdout, result.stderr
        with patch.object(c, "ssh_run", side_effect=ssh):
            self.assertEqual(self.invoke(c.cmd_dispatch, ["gpu", "--workdir", str(target), "--cmd", "printf 'hello'; exit 7", "--job-id", "real"]), 0)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if (target / ".remote-compute/jobs/real/exitcode").exists():
                    break
                time.sleep(0.05)
            self.invoke(c.cmd_job_status, "real")
        self.assertIn("finishedAt", c.load_job("real"))
        self.assertEqual((target / ".remote-compute/jobs/real/exitcode").read_text().strip(), "7")
        self.assertEqual((target / ".remote-compute/jobs/real/job.log").read_text(), "hello")

    def test_add_job_rejects_invalid_parameter_patterns(self):
        for parameter in ("value:[", "jobdir:.*"):
            self.assertEqual(self.invoke(c.cmd_add_job, ["gpu", "bad", "--workdir", "~", "--cmd", "echo {value}", "--param", parameter]), 2)
        self.assertNotIn("bad", c.get_resource("gpu")["jobs"])


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

    def test_real_launch_captures_activation_failure_and_is_idempotent(self):
        request = {"id": "activate-fails", "token": "token", "limit": 1}
        self.assertEqual(self.rpc("reserve", request)[0], 0)
        request.update(workdir=str(self.root), cmd="touch SHOULD_NOT_EXIST; touch ALSO_MUST_NOT_EXIST", activate="false")
        first = self.rpc("launch", request)
        self.assertEqual(first[0], 0, first)
        self.assertEqual(self.rpc("launch", request)[0], 0)
        deadline = time.monotonic() + 5
        while not (self.root / "jobs/activate-fails/exitcode").exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(self.rpc("status", {"id": request["id"]})[1]["state"], "failed")
        self.assertFalse((self.root / "SHOULD_NOT_EXIST").exists())
        self.assertFalse((self.root / "ALSO_MUST_NOT_EXIST").exists())

    def test_cancelled_supervisor_does_not_hide_live_descendant(self):
        job = self.root / "jobs" / "descendant"
        job.mkdir(parents=True)
        code = 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print("ready",flush=True); time.sleep(30)'
        parent = subprocess.Popen(["python3", "-c", 'import subprocess,time,sys; subprocess.Popen([sys.executable,"-c",sys.argv[1]]); time.sleep(30)', code],
                                  stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            self.assertEqual(parent.stdout.readline().strip(), "ready")
            (job / "pid").write_text(str(parent.pid))
            broker = module("state", SHARED / "compute-state.py")
            (job / "record.json").write_text(json.dumps({"processIdentity": broker.process_identity(parent.pid), "phase": "running"}))
            self.assertNotEqual(self.rpc("cancel", {"id": "descendant"})[0], 0)
            self.assertEqual(self.rpc("status", {"id": "descendant"})[1]["state"], "cancelling")
        finally:
            os.killpg(parent.pid, signal.SIGKILL)
            parent.wait(timeout=5)
            parent.stdout.close()

    def test_pid_reuse_is_never_signalled(self):
        job = self.root / "jobs" / "reused"
        job.mkdir(parents=True)
        proc = subprocess.Popen(["sleep", "30"], start_new_session=True)
        try:
            (job / "pid").write_text(str(proc.pid))
            (job / "record.json").write_text(json.dumps({"processIdentity": "not-this-process", "phase": "running"}))
            self.assertNotEqual(self.rpc("cancel", {"id": "reused"})[0], 0)
            self.assertIsNone(proc.poll())
        finally:
            proc.kill()
            proc.wait(timeout=5)

    def test_catalog_upgrade_is_atomic_and_doctor_detects_corruption(self):
        def install(stage, value, digest):
            directory = self.root / ".staging" / stage
            directory.mkdir(parents=True)
            (directory / "runner.py").write_text(value)
            return self.rpc("cap-commit", {"name": "demo", "stage": stage,
                "manifest": {"name": "demo", "jobs": {"run": {"cmd": "true"}}}, "digest": digest,
                "files": {"runner.py": hashlib.sha256(value.encode()).hexdigest()},
                "source": {"url": "https://github.com/o/r.git", "commit": "a" * 40}})
        self.assertEqual(install("first", "old", "one")[0], 0)
        self.assertEqual(self.rpc("catalog", {})[1]["capabilities"]["demo"]["source"]["commit"], "a" * 40)
        self.rpc("reserve", {"id": "busy", "token": "t", "limit": 1})
        self.assertEqual(install("second", "new", "two")[0], 6)
        self.assertEqual((self.root / "caps/demo/runner.py").read_text(), "old")
        self.rpc("abort", {"id": "busy", "token": "t"})
        self.assertEqual(install("third", "new", "two")[0], 0)
        (self.root / "caps/demo/runner.py").write_text("tampered")
        self.assertTrue(self.rpc("doctor", {})[1].get("payloadIssues"))

    def test_removed_job_directory_does_not_allow_id_reuse(self):
        import shutil
        request = {"id": "history", "token": "one", "limit": 1}
        self.assertEqual(self.rpc("reserve", request)[0], 0)
        self.rpc("abort", request)
        shutil.rmtree(self.root / "jobs/history")
        self.assertNotEqual(self.rpc("reserve", dict(request, token="two"))[0], 0)

    def test_catalog_read_waits_for_atomic_payload_commit(self):
        with open(self.root / ".state.lock", "a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            proc = subprocess.Popen(["python3", str(SHARED / "compute-state.py"), "catalog", "{}"],
                                    env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                time.sleep(0.2)
                self.assertIsNone(proc.poll(), "catalog read crossed an in-progress bundle commit")
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                proc.communicate(timeout=5)

    def test_unverified_legacy_pid_is_not_signalled(self):
        job = self.root / "jobs/legacy"
        job.mkdir(parents=True)
        proc = subprocess.Popen(["sleep", "30"], start_new_session=True)
        try:
            (job / "pid").write_text(str(proc.pid))
            self.assertNotEqual(self.rpc("cancel", {"id": "legacy"})[0], 0)
            self.assertIsNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
