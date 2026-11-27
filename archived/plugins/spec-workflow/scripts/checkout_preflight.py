#!/usr/bin/env python3
"""Inspect the actual checkout without refreshing its index or changing user work.

This is a point-in-time decision, not a lock or an ownership classifier. The
caller supplies the authorized session mode; this module never grants consent,
fetches, creates worktrees, or switches branches. Paths use JSON escaping and
surrogateescape for Git's arbitrary filename bytes.
"""
import argparse
import json
import os
import subprocess
import sys


class Arguments(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def git(root, env, *args):
    result = subprocess.run(
        ['git', '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false',
         '-c', 'status.showUntrackedFiles=all',
         '-C', root, *args], env=env, capture_output=True, timeout=60,
    )
    if result.returncode:
        evidence = os.fsdecode(result.stderr).strip()
        raise ValueError(f'git {args[0]} failed ({result.returncode}): {evidence}')
    return result.stdout


def changes_from_status(raw):
    """Parse porcelain v1 -z, whose rename source is a separate NUL record."""
    if not raw:
        return []
    if not raw.endswith(b'\0'):
        raise ValueError('git status returned unterminated porcelain records')
    records = iter(raw[:-1].split(b'\0'))
    changes = []
    for record in records:
        if (len(record) < 4 or record[2:3] != b' '
                or any(c not in b' MTADRCU?!' for c in record[:2])
                or record[:2] == b'  '):
            raise ValueError('git status returned malformed porcelain records')
        change = {'status': record[:2].decode('ascii'), 'path': os.fsdecode(record[3:])}
        if b'R' in record[:2] or b'C' in record[:2]:
            source = next(records, b'')
            if not source:
                raise ValueError('git status returned a rename/copy without its source')
            change['source'] = os.fsdecode(source)
        changes.append(change)
    return sorted(changes, key=lambda c: (c['path'], c['status'], c.get('source', '')))


def main(argv=None):
    root = None
    try:
        parser = Arguments(description=__doc__)
        parser.add_argument('--root', help='checkout directory (default: cwd, never the shared telemetry root)')
        parser.add_argument('--checkout', choices=('main', 'worktree'),
                            help='already authorized session mode; omitted means no isolation grant')
        args = parser.parse_args(argv)
        root = os.path.abspath(args.root or os.getcwd())
        env = dict(os.environ)
        # Ambient repository targeting must not redirect inspection away from
        # the checkout selected by cwd/--root, especially in linked worktrees.
        for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR',
                    'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES',
                    'GIT_NAMESPACE'):
            env.pop(key, None)
        env.update(GIT_OPTIONAL_LOCKS='0', GIT_NO_LAZY_FETCH='1', LC_ALL='C')
        top = git(root, env, 'rev-parse', '--show-toplevel')
        if not top.endswith(b'\n') or not top[:-1]:
            raise ValueError('git rev-parse returned no checkout path')
        root = os.fsdecode(top[:-1])
        changes = changes_from_status(git(
            root, env, 'status', '--porcelain=v1', '-z',
            '--untracked-files=all', '--ignore-submodules=none',
        ))
        status = 'dirty' if changes else 'clean'
        action = ('isolate' if args.checkout == 'worktree' else 'pause') if changes else 'proceed'
        decision = {'status': status, 'root': root, 'action': action, 'changes': changes}
        code = 1 if changes else 0
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        decision = {'status': 'uninspectable', 'root': root, 'action': 'stop', 'error': str(exc)}
        code = 2
    print(json.dumps(decision, ensure_ascii=True, sort_keys=True))
    return code


if __name__ == '__main__':
    sys.exit(main())
