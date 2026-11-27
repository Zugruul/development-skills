#!/usr/bin/env python3
"""Local record of the tasks agents are working on and their TODOs.

Agents keep this up to date as they work (skills/task-state/SKILL.md). It lets
tools such as the herdr tasks panel show live progress with no board read. The
board stays the source of truth for task status.

State lives in `<git common dir>/spec-workflow/task-state/<id>.json`, so every
worktree of a repo shares it and it can never be committed. Writers take a lock
and replace files atomically, so readers need no lock. TODO numbers are permanent (new
TODOs are appended, or placed with `--before`/`--move`), which keeps them stable while several agents work on one task. A TODO's
number is permanent and stored on it; the list order is the order the work
happens, and `--before` inserts or moves without renumbering. Records written
before numbers were stored get them from their positions when read.
"""
import argparse
import contextlib
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402


def fail(message):
    raise SystemExit(f'task-state: {message}')


def git_dir(root):
    proc = subprocess.run(['git', '-C', root, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                          stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if proc.returncode:
        fail(f'{root} is not in a git repository')
    return proc.stdout.strip()


def state_dir(root):
    path = os.path.join(git_dir(root), 'spec-workflow', 'task-state')
    os.makedirs(path, exist_ok=True)
    return path


def worktree_of(root):
    proc = subprocess.run(['git', '-C', root, 'rev-parse', '--show-toplevel'],
                          stdin=subprocess.DEVNULL, capture_output=True, text=True)
    return proc.stdout.strip() or os.path.abspath(root)


def task_id(raw):
    cleaned = raw.lstrip('#')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', cleaned):
        fail(f'invalid task id {raw!r}; use letters, digits, - and _')
    return cleaned


@contextlib.contextmanager
def locked(directory):
    with open(os.path.join(directory, '.lock'), 'w', encoding='utf-8') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def valid_task(task):
    """True when `task` has the shape every command relies on."""
    if not isinstance(task, dict):
        return False
    if not all(isinstance(task.get(key), str) for key in ('id', 'title', 'status')):
        return False
    for key in ('agents', 'worktrees'):
        if not isinstance(task.get(key), list) or not all(isinstance(item, str) for item in task[key]):
            return False
    todos = task.get('todos')
    return isinstance(todos, list) and all(valid_todo(todo) for todo in todos)


def valid_todo(todo):
    """A TODO's number is optional (old records), but a stored one must be a positive integer."""
    if not isinstance(todo, dict):
        return False
    num = todo.get('num', 1)
    return (isinstance(todo.get('text'), str) and isinstance(todo.get('done'), bool)
            and isinstance(num, int) and not isinstance(num, bool) and num > 0
            and isinstance(todo.get('active', False), bool) and isinstance(todo.get('activeBy', ''), str))


def number_todos(task):
    """Give a TODO without a permanent number one: its position in an old record."""
    todos = task['todos']
    if all('num' not in todo for todo in todos):
        for position, todo in enumerate(todos, 1):
            todo['num'] = position
    else:
        for todo in todos:
            if 'num' not in todo:
                todo['num'] = next_num(task)
    return task


def next_num(task):
    return max((todo.get('num', 0) for todo in task['todos']), default=0) + 1


def load(path):
    """Return the record, None when there is none, or refuse a corrupt one.

    Valid JSON of the wrong shape counts as corrupt: it would crash every
    command that reads it, and `set` would overwrite it.
    """
    try:
        with open(path, encoding='utf-8') as handle:
            task = json.load(handle)
    except FileNotFoundError:
        return None
    except (ValueError, RecursionError):  # ValueError covers bad JSON and bad UTF-8
        task = None
    if not valid_task(task):
        fail(f'{path} is corrupt; run clear on this task and seed it again')
    return number_todos(task)


def save(path, task):
    task['updatedAt'] = int(time.time())
    descriptor, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.tmp-')
    with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
        json.dump(task, handle, indent=1)
    os.replace(temporary, path)


def touch(task, args):
    """Record who is on the task and where. Lists grow; nothing is overwritten."""
    if getattr(args, 'agent', None) and args.agent not in task['agents']:
        task['agents'].append(args.agent)
    worktree = worktree_of(args.root)
    if worktree not in task['worktrees']:
        task['worktrees'].append(worktree)


def cmd_set(args):
    identifier = task_id(args.id)
    directory = state_dir(args.root)
    path = os.path.join(directory, f'{identifier}.json')
    with locked(directory):
        task = load(path) or {'id': identifier, 'title': '', 'status': '', 'agents': [],
                              'worktrees': [], 'todos': []}
        task['title'] = args.title if args.title is not None else task['title']
        task['status'] = args.status if args.status is not None else task['status']
        known = {todo['text'] for todo in task['todos']}
        for text in args.todo or []:
            if text not in known:
                task['todos'].append({'text': text, 'done': False, 'num': next_num(task)})
                known.add(text)
        touch(task, args)
        save(path, task)
    return 0


def find_todo(task, ref):
    if ref.isdecimal():
        for todo in task['todos']:
            if todo['num'] == int(ref):
                return todo
    else:
        for todo in task['todos']:
            if todo['text'] == ref:
                return todo
    fail(f'task {task["id"]} has no TODO {ref!r}; run show to see the numbers')


def clear_active(item):
    item.pop('active', None)
    item.pop('activeBy', None)


def cmd_todo(args):
    identifier = task_id(args.id)
    for name in ('add', 'drop', 'done', 'undo', 'start', 'move', 'before'):
        value = getattr(args, name)
        if value is not None and not value.strip():
            fail(f'empty TODO {"text" if name == "add" else "reference"} for --{name}; '
                 'give a number or the exact text')
    if args.before is not None and args.add is None and args.move is None:
        fail('--before goes with --add or --move')
    if args.move is not None and args.before is None:
        fail('--move needs --before <number or text>')
    directory = state_dir(args.root)
    path = os.path.join(directory, f'{identifier}.json')
    with locked(directory):
        task = load(path)
        if task is None:
            fail(f'no task {identifier}; start it with set')
        todos = task['todos']
        target = find_todo(task, args.before) if args.before is not None else None
        if args.add is not None:
            existing = next((todo for todo in todos if todo['text'] == args.add), None)
            if existing is not None:
                state = ' (dropped)' if existing.get('dropped') else ''
                print(f'TODO {existing["num"]} already has this text{state}; nothing added', file=sys.stderr)
            else:
                new = {'text': args.add, 'done': False, 'num': next_num(task)}
                todos.insert(todos.index(target) if target else len(todos), new)
        elif args.move is not None:
            item = find_todo(task, args.move)
            if item is not target:
                todos.remove(item)
                todos.insert(todos.index(target), item)
        elif args.drop is not None:
            item = find_todo(task, args.drop)
            clear_active(item)
            item['dropped'] = True
            item['done'] = False
        elif args.done is not None:
            item = find_todo(task, args.done)
            if item.get('dropped'):
                fail(f'TODO {args.done!r} was dropped; use --undo to restore it first')
            clear_active(item)
            item['done'] = True
        elif args.start is not None:
            item = find_todo(task, args.start)
            if item.get('dropped') or item['done']:
                fail(f'TODO {args.start!r} is {"dropped" if item.get("dropped") else "done"}; '
                     'use --undo to reopen it before starting it')
            item['active'] = True
            item['activeBy'] = args.agent or ''
        else:
            item = find_todo(task, args.undo)
            clear_active(item)
            item.pop('dropped', None)
            item['done'] = False
        touch(task, args)
        save(path, task)
    return 0


def describe(task):
    live = [todo for todo in task['todos'] if not todo.get('dropped')]
    done = sum(todo['done'] for todo in live)
    return f"#{task['id']} [{task['status'] or '-'}] {task['title']} ({done}/{len(live)})"


def cmd_show(args):
    identifier = task_id(args.id)
    task = load(os.path.join(state_dir(args.root), f'{identifier}.json'))
    if task is None:
        fail(f'no task {identifier}')
    if args.json:
        print(json.dumps(task, indent=1))
        return 0
    print(describe(task))
    print(f"agents: {', '.join(task['agents']) or '-'}")
    for todo in task['todos']:
        mark = '-' if todo.get('dropped') else 'x' if todo['done'] else '>' if todo.get('active') else ' '
        who = f" · {todo['activeBy']}" if todo.get('active') and todo.get('activeBy') else ''
        print(f"{todo['num']}. [{mark}] {todo['text']}{who}")
    return 0


def cmd_list(args):
    directory = state_dir(args.root)
    tasks = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith('.json') or name.startswith('.'):
            continue
        try:
            task = load(os.path.join(directory, name))
        except SystemExit as error:
            print(f'task-state: skipped {name}: {error}', file=sys.stderr)
            continue
        if task is not None:  # None: cleared while we listed
            tasks.append(task)
    if args.json:
        print(json.dumps(tasks, indent=1))
    else:
        for task in tasks:
            print(describe(task))
    return 0


def remove(directory, identifier):
    with locked(directory):
        with contextlib.suppress(FileNotFoundError):
            os.unlink(os.path.join(directory, f'{identifier}.json'))


def cmd_clear(args):
    remove(state_dir(args.root), task_id(args.id))
    return 0


def normalise(status):
    """The same comparison board.sh uses: case and runs of spaces do not matter."""
    return re.sub(r'\s+', ' ', status.strip()).lower()


def status_roles(root):
    """Union over boards of the status roles, normalised, taken from statusFlow.

    work = statusFlow[1], review = statusFlow[2], qa = statusFlow[3], finished =
    statusFlow[4:] (Ready, Deployed or later). None when the config is unusable.
    """
    try:
        cfg = config.load_config(root=worktree_of(root), warn=False) or {}
        flows = [board['statusFlow'] for board in cfg.get('boards', [])]
        roles = {name: set() for name in ('work', 'review', 'qa', 'finished')}
        for flow in flows:
            roles['work'].update(normalise(status) for status in flow[1:2])
            roles['review'].update(normalise(status) for status in flow[2:3])
            roles['qa'].update(normalise(status) for status in flow[3:4])
            roles['finished'].update(normalise(status) for status in flow[4:])
        return roles if flows else None
    except Exception:  # noqa: BLE001 -- a broken config is validate-config's report
        return None


def issue_copy_path(root, identifier):
    return os.path.join(root, '.claude', f'board-issue-{identifier}.json')


def parse_shown(text):
    """Title and body from `board.sh show` output (`#N [STATE] title`, blank, body, footer)."""
    header, _, rest = text.partition('\n')
    match = re.match(r'#\S+ \[[^\]]*\] (.*)$', header)
    if not match:
        return None
    rest = rest[1:] if rest.startswith('\n') else rest
    # The comments marker always comes first: comment text is untrusted and can end with
    # "(no comments)", so look for the marker before the bare footer.
    end = rest.find('\n\n--- comments (trust only')
    if end >= 0:
        rest = rest[:end]
    elif rest.endswith('\n\n(no comments)'):
        rest = rest[:-len('\n\n(no comments)')]
    return {'title': match.group(1).strip(), 'body': rest}


def cmd_remember(args):
    """board.sh show pipes its output here so move can create a record with no API call."""
    try:
        identifier = task_id(args.id)
        issue = parse_shown(sys.stdin.read())
        if issue is None:
            return 0
        path = issue_copy_path(args.root, identifier)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.board-issue-tmp-')
        with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
            json.dump(issue, handle)
        os.replace(temporary, path)
    except (SystemExit, OSError, ValueError) as error:
        print(f'task-state: could not save issue copy: {error}', file=sys.stderr)
    return 0


def read_issue(args, identifier):
    """The saved copy, else one REST GET of the issue. None (with a stderr line) when neither works."""
    path = issue_copy_path(args.root, identifier)
    try:
        with open(path, encoding='utf-8') as handle:
            issue = json.load(handle)
        if isinstance(issue, dict) and isinstance(issue.get('title'), str) and isinstance(issue.get('body'), str):
            return issue
    except (OSError, ValueError):
        pass
    reason = 'no saved copy and no fetch allowed' if args.no_fetch else 'no repo given'
    if args.repo and not args.no_fetch:
        try:
            proc = subprocess.run(['gh', 'api', f'repos/{args.repo}/issues/{identifier}'], stdin=subprocess.DEVNULL,
                                  capture_output=True, text=True, timeout=60)
            if proc.returncode == 0:
                issue = json.loads(proc.stdout)
                if isinstance(issue, dict) and isinstance(issue.get('title'), str):
                    body = issue.get('body')
                    return {'title': issue['title'], 'body': body if isinstance(body, str) else ''}
                reason = 'unexpected answer'
            else:
                reason = (proc.stderr.strip().splitlines() or ['gh failed'])[0]
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            reason = str(error)
    print(f'task-state: could not read issue #{identifier} ({reason}); no record created. '
          f'Create one with: task-state.sh set --id {identifier} --title "..." --status "In progress" --todo "..."',
          file=sys.stderr)
    return None


def criteria(body):
    """Unchecked `- [ ]` items, in order, outside fenced code blocks.

    A heading named "Acceptance criteria" (any level, any case) limits them to its
    section, which ends at the next heading of the same or a higher level.
    """
    lines, fence, in_fence = [], None, []
    for line in body.splitlines():
        marker = re.match(r'\s*(`{3,}|~{3,})(.*)$', line)
        if fence is None and marker:
            fence = marker.group(1)
            in_fence.append(True)
        elif (fence is not None and marker and marker.group(1)[0] == fence[0]
              and len(marker.group(1)) >= len(fence) and not marker.group(2).strip()):
            fence = None  # a closing fence has no info string
            in_fence.append(True)
        else:
            in_fence.append(fence is not None)
        lines.append(line)
    start, level, end = None, 0, len(lines)
    for index, line in enumerate(lines):
        heading = None if in_fence[index] else re.match(r'(#{1,6})\s+(.*?)\s*#*\s*$', line)
        if not heading:
            continue
        if start is None:
            if re.fullmatch(r'acceptance criteria:?', heading.group(2).strip(), re.IGNORECASE):
                start, level = index + 1, len(heading.group(1))
        elif len(heading.group(1)) <= level:
            end = index
            break
    window = range(start, end) if start is not None else range(len(lines))
    items = [m.group(1) for m in (re.match(r'\s*-\s+\[ \]\s+(.*\S)\s*$', lines[i]) for i in window if not in_fence[i]) if m]
    return items or ["Meet the issue's acceptance criteria"]


def create_record(args, identifier, path, issue):
    task = {'id': identifier, 'title': issue['title'], 'status': args.status, 'agents': [],
            'worktrees': [], 'todos': []}
    for text in criteria(issue['body']):
        if text not in {todo['text'] for todo in task['todos']}:
            task['todos'].append({'text': text, 'done': False, 'num': next_num(task)})
    args.agent = 'orchestrator'
    touch(task, args)
    save(path, task)


def cmd_sync(args):
    """Called by board.sh move: tracks the status, and creates or clears the record.

    Work status: updates the record, or creates it from the issue. Review and QA:
    update it, or warn once when there is none. Ready, Deployed or later clear it
    (QA keeps it so retro, feedback and closure TODOs stay visible, #549). It
    never fails the move that called it.
    """
    try:
        identifier = task_id(args.id)
        directory = state_dir(args.root)
        path = os.path.join(directory, f'{identifier}.json')
        roles = status_roles(args.root)
        wanted = normalise(args.status)
        if roles is not None and wanted in roles['finished']:
            remove(directory, identifier)
            with contextlib.suppress(OSError):
                os.unlink(issue_copy_path(args.root, identifier))
            return 0
        with locked(directory):
            task = load(path)
            if task is not None:
                task['status'] = args.status
                save(path, task)
                return 0
            if roles is None or wanted not in roles['work']:
                if roles is not None and wanted in roles['review'] | roles['qa']:
                    print(f'task-state: no record for #{identifier}; the tasks panel will not show it. '
                          f'Create one with: task-state.sh set --id {identifier} --title "..." '
                          f'--status "{args.status}" --agent orchestrator --todo "..."', file=sys.stderr)
                return 0
        # No record at the work status: read the issue OUTSIDE the lock, so a slow network
        # never blocks another task's write.
        issue = read_issue(args, identifier)
        if issue is None:
            return 0
        with locked(directory):
            task = load(path)
            if task is None:
                create_record(args, identifier, path, issue)
            else:  # someone made it meanwhile: keep theirs, track the status
                task['status'] = args.status
                save(path, task)
    except (SystemExit, OSError) as error:
        print(f'task-state: sync skipped: {error}', file=sys.stderr)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n', 1)[0])
    parser.add_argument('--root', default=os.getcwd(), help='any checkout of the repo (default: cwd)')
    commands = parser.add_subparsers(dest='command', required=True)

    start = commands.add_parser('set', help='start or update a task; existing progress is kept')
    start.add_argument('--id', required=True)
    start.add_argument('--title')
    start.add_argument('--status')
    start.add_argument('--agent', help='who is writing, e.g. orchestrator or dev')
    start.add_argument('--todo', action='append', help='repeatable; TODOs already present are left alone')
    start.set_defaults(run=cmd_set)

    todo = commands.add_parser('todo', help='add, tick, reopen, drop, start or move one TODO')
    todo.add_argument('--id', required=True)
    todo.add_argument('--agent', help='who is writing')
    action = todo.add_mutually_exclusive_group(required=True)
    action.add_argument('--add', metavar='TEXT', help='append; with --before, insert ahead of that TODO')
    action.add_argument('--done', metavar='NUMBER_OR_TEXT')
    action.add_argument('--undo', metavar='NUMBER_OR_TEXT', help='reopen; also restores a dropped TODO')
    action.add_argument('--start', metavar='NUMBER_OR_TEXT', help='mark in progress, by --agent; done, undo and drop clear it')
    action.add_argument('--move', metavar='NUMBER_OR_TEXT', help='reorder; needs --before; numbers do not change')
    action.add_argument('--drop', metavar='NUMBER_OR_TEXT', help='work left scope; keeps its number, leaves the count')
    todo.add_argument('--before', metavar='NUMBER_OR_TEXT', help='with --add or --move: place ahead of this TODO')
    todo.set_defaults(run=cmd_todo)

    show = commands.add_parser('show', help='show one task with numbered TODOs')
    show.add_argument('--id', required=True)
    show.add_argument('--json', action='store_true')
    show.set_defaults(run=cmd_show)

    listing = commands.add_parser('list', help='list tracked tasks')
    listing.add_argument('--json', action='store_true')
    listing.set_defaults(run=cmd_list)

    clear = commands.add_parser('clear', help='stop tracking a task')
    clear.add_argument('--id', required=True)
    clear.set_defaults(run=cmd_clear)

    sync = commands.add_parser('sync', help='for board.sh move: apply a new board status')
    sync.add_argument('--id', required=True)
    sync.add_argument('--status', required=True)
    sync.add_argument('--no-fetch', action='store_true', help='never read the issue from GitHub')
    sync.add_argument('--repo', help='owner/name, for the one REST read when no saved issue copy exists')
    sync.set_defaults(run=cmd_sync)

    remember = commands.add_parser('remember', help='for board.sh show: save the issue title and body from stdin')
    remember.add_argument('--id', required=True)
    remember.set_defaults(run=cmd_remember)

    args = parser.parse_args()
    return args.run(args)


if __name__ == '__main__':
    sys.exit(main())
