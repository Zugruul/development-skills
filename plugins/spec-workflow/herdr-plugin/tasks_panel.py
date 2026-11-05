#!/usr/bin/env python3
"""Herdr side panel: tasks being worked on and their TODOs.

  toggle    closes this tab's panel, or opens one to the right.
  run       the panel itself. Keys: r reread, j/k scroll, q close.
  snapshot  prints the panel once and exits.

The panel reads only the local record agents keep up to date through
scripts/task-state.sh (skills/task-state/SKILL.md). It reads no remote task data
and makes no network calls. Repos come from the working directories of the panes
open in herdr. Task text is untrusted, so control characters are stripped before
it reaches the terminal.
"""
import glob
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import termios
import textwrap
import threading
import time
import tty

POLL_SECONDS = 2  # local files only, so polling costs almost nothing
REPO_SECONDS = 30  # how often to look for newly opened repos
OSC_OR_CSI = re.compile(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b\[[0-?]*[ -/]*[@-~]|\x1b.?')
CONTROL = re.compile(r'[\x00-\x1f\x7f-\x9f]')
PANEL_WIDTH_SHRINK = 0.2  # the split starts at half the pane; this narrows it


def clean(text):
    return CONTROL.sub(' ', OSC_OR_CSI.sub('', str(text))).strip()


def herdr_bin():
    return os.environ.get('HERDR_BIN_PATH') or 'herdr'


def herdr(*args):
    """Run herdr. Return its `result` object, or None on any failure."""
    try:
        proc = subprocess.run([herdr_bin(), *args], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
        if proc.returncode:
            return None
        result = json.loads(proc.stdout).get('result')
    except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
        return None
    return result if isinstance(result, dict) else None


# --- toggle -----------------------------------------------------------------

def state_dir():
    path = os.environ.get('HERDR_PLUGIN_STATE_DIR') or os.path.expanduser('~/.cache/spec-workflow/herdr-panel')
    os.makedirs(path, exist_ok=True)
    return path


def process_alive(pid):
    try:
        if int(pid) <= 0:  # kill(0) and kill(-1) would signal whole groups
            return False
        os.kill(int(pid), 0)
    except (OSError, TypeError, ValueError, OverflowError):
        return False
    return True


def forget(record):
    try:
        os.unlink(record)
    except OSError:
        pass


def panels_in_tab(tab):
    """Pane ids of live panels in `tab`.

    The record of a panel whose process is gone, or that is not a valid record,
    is deleted. A live panel that herdr does not answer for keeps its record:
    that is a herdr hiccup, and deleting it would hide the panel from the next
    toggle. It counts as not being in this tab.
    """
    found = []
    for record in glob.glob(os.path.join(state_dir(), 'panel-*.json')):
        try:
            with open(record, encoding='utf-8') as handle:
                panel = json.load(handle)
        except (OSError, ValueError, RecursionError):
            panel = None
        pane_id = panel.get('pane_id') if isinstance(panel, dict) else None
        if not isinstance(pane_id, str) or not pane_id or not process_alive(panel.get('pid')):
            forget(record)
            continue
        pane = herdr('pane', 'get', str(pane_id))
        info = pane.get('pane') if pane is not None else None
        if isinstance(info, dict) and info.get('tab_id') == tab:
            found.append(pane_id)
    return found


def toggle():
    tab = os.environ.get('HERDR_TAB_ID')
    existing = panels_in_tab(tab) if tab else []
    if existing:
        for pane_id in existing:
            herdr('plugin', 'pane', 'close', pane_id)
        return 0
    args = ['plugin', 'pane', 'open', '--plugin', os.environ.get('HERDR_PLUGIN_ID', 'spec-workflow.tasks'),
            '--entrypoint', 'panel', '--placement', 'split', '--direction', 'right', '--no-focus']
    if os.environ.get('HERDR_PANE_ID'):
        args += ['--target-pane', os.environ['HERDR_PANE_ID']]
    opened = herdr(*args)
    if opened is None:
        print('tasks panel: herdr could not open the panel', file=sys.stderr)
        return 1
    plugin = opened.get('plugin_pane')
    pane = plugin.get('pane') if isinstance(plugin, dict) else None
    pane_id = pane.get('pane_id') if isinstance(pane, dict) else None
    if isinstance(pane_id, str) and pane_id:
        herdr('pane', 'resize', '--pane', pane_id, '--direction', 'right', '--amount', str(PANEL_WIDTH_SHRINK))
    return 0


# --- data -------------------------------------------------------------------

def open_repos():
    """(primary checkout, git common dir) of each spec-workflow repo open in herdr."""
    panes = (herdr('pane', 'list') or {}).get('panes')
    panes = panes if isinstance(panes, list) else []
    repos = {}
    for pane in panes:
        cwd = pane.get('cwd') if isinstance(pane, dict) else None
        if not isinstance(cwd, str) or not cwd or not os.path.isdir(cwd):
            continue
        common = subprocess.run(['git', '-C', cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True)
        listing = subprocess.run(['git', '-C', cwd, 'worktree', 'list', '--porcelain'],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if common.returncode or listing.returncode:
            continue
        # The first listed worktree is the primary checkout. With a separate git
        # dir, git lists the git dir itself there, so use this pane's checkout.
        first = listing.stdout.split('\n', 1)[0]
        root = first[len('worktree '):].strip() if first.startswith('worktree ') else ''
        git_dir = common.stdout.strip()
        if not root or os.path.realpath(root) == os.path.realpath(git_dir):
            top = subprocess.run(['git', '-C', cwd, 'rev-parse', '--show-toplevel'],
                                 stdin=subprocess.DEVNULL, capture_output=True, text=True)
            root = top.stdout.strip()
        if root and git_dir not in repos.values() and os.path.exists(os.path.join(root, '.neural-network', 'project.yaml')):
            repos[root] = git_dir
    return sorted(repos.items())


# Each line of the project section is one of two disjoint shapes (blank, or
# indented text), so the lazy repeat cannot backtrack exponentially.
PROJECT_NAME = (r'^project:[ \t]*\n(?:[ \t]*\n|[ \t]+[^ \t\n][^\n]*\n)*?'
                r'[ \t]+name:[ \t]*["\']?([^"\'\n]+)')


def project_name(root):
    try:
        with open(os.path.join(root, '.neural-network', 'project.yaml'), encoding='utf-8') as handle:
            match = re.search(PROJECT_NAME, handle.read(), re.M)
    except (OSError, ValueError):  # unreadable or not UTF-8
        match = None
    return clean(match.group(1)) if match else os.path.basename(root)


def readable(task):
    """True when `task` has the shape scripts/task_state.py accepts (valid_task).

    This mirrors it on purpose: the panel stays standalone, and a test checks
    that the two agree.
    """
    if not isinstance(task, dict):
        return False
    if not all(isinstance(task.get(key), str) for key in ('id', 'title', 'status')):
        return False
    for key in ('agents', 'worktrees'):
        if not isinstance(task.get(key), list) or not all(isinstance(item, str) for item in task[key]):
            return False
    todos = task.get('todos')
    return isinstance(todos, list) and all(readable_todo(todo) for todo in todos)


def readable_todo(todo):
    if not isinstance(todo, dict):
        return False
    num = todo.get('num', 1)
    return (isinstance(todo.get('text'), str) and isinstance(todo.get('done'), bool)
            and isinstance(num, int) and not isinstance(num, bool) and num > 0
            and isinstance(todo.get('active', False), bool) and isinstance(todo.get('activeBy', ''), str))


def read_repo(root, git_dir):
    """Return {'name', 'tasks', 'unreadable'} from the repo's local task state.

    `git_dir` is the git common dir, where scripts/task_state.py keeps the records.
    """
    directory = os.path.join(git_dir, 'spec-workflow', 'task-state')
    tasks, unreadable = [], []
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        names = []
    for name in names:
        if not name.endswith('.json') or name.startswith('.'):
            continue
        try:
            with open(os.path.join(directory, name), encoding='utf-8') as handle:
                task = json.load(handle)
            if not readable(task):
                raise ValueError
            tasks.append(task)
        except (OSError, ValueError, RecursionError):
            unreadable.append(clean(name))
    tasks.sort(key=lambda task: (str(task.get('status')), str(task.get('id')).zfill(12)))
    return {'name': project_name(root), 'tasks': tasks, 'unreadable': unreadable}


REPO_CACHE = {'at': 0, 'roots': []}


def collect(rescan=True):
    if rescan or time.time() - REPO_CACHE['at'] >= REPO_SECONDS:
        REPO_CACHE.update(at=time.time(), roots=open_repos())
    return [read_repo(root, git_dir) for root, git_dir in REPO_CACHE['roots']]


def age(updated_at):
    try:
        seconds = max(0, int(time.time() - float(updated_at)))
    except (TypeError, ValueError, OverflowError):
        return ''
    if seconds < 60:
        return 'just now'
    if seconds < 3600:
        return f'{seconds // 60}m ago'
    if seconds < 86400:
        return f'{seconds // 3600}h ago'
    return f'{seconds // 86400}d ago'


# --- render -----------------------------------------------------------------

BOLD, DIM, GREEN, RESET = '\x1b[1m', '\x1b[2m', '\x1b[32m', '\x1b[0m'


def wrap(text, width, first, rest):
    return textwrap.wrap(text, width=max(width, 8), initial_indent=first, subsequent_indent=rest,
                         break_long_words=True, break_on_hyphens=False) or [first.rstrip()]


def is_active(todo):
    return bool(todo.get('active')) and not todo.get('done') and not todo.get('dropped')


def describe_active(todo):
    who = clean(todo.get('activeBy') or '')
    return clean(todo.get('text')) + (f' · {who}' if who else '')


def render(boards, width, color=False):
    """Return display lines. Each fits `width` before any color is added."""
    paint = (lambda code, line: f'{code}{line}{RESET}') if color else (lambda _code, line: line)
    if not boards:
        return [paint(DIM, line) for line in wrap('No spec-workflow repos are open in herdr.', width, '', '')]
    lines = []
    for board in boards:
        lines += [paint(BOLD, line) for line in wrap(board['name'], width, '', '')]
        for name in board.get('unreadable', []):
            lines += wrap(f'! unreadable state file: {name}', width, '  ', '    ')
        if not board['tasks']:
            lines += [paint(DIM, line) for line in wrap('no active tasks', width, '  ', '  ')]
        status = None
        for task in board['tasks']:
            if task.get('status') != status:
                status = task.get('status')
                lines += [paint(DIM, line) for line in wrap(clean(status or 'no status'), width, '  ', '  ')]
            todos = [todo for todo in task.get('todos') or [] if isinstance(todo, dict)]
            live = [todo for todo in todos if not todo.get('dropped')]
            done = sum(bool(todo.get('done')) for todo in live)
            count = f' ({done}/{len(live)})' if live else ''
            lines += wrap(f"#{clean(task.get('id'))} {clean(task.get('title'))}{count}", width, '  ', '    ')
            who = ', '.join(clean(agent) for agent in task.get('agents') or [])
            meta = ' · '.join(part for part in (who, age(task.get('updatedAt'))) if part)
            if meta:
                lines += [paint(DIM, line) for line in wrap(meta, width, '    ', '    ')]
            for todo in todos:
                if is_active(todo):
                    lines += [paint(BOLD, line) for line in wrap(f'Now: {describe_active(todo)}', width, '    ', '      ')]
            for todo in todos:
                dropped = bool(todo.get('dropped'))
                active = is_active(todo)
                mark = '[-] ' if dropped else '[x] ' if todo.get('done') else '[>] ' if active else '[ ] '
                text = describe_active(todo) if active else clean(todo.get('text'))
                wrapped = wrap(mark + text, width, '    ', '        ')
                if active:
                    lines += [paint(BOLD, line) for line in wrapped]
                elif dropped:
                    lines += [paint(DIM, line) for line in wrapped]
                else:
                    lines += [paint(DIM + GREEN, line) for line in wrapped] if todo.get('done') else wrapped
            if not todos:
                lines += [paint(DIM, line) for line in wrap('no TODOs recorded', width, '    ', '    ')]
        lines.append('')
    return lines[:-1]


def snapshot():
    width = shutil.get_terminal_size((60, 24)).columns
    print('\n'.join(render(collect(), width)))
    return 0


# --- interactive panel ------------------------------------------------------

class Panel:
    def __init__(self):
        self.scroll = 0
        self.last_frame = None

    def draw(self, boards):
        size = shutil.get_terminal_size((60, 24))
        body = render(boards, size.columns - 1, color=True)
        height = max(size.lines - 2, 1)
        self.scroll = max(0, min(self.scroll, len(body) - height))
        header = f'{BOLD}Tasks{RESET}'
        frame = '\x1b[H\x1b[2J' + header + '\r\n\r\n' + '\r\n'.join(body[self.scroll:self.scroll + height])
        if frame != self.last_frame:
            self.last_frame = frame
            try:
                sys.stdout.write(frame)
                sys.stdout.flush()
            except OSError:
                raise SystemExit(0)  # the terminal is gone: its pane was closed


def write_record():
    pane_id = os.environ.get('HERDR_PANE_ID')
    if not pane_id:
        return None
    record = os.path.join(state_dir(), f"panel-{re.sub(r'[^A-Za-z0-9_-]', '-', pane_id)}.json")
    with open(record, 'w', encoding='utf-8') as handle:
        json.dump({'pane_id': pane_id, 'pid': os.getpid()}, handle)
    return record


KEYS = re.compile(rb'\x1b\[[AB]|.', re.S)  # arrow keys, else one byte


def leave_terminal(fd, saved):
    """Undo the setup in run(). A terminal that is already gone is not an error."""
    try:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        sys.stdout.write('\x1b[?25h\x1b[?1049l')
        sys.stdout.flush()
    except (OSError, termios.error, ValueError):
        # Unsent output would fail again at exit and change the exit code.
        os.dup2(os.open(os.devnull, os.O_WRONLY), 1)


def run():
    record = write_record()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))  # a background job starts with SIGINT ignored
    panel = Panel()
    resized = threading.Event()
    signal.signal(signal.SIGWINCH, lambda *_: resized.set())
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    sys.stdout.write('\x1b[?1049h\x1b[?25l')
    try:
        tty.setcbreak(fd)
        boards = collect()
        panel.draw(boards)
        next_read = time.time() + POLL_SECONDS
        while True:
            ready, _, _ = select.select([fd], [], [], 0.25)
            redraw = resized.is_set()
            if ready:
                try:
                    data = os.read(fd, 64)
                except OSError:
                    return 0  # the terminal is gone
                if not data:
                    return 0  # end of input
                for key in KEYS.findall(data):  # a fast burst arrives as one read
                    if key == b'q':
                        return 0
                    if key == b'r':
                        next_read = 0
                        REPO_CACHE['at'] = 0
                    elif key in (b'j', b'\x1b[B'):
                        panel.scroll += 1
                        redraw = True
                    elif key in (b'k', b'\x1b[A'):
                        panel.scroll = max(0, panel.scroll - 1)
                        redraw = True
            if time.time() >= next_read:
                boards = collect(rescan=False)
                next_read = time.time() + POLL_SECONDS
                redraw = True
            if redraw:
                resized.clear()
                panel.draw(boards)
    except KeyboardInterrupt:
        return 0
    finally:
        leave_terminal(fd, saved)
        if record:
            forget(record)


COMMANDS = {'toggle': toggle, 'run': run, 'snapshot': snapshot}

if __name__ == '__main__':
    command = COMMANDS.get(sys.argv[1] if len(sys.argv) > 1 else '')
    if command is None:
        sys.exit('usage: tasks_panel.py toggle|run|snapshot')
    sys.exit(command())
