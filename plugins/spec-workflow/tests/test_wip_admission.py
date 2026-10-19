"""Mutation-boundary WIP contracts: real board entrypoints, isolated remote state."""
import copy
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import time
import unittest
import test_checkpoint as fixture

SCRIPTS = fixture.SCRIPTS


class WipAdmissionTests(unittest.TestCase):
    setUp = fixture.CheckpointTests.setUp
    save = fixture.CheckpointTests.save
    run_cmd = fixture.CheckpointTests.run_cmd
    board = fixture.CheckpointTests.board

    def state(self, statuses, numbers=None):
        numbers = numbers or [239 + i for i in range(len(statuses))]
        self.items.write_text(json.dumps({'items': [dict(id=f'ITEM{n}', status=s, content={'number': n})
                                                   for s, n in zip(statuses, numbers)]}))

    def settings(self, limit=1, serial=False):
        self.cfg['methodology'].update(maxInProgress=limit, serialDelivery=serial)
        self.save()

    def reset_effects(self):
        for path in (self.calls, self.telemetry, self.queue):
            path.unlink(missing_ok=True)

    def refused(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('WIP', result.stdout)
        self.assertNotIn('item-edit', self.calls.read_text() if self.calls.exists() else '')
        self.assertFalse(self.telemetry.exists())
        self.assertFalse(self.queue.exists())

    def test_plain_default_explicit_and_over_capacity(self):
        self.cfg['methodology'].pop('maxInProgress', None)
        self.save()
        self.state(['Backlog', 'In progress'])
        self.refused(self.board('move', '239', 'In progress'))
        self.settings(2)
        result = self.board('move', '239', 'In progress')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.reset_effects()
        self.state(['Backlog', 'In progress', 'In progress'])
        self.refused(self.board('move', '239', 'In progress'))
        self.settings(1)
        self.refused(self.board('move', '239', 'In progress'))

    def test_occupancy_modes_reentry_and_unnumbered_items(self):
        for serial, target, others, allowed in (
                (False, 'Backlog', ['In review'], True),
                (True, 'Backlog', ['In review'], False),
                (False, 'In review', ['In progress'], False),
                (False, 'In progress', ['In progress', 'In progress'], True),
                (True, 'In review', ['In progress', 'In review'], True)):
            with self.subTest(serial=serial, target=target, others=others):
                self.reset_effects()
                self.settings(1, serial)
                self.state([target] + others)
                result = self.board('move', '239', 'In progress')
                if allowed:
                    self.assertEqual(result.returncode, 0, result.stdout)
                else:
                    self.refused(result)
        self.reset_effects()
        self.state(['Backlog', 'In progress'], [239, None])
        self.refused(self.board('move', '239', 'In progress'))

    def test_serial_direct_review_and_work_to_review(self):
        board = self.cfg['boards'][0]
        board['statusFlow'][2] = 'Reviewing'
        board['fields']['status']['options']['Reviewing'] = 'review-option'
        self.settings(1, True)
        self.state(['Backlog', 'Reviewing'])
        self.refused(self.board('move', '239', 'Reviewing'))
        self.state(['In progress', 'Reviewing'])
        result = self.board('move', '239', 'Reviewing')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_board_selection_normalization_and_single_status(self):
        first = self.cfg['boards'][0]
        first['statusFlow'][1] = 'Active Work'
        first['fields']['status']['options']['Active Work'] = 'active'
        second = copy.deepcopy(first)
        second.update(id='second', projectNumber=99, projectId='SECOND')
        second['statusFlow'][1] = 'Coding'
        second['fields']['status']['options']['Coding'] = 'coding'
        self.cfg['boards'].append(second)
        self.settings()
        for bid, work in (('', 'Active Work'), ('unknown', 'Active Work'), ('second', 'Coding')):
            with self.subTest(board=bid):
                self.reset_effects()
                self.env['BOARD'] = bid
                self.state(['Backlog', work])
                self.refused(self.board('move', '239', '  ' + work.upper().replace(' ', '   ') + '  '))
        self.env['BOARD'] = ''
        first['statusFlow'] = ['Backlog']
        self.save()
        self.state(['Elsewhere', 'Backlog'])
        self.reset_effects()
        self.refused(self.board('move', '239', 'Backlog'))

    def test_counted_option_id_aliases_fail_before_mutation(self):
        baseline = copy.deepcopy(self.cfg)
        for counted, serial, in_flow in (('In progress', False, False),
                                         ('In progress', False, True),
                                         ('In review', True, False),
                                         ('In review', True, True)):
            with self.subTest(counted=counted, in_flow=in_flow):
                self.cfg = copy.deepcopy(baseline)
                board = self.cfg['boards'][0]
                board['fields']['status']['options']['Running'] = board['fields']['status']['options'][counted]
                if in_flow:
                    board['statusFlow'].append('Running')
                self.settings(1, serial)
                self.state(['Backlog', counted])
                self.reset_effects()
                self.refused(self.board('move', '239', 'Running'))
                result = self.run_cmd(sys.executable, str(SCRIPTS / 'next.py'), str(self.path), '', str(self.items))
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('WIP', result.stdout)
                self.assertIn('option', result.stdout.lower())
        # Work and review are distinct counted statuses in serial mode; sharing
        # one ID is ambiguous even without an extra alias outside statusFlow.
        self.cfg = copy.deepcopy(baseline)
        opts = self.cfg['boards'][0]['fields']['status']['options']
        opts['In review'] = opts['In progress']
        self.settings(1, True)
        self.state(['In progress'])
        self.reset_effects()
        self.refused(self.board('move', '239', 'In progress'))

    def test_counted_normalized_option_labels_must_be_unambiguous(self):
        baseline = copy.deepcopy(self.cfg)
        for counted, duplicate, serial in (('In progress', '  IN   PROGRESS ', False),
                                            ('In review', ' in   REVIEW ', True)):
            for same_id in (False, True):
                with self.subTest(counted=counted, same_id=same_id):
                    self.cfg = copy.deepcopy(baseline)
                    opts = self.cfg['boards'][0]['fields']['status']['options']
                    opts[duplicate] = opts[counted] if same_id else 'different-option'
                    self.settings(1, serial)
                    self.state(['In progress'])
                    self.reset_effects()
                    self.refused(self.board('move', '239', 'Backlog'))

    def test_queued_counted_option_alias_is_retained(self):
        opts = self.cfg['boards'][0]['fields']['status']['options']
        opts['Running'] = opts['In progress']
        self.settings()
        self.state(['Backlog', 'In progress'])
        line = json.dumps({'op': 'move', 'issue': '239', 'status': 'Running'}) + '\n'
        self.queue.write_text(line)
        result = self.board('flush')
        self.assertIn('WIP', result.stdout)
        self.assertEqual(self.queue.read_text(), line)
        self.assertNotIn('item-edit', self.calls.read_text())
        self.assertFalse(self.telemetry.exists())

    def test_live_identity_ignores_cache_and_never_retargets_retry(self):
        self.settings(2)
        self.state(['Backlog'])
        result = self.board('move', '239', 'In progress')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('--id ITEM239 ', self.calls.read_text())
        self.assertNotIn('--id ITEM ', self.calls.read_text())
        self.reset_effects()
        gh = self.root / 'bin/gh'
        gh.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$CALLS"
case "$1 $2" in
 "project item-list") cat "$ITEMS" ;;
 "project item-edit") echo '{"239":{"itemId":"WRONG","status":"Backlog"}}' > .claude/board-cache.json; echo "fake edit failure" >&2; exit 1 ;;
 "api rate_limit") echo '{"resources":{"graphql":{"remaining":100}}}' ;;
