"""Bounded, same-clone mutex for every telemetry append and review check.

Directory creation is portable across supported WSL/Linux/macOS hosts. Never
steal by age/PID: after a hard crash, a human must verify all writers stopped
before removing this directory. No distributed-filesystem guarantees.
"""
from contextlib import contextmanager
import os
import time


@contextmanager
def locked(root):
    # Root is an existing consumer directory. Never recursively create it:
    # append() persists .claude and root, not newly-created root ancestors.
    if not os.path.isdir(root):
        raise OSError(f'telemetry root must be an existing directory: {root}')
    parent = os.path.join(root, '.claude')
    os.makedirs(parent, exist_ok=True)
    path = os.path.join(parent, 'telemetry.lock')
    deadline = time.monotonic() + 2
    while True:
        try:
            os.mkdir(path)
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise OSError('telemetry lock unavailable; stop competing writers and verify all '
                              f'writers are idle before manually removing {path}; never remove a live lock')
            time.sleep(0.025)
    try:
        yield
    finally:
        os.rmdir(path)


def append(path, rec):
    """Flush the event and directory entry before reporting success.

A failed/partial write may leave ambiguous evidence; callers fail closed on
that evidence instead of pretending the attempt was never admitted.
    """
    import json
    # Validate the complete payload before even creating/opening the log.
    # This also protects callers that pass objects without strict_json().
    payload = json.dumps(rec, sort_keys=True, allow_nan=False) + '\n'
    with open(path, 'a', encoding='utf-8') as fh:
        fh.write(payload)
        fh.flush()
        os.fsync(fh.fileno())
    # Also persist a newly-created .claude entry in the existing repo root.
    for directory in (os.path.dirname(path), os.path.dirname(os.path.dirname(path))):
        descriptor = os.open(directory or '.', os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
