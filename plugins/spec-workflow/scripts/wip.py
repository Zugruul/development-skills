#!/usr/bin/env python3
"""Shared count-based WIP policy and strict remote snapshot validation.

No reservations or cached occupancy: the shell caller owns serialization and
passes the fresh complete snapshot used to bind its one mutation target.
"""
import contextlib
import copy
import datetime
import fcntl
import json
import os
import re
import sys
import tempfile
import time

import config as C


class WipError(ValueError):
    """Cannot establish safe admission."""


def normalized(status):
    return re.sub(r'\s+', ' ', status.strip()).lower()


class Policy:
    def __init__(self, cfg, board_id=''):
        boards = cfg.get('boards')
        if (not isinstance(boards, list) or not boards
                or any(not isinstance(b, dict) or not isinstance(b.get('id'), str)
                       or not b['id'].strip() for b in boards)):
            raise WipError('boards must contain mappings with nonempty ids')
        self.board = next((b for b in boards if b['id'] == board_id), boards[0])
        flow = self.board.get('statusFlow')
        if (not isinstance(flow, list) or not flow
                or any(not isinstance(s, str) or not s.strip() for s in flow)):
            raise WipError('statusFlow must be a nonempty list of status strings')
        if len(set(map(normalized, flow))) != len(flow):
            raise WipError('statusFlow contains ambiguous normalized statuses')
        methodology = cfg.get('methodology', {})
        if not isinstance(methodology, dict):
            raise WipError('methodology must be a mapping')
        self.limit = methodology.get('maxInProgress', 1)
        self.serial = methodology.get('serialDelivery', False)
        if type(self.limit) is not int or self.limit < 1:
            raise WipError('methodology.maxInProgress must be a positive non-boolean integer')
        if type(self.serial) is not bool:
            raise WipError('methodology.serialDelivery must be a boolean')
        self.work = flow[1] if len(flow) > 1 else flow[0]
        self.review = flow[2] if len(flow) > 2 else None
        # #563: optional separate limits. Absent keeps ONE shared limit over the
        # counted statuses; present gives In progress and In review their own.
        wip_limits = methodology.get('wipLimits')
        self.split = wip_limits is not None
        self.review_limit = self.limit
        if self.split:
            if (not isinstance(wip_limits, dict) or not wip_limits or set(wip_limits) - {'inProgress', 'inReview'}
                    or any(type(v) is not int or v < 1 for v in wip_limits.values())):
                raise WipError('methodology.wipLimits must map inProgress/inReview to positive non-boolean integers')
            self.limit = wip_limits.get('inProgress', self.limit)
            self.review_limit = wip_limits.get('inReview', self.review_limit)
        self.counted = {normalized(self.work)}
        if self.review and (self.serial or (self.split and 'inReview' in wip_limits)):
            self.counted.add(normalized(self.review))

        # Classification uses labels, while GitHub mutates option IDs. An
        # alternate label for a counted ID must not select the unguarded path.
        # Validate only the mapping needed to identify these counted options;
        # this is local config consistency, not a remote schema attestation.
        fields = self.board.get('fields')
        status_field = fields.get('status') if isinstance(fields, dict) else None
        options = status_field.get('options') if isinstance(status_field, dict) else None
        if (not isinstance(options, dict)
                or any(not isinstance(label, str) or not label.strip() for label in options)):
            raise WipError('status options must map nonempty labels to option IDs')
        for counted in self.counted:
            matches = [(label, value) for label, value in options.items()
                       if normalized(label) == counted]
            if len(matches) != 1:
                raise WipError(f'counted status {counted!r} needs one unambiguous normalized option label')
            label, option_id = matches[0]
            if not isinstance(option_id, str) or not option_id.strip():
                raise WipError(f'counted status {counted!r} needs a nonempty option ID')
            if any(other != label and value == option_id for other, value in options.items()):
                raise WipError(f'counted status {counted!r} has an ambiguous option ID shared by another label')

    def occupies(self, status):
        return isinstance(status, str) and normalized(status) in self.counted

    def bucket(self, status):
        """The pool a counted status draws from: one shared pool unless wipLimits splits it."""
        if not self.occupies(status):
            return None
        if self.split and self.review and normalized(status) == normalized(self.review):
            return 'review'
        return 'work' if self.split else 'all'

    def limit_of(self, bucket):
        return self.review_limit if bucket == 'review' else self.limit

    def count(self, items, bucket):
        return sum(self.bucket(it.get('status')) == bucket for it in items)


OVER_FILE = 'over-wip.json'
GRACE_SECONDS = 600  # a record younger than this is never pruned


def over_path(root):
    return f'{root}/.claude/{OVER_FILE}'


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


@contextlib.contextmanager
def over_lock(root):
    os.makedirs(f'{root}/.claude', exist_ok=True)
    with open(f'{root}/.claude/over-wip.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def read_over(root, locked=False):
    """Records keyed '<board>#<issue>'. A corrupt file is moved aside (only by a caller
    holding over_lock, locked=True), never overwritten blindly; others warn and see {}."""
    path = over_path(root)
    try:
        with open(path) as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
        raise ValueError('not a mapping')
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        if not locked:
            print(f'WARN: {path} is corrupt ({exc}); ignoring it (the next recorded overage moves it aside)', file=sys.stderr)
            return {}
        aside = f'{path}.corrupt-{time.strftime("%Y%m%dT%H%M%S")}-{os.getpid()}'
        try:
            os.replace(path, aside)
            print(f'WARN: {path} is corrupt ({exc}); moved aside to {aside}', file=sys.stderr)
        except OSError:
            print(f'WARN: {path} is corrupt ({exc}) and could not be moved aside', file=sys.stderr)
        return {}


def write_over(root, data):
    fd, tmp = tempfile.mkstemp(prefix=f'{OVER_FILE}.tmp', dir=f'{root}/.claude')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, indent=1)
        os.replace(tmp, over_path(root))
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def update_over(root, change):
    """Read-modify-write under the lock; change(data) -> new data."""
    with over_lock(root):
        data = read_over(root, locked=True)
        new = change(copy.deepcopy(data))
        if new != data:
            write_over(root, new)


