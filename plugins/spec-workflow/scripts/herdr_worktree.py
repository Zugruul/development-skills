#!/usr/bin/env python3
"""Create and remove worktrees so they appear in herdr's spaces sidebar.

Config lives in the top-level `herdr` object of project.yaml. Absent or
`enabled: false` means plain git and no herdr call at all.

  add     creates a task lane; prints its absolute path on stdout.
  remove  removes a lane and its workspace. A plain `git worktree remove` would
          leave a "(deleted)" entry in the sidebar.
  subagent-hook
          SubagentStart/SubagentStop hook. Opens an isolated subagent's
          worktree in herdr and closes that workspace when the subagent stops.
          It does not use WorktreeCreate on purpose: that hook REPLACES Claude
          Code's own creation in every repo that has this plugin, herdr or not.

Herdr only adds visibility, so a herdr failure must never block work: `add` and
`remove` fall back to git with a notice, and the hook always exits 0. git's own
errors (branch or path conflicts, dirty worktrees) still fail the command.
--trust-repository is never passed: herdr reserves it for a human decision.
"""
import argparse
import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402

# Checking out a large repo can take minutes, so herdr calls that create or
# remove a checkout get far longer than the display-only calls.
CHECKOUT_TIMEOUT = 900
HOOK_TIMEOUT = 15


def notice(message):
    print(f'herdr-worktree: {message}', file=sys.stderr)


def settings(root):
    """Return (enabled, task_lanes, subagents). Unreadable config means off."""
    try:
        # config.py exits (SystemExit) when PyYAML is missing and may print
        # about it; neither may reach a hook or a lane command.
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            cfg = config.load_config(root=root, warn=False)
    except (Exception, SystemExit):  # a broken config is validate-config's report, not ours
        return False, False, False
    herdr = cfg.get('herdr') if isinstance(cfg, dict) else None
    if not isinstance(herdr, dict) or herdr.get('enabled') is not True:
        return False, False, False
    worktrees = herdr.get('worktrees')
    worktrees = worktrees if isinstance(worktrees, dict) else {}
    return True, worktrees.get('taskLanes', True) is True, worktrees.get('subagents', False) is True


def herdr(*args, timeout=HOOK_TIMEOUT):
    """Run herdr. Return its `result` object, or None on any failure."""
    if not shutil.which('herdr'):
        return None
    try:
        proc = subprocess.run(['herdr', *args], capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL)
        if proc.returncode:
            return None
        result = json.loads(proc.stdout).get('result')
    except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
        return None
    return result if isinstance(result, dict) else None


def git(root, *args, check=True):
    proc = subprocess.run(['git', '-C', root, *args], capture_output=True, text=True)
    if check and proc.returncode:
        raise SystemExit(f'herdr-worktree: git {args[0]} {args[1] if len(args) > 1 else ""}: '
                         f'{proc.stderr.strip()}')
    return proc


def primary_checkout(root):
    """The checkout herdr must start worktree actions from, or None.

    herdr refuses to start from a linked worktree. The parent of the common git
    dir is only the primary checkout when that dir is `<parent>/.git`; a
    submodule, a separate git dir or a bare repo needs another answer, and
    guessing would put the lane in the wrong repository.
    """
    absolute = git(root, 'rev-parse', '--path-format=absolute', '--absolute-git-dir').stdout.strip()
    common = git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir').stdout.strip()
    if same_path(absolute, common):  # this is the primary checkout itself (none, if bare)
        return git(root, 'rev-parse', '--show-toplevel', check=False).stdout.strip() or None
    parent = os.path.dirname(common)
    return parent if same_path(os.path.join(parent, '.git'), common) else None


def same_path(a, b):
    return os.path.realpath(a) == os.path.realpath(b)


def registered(root, path):
    listing = git(root, 'worktree', 'list', '--porcelain').stdout
    return any(line.startswith('worktree ') and same_path(line[len('worktree '):], path)
               for line in listing.splitlines())


