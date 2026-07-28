#!/usr/bin/env python3
"""whisper.cpp sidecar lifecycle script (issue #424, SPEC-ASSISTANT.md §13.2,
docs/spec-deltas/applied/ast-051.md). Stdlib only -- this script is invoked as
a bare subprocess by `assistant.provisioning`/`assistant.adapters` (via the
capability's own `capability.yaml`), never imports the `assistant` package,
and must work with no PYTHONPATH set up at all.

Owns exactly what docs/spec-deltas/applied/ast-051.md deferred: install the
`whisper-server` binary + model, manage its process lifecycle (start/stop),
and report an HONEST provisioning status -- never the transcription itself
(that stays the browser client's job; this script never touches
`/transcribe`). The client this sidecar serves already assumes:
  POST http://127.0.0.1:8737/transcribe, multipart "audio" -> {"text": ...}
(neural-view.html's WhisperSttEngine, unmodified by this task).

Actions (argv[1], dispatched by `main()`):
    status  -- read-only health report (this is `capability.yaml`'s
        `provisioning.check` -- Sec11.4: NEVER installs, NEVER starts
        anything, only reports). Exit 0 iff genuinely healthy (installed,
        process alive, port accepting connections); otherwise exits
        nonzero with ONE specific stderr line naming which of the states
        below applies and the fix action.
    install -- fetches the binary + model (Sec11.2/AC: "install runs only
        via an explicit invoke action", never implied by status/start).
        Idempotent: a no-op (exit 0) if already installed. Network
        sources are overridable via WHISPER_SIDECAR_BINARY_SRC/
        WHISPER_SIDECAR_MODEL_SRC for hermetic tests (see `_fetch`).
    start -- spawns the (already-installed) whisper-server as a detached
        background process (pidfile + `start_new_session=True`, so it
        outlives this launcher script's own exit) and polls for health
        before this script itself exits. Idempotent: a no-op (exit 0) if
        already healthy; refuses (never force-starts) if the configured
        port is held by an unrelated process.
    stop -- terminates the tracked process (SIGTERM, escalating to
        SIGKILL if it doesn't exit -- both bounded waits, never hangs
        indefinitely) and removes the pidfile. Idempotent: exit 0 even if
        nothing was running.

Health-state enumeration (issue #424's "protocol-layer-failure-enumeration"
lesson: what can a half-started sidecar legitimately do -- see
`_diagnose()`'s docstring for the exact five states this script
distinguishes, each with its own specific, actionable reason string).

Config (env-overridable so tests never touch the real port/filesystem or
network -- "hermetic-path-fixtures-for-cli-tests" house lesson):
    WHISPER_SIDECAR_STATE_DIR  -- where the binary/model/pidfile live.
        Default: ~/.claude/whisper-sidecar (never inside this skill's own
        plugin-shipped directory, which may be read-only/shared).
    WHISPER_SIDECAR_PORT       -- default 8737 (the port the ALREADY-
        SHIPPED browser client hardcodes -- see module docstring).
    WHISPER_SIDECAR_BINARY_SRC / WHISPER_SIDECAR_MODEL_SRC -- override the
        install sources. An http(s):// URL is downloaded; anything else
        is treated as a local filesystem path and copied -- the seam
        tests use to prove `install` end-to-end with zero network calls.
    WHISPER_SIDECAR_START_TIMEOUT_SECONDS -- how long `start` polls for
        health before giving up (default 15; tests override to a couple
        seconds since the stub server binds its port almost instantly).
"""
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

BIN_NAME = "whisper-server"
MODEL_NAME = "ggml-model.bin"

# Placeholder upstream sources -- real production defaults, NEVER reached in
# tests (WHISPER_SIDECAR_BINARY_SRC/MODEL_SRC always override to a local
# fixture path in every test in section-whisper-sidecar.sh).
DEFAULT_BINARY_URL = "https://github.com/ggerganov/whisper.cpp/releases/latest/download/whisper-server"
DEFAULT_MODEL_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"

DEFAULT_START_TIMEOUT_SECONDS = 15
_POLL_INTERVAL_SECONDS = 0.1
_STOP_WAIT_SECONDS = 3.0


def _state_dir():
    override = os.environ.get("WHISPER_SIDECAR_STATE_DIR")
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".claude", "whisper-sidecar")


def _port():
    try:
        return int(os.environ.get("WHISPER_SIDECAR_PORT", "8737"))
    except ValueError:
        return 8737


def _start_timeout():
    try:
        return float(os.environ.get("WHISPER_SIDECAR_START_TIMEOUT_SECONDS", str(DEFAULT_START_TIMEOUT_SECONDS)))
    except ValueError:
        return DEFAULT_START_TIMEOUT_SECONDS


def _bin_path(state_dir):
    return os.path.join(state_dir, "bin", BIN_NAME)


