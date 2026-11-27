"""#553: `next <spec-id>` keeps only that spec's tasks; WIP/capacity stay board-wide."""
import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
NEXT = HERE.parent / 'scripts' / 'next.py'
BASE = json.loads((HERE / 'fixtures' / 'valid.project.json').read_text())


def item(num, title, status='Backlog', prio='P1'):
    return dict(status=status, priority=prio, title=title, content=dict(number=num, title=title))


class NextSpecFilter(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        self.cfg = copy.deepcopy(BASE)
        for sid, prefix in (('ops', 'TT'), ('cap', 'PC')):
            self.cfg['specs'].append(dict(
                id=sid, title=sid, board='main', specPath='SPEC.md', backlogPath='B.md',
                taskPrefix=prefix, epics=[
                    dict(id='E1', title='e', taskRanges=[[1, 9]]),
                    dict(id='E2', title='blocked', taskRanges=[[10, 19]],
                         blockedBy=[dict(epic='E1', untilStatus='Deployed')])]))

    def run_next(self, items, spec='', limit=1):
        self.cfg['methodology']['maxInProgress'] = limit
        cfg, data = self.dir / 'project.json', self.dir / 'items.json'
        cfg.write_text(json.dumps(self.cfg))
        data.write_text(json.dumps(dict(items=items)))
        args = [sys.executable, str(NEXT), str(cfg), '', str(data)] + ([spec] if spec else [])
        return subprocess.run(args, capture_output=True, text=True, cwd=self.dir)

    BOARD = [
        item(1, 'FX-001: mine'),
        item(2, 'TT-001: other spec', prio='P0'),
        item(3, 'PC-001: third spec', prio='P0'),
        item(4, 'BUG: untagged', prio='P0'),
    ]

    def test_filter_lists_and_picks_only_that_spec(self):
        out = self.run_next(self.BOARD, 'core').stdout
        self.assertIn('=> PICK: #1  FX-001', out)
        for stray in ('TT-001', 'PC-001'):
            self.assertNotIn(stray, out)

    def test_filter_excludes_untagged_items(self):
        out = self.run_next(self.BOARD, 'core').stdout
        self.assertNotIn('BUG: untagged', out)

    def test_other_spec_never_picked_when_own_spec_empty(self):
        out = self.run_next([item(2, 'TT-001: other spec')], 'core').stdout
        self.assertNotIn('=> PICK', out)
        self.assertNotIn('TT-001', out)
        self.assertIn('(no backlog tasks for spec core)', out)
        self.assertNotIn('(backlog empty', out)

    def test_no_filter_unchanged(self):
        out = self.run_next(self.BOARD).stdout
        self.assertIn('=> PICK: #4  BUG: untagged', out)
        for seen in ('FX-001', 'TT-001', 'PC-001'):
            self.assertIn(seen, out)

    def test_other_specs_wip_counts_toward_limit(self):
        board = self.BOARD + [item(5, 'TT-002: busy', status='In progress')]
        out = self.run_next(board, 'core').stdout
        self.assertIn('=> RESUME: #5', out)
        self.assertNotIn('=> PICK', out)

    def test_other_specs_review_counts_in_serial_mode(self):
        self.cfg['methodology']['serialDelivery'] = True
        board = self.BOARD + [item(5, 'TT-002: waiting', status='In review')]
        out = self.run_next(board, 'core').stdout
        self.assertIn('WAIT: merge-dance', out)
        self.assertNotIn('=> PICK', out)

    def test_blocked_guard_still_applies_within_spec(self):
        board = [item(1, 'FX-001: scaffold'), item(10, 'FX-010: link endpoint')]
        out = self.run_next(board, 'core').stdout
        self.assertIn('BLOCKED #10', out)

    def test_other_specs_blocked_lines_do_not_leak(self):
        board = self.BOARD + [item(10, 'TT-010: held by ops E1'), item(11, 'PC-010: held by cap E1')]
        out = self.run_next(board, 'core').stdout
        self.assertNotIn('BLOCKED', out)
        self.assertNotIn('TT-010', out)
        self.assertNotIn('PC-010', out)
        self.assertIn('BLOCKED #10 TT-010', self.run_next(board, 'ops').stdout)

    def test_unfiltered_empty_text_unchanged(self):
        self.assertIn('(backlog empty)', self.run_next([]).stdout)

    def test_unknown_spec_fails_clearly(self):
        r = self.run_next(self.BOARD, 'nope')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unknown spec 'nope'", r.stderr)
        self.assertIn('core', r.stderr)
        self.assertNotIn('=> PICK', r.stdout)


if __name__ == '__main__':
    unittest.main()