def _fresh(rec, now):
    try:
        then = datetime.datetime.strptime(rec.get('ts', ''), '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    except (ValueError, TypeError, AttributeError):
        return False
    return (now - then).total_seconds() < GRACE_SECONDS


def live_overages(policy, items, records, now=None):
    """-> (live [(number, record, occupied, limit)], drop {key: record}).

    Only this board's records are judged. A record is dropped only when its issue is SEEN
    outside the counted statuses, or its pool is seen at/under the limit; an issue missing
    from the snapshot keeps its record, and a record younger than the grace period is kept."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    prefix = f"{policy.board['id']}#"
    live, drop = [], {}
    for key, rec in records.items():
        if not key.startswith(prefix) or not isinstance(rec, dict):
            continue
        num = key[len(prefix):]
        item = next((it for it in items if str((it.get('content') or {}).get('number')) == num), None)
        if item is None:
            continue
        bucket = policy.bucket(item.get('status'))
        occupied = policy.count(items, bucket) if bucket else 0
        limit = policy.limit_of(bucket) if bucket else 0
        if bucket and occupied > limit:
            live.append((num, rec, occupied, limit))
        elif not _fresh(rec, now):
            drop[key] = rec
    return live, drop


def snapshot(data):
    if not isinstance(data, dict) or not isinstance(data.get('items'), list):
        raise WipError('malformed board snapshot: expected items array')
    items = data['items']
    total = data.get('totalCount')
    if 'totalCount' in data and (type(total) is not int or total < len(items)):
        raise WipError('malformed board snapshot totalCount')
    ids = set()
    for item in items:
        if (not isinstance(item, dict) or not isinstance(item.get('id'), str)
                or not item['id'].strip() or any(c in item['id'] for c in '\n\r\t')):
            raise WipError('malformed board item identity')
        if item['id'] in ids:
            raise WipError('ambiguous duplicate board item identity')
        ids.add(item['id'])
        if item.get('status') is not None and not isinstance(item['status'], str):
            raise WipError('malformed board item status')
        content = item.get('content')
        if content is not None and not isinstance(content, dict):
            raise WipError('malformed board item content')
        number = (content or {}).get('number')
        if number is not None and (type(number) is not int or number < 1):
            raise WipError('malformed board issue number')
    return items


def target(items, number, repo=None):
    try:
        number = int(number)
    except ValueError as exc:
        raise WipError('target issue must be a number') from exc
    matches = [it for it in items if (it.get('content') or {}).get('number') == number]
    if len(matches) != 1:
        raise WipError(f'target #{number} is missing or ambiguous in the fresh board snapshot')
    item = matches[0]
    repository = (item.get('content') or {}).get('repository')
    if repo and repository is not None and repository != repo:
        raise WipError(f'target #{number} repository does not match the selected board repository')
    return item


def main():
    try:
        action = sys.argv[1]
        if action == 'page':
            # Merged cursor-paginated snapshot (paginate.sh --strict): hasNextPage already
            # proved exhaustion, so require the API's own total to agree with what was read.
            data = json.load(sys.stdin)
            items = snapshot(data)
            if 'totalCount' not in data:
                raise WipError('incomplete board snapshot: no totalCount')
            if data['totalCount'] != len(items):
                raise WipError('incomplete board snapshot: totalCount exceeds returned items')
            print(len(items))
            return 0
        if action == 'record-over':
            # record-over <root> <config> <board> <issue#> <reason> <by> <status> <occupied/limit>
            root, config, board, num, reason, by, status, ratio = sys.argv[2:10]
            key = f"{Policy(C.load_config(path=config, warn=False), board).board['id']}#{int(num)}"
            rec = {'reason': reason, 'by': by, 'status': status, 'ratio': ratio, 'ts': now_iso()}
            update_over(root, lambda data: {**data, key: rec})
            return 0
        cfg = C.load_config(path=sys.argv[2], warn=False)
        policy = Policy(cfg, sys.argv[3])
        if action == 'describe':
            if policy.split:
                parts = [f'{policy.work} {policy.limit}']
                if policy.review and policy.occupies(policy.review):
                    parts.append(f'{policy.review} {policy.review_limit}')
                print('wip limits: ' + ', '.join(parts))
            return 0
        if action == 'classify':
            return 0 if policy.occupies(sys.argv[4]) else 3
        data = json.load(sys.stdin)
        items = snapshot(data)
        if data.get('totalCount', len(items)) != len(items):
            raise WipError('incomplete board snapshot')
        item = target(items, sys.argv[4], policy.board.get('repo'))
        if action == 'current':
            print(item.get('status') or '')
            return 0
        dest = sys.argv[5] if len(sys.argv) > 5 and not sys.argv[5].startswith('--') else policy.work
        over_ok = '--over' in sys.argv[5:]
        dest_bucket = policy.bucket(dest)
        occupied = policy.count(items, dest_bucket)
        limit = policy.limit_of(dest_bucket)
        print(item['id'])
        if policy.bucket(item.get('status')) is None and occupied >= limit:
            if not over_ok:
                raise WipError(f'capacity {occupied}/{limit} occupied; finish or release existing work before starting #{sys.argv[4]}')
            print(f'OVER {occupied + 1}/{limit}')
        return 0
    except (WipError, C.ConfigError, OSError, ValueError, TypeError, KeyError) as exc:
        print(f'WIP BLOCKED: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
