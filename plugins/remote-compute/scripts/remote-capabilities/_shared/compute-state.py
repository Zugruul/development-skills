#!/usr/bin/env python3
"""Target-side, stdlib-only coordination. The protocol is additive to legacy jobs.

_REMOTE_COMPUTE_PROTOCOL_V1_ identifies this payload to hermetic transports.
All controllers sharing a remote account use this account's lock and job store.
"""
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

VERSION = "0.2.0"
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


class Refusal(Exception):
    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


def root_path():
    return Path(os.environ.get("REMOTE_COMPUTE_ROOT") or Path.home() / ".remote-compute")


def name(value):
    if not isinstance(value, str) or not NAME.fullmatch(value):
        raise Refusal("invalid name: %r" % value)
    return value


def write_atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".write-")
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def write_json(path, value):
    write_atomic(path, json.dumps(value, sort_keys=True))


@contextlib.contextmanager
def locked(root):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(root / ".state.lock", "a+") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        state = read_json(root / "state.json", {"schemaVersion": "2.0.0", "reservations": {}})
        try:
            yield state
        finally:
            write_json(root / "state.json", state)


@contextlib.contextmanager
def reading(root):
    try:
        stream = open(root / ".state.lock", "r")
    except FileNotFoundError:
        yield
        return
    with stream:
        fcntl.flock(stream, fcntl.LOCK_SH)
        yield


def process_identity(pid):
    try:
        pid = int(pid)
        if pid <= 1:
            return None
        if Path("/proc").is_dir():
            fields = Path("/proc/%s/stat" % pid).read_text().rsplit(")", 1)[1].split()
            if fields[0] == "Z":
                return None
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            return "%s:%s:%s" % (boot, pid, fields[19])
        result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart=", "-o", "stat="],
                                capture_output=True, text=True, timeout=5)
        value = result.stdout.strip()
        return "%s:%s" % (pid, value) if result.returncode == 0 and value and "Z" not in value.split()[-1] else None
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return None