def workspace_for(path):
    workspaces = (herdr('workspace', 'list') or {}).get('workspaces')
    for workspace in workspaces if isinstance(workspaces, list) else []:
        worktree = workspace.get('worktree') if isinstance(workspace, dict) else None
        checkout = worktree.get('checkout_path') if isinstance(worktree, dict) else None
        if isinstance(checkout, str) and checkout and worktree.get('is_linked_worktree') and same_path(checkout, path):
            identifier = workspace.get('workspace_id')
            return identifier if isinstance(identifier, str) and identifier else None
    return None  # an unexpected reply shape means no workspace


def resolve(args):
    root = git(args.root or os.getcwd(), 'rev-parse', '--show-toplevel').stdout.strip()
    return root, os.path.abspath(os.path.join(root, args.path))


def git_add(root, path, args, branch_exists):
    if args.detach:
        git(root, 'worktree', 'add', '-q', '--detach', path, *([args.base] if args.base else []))
    elif branch_exists:
        git(root, 'worktree', 'add', '-q', path, args.branch)
    else:
        git(root, 'worktree', 'add', '-q', path, '-b', args.branch, *([args.base] if args.base else []))


def branch_present(root, branch):
    return bool(branch) and git(root, 'show-ref', '--verify', '--quiet', f'refs/heads/{branch}',
                                check=False).returncode == 0


def cmd_add(args):
    root, path = resolve(args)
    if registered(root, path):
        raise SystemExit(f'herdr-worktree: {path} is already a worktree; lanes are never reused')
    branch_exists = branch_present(root, args.branch)
    _, use_herdr, _ = settings(root)
    primary = primary_checkout(root) if use_herdr else None
    if use_herdr and primary is None:
        notice('no primary checkout found for this repository; herdr was not used')
        use_herdr = False
    label = args.label or args.branch or os.path.basename(path)
    display = ['--cwd', primary, '--path', path, '--label', label, '--no-focus']

    if use_herdr and args.detach:
        # `herdr worktree create` invents a branch when given none, so a
        # detached lane is made by git and then opened.
        git_add(root, path, args, branch_exists)
        if herdr('worktree', 'open', *display) is None:
            notice(f'created {path} but could not open it in herdr')
    elif use_herdr:
        # Herdr is run from the primary checkout, so without an explicit base
        # it would start from the primary's HEAD, not the invoking checkout's.
        base = []
        if not branch_exists:
            start = args.base or git(root, 'rev-parse', 'HEAD').stdout.strip()
            base = ['--base', start]
        reply = herdr('worktree', 'create', '--branch', args.branch, *base, *display,
                      timeout=CHECKOUT_TIMEOUT)
        # Neither an error reply nor a success reply proves anything about the
        # worktree; check git before trusting either.
        if registered(root, path):
            if reply is None:
                notice(f'herdr reported an error after creating {path}')
        else:
            if reply is not None:
                reason = 'herdr did not create the worktree'
            elif not shutil.which('herdr'):
                reason = 'herdr is not installed'
            else:
                reason = 'herdr could not create the worktree'
            notice(f'{reason}; fell back to git')
            # A failed create can leave the branch behind.
            git_add(root, path, args, branch_present(root, args.branch))
    else:
        git_add(root, path, args, branch_exists)
    print(path)
    return 0


def cmd_remove(args):
    lane, path = resolve(args)
    # The lane may be the directory we run from and herdr deletes it, so all
    # later git work runs from a directory that survives.
    home = primary_checkout(lane) or git(lane, 'rev-parse', '--path-format=absolute',
                                         '--git-common-dir').stdout.strip()
    with contextlib.suppress(OSError):
        os.chdir(home)
    root = home
    # Deliberately ignores worktrees.taskLanes: a lane opened before that
    # setting was switched off would otherwise leave a "(deleted)" sidebar
    # entry. Herdr is used whenever it is enabled and has a workspace open for
    # this path.
    enabled, _, _ = settings(lane)
    workspace = workspace_for(path) if enabled else None
    if workspace:
        force = ['--force'] if args.force else []
        herdr('worktree', 'remove', '--workspace', workspace, *force, timeout=CHECKOUT_TIMEOUT)
        if not registered(root, path):  # trust git, not the reply
            return 0
        notice('herdr could not remove the worktree; trying git')
    git(root, 'worktree', 'remove', *(['--force'] if args.force else []), path)
    return 0


