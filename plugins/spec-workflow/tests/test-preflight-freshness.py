#!/usr/bin/env python3
"""Task #274: real preflight/helper integration, hermetic transport and failure injection."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

PLUGIN = Path(__file__).resolve().parents[1]
SCRIPTS = PLUGIN / 'scripts'


class Freshness(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='freshness-274-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name) / 'consumer with spaces'
        self.root.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / '.neural-network').mkdir()
        self.config = self.root / '.neural-network/project.json'
        self.valid = json.loads((PLUGIN / 'tests/fixtures/valid.project.json').read_text())
        self.config.write_text(json.dumps(self.valid))
        (self.root / 'SPEC.md').touch()
        self.gi = self.root / '.gitignore'
        self.tmp = self.root / 'tmp'
        self.tmp.mkdir()
        (self.tmp / 'user-owned').write_text('preserve me')
        self.env = dict(os.environ, TMPDIR=str(self.tmp), SPEC_WORKFLOW_CACHE_SEARCH_BASE=str(self.tmp),
                        PYTHONDONTWRITEBYTECODE='1')
        self.env.pop('CLAUDE_PLUGIN_ROOT', None)

    def run_script(self, name, *args, **kwargs):
        return subprocess.run(['bash', str(SCRIPTS / name), *map(str, args)], cwd=self.root,
                              env=self.env, capture_output=True, text=True, timeout=20, **kwargs)

    def sync(self, *args):
        return self.run_script('gitignore-sync.sh', *args, self.gi)

    def preflight(self, *args):
        result = self.run_script('preflight.sh', *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def assert_clean_tmp(self):
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()), ['user-owned'])

    def stub(self, name, body):
        directory = Path(self.scratch.name) / 'bin'
        directory.mkdir(exist_ok=True)
        script = directory / name
        script.write_text('#!/bin/bash\n' + body + '\n')
        script.chmod(0o755)
        self.env['PATH'] = str(directory) + os.pathsep + os.environ['PATH']

    def test_missing_stale_repair_and_silent_current_both_modes(self):
        for mode in [(), ('--spec',)]:
            with self.subTest(mode=mode):
                self.gi.unlink(missing_ok=True)
                out = self.preflight(*mode)
                self.assertIn('PREFLIGHT FAIL', out)
                self.assertIn('gitignore-sync.sh', out)
                self.assertIn(str(self.gi), out)
                self.assertNotIn('preflight ok:', out)
                self.assertFalse(self.gi.exists())
                self.gi.write_text('# mine\n# >>> spec-workflow managed\nstale/\n# <<< spec-workflow managed\n')
                self.assertIn('PREFLIGHT FAIL', self.preflight(*mode))
                self.assertEqual(self.sync().returncode, 0)
                out = self.preflight(*mode)
                self.assertNotIn('PREFLIGHT FAIL', out)
                self.assertNotIn('VALID:', out)
                expected = 'preflight ok: config + 1 spec(s) present' if mode else 'preflight ok: config present'
                # Legacy inline-spec suggestion and existing identity warnings remain allowed.
                self.assertEqual([s for s in out.splitlines() if s.startswith('preflight')], [expected])
                self.assertEqual(self.sync('--dry-run').stdout, '')
                self.assert_clean_tmp()

    def test_validator_both_modes_and_local_overlay(self):
        self.assertEqual(self.sync().returncode, 0)
        for mode in [(), ('--spec',)]:
            for source in ['base', 'overlay']:
                with self.subTest(mode=mode, source=source):
                    cfg = dict(self.valid)
                    cfg['commands'] = dict(self.valid['commands'], gate=False)
                    overlay = self.root / '.neural-network/project.local.yaml'
                    if source == 'base':
                        self.config.write_text(json.dumps(cfg))
                    else:
                        self.config.write_text(json.dumps(self.valid))
                        overlay.write_text('compute:\n  resources:\n    box:\n      roles: invalid\n')
                    out = self.preflight(*mode)
                    self.assertIn('PREFLIGHT FAIL', out)
                    self.assertIn('commands.gate' if source == 'base' else 'compute.resources.box.roles', out)
                    self.assertNotIn('preflight ok:', out)
                    overlay.unlink(missing_ok=True)
        self.assert_clean_tmp()

    def test_diff_errors_are_not_clean_and_cleanup(self):
        self.sync()
        self.stub('diff', 'echo comparison-unavailable >&2\nexit 2')
        result = self.sync('--dry-run')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('comparison-unavailable', result.stderr)
        out = self.preflight()
        self.assertIn('PREFLIGHT FAIL', out)
        self.assertIn('comparison-unavailable', out)
        self.assertNotIn('preflight ok:', out)
        self.assert_clean_tmp()

    def test_invalid_target_and_failed_publish(self):
        self.gi.mkdir()
        result = self.sync('--dry-run')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr)
        self.assertIn('PREFLIGHT FAIL', self.preflight())
        self.gi.rmdir()
        self.stub('mv', 'echo publish-unavailable >&2\nexit 1')
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('publish-unavailable', result.stderr)
        self.assertFalse(self.gi.exists())
        self.assert_clean_tmp()

    def test_handled_interruption_cleans_only_owned_temps(self):
        for sig in ['TERM', 'HUP', 'INT']:
            with self.subTest(signal=sig):
                self.stub('diff', 'kill -' + sig + ' "$PPID"\nexit 2')
                result = self.sync('--dry-run')
                self.assertNotEqual(result.returncode, 0)
                self.assert_clean_tmp()

    def test_preserves_nonmanaged_bytes_and_track_warning(self):
        before = b'# user\r\nkeep/\r\n'
        after = b'docs/handoffs/\n# no final newline'
        self.gi.write_bytes(before + b'# >>> spec-workflow managed\nstale/\n# <<< spec-workflow managed\n' + after)
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.gi.read_bytes().startswith(before))
        self.assertTrue(self.gi.read_bytes().endswith(after))
        self.assertIn('WARNING: track path docs/handoffs/', result.stderr)
        self.assertEqual(self.sync('--dry-run').stdout, '')
        self.assert_clean_tmp()

    def test_marker_collisions_refuse_without_changing_user_bytes(self):
        start = b'# >>> spec-workflow managed'
        end = b'# <<< spec-workflow managed'
        cases = {
            'bare CR before start': b'user-prefix\r' + start + b'\nuser-owned-rule/\n' + end + b'\nlast/',
            'bare CR before end': start + b'\nuser-owned-rule/\nuser-prefix\r' + end + b'\nlast/',
            'extra CR after start': start + b'\r\r\nuser-owned-rule/\n' + end + b'\nlast/',
            'extra CR after end': start + b'\nuser-owned-rule/\n' + end + b'\r\r\nlast/',
        }
        for label, original in cases.items():
            for args in [(), ('--dry-run',)]:
                with self.subTest(case=label, args=args):
                    self.gi.write_bytes(original)
                    result = self.sync(*args)
                    self.assertEqual(self.gi.read_bytes(), original)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('malformed managed markers', result.stderr)
                    self.assert_clean_tmp()

    def test_exact_lf_and_crlf_markers_preserve_surrounding_bytes(self):
        for newline in [b'\n', b'\r\n']:
            with self.subTest(newline=newline):
                before = b'non-marker\ruser-prefix/\r\n'
                after = b'last/\rno-final-newline'
                original = (before + b'# >>> spec-workflow managed' + newline + b'stale/' + newline
                            + b'# <<< spec-workflow managed' + newline + after)
                self.gi.write_bytes(original)
                result = self.sync('--dry-run')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.gi.read_bytes(), original)
                result = self.sync()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(self.gi.read_bytes().startswith(before))
                self.assertTrue(self.gi.read_bytes().endswith(after))
                self.assertNotIn(b'stale/', self.gi.read_bytes())
                current = self.sync('--dry-run')
                self.assertEqual((current.returncode, current.stdout), (0, ''))
                self.assert_clean_tmp()

    def test_mem013_repair_converges(self):
        spec = importlib.util.spec_from_file_location('sync_configs_274', SCRIPTS / 'sync-configs.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(module.mem013_gitignore_detect(self.root)[0])
        module.mem013_gitignore_apply(self.root)
        self.assertFalse(module.mem013_gitignore_detect(self.root)[0])
        self.assertNotIn('PREFLIGHT FAIL', self.preflight('--spec'))
        self.assert_clean_tmp()

    def test_mem013_helper_failure_is_not_noop(self):
        spec = importlib.util.spec_from_file_location('sync_configs_error_274', SCRIPTS / 'sync-configs.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.stub('diff', 'echo mem013-comparison-unavailable >&2\nexit 2')
        with mock.patch.dict(os.environ, self.env):
            with self.assertRaisesRegex(RuntimeError, 'mem013-comparison-unavailable'):
                module.mem013_gitignore_detect(self.root)
        self.stub('mv', 'echo mem013-publish-unavailable >&2\nexit 1')
        with mock.patch.dict(os.environ, self.env):
            with self.assertRaisesRegex(RuntimeError, 'mem013-publish-unavailable'):
                module.mem013_gitignore_apply(self.root)
        self.assert_clean_tmp()

    @unittest.skipIf(os.geteuid() == 0, 'root can read mode-000 files')
    def test_unreadable_manifest_is_not_empty_clean_policy(self):
        manifest = self.root / 'unreadable.manifest'
        manifest.write_text('ignore\tlocal-only/\n')
        manifest.chmod(0)
        self.addCleanup(manifest.chmod, 0o600)
        self.env['SPEC_WORKFLOW_LOCAL_STATE_MANIFEST'] = str(manifest)
        result = self.sync('--dry-run')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('manifest', result.stderr)
        self.assertIn('PREFLIGHT FAIL', self.preflight())
        self.assert_clean_tmp()

    def test_bad_marker_layout_is_visible(self):
        self.gi.write_text('# >>> spec-workflow managed\nunterminated\n')
        result = self.sync('--dry-run')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr)
        self.assertIn('PREFLIGHT FAIL', self.preflight())
        self.assert_clean_tmp()


if __name__ == '__main__':
    unittest.main()
