"""Hermetic inventory contract and shared-discovery regression checks (#277)."""
import copy
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

sys.dont_write_bytecode = True
PLUGIN = Path(__file__).resolve().parents[1]
SCRIPTS = PLUGIN / 'scripts'
sys.path.insert(0, str(SCRIPTS))


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), SCRIPTS / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.scan = self.base / 'scan'
        self.scan.mkdir()
        self.current = self.base / 'current'
        self.current.mkdir()
        self.cfg = yaml.safe_load((PLUGIN / 'tests/fixtures/valid.project.yaml').read_text())
        self.cfg['schemaVersion'] = '2.0.0'

    def repo(self, name, cfg=None, filename='project.yaml'):
        repo = self.scan / name
        (repo / '.neural-network').mkdir(parents=True)
        value = copy.deepcopy(self.cfg if cfg is None else cfg)
        (repo / '.neural-network' / filename).write_text(
            json.dumps(value) if filename.endswith('.json') else yaml.safe_dump(value))
        return repo

    def run_cli(self, *args, cwd=None, env=None):
        result = subprocess.run([sys.executable, str(SCRIPTS / 'projects-list.py'), *args],
                                cwd=cwd or self.current, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def rows(self, **kw):
        return json.loads(self.run_cli('--scan', str(self.scan), '--root', str(self.current), '--json', **kw))

    def test_discovery_values_defaults_and_symlink_dedup(self):
        self.cfg['project']['name'] = 'Example'
        self.cfg['methodology'] = dict(maxInProgress=3, autoMerge=False, serialDelivery=True,
                                      feedback={'enabled': False}, iterativeUI=True)
        board = copy.deepcopy(self.cfg['boards'][0])
        board.update(id='second', projectNumber=987)
        self.cfg['boards'].append(board)
        repo = self.repo('good')
        (self.scan / 'alias').symlink_to(repo, target_is_directory=True)
        (self.scan / 'plain').mkdir()
        (self.scan / 'plain' / 'nested' / '.neural-network').mkdir(parents=True)
        (self.scan / 'marker-file').mkdir()
        (self.scan / 'marker-file' / '.neural-network').touch()
        rows = self.rows()
        self.assertEqual([r['path'] for r in rows], sorted([str(repo), str(self.current)]))
        good = next(r for r in rows if r['path'] == str(repo))
        self.assertEqual(good['name'], 'Example')
        self.assertEqual(good['schemaVersion'], '2.0.0')
        self.assertEqual(good['methodology'], dict(maxInProgress=3, autoMerge=False,
                         serialDelivery=True, feedback=False, iterativeUI=True))
        self.assertEqual(good['boards'], [{'provider': b['provider'], 'number': b['projectNumber']} for b in self.cfg['boards']])
        self.assertEqual(good['validity'], 'OK', good)
        missing = next(r for r in rows if r['path'] == str(self.current))
        self.assertEqual(missing['validity'], 'INVALID')
        self.assertTrue(all(v is None for v in missing['methodology'].values()))
        self.assertFalse((self.current / '.neural-network').exists())

    def test_formats_raw_schema_precedence_feedback_and_hostile_environment(self):
        self.cfg['methodology']['feedback'] = True
        self.repo('yml', filename='project.yml')
        legacy = json.loads((PLUGIN / 'tests/fixtures/valid.project.json').read_text())
        self.repo('legacy', legacy, 'project.json')
        self.cfg['schemaVersion'] = 2
        precedence = self.repo('precedence')
        (precedence / '.neural-network/project.json').write_text('{}')
        env = dict(os.environ, PROJECT_CONFIG=str(precedence / '.neural-network/project.json'))
        rows = {Path(r['path']).name: r for r in self.rows(env=env)}
        self.assertEqual(rows['yml']['schemaVersion'], '2.0.0')
        self.assertEqual(rows['yml']['methodology']['feedback'], True)
        for name in ('legacy', 'precedence'):
            self.assertEqual(rows[name]['schemaVersion'], '1.0.0')
            self.assertEqual(rows[name]['validity'], 'OK', rows[name])
        self.assertEqual(rows['current']['validity'], 'INVALID')

    def test_bad_configs_keep_siblings_and_report_real_first_error(self):
        good = self.repo('good')
        self.repo('list', ['bad'])
        bad = copy.deepcopy(self.cfg)
        bad['project'].pop('name')
        self.repo('missing-name', bad)
        bad['boards'] = [None]
        self.repo('validator-crash', bad)
        malformed = self.repo('syntax')
        (malformed / '.neural-network/project.yaml').write_text('bad: [')
        odd = self.repo('odd')
        (odd / '.neural-network/project.yaml').write_text('schemaVersion: 2.0.0\nproject: {name: 2026-01-01}\nmethodology: &loop {autoMerge: *loop, feedback: !!set {x: null}}\nboards: [null, {provider: [x], projectNumber: {x: y}}]\n')
        rows = {Path(r['path']).name: r for r in self.rows()}
        self.assertEqual(rows['good']['validity'], 'OK', rows)
        for name in ('list', 'missing-name', 'validator-crash', 'syntax', 'odd'):
            self.assertEqual(rows[name]['validity'], 'INVALID', rows[name])
            self.assertTrue(rows[name]['diagnostic'])
        self.assertEqual(rows['missing-name']['diagnostic'], "project: missing required key 'name'")
        self.assertIn('top level must be a mapping', rows['list']['diagnostic'])
        self.assertIn('validator failed', rows['validator-crash']['diagnostic'])
        text = self.run_cli('--scan', str(self.scan), '--root', str(good))
        self.assertIn('maxInProgress', text)
        self.assertIn('INVALID', text)
        self.assertIn('unspecified', text)

    def test_surrogate_name_is_contained_in_both_renderers(self):
        normal_name = 'São Paulo — 東京'
        self.cfg['project']['name'] = normal_name
        good = self.repo('good')
        self.cfg['project']['name'] = 'broken\ud800name'
        self.repo('surrogate')
        # Pin UTF-8 strict output so ambient Python encoding settings cannot
        # conceal either renderer's failure on a retained invalid scalar.
        env = dict(os.environ, PYTHONIOENCODING='utf-8:strict')
        for suffix in ([], ['--json']):
            with self.subTest(format='json' if suffix else 'table'):
                text = self.run_cli('--scan', str(self.scan), '--root', str(good), *suffix, env=env)
                if suffix:
                    rows = {Path(r['path']).name: r for r in json.loads(text)}
                    self.assertEqual(rows['good']['name'], normal_name)
                    self.assertEqual(rows['good']['validity'], 'OK')
                    self.assertEqual(rows['surrogate']['name'], 'broken\ud800name')
                    self.assertEqual(rows['surrogate']['validity'], 'INVALID')
                    self.assertIn('validator failed', rows['surrogate']['diagnostic'])
                    self.assertIn('UnicodeEncodeError', rows['surrogate']['diagnostic'])
                else:
                    lines = text.splitlines()
                    self.assertEqual(len(lines), 3, text)
                    rows = {Path(cells[0]).name: cells for cells in
                            (line.split('\t') for line in lines[1:])}
                    # Table string cells use JSON escaping without outer quotes;
                    # ordinary Unicode and the malformed scalar remain recoverable.
                    self.assertEqual(json.loads('"' + rows['good'][1] + '"'), normal_name)
                    self.assertEqual(rows['good'][-2], 'OK')
                    self.assertEqual(json.loads('"' + rows['surrogate'][1] + '"'), 'broken\ud800name')
                    self.assertEqual(rows['surrogate'][-2], 'INVALID')
                    self.assertIn('validator failed', rows['surrogate'][-1])
                    self.assertIn('UnicodeEncodeError', rows['surrogate'][-1])

    def rendered_rows(self, text, json_mode):
        if json_mode:
            return json.loads(text)
        rows = []
        for line in text.splitlines()[1:]:
            cells = line.split('\t')
            rows.append(dict(path=json.loads('"' + cells[0] + '"'),
                             validity=cells[-2], diagnostic=cells[-1]))
        return rows

    @unittest.skipUnless(os.name == 'posix', 'POSIX filename-byte contract')
    def test_scanned_non_utf8_paths_preserve_rows_and_validator_errors(self):
        good = self.repo('good')
        valid = self.repo(os.fsdecode(b'valid\xff'))
        bad_cfg = copy.deepcopy(self.cfg)
        bad_cfg['project'].pop('name')
        invalid = self.repo(os.fsdecode(b'invalid\xff'), bad_cfg)
        env = dict(os.environ, PROJECT_CONFIG='/nonexistent',
                   PYTHONIOENCODING='utf-8:surrogateescape')
        for json_mode in (False, True):
            with self.subTest(format='json' if json_mode else 'table'):
                suffix = ['--json'] if json_mode else []
                text = self.run_cli('--scan', str(self.scan), '--root', str(self.current),
                                    *suffix, env=env)
                rows = {os.fsencode(r['path']): r for r in self.rendered_rows(text, json_mode)}
                self.assertEqual(set(rows), {os.fsencode(p) for p in
                                            (self.current, good, valid, invalid)})
                self.assertEqual(rows[os.fsencode(good)]['validity'], 'OK')
                self.assertEqual(rows[os.fsencode(valid)]['validity'], 'OK')
                self.assertEqual(rows[os.fsencode(invalid)]['validity'], 'INVALID')
                self.assertEqual(rows[os.fsencode(invalid)]['diagnostic'],
                                 "project: missing required key 'name'")

    @unittest.skipUnless(os.name == 'posix', 'POSIX filename-byte contract')
    def test_implicit_git_root_preserves_non_utf8_filename_bytes(self):
        good = self.repo('good')
        repo = self.repo(os.fsdecode(b'repo\xff'))
        subprocess.run(['git', '-C', str(repo), 'init', '-q'], check=True)
        # Scan only the healthy sibling's parent; remove the byte-named repo
        # from the scan so its inclusion necessarily comes from Git discovery.
        selected = self.base / repo.name
        repo.rename(selected)
        env = dict(os.environ, PYTHONIOENCODING='utf-8:surrogateescape')
        for json_mode in (False, True):
            with self.subTest(format='json' if json_mode else 'table'):
                suffix = ['--json'] if json_mode else []
                text = self.run_cli('--scan', str(self.scan), *suffix, cwd=selected, env=env)
                rows = {os.fsencode(r['path']): r for r in self.rendered_rows(text, json_mode)}
                self.assertEqual(set(rows), {os.fsencode(good), os.fsencode(selected)})
                self.assertTrue(all(r['validity'] == 'OK' for r in rows.values()), rows)

    @unittest.skipUnless(os.name == 'posix', 'POSIX filename control-character contract')
    def test_default_git_root_preserves_cr_and_crlf_bytes(self):
        for name in ('carriage\rreturn', 'carriage\r\nreturn', 'line\nreturn'):
            repo = self.repo(name)
            subprocess.run(['git', '-C', str(repo), 'init', '-q'], check=True)
            for json_mode in (False, True):
                with self.subTest(name=repr(name), format='json' if json_mode else 'table'):
                    suffix = ['--json'] if json_mode else []
                    text = self.run_cli('--scan', str(self.base / 'absent'), *suffix, cwd=repo)
                    rows = self.rendered_rows(text, json_mode)
                    self.assertEqual([os.fsencode(r['path']) for r in rows], [os.fsencode(repo)])
                    self.assertEqual(rows[0]['validity'], 'OK', rows)

    def test_default_root_git_cwd_and_default_scan_home(self):
        subprocess.run(['git', '-C', str(self.current), 'init', '-q'], check=True)
        nested = self.current / 'nested'
        nested.mkdir()
        home = self.base / 'home'
        (home / 'Development' / 'sibling' / '.neural-network').mkdir(parents=True)
        env = dict(os.environ, HOME=str(home))
        rows = json.loads(self.run_cli('--json', cwd=nested, env=env))
        self.assertEqual({r['path'] for r in rows}, {str(self.current), str(home / 'Development/sibling')})

    def test_no_file_or_network_side_effects_and_permission_failure(self):
        self.repo('good')
        inventory = module('projects-list')
        import config
        before = {str(p): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        original = config._parse
        def unreadable(path):
            if '/good/' in str(path):
                raise PermissionError('fixture read denied')
            return original(path)
        with patch('socket.socket', side_effect=AssertionError('network forbidden')), \
             patch('pathlib.Path.mkdir', side_effect=AssertionError('writes forbidden')), \
             patch.object(config, '_parse', side_effect=unreadable):
            row = inventory.inventory_row(self.scan / 'good')
        self.assertEqual(row['validity'], 'INVALID')
        self.assertIn('fixture read denied', row['diagnostic'])
        self.rows()
        after = {str(p): p.read_bytes() for p in self.base.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        self.assertFalse(list(self.base.rglob('__pycache__')))

    def test_installed_cache_with_spaces_stays_read_only(self):
        self.repo('good')
        cache = self.base / 'plugin cache' / 'scripts'
        (cache / 'assistant').mkdir(parents=True)
        for name in ('projects-list.py', 'repo_discovery.py', 'config.py', 'validate-config.py',
                     'assistant/__init__.py', 'assistant/config.py'):
            shutil.copyfile(SCRIPTS / name, cache / name)
        # Arm the audit probe only after fixture setup. Subprocesses are limited
        # to the actual validator; CLI --root avoids Git in this invocation.
        wrapper = self.base / 'readonly-probe.py'
        wrapper.write_text("""import os, runpy, sys

def audit(event, args):
    if event == 'open':
        flags = args[2]
        if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
            raise AssertionError('filesystem write: ' + str(args[0]))
    if event.startswith('socket.') or event in ('os.mkdir', 'os.remove', 'os.rename', 'os.rmdir'):
        raise AssertionError('side effect: ' + event)
    if event == 'subprocess.Popen':
        argv = args[1]
        assert argv[:2] == [sys.executable, '-B'] and argv[2].endswith('/validate-config.py'), argv
sys.addaudithook(audit)
sys.path.insert(0, os.path.dirname(sys.argv[1]))
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
""")
        def snapshot():
            return {str(p): p.read_bytes() if p.is_file() else None for p in self.base.rglob('*')}
        before = snapshot()
        result = subprocess.run([sys.executable, str(wrapper), str(cache / 'projects-list.py'),
                                 '--scan', str(self.scan), '--root', str(self.current), '--json'],
                                cwd=self.current, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rows = json.loads(result.stdout)
        self.assertEqual(next(r for r in rows if r['name'])['validity'], 'OK')
        self.assertEqual(before, snapshot())

    def test_default_git_root_preserves_trailing_space(self):
        repo = self.base / 'repo with trailing space '
        repo.mkdir()
        subprocess.run(['git', '-C', str(repo), 'init', '-q'], check=True)
        rows = json.loads(self.run_cli('--scan', str(self.base / 'absent'), '--json', cwd=repo))
        self.assertEqual([r['path'] for r in rows], [str(repo)])

    def test_sync_import_by_absolute_filename_without_pythonpath(self):
        code = ("import importlib.util; "
                "spec = importlib.util.spec_from_file_location('sync_probe', "
                + repr(str(SCRIPTS / 'sync-configs.py')) + "); "
                "spec.loader.exec_module(importlib.util.module_from_spec(spec))")
        env = dict(os.environ)
        env.pop('PYTHONPATH', None)
        result = subprocess.run([sys.executable, '-B', '-c', code], cwd=self.current,
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_shared_scanner_and_caller_policies(self):
        shared = module('repo_discovery')
        good = self.repo('good')
        alias = self.scan / 'alias'
        alias.symlink_to(good, target_is_directory=True)
        found = shared.scan_anchored_repos(self.scan)
        self.assertEqual({p.resolve() for p in found}, {good})
        with patch.object(Path, 'iterdir', side_effect=PermissionError('blocked')):
            self.assertEqual(shared.scan_anchored_repos(self.scan), [])
        viewer, sync, inventory = module('neural-view'), module('sync-configs'), module('projects-list')
        for caller in (viewer, sync, inventory):
            with patch.object(caller, 'scan_anchored_repos', return_value=[good]) as scan:
                if caller is viewer:
                    rows = viewer.discover_repos(['--scan', str(self.scan), '--dir', str(self.current)])
                    self.assertEqual({p for _, p in rows}, {good, self.current})
                elif caller is sync:
                    self.assertEqual(sync.discover_repos(self.scan, good), [])
                else:
                    self.assertEqual(caller.discover_repos(self.scan, self.current), sorted([good, self.current]))
                scan.assert_called_once()
        with patch.object(viewer, 'scan_anchored_repos', return_value=[]), \
             patch.object(viewer, 'git_root', return_value=str(self.current)), \
             patch.object(viewer, 'ensure_marker') as marker, \
             patch.dict(os.environ, {}, clear=True):
            self.assertEqual(viewer.discover_repos([]), [('current', self.current)])
            marker.assert_called_once_with(self.current)

    def test_skill_registration_and_indexes(self):
        name = 'neural-network-projects-list'
        skill = PLUGIN / 'skills' / name / 'SKILL.md'
        text = skill.read_text()
        front = yaml.safe_load(text.split('---')[1])
        self.assertEqual(front['name'], name)
        self.assertIsInstance(front['description'], str)
        manifest = json.loads((PLUGIN / '.codex-plugin/plugin.json').read_text())
        self.assertTrue((PLUGIN / manifest['skills'] / name / 'SKILL.md').is_file())
        self.assertIn('projects-list.py', text)
        for path in ('README.md', 'AGENTS.md', 'docs/compatibility-matrix.md', 'plugins/spec-workflow/README.md'):
            self.assertIn(name, (PLUGIN.parents[1] / path).read_text())


if __name__ == '__main__':
    unittest.main()