def state_file(agent_id):
    cache = os.environ.get('XDG_CACHE_HOME') or os.path.expanduser('~/.cache')
    return os.path.join(cache, 'spec-workflow', 'herdr-subagents', f'{agent_id}.json')


def subagent_start(agent_id, agent_type, cwd):
    if not os.path.isdir(cwd) or not settings(cwd)[2]:
        return
    primary = primary_checkout(cwd)
    if primary is None:
        return
    result = herdr('worktree', 'open', '--cwd', primary, '--path', cwd,
                   '--label', f'{agent_type} {agent_id[:8]}', '--no-focus')
    if not result or result.get('already_open'):
        return  # an already-open workspace is not ours to close later
    workspace = (result.get('workspace') or {}).get('workspace_id')
    if workspace:
        state = state_file(agent_id)
        os.makedirs(os.path.dirname(state), exist_ok=True)
        with open(state, 'w', encoding='utf-8') as handle:
            json.dump({'workspace_id': workspace, 'path': cwd}, handle)


def subagent_stop(agent_id):
    # Deliberately ignores config: a workspace we opened must still close if
    # the setting was switched off while the subagent ran.
    state = state_file(agent_id)
    try:
        with open(state, encoding='utf-8') as handle:
            opened = json.load(handle)
    except (OSError, ValueError):
        return
    if not isinstance(opened, dict):
        os.unlink(state)
        return
    workspace = opened.get('workspace_id')
    current = herdr('workspace', 'get', str(workspace))
    if current is None:
        return  # herdr did not answer: keep the state so a later stop can close it
    info = current.get('workspace')
    worktree = info.get('worktree') if isinstance(info, dict) else None
    checkout = worktree.get('checkout_path') if isinstance(worktree, dict) else None
    # Workspace ids can be reused after a server restart, so verify before closing.
    if isinstance(checkout, str) and checkout and same_path(checkout, str(opened.get('path', ''))):
        if herdr('workspace', 'close', str(workspace)) is None:
            return
    os.unlink(state)


def cmd_subagent_hook(_args):
    try:
        event = json.load(sys.stdin)
        agent_id = str(event.get('agent_id') or '')
        cwd = str(event.get('cwd') or '')
        # Only isolated subagents run in their own agent-<id> worktree. Any
        # other subagent shares a checkout, and that workspace is not its own.
        # Stop needs only the id: its state file exists only if Start opened a
        # workspace, and the cwd at Stop may be a subdirectory.
        if re.fullmatch(r'[A-Za-z0-9_-]+', agent_id):
            if event.get('hook_event_name') == 'SubagentStart' and os.path.basename(cwd) == f'agent-{agent_id}':
                subagent_start(agent_id, str(event.get('agent_type') or 'agent'), cwd)
            elif event.get('hook_event_name') == 'SubagentStop':
                subagent_stop(agent_id)
    except (Exception, SystemExit):  # noqa: BLE001 -- display only; never disturb a subagent
        pass
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n', 1)[0])
    commands = parser.add_subparsers(dest='command', required=True)

    add = commands.add_parser('add', help='create a task lane; prints its absolute path')
    add.add_argument('--root', help='checkout to run from (default: cwd)')
    add.add_argument('--path', required=True, help='worktree path, relative to the root or absolute')
    target = add.add_mutually_exclusive_group(required=True)
    target.add_argument('--branch', help='branch to check out; created from --base if new')
    target.add_argument('--detach', action='store_true', help='detached lane at --base')
    add.add_argument('--base', help='start ref (default: HEAD)')
    add.add_argument('--label', help='sidebar label (default: the branch or directory name)')
    add.set_defaults(run=cmd_add)

    remove = commands.add_parser('remove', help='remove a lane and its workspace; keeps the branch')
    remove.add_argument('--root', help='checkout to run from (default: cwd)')
    remove.add_argument('--path', required=True, help='worktree path, relative to the root or absolute')
    remove.add_argument('--force', action='store_true', help='remove even with local changes')
    remove.set_defaults(run=cmd_remove)

    hook = commands.add_parser('subagent-hook', help='SubagentStart/SubagentStop hook; reads stdin')
    hook.set_defaults(run=cmd_subagent_hook)

    args = parser.parse_args()
    return args.run(args)


if __name__ == '__main__':
    sys.exit(main())
