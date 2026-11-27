"""Install-time setup plans: shown after install, asked on a TTY, never implicit."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


c = module("setup_controller", SCRIPTS / "remote-compute.py")

MANIFEST = {
    "name": "pixel",
    "jobs": {
        "setup": {"description": "Download pinned models.", "cmd": "python3 {capdir}/s.py --root {comfy_root}",
                  "params": {"comfy_root": {"pattern": "/[^\\r\\n]+"}}},
        "setup-runtime": {"description": "Create the Pillow runtime.", "cmd": "python3 {capdir}/r.py",
                          "params": {"port": {"pattern": "[0-9]+", "default": "8188"}}},
        "preflight": {"cmd": "python3 {capdir}/p.py"},
    },
    "setup": {
        "prerequisites": ["python3.12"],
        "params": {"comfy_root": "existing ComfyUI root"},
        "steps": ["setup", "setup-runtime"],
        "verify": ["preflight"],
        "notes": "Does not start ComfyUI.",
    },
}


def capture(function, *args, **kwargs):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        result = function(*args, **kwargs)
    return result, buffer.getvalue()


class SetupPlanTests(unittest.TestCase):
    def test_manifest_setup_must_name_declared_jobs(self):
        c.validate_manifest(dict(MANIFEST))
        broken = dict(MANIFEST, setup={"steps": ["missing"]})
        with self.assertRaisesRegex(ValueError, "undeclared job"):
            c.validate_manifest(broken)
        with self.assertRaisesRegex(ValueError, "list of names"):
            c.validate_manifest(dict(MANIFEST, setup={"steps": "setup"}))

    def test_plan_lists_steps_params_and_follow_up(self):
        text = "\n".join(c.render_setup_plan("gpubox", MANIFEST))
        self.assertIn("nothing has run yet", text)
        self.assertIn("prerequisite: python3.12", text)
        self.assertIn("1. pixel:setup", text)
        self.assertIn("Download pinned models.", text)
        self.assertIn("--param comfy_root=<required> existing ComfyUI root", text)
        self.assertIn("2. pixel:setup-runtime", text)
        self.assertIn("--param port=8188 (default)", text)
        self.assertIn("verify after services are running: pixel:preflight", text)
        self.assertIn("capabilities setup gpubox pixel --param comfy_root=...", text)
        self.assertIn("no setup declared", c.render_setup_plan("gpubox", {"name": "x", "jobs": {}})[0])

    def test_non_interactive_install_prints_plan_without_dispatch(self):
        with patch.object(c, "_interactive", return_value=False), \
                patch.object(c, "run_setup", side_effect=AssertionError("must not run")):
            rc, out = capture(c.offer_setup, "gpubox", MANIFEST, "ask", {})
        self.assertEqual(rc, 0)
        self.assertIn("SETUP PLAN pixel", out)
        self.assertIn("Re-run install with --setup", out)

    def test_interactive_yes_prompts_for_required_params_then_runs(self):
        answers = iter(["y", "relative", "/opt/ComfyUI"])
        calls = []
        with patch.object(c, "_interactive", return_value=True), \
                patch("builtins.input", lambda prompt: next(answers)), \
                patch.object(c, "run_setup", lambda nick, manifest, given: calls.append(given) or 0):
            rc, out = capture(c.offer_setup, "gpubox", MANIFEST, "ask", {})
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [{"comfy_root": "/opt/ComfyUI"}])
        self.assertIn("value must match", out)

    def test_interactive_default_answer_skips(self):
        with patch.object(c, "_interactive", return_value=True), \
                patch("builtins.input", lambda prompt: ""), \
                patch.object(c, "run_setup", side_effect=AssertionError("must not run")):
            rc, out = capture(c.offer_setup, "gpubox", MANIFEST, "ask", {})
        self.assertEqual(rc, 0)
        self.assertIn("Setup skipped", out)

    def test_explicit_setup_without_required_param_fails_before_dispatch(self):
        with patch.object(c, "_interactive", return_value=False), \
                patch.object(c, "run_setup", side_effect=AssertionError("must not run")):
            rc, out = capture(c.offer_setup, "gpubox", MANIFEST, "run", {})
        self.assertEqual(rc, c.EXIT_USAGE)
        self.assertIn("--param comfy_root=", out)

    def test_no_setup_only_prints_plan(self):
        with patch.object(c, "run_setup", side_effect=AssertionError("must not run")):
            rc, out = capture(c.offer_setup, "gpubox", MANIFEST, "skip", {})
        self.assertEqual(rc, 0)
        self.assertIn("1. pixel:setup", out)

    def registry(self, installed=("pixel",)):
        jobs = {"pixel:" + name: dict(job, capdir="~/.remote-compute/caps/pixel", workdir="~",
                                      capability="pixel",
                                      params={k: dict(v) for k, v in (job.get("params") or {}).items()})
                for name, job in MANIFEST["jobs"].items()}
        return {"resources": {"gpubox": {"jobs": jobs,
                                         "capabilities_installed": {n: {} for n in installed}}}}

    def test_run_setup_dispatches_steps_in_order_and_stops_on_failure(self):
        launched, states = [], iter([("completed", "0"), ("failed", "1")])
        def launch(reg, res, nick, workdir, rendered, opts):
            launched.append(rendered)
            return 0
        with patch.object(c, "load_registry", lambda: self.registry()), \
                patch.object(c, "_launch_job", launch), \
                patch.object(c, "_await_job", lambda job_id, deadline: next(states)):
            rc, out = capture(c.run_setup, "gpubox", MANIFEST, {"comfy_root": "/opt/Comfy UI"})
        self.assertEqual(rc, 1)
        self.assertEqual(len(launched), 2)
        self.assertIn("'/opt/Comfy UI'", launched[0])
        self.assertIn("s.py", launched[0])
        self.assertIn("r.py", launched[1])
        self.assertIn("SETUP FAILED at pixel:setup-runtime", out)

    def test_run_setup_success_points_at_verify_jobs(self):
        with patch.object(c, "load_registry", lambda: self.registry()), \
                patch.object(c, "_launch_job", lambda *a: 0), \
                patch.object(c, "_await_job", lambda job_id, deadline: ("completed", "0")):
            rc, out = capture(c.run_setup, "gpubox", MANIFEST, {"comfy_root": "/opt/ComfyUI"})
        self.assertEqual(rc, 0)
        self.assertIn("SETUP COMPLETE pixel", out)
        self.assertIn("remote-compute run gpubox pixel:preflight", out)

    def test_run_setup_refuses_missing_required_bundles(self):
        manifest = dict(MANIFEST, setup=dict(MANIFEST["setup"], requires=["runtime-bundle"]))
        with patch.object(c, "load_registry", lambda: self.registry()), \
                patch.object(c, "_launch_job", side_effect=AssertionError("must not launch")):
            rc, out = capture(c.run_setup, "gpubox", manifest, {"comfy_root": "/opt/ComfyUI"})
        self.assertEqual(rc, c.EXIT_USAGE)
        self.assertIn("requires runtime-bundle", out)

    def test_split_setup_options(self):
        rest, setup = c.split_setup_options(["install", "gpubox", "/repo", "pixel", "--setup",
                                             "--param", "comfy_root=/opt/ComfyUI", "--env", "gpu"])
        self.assertEqual(rest, ["install", "gpubox", "/repo", "pixel", "--env", "gpu"])
        self.assertEqual(setup, {"mode": "run", "params": {"comfy_root": "/opt/ComfyUI"}})
        for bad in (["--setup", "--no-setup"], ["--param", "novalue"], ["--no-setup", "--param", "a=b"]):
            with self.assertRaises(ValueError):
                c.split_setup_options(["install"] + bad)


if __name__ == "__main__":
    unittest.main()