esac
''')
        result = self.board('move', '239', 'In progress')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn('--id WRONG', self.calls.read_text())
        self.assertEqual(self.calls.read_text().count('project item-edit'), 1)
        self.assertFalse(self.telemetry.exists())

    def test_missing_ambiguous_malformed_and_incomplete_snapshots(self):
        self.settings()
        valid = {'id': 'ITEM239', 'status': 'Backlog', 'content': {'number': 239}}
        payloads = [None, {}, {'items': None}, {'items': {}}, {'items': []},
                    {'items': [valid, dict(valid, id='OTHER')]},
                    {'items': [valid, {'id': 'OTHER', 'status': 42}]},
                    {'items': [valid, None]}, {'items': [dict(valid, id='')]},
                    {'items': [valid], 'totalCount': 2}, {'items': [valid], 'totalCount': '1'},
                    {'items': [valid, dict(valid, content={'number': 240})]}]
        for payload in payloads:
            with self.subTest(payload=payload):
                self.reset_effects()
                self.items.write_text(json.dumps(payload))
                self.refused(self.board('move', '239', 'In progress'))
        self.items.write_text('{broken')
        self.refused(self.board('move', '239', 'In progress'))
        self.reset_effects()
        self.state(['Backlog'])
        self.env.update(PAGINATE_BASE_LIMIT='1', PAGINATE_HARD_CAP='1')
        self.refused(self.board('move', '239', 'In progress'))

    def test_invalid_policy_fails_closed(self):
        for key, values in (('maxInProgress', [0, -1, True, None, '2', 1.5]),
                            ('serialDelivery', [0, 1, None, 'false', []])):
            for value in values:
                with self.subTest(key=key, value=value):
                    self.settings()
                    self.cfg['methodology'][key] = value
                    self.save()
                    self.refused(self.board('move', '239', 'In progress'))
                    result = self.run_cmd(sys.executable, str(SCRIPTS / 'next.py'), str(self.path), '', str(self.items))
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn('WIP', result.stdout)

    def test_queue_capacity_retention_unrelated_replay_and_recovery(self):
        self.settings()
        self.state(['Backlog', 'In progress'])
        start = {'op': 'move', 'issue': '239', 'status': 'In progress'}
        self.queue.write_text(json.dumps(start) + '\n' + json.dumps({'op': 'prio', 'issue': '240', 'priority': 'P0'}) + '\n')
        result = self.board('flush')
        self.assertIn('WIP', result.stdout)
        self.assertEqual([json.loads(x) for x in self.queue.read_text().splitlines()], [start])
        self.assertNotIn('moved #239', result.stdout)
        self.assertIn('prio #240', result.stdout)
        self.assertFalse(self.telemetry.exists())
        self.state(['Backlog', 'Backlog'])
        result = self.board('flush')
        self.assertIn('moved #239', result.stdout)
        self.assertFalse(self.queue.exists() and self.queue.read_text().strip())

    def test_transport_failure_rate_limit_and_replay_recheck(self):
        gh = self.root / 'bin/gh'
        original = gh.read_text()
        for message, queued in (('fake network failure', False), ('API rate limit exceeded', True)):
            with self.subTest(message=message):
                self.reset_effects()
                gh.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$CALLS"\n'
                              + 'if [[ "$1 $2" == "project item-list" ]]; then echo "' + message + '" >&2; exit 1; fi\n'
                              + 'if [[ "$1 $2" == "api rate_limit" ]]; then echo \'{"resources":{"graphql":{"remaining":100,"reset":1}}}\'; exit 0; fi\nexit 1\n')
                result = self.board('move', '239', 'In progress')
                self.assertEqual(self.queue.exists(), queued, result.stdout)
                self.assertNotIn('item-edit', self.calls.read_text())
                self.assertFalse(self.telemetry.exists())
                if not queued:
                    self.assertNotEqual(result.returncode, 0)
        gh.write_text(original)
        self.settings()
        self.state(['Backlog', 'In progress'])
        result = self.board('flush')
        self.assertIn('WIP', result.stdout)
        self.assertTrue(self.queue.read_text().strip())

    def test_replay_repeat_requires_complete_unambiguous_live_identity(self):
        self.settings()
        self.state(['In progress'])
        start = json.dumps({'op': 'move', 'issue': '239', 'status': 'In progress'}) + '\n'
        self.queue.write_text(start)
        result = self.board('flush')
        self.assertIn('skip move #239', result.stdout)
        self.assertNotIn('item-edit', self.calls.read_text())
        valid = json.loads(self.items.read_text())['items'][0]
        for payload in ({'items': [valid, dict(valid, id='OTHER')]},
                        {'items': [valid], 'totalCount': 2},
                        {'items': [valid, {'id': 'OTHER', 'status': 123}] }):
            with self.subTest(payload=payload):
                self.reset_effects()
                self.items.write_text(json.dumps(payload))
                self.queue.write_text(start)
                result = self.board('flush')
                self.assertIn('WIP', result.stdout)
                self.assertEqual(self.queue.read_text(), start)
                self.assertNotIn('skip move', result.stdout)
                self.assertNotIn('item-edit', self.calls.read_text())
        self.reset_effects()
        self.state(['In progress'])
        self.cfg['methodology']['maxInProgress'] = True
        self.save()
        self.queue.write_text(start)
        result = self.board('flush')
        self.assertIn('WIP', result.stdout)
        self.assertEqual(self.queue.read_text(), start)

    def test_checkpoint_appearing_during_lock_wait(self):
        self.settings()
        self.state(['Backlog'])
        lock = self.root / '.claude/board-wip.lock'
        lock.mkdir()
        logpath = self.root / 'waiting.log'
        with logpath.open('w') as log:
            child = subprocess.Popen(['bash', str(SCRIPTS / 'board.sh'), 'move', '239', 'In progress'],
                                     cwd=self.root, env=self.env, stdout=log, stderr=subprocess.STDOUT)
            try:
                self.wait_for(lambda: 'WIP: waiting' in logpath.read_text(), 'lock wait', [child])
                self.flag.touch()
                lock.rmdir()
                self.assertEqual(child.wait(timeout=15), 1)
                self.assertIn('CHECKPOINT', logpath.read_text())
                self.assertFalse(self.calls.exists())
                self.assertFalse(self.queue.exists())
                self.assertFalse(self.telemetry.exists())
                self.assertFalse(lock.exists())
            finally:
                if child.poll() is None: child.kill()
                child.wait(timeout=15)

    def test_release_capacity_and_existing_guards(self):
        self.settings()
        self.state(['In progress', 'In progress'])
        result = self.board('move', '239', 'Backlog')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.reset_effects()
        result = self.board('move', '239', 'In review')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('item-edit', self.calls.read_text() if self.calls.exists() else '')
        self.flag.touch()
        result = self.board('move', '239', 'In progress')
        self.assertIn('CHECKPOINT', result.stdout)

    def wait_for(self, predicate, label, children):
        deadline = time.monotonic() + 15
        while not predicate():
            for child in children:
                self.assertIsNone(child.poll(), label + ': child ended early')
            self.assertLess(time.monotonic(), deadline, label)
            time.sleep(.01)

    def test_signal_keeps_mutex_until_remote_child_finishes(self):
        self.settings()
        self.state(['Backlog'])
        gh = self.root / 'bin/gh'
        gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, signal, sys, time
root = pathlib.Path(os.environ['ITEMS']).parent
args = sys.argv[1:]
if args[:2] == ['project', 'item-list']: print((root / 'items.json').read_text())
elif args[:2] == ['project', 'item-edit']:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    (root / 'edit.ready').write_text(str(os.getpid()))
    deadline = time.monotonic() + 15
    while not (root / 'edit.go').exists():
        if time.monotonic() > deadline: sys.exit('edit barrier timed out')
        time.sleep(.01)
    (root / 'edit.done').touch()
else: sys.exit('unexpected gh')
''')
        lock = self.root / '.claude/board-wip.lock'
        with (self.root / 'signal.log').open('w') as log:
            child = subprocess.Popen(['bash', str(SCRIPTS / 'board.sh'), 'move', '239', 'In progress'],
                                     cwd=self.root, env=self.env, stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            try:
                self.wait_for(lambda: (self.root / 'edit.ready').exists(), 'remote mutation', [child])
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=10)
                # The remote child explicitly ignores TERM and has not reached
                # its barrier release: ownership must survive the caller exit.
                self.assertFalse((self.root / 'edit.done').exists())
                self.assertTrue(lock.exists(), 'released mutex while mutation still live')
                (self.root / 'edit.go').touch()
                self.wait_for(lambda: (self.root / 'edit.done').exists() and not lock.exists(),
                              'signal cleanup after child completion', [])
            finally:
                (self.root / 'edit.go').touch()
                if child.poll() is None: child.kill()
                child.wait(timeout=15)

    def test_simultaneous_linked_worktree_last_slot_and_failure_cleanup(self):
        self.settings()
        self.state(['Backlog', 'Backlog'])
        (self.root / '.claude/board-comments-seen.json').write_text('{"239":true,"240":true}')
        for args in (('init',), ('add', '.neural-network'), ('commit', '-m', 'fixture'),
                     ('worktree', 'add', '-b', 'linked', str(self.root / 'linked'))):
            result = self.run_cmd('git', *args)
            self.assertEqual(result.returncode, 0, result.stdout)
        gh = self.root / 'bin/gh'
        gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['ITEMS']).parent
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as out: out.write(' '.join(args) + '\\n')
if args[:2] == ['project', 'item-list']:
    if not (root / 'read.ready').exists():
        (root / 'read.ready').touch()
        deadline = time.monotonic() + 15
        while not (root / 'read.go').exists():
            if time.monotonic() > deadline: sys.exit('barrier timed out')
            time.sleep(.01)
    print((root / 'items.json').read_text())
