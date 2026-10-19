#!/usr/bin/env python3
"""Shared count-based WIP policy and strict remote snapshot validation.

No reservations or cached occupancy: the shell caller owns serialization and
passes the fresh complete snapshot used to bind its one mutation target.
"""
import json
import re
import sys

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
        self.counted = {normalized(self.work)}
        if self.serial and self.review:
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
            data = json.load(sys.stdin)
            items = snapshot(data)
            # A short result contradicting the API's total count is incomplete.
            if len(items) < int(sys.argv[2]) and data.get('totalCount', len(items)) != len(items):
                raise WipError('incomplete board snapshot: totalCount exceeds returned items')
            print(len(items))
            return 0
        cfg = C.load_config(path=sys.argv[2], warn=False)
        policy = Policy(cfg, sys.argv[3])
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
        occupied = sum(policy.occupies(it.get('status')) for it in items)
        if not policy.occupies(item.get('status')) and occupied >= policy.limit:
            raise WipError(f'capacity {occupied}/{policy.limit} occupied; finish or release existing work before starting #{sys.argv[4]}')
        print(item['id'])
        return 0
    except (WipError, C.ConfigError, OSError, ValueError, TypeError, KeyError) as exc:
        print(f'WIP BLOCKED: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
