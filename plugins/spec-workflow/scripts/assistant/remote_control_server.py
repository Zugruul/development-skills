#!/usr/bin/env python3
"""AST-080 forced-command dispatcher. Run with Python -I and admin-fixed paths.

Only this module and the selected compute-state helper are needed on the target.
The SSH key's forced command supplies the class; the original command is data.
"""
import argparse
import base64
import binascii
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import time

NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
CLASSES = {"inspect": {"inventory", "status", "logs"}, "cancel": {"cancel"}}
OUTPUT_LIMIT = 131072
LOG_LIMIT = 65536
HELPER_TIMEOUT = 8


class Refusal(Exception):
    """A refused operation; never a reason to retry with broader credentials."""


def identifier(value):
    if not isinstance(value, str) or not NAME.fullmatch(value):
        raise Refusal("invalid identifier")
    return value


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refusal("duplicate request field")
        result[key] = value
    return result


def validate_request(request, operation_class):
    if operation_class not in CLASSES:
        raise Refusal("unknown operation class")
    if not isinstance(request, dict) or type(request.get("version")) is not int or request["version"] != 1:
        raise Refusal("unsupported request version or shape")
    operation = request.get("operation")
    if not isinstance(operation, str) or operation not in CLASSES[operation_class]:
        raise Refusal("operation refused for fixed key class")
    fields = {"version", "operation"} | ({"job_id"} if operation != "inventory" else set())
    if set(request) != fields:
        raise Refusal("operation requires exact fields")
    if operation != "inventory":
        identifier(request["job_id"])
    return request


def encode_request(operation, job_id=""):
    if not isinstance(operation, str) or operation not in CLASSES["inspect"] | CLASSES["cancel"]:
        raise Refusal("unknown operation")
    request = {"version": 1, "operation": operation}
    if operation == "inventory":
        if job_id != "":
            raise Refusal("inventory requires empty job_id")
    else:
        request["job_id"] = identifier(job_id)
    return base64.urlsafe_b64encode(json.dumps(request, separators=(",", ":")).encode("ascii")).decode("ascii").rstrip("=")


def decode_request(command, operation_class):
    if not isinstance(command, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,2048}", command):
        raise Refusal("expected one bounded ASCII request token")
    try:
        raw = base64.b64decode(command + "=" * (-len(command) % 4), altchars=b"-_", validate=True)
        request = json.loads(raw.decode("ascii"), object_pairs_hook=_unique_object)
    except (ValueError, UnicodeError, binascii.Error, RecursionError) as exc:
        raise Refusal("invalid encoded JSON request") from exc
    return validate_request(request, operation_class)


def bounded_run(argv, *, timeout, env=None):
    """Own the entire child group; bound both output pipes and wall time."""
    if not isinstance(timeout, (float, int)) or not 0 < timeout <= 30:
        raise Refusal("invalid subprocess timeout")
    output = [bytearray(), bytearray()]
    child = None
    try:
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, env=env, start_new_session=True)
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            for i, pipe in enumerate((child.stdout, child.stderr)):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, i)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Refusal("subprocess timeout; outcome may be unknown, inspect before retry")
                for key, _ in selector.select(min(remaining, .1)):
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        output[key.data].extend(chunk)
                        if sum(map(len, output)) > OUTPUT_LIMIT:
                            raise Refusal("subprocess output exceeded bound")
            try:
                code = child.wait(timeout=max(.001, deadline - time.monotonic()))
            except subprocess.TimeoutExpired as exc:
                raise Refusal("subprocess timeout; outcome may be unknown, inspect before retry") from exc
        stdout, stderr = (bytes(value).decode("utf-8", errors="replace") for value in output)
        if code:
            raise Refusal(f"subprocess exited {code}: {(stderr or stdout)[-2000:]}")
        return stdout
    except OSError as exc:
        raise Refusal(f"subprocess unavailable: {exc}") from exc
    finally:
        if child is not None:
            # Also reap descendants that inherited pipes after the leader exited.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            child.stdout.close()
            child.stderr.close()


def absolute_path(value):
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        raise Refusal("path must be absolute without parent traversal")
    return path