def _model_path(state_dir):
    return os.path.join(state_dir, "models", MODEL_NAME)


def _pid_path(state_dir):
    return os.path.join(state_dir, "whisper-server.pid")


def _log_path(state_dir):
    return os.path.join(state_dir, "whisper-server.log")


def _is_installed(state_dir):
    b, m = _bin_path(state_dir), _model_path(state_dir)
    return os.path.isfile(b) and os.access(b, os.X_OK) and os.path.isfile(m)


def _fetch(source, dest):
    """Copies (local path) or downloads (http(s):// URL) `source` to
    `dest`, creating parent directories as needed. Raises on failure --
    callers classify. A local-path source is exactly the seam tests use
    to prove `install` end-to-end without any network access ("stub
    everything" -- issue #424's brief)."""
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if source.startswith("http://") or source.startswith("https://"):
        with urllib.request.urlopen(source, timeout=30) as resp, open(dest, "wb") as out:
            shutil.copyfileobj(resp, out)
    else:
        shutil.copyfile(source, dest)


def cmd_install():
    state_dir = _state_dir()
    if _is_installed(state_dir):
        print(f"already installed (binary={_bin_path(state_dir)}, model={_model_path(state_dir)})")
        return 0

    binary_src = os.environ.get("WHISPER_SIDECAR_BINARY_SRC", DEFAULT_BINARY_URL)
    model_src = os.environ.get("WHISPER_SIDECAR_MODEL_SRC", DEFAULT_MODEL_URL)
    bin_dest, model_dest = _bin_path(state_dir), _model_path(state_dir)

    try:
        _fetch(binary_src, bin_dest)
        os.chmod(bin_dest, 0o755)
    except (OSError, urllib.error.URLError) as exc:
        sys.stderr.write(f"install failed: could not fetch whisper-server binary from {binary_src!r}: {exc}\n")
        return 1

    try:
        _fetch(model_src, model_dest)
    except (OSError, urllib.error.URLError) as exc:
        sys.stderr.write(f"install failed: could not fetch model from {model_src!r}: {exc}\n")
        return 1

    print(f"installed (binary={bin_dest}, model={model_dest})")
    return 0


def _read_pid(state_dir):
    """Returns the pidfile's int pid, or None if the pidfile is absent,
    empty, or unparseable (never raises)."""
    path = _pid_path(state_dir)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read().strip()
    except OSError:
        return None
    try:
        return int(text)
    except ValueError:
        return None


def _write_pid(state_dir, pid):
    os.makedirs(state_dir, exist_ok=True)
    with open(_pid_path(state_dir), "w", encoding="utf-8") as fh:
        fh.write(str(pid))


def _clear_pid(state_dir):
    try:
        os.remove(_pid_path(state_dir))
    except OSError:
        pass


def _pid_alive(pid):
    """os.kill(pid, 0) -- True if `pid` exists (whether or not we own it;
    EPERM still means it exists), False once it's genuinely gone."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _port_open(port, timeout=1.0):
    """A bare TCP connect-and-close probe -- proves the sidecar's port is
    bound and accepting connections without building a bespoke HTTP
    client for a real /transcribe round trip (that round trip is the
    browser client's own concern, AST-051, already built and out of this
    task's scope -- flagged simplification, see this task's report)."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


# Health-state enumeration (issue #424's protocol-layer-failure-enumeration
# lesson applied): a half-started sidecar can legitimately be in any of
# these distinct states, each needing its OWN specific, actionable message
# -- collapsing them into a bare "not available" would violate §13.2's
# "never a generic/silent failure" for the one layer this script owns.
STATE_NOT_INSTALLED = "not_installed"
STATE_NOT_RUNNING = "not_running"
STATE_PORT_CONFLICT = "port_conflict"
STATE_STARTING = "starting"
STATE_HEALTHY = "healthy"


