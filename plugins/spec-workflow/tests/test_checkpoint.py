"""Checkpoint admission through public commands, with hermetic git/gh fixtures."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
FIX = Path(__file__).resolve().parent / "fixtures"


class CheckpointTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / ".neural-network").mkdir()
        (self.root / ".claude").mkdir()
        self.cfg = json.loads((FIX / "valid.project.json").read_text())
        self.path = self.root / ".neural-network/project.json"
        self.save()
        self.flag = self.root / ".claude/CHECKPOINT"
        self.calls = self.root / "calls"
        self.queue = self.root / ".claude/board-queue.jsonl"
        self.telemetry = self.root / ".claude/telemetry.jsonl"
        self.items = self.root / "items.json"
        self.items.write_text(json.dumps({"items": [{"id": "ITEM", "status": "Backlog", "title": "fix", "content": {"number": 239}}]}))
        (self.root / ".claude/board-comments-seen.json").write_text('{"239":true}')
        (self.root / ".claude/board-cache.json").write_text('{"239":{"itemId":"ITEM","status":"Backlog"}}')
        self.env = dict(os.environ)
        for key in tuple(self.env):
            if key.startswith(('BOARD_', 'SPEC_WORKFLOW_')) or key == 'PROJECT_CONFIG':
                self.env.pop(key)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$CALLS"
case "$1 $2" in
  "project item-list") cat "$ITEMS" ;;
  "project item-edit") echo edited ;;
  *) echo "unexpected fake gh call: $*" >&2; exit 1 ;;
esac
''')
        gh.chmod(0o755)
        self.env.update(PATH=str(bin_dir) + os.pathsep + self.env['PATH'],
                        CALLS=str(self.calls), ITEMS=str(self.items),
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.test',
                        GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.test')

    def save(self):
        self.path.write_text(json.dumps(self.cfg))

    def run_cmd(self, *args, cwd=None):
        return subprocess.run(args, cwd=cwd or self.root, env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def preflight(self, *args, cwd=None):
        return self.run_cmd('bash', str(SCRIPTS / 'checkpoint-preflight.sh'), *args, cwd=cwd)

    def board(self, *args, cwd=None):
        return self.run_cmd('bash', str(SCRIPTS / 'board.sh'), *args, cwd=cwd)

    def picker(self, path=None, cwd=None):
        return self.run_cmd(sys.executable, str(SCRIPTS / 'next.py'), str(path or self.path), '', str(self.items), cwd=cwd)

    def blocked(self, result, path=None):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('CHECKPOINT', result.stdout)
        self.assertNotIn('PICK:', result.stdout)
        self.assertNotIn('RESUME:', result.stdout)
        if path:
            self.assertIn(str(path), result.stdout)
            self.assertIn('resume', result.stdout.lower())

    def quiet_board(self):
        self.assertFalse(self.calls.exists(), self.calls.read_text() if self.calls.exists() else '')
        self.assertFalse(self.telemetry.exists())

    def test_default_absent_empty_and_removal(self):
        self.cfg.pop('paths')
        self.save()
        result = self.preflight()
        self.assertEqual((result.returncode, result.stdout), (0, ''))
        self.flag.touch()
        self.blocked(self.preflight(), self.flag)
        self.flag.unlink()
        self.assertEqual(self.preflight().returncode, 0)

    def test_custom_absolute_and_legacy(self):
        for name in ('pause here/flag', str(self.root / 'absolute.flag')):
            with self.subTest(name=name):
                self.cfg['paths']['checkpointFile'] = name
                self.save()
                flag = self.root / name
                flag.parent.mkdir(parents=True, exist_ok=True)
                flag.touch()
                self.blocked(self.preflight(), flag)
                self.blocked(self.picker(), flag)
                flag.unlink()
                self.assertEqual(self.preflight().returncode, 0)

    def test_effective_config_override_and_overlay(self):
        override = self.root / 'override.yaml'
        self.cfg['schemaVersion'] = '2.0.0'
        self.cfg['paths']['checkpointFile'] = 'effective.flag'
        override.write_text(json.dumps(self.cfg))
        (self.root / 'project.local.yaml').write_text('compute: []\npaths:\n  checkpointFile: ignored.flag\n')
        self.env['PROJECT_CONFIG'] = str(override)
        flag = self.root / 'effective.flag'
        flag.touch()
        self.blocked(self.preflight(), flag)
        self.blocked(self.board('next'), flag)
        self.quiet_board()

    def test_invalid_path_shapes_fail_closed_at_all_boundaries(self):
        for paths in (None, [], 'bad', {'checkpointFile': None}, {'checkpointFile': ''},
                      {'checkpointFile': '  '}, {'checkpointFile': []}, {'checkpointFile': True},
                      {'checkpointFile': 'bad\x00path'}):
            with self.subTest(paths=paths):
                self.cfg['paths'] = paths
                self.save()
                for result in (self.preflight(), self.picker(), self.board('next'), self.board('move', '239', 'In progress')):
                    self.blocked(result)
                self.quiet_board()
                self.assertFalse(self.queue.exists())

    def test_malformed_missing_unreadable_config(self):
        self.path.write_text('{broken')
        self.blocked(self.preflight())
        self.path.unlink()
        self.env['PROJECT_CONFIG'] = str(self.path)
        self.blocked(self.preflight())
        self.path.mkdir()
        self.blocked(self.preflight())

    def test_uninspectable_state_and_dangling_flag_fail_closed(self):
        self.cfg['paths']['checkpointFile'] = 'not-directory/flag'
        self.save()
        (self.root / 'not-directory').write_text('x')
        self.blocked(self.preflight())
        self.cfg['paths']['checkpointFile'] = '.claude/CHECKPOINT'
        self.save()
        self.flag.symlink_to(self.root / 'missing-target')
        self.blocked(self.preflight(), self.flag)

    def test_direct_picker_blocks_pick_and_resume(self):
        self.flag.touch()
        for status in ('Backlog', 'In progress'):
            self.items.write_text(json.dumps({'items': [{'status': status, 'content': {'number': 239}}]}))
            self.blocked(self.picker(), self.flag)
        self.flag.unlink()
        self.assertIn('RESUME:', self.picker().stdout)

    def test_board_next_checks_before_replay_or_network(self):
        self.queue.write_text('{"op":"move","issue":"239","status":"Backlog"}\n')
        before = self.queue.read_bytes()
        self.flag.touch()
        self.blocked(self.board('next'), self.flag)
        self.assertEqual(self.queue.read_bytes(), before)
        self.quiet_board()

    def test_direct_move_refuses_before_comments_queue_and_telemetry(self):
        self.flag.touch()
        for status in ('In progress', '  IN   PROGRESS  '):
            self.blocked(self.board('move', '239', status), self.flag)
        (self.root / '.claude/board-comments-seen.json').unlink()
        self.blocked(self.board('move', '239', 'In progress'), self.flag)
        self.quiet_board()
        self.assertFalse(self.queue.exists())
        self.flag.unlink()
        result = self.board('move', '239', 'In progress')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('comments', result.stdout)

    def test_replay_retains_then_recovers_even_cached_repeat(self):
        for status in ('Backlog', 'In progress'):
            with self.subTest(cached=status):
                self.calls.unlink(missing_ok=True)
                self.telemetry.unlink(missing_ok=True)
                (self.root / '.claude/board-cache.json').write_text(json.dumps({'239': {'itemId': 'ITEM', 'status': status}}))
                self.queue.write_text('{"op":"move","issue":"239","status":"In progress"}\n')
                before = self.queue.read_bytes()
                self.flag.touch()
                result = self.board('flush')
                self.assertIn('CHECKPOINT', result.stdout)
                self.assertEqual(self.queue.read_bytes(), before)
                self.quiet_board()
                self.flag.unlink()
                result = self.board('flush')
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertFalse(self.queue.exists() and self.queue.read_text().strip())

    def test_unrelated_transition_and_existing_qa_guard(self):
        self.flag.touch()
        result = self.board('move', '239', 'Backlog')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('item-edit', self.calls.read_text())
        result = self.board('move', '239', 'QA')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('review', result.stdout)
        self.assertNotIn('CHECKPOINT', result.stdout)

    def test_advisory_and_bootstrap_contracts(self):
        self.cfg['paths']['checkpointFile'] = 'custom.flag'
        self.save()
        flag = self.root / 'custom.flag'
        flag.touch()
        for script in ('preflight.sh', 'session-start.sh'):
            result = self.run_cmd('bash', str(SCRIPTS / script))
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn(str(flag), result.stdout)
        self.path.write_text('{bad')
        for script in ('preflight.sh', 'session-start.sh'):
            result = self.run_cmd('bash', str(SCRIPTS / script))
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn('CHECKPOINT', result.stdout)
        self.path.unlink()
        self.assertEqual(self.run_cmd('bash', str(SCRIPTS / 'session-start.sh')).stdout, '')
        self.assertIn('setup-project', self.run_cmd('bash', str(SCRIPTS / 'preflight.sh')).stdout)

    def rename_work_status(self, board, name):
        old = board['statusFlow'][1]
        board['statusFlow'][1] = name
        # A real rename replaces the label; keeping the old label with the
        # same ID would be the ambiguous WIP alias rejected by #240.
        board['fields']['status']['options'][name] = board['fields']['status']['options'].pop(old)

    def test_custom_work_status_refuses_then_recovers_without_broadening_comments(self):
        self.rename_work_status(self.cfg['boards'][0], 'Doing')
        self.save()
        self.flag.touch()
        for status in ('Doing', '  DOING  '):
            self.blocked(self.board('move', '239', status), self.flag)
        self.quiet_board()
        self.assertFalse(self.queue.exists())
        self.flag.unlink()
        (self.root / '.claude/board-comments-seen.json').unlink()
        result = self.board('move', '239', 'Doing')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('item-edit', self.calls.read_text())
        result = self.board('move', '239', 'In progress')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('comments', result.stdout)

    def test_active_board_work_status_and_unknown_id_fallback(self):
        first = self.cfg['boards'][0]
        self.rename_work_status(first, 'Doing')
        second = copy.deepcopy(first)
        second['id'] = 'second'
        self.rename_work_status(second, 'Coding')
        first['fields']['status']['options']['Coding'] = 'other-option'
        second['fields']['status']['options']['Doing'] = 'other-option'
        self.cfg['boards'].append(second)
        self.save()
        self.flag.touch()
        for bid, work, other in (('', 'Doing', 'Coding'),
                                 ('second', 'Coding', 'Doing'),
                                 ('unknown-board', 'Doing', 'Coding')):
            with self.subTest(board=bid):
                self.env['BOARD'] = bid
                self.calls.unlink(missing_ok=True)
                self.telemetry.unlink(missing_ok=True)
                self.blocked(self.board('move', '239', work), self.flag)
                self.quiet_board()
                result = self.board('move', '239', other)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn('item-edit', self.calls.read_text())

    def test_custom_status_replay_retains_cached_repeat_and_recovers(self):
        self.rename_work_status(self.cfg['boards'][0], 'Doing')
        second = copy.deepcopy(self.cfg['boards'][0])
        second['id'] = 'second'
        self.rename_work_status(second, 'Coding')
        self.cfg['boards'].append(second)
        self.env['BOARD'] = 'second'
        self.save()
        for cached in ('Backlog', 'Coding'):
            with self.subTest(cached=cached):
                self.calls.unlink(missing_ok=True)
                self.telemetry.unlink(missing_ok=True)
                (self.root / '.claude/board-cache.json').write_text(json.dumps({'239': {'itemId': 'ITEM', 'status': cached}}))
                self.queue.write_text('{"op":"move","issue":"239","status":"Coding"}\n')
                before = self.queue.read_bytes()
                self.flag.touch()
                result = self.board('flush')
                self.assertIn('CHECKPOINT', result.stdout)
                self.assertEqual(self.queue.read_bytes(), before)
                self.quiet_board()
                self.flag.unlink()
                result = self.board('flush')
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertFalse(self.queue.exists() and self.queue.read_text().strip())

    def test_single_status_picker_fallback_is_also_mutation_work_status(self):
        self.cfg['boards'][0]['statusFlow'] = ['Backlog']
        self.save()
        self.flag.touch()
        self.blocked(self.board('move', '239', 'Backlog'), self.flag)
        self.quiet_board()
        self.flag.unlink()
        result = self.board('move', '239', 'Backlog')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('RESUME:', self.picker().stdout)

    def test_malformed_board_selection_and_flow_fail_closed_without_flag(self):
        board = copy.deepcopy(self.cfg['boards'][0])
        bad_boards = [None, [], 'boards', [None], [{}]]
        bad_boards += [ [dict(board, statusFlow=flow)] for flow in
                        (None, [], 'Backlog Doing', ['Backlog', None], ['Backlog', ''], ['Backlog', ' ']) ]
        for boards in bad_boards:
            with self.subTest(boards=boards):
                self.cfg['boards'] = boards
                self.save()
                for result in (self.picker(), self.board('next'), self.board('move', '239', 'Backlog')):
                    self.blocked(result)
                self.quiet_board()
                self.assertFalse(self.queue.exists())

    def test_advisory_preserves_current_tree_spec_checks(self):
        self.cfg['specs'][0]['specPath'] = 'primary-only.md'
        self.save()
        for args in (('init',), ('add', '.neural-network'), ('commit', '-m', 'fixture')):
            result = self.run_cmd('git', *args)
            self.assertEqual(result.returncode, 0, result.stdout)
        tree = self.root / 'linked'
        result = self.run_cmd('git', 'worktree', 'add', '-b', 'linked', str(tree))
        self.assertEqual(result.returncode, 0, result.stdout)
        tree_cfg = dict(self.cfg, specs=[dict(self.cfg['specs'][0], specPath='tree-only.md')])
        (tree / '.neural-network/project.json').write_text(json.dumps(tree_cfg))
        (tree / 'tree-only.md').write_text('worktree spec')
        self.flag.touch()
        result = self.run_cmd('bash', str(SCRIPTS / 'preflight.sh'), '--spec', cwd=tree)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(str(self.flag), result.stdout)
        self.assertIn('preflight ok: config + 1 spec(s) present', result.stdout)
        self.assertNotIn('spec file(s) missing', result.stdout)

    def test_linked_worktree_primary_and_explicit_root(self):
        for args in (('init',), ('add', '.neural-network'), ('commit', '-m', 'fixture')):
            result = self.run_cmd('git', *args)
            self.assertEqual(result.returncode, 0, result.stdout)
        tree = self.root / 'linked'
        result = self.run_cmd('git', 'worktree', 'add', '-b', 'linked', str(tree))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.flag.touch()
        self.blocked(self.preflight(cwd=tree), self.flag)
        self.blocked(self.picker(tree / '.neural-network/project.json', cwd=Path('/tmp')), self.flag)
        self.blocked(self.board('next', cwd=tree), self.flag)
        self.blocked(self.preflight('--root', str(self.root), cwd=Path('/tmp')), self.flag)
        other = self.root / 'other'
        (other / '.neural-network').mkdir(parents=True)
        shutil.copyfile(self.path, other / '.neural-network/project.json')
        self.env['SPEC_WORKFLOW_REPO_ROOT'] = str(other)
        self.assertEqual(self.preflight().returncode, 0)
        self.assertIn('PICK:', self.picker().stdout)
        self.blocked(self.preflight('--root', str(self.root)), self.flag)


if __name__ == '__main__':
    unittest.main()