def group_members(group):
    """Capture identities, not bare PIDs, so later cancellation cannot kill reuse."""
    members = {}
    if Path("/proc").is_dir():
        for path in Path("/proc").glob("[0-9]*/stat"):
            try:
                fields = path.read_text().rsplit(")", 1)[1].split()
                if int(fields[2]) == group and fields[0] != "Z":
                    pid = int(path.parent.name)
                    identity_value = process_identity(pid)
                    if identity_value:
                        members[str(pid)] = identity_value
            except (OSError, ValueError, IndexError):
                continue
    else:
        result = subprocess.run(["ps", "-ax", "-o", "pid=", "-o", "pgid="], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            pid, pgid = map(int, line.split())
            if pgid == group:
                identity_value = process_identity(pid)
                if identity_value:
                    members[str(pid)] = identity_value
    return members


def snapshot(directory):
    directory = Path(directory)
    record = read_json(directory / "record.json", {})
    result = {"id": directory.name, "state": "unknown", "pid": None, "exitcode": None}
    if record.get("phase") == "cancelling":
        if any(process_identity(pid) == value for pid, value in record.get("cancelMembers", {}).items()):
            return dict(result, state="cancelling", pid=record.get("pid"))
    if record.get("processGroup") and not process_identity(record.get("pid")):
        if group_members(record["processGroup"]):
            # A dead supervisor does not prove that its workload stopped.
            return dict(result, state="unknown", pid=record.get("pid"))
    try:
        result["exitcode"] = int((directory / "exitcode").read_text().strip())
        result["state"] = "done" if result["exitcode"] == 0 else "failed"
        if (directory / "cancelled.json").exists():
            result["state"] = "cancelled"
        return result
    except (FileNotFoundError, ValueError):
        pass
    try:
        result["pid"] = int((directory / "pid").read_text().strip())
    except (FileNotFoundError, ValueError):
        if record.get("phase") == "reserved":
            result["state"] = "reserved" if record.get("expires", 0) > time.time() else "lost"
        return result
    actual = process_identity(result["pid"])
    if not actual or (record.get("processIdentity") and actual != record["processIdentity"]):
        result["state"] = "lost"
    elif record.get("phase") == "cancelling":
        result["state"] = "cancelling"
    else:
        result["state"] = "running"
    return result


def active_jobs(root):
    jobs = root / "jobs"
    if not jobs.is_dir():
        return []
    return [s for d in jobs.iterdir() if d.is_dir() and not d.name.startswith(("_", "."))
            for s in [snapshot(d)] if s["state"] in ("running", "reserved", "cancelling", "unknown")]


def identity(root, nickname):
    stamp = root / ".identity"
    if not stamp.exists():
        write_atomic(stamp, name(nickname) + "\n")
    machine = root / ".machine-id"
    if not machine.exists():
        write_atomic(machine, str(uuid.uuid4()) + "\n")
    return {"machineId": machine.read_text().strip(), "nickname": stamp.read_text().strip()}


WORKER = r'''
import json, os, subprocess, sys, tempfile, time
from pathlib import Path
directory = Path(sys.argv[1])
request = json.loads(sys.argv[2])
env = dict(os.environ, COMPUTE_JOB_DIR=str(directory))
code = 1
try:
    deadline = time.monotonic() + 30
    while not (directory / "launch-ready").exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("launch acknowledgement was not persisted; command not run")
        time.sleep(0.02)
    with open(directory / "job.log", "a") as log:
        command = request["cmd"]
        if request.get("activate"):
            command = "{\n" + request["activate"] + "\n} && {\n" + command + "\n}"
        code = subprocess.call(["bash", "-lc", command], cwd=request["workdir"], env=env,
                               stdout=log, stderr=subprocess.STDOUT)
except Exception as exc:
    with open(directory / "job.log", "a") as log:
        log.write("launch error: %s\n" % exc)
fd, temp = tempfile.mkstemp(dir=directory, prefix=".exit-")
with os.fdopen(fd, "w") as stream:
    stream.write(str(code if code >= 0 else 128 - code) + "\n")
os.replace(temp, directory / "exitcode")
'''


def reserve(root, state, request):
    job_id = name(request["id"])
    token = request["token"]
    directory = root / "jobs" / job_id
    previous = read_json(directory / "record.json", {})
    if directory.exists():
        if previous.get("token") == token and previous.get("phase") == "reserved" and previous.get("expires", 0) > time.time():
            return {"reserved": True, "id": job_id}
        raise Refusal("job ID already exists: %s (use a new ID for a retry)" % job_id)
    if job_id in state["reservations"]:
        raise Refusal("job ID was previously used: %s (history was removed; choose a new ID)" % job_id)
    manual = state.get("manualLock")
    if manual and (manual.get("owner"), manual.get("holder")) != (request.get("owner"), request.get("holder")):
        raise Refusal("LOCKED: held by %s: %s" % (manual.get("holder"), manual.get("reason")), 6)
    requested = request.get("limit") or 1
    if not isinstance(requested, int) or requested < 1:
        raise Refusal("maxConcurrentJobs must be a positive integer")
    limit = min(state.setdefault("maxConcurrentJobs", requested), requested)
    active = active_jobs(root)
    if len(active) >= limit:
        raise Refusal("BUSY: maxConcurrentJobs=%s; active: %s" % (limit, ", ".join(j["id"] for j in active)), 6)
    capability = request.get("capability")
    if capability and request.get("digest"):
        installed = read_json(root / "caps" / name(capability) / ".installed.json", {})
        if installed.get("digest") != request["digest"] or not installed.get("active", True):
            raise Refusal("capability changed on target; run capabilities sync before dispatch")
    directory.mkdir(parents=True, mode=0o700)
    record = dict(request, schemaVersion="2.0.0", phase="reserved", expires=time.time() + 3600)
    write_json(directory / "record.json", record)
    state["reservations"][job_id] = token
    return {"reserved": True, "id": job_id}


def launch(root, state, request):
    directory = root / "jobs" / name(request["id"])
    record = read_json(directory / "record.json", {})
    if record.get("token") != request.get("token"):
        raise Refusal("reservation token does not match", 6)
    if record.get("phase") in ("running", "cancelling"):
        return dict(snapshot(directory), launched=True)
    if record.get("phase") != "reserved" or record.get("expires", 0) <= time.time():
        raise Refusal("reservation expired or already finished; inspect job status")
    workdir = Path(os.path.expanduser(request["workdir"]))
    if not workdir.is_dir():
        raise Refusal("workdir does not exist: %s" % workdir)
    if request.get("inputs"):
        shutil.copytree(directory / "inputs", workdir, dirs_exist_ok=True)
    request = dict(request, workdir=str(workdir.resolve()))
    # The child waits for a durable identity record before executing anything.
    # A crashed launch is never retried against the same ID.
    record["phase"] = "launching"
    write_json(directory / "record.json", record)
    with open(directory / "job.log", "a") as log:
        child = subprocess.Popen([sys.executable, "-c", WORKER, str(directory.resolve()), json.dumps(request)],
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    record.update(phase="running", processIdentity=process_identity(child.pid), pid=child.pid, processGroup=child.pid,
                  startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
    write_atomic(directory / "pid", str(child.pid) + "\n")
    write_json(directory / "record.json", record)
    write_atomic(directory / "launch-ready", "ready\n")
    return {"launched": True, "id": request["id"], "pid": child.pid}


def cancel(root, request):
    directory = root / "jobs" / name(request["id"])
    status = snapshot(directory)
    if status["state"] not in ("running", "cancelling"):
        raise Refusal("job is not running (state: %s)" % status["state"])
    pid = status["pid"]
    record = read_json(directory / "record.json", {})
    expected = record.get("processIdentity")
    if not expected:
        raise Refusal("legacy job has no saved process fingerprint; verify its process manually before stopping it")
    members = record.get("cancelMembers", {})
    if process_identity(pid) == expected and expected:
        group = os.getpgid(pid)
        members.update(group_members(group) if group == pid else {str(pid): expected})
    if not members:
        raise Refusal("process identity changed; refusing to signal")
    record.update(phase="cancelling", processIdentity=expected, pid=pid, cancelMembers=members)
    write_json(directory / "record.json", record)
    for member, fingerprint in members.items():
        if process_identity(member) == fingerprint:
            try:
                os.kill(int(member), signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 3
    def survivors():
        return any(process_identity(member) == fingerprint for member, fingerprint in members.items())
    while time.monotonic() < deadline and survivors():
        time.sleep(0.1)
    if survivors():
        raise Refusal("cancellation pending: process is still alive; no exit code recorded", 1)
    if not (directory / "exitcode").exists():
        write_atomic(directory / "exitcode", "143\n")
    write_json(directory / "cancelled.json", {"schemaVersion": "2.0.0", "at": time.time()})
    with open(directory / "job.log", "a") as log:
        log.write("[remote-compute] cancelled by user\n")
    return dict(snapshot(directory), cancelled=True)


def catalog(root):
    entries = {}
    caps = root / "caps"
    if caps.is_dir():
        for directory in sorted(caps.iterdir()):
            if not directory.is_dir() or directory.name.startswith(("_", ".")):
                continue
            metadata = read_json(directory / ".installed.json", {})
            if metadata.get("active", True):
                entries[directory.name] = metadata or {"legacy": True, "description": "legacy payload; reinstall once to publish metadata"}
    return entries


def payload_issues(root, entries):
    issues = []
    for cap, metadata in entries.items():
        for rel, expected in metadata.get("files", {}).items():
            directory = root / "caps" / cap
            path = directory / rel
            try:
                safe = os.path.commonpath([str(path.resolve()), str(directory.resolve())]) == str(directory.resolve())
                if not safe or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                    issues.append("%s/%s: payload checksum/path mismatch; reinstall the trusted bundle" % (cap, rel))
            except OSError:
                issues.append("%s/%s: payload missing or unreadable; reinstall the bundle" % (cap, rel))
    return issues


def cap_commit(root, request):
    cap = name(request["name"])
    stage = root / ".staging" / name(request["stage"])
    if not stage.is_dir() or stage.is_symlink():
        raise Refusal("capability staging directory is missing or unsafe")
    if active_jobs(root):
        raise Refusal("BUSY: finish active jobs before changing capability payloads", 6)
    destination = root / "caps" / cap
    if destination.is_symlink():
        raise Refusal("capability destination must not be a symlink")
    for rel, expected in request["files"].items():
        path = stage / rel
        if os.path.commonpath([str(path.resolve()), str(stage.resolve())]) != str(stage.resolve()) or not path.is_file() or path.is_symlink():
            raise Refusal("unsafe or missing staged payload: %s" % rel)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise Refusal("payload checksum mismatch: %s" % rel)
    metadata = {"schemaVersion": "2.0.0", "manifest": request["manifest"], "digest": request["digest"],
                "files": request["files"], "active": True, "installedAt": time.time()}
    if request.get("source"):
        metadata["source"] = request["source"]
    write_json(stage / ".installed.json", metadata)
    destination.parent.mkdir(parents=True, exist_ok=True)
    previous = root / ".staging" / ("previous-" + uuid.uuid4().hex)
    if destination.exists():
        destination.rename(previous)
    try:
        stage.rename(destination)
    except OSError:
        if previous.exists():
            previous.rename(destination)
        raise
    if previous.exists():
        shutil.rmtree(previous)
    return {"installed": True, "digest": request["digest"]}


def operate(action, request):
    root = root_path()
    if request.get("machineId"):
        try:
            actual = (root / ".machine-id").read_text().strip()
        except FileNotFoundError:
            actual = None
        if actual != request["machineId"]:
            raise Refusal("IDENTITY_MISMATCH: target UUID differs from the registered machine", 7)
    if action == "status":
        return snapshot(root / "jobs" / name(request["id"]))
    if action == "catalog":
        with reading(root):
            return {"capabilities": catalog(root)}
    if action == "doctor":
        with reading(root):
            entries = catalog(root)
            return {"version": VERSION, "python": sys.version.split()[0], "root": str(root),
                    "machineId": (root / ".machine-id").read_text().strip() if (root / ".machine-id").exists() else None,
                    "jobs": [snapshot(d) for d in (root / "jobs").glob("*") if d.is_dir()],
                    "capabilities": entries, "payloadIssues": payload_issues(root, entries)}
    with locked(root) as state:
        if action == "identity":
            return identity(root, request["nickname"])
        if action == "reserve":
            return reserve(root, state, request)
        if action == "launch":
            return launch(root, state, request)
        if action == "abort":
            directory = root / "jobs" / name(request["id"])
            record = read_json(directory / "record.json", {})
            if record.get("token") == request.get("token") and record.get("phase") == "reserved":
                record["phase"] = "aborted"
                write_json(directory / "record.json", record)
                write_atomic(directory / "exitcode", "125\n")
            return {"aborted": True}
        if action == "cancel":
            return cancel(root, request)
        if action == "policy":
            limit = request["maxConcurrentJobs"]
            if not isinstance(limit, int) or limit < 1:
                raise Refusal("maxConcurrentJobs must be a positive integer")
            state["maxConcurrentJobs"] = limit
            return {"maxConcurrentJobs": limit}
        if action in ("lock", "unlock"):
            previous = state.get("manualLock")
            if previous and (previous.get("owner"), previous.get("holder")) != (request.get("owner"), request.get("holder")) and not request.get("force"):
                raise Refusal("LOCKED by %s" % previous.get("holder"), 6)
            if action == "lock":
                for job in active_jobs(root):
                    record = read_json(root / "jobs" / job["id"] / "record.json", {})
                    if (record.get("owner"), record.get("holder")) != (request.get("owner"), request.get("holder")):
                        raise Refusal("BUSY: job %s belongs to another controller/holder" % job["id"], 6)
            state["manualLock"] = request if action == "lock" else None
            return {"previous": previous, "locked": action == "lock"}
        if action == "cap-commit":
            return cap_commit(root, request)
        if action == "cap-remove":
            directory = root / "caps" / name(request["name"])
            if directory.is_symlink():
                raise Refusal("refusing a symlink capability directory")
            if active_jobs(root):
                raise Refusal("BUSY: finish jobs before retiring capability payloads", 6)
            if request.get("purge"):
                if directory.exists():
                    shutil.rmtree(directory)
            elif directory.exists():
                metadata = read_json(directory / ".installed.json", {"schemaVersion": "2.0.0"})
                metadata["active"] = False
                write_json(directory / ".installed.json", metadata)
            return {"removed": True}
    raise Refusal("unknown protocol action: %s" % action)


def main():
    try:
        action = sys.argv[1]
        request = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
        if action == "state-text":
            print(operate("status", request)["state"])
            return 0
        if action == "caps-text":
            entries = operate("catalog", {})["capabilities"]
            for cap, metadata in entries.items():
                print("%-20s %s" % (cap, (metadata.get("manifest") or {}).get("description") or metadata.get("description", "")))
            if not entries:
                print("(none installed)")
            return 0
        result = operate(action, request)
        print(json.dumps(result))
        return 0
    except Refusal as exc:
        print(json.dumps({"error": str(exc)}))
        return exc.code
    except (OSError, ValueError, KeyError, TypeError, IndexError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
