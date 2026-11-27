#!/usr/bin/env python3
"""Read-only local config inventory, independent of ambient PROJECT_CONFIG.

projects-list.py [--scan BASE] [--root DIR] [--json]
Invalid repositories remain rows; only CLI usage errors fail the command.
"""
import argparse
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import subprocess
import sys

# Set before importing the shared engine (including validator subprocesses).
sys.dont_write_bytecode = True
import config as C
from repo_discovery import scan_anchored_repos

HERE = Path(__file__).resolve().parent
TOGGLES = ('maxInProgress', 'autoMerge', 'serialDelivery', 'feedback', 'iterativeUI')


@contextmanager
def local_config_environment():
    """Use canonical repo paths even when the caller exported PROJECT_CONFIG."""
    previous = os.environ.pop('PROJECT_CONFIG', None)
    try:
        yield
    finally:
        if previous is not None:
            os.environ['PROJECT_CONFIG'] = previous


def current_root():
    try:
        result = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                                capture_output=True, timeout=10)
        if result.returncode == 0 and result.stdout:
            # Keep raw filename bytes: text mode would normalize embedded CR/CRLF.
            # Remove only Git's final record terminator before filesystem decoding.
            root = result.stdout[:-1] if result.stdout.endswith(b'\n') else result.stdout
            if root:
                return Path(os.fsdecode(root))
    except (OSError, subprocess.SubprocessError):
        pass
    return Path.cwd()


def discover_repos(scan_base, root):
    found = {Path(root).expanduser().resolve()}
    for child in scan_anchored_repos(Path(scan_base).expanduser()):
        try:
            found.add(child.resolve())
        except (OSError, RuntimeError):
            continue
    return sorted(found)


def scalar(value):
    """Keep readable scalar fields; malformed YAML objects cannot break output."""
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float) and math.isfinite(value):
        return value
    return '<invalid value>'


def mapping(value):
    return value if isinstance(value, dict) else {}


def validate(path):
    """Run the actual validator in its own process, retaining its first error."""
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    env.pop('PROJECT_CONFIG', None)
    try:
        result = subprocess.run([sys.executable, '-B', str(HERE / 'validate-config.py'), str(path)],
                                capture_output=True, text=True, errors='surrogateescape', env=env, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        return 'INVALID', f'validator failed: {exc}'
    if result.returncode == 0:
        return 'OK', None
    lines = (result.stdout + '\n' + result.stderr).splitlines()
    for line in lines:
        if line.startswith('  - '):
            return 'INVALID', line[4:]
    for line in lines:
        if line.startswith(('INVALID:', 'PREFLIGHT FAIL:')):
            return 'INVALID', line
    detail = next((line.strip() for line in reversed(lines) if line.strip()),
                  f'exit {result.returncode} without diagnostics')
    return 'INVALID', f'validator failed: {detail}'


def inventory_row(root):
    row = dict(path=str(root), name=None, schemaVersion=None,
               methodology={key: None for key in TOGGLES}, boards=[],
               validity='INVALID', diagnostic=None)
    cfg = {}
    load_error = None
    path = None
    try:
        with local_config_environment():
            path = C.find_config(str(root))
            if path:
                cfg = C._parse(path)
                row['schemaVersion'] = C.schema_semver(cfg)
                # Preserve readable raw fields if normalization/overlay fails.
                cfg = C.load_config(path=path, warn=False)
    except (Exception, SystemExit) as exc:  # malformed per-repo data stays visible
        load_error = f'cannot load config: {exc}'
    if path:
        row['validity'], row['diagnostic'] = validate(path)
        if load_error and row['validity'] == 'OK':
            row.update(validity='INVALID', diagnostic=load_error)
    else:
        row['diagnostic'] = load_error or 'missing config: .neural-network/project.yaml, project.yml or project.json'
    cfg = mapping(cfg)
    row['name'] = scalar(mapping(cfg.get('project')).get('name'))
    methodology = mapping(cfg.get('methodology'))
    for key in TOGGLES:
        value = methodology.get(key)
        if key == 'feedback' and isinstance(value, dict):
            value = value.get('enabled')
        row['methodology'][key] = scalar(value)
    boards = cfg.get('boards')
    if isinstance(boards, list):
        row['boards'] = [dict(provider=scalar(mapping(board).get('provider')),
                              number=scalar(mapping(board).get('projectNumber'))) for board in boards]
    return row


def cell(value):
    # Escape whitespace/control characters so each repo is exactly one table row.
    if value is None:
        return 'unspecified'
    # ASCII escaping also contains malformed YAML strings with lone surrogates.
    text = json.dumps(value, ensure_ascii=True)
    return text[1:-1] if isinstance(value, str) else text


def print_table(rows):
    print('\t'.join(('path', 'project.name', 'schemaVersion', *TOGGLES, 'boards', 'validity', 'diagnostic')))
    for row in rows:
        boards = ', '.join(f"{cell(b['provider'])}#{cell(b['number'])}" for b in row['boards']) or 'unspecified'
        print('\t'.join([cell(row['path']), cell(row['name']), cell(row['schemaVersion']),
                         *(cell(row['methodology'][key]) for key in TOGGLES), boards,
                         row['validity'], cell(row['diagnostic'])]))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scan', default=str(Path.home() / 'Development'))
    parser.add_argument('--root', help='Always include this repository (default: cwd Git root, else cwd)')
    parser.add_argument('--json', action='store_true', help='Print structured rows instead of a table')
    args = parser.parse_args(argv)
    rows = [inventory_row(root) for root in discover_repos(args.scan, args.root or current_root())]
    if args.json:
        print(json.dumps(rows, ensure_ascii=True, indent=2))
    else:
        print_table(rows)
    return 0


if __name__ == '__main__':
    sys.exit(main())
