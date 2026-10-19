"""Behavioral contract for #241's shared admission/append boundary."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
TS = '2026-10-19T12:00:00Z'
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('telemetry', SCRIPTS / 'telemetry.py')
telemetry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(telemetry)


class ReviewRounds(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.log = self.root / '.claude/telemetry.jsonl'

    def cli(self, *args, root=None):
        return subprocess.run([sys.executable, str(SCRIPTS / 'telemetry.py'),
                               str(root or self.root), *args], text=True, capture_output=True)

    def event(self, n=1, task='241', **extra):
        return dict(kind='review-round', task=task, round=n, verdict='REQUEST_CHANGES', ts=TS, **extra)

    def record(self, event):
        return self.cli('record', json.dumps(event))

    def admit(self, task='241'):
        return self.cli('review-admit', task, TS)

    def approve(self):
        return self.cli('review-approval-check', '241')

    def snapshot(self):
        return self.log.read_bytes() if self.log.exists() else None

    def ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def refused(self, fn):
        before = self.snapshot()
        result = fn()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)
        return result.stdout + result.stderr

    def seed(self, records):
        self.log.parent.mkdir(exist_ok=True)
        self.log.write_text(''.join(json.dumps(r) + '\n' for r in records))

    def test_reservation_precedes_reviewer_and_cap_survives_restarts(self):
        self.refused(self.approve)
        self.assertFalse((self.root / ".claude").exists())
        for n in range(1, 4):
            result = self.admit()
            self.ok(result)
            self.assertEqual(json.loads(result.stdout)['round'], n)
            self.assertEqual(json.loads(self.log.read_text().splitlines()[-1])['kind'], 'review-round-start')
            self.assertIn('pending', self.refused(self.admit).lower())
            self.refused(self.approve)
            self.ok(self.record(self.event(n)))
        message = self.refused(self.admit)
        self.assertIn('In review', message)
        self.assertIn('handoff', message)
        self.refused(self.approve)

    def test_third_approval_and_pending_after_prior_approval(self):
        for n in range(1, 4):
            self.ok(self.admit())
            rec = self.event(n)
            rec['verdict'] = 'approved'
            self.ok(self.record(rec))
            before = self.snapshot()
            self.ok(self.approve())
            self.assertEqual(before, self.snapshot())
        self.refused(self.admit)
        self.ok(self.approve())

    def test_latest_verdict_controls_approval(self):
        rec = self.event(); rec['verdict'] = 'APPROVE'
        self.ok(self.record(rec))
        self.ok(self.approve())
        self.ok(self.admit())
        self.refused(self.approve)
        self.ok(self.record(self.event(2)))
        self.refused(self.approve)

    def test_legacy_sequence_and_no_duplicate_skip_or_regression(self):
        for n in range(1, 4):
            self.ok(self.record(self.event(n)))
            self.refused(lambda: self.record(self.event(n)))
        for n in (1, 2, 4, 5):
            self.refused(lambda: self.record(self.event(n)))
        self.refused(self.admit)

    def test_invalid_rounds_and_task_types_never_append(self):
        for n in (True, False, 0, -1, 4, 1.0, '1', None, [], {}):
            self.refused(lambda: self.record(self.event(n)))
        for task in (True, False, [], {}, ' ', ' 241', '241 '):
            self.refused(lambda: self.record(self.event(task=task)))
        for verdict in (True, {}, [], 17, ' '):
            rec = self.event(); rec['verdict'] = verdict
            self.refused(lambda: self.record(rec))
        self.refused(lambda: self.record(self.event(2)))

    def test_reserved_history_requires_matching_completion(self):
        self.ok(self.admit())
        self.refused(lambda: self.record(self.event(2)))
        self.ok(self.record(self.event()))
        self.refused(lambda: self.record(self.event(2)))
        start = dict(kind='review-round-start', task='241', round=3, ts=TS)
        self.refused(lambda: self.record(start))
        start['round'] = 2
        self.ok(self.record(start))
        self.ok(self.record(self.event(2)))

    def test_task_isolation_and_tagged_passes_do_not_consume_budget(self):
        for n in range(1, 8):
            self.ok(self.record(self.event(n, **{'pass': 'spec-compliance'})))
            self.ok(self.record(self.event(n, **{'pass': 'code-quality'})))
        self.ok(self.record(self.event(task=99)))
        self.ok(self.record(self.event(2, task='99')))
        self.ok(self.admit())
        self.ok(self.record(self.event(task=241)))
        self.assertEqual(json.loads(self.admit().stdout)['round'], 2)

    def test_legacy_history_and_metrics_remain_readable(self):
        self.seed([self.event(1), self.event(2)])
        self.assertEqual(json.loads(self.admit().stdout)['round'], 3)
        self.ok(self.cli('metrics'))
        self.seed([self.event(4)])
        self.ok(self.cli('metrics'))
        self.refused(self.admit)

    def test_malformed_ambiguous_and_truncated_history_fail_closed(self):
        histories = ['not json\n', '[]\n', '{"task":"other"}\n', '\xff',
                     json.dumps(self.event()), # missing final newline
                     json.dumps(self.event(2)) + '\n',
                     json.dumps(self.event()) + '\n' + json.dumps(self.event()) + '\n',
                     json.dumps(dict(self.event(), **{'pass': 'unknown'})) + '\n']
        for history in histories:
            self.log.parent.mkdir(exist_ok=True)
            self.log.write_bytes(history.encode('latin1'))
            self.refused(self.admit)
            self.refused(self.approve)
            self.refused(lambda: self.record(self.event()))
        self.log.unlink()
        self.log.mkdir()
        result = self.admit()
        self.assertNotEqual(result.returncode, 0)

    def test_concurrent_admissions_and_verdicts(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.admit(), range(8)))
        self.assertEqual(sum(r.returncode == 0 for r in results), 1)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.record(self.event()), range(8)))
        self.assertEqual(sum(r.returncode == 0 for r in results), 1)
        self.assertEqual(len(self.log.read_text().splitlines()), 2)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda n: self.record(dict(kind='gate', task=str(n), ok=True, ts=TS)), range(30)))
        for r in results: self.ok(r)
        self.assertEqual(len([json.loads(line) for line in self.log.read_text().splitlines()]), 32)

    def test_lock_failure_and_write_failure_never_admit(self):
        lock = self.root / '.claude/telemetry.lock'
        lock.mkdir(parents=True)
        self.assertIn('lock', self.refused(self.admit).lower())
        lock.rmdir()
        with patch.object(telemetry.os, 'fsync', side_effect=OSError('synthetic disk failure')):
            self.assertNotEqual(telemetry._cli([str(self.root), 'review-admit', '241', TS]), 0)
        self.assertFalse(lock.exists())

    def test_shell_defaults_share_primary_worktree_state_and_explicit_root(self):
        def git(*args):
            r = subprocess.run(['git', '-C', str(self.root), *args], capture_output=True, text=True)
            self.ok(r)
        git('init', '-q')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com', 'commit', '--allow-empty', '-m', 'fixture')
        linked = self.root / 'linked'
        git('worktree', 'add', '-b', 'linked', str(linked))
        env = dict(os.environ); env.pop('SPEC_WORKFLOW_REPO_ROOT', None)
        shell = ['bash', str(SCRIPTS / 'review-round.sh')]
        def run(*args):
            return subprocess.run(shell + list(args), cwd=linked, env=env, text=True, capture_output=True)
        self.ok(run('admit', '--task', '241', '--ts', TS))
        self.assertTrue(self.log.exists())
        self.assertFalse((linked / '.claude/telemetry.jsonl').exists())
        self.refused(self.admit)
        self.ok(run('admit', '--task', '241', '--ts', TS, '--root', str(linked)))
        self.ok(self.record(dict(self.event(), verdict='APPROVE')))
        self.ok(run('approval-check', '--task', '241'))
        self.assertNotEqual(run('approval-check', '--task', '241', '--root', str(linked)).returncode, 0)

    def test_ambiguous_json_and_invalid_other_task_history(self):
        for raw in ('{"kind":"gate","kind":"review-round","task":"241","round":1,"verdict":"APPROVE","ts":"x"}\n',
                    '{"kind":"gate","task":"other","ok":true,"ts":"x","x":NaN}\n',
                    json.dumps(self.event(4, task='other')) + '\n'):
            self.log.parent.mkdir(exist_ok=True)
            self.log.write_text(raw)
            self.refused(self.admit)
            self.refused(self.approve)
        self.log.unlink()
        raw = '{"kind":"review-round","task":"241","round":4,"round":1,"verdict":"APPROVE","ts":"x"}'
        self.refused(lambda: self.cli('record', raw))

    def test_lock_waits_for_active_writer_and_releases_on_failure(self):
        # Real policy lock holder; synchronize on its flushed readiness line.
        code = "import sys,time; sys.path.insert(0,sys.argv[1]); from telemetry_lock import locked; exec(\"with locked(sys.argv[2]):\\n print('locked',flush=True)\\n time.sleep(.35)\")"
        proc = subprocess.Popen([sys.executable, '-c', code, str(SCRIPTS), str(self.root)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(proc.stdout.readline().strip(), 'locked')
            started = time.monotonic()
            self.ok(self.admit())
            self.assertGreater(time.monotonic() - started, .2)
            _, errors = proc.communicate(timeout=5)
            self.assertEqual(proc.returncode, 0, errors)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate(timeout=5)
        self.assertFalse((self.root / '.claude/telemetry.lock').exists())
        self.refused(self.admit)
        self.assertFalse((self.root / '.claude/telemetry.lock').exists())

    def test_missing_explicit_root_refuses_without_creating_state(self):
        missing = self.root / 'absent' / 'consumer'
        calls = [
            lambda: self.cli('review-admit', '241', TS, root=missing),
            lambda: self.cli('record', json.dumps(self.event()), root=missing),
            lambda: self.cli('record', json.dumps(dict(kind='gate', task='241', ok=True, ts=TS)), root=missing),
            lambda: self.cli('review-approval-check', '241', root=missing),
            lambda: subprocess.run(['bash', str(SCRIPTS / 'review-round.sh'), 'admit',
                                    '--task', '241', '--ts', TS, '--root', str(missing)],
                                   text=True, capture_output=True),
        ]
        for call in calls:
            result = call()
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((self.root / 'absent').exists())
            self.assertNotIn('Traceback', result.stderr)

    def test_float_overflow_rejected_in_extra_and_nested_fields(self):
        self.ok(self.record(dict(kind='gate', task='other', ok=True, ts=TS)))
        for token in ('1e400', '-1e400'):
            for value in (token, '{"nested":[' + token + ']}'):
                with self.subTest(token=token, value=value):
                    raw = '{"kind":"gate","task":"other","ok":true,"ts":"' + TS + '","duration":' + value + '}'
                    message = self.refused(lambda: self.cli('record', raw))
                    self.assertIn('INVALID', message)
                    self.assertNotIn('Traceback', message)
        self.ok(self.admit())

    def test_valid_finite_floats_preserve_forward_admission(self):
        for value in (0.0, -1.5, 1e308, -1e308, 1e-300):
            self.ok(self.record(dict(kind='gate', task='other', ok=True, ts=TS,
                                     duration=value, extra={'nested': [value]})))
        self.ok(self.admit())

    def test_raw_overflow_history_blocks_forward_checks_but_metrics_remain_readable(self):
        for token in ('1e400', '-1e400'):
            with self.subTest(token=token):
                self.log.parent.mkdir(exist_ok=True)
                self.log.write_text('{"kind":"gate","task":"other","ok":true,"ts":"' + TS + '","duration":' + token + '}\n')
                self.refused(self.admit)
                self.refused(self.approve)
                self.ok(self.cli('metrics'))

    def test_append_serializes_fully_before_touching_destination(self):
        self.seed([dict(kind='gate', task='other', ok=True, ts=TS)])
        for value, error in ((float('inf'), ValueError), (float('-inf'), ValueError),
                             (float('nan'), ValueError), ({'not-json'}, TypeError)):
            for destination in (self.log, self.log.parent / 'new.jsonl'):
                with self.subTest(value=value, destination=destination):
                    before = destination.read_bytes() if destination.exists() else None
                    with self.assertRaises(error):
                        telemetry.append(str(destination), {'extra': {'nested': [value]}})
                    after = destination.read_bytes() if destination.exists() else None
                    self.assertEqual(before, after)

    def test_serializer_rejection_reports_failure_and_releases_lock(self):
        self.seed([dict(kind='gate', task='other', ok=True, ts=TS)])
        before = self.snapshot()
        for error in (ValueError('synthetic serializer refusal'), TypeError('synthetic unsupported object')):
            with self.subTest(error=error):
                with patch.object(telemetry, 'append', side_effect=error):
                    self.assertNotEqual(telemetry.cmd_record(str(self.root), json.dumps(self.event())), 0)
                    self.assertNotEqual(telemetry.cmd_review(str(self.root), '241', TS), 0)
                self.assertEqual(self.snapshot(), before)
                self.assertFalse((self.root / '.claude/telemetry.lock').exists())

    def test_docs_wire_both_routes_and_register_lock(self):
        plugin = SCRIPTS.parent
        for rel in ('skills/build-next/SKILL.md', 'skills/implement-task/SKILL.md', 'skills/build-next/references/auto-review.md'):
            doc = (plugin / rel).read_text()
            self.assertIn('review-round.sh', doc)
            self.assertIn('approval-check', doc)
            self.assertIn('admit', doc)
        self.assertIn('ignore\t.claude/telemetry.lock/', (SCRIPTS / 'local-state.manifest').read_text())
        self.assertIn('.claude/telemetry.lock/', (plugin.parents[1] / '.gitignore').read_text())
        deltas = plugin.parents[1] / 'docs/spec-deltas'
        self.assertTrue(any(path.is_file() for path in (deltas / '241.md', deltas / 'applied/241.md')),
                        'task #241 delta must exist either pending or applied after the required fold')


if __name__ == '__main__':
    unittest.main()