elif args[:2] == ['project', 'item-edit']:
    data = json.loads((root / 'items.json').read_text())
    for item in data['items']:
        if item['id'] == args[args.index('--id')+1]: item['status'] = 'In progress'
    (root / 'items.json').write_text(json.dumps(data))
else: sys.exit('unexpected gh')
''')
        logs = [open(self.root / f'p{i}.log', 'w+') for i in range(2)]
        children = []
        try:
            children.append(subprocess.Popen(['bash', str(SCRIPTS / 'board.sh'), 'move', '239', 'In progress'], cwd=self.root, env=self.env, stdout=logs[0], stderr=subprocess.STDOUT))
            self.wait_for(lambda: (self.root / 'read.ready').exists(), 'first snapshot', children)
            children.append(subprocess.Popen(['bash', str(SCRIPTS / 'board.sh'), 'move', '240', 'In progress'], cwd=self.root / 'linked', env=self.env, stdout=logs[1], stderr=subprocess.STDOUT))
            self.wait_for(lambda: 'WIP: waiting' in (self.root / 'p1.log').read_text(), 'second waits on shared mutex', children)
            self.assertEqual(self.calls.read_text().count('project item-list'), 1)
            (self.root / 'read.go').touch()
            results = [p.wait(timeout=15) for p in children]
            self.assertEqual(results, [0, 1], [(self.root / f'p{i}.log').read_text() for i in range(2)])
            self.assertEqual(self.calls.read_text().count('project item-edit'), 1)
            self.assertFalse((self.root / '.claude/board-wip.lock').exists())
            result = self.board('move', '240', 'In progress')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('waiting', result.stdout)
            self.assertFalse((self.root / '.claude/board-wip.lock').exists())
        finally:
            (self.root / 'read.go').touch()
            for p in children:
                if p.poll() is None: p.kill()
                p.wait(timeout=15)
            for log in logs: log.close()


if __name__ == '__main__':
    unittest.main()
