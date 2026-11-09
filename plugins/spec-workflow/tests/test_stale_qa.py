"""#567: `next` reports QA items older than methodology.qaStaleHours (default 24)
from LOCAL telemetry transition events only."""
import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
NEXT = HERE.parent / 'scripts' / 'next.py'
BASE = json.loads((HERE / 'fixtures' / 'valid.project.json').read_text())


def item(num, title, status):
    return dict(status=status, priority='P1', title=title, content=dict(number=num, title=title))


def iso(hours_ago):
    t = datetime.now(timezone.utc) - timedelta(hours=hours_ago)
    return t.strftime('%Y-%m-%dT%H:%M:%SZ')


class StaleQa(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        (self.dir / '.claude').mkdir()
        self.cfg = copy.deepcopy(BASE)

    def transitions(self, *rows):
        lines = [json.dumps(dict(kind='transition', task=str(n), **{'from': 'In review'}, to=to, ts=ts))
                 for n, to, ts in rows]
        (self.dir / '.claude' / 'telemetry.jsonl').write_text('\n'.join(lines) + '\n')

    def run_next(self, items):
        cfg, data = self.dir / 'project.json', self.dir / 'items.json'
        cfg.write_text(json.dumps(self.cfg))
        data.write_text(json.dumps(dict(items=items)))
        env = dict(os.environ, SPEC_WORKFLOW_REPO_ROOT=str(self.dir))
        r = subprocess.run([sys.executable, str(NEXT), str(cfg), '', str(data)],
                           capture_output=True, text=True, cwd=self.dir, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def test_three_day_old_qa_item_reported_in_days(self):
        self.transitions((7, 'QA', iso(72)))
        out = self.run_next([item(7, 'FX-001: a', 'QA')])
        self.assertIn('STALE QA: #7 in QA for 3d — validate and move on, or record why not', out)

    def test_under_a_day_not_reported(self):
        self.transitions((7, 'QA', iso(23)))
        self.assertNotIn('STALE QA', self.run_next([item(7, 'FX-001: a', 'QA')]))

    def test_just_over_a_day_reported_in_hours(self):
        self.transitions((7, 'QA', iso(25)))
        self.assertIn('STALE QA: #7 in QA for 25h —', self.run_next([item(7, 'FX-001: a', 'QA')]))

    def test_threshold_configurable(self):
        self.cfg['methodology']['qaStaleHours'] = 48
        self.transitions((7, 'QA', iso(30)), (8, 'QA', iso(50)))
        out = self.run_next([item(7, 'FX-001: a', 'QA'), item(8, 'FX-002: b', 'QA')])
        self.assertNotIn('#7 in QA', out)
        self.assertIn('STALE QA: #8 in QA for 2d', out)

    def test_latest_qa_transition_wins(self):
        self.transitions((7, 'QA', iso(200)), (7, 'In progress', iso(100)), (7, 'QA', iso(2)))
        self.assertNotIn('STALE QA', self.run_next([item(7, 'FX-001: a', 'QA')]))

    def test_no_local_record_reports_age_unknown(self):
        out = self.run_next([item(7, 'FX-001: a', 'QA')])
        self.assertIn('STALE QA: 1 item with age unknown: #7', out)

    def test_other_tasks_records_do_not_leak(self):
        self.transitions((9, 'QA', iso(1)))
        out = self.run_next([item(7, 'FX-001: a', 'QA')])
        self.assertIn('STALE QA: 1 item with age unknown: #7', out)
        self.assertNotIn('#9', out)

    def test_non_qa_items_never_reported(self):
        self.transitions((7, 'QA', iso(100)))
        out = self.run_next([item(7, 'FX-001: a', 'Ready'), item(8, 'FX-002: b', 'In review')])
        self.assertNotIn('STALE QA', out)

    def test_reported_even_when_resume_guard_returns_early(self):
        self.transitions((7, 'QA', iso(100)))
        out = self.run_next([item(7, 'FX-001: a', 'QA'), item(8, 'FX-002: b', 'In progress')])
        self.assertIn('=> RESUME: #8', out)
        self.assertIn('STALE QA: #7 in QA for 4d', out)

    def test_malformed_telemetry_never_breaks_next(self):
        (self.dir / '.claude' / 'telemetry.jsonl').write_text('not json\n{"kind":"transition"}\n')
        out = self.run_next([item(1, 'FX-001: a', 'Backlog'), item(7, 'FX-009: b', 'QA')])
        self.assertIn('=> PICK: #1', out)
        self.assertIn('STALE QA: 1 item with age unknown: #7', out)

    def test_known_ages_capped_at_five_oldest_first_then_more(self):
        self.transitions(*[(n, 'QA', iso(30 + n)) for n in range(1, 8)])
        out = self.run_next([item(n, f'FX-00{n}: t', 'QA') for n in range(1, 8)])
        got = [l for l in out.splitlines() if l.startswith('STALE QA: #')]
        self.assertEqual([l.split()[2] for l in got], ['#7', '#6', '#5', '#4', '#3'])
        self.assertIn('STALE QA: +2 more', out)

    def test_unknown_ages_fold_into_one_capped_line(self):
        out = self.run_next([item(n, f'FX-00{n}: t', 'QA') for n in range(1, 9)])
        got = [l for l in out.splitlines() if l.startswith('STALE QA')]
        self.assertEqual(got, ['STALE QA: 8 items with age unknown: #1, #2, #3, #4, #5, +3 more'])

    def test_malformed_latest_ts_makes_age_unknown_not_older_entry(self):
        self.transitions((7, 'QA', iso(200)), (7, 'QA', 'garbage'))
        out = self.run_next([item(7, 'FX-001: a', 'QA')])
        self.assertIn('STALE QA: 1 item with age unknown: #7', out)
        self.assertNotIn('for 8d', out)

    def test_qa_status_taken_from_flow_position(self):
        self.cfg['boards'][0]['statusFlow'][3] = 'Validating'
        self.transitions((7, 'Validating', iso(100)))
        out = self.run_next([item(7, 'FX-001: a', 'Validating'), item(8, 'FX-002: b', 'QA')])
        self.assertIn('STALE QA: #7 in QA for 4d', out)
        self.assertNotIn('#8', out)

    def test_wait_path_still_reports(self):
        self.cfg['methodology'].update(serialDelivery=True, maxInProgress=1)
        self.transitions((7, 'QA', iso(100)))
        out = self.run_next([item(8, 'FX-002: b', 'In review'), item(7, 'FX-001: a', 'QA')])
        self.assertIn('WAIT', out)
        self.assertIn('STALE QA: #7 in QA for 4d', out)

    def test_report_stays_board_wide_under_spec_filter(self):
        self.transitions((7, 'QA', iso(100)))
        cfg, data = self.dir / 'project.json', self.dir / 'items.json'
        cfg.write_text(json.dumps(self.cfg))
        data.write_text(json.dumps(dict(items=[item(7, 'TT-001: other', 'QA')])))
        env = dict(os.environ, SPEC_WORKFLOW_REPO_ROOT=str(self.dir))
        r = subprocess.run([sys.executable, str(NEXT), str(cfg), '', str(data), 'core'],
                           capture_output=True, text=True, cwd=self.dir, env=env)
        self.assertIn('STALE QA: #7 in QA for 4d', r.stdout)

    # #560/#563 paths: the report prints wherever next stops, and #560's output stays.
    def test_prints_after_over_wip_refusal(self):
        (self.dir / '.claude' / 'over-wip.json').write_text(
            json.dumps({'main#8': {'reason': 'human override', 'ts': iso(0)}}))
        self.transitions((7, 'QA', iso(100)))
        out = self.run_next([item(7, 'FX-001: a', 'QA'), item(8, 'FX-002: b', 'In progress'),
                             item(9, 'FX-003: c', 'In progress'), item(10, 'FX-004: d', 'Backlog')])
        self.assertIn('OVER WIP 2/1: #8 (human override)', out)
        self.assertIn('=> RESUME: #8', out)
        self.assertNotIn('=> PICK', out)
        self.assertIn('STALE QA: #7 in QA for 4d', out)

    def test_prints_when_split_in_progress_pool_is_full(self):
        self.cfg['methodology']['wipLimits'] = dict(inProgress=1, inReview=1)
        self.transitions((7, 'QA', iso(100)))
        out = self.run_next([item(7, 'FX-001: a', 'QA'), item(8, 'FX-002: b', 'In progress'),
                             item(10, 'FX-004: d', 'Backlog')])
        self.assertIn('=> RESUME: #8', out)
        self.assertIn('STALE QA: #7 in QA for 4d', out)

    def test_prints_with_full_in_review_warning_and_pick(self):
        self.cfg['methodology']['wipLimits'] = dict(inProgress=1, inReview=1)
        self.transitions((7, 'QA', iso(100)))
        out = self.run_next([item(7, 'FX-001: a', 'QA'), item(8, 'FX-002: b', 'In review'),
                             item(10, 'FX-004: d', 'Backlog')])
        self.assertIn('WARN: In review 1/1 is at its limit', out)
        self.assertIn('=> PICK: #10', out)
        self.assertIn('STALE QA: #7 in QA for 4d', out)


if __name__ == '__main__':
    unittest.main()
