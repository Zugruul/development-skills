#!/usr/bin/env python3
"""Read-only checkpoint admission, shared by shell commands and the direct picker.

This is a path-presence check, not an atomic admission lock. The primary checkout
owns relative state; an explicit root (then the existing environment override)
is authoritative. Config parsing/overlays remain owned by config.py.
"""
import argparse
import os
import re
import subprocess
import sys

import config as C

HERE = os.path.dirname(os.path.abspath(__file__))


class CheckpointError(Exception):
    """Admission cannot safely proceed."""


def repository_root(root=None, config_path=None):
    if root is not None:
        return os.path.realpath(root)
    # A direct picker may run outside its configured repo. Anchor the existing
    # shared resolver at that config, never at the unrelated caller cwd.
    cwd = None
    if config_path:
        cwd = os.path.dirname(os.path.abspath(config_path))
        if os.path.basename(cwd) in (C.CONFIG_DIR, '.claude'):
            cwd = os.path.dirname(cwd)
    result = subprocess.run(
        ['bash', '-c', 'source "$1"; spec_workflow_repo_root',
         'checkpoint', os.path.join(HERE, 'lib', 'repo-root.sh')],
        cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if result.returncode or not result.stdout.strip():
        raise CheckpointError('cannot resolve primary repository root')
    return result.stdout.strip()


def _context(root=None, config_path=None):
    root = repository_root(root, config_path)
    cfg = C.load_config(root=root, path=config_path, warn=False)
    if not isinstance(cfg, dict):
        raise CheckpointError('configuration missing or unreadable; run setup-project or fix PROJECT_CONFIG')
    return root, cfg


def _flag_path(root, cfg):
    paths = cfg.get('paths', {})
    if not isinstance(paths, dict):
        raise CheckpointError('paths must be a mapping')
    flag = paths.get('checkpointFile', '.claude/CHECKPOINT')
    if not isinstance(flag, str) or not flag.strip() or '\x00' in flag:
        raise CheckpointError('paths.checkpointFile must be a nonempty path string')
    return os.path.join(root, flag)


def checkpoint_path(root=None, config_path=None):
    return _flag_path(*_context(root, config_path))


def _normalized(status):
    return re.sub(r'\s+', ' ', status.strip()).lower()


def work_status(cfg, board_id):
    """Match the picker's selected-board and single-status fallback semantics.

    Only validate the structure needed to classify starts. Unknown board ids
    retain the established first-board fallback; other schema validation remains
    with the existing config tooling.
    """
    boards = cfg.get('boards')
    if not isinstance(boards, list) or not boards:
        raise CheckpointError('boards must be a nonempty list to classify work status')
    if any(not isinstance(board, dict) or not isinstance(board.get('id'), str)
           or not board['id'].strip() for board in boards):
        raise CheckpointError('board selection requires mappings with nonempty string ids')
    board = next((board for board in boards if board['id'] == board_id), boards[0])
    flow = board.get('statusFlow')
    if (not isinstance(flow, list) or not flow
            or any(not isinstance(status, str) or not status.strip() for status in flow)):
        raise CheckpointError(f"board {board['id']}: statusFlow must be a nonempty list of status strings")
    return _normalized(flow[1] if len(flow) > 1 else flow[0])


def require_running(root=None, config_path=None, board_id=None, status=None):
    """Refuse selection/starts on pause; other classified moves may finish."""
    try:
        primary, cfg = _context(root, config_path)
        if board_id is not None or status is not None:
            work = work_status(cfg, board_id or '')
            if status is not None and _normalized(status) != work:
                return
        flag = _flag_path(primary, cfg)
        try:
            os.lstat(flag)  # dangling symlinks and empty files also pause
        except FileNotFoundError:
            return
        raise CheckpointError(
            f'CHECKPOINT flag is present: PAUSED at {flag}; finish existing work at a safe boundary, write a '
            'handoff, then remove this flag to resume (checkpoint skill).')
    except (C.ConfigError, OSError, ValueError, TypeError) as exc:
        raise CheckpointError(f'cannot inspect checkpoint configuration/state: {exc}') from exc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root')
    parser.add_argument('--board', help='active board id; unknown ids use the first board')
    parser.add_argument('--status', help='classify a mutation; only work-status moves check pause')
    args = parser.parse_args()
    try:
        require_running(root=args.root, board_id=args.board, status=args.status)
    except CheckpointError as exc:
        print(f'CHECKPOINT BLOCKED: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
