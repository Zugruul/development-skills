"""Local autonomous-review policy; callers hold telemetry's mutex throughout.

This is an attestation boundary, not interception of raw agents/git/gh. Strict
forward checks deliberately differ from telemetry's tolerant metric reader.
"""
import json
import math


class ReviewError(ValueError):
    """Unproven budget or approval: leave the task for a human."""


def strict_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ReviewError(f'ambiguous duplicate JSON key {key!r}')
            result[key] = value
        return result

    def constant(value):
        raise ReviewError(f'non-JSON numeric constant {value}')

    def finite_float(value):
        parsed = float(value)
        if not math.isfinite(parsed):
            raise ReviewError(f'non-finite JSON number {value}')
        return parsed

    return json.loads(raw, object_pairs_hook=pairs, parse_constant=constant,
                      parse_float=finite_float)


def task_key(task):
    if (not isinstance(task, (str, int)) or isinstance(task, bool)
            or not str(task).strip() or str(task) != str(task).strip()):
        raise ReviewError('task must be an integer or nonblank string without surrounding whitespace')
    return str(task)


def validate_review(rec):
    task_key(rec.get('task'))
    if not isinstance(rec.get('ts'), str) or not rec['ts'].strip():
        raise ReviewError('review timestamp must be a nonblank string')
    n = rec.get('round')
    if type(n) is not int or not 1 <= n <= 3:
        raise ReviewError('autonomous round must be an integer in 1..3')
    if rec['kind'] == 'review-round-start':
        if 'pass' in rec or 'verdict' in rec:
            raise ReviewError('reservation cannot include pass or verdict')
    elif not isinstance(rec.get('verdict'), str) or not rec['verdict'].strip():
        raise ReviewError('review verdict must be a nonblank string')


class History:
    def __init__(self):
        self.completed = 0
        self.pending = None
        self.reserved = False
        self.verdict = None

    def apply(self, rec):
        validate_review(rec)
        n = rec['round']
        if rec['kind'] == 'review-round-start':
            if self.pending is not None:
                raise ReviewError(f'round {self.pending} is pending; record its truthful verdict before continuing')
            if n != self.completed + 1:
                raise ReviewError('reservation must advance sequentially; duplicate, regressed or skipped round')
            self.pending = n
            self.reserved = True
        else:
            if n != self.completed + 1:
                raise ReviewError('verdict must advance sequentially; duplicate, conflicting, regressed or skipped round')
            if self.reserved and self.pending != n:
                raise ReviewError('verdict requires its matching pending reservation')
            self.pending = None
            self.completed = n
            self.verdict = rec['verdict'].strip().upper()

    def next_round(self):
        if self.pending is not None:
            raise ReviewError(f'round {self.pending} is pending; record its truthful verdict, never reset the budget')
        if self.completed >= 3:
            raise ReviewError('three autonomous rounds exhausted')
        return self.completed + 1

    def approval(self):
        if self.pending is not None or not self.completed or self.verdict not in ('APPROVE', 'APPROVED'):
            raise ReviewError('latest autonomous round must be completed APPROVE with no pending reservation')


def read_history(path, task, validate_event):
    key = task_key(task)
    history = History()
    try:
        with open(path, encoding='utf-8') as fh:
            for number, line in enumerate(fh, 1):
                # Blank complete lines are harmless historical separators. A
                # missing final newline could be a torn append; never join it.
                if not line.endswith('\n'):
                    raise ReviewError(f'truncated telemetry line {number} (missing newline)')
                if not line.strip():
                    continue
                try:
                    rec = strict_json(line)
                    if validate_event(rec):
                        raise ReviewError('invalid event')
                    rec_task = task_key(rec.get('task'))
                    if rec['kind'] in ('review-round', 'review-round-start') and 'pass' not in rec:
                        validate_review(rec)
                except (ValueError, TypeError, KeyError) as exc:
                    raise ReviewError(f'malformed telemetry line {number}: {exc}') from exc
                if rec_task != key:
                    continue
                if rec['kind'] in ('review-round', 'review-round-start') and 'pass' not in rec:
                    history.apply(rec)
    except FileNotFoundError:
        # A dangling symlink is unreadable evidence, not a fresh budget.
        import os
        if os.path.lexists(path):
            raise ReviewError('telemetry path is a dangling symlink')
    return history