def _diagnose(state_dir, port):
    """Returns (state, reason_or_None) -- `reason` is always a specific,
    actionable string except for STATE_HEALTHY (None, nothing to report).

    - STATE_NOT_INSTALLED: binary/model missing -- run install.
    - STATE_NOT_RUNNING: installed, no pidfile at all, OR a STALE pidfile
      (its pid is dead) whose port is ALSO closed. A stale pidfile is
      always cleared as a side effect before this state is returned --
      there is no separate "stale pidfile" state distinct from
      NOT_RUNNING; the reason string still tells the two apart ("a stale
      pidfile was cleared" vs. plain "not running") without a dedicated
      constant, since no caller needs to branch on that distinction.
      Fix action either way: run start.
    - STATE_PORT_CONFLICT: the pidfile's pid is dead, but the configured
      port is nonetheless occupied by SOME process -- never assumed to be
      ours; refuse to touch it, name the port, tell the operator to
      resolve it manually (mirrors neural-view.py's own foreign-port-
      holder precedent -- never blindly rebind/kill an unrelated
      process).
    - STATE_STARTING: the tracked pid is alive but the port isn't open
      yet (model likely still loading) -- transient, retry-later, not a
      failure to install/configure.
    - STATE_HEALTHY: pid alive AND port open."""
    if not _is_installed(state_dir):
        return STATE_NOT_INSTALLED, (
            "whisper-server is not installed -- run the whisper-sidecar capability's "
            "'install' action first"
        )

    pid = _read_pid(state_dir)
    if pid is None:
        if _port_open(port):
            return STATE_PORT_CONFLICT, (
                f"port {port} is occupied by an unrelated process (no pidfile on record) -- "
                "resolve the conflict manually, or set WHISPER_SIDECAR_PORT to a free port"
            )
        return STATE_NOT_RUNNING, (
            "whisper-server is not running -- run the whisper-sidecar capability's 'start' action"
        )

    if not _pid_alive(pid):
        _clear_pid(state_dir)
        if _port_open(port):
            return STATE_PORT_CONFLICT, (
                f"port {port} is occupied by an unrelated process (PID {pid} from the pidfile is "
                "dead) -- resolve the conflict manually, or set WHISPER_SIDECAR_PORT to a free port"
            )
        return STATE_NOT_RUNNING, (
            "whisper-server is not running (a stale pidfile was cleared) -- run the "
            "whisper-sidecar capability's 'start' action"
        )

    if not _port_open(port):
        return STATE_STARTING, (
            f"whisper-server (PID {pid}) is alive but not yet accepting connections on port "
            f"{port} (the model may still be loading) -- retry shortly"
        )

    return STATE_HEALTHY, None


def cmd_status():
    state_dir, port = _state_dir(), _port()
    state, reason = _diagnose(state_dir, port)
    if state == STATE_HEALTHY:
        print(f"healthy: whisper-server is running on 127.0.0.1:{port}")
        return 0
    sys.stderr.write(reason + "\n")
    return 1


def cmd_start():
    state_dir, port = _state_dir(), _port()
    state, reason = _diagnose(state_dir, port)

    if state == STATE_NOT_INSTALLED:
        sys.stderr.write(reason + "\n")
        return 1
    if state == STATE_PORT_CONFLICT:
        sys.stderr.write(reason + "\n")
        return 1
    if state == STATE_HEALTHY:
        print(f"already running on 127.0.0.1:{port}")
        return 0

    deadline = time.monotonic() + _start_timeout()

    if state == STATE_NOT_RUNNING:
        bin_path, model_path = _bin_path(state_dir), _model_path(state_dir)
        log_path = _log_path(state_dir)
        os.makedirs(state_dir, exist_ok=True)
        with open(log_path, "ab") as log:
            proc = subprocess.Popen(
                [bin_path, "--port", str(port), "--model", model_path],
                stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                start_new_session=True,  # detach -- must outlive THIS launcher process
            )
        _write_pid(state_dir, proc.pid)
    # STATE_STARTING: something is already alive under our pidfile -- fall
    # through to the same poll-for-health loop rather than spawning a
    # second instance (never leave orphan processes).

    while time.monotonic() < deadline:
        if _port_open(port):
            print(f"started: whisper-server is running on 127.0.0.1:{port}")
            return 0
        time.sleep(_POLL_INTERVAL_SECONDS)

    sys.stderr.write(
        f"whisper-server did not become healthy on port {port} within "
        f"{_start_timeout():.1f}s (pidfile left in place -- check the log at {_log_path(state_dir)} "
        "or run 'status' again)\n"
    )
    return 1


def cmd_stop():
    state_dir = _state_dir()
    pid = _read_pid(state_dir)
    if pid is None:
        print("not running")
        return 0
    if not _pid_alive(pid):
        _clear_pid(state_dir)
        print("not running (stale pidfile cleared)")
        return 0

    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    deadline = time.monotonic() + _STOP_WAIT_SECONDS
    while time.monotonic() < deadline and _pid_alive(pid):
        time.sleep(_POLL_INTERVAL_SECONDS)

    if _pid_alive(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        deadline = time.monotonic() + _STOP_WAIT_SECONDS
        while time.monotonic() < deadline and _pid_alive(pid):
            time.sleep(_POLL_INTERVAL_SECONDS)

    if _pid_alive(pid):
        sys.stderr.write(f"FAILED to kill PID {pid} -- still alive after SIGKILL\n")
        return 1

    _clear_pid(state_dir)
    print("stopped")
    return 0


_ACTIONS = {"install": cmd_install, "start": cmd_start, "stop": cmd_stop, "status": cmd_status}


def main(argv):
    if len(argv) != 2 or argv[1] not in _ACTIONS:
        sys.stderr.write(f"usage: whisper_sidecar.py <{'|'.join(_ACTIONS)}>\n")
        return 2
    return _ACTIONS[argv[1]]()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
