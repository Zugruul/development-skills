"""Real disposable Git repositories exercise #285's public startup/advisory commands."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1]
SCRIPTS = PLUGIN / 'scripts'


class CheckoutPreflight(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='checkout-285-')
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.root = self.base / 'consumer with spaces'
        self.root.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('GIT_', 'SPEC_WORKFLOW_', 'BOARD_'))
                    and k not in ('PROJECT_CONFIG', 'CLAUDE_PLUGIN_ROOT')}
        self.env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.test',
                        GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.test',
                        PYTHONDONTWRITEBYTECODE='1', SPEC_WORKFLOW_CACHE_SEARCH_BASE=str(self.base / 'cache'))
        self.git('init', '-q', '-b', 'main')
        (self.root / 'tracked').write_text('base\n')
        (self.root / 'deleted').write_text('delete me\n')
        (self.root / 'renamed').write_text('rename me\n')
        (self.root / '.gitignore').write_text('ignored/\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')

    def run_cmd(self, *args, cwd=None, check=False):
        return subprocess.run(args, cwd=cwd or self.root, env=self.env,
                              capture_output=True, check=check, timeout=30)

    def git(self, *args, cwd=None, check=True):
        return self.run_cmd('git', *args, cwd=cwd, check=check)

    def snapshot(self, root=None):
        root = root or self.root
        index = Path(os.fsdecode(self.git('rev-parse', '--git-path', 'index', cwd=root).stdout.rstrip(b'\n')))
        if not index.is_absolute():
            index = root / index
        files = {}
        for directory, dirs, names in os.walk(root):
            dirs[:] = [d for d in dirs if d != '.git']
            for name in names:
                path = Path(directory) / name
                if name != '.git':
                    files[str(path.relative_to(root))] = (('symlink', os.readlink(path))
                                                         if path.is_symlink() else ('file', path.read_bytes()))
        return (self.git('rev-parse', 'HEAD', cwd=root).stdout,
                index.read_bytes(), index.stat().st_mtime_ns,
                files, self.git('stash', 'list', cwd=root).stdout)

    def inspect(self, *args, cwd=None, expected=0):
        result = self.run_cmd('bash', str(SCRIPTS / 'checkout-preflight.sh'), *args, cwd=cwd)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        decision = json.loads(result.stdout)
        self.assertEqual(decision['status'], {0: 'clean', 1: 'dirty', 2: 'uninspectable'}[expected])
        self.assertEqual(len(result.stdout.splitlines()), 1, 'paths must be escaped on one JSON line')
        return decision

    def advisory(self, *args, cwd=None):
        result = self.run_cmd('bash', str(SCRIPTS / 'preflight.sh'), *args, cwd=cwd)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.decode()

    def add_config(self):
        (self.root / '.neural-network').mkdir()
        shutil.copyfile(PLUGIN / 'tests/fixtures/valid.project.json', self.root / '.neural-network/project.json')
        (self.root / 'SPEC.md').touch()
        self.run_cmd('bash', str(SCRIPTS / 'gitignore-sync.sh'), str(self.root / '.gitignore'), check=True)
        self.git('add', '.')
        self.git('commit', '-qm', 'config')

    def test_clean_ignored_and_unborn(self):
        (self.root / 'ignored').mkdir()
        (self.root / 'ignored/runtime').write_text('ignored')
        before = self.snapshot()
        decision = self.inspect('--checkout', 'main')
        self.assertEqual(decision['root'], str(self.root))
        self.assertEqual((decision['action'], decision['changes']), ('proceed', []))
        self.assertEqual(before, self.snapshot())
        unborn = self.base / 'unborn'
        unborn.mkdir()
        self.git('init', '-q', cwd=unborn)
        self.inspect(cwd=unborn)

    def test_all_changes_and_weird_filenames_preserve_state_and_stash(self):
        (self.root / 'tracked').write_text('stash material\n')
        self.git('stash', 'push', '-qm', 'existing user stash')
        (self.root / 'tracked').write_text('staged\n')
        self.git('add', 'tracked')
        (self.root / 'tracked').write_text('unstaged\n')
        (self.root / 'deleted').unlink()
        self.git('mv', 'renamed', 'renamed\nwith tab\t')
        unusual = 'untracked\n\t";$(touch SHOULD_NOT_EXIST)'
        (self.root / unusual).write_text('human data')
        byte_name = os.fsdecode(b'invalid-utf8-\xff')
        (self.root / byte_name).touch()
        self.git('config', 'status.showUntrackedFiles', 'no')
        before = self.snapshot()
        decision = self.inspect('--checkout', 'worktree', expected=1)
        self.assertEqual(decision['action'], 'isolate')
        changes = {c['path']: c for c in decision['changes']}
        self.assertEqual(changes['tracked']['status'], 'MM')
        self.assertEqual(changes['deleted']['status'], ' D')
        self.assertEqual(changes['renamed\nwith tab\t']['source'], 'renamed')
        self.assertEqual(changes[unusual]['status'], '??')
        self.assertIn(byte_name, changes)
        again = self.inspect('--checkout', 'worktree', expected=1)
        self.assertEqual(decision, again)
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.root / 'SHOULD_NOT_EXIST').exists())

    def test_unmerged_paths_are_dirty_and_unchanged(self):
        self.git('checkout', '-qb', 'other')
        (self.root / 'tracked').write_text('other\n')
        self.git('commit', '-qam', 'other')
        self.git('checkout', '-q', 'main')
        (self.root / 'tracked').write_text('main\n')
        self.git('commit', '-qam', 'main')
        self.assertNotEqual(self.git('merge', 'other', check=False).returncode, 0)
        before = self.snapshot()
        decision = self.inspect(expected=1)
        self.assertIn({'path': 'tracked', 'status': 'UU'}, decision['changes'])
        self.assertEqual(before, self.snapshot())

    def test_staged_and_unstaged_type_changes_are_dirty(self):
        (self.root / 'tracked').unlink()
        (self.root / 'tracked').symlink_to('nonexistent target')
        for staged in (False, True):
            with self.subTest(staged=staged):
                if staged:
                    self.git('add', 'tracked')
                before = self.snapshot()
                decision = self.inspect('--checkout', 'worktree', expected=1)
                self.assertEqual(decision['action'], 'isolate')
                self.assertIn({'path': 'tracked', 'status': 'T ' if staged else ' T'}, decision['changes'])
                self.assertEqual(before, self.snapshot())

    def test_submodule_preferences_cannot_hide_changes(self):
        source = self.base / 'sub-source'
        self.git('clone', '-q', str(self.root), str(source))
        self.git('-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', str(source), 'module')
        self.git('commit', '-qam', 'submodule')
        self.git('config', 'diff.ignoreSubmodules', 'all')
        self.git('config', 'submodule.module.ignore', 'all')
        self.git('config', 'status.showUntrackedFiles', 'no')
        self.git('config', 'status.showUntrackedFiles', 'no', cwd=self.root / 'module')
        for kind in ('untracked', 'tracked', 'commit'):
            with self.subTest(kind=kind):
                if kind == 'untracked':
                    (self.root / 'module/new').write_text('untracked')
                elif kind == 'tracked':
                    (self.root / 'module/new').unlink()
                    (self.root / 'module/tracked').write_text('changed')
                else:
                    self.git('commit', '-qam', 'new submodule commit', cwd=self.root / 'module')
                before, sub_before = self.snapshot(), self.snapshot(self.root / 'module')
                decision = self.inspect(expected=1)
                self.assertIn('module', [c['path'] for c in decision['changes']])
                self.assertEqual(before, self.snapshot())
                self.assertEqual(sub_before, self.snapshot(self.root / 'module'))

    def test_actual_linked_checkout_and_explicit_root_override_shared_root(self):
        lane = self.base / 'clean lane'
        self.git('worktree', 'add', '-qb', 'lane', str(lane), 'main')
        (self.root / 'tracked').write_text('primary is dirty')
        self.env['SPEC_WORKFLOW_REPO_ROOT'] = str(self.root)
        self.env['GIT_DIR'] = str(self.root / '.git')
        self.env['GIT_WORK_TREE'] = str(self.root)
        decision = self.inspect(cwd=lane)
        self.assertEqual(decision['root'], str(lane))
        decision = self.inspect('--root', str(lane))
        self.assertEqual(decision['root'], str(lane))

    def test_inspection_errors_fail_closed_without_mutation(self):
        index = self.root / '.git/index'
        index.write_bytes(b'invalid index contents')
        before = self.snapshot()
        decision = self.inspect('--checkout', 'worktree', expected=2)
        self.assertEqual(decision['action'], 'stop')
        self.assertTrue(decision['error'])
        self.assertEqual(before, self.snapshot())
        self.inspect('--root', str(self.base / 'missing'), expected=2)
        self.inspect('--root', str(self.base), expected=2)

    def test_failed_status_and_malformed_output_are_not_clean(self):
        real_git = shutil.which('git')
        binary = self.base / 'bin'
        binary.mkdir()
        fake = binary / 'git'
        for body in ('echo status-unavailable >&2; exit 73', "printf 'malformed'; exit 0"):
            with self.subTest(body=body):
                fake.write_text('#!/bin/bash\ncase " $* " in\n*" status "*) ' + body + ' ;;\nesac\nexec "' + real_git + '" "$@"\n')
                fake.chmod(0o755)
                self.env['PATH'] = str(binary) + os.pathsep + os.environ['PATH']
                before = self.snapshot()
                decision = self.inspect(expected=2)
                self.assertEqual(decision['action'], 'stop')
                self.assertTrue(decision['error'])
                self.assertEqual(before, self.snapshot())

    def test_dirty_decision_requires_authorization_and_preserves_main_only(self):
        (self.root / 'tracked').write_text('pre-existing changes')
        before = self.snapshot()
        self.assertEqual(self.inspect(expected=1)['action'], 'pause')
        self.assertEqual(self.inspect('--checkout', 'main', expected=1)['action'], 'pause')
        self.assertEqual(self.inspect('--checkout', 'worktree', expected=1)['action'], 'isolate')
        self.assertEqual(before, self.snapshot())

    def test_authorized_isolation_uses_remote_main_without_switching_dirty_checkout(self):
        remote = self.base / 'remote.git'
        self.git('clone', '-q', '--bare', str(self.root), str(remote))
        self.git('remote', 'add', 'origin', str(remote))
        writer = self.base / 'writer'
        self.git('clone', '-q', str(remote), str(writer))
        (writer / 'remote-new').write_text('latest main')
        self.git('add', '.', cwd=writer)
        self.git('commit', '-qm', 'advance remote', cwd=writer)
        self.git('push', '-q', 'origin', 'main', cwd=writer)
        self.git('checkout', '-qb', 'human-branch')
        (self.root / 'tracked').write_text('preserve the human edit')
        before = self.snapshot()
        decision = self.inspect('--checkout', 'worktree', expected=1)
        self.assertEqual(decision['action'], 'isolate')
        self.git('fetch', 'origin', 'main')
        lane = self.base / 'orchestration lane'
        self.git('worktree', 'add', '--detach', str(lane), 'origin/main')
        self.assertEqual(self.inspect('--root', str(lane))['action'], 'proceed')
        self.assertTrue((lane / 'remote-new').exists())
        self.assertEqual(before, self.snapshot())
        self.assertEqual(self.git('branch', '--show-current').stdout.strip(), b'human-branch')

    def test_authorized_isolation_without_remote_uses_local_main(self):
        (self.root / 'tracked').write_text('preserve')
        before = self.snapshot()
        self.assertEqual(self.inspect('--checkout', 'worktree', expected=1)['action'], 'isolate')
        lane = self.base / 'local lane'
        self.git('worktree', 'add', '--detach', str(lane), 'main')
        self.inspect(cwd=lane)
        self.assertEqual(before, self.snapshot())

    def test_advisory_surfaces_decision_and_preserves_freshness_checks(self):
        self.add_config()
        (self.root / 'tracked').write_text('unowned edit')
        for mode in ((), ('--spec',)):
            with self.subTest(mode=mode):
                before = self.snapshot()
                out = self.advisory(*mode)
                self.assertIn('CHECKOUT ACTION REQUIRED', out)
                self.assertIn('"status": "dirty"', out)
                self.assertNotIn('PREFLIGHT FAIL', out)
                self.assertEqual(before, self.snapshot())
        (self.root / '.gitignore').write_text('stale block missing')
        out = self.advisory()
        self.assertIn('CHECKOUT ACTION REQUIRED', out)
        self.assertIn('PREFLIGHT FAIL: missing/stale managed block', out)

    def test_advisory_unknown_is_failure_and_clean_linked_checkout_is_allowed(self):
        self.add_config()
        lane = self.base / 'lane'
        self.git('worktree', 'add', '-qb', 'lane', str(lane), 'main')
        (self.root / 'tracked').write_text('primary edit')
        out = self.advisory('--spec', cwd=lane)
        self.assertNotIn('CHECKOUT ACTION REQUIRED', out)
        self.assertNotIn('PREFLIGHT FAIL', out)
        (self.root / '.git/index').write_bytes(b'broken')
        out = self.advisory()
        self.assertIn('PREFLIGHT FAIL: checkout uninspectable', out)
        self.assertNotIn('preflight ok:', out)

    def test_skill_startup_order_and_isolation_contract(self):
        build = (PLUGIN / 'skills/build-next/SKILL.md').read_text()
        preflight = build.split('## Preflight (every iteration)', 1)[1].split('## Iteration', 1)[0]
        self.assertLess(preflight.index('checkout-preflight.sh'), preflight.index('git switch'))
        self.assertLess(preflight.index('Checkout question'), preflight.index('git switch'))
        for instruction in ('--checkout', 'isolate', 'main-only', 'git fetch', 'git worktree add --detach', 'point-in-time'):
            self.assertIn(instruction, build)
        implement = (PLUGIN / 'skills/implement-task/SKILL.md').read_text()
        self.assertIn('checkout-preflight.sh', implement)
        self.assertIn('verified base', implement)


if __name__ == '__main__':
    unittest.main()
