"""#530: drive the real inline lifecycle test under controlled scheduling."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest


TESTS = Path(__file__).resolve().parent
SCRIPTS = TESTS.parent / "scripts"


def run_fixture(mode):
    sys.path.insert(0, str(SCRIPTS))
    from assistant import tasks

    # Execute the section's actual check, not a copy of its readiness logic.
    section = (TESTS / "section-assistant-engine.sh").read_text()
    source = section.split("python3 - <<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
    original_worker = tasks.run_worker
    original_enumerate = threading.enumerate
    baseline = {t.ident for t in original_enumerate()}
    release = threading.Event()
    sampled = False

    def controlled_worker(q, stop_event, **kwargs):
        if mode == "missing":
            # Keep the registered task worker alive, but never create its timer.
            stop_event.wait()
            return
        if not release.wait(10):
            raise RuntimeError("fixture never released the task worker")
        return original_worker(q, stop_event, **kwargs)

    def sample_then_release():
        nonlocal sampled
        snapshot = original_enumerate()
        if not sampled and any(t.name == "assistant-tasks" for t in snapshot):
            sampled = True
            print("FIXTURE_FIRST_SAMPLE", sorted(t.name for t in snapshot
                                                if t.ident not in baseline))
            # The first post-start snapshot necessarily lacks the timer.
            # Only a subsequent observation can see nested worker startup.
            release.set()
        return snapshot

    with tempfile.TemporaryDirectory(prefix="engine-lifecycle-") as scratch:
        root = Path(scratch)
        for name in ("state", "a", "b"):
            (root / name).mkdir()
        (root / "a/.neural-network").mkdir()
        (root / "a/.neural-network/project.yaml").write_text(
            'schemaVersion: "2.0.0"\nassistant:\n'
            '  enabled: true\n  version: 1\n  names: [jarvis]\n'
            '  systemPrompt: You are jarvis.\n'
            '  llm: {provider: openai, model: fixture}\n'
            '  capabilities:\n'
            '    codex: {enabled: true, provisioning: {bin: codex}}\n'
        )
        os.environ.update(SCRIPTS_DIR=str(SCRIPTS), REPO_A=str(root / "a"),
                          REPO_B=str(root / "b"), STATE=str(root / "state"))
        tasks.run_worker = controlled_worker
        threading.enumerate = sample_then_release
        namespace = {}
        try:
            exec(compile(source, "section-assistant-engine-unit", "exec"), namespace)
        finally:
            threading.enumerate = original_enumerate
            tasks.run_worker = original_worker
            # Observe the check's own failure cleanup BEFORE harness recovery.
            # Recovery keeps a broken regression from hanging on owned threads.
            leaked = [t.name for t in original_enumerate() if t.ident not in baseline]
            print("FIXTURE_THREADS_BEFORE_RECOVERY", sorted(leaked))
            release.set()
            if "e" in namespace:
                namespace["e"].stop()


class EngineLifecycleRegression(unittest.TestCase):
    def probe(self, mode):
        try:
            result = subprocess.run(
                [sys.executable, str(Path(__file__).resolve()), "--fixture", mode],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=15,
            )
        except subprocess.TimeoutExpired as exc:
            self.fail("lifecycle check exceeded 15s bound: %s" % exc.stdout)
        self.assertIn("FIXTURE_THREADS_BEFORE_RECOVERY []", result.stdout, result.stdout)
        return result

    def test_delayed_nested_startup(self):
        result = self.probe("delayed")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(
            "FIXTURE_FIRST_SAMPLE ['assistant-distiller', 'assistant-index', "
            "'assistant-tasks', 'assistant-traces']", result.stdout, result.stdout,
        )
        self.assertIn("THREADS_AFTER_START 5", result.stdout, result.stdout)
        for marker in ("WORKER_NAMES ['distiller', 'index', 'tasks', 'traces']",
                       "WORKERS_ALIVE True", "WORKERS_COUNT 4",
                       "WORKER_COUNT_AFTER_RESTART 4", "THREADS_AFTER_STOP 0",
                       "ALL_JOINED True", "DOUBLE_STOP_OK True"):
            self.assertIn(marker, result.stdout, result.stdout)

    def test_missing_heartbeat_fails_with_cleanup(self):
        result = self.probe("missing")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("heartbeat readiness timed out", result.stdout, result.stdout)
        self.assertIn("assistant-tasks", result.stdout, result.stdout)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--fixture":
        run_fixture(sys.argv[2])
    else:
        unittest.main()