def checked_path(value, *, directory=False, optional=False):
    """Reject linked ancestors and nonregular leaves on admin-owned helper data.

    The helper's own reads are path-based; this check does not claim to sandbox
    a hostile local writer racing metadata. Logs additionally use descriptor walks.
    """
    path = absolute_path(value)
    try:
        for parent in reversed(path.parents):
            if not stat.S_ISDIR(parent.lstat().st_mode):
                raise Refusal("path ancestor must be a real directory")
        info = path.lstat()
    except FileNotFoundError:
        if optional and path.parent.is_dir():
            return path
        raise Refusal("required path is missing") from None
    mode = info.st_mode
    if directory:
        if not stat.S_ISDIR(mode):
            raise Refusal("path must be a real directory")
    elif not stat.S_ISREG(mode) or info.st_nlink != 1:
        raise Refusal("path must be a single-link regular file")
    elif info.st_size > OUTPUT_LIMIT and path.name != "job.log":
        raise Refusal("metadata exceeds size bound")
    return path


def _validate_helper_inputs(root, request):
    checked_path(root, directory=True)
    checked_path(root / ".state.lock", optional=True)
    checked_path(root / "state.json", optional=True)
    if request["operation"] == "inventory":
        caps = root / "caps"
        if not caps.exists() and not caps.is_symlink():
            return
        checked_path(caps, directory=True)
        entries = list(caps.iterdir())
        if len(entries) > 128:
            raise Refusal("catalog exceeds entry bound")
        for entry in entries:
            if entry.name.startswith(("_", ".")):
                continue
            identifier(entry.name)
            checked_path(entry, directory=True)
            checked_path(entry / ".installed.json", optional=True)
    else:
        directory = checked_path(root / "jobs" / request["job_id"], directory=True)
        for filename in ("record.json", "exitcode", "pid", "cancelled.json", "job.log"):
            checked_path(directory / filename, optional=True)


def _read_log(root, job_id):
    # Open each component relative to the previous fd: a swapped symlink cannot
    # redirect this read outside the selected root, including at the leaf.
    path = absolute_path(root) / "jobs" / identifier(job_id) / "job.log"
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:-1]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        log_fd = os.open("job.log", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        try:
            info = os.fstat(log_fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise Refusal("log must be a single-link regular file")
            os.lseek(log_fd, max(0, info.st_size - LOG_LIMIT), os.SEEK_SET)
            data = os.read(log_fd, LOG_LIMIT)
            return {"job_id": job_id, "text": data.decode("utf-8", errors="replace"),
                    "truncated": info.st_size > LOG_LIMIT}
        finally:
            os.close(log_fd)
    finally:
        os.close(fd)


def execute(command, operation_class, root, helper):
    request = decode_request(command, operation_class)
    root = absolute_path(root)
    helper = checked_path(helper)
    try:
        _validate_helper_inputs(root, request)
        operation = request["operation"]
        if operation == "logs":
            data = _read_log(root, request["job_id"])
        else:
            action = {"inventory": "catalog", "status": "status", "cancel": "cancel"}[operation]
            params = {} if operation == "inventory" else {"id": request["job_id"]}
            output = bounded_run([str(Path(sys.executable).resolve()), "-I", str(helper), action, json.dumps(params)],
                                 timeout=HELPER_TIMEOUT,
                                 env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "REMOTE_COMPUTE_ROOT": str(root)})
            data = json.loads(output)
        result = {"version": 1, "ok": True, "operation": operation, "data": data}
        if len(json.dumps(result, ensure_ascii=True).encode("ascii")) > OUTPUT_LIMIT:
            raise Refusal("response exceeds output bound")
        return result
    except (OSError, ValueError, TypeError) as exc:
        raise Refusal(f"unsafe or unreadable target data: {exc}") from exc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--class", dest="operation_class", required=True, choices=CLASSES)
    parser.add_argument("--root", required=True)
    parser.add_argument("--helper", required=True)
    args = parser.parse_args()
    try:
        result = execute(os.environ.get("SSH_ORIGINAL_COMMAND", ""), args.operation_class, args.root, args.helper)
        print(json.dumps(result, ensure_ascii=True))
        return 0
    except Refusal as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=True))
        print(f"refused: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
