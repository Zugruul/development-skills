"""Task closure contract exercised through bundled command boundaries."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
FIX = Path(__file__).resolve().parent / "fixtures"
TS = "2026-01-01T00:00:00Z"


class ClosureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / ".neural-network").mkdir()
        (self.root / ".claude").mkdir()
        self.cfg = json.loads((FIX / "valid.project.json").read_text())
        self.config()
        self.log = self.root / ".claude/telemetry.jsonl"
        self.env = dict(os.environ)
        self.env.pop("PROJECT_CONFIG", None)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text('''#!/usr/bin/env bash
case "$1 $2" in
  "project item-list") echo '{"items":[{"id":"ITEM_238","content":{"number":238},"status":"Backlog"}]}' ;;
  "project item-edit") echo "$*" >> "$MUTATIONS"; echo edited ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
''')
        gh.chmod(0o755)
        self.marker = self.root / "mutations"
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"],
                        MUTATIONS=str(self.marker), GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_AUTHOR_NAME="Fixture",
                        GIT_AUTHOR_EMAIL="fixture@example.test",
                        GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.test")

    def config(self, feedback=False):
        self.cfg.setdefault("methodology", {})["feedback"] = feedback
        (self.root / ".neural-network/project.json").write_text(json.dumps(self.cfg))

    def run_cmd(self, *args, cwd=None):
        return subprocess.run(args, cwd=cwd or self.root, env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def record(self, event):
        return self.run_cmd(sys.executable, str(SCRIPTS / "telemetry.py"),
                            str(self.root), "record", json.dumps(event))

    def event(self, kind, **extra):
        return dict(kind=kind, task="238", ts=TS, **extra)

    def raw(self, *records):
        self.log.write_text("\n".join(json.dumps(r) for r in records) + "\n")

    def preflight(self, *args, cwd=None):
        return self.run_cmd("bash", str(SCRIPTS / "closure-preflight.sh"),
                            "--task", "238", *args, cwd=cwd)

    def close(self):
        return self.record(self.event("task-close", estimate=3))

    def assert_blocked(self, result, text):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("BLOCKED", result.stdout)
        self.assertIn(text, result.stdout)

    def test_missing_retro_blocks_preflight_and_new_close_without_append(self):
        self.assert_blocked(self.preflight(), "retro")
        self.assert_blocked(self.close(), "retro")
        self.assertFalse(self.log.exists())

    def test_enabled_feedback_missing_blocks_even_with_retro(self):
        for setting in (True, {"enabled": True}):
            with self.subTest(setting=setting):
                self.config(setting)
                self.raw(self.event("retro-complete", evidence="commit:abc"))
                before = self.log.read_bytes()
                self.assert_blocked(self.preflight(), "feedback")
                self.assert_blocked(self.close(), "feedback")
                self.assertEqual(self.log.read_bytes(), before)

    def test_disabled_or_absent_feedback_allows_retro_and_explicit_skip(self):
        for setting in (False, {"enabled": False}, {},
                        {"feed": ".neural-network/feedbacks/feed.yaml", "roles": [], "autoTriage": False}):
            for kind, extra in (("retro-complete", {"evidence": "commit:abc"}),
                                ("retro-skip", {"reason": "identities disabled"})):
                with self.subTest(setting=setting, kind=kind):
                    self.config(setting)
                    self.raw(self.event(kind, **extra))
                    result = self.preflight()
                    self.assertEqual(result.returncode, 0, result.stdout)
                    result = self.close()
                    self.assertEqual(result.returncode, 0, result.stdout)
        del self.cfg["methodology"]["feedback"]
        (self.root / ".neural-network/project.json").write_text(json.dumps(self.cfg))
        self.assertEqual(self.preflight().returncode, 0)

    def test_enabled_feedback_and_late_earlier_transition_allow_closure(self):
        self.config(True)
        for kind in ("retro-complete", "feedback-complete"):
            result = self.record(self.event(kind, evidence="artifact:report"))
            self.assertEqual(result.returncode, 0, result.stdout)
        # Deferred sync may append an earlier transition after learning evidence.
        result = self.record(self.event("transition", **{"from": "", "to": "In progress"}))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.preflight().returncode, 0)
        self.assertEqual(self.close().returncode, 0)

    def test_wrong_task_cannot_supply_retro_or_feedback(self):
        self.raw(dict(self.event("retro-complete", evidence="commit:other"), task="999"))
        self.assert_blocked(self.close(), "retro")
        self.config(True)
        self.raw(self.event("retro-complete", evidence="commit:abc"),
                 dict(self.event("feedback-complete", evidence="commit:other"), task="999"))
        self.assert_blocked(self.close(), "feedback")

    def test_invalid_completion_and_skip_records_rejected_without_append(self):
        for kind, field in (("retro-complete", "evidence"),
                            ("feedback-complete", "evidence"), ("retro-skip", "reason")):
            for value in (None, "", " \t\n", True, 42, ["claim"], {"claim": "yes"}):
                with self.subTest(kind=kind, value=value):
                    rec = self.event(kind, **{field: value})
                    result = self.record(rec)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("INVALID", result.stdout)
                    self.assertFalse(self.log.exists())
            for field_missing in (field, "task", "ts"):
                rec = self.event(kind, **{field: "claim"})
                del rec[field_missing]
                self.assertNotEqual(self.record(rec).returncode, 0)

    def test_raw_malformed_evidence_never_satisfies_closure(self):
        cases = [None, [], {"kind": []}]
        for kind, field in (("retro-complete", "evidence"), ("retro-skip", "reason")):
            for value in (None, "", " ", True, 42, [], {}):
                cases.append(self.event(kind, **{field: value}))
            for field_missing in (field, "task", "ts"):
                rec = self.event(kind, **{field: "claim"})
                del rec[field_missing]
                cases.append(rec)
        for kind in ("retro-complete", "retro-skip"):
            base = self.event(kind, **({"reason": "blocker"} if kind == "retro-skip" else {"evidence": "commit:abc"}))
            for field in ("task", "ts"):
                for value in ([], {}, True, " "):
                    cases.append(dict(base, **{field: value}))
        for rec in cases:
            with self.subTest(rec=rec):
                self.raw(rec)
                with self.log.open("a") as log:
                    log.write("not-json\n")
                before = self.log.read_bytes()
                self.assert_blocked(self.preflight(), "retro")
                self.assert_blocked(self.close(), "retro")
                self.assertEqual(self.log.read_bytes(), before)
        self.config(True)
        self.raw(self.event("retro-complete", evidence="commit:abc"),
                 self.event("feedback-complete", evidence=True))
        self.assert_blocked(self.close(), "feedback")

    def test_config_errors_fail_closed(self):
        self.raw(self.event("retro-skip", reason="identities disabled"))
        path = self.root / ".neural-network/project.json"
        for contents in ("{bad", "[]", '{"methodology": []}',
                         '{"methodology": {"feedback": "false"}}',
                         '{"methodology": {"feedback": {"enabled": "false"}}}'):
            with self.subTest(contents=contents):
                path.write_text(contents)
                before = self.log.read_bytes()
                self.assert_blocked(self.preflight(), "config")
                self.assert_blocked(self.close(), "config")
                self.assertEqual(self.log.read_bytes(), before)
        path.unlink()
        self.assert_blocked(self.close(), "config")

    def test_unknown_feedback_key_blocks_all_closure_boundaries_then_recovers(self):
        queue = self.root / ".claude/board-queue.jsonl"
        actions = [("preflight", self.preflight), ("task-close", self.close)]
        for status in ("Ready", "Deployed"):
            actions.append((status, lambda status=status: self.run_cmd(
                "bash", str(SCRIPTS / "board.sh"), "move", "238", status)))
            actions.append(("queued " + status, lambda: self.run_cmd(
                "bash", str(SCRIPTS / "board.sh"), "flush")))
        for name, action in actions:
            with self.subTest(boundary=name):
                self.config({"enabld": True})
                self.raw(self.event("retro-complete", evidence="commit:retro"))
                self.marker.unlink(missing_ok=True)
                (self.root / ".claude/board-cache.json").unlink(missing_ok=True)
                queue.unlink(missing_ok=True)
                if name.startswith("queued "):
                    queue.write_text(json.dumps(dict(op="move", issue="238",
                                                    status=name.split()[1], ts=TS)) + "\n")
                    queued_before = queue.read_bytes()
                before = self.log.read_bytes()
                result = action()
                # Flush reports individual blocked operations without failing the batch.
                if not name.startswith("queued "):
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("BLOCKED", result.stdout)
                self.assertIn("config", result.stdout)
                self.assertIn("enabld", result.stdout)
                self.assertEqual(self.log.read_bytes(), before)
                self.assertFalse(self.marker.exists())
                if name.startswith("queued "):
                    self.assertEqual(queue.read_bytes(), queued_before)
                # Correct the policy and supply its required evidence; retry the same boundary.
                self.config({"enabled": True})
                result = self.record(self.event("feedback-complete", evidence="commit:feedback"))
                self.assertEqual(result.returncode, 0, result.stdout)
                result = action()
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("BLOCKED", result.stdout)
                if name not in ("preflight", "task-close"):
                    self.assertTrue(self.marker.exists())
                if name == "task-close":
                    self.assertIn('"kind": "task-close"', self.log.read_text())
                if name.startswith("queued "):
                    self.assertFalse(queue.exists() and queue.read_text().strip())

    def test_shared_loader_honors_project_config(self):
        self.raw(self.event("retro-complete", evidence="commit:abc"))
        override = self.root / "override.json"
        cfg = dict(self.cfg, methodology={"feedback": True})
        override.write_text(json.dumps(cfg))
        self.env["PROJECT_CONFIG"] = str(override)
        self.assert_blocked(self.preflight(), "feedback")
        self.assert_blocked(self.close(), "feedback")

    def test_ready_deployed_block_before_external_mutation_then_succeed(self):
        for status in ("Ready", "Deployed", " rEaDy "):
            with self.subTest(status=status):
                self.log.unlink(missing_ok=True)
                self.marker.unlink(missing_ok=True)
                result = self.run_cmd("bash", str(SCRIPTS / "board.sh"), "move", "238", status)
                self.assert_blocked(result, "retro")
                self.assertFalse(self.marker.exists())
                self.assertFalse(self.log.exists())
                self.raw(self.event("retro-skip", reason="identities disabled"))
                result = self.run_cmd("bash", str(SCRIPTS / "board.sh"), "move", "238", status)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertTrue(self.marker.exists())

    def test_queued_replay_checks_closure_and_retains_blocked_operation(self):
        queue = self.root / ".claude/board-queue.jsonl"
        for status in ("Ready", "Deployed"):
            with self.subTest(status=status):
                self.log.unlink(missing_ok=True)
                self.marker.unlink(missing_ok=True)
                queue.write_text(json.dumps(dict(op="move", issue="238", status=status, ts=TS)) + "\n")
                result = self.run_cmd("bash", str(SCRIPTS / "board.sh"), "flush")
                self.assertIn("BLOCKED", result.stdout)
                self.assertFalse(self.marker.exists())
                self.assertFalse(self.log.exists())
                self.assertIn(status, queue.read_text())
                self.raw(self.event("retro-complete", evidence="commit:abc"))
                result = self.run_cmd("bash", str(SCRIPTS / "board.sh"), "flush")
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertTrue(self.marker.exists())
                self.assertFalse(queue.exists() and queue.read_text().strip())

    def test_earlier_transitions_keep_their_existing_guards(self):
        result = self.run_cmd("bash", str(SCRIPTS / "board.sh"), "move", "238", "Backlog")
        self.assertEqual(result.returncode, 0, result.stdout)
        for status, message in (("In progress", "comments"), ("QA", "review pass"),
                                ("In review", "gate")):
            self.marker.unlink(missing_ok=True)
            result = self.run_cmd("bash", str(SCRIPTS / "board.sh"), "move", "238", status)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(message, result.stdout.lower())
            self.assertNotIn("closure", result.stdout.lower())
            self.assertFalse(self.marker.exists())

    def test_linked_worktree_defaults_to_primary_and_explicit_root_is_honored(self):
        for args in (("init", "-q", "-b", "main"), ("add", ".neural-network"),
                     ("commit", "-qm", "fixture")):
            result = self.run_cmd("git", *args)
            self.assertEqual(result.returncode, 0, result.stdout)
        linked = self.root / "linked"
        result = self.run_cmd("git", "worktree", "add", "-qb", "linked", str(linked))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.raw(self.event("retro-skip", reason="identities disabled"))
        result = self.preflight(cwd=linked)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_blocked(self.preflight("--root", str(linked), cwd=linked), "retro")
        result = self.run_cmd("bash", str(SCRIPTS / "board.sh"), "move", "238", "Ready", cwd=linked)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertFalse((linked / ".claude/telemetry.jsonl").exists())

    def test_historical_metrics_read_closes_without_new_evidence(self):
        self.raw(self.event("task-close", estimate=3),
                 self.event("retro-skip", reason="historical blocker"))
        result = self.run_cmd(sys.executable, str(SCRIPTS / "telemetry.py"), str(self.root), "metrics")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("task=238  estimate=3", result.stdout)
        self.assertIn("retro skips: 1", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
