#!/usr/bin/env python3
"""remote-compute.py — register remote machines as user-level
compute resources and advertise their availability to projects.

Design: docs/design/remote-compute-plan.md. This is the HUMAN dev-workflow
layer (the orchestrator session operating machines the human owns, under the
human's own key). It implements nothing of SPEC-ASSISTANT §14/E7 and must not
be cited as satisfying any §14 requirement.

Registry lives at $COMPUTE_HOME (default ~/.remote-compute)/resources.yaml —
machine-local, never committed. `enable` advertises a machine to a project —
non-exclusive, capability-style (mirrors assistant.capabilities.<name>): the
repo's .neural-network/project.local.yaml `compute:` section gets a map keyed by alias with
{enabled, roles, probedAt, informational capability snapshot}; never
host/user/secrets. Many projects may enable the same machine — the machine-
account's cooperative admission lock serializes actual use. Run probe explicitly
when fresh hardware information is needed; dispatch does not re-probe hardware.

Hard rules enforced here: every ssh invocation carries -o BatchMode=yes (key
auth only, never a password prompt); sudo-containing payloads are rejected;
no dispatch to a resource locked by someone else; probes record real command
output or a verbatim error — never a guess.

CLI verbs (machine-readable output; interactivity is the calling agent's job):
    register <nick> [user@host] [--accept-hostkey]   converge to end-state
    probe <nick> | status [<nick>] | list
    scan [<nick>...] [--subnet CIDR]... [--dry-run] [--pick NICK=HOST]
             re-find direct machines whose address moved (DHCP): sweep their SSH port, match
             the PINNED host key AND the stable UUID (legacy: .identity), then
             converge known_hosts + ssh alias + registry to the new host
    identity <nick>          print the identity stamp the machine carries
    enable <nick> --root <repo> [--role R]...     advertise to a project
    disable <nick> --root <repo>                  keep entry, enabled: false
    add-env <nick> NAME --activate CMD [--verify SNIPPET] | envs <nick>
    add-job <nick> <name> --workdir DIR --cmd CMD [--env NAME] [--param ...]
    remove-job <nick> <name> | jobs <nick> | run <nick> <job> [--param K=V]
    capabilities list | capabilities installed [<nick>]
    capabilities install <nick> <name-or-bundle-dir>
    capabilities install <nick> <github-url> [<capability-name>|--all] [--ref REF]
    capabilities sync <nick> | capabilities validate <name-or-bundle-dir>
    install-capability <nick> <bundle-dir>   (legacy alias)
    capabilities <nick>                      (legacy installed-capability view)
    remove-capability <nick> NAME [--purge-remote | --retire-remote]
    install-cli [--prefix ~/.local]   install the combined controller/target CLI
    doctor [<nick>] [--json]          read-only connectivity and readiness checks
    policy <nick> --max-concurrent-jobs N   set the target-wide admission limit
    version [--json] | <command> --help
    -h | --help | help         show this command list
    exec <nick> -- <cmd...>
    install-tools <nick>     (re)ship compute-top + the on-machine `remote-compute` command,
             and stamp ~/.remote-compute/.identity with the nick
    connect [<nick>...]      print the ssh one-liners for each machine (+ up/down)
    lock <nick> [--holder H] [--reason R] | unlock <nick> [--force]
    dispatch <nick> --workdir W --cmd C [--env E] [--inputs DIR]
             [--job-id ID] [--holder H]
    job-status <id> | job-logs <id> | job-pull <id> [--dest D] | job-cancel <id>
    remove <nick>
    setup-sheet wsl2|linux|macos
    parse gpu|free|df|profiler   (stdin -> JSON; unit-test surface)

Exit codes: 0 ok · 1 unreachable · 2 usage · 3 NEEDS_KEY_AUTH ·
4 NEEDS_HOSTKEY_ACK · 5 sudo rejected · 6 locked · 7 identity conflict.
"""
import concurrent.futures
import argparse
import copy
import datetime
import fcntl
import getpass
import hashlib
import ipaddress
import json
import os
import re
import shlex
import socket
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

try:
    import yaml
except ImportError:  # same hard-environment stance as config.py
    sys.stderr.write("PREFLIGHT FAIL: PyYAML is required (pip install pyyaml)\n")
    sys.exit(1)

# The remote layout, in ONE place: everything this tool creates on a compute
# machine lives under ~/.remote-compute/ (jobs, capability payloads), mirroring
# the local registry root so the two sides read the same on both machines.
REMOTE_ROOT = "~/.remote-compute"
REMOTE_JOBS_ROOT = REMOTE_ROOT + "/jobs"
REMOTE_TOOLS_ROOT = REMOTE_ROOT + "/tools"   # compute-top.py + the on-machine command source
IDENTITY_FILE = REMOTE_ROOT + "/.identity"   # holds the nick and only that; scan's second factor
REMOTE_BIN_ROOT = REMOTE_ROOT + "/bin"       # ~/.remote-compute/bin/remote-compute, linked from ~/.local/bin
SHARED_TOOLS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "remote-capabilities", "_shared")

EXIT_UNREACHABLE, EXIT_USAGE, EXIT_KEYAUTH, EXIT_HOSTKEY, EXIT_SUDO, EXIT_LOCKED, EXIT_IDENTITY = 1, 2, 3, 4, 5, 6, 7
VERSION = "0.2.0"


def _env(name, default):
    return os.environ.get(name) or default


def compute_home():
    return _env("COMPUTE_HOME", os.path.expanduser("~/.remote-compute"))


def ssh_config_path():
    return _env("COMPUTE_SSH_CONFIG", os.path.expanduser("~/.ssh/config"))


def known_hosts_path():
    return os.path.join(os.path.dirname(ssh_config_path()), "known_hosts")


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


# --- registry ---------------------------------------------------------------

def registry_path():
    return os.path.join(compute_home(), "resources.yaml")


class Registry(dict):
    """A snapshot retains its base so concurrent field edits can be merged."""


def load_registry():
    try:
        with open(registry_path()) as f:
            data = yaml.safe_load(f) or {}
    except FileNotFoundError:
        data = {"schemaVersion": "2.0.0"}
    data.setdefault("schemaVersion", 1)
    data.setdefault("resources", {})
    snapshot = Registry(data)
    snapshot.base = copy.deepcopy(data)
    return snapshot


def _merge_edits(base, changed, current):
    if not all(isinstance(value, dict) for value in (base, changed, current)):
        return copy.deepcopy(changed)
    result = copy.deepcopy(current)
    for key in base.keys() - changed.keys():
        result.pop(key, None)
    for key, value in changed.items():
        if key not in base:
            result[key] = copy.deepcopy(value)
        elif value != base[key]:
            result[key] = _merge_edits(base[key], value, result.get(key))
    return result


def save_registry(data, touched=None):
    """Persist the registry. `touched` names the resource this caller actually
    modified: the file is re-read immediately before writing and only that
    resource is applied, so a long-running verb (dispatch holds its copy across
    many seconds of ssh) cannot silently erase another process's concurrent
    write to a different resource — or to jobs/envs on the same one."""
    os.makedirs(compute_home(), mode=0o700, exist_ok=True)
    with open(os.path.join(compute_home(), ".registry.lock"), "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        fresh = load_registry()
        if hasattr(data, "base"):
            result = _merge_edits(data.base, data, fresh)
        elif touched:
            result = dict(fresh)
            if touched in data.get("resources", {}):
                result["resources"][touched] = data["resources"][touched]
            else:
                result["resources"].pop(touched, None)
        else:
            result = dict(data)
        fd, tmp = tempfile.mkstemp(dir=compute_home(), prefix=".resources.")
        try:
            with os.fdopen(fd, "w") as f:
                yaml.safe_dump(dict(result), f, default_flow_style=False, sort_keys=False, indent=4)
            os.replace(tmp, registry_path())
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        if hasattr(data, "base"):
            data.base = copy.deepcopy(dict(data))


def get_resource(name, required=True):
    reg = load_registry()
    res = reg["resources"].get(name)
    if res is None and required:
        print("ERROR: '%s' is not a registered compute resource (run register first)" % name)
        sys.exit(EXIT_USAGE)
    return res


# --- parsers (every capability claim comes from real output) ----------------

def parse_gpu_csv(text):
    """nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
    — authoritative: the ASCII table truncates long names (a 5090 Laptop GPU
    shows as 'NVIDIA GeForce RTX 5090 ...')."""
    line = next((l for l in text.splitlines() if l.strip()), "")
    parts = [p.strip() for p in line.split(",")]
    if len(parts) < 3:
        return {"present": False, "error": (text or "no csv output")[:500]}
    gpu = {"present": True, "name": parts[0], "driver": parts[2]}
    m = re.match(r"(\d+)", parts[1])
    if m:
        gpu["vramMB"] = int(m.group(1))
    return gpu


def parse_gpu(text):
    gpu = {"present": False}
    # WSL's nvidia-smi prints 'KMD Version:' / 'CUDA UMD Version:' where the
    # native build prints 'Driver Version:' / 'CUDA Version:' — accept both.
    m = re.search(r"(?:Driver|KMD) Version:\s*([\d.]+)", text)
    if m:
        gpu["driver"] = m.group(1)
    m = re.search(r"CUDA(?: UMD)? Version:\s*([\d.]+)", text)
    if m:
        gpu["cuda"] = m.group(1)
    m = re.search(r"^\|\s+\d+\s+(.+?)\s+(?:On|Off|N/A)\s+\|", text, re.M)
    if m:
        gpu["name"] = m.group(1).strip()
        gpu["present"] = True
    m = re.search(r"\d+MiB\s*/\s*(\d+)MiB", text)
    if m:
        gpu["vramMB"] = int(m.group(1))
    return gpu


def parse_free(text):
    for line in text.splitlines():
        if line.startswith("Mem:"):
            nums = re.findall(r"\d+", line)
            if nums:
                return {"ramGB": int(nums[0])}
    return {"ramGB": None}


def _size_to_gb(tok):
    m = re.match(r"([\d.]+)([KMGTP]?)", tok or "")
    if not m:
        return None
    val, unit = float(m.group(1)), m.group(2)
    factor = {"K": 1.0 / (1024 * 1024), "M": 1.0 / 1024, "G": 1, "T": 1024, "P": 1024 * 1024}.get(unit, 1)
    return int(val * factor)


SLOW_FILESYSTEMS = ("drvfs", "9p", "cifs", "nfs")
# Pseudo-filesystems are not storage the human can put a dataset on; listing
# them as "disks" makes the descriptor lie about available space.
PSEUDO_FILESYSTEMS = ("tmpfs", "devtmpfs", "overlay", "squashfs", "proc", "sysfs")


def parse_df(text):
    """Accepts `df -hPT` (Type column — preferred, lets us classify slow and
    drop pseudo-filesystems) and plain `df -hP` (no Type column)."""
    lines = text.splitlines()
    if not lines:
        return {"disks": []}
    typed = "Type" in lines[0]
    disks = []
    for line in lines[1:]:
        parts = line.split()
        if len(parts) < (7 if typed else 6):
            continue
        fstype = parts[1].lower() if typed else parts[0].lower()
        if typed and fstype in PSEUDO_FILESYSTEMS:
            continue
        disk = {"mount": parts[6] if typed else parts[5],
                "freeGB": _size_to_gb(parts[4] if typed else parts[3])}
        if fstype in SLOW_FILESYSTEMS:
            disk["slow"] = True
        disks.append(disk)
    return {"disks": disks}


def parse_profiler(text):
    m = re.search(r"Chipset Model:\s*(.+)", text)
    name = m.group(1).strip() if m else None
    # MPS is an Apple-silicon capability: DERIVE it from the reported chip
    # rather than assuming every Mac has it (an Intel Mac with an AMD GPU does
    # not). Hard rule 4: claims come from real output.
    mps = bool(name) and re.match(r"Apple\s+M\d", name) is not None
    return {"present": bool(name), "name": name, "mps": mps, "cuda": None}


# --- transport (BatchMode always; the fake-transport env seam for tests) ----

def _bin(var, default):
    return _env(var, default)


def ssh_opts():
    """The hardening every remote connection must carry (hard rule 1). Shared
    by ssh_argv and by rsync's -e, because rsync spawns its OWN ssh: without
    this it would bypass BatchMode (and could block on a password prompt in an
    autonomous loop), the pinned known_hosts, and COMPUTE_SSH_CONFIG."""
    return ["-F", ssh_config_path(), "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=%s" % known_hosts_path(),
            "-o", "ConnectTimeout=8"]


def rsync_argv(*args):
    """rsync with the same transport hardening as ssh_argv."""
    ssh_cmd = " ".join(shlex.quote(part)
                       for part in [_bin("COMPUTE_SSH_BIN", "ssh")] + ssh_opts())
    return [_bin("COMPUTE_RSYNC_BIN", "rsync"), "-az", "--partial", "-e", ssh_cmd] + list(args)


def ssh_argv(alias, payload):
    # ssh JOINS everything after the destination into one string that the
    # remote LOGIN shell (possibly zsh) re-parses — so the payload must be
    # shipped as a single, fully-quoted `bash -lc <payload>` word, or a
    # multi-word payload silently loses its arguments/operators to the outer
    # shell (found live on a zsh WSL2 box: `free -g` ran as plain `free`).
    return ([_bin("COMPUTE_SSH_BIN", "ssh")] + ssh_opts()
            + [alias, "bash -lc %s" % shlex.quote(payload)])


def ssh_run(alias, payload, timeout=60):
    try:
        p = subprocess.run(ssh_argv(alias, payload), capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout after %ss" % timeout
    except OSError as exc:
        return 127, "", str(exc)


def remote_state(nick, action, request):
    # Shipping the stdlib helper inline lets current controllers coordinate on
    # older targets without requiring an installed daemon or a tool upgrade.
    request = dict(request)
    resource = load_registry().get("resources", {}).get(nick, {})
    if resource.get("machineId"):
        request["machineId"] = resource["machineId"]
    source = Path(SHARED_TOOLS_DIR, "compute-state.py").read_text(encoding="utf-8")
    payload = "python3 -c %s %s %s" % (shlex.quote(source), shlex.quote(action), shlex.quote(json.dumps(request)))
    rc, out, err = ssh_run(nick, payload, timeout=120)
    try:
        reply = json.loads(out)
        if not isinstance(reply, dict):
            raise ValueError("not an object")
    except ValueError:
        return rc or 1, {"error": err or "target did not return a valid coordination response", "ambiguous": True}
    acknowledgements = {"reserve": "reserved", "launch": "launched", "cap-commit": "installed", "catalog": "capabilities", "status": "state"}
    if not rc and action in acknowledgements and acknowledgements[action] not in reply:
        return 1, {"error": "target response omitted %s" % acknowledgements[action], "ambiguous": True}
    return rc, reply


def controller_id():
    directory = Path(compute_home())
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / ".controller-id"
    with open(directory / ".controller.lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not path.exists():
            path.write_text(str(uuid.uuid4()) + "\n")
            path.chmod(0o600)
        return path.read_text().strip()


def new_job_id():
    return "j%s-%s" % (datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M%S%f"), uuid.uuid4().hex[:8])


def render_command(template, values, paths):
    """Render from the original text only, respecting its shell quote context."""
    result, quote, i = [], None, 0
    token = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
    while i < len(template):
        char = template[i]
        if char == "\\" and quote != "'" and i + 1 < len(template):
            result.append(template[i:i + 2])
            i += 2
            continue
        match = token.match(template, i)
        if match and match[1] in (values.keys() | paths.keys()):
            key = match[1]
            if key in paths:
                word = remote_path(paths[key])
                result.append((quote or "") + word + (quote or ""))
            else:
                value = str(values[key])
                if quote == "'":
                    result.append(value.replace("'", "'\"'\"'"))
                elif quote == '"':
                    result.append(re.sub(r'([\\"$`])', r'\\\1', value))
                else:
                    result.append(shlex.quote(value))
            i = match.end()
            continue
        if char in ("'", '"'):
            if quote is None:
                quote = char
            elif quote == char:
                quote = None
        result.append(char)
        i += 1
    return "".join(result)


def remote_path(p):
    """Quote a remote path WITHOUT killing tilde expansion.

    A tilde inside single quotes is literal, so shlex.quote("~/train") yields
    '~/train' and the remote shell then does `cd '~/train'` (fails) or creates
    a directory literally named "~". Rewrite a leading ~/ as "$HOME"/ — $HOME
    is expanded by the shell but is not operator-controlled — and quote only
    the remainder, which is the part that could carry metacharacters.
    """
    p = (p or "").strip()
    if p in ("~", "~/"):
        return '"$HOME"'
    if p.startswith("~/"):
        return '"$HOME"/%s' % shlex.quote(p[2:])
    return shlex.quote(p)


def reject_sudo(payload):
    if re.search(r"\bsudo\b", payload):
        print("ERROR: payload contains sudo — this tool never runs sudo, locally or remotely"
              " (hard rule 2); privileged steps are printed for the human instead")
        sys.exit(EXIT_SUDO)


# --- ssh config alias (idempotent convergence) ------------------------------

def ensure_alias(nick, host, user):
    path = ssh_config_path()
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    text = ""
    if os.path.exists(path):
        with open(path) as f:
            text = f.read()
    block = "Host %s\n    HostName %s\n    User %s\n" % (nick, host, user)
    existing = re.search(r"(?ms)^Host %s$.*?(?=^Host |\Z)" % re.escape(nick), text)
    if existing:
        # CONVERGE, don't skip: re-registering with a new target must rewrite
        # HostName/User. Returning early left the alias pointing at the OLD
        # machine while the registry described the new one, so every later
        # probe and dispatch silently described the wrong host.
        old = existing.group(0)
        # keep any directive the human added (Port, IdentityFile, ProxyJump...)
        # -- converging the target must not silently delete their config
        extra = [ln for ln in old.splitlines()[1:]
                 if ln.strip() and not re.match(r"\s*(HostName|User)\s", ln)]
        new_block = block + ("\n".join(extra) + "\n" if extra else "")
        if old.strip() == new_block.strip():
            return False
        text = text[:existing.start()] + new_block + text[existing.end():]
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        text = text + block
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, 0o600)
    return True


def alias_target(nick):
    """Read HostName/User back out of an existing alias block."""
    try:
        with open(ssh_config_path()) as f:
            text = f.read()
    except FileNotFoundError:
        return None, None
    m = re.search(r"(?ms)^Host %s$(.*?)(?=^Host |\Z)" % re.escape(nick), text)
    if not m:
        return None, None
    host = re.search(r"HostName\s+(\S+)", m.group(1))
    user = re.search(r"User\s+(\S+)", m.group(1))
    return (host.group(1) if host else None), (user.group(1) if user else None)


def ssh_endpoint(nick, host=None, user=None):
    endpoint = {"host": host, "user": user, "port": 22, "proxyjump": None, "proxycommand": None}
    try:
        result = subprocess.run([_bin("COMPUTE_SSH_BIN", "ssh"), "-G"] + ssh_opts() + [nick],
                                capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                parts = line.split(None, 1)
                if len(parts) != 2:
                    continue
                key, value = parts
                if key == "hostname" and not host:
                    endpoint["host"] = value
                elif key == "user" and not user:
                    endpoint["user"] = value
                elif key == "port":
                    endpoint["port"] = int(value)
                elif key in ("proxyjump", "proxycommand", "hostkeyalias") and value != "none":
                    endpoint[key] = value
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return endpoint


def _host_token(host, port=22):
    return host if port == 22 else "[%s]:%s" % (host, port)


# --- probe (each step failure-isolated; errors recorded verbatim) -----------

def probe_resource(nick, res):
    caps = {}
    platform = {"os": None, "quirks": {}}
    rc, out, err = ssh_run(nick, "uname -s")
    uname = out if rc == 0 else None
    if uname == "Darwin":
        platform["os"] = "macos"
    elif uname == "Linux":
        rc2, out2, _ = ssh_run(nick, "cat /proc/version 2>/dev/null")
        if rc2 == 0 and "microsoft" in out2.lower():
            platform["os"] = "windows-wsl2"
        else:
            platform["os"] = "linux"
    elif uname is not None:
        platform["os"] = uname.lower()
    else:
        platform["quirks"]["unameError"] = err or "uname failed"

    if platform["os"] == "macos":
        rc, out, err = ssh_run(nick, "system_profiler SPDisplaysDataType")
        caps["gpu"] = parse_profiler(out) if rc == 0 else {"present": False, "error": err or "system_profiler failed"}
        rc, out, err = ssh_run(nick, "sysctl -n hw.memsize")
        caps["ramGB"] = int(int(out) / (1024 ** 3)) if rc == 0 and out.isdigit() else None
    else:
        # WSL keeps nvidia-smi off the non-interactive PATH; try both, and
        # prefer the CSV query (the ASCII table truncates long GPU names).
        smi = "$(command -v nvidia-smi || echo /usr/lib/wsl/lib/nvidia-smi)"
        rc, out, err = ssh_run(
            nick, "%s --query-gpu=name,memory.total,driver_version --format=csv,noheader" % smi)
        if rc == 0 and out.strip():
            caps["gpu"] = parse_gpu_csv(out)
            # the CSV query has no CUDA field — take it from the table header
            rc2, out2, _ = ssh_run(nick, "%s" % smi)
            if rc2 == 0:
                cuda = parse_gpu(out2).get("cuda")
                if cuda:
                    caps["gpu"]["cuda"] = cuda
            if platform["os"] == "windows-wsl2":
                platform["quirks"]["nvidiaSmiPath"] = "/usr/lib/wsl/lib/nvidia-smi"
        else:
            caps["gpu"] = {"present": False, "error": (err or out or "nvidia-smi unavailable")[:500]}
        rc, out, err = ssh_run(nick, "free -g")
        caps["ramGB"] = parse_free(out)["ramGB"] if rc == 0 else None
        # WSL2 gives its VM ~half the host's RAM by default, so `free` here is
        # the JOB-VISIBLE limit, not the machine's total. Label the scope so a
        # 94GB reading on a 192GB box is not mistaken for a wrong claim.
        caps["ramScope"] = "wsl2-vm" if platform["os"] == "windows-wsl2" else "host"
    rc, out, err = ssh_run(nick, 'df -hPT ~ /mnt/* 2>/dev/null || df -hPT ~')
    caps["disks"] = parse_df(out)["disks"] if rc == 0 else []
    rc, out, err = ssh_run(nick, 'echo "$SHELL"')
    if rc == 0 and out:
        shell = os.path.basename(out)
        platform["quirks"]["defaultShell"] = shell
        # a non-bash login shell re-parses whatever ssh hands it, which is why
        # payloads ship as one quoted `bash -lc` word (see ssh_argv)
        platform["quirks"]["nonBashLoginShell"] = shell != "bash"
    # ICMP is blocked by default on Windows, so a failed ping says nothing
    # about reachability -- TCP:22 already answered. Record it rather than
    # letting a future reader mistake silence for "down" (design §7 rule 7).
    host = (res.get("ssh") or {}).get("host")
    if host:
        try:
            pinged = subprocess.run([_bin("COMPUTE_PING_BIN", "ping"), "-c", "1", host],
                                    capture_output=True, timeout=3).returncode
            # NOTE: no -W. Its unit differs by platform (macOS milliseconds,
            # Linux seconds), so a normal Wi-Fi RTT was being recorded as
            # icmpBlocked. The subprocess timeout is portable.
            platform["quirks"]["icmpBlocked"] = pinged != 0
        except (subprocess.TimeoutExpired, OSError):
            platform["quirks"]["icmpBlocked"] = True
    if platform["os"] == "macos":
        platform["quirks"]["acceleratorIsMpsNotCuda"] = True
    # envs: verify each configured env with a real import, record verbatim
    envs = res.get("envs") or {}
    for name, env in envs.items():
        activate = env.get("activate")
        if not activate:
            continue
        default_probe = ("import torch; print(torch.__version__, "
                         "torch.backends.mps.is_available())"
                         if platform["os"] == "macos" else
                         "import torch; print(torch.__version__, torch.cuda.is_available())")
        snippet = env.get("verify") or default_probe
        rc, out, err = ssh_run(nick, "%s && python -c %s" % (activate, shlex.quote(snippet)))
        if rc == 0 and out:
            # record the verification output VERBATIM — never a guess
            env["verified"] = {"output": out.strip()[:500], "checkedAt": now_iso()}
        else:
            env["verified"] = {"error": (err or out or "verification failed")[:500],
                               "checkedAt": now_iso()}
    res["capabilities"] = caps
    res["platform"] = platform
    res["envs"] = envs
    res.setdefault("state", {})
    res["state"]["lastProbe"] = now_iso()
    res["state"]["lastSeen"] = now_iso()
    return res


# --- register: converge to the declared end-state ---------------------------

def cmd_register(args):
    parser = argparse.ArgumentParser(prog="remote-compute register")
    parser.add_argument("nickname")
    parser.add_argument("target", nargs="?")
    parser.add_argument("--accept-hostkey", action="store_true")
    parsed = parser.parse_args(args)
    nick = args[0]
    if not JOB_ID_RE.fullmatch(nick):
        print("ERROR: nickname must be a safe single name")
        return EXIT_USAGE
    target = parsed.target
    accept_hostkey = parsed.accept_hostkey
    reg = load_registry()
    res = reg["resources"].get(nick) or {"name": nick, "transport": "ssh"}
    host = user = None
    if target:
        if "@" not in target:
            print("ERROR: target must be user@host (got '%s')" % target)
            sys.exit(EXIT_USAGE)
        user, host = target.split("@", 1)
    else:
        host = (res.get("ssh") or {}).get("host")
        user = (res.get("ssh") or {}).get("user")
        if not host:
            host, user = alias_target(nick)
    if not host or not user:
        print("ERROR: '%s' is unknown — pass a target: register %s user@host" % (nick, nick))
        sys.exit(EXIT_USAGE)

    if any(char.isspace() for char in host + user) or host.startswith("-") or user.startswith("-"):
        print("ERROR: invalid SSH target")
        return EXIT_USAGE
    endpoint = ssh_endpoint(nick, host, user)
    port = endpoint["port"]
    proxied = endpoint.get("proxyjump") or endpoint.get("proxycommand")
    if not proxied and not _port22_open(host, timeout=4, port=port):
        print("UNREACHABLE %s:%s — machine off, asleep, or sshd not listening." % (host, port))
        print("If this box is new, print its setup sheet: setup-sheet wsl2|linux|macos")
        sys.exit(EXIT_UNREACHABLE)

    # 2. host key: pinned known_hosts; fingerprint shown, human-acked keyscan
    kh = known_hosts_path()
    # EXACT host match per entry, never a substring of the file: "192.0.2.1"
    # occurs inside "192.0.2.17", and any short name can collide with a base64
    # key blob, which silently skipped the acknowledgement gate and left the
    # new host unpinned. known_hosts' first field may list comma-separated
    # hosts and may be bracketed with a port.
    host_known = bool(_known_host_keys(endpoint.get("hostkeyalias") or host, port))
    if not host_known:
        if proxied:
            print("NEEDS_HOSTKEY_ACK: pin the target's verified host key in %s as %s; then rerun register."
                  " Direct keyscan is not used through a jump host." % (kh, _host_token(endpoint.get("hostkeyalias") or host, port)))
            return EXIT_HOSTKEY
        scan = subprocess.run([_bin("COMPUTE_KEYSCAN_BIN", "ssh-keyscan"), "-T", "5", "-p", str(port), host],
                              capture_output=True, text=True).stdout.strip()
        if not scan:
            print("UNREACHABLE %s: ssh-keyscan got no banner (wrong sshd? firewall?)" % host)
            sys.exit(EXIT_UNREACHABLE)
        if not accept_hostkey:
            print("Host key for %s (verify on the machine itself, then re-run with --accept-hostkey):" % host)
            print("  %s" % scan.splitlines()[0])
            print("NEEDS_HOSTKEY_ACK: re-run: register %s %s@%s --accept-hostkey" % (nick, user, host))
            sys.exit(EXIT_HOSTKEY)
        os.makedirs(os.path.dirname(kh), mode=0o700, exist_ok=True)
        with open(kh, "a") as f:
            f.write(scan + "\n")
        res.setdefault("ssh", {})["hostKeyAccepted"] = "keyscan"

    # 3. alias: ~/.ssh/config Host block (idempotent)
    ensure_alias(nick, host, user)
    res.setdefault("ssh", {}).update({"configAlias": nick, "host": host, "user": user, "port": port})

    # 4. key auth under BatchMode — the skill never touches passwords
    rc, out, err = ssh_run(nick, "true", timeout=20)
    if rc != 0:
        res["ssh"]["batchModeVerified"] = False
        print("NEEDS_KEY_AUTH: key-based auth is not set up for %s@%s." % (user, host))
        print("Run this yourself, then re-run register:")
        print("  ssh-copy-id %s@%s" % (user, host))
        sys.exit(EXIT_KEYAUTH)
    res["ssh"]["batchModeVerified"] = True

    # 5. capability probe (read-only) + converge the remote job layout. The
    # mkdir lives HERE, in register, not in probe_resource: hard rule 3 says a
    # probe never writes, and probe/enable/add-env all call probe_resource.
    probe_resource(nick, res)
    ssh_run(nick, "mkdir -p %s %s" % (remote_path(REMOTE_JOBS_ROOT), remote_path(CAPS_REMOTE_ROOT)))
    tools_ok, tools_on_path = _install_tools(nick, res)
    # no allowSudo key: sudo rejection is unconditional (hard rule 2), and a
    # policy field implying it is togglable would be a lie
    res.setdefault("policy", {"maxConcurrentJobs": 1, "powerPolicyConfirmed": False})
    reg["resources"][nick] = res
    save_registry(reg, touched=nick)

    caps = res.get("capabilities", {})
    gpu = caps.get("gpu", {})
    print("REGISTERED %s (%s@%s)" % (nick, user, host))
    print("  os:     %s" % (res.get("platform") or {}).get("os"))
    print("  gpu:    %s  vramMB: %s  cuda: %s  driver: %s" % (
        gpu.get("name"), gpu.get("vramMB"), gpu.get("cuda"), gpu.get("driver")))
    print("  ramGB:  %s" % caps.get("ramGB"))
    for d in caps.get("disks", []):
        print("  disk:   %-12s freeGB: %-6s%s" % (d.get("mount"), d.get("freeGB"),
                                                  "  (slow: DrvFs/9p)" if d.get("slow") else ""))
    print("  shell:  %s" % (res.get("platform") or {}).get("quirks", {}).get("defaultShell"))
    print("  tools:  %s" % ("`remote-compute` command installed (ssh -t %s remote-compute top)" % nick
                            if tools_ok else "NOT installed — run: install-tools %s" % nick))
    if tools_ok and not tools_on_path:
        print(_path_note(res))
    if not res["policy"].get("powerPolicyConfirmed"):
        print("  NOTE: power policy unconfirmed — machine must not sleep on AC (see setup-sheet)")
    return 0


# --- enable: advertise a registered device to the CURRENT project -----------
# Non-exclusive, capability-style (mirrors assistant.capabilities.<name>):
# many projects may enable the same machine; the machine-local cooperative
# lock is what serializes actual use, never this declaration.

def _strip_top_block(text, key):
    """Remove a top-level YAML block (key + indented lines) via text surgery,
    leaving every other byte of the file untouched (same stance as
    sync-configs.py: never round-trip the whole file through a dumper)."""
    lines = text.splitlines(keepends=True)
    out, i, n = [], 0, len(lines)
    while i < n:
        if re.match(r"^%s:" % re.escape(key), lines[i]):
            i += 1
            while i < n and (lines[i].strip() == "" or lines[i][:1] in (" ", "\t")):
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return "".join(out)


def _project_cfg_path(root):
    """Availability lives in .neural-network/project.local.yaml — the gitignored,
    machine-local overlay config.py merges over project.yaml (compute key
    only). Missing local file is normal: created on first enable. The repo
    must still be a spec-workflow repo (project.yaml present)."""
    if not os.path.exists(os.path.join(root, ".neural-network", "project.yaml")):
        print("ERROR: %s/.neural-network/project.yaml not found — this verb runs inside a spec-workflow repo" % root)
        sys.exit(EXIT_USAGE)
    return os.path.join(root, ".neural-network", "project.local.yaml")


def _write_compute_section(cfg_path, mutate):
    """Read compute.resources (map keyed by alias), let `mutate` update it,
    rewrite only the compute: block (text surgery, rest of file untouched)."""
    text = ""
    if os.path.exists(cfg_path):
        with open(cfg_path) as f:
            text = f.read()
    if not text.strip():
        text = ("# Machine-local overlay (gitignored, see local-state.manifest).\n"
                "# config.py merges ONLY the allowlisted overlay keys (today: compute)\n"
                "# over project.yaml — written by remote-compute.py, safe to delete.\n")
    existing = (yaml.safe_load(text) or {}).get("compute") or {}
    resources = existing.get("resources") or {}
    resources = mutate(dict(resources))
    text = _strip_top_block(text, "compute")
    if not text.endswith("\n"):
        text += "\n"
    block = yaml.safe_dump({"compute": {"resources": resources}},
                           default_flow_style=False, sort_keys=False, indent=4)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cfg_path), prefix=".project.")
    with os.fdopen(fd, "w") as f:
        f.write(text + block)
    os.replace(tmp, cfg_path)


def cmd_enable(args):
    nick = args[0]
    opts = _parse_opts(args, {"--root": os.getcwd()}, repeat=("--role",))
    root, roles = opts["--root"], opts["--role"]
    cfg_path = _project_cfg_path(root)
    reg = load_registry()
    res = reg["resources"].get(nick)
    if res is None:
        print("ERROR: '%s' is not registered (run register first)" % nick)
        sys.exit(EXIT_USAGE)

    # never advertise from a stale snapshot — re-probe live
    probe_resource(nick, res)
    reg["resources"][nick] = res
    save_registry(reg, touched=nick)

    caps = res.get("capabilities", {})
    # NOTE: `activate` is deliberately NOT published. It is free-form shell a
    # human may have written with an inline token (export HF_TOKEN=... &&
    # source ...), and this snapshot lands in a repo file whose contract says
    # it carries no secrets. Consumers resolve envs by NAME against the
    # machine-local registry.
    envs = [{"name": k, "verified": v.get("verified")}
            for k, v in (res.get("envs") or {}).items()]
    entry = {
        "enabled": True,
        "roles": roles or ["general"],
        "probedAt": now_iso(),
        # informational snapshot only — no host, no user, no secrets
        "capabilities": {"gpu": {k: v for k, v in caps.get("gpu", {}).items() if k != "error"},
                         "ramGB": caps.get("ramGB"), "disks": caps.get("disks", [])},
    }
    if envs:
        entry["capabilities"]["envs"] = envs

    def mutate(resources):
        resources[nick] = entry
        return resources
    _write_compute_section(cfg_path, mutate)
    print("AVAILABLE %s -> %s (non-exclusive: other projects may enable it too)" % (nick, root))
    print("Tasks can now reference it, e.g. `resource: %s` / roles: %s" % (nick, entry["roles"]))
    print("Snapshot is informational; use probe explicitly when fresh hardware facts matter.")
    return 0


def cmd_disable(args):
    nick = args[0]
    root = _parse_opts(args, {"--root": os.getcwd()})["--root"]
    cfg_path = _project_cfg_path(root)

    def mutate(resources):
        if nick not in resources:
            print("ERROR: '%s' is not enabled in %s" % (nick, cfg_path))
            sys.exit(EXIT_USAGE)
        resources[nick]["enabled"] = False
        return resources
    _write_compute_section(cfg_path, mutate)
    print("DISABLED %s in %s (entry kept, enabled: false — like a disabled capability)" % (nick, root))
    return 0


# --- locks ------------------------------------------------------------------

def cmd_lock(nick, holder, reason):
    reg = load_registry()
    res = reg["resources"].get(nick)
    if res is None:
        print("ERROR: '%s' is not registered" % nick)
        sys.exit(EXIT_USAGE)
    lock = (res.get("state") or {}).get("lock")
    if lock and lock.get("holder") != holder:
        print("LOCKED: %s is held by %s (reason: %s, since %s)" % (
            nick, lock.get("holder"), lock.get("reason"), lock.get("since")))
        sys.exit(EXIT_LOCKED)
    rc, reply = remote_state(nick, "lock", {"owner": controller_id(), "holder": holder, "reason": reason})
    if rc:
        print("ERROR: %s" % reply.get("error"))
        return rc
    res.setdefault("state", {})["lock"] = {"holder": holder, "reason": reason, "since": now_iso()}
    save_registry(reg, touched=nick)
    print("locked %s (holder: %s)" % (nick, holder))
    return 0


def cmd_unlock(nick, holder, force):
    reg = load_registry()
    res = reg["resources"].get(nick)
    if res is None:
        print("ERROR: '%s' is not registered" % nick)
        sys.exit(EXIT_USAGE)
    lock = (res.get("state") or {}).get("lock")
    if lock and lock.get("holder") != holder and not force:
        print("LOCKED: held by %s (reason: %s, since %s) — use --force to override" % (
            lock.get("holder"), lock.get("reason"), lock.get("since")))
        sys.exit(EXIT_LOCKED)
    rc, reply = remote_state(nick, "unlock", {"owner": controller_id(), "holder": holder, "force": force})
    if rc:
        print("ERROR: %s" % reply.get("error"))
        return rc
    previous = reply.get("previous") or lock
    if force and previous:
        print("WARNING: force-unlocking %s; previous holder: %s" % (nick, previous.get("holder")))
    if lock and lock.get("holder") != holder:
        print("WARNING: force-unlocking %s — was held by %s (reason: %s, since %s)" % (
            nick, lock.get("holder"), lock.get("reason"), lock.get("since")))
    res.setdefault("state", {})["lock"] = None
    save_registry(reg, touched=nick)
    print("unlocked %s" % nick)
    return 0


# --- dispatch: detached remote job, state recoverable from files alone ------

def jobs_dir():
    return os.path.join(compute_home(), "jobs")


def _parse_opts(argv, spec, repeat=()):
    """Tiny flag parser: spec maps --flag -> default; flags in `repeat`
    accumulate into a list. Returns (opts, positionals-after-argv0)."""
    opts = dict(spec)
    for r in repeat:
        opts[r] = []
    i = 1
    while i < len(argv):
        if argv[i] in opts and i + 1 < len(argv):
            if argv[i] in repeat:
                opts[argv[i]].append(argv[i + 1])
            else:
                opts[argv[i]] = argv[i + 1]
            i += 2
        else:
            print("ERROR: unknown option or missing value: %s" % argv[i])
            sys.exit(EXIT_USAGE)
    return opts


def cmd_dispatch(argv):
    nick = argv[0]
    opts = _parse_opts(argv, {"--workdir": None, "--cmd": None, "--env": None,
                              "--inputs": None, "--job-id": None,
                              "--holder": getpass.getuser()})
    workdir, cmd = opts["--workdir"], opts["--cmd"]
    if not workdir or not cmd:
        print("ERROR: dispatch needs --workdir and --cmd")
        sys.exit(EXIT_USAGE)
    reject_sudo(cmd)
    reg = load_registry()
    res = reg["resources"].get(nick)
    if res is None:
        print("ERROR: '%s' is not registered" % nick)
        sys.exit(EXIT_USAGE)
    return _launch_job(reg, res, nick, workdir, cmd, opts)


def _running_jobs(nick):
    """Jobs recorded locally for this resource with no exitcode yet."""
    running = []
    try:
        names = os.listdir(jobs_dir())
    except FileNotFoundError:
        return running
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(jobs_dir(), name)) as f:
                job = json.load(f)
        except (OSError, ValueError):
            continue
        if job.get("resource") != nick or job.get("finishedAt"):
            continue
        remote_dir = job.get("remoteDir")
        if not remote_dir:
            continue
        if job.get("protocol"):
            rc, reply = remote_state(nick, "status", {"id": job["id"]})
            if rc or reply.get("state") not in ("done", "failed", "cancelled", "lost"):
                running.append(job["id"])
            else:
                _finish_local_job(job["id"], job)
            continue
        q_rd = remote_path(remote_dir)
        rc, out, _ = ssh_run(nick, "if [ -d %s ]; then cat %s/exitcode 2>/dev/null "
                             "|| echo __RUNNING__; else echo __GONE__; fi" % (q_rd, q_rd))
        state = out.strip()
        if rc != 0:
            # FAIL CLOSED: an unreachable/slow resource is exactly when the
            # limit matters most. Treating "unknown" as idle would let a second
            # job land on a saturated GPU.
            running.append("%s (status unknown)" % (job.get("id") or name[:-5]))
        elif state == "__RUNNING__":
            running.append(job.get("id") or name[:-5])
        else:
            # finished (exitcode present) or its remote dir is gone (reboot,
            # tmp cleanup): record it so we never re-probe this job again
            _mark_job_finished(os.path.join(jobs_dir(), name))
    return running


def _mark_job_finished(path):
    try:
        with open(path) as f:
            job = json.load(f)
        job["finishedAt"] = now_iso()
        _atomic_json(path, job)
    except (OSError, ValueError):
        pass


def _atomic_json(path, data):
    """Write job state atomically: a crash mid-write must not leave a truncated
    file that later raises an uncaught ValueError from load_job."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".job.")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


# A job id becomes BOTH a remote path segment and a local filename, so it is
# restricted to characters that are inert in a shell and cannot traverse.
JOB_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


def _launch_job(reg, res, nick, workdir, cmd, opts):
    holder = opts["--holder"]
    env = (res.get("envs") or {}).get(opts["--env"]) if opts["--env"] else None
    if opts["--env"] and (not env or not env.get("activate")):
        print("ERROR: env '%s' is not configured on %s" % (opts["--env"], nick))
        return EXIT_USAGE
    if env:
        reject_sudo(env["activate"])
    job_id = opts["--job-id"] or new_job_id()
    if not JOB_ID_RE.fullmatch(job_id):
        print("ERROR: --job-id must match [A-Za-z0-9][A-Za-z0-9._-]{0,63} (got %r)" % job_id)
        return EXIT_USAGE
    if os.path.exists(os.path.join(jobs_dir(), "%s.json" % job_id)):
        print("ERROR: job ID already exists locally: %s (use a new ID for a retry)" % job_id)
        return EXIT_USAGE
    # maxConcurrentJobs is ENFORCED, not advisory: two agents sharing one GPU
    # must not both start work just because neither took the lock first.
    limit = (res.get("policy") or {}).get("maxConcurrentJobs")
    if isinstance(limit, int) and limit > 0:
        running = _running_jobs(nick)
        if len(running) >= limit:
            print("BUSY: %s is at its maxConcurrentJobs limit (%d) — running: %s"
                  % (nick, limit, ", ".join(running)))
            print("Wait for it, raise policy.maxConcurrentJobs in the registry, "
                  "or use a different resource.")
            sys.exit(EXIT_LOCKED)
        reg = load_registry()
        res = reg["resources"][nick]
    lock = (res.get("state") or {}).get("lock")
    if lock and lock.get("holder") != holder:
        print("LOCKED: %s is held by %s (reason: %s, since %s) — refusing dispatch" % (
            nick, lock.get("holder"), lock.get("reason"), lock.get("since")))
        sys.exit(EXIT_LOCKED)
    # --job-id is interpolated into the remote payload AND used as a local
    # filename: an unvalidated value is remote command injection plus path
    # traversal, and it lands after the sudo check on --cmd.
    if not JOB_ID_RE.fullmatch(job_id):
        print("ERROR: --job-id must match [A-Za-z0-9][A-Za-z0-9._-]{0,63} (got %r)" % job_id)
        sys.exit(EXIT_USAGE)
    # workdir reaches the remote shell too, via `cd <workdir>`; it faces the
    # same sudo guard as --cmd and is quoted at the interpolation site below.
    reject_sudo(workdir)
    remote_dir = "%s/%s" % (REMOTE_JOBS_ROOT, job_id)
    # {jobdir} is engine-supplied and can only be resolved HERE, once the job
    # id exists. Without this the placeholder reached the remote shell
    # literally, breaking every bundle job that used it. $COMPUTE_JOB_DIR is
    # the equivalent for payloads that prefer reading the environment.
    if not opts.get("--rendered"):
        cmd = render_command(cmd, {}, {"jobdir": remote_dir})

    token = uuid.uuid4().hex
    request = {"id": job_id, "token": token, "owner": controller_id(), "holder": holder,
               "limit": limit or 1, "capability": opts.get("--capability"), "digest": opts.get("--digest")}
    rc, reply = remote_state(nick, "reserve", request)
    if rc:
        print("ERROR: %s" % reply.get("error", "reservation failed"))
        return rc
    state = {"id": job_id, "resource": nick, "workdir": workdir, "cmd": cmd,
             "env": opts["--env"], "holder": holder, "remoteDir": remote_dir,
             "submittedAt": now_iso(), "token": token, "phase": "reserved", "protocol": 1}
    # A receipt exists before either transfer or launch, including a response
    # lost after the remote process actually starts.
    local_path = os.path.join(jobs_dir(), "%s.json" % job_id)
    try:
        os.makedirs(jobs_dir(), exist_ok=True, mode=0o700)
        with open(local_path, "x") as receipt:
            json.dump(state, receipt, indent=2)
    except FileExistsError:
        remote_state(nick, "abort", request)
        print("ERROR: job ID was concurrently reserved locally: %s" % job_id)
        return EXIT_USAGE

    # cooperative lock for the duration of the job. Never overwrite a human's
    # manual `lock --reason`: same holder keeps their reason, so job-status
    # cannot silently clear a lock a person took deliberately.
    existing = (res.get("state") or {}).get("lock")
    manual_lock = bool(existing) and not str(existing.get("reason", "")).startswith("job ")
    if not manual_lock:
        # take (or RE-POINT) the job lock: a second dispatch by the same holder
        # must move the lock to the newer job, otherwise job-status on the
        # first job releases a lock while the second is still running
        res.setdefault("state", {})["lock"] = {"holder": holder, "reason": "job %s" % job_id,
                                               "since": now_iso()}
    save_registry(reg, touched=nick)

    if opts["--inputs"]:
        try:
            transferred = subprocess.run(rsync_argv(opts["--inputs"].rstrip("/") + "/",
                "%s:%s/inputs/" % (nick, remote_dir.replace("~/", "", 1))), check=False).returncode
        except OSError as exc:
            transferred = 1
            print("ERROR: input transfer failed: %s" % exc)
        if transferred:
            remote_state(nick, "abort", request)
            state.update(phase="failed-staging", finishedAt=now_iso())
            _atomic_json(local_path, state)
            if not manual_lock:
                res["state"]["lock"] = None
                save_registry(reg, touched=nick)
            print("ERROR: input transfer failed (exit %s); job was not launched" % transferred)
            return 1
    request.update(cmd=cmd, workdir=workdir, activate=env.get("activate") if env else None,
                   inputs=bool(opts["--inputs"]))
    rc, reply = remote_state(nick, "launch", request)
    if rc:
        # A transport failure is ambiguous, not evidence that no process ran.
        state["phase"] = "unknown" if rc not in (2, 5, 6, 7) or reply.get("ambiguous") else "failed-launch"
        if state["phase"] != "unknown":
            remote_state(nick, "abort", request)
            state["finishedAt"] = now_iso()
            if not manual_lock:
                res["state"]["lock"] = None
                save_registry(reg, touched=nick)
        _atomic_json(local_path, state)
        print("ERROR: launch %s on %s: %s; inspect job-status %s" % (state["phase"], nick, reply.get("error"), job_id))
        return rc
    state["phase"] = "running"
    _atomic_json(local_path, state)
    print("DISPATCHED %s on %s (workdir %s)" % (job_id, nick, workdir))
    print("follow: job-status %s | job-logs %s | job-pull %s" % (job_id, job_id, job_id))
    return 0


# --- declared jobs: dispatch by intent, capability-style --------------------
# A resource declares NAMED jobs (cmd template + per-param regex — the same
# stance as capability.yaml's invoke: schema-validated substitution into a
# pre-authored template, never a free-form command from the model). ComfyUI
# rule (compute-registry-plan-v3 §3.6 / SPEC-ASSISTANT §14.2) carries over:
# a comfy job's template must reference a committed workflow file, never a
# dynamically-composed graph.

DEFAULT_PARAM_PATTERN = r"[A-Za-z0-9._/-]+"


def cmd_add_env(argv):
    nick, env_name = argv[0], argv[1]
    opts = _parse_opts(argv[1:], {"--activate": None, "--verify": None, "--kind": "python-venv"})
    if not opts["--activate"]:
        print("ERROR: add-env needs --activate (e.g. 'source ~/.venv/bin/activate')")
        sys.exit(EXIT_USAGE)
    reject_sudo(opts["--activate"])
    if opts["--verify"]:
        reject_sudo(opts["--verify"])
    reg = load_registry()
    res = reg["resources"].get(nick)
    if res is None:
        print("ERROR: '%s' is not registered" % nick)
        sys.exit(EXIT_USAGE)
    res.setdefault("envs", {})[env_name] = {
        "kind": opts["--kind"], "activate": opts["--activate"],
        "verify": opts["--verify"], "verified": None,
    }
    save_registry(reg, touched=nick)
    # verify immediately — a declared env that has never been exercised is a
    # claim, and claims must come from real output (hard rule 4)
    probe_resource(nick, res)
    reg["resources"][nick] = res
    save_registry(reg, touched=nick)
    v = (res["envs"][env_name] or {}).get("verified") or {}
    print("declared env '%s' on %s" % (env_name, nick))
    print("  activate: %s" % opts["--activate"])
    print("  verified: %s" % (v.get("output") or v.get("error") or "not verified"))
    return 0


def cmd_envs(nick):
    res = get_resource(nick)
    envs = res.get("envs") or {}
    if not envs:
        print("no envs declared on %s (use: add-env %s NAME --activate 'source ~/.venv/bin/activate')"
              % (nick, nick))
        return 0
    for name, env in envs.items():
        v = env.get("verified") or {}
        print("%-14s %s" % (name, env.get("activate")))
        print("               verified: %s" % (v.get("output") or v.get("error") or "never"))
    return 0


# --- capability bundles -----------------------------------------------------
# A bundle is DATA, not engine code: a directory with capability.yaml
# {name, description, payload[], jobs{name: {description, cmd, params, env}}}
# plus the payload files its jobs invoke. install-capability rsyncs the payload
# to ~/.remote-compute/caps/<name>/ and declares the manifest's jobs through the
# same add-job machinery a human would use. The engine stays domain-agnostic —
# supporting a new domain means adding a bundle, never editing this file.
# Templates may use {capdir} (the installed payload dir) and {jobdir} (the
# per-job directory, resolved at dispatch); everything else is a job param.

CAPS_REMOTE_ROOT = "~/.remote-compute/caps"


def validate_manifest(manifest):
    if not isinstance(manifest, dict) or not isinstance(manifest.get("name"), str) or not JOB_ID_RE.fullmatch(manifest["name"]):
        raise ValueError("capability name must be a safe single path component")
    jobs = manifest.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        raise ValueError("manifest must declare at least one job")
    payload = manifest.get("payload", [])
    if not isinstance(payload, list):
        raise ValueError("payload must be a list of relative paths")
    for rel in payload:
        if not isinstance(rel, str) or not rel or Path(rel).is_absolute() or ".." in Path(rel).parts or "\\" in rel:
            raise ValueError("unsafe payload path: %r" % rel)
    for key, job in jobs.items():
        if not isinstance(key, str) or not JOB_ID_RE.fullmatch(key) or not isinstance(job, dict):
            raise ValueError("invalid job declaration: %r" % key)
        if not isinstance(job.get("cmd"), str) or not job["cmd"].strip():
            raise ValueError("job %s needs a command" % key)
        reject_sudo(job["cmd"])
        for field in ("workdir", "env"):
            if job.get(field) is not None and not isinstance(job[field], str):
                raise ValueError("job %s: %s must be text" % (key, field))
        params = job.get("params") or {}
        if not isinstance(params, dict):
            raise ValueError("job %s: params must be a map" % key)
        for param, declaration in params.items():
            if not isinstance(param, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", param) or param in ("capdir", "jobdir"):
                raise ValueError("invalid or reserved parameter: %r" % param)
            declaration = declaration if isinstance(declaration, dict) else {"pattern": declaration}
            try:
                regex = re.compile(declaration.get("pattern") or DEFAULT_PARAM_PATTERN)
            except (TypeError, re.error) as exc:
                raise ValueError("invalid pattern for %s: %s" % (param, exc))
            if "default" in declaration and not regex.fullmatch(str(declaration["default"])):
                raise ValueError("default for %s does not match its pattern" % param)
    return manifest


def bundle_files(bundle, manifest):
    root = Path(bundle).resolve()
    files = {"capability.yaml": root / "capability.yaml"}
    for rel in manifest.get("payload", []):
        path = root / rel
        if not path.exists():
            raise ValueError("missing payload file: %s" % rel)
        candidates = [path] + (list(path.rglob("*")) if path.is_dir() else [])
        for candidate in candidates:
            if os.path.commonpath([str(root), str(candidate.resolve())]) != str(root) or candidate.is_symlink():
                raise ValueError("payload escapes bundle or is a symlink: %s" % candidate)
            if candidate.is_file():
                files[candidate.relative_to(root).as_posix()] = candidate
    if files["capability.yaml"].is_symlink():
        raise ValueError("manifest must not be a symlink")
    return files


def validate_bundle(bundle):
    try:
        manifest = _read_capability_manifest(bundle)
        validate_manifest(manifest)
        bundle_files(bundle, manifest)
        return manifest
    except (OSError, yaml.YAMLError) as exc:
        raise ValueError(str(exc))


def _record_capability(res, manifest, digest=None, default_env=None):
    cap = manifest["name"]
    capdir = "%s/%s" % (CAPS_REMOTE_ROOT, cap)
    roster = res.setdefault("jobs", {})
    for key in list(roster):
        if roster[key].get("capability") == cap:
            del roster[key]
    declared = []
    for job_name, job in manifest["jobs"].items():
        key = "%s:%s" % (cap, job_name)
        roster[key] = {
            "description": job.get("description") or "", "workdir": job.get("workdir") or capdir,
            "cmd": job["cmd"], "capdir": capdir, "env": job.get("env") or default_env or manifest.get("defaultEnv"),
            "params": {k: (dict(v) if isinstance(v, dict) else {"pattern": v}) for k, v in (job.get("params") or {}).items()},
            "capability": cap, "digest": digest, "jobIdSchema": manifest.get("jobIdSchema") or job.get("jobIdSchema")}
        declared.append(key)
    res.setdefault("capabilities_installed", {})[cap] = {
        "version": manifest.get("version"), "installedAt": now_iso(), "digest": digest,
        "description": manifest.get("description") or "", "jobs": declared}
    return declared


def cmd_install_capability(argv, provenance=None):
    nick, bundle = argv[0], argv[1]
    opts = _parse_opts(argv[1:], {"--env": None})
    try:
        manifest = validate_bundle(bundle)
        files = bundle_files(bundle, manifest)
    except ValueError as exc:
        print("ERROR: %s" % exc)
        return EXIT_USAGE
    cap = manifest["name"]

    reg = load_registry()
    res = reg["resources"].get(nick)
    if res is None:
        print("ERROR: '%s' is not registered" % nick)
        sys.exit(EXIT_USAGE)

    hashes = {rel: hashlib.sha256(path.read_bytes()).hexdigest() for rel, path in files.items()}
    if opts["--env"]:
        manifest["defaultEnv"] = opts["--env"]
    digest = hashlib.sha256(json.dumps({"manifest": manifest, "files": hashes}, sort_keys=True).encode()).hexdigest()
    stage = uuid.uuid4().hex
    staging = "~/.remote-compute/.staging/%s" % stage
    rc, out, err = ssh_run(nick, "mkdir -p %s" % remote_path(staging))
    if rc:
        print("ERROR: cannot stage capability: %s" % (err or out))
        return 1
    sources = [os.path.join(os.path.abspath(bundle), ".", rel) for rel in files]
    rc = subprocess.run(rsync_argv("--relative", *sources,
                        "%s:%s/" % (nick, staging.replace("~/", "", 1))), check=False).returncode
    if rc:
        print("ERROR: rsync of capability failed (exit %s); previous installation unchanged" % rc)
        return 1
    rc, reply = remote_state(nick, "cap-commit", {
        "name": cap, "stage": stage, "manifest": manifest, "files": hashes, "digest": digest, "source": provenance})
    if rc:
        print("ERROR: %s" % reply.get("error"))
        return rc
    declared = _record_capability(res, manifest, digest, opts["--env"])
    if provenance:
        res["capabilities_installed"][cap]["source"] = provenance
    save_registry(reg, touched=nick)
    capdir = "%s/%s" % (CAPS_REMOTE_ROOT, cap)
    print("installed capability '%s' on %s (payload -> %s)" % (cap, nick, capdir))
    for key in declared:
        print("  job: %s" % key)
    return 0


def cmd_remove_capability(argv):
    """Uninstall a capability: drop it from the roster and remove the jobs it
    declared. The remote payload is LEFT IN PLACE by default -- deleting files
    on someone's machine is not implied by 'stop offering this here' --
    --purge-remote opts into removing that one capability's directory."""
    nick, cap = argv[0], argv[1]
    if any(option not in ("--purge-remote", "--retire-remote") for option in argv[2:]):
        print("ERROR: unknown remove-capability option")
        return EXIT_USAGE
    if not JOB_ID_RE.fullmatch(cap):
        print("ERROR: capability name must be a safe path component")
        return EXIT_USAGE
    purge = "--purge-remote" in argv
    retire = "--retire-remote" in argv
    reg = load_registry()
    res = reg["resources"].get(nick)
    if res is None:
        print("ERROR: '%s' is not registered" % nick)
        sys.exit(EXIT_USAGE)
    installed = res.get("capabilities_installed") or {}
    if cap not in installed:
        print("ERROR: '%s' has no capability '%s' — installed: %s"
              % (nick, cap, ", ".join(installed) or "none"))
        sys.exit(EXIT_USAGE)

    if purge or retire:
        rc, reply = remote_state(nick, "cap-remove", {"name": cap, "purge": purge})
        if rc:
            print("ERROR: %s" % reply.get("error"))
            return rc
    jobs = res.get("jobs") or {}
    dropped = [name for name, job in jobs.items() if job.get("capability") == cap]
    for name in dropped:
        del jobs[name]
    del installed[cap]
    save_registry(reg, touched=nick)

    print("removed capability '%s' from %s" % (cap, nick))
    for name in dropped:
        print("  dropped job: %s" % name)
    capdir = "%s/%s" % (CAPS_REMOTE_ROOT, cap)
    if purge:
        print("  purged remote payload at %s" % capdir)
    else:
        print("  payload left on the machine at %s "
              "(add --purge-remote to delete it)" % capdir)
    return 0


def capability_bundle_root():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "remote-capabilities")


def _read_capability_manifest(path):
    manifest_path = os.path.join(path, "capability.yaml")
    try:
        with open(manifest_path, encoding="utf-8") as f:
            manifest = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError) as exc:
        raise ValueError("cannot read %s: %s" % (manifest_path, exc))
    if not isinstance(manifest, dict) or not manifest.get("name") or not manifest.get("jobs"):
        raise ValueError("%s must declare a name and at least one job" % manifest_path)
    return manifest


def cmd_capability_list(bundle_root=None):
    bundle_root = bundle_root or capability_bundle_root()
    if not os.path.isdir(bundle_root):
        print("ERROR: capability bundle directory does not exist: %s" % bundle_root)
        return EXIT_USAGE
    bundles = []
    for name in sorted(os.listdir(bundle_root)):
        path = os.path.join(bundle_root, name)
        if not os.path.isdir(path):
            continue
        manifest_path = os.path.join(path, "capability.yaml")
        if not os.path.isfile(manifest_path):
            continue
        try:
            manifest = _read_capability_manifest(path)
        except ValueError as exc:
            print("ERROR: %s" % exc)
            return EXIT_USAGE
        bundles.append((manifest, path))
    if not bundles:
        print("no capability bundles found in %s" % bundle_root)
        return 0
    print("Available capability bundles:")
    for manifest, _ in bundles:
        print("  %s: %s" % (manifest["name"],
                            (manifest.get("description") or "").strip()))
        print("    jobs: %s" % ", ".join((manifest.get("jobs") or {}).keys()))
    return 0


def _resolve_capability_bundle(selector):
    expanded = os.path.abspath(os.path.expanduser(selector))
    if os.path.isdir(expanded):
        return expanded
    if os.path.isabs(selector) or os.path.sep in selector or (os.path.altsep and os.path.altsep in selector):
        raise ValueError("bundle directory does not exist: %s" % selector)
    candidate = os.path.join(capability_bundle_root(), selector)
    if not os.path.isdir(candidate):
        raise ValueError("unknown bundled capability '%s' (run: capabilities list)" % selector)
    manifest = _read_capability_manifest(candidate)
    if manifest["name"] != selector:
        raise ValueError("bundle directory '%s' declares a different name: %s"
                         % (selector, manifest["name"]))
    return candidate


def cmd_capabilities(nick):
    res = get_resource(nick)
    caps = res.get("capabilities_installed") or {}
    if not caps:
        print("no capabilities installed on %s "
              "(use: capabilities install %s <bundle-name-or-dir>)" % (nick, nick))
        return 0
    for name, cap in caps.items():
        print("%-12s v%-3s %s" % (name, cap.get("version"), (cap.get("description") or "").strip()))
        print("             jobs: %s" % ", ".join(cap.get("jobs") or []))
    return 0


def cmd_installed_capabilities(nick=None):
    resources = load_registry().get("resources") or {}
    if nick is not None:
        if nick not in resources:
            print("ERROR: '%s' is not a registered compute resource (run register first)" % nick)
            return EXIT_USAGE
        return cmd_capabilities(nick)

    found = False
    for machine in sorted(resources):
        caps = resources[machine].get("capabilities_installed") or {}
        if not caps:
            continue
        found = True
        print("%s:" % machine)
        for name, cap in caps.items():
            print("  %-12s v%-3s %s" % (
                name, cap.get("version"), (cap.get("description") or "").strip()))
            print("               jobs: %s" % ", ".join(cap.get("jobs") or []))
    if not found:
        print("no capabilities installed on any machine")
    return 0


def github_source(value):
    """Accept repository URLs, never Git transport helpers or credential URLs."""
    match = re.fullmatch(r"(https://github\.com/|git@github\.com:)([A-Za-z0-9_-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?", value)
    if not match or match[3] in (".", ".."):
        raise ValueError("use a GitHub repository URL (https://github.com/OWNER/REPO or git@github.com:OWNER/REPO.git); select a branch with --ref")
    return "%s%s/%s.git" % (match[1], match[2], match[3])


def discover_bundles(root, name=None, all_bundles=False):
    root = Path(root)
    found = {}
    for directory, children, files in os.walk(root, followlinks=False):
        children[:] = sorted(child for child in children if child != ".git" and not Path(directory, child).is_symlink())
        if "capability.yaml" not in files:
            continue
        manifest = validate_bundle(directory)
        cap = manifest["name"]
        if cap in found:
            raise ValueError("repository contains duplicate capability name: %s" % cap)
        found[cap] = Path(directory)
    if not found:
        raise ValueError("repository contains no capability.yaml bundles")
    if name:
        if name not in found:
            raise ValueError("unknown capability %s; available: %s" % (name, ", ".join(sorted(found))))
        return [found[name]]
    if not all_bundles and len(found) != 1:
        raise ValueError("choose a capability name or --all; available: %s" % ", ".join(sorted(found)))
    return [found[key] for key in sorted(found)]


def cmd_github_install(args):
    parser = argparse.ArgumentParser(prog="remote-compute capabilities install")
    parser.add_argument("nickname")
    parser.add_argument("url")
    parser.add_argument("name", nargs="?")
    parser.add_argument("--all", action="store_true", dest="all_bundles")
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--env")
    options = parser.parse_args(args)
    if options.name and options.all_bundles:
        parser.error("choose a capability name OR --all")
    try:
        url = github_source(options.url)
        if not options.ref or options.ref.startswith("-") or any(ch.isspace() for ch in options.ref):
            raise ValueError("--ref must be a branch, tag, or commit without whitespace")
        get_resource(options.nickname)
        with tempfile.TemporaryDirectory(prefix="remote-compute-github-") as temp:
            checkout = Path(temp, "repo")
            environment = dict(os.environ, GIT_TERMINAL_PROMPT="0")
            # Do not initialize submodules or run repository hooks. SSH remains
            # key-only and refuses unknown hosts; credentials stay in Git's helpers.
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes"
            base = ["git", "-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=never"]
            def git(*arguments):
                result = subprocess.run(base + list(arguments), env=environment, capture_output=True, text=True, timeout=180)
                if result.returncode:
                    raise ValueError("GitHub checkout failed: %s" % result.stderr.strip())
                return result.stdout.strip()
            git("clone", "--no-checkout", "--depth", "1", "--", url, str(checkout))
            git("-C", str(checkout), "fetch", "--depth", "1", "origin", options.ref)
            commit = git("-C", str(checkout), "rev-parse", "--verify", "FETCH_HEAD^{commit}")
            git("-C", str(checkout), "checkout", "--detach", commit)
            bundles = discover_bundles(checkout, options.name, options.all_bundles)
            provenance = {"url": url, "ref": options.ref, "commit": commit}
            print("SOURCE %s @ %s" % (url, commit))
            # Discovery validates every manifest/payload before the first mutation.
            # Each bundle is atomic; an --all operation can be partially complete.
            for bundle in bundles:
                arguments = [options.nickname, str(bundle)]
                if options.env:
                    arguments += ["--env", options.env]
                rc = cmd_install_capability(arguments, provenance=provenance)
                if rc:
                    print("STOPPED at %s; earlier successful bundles remain installed" % bundle.name)
                    return rc
            return 0
    except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
        print("ERROR: %s" % exc)
        return EXIT_USAGE


def cmd_capability_cli(args):
    if not args:
        print("ERROR: capabilities requires list, installed, install, sync, or validate")
        return EXIT_USAGE
    action = args[0]
    if action in ("help", "-h", "--help"):
        print("capabilities list | installed [nick] | sync nick | validate bundle-dir\n"
              "capabilities install nick name-or-dir [--env NAME]\n"
              "capabilities install nick github-url [name | --all] [--ref REF] [--env NAME]\n"
              "Install only trusted bundles; payloads execute with the SSH account's permissions.")
        return 0
    if action == "list":
        if len(args) == 1:
            return cmd_capability_list()
        print("ERROR: usage: capabilities list")
        return EXIT_USAGE
    if action == "installed":
        if len(args) == 1:
            return cmd_installed_capabilities()
        if len(args) == 2:
            return cmd_installed_capabilities(args[1])
        print("ERROR: usage: capabilities installed [<nick>]")
        return EXIT_USAGE
    if action == "install":
        if len(args) < 3:
            print("ERROR: usage: capabilities install <nick> <name-or-bundle-dir> [--env NAME]")
            return EXIT_USAGE
        if args[2].startswith(("https://", "http://", "git@", "ssh://")):
            return cmd_github_install(args[1:])
        try:
            bundle_dir = _resolve_capability_bundle(args[2])
        except ValueError as exc:
            print("ERROR: %s" % exc)
            return EXIT_USAGE
        return cmd_install_capability([args[1], bundle_dir] + args[3:])
    if action == "sync" and len(args) == 2:
        return cmd_capability_sync(args[1])
    if action == "validate" and len(args) == 2:
        try:
            manifest = validate_bundle(_resolve_capability_bundle(args[1]))
        except ValueError as exc:
            print("ERROR: %s" % exc)
            return EXIT_USAGE
        print("VALID %s" % manifest["name"])
        return 0
    if len(args) == 1:
        return cmd_capabilities(action)
    print("ERROR: unknown capabilities action '%s'" % action)
    return EXIT_USAGE


def cmd_capability_sync(nick):
    reg = load_registry()
    res = get_resource(nick)
    rc, reply = remote_state(nick, "catalog", {})
    if rc:
        print("ERROR: %s" % reply.get("error"))
        return rc
    installed = reply.get("capabilities", {})
    # Validate the entire response before changing any client declarations.
    try:
        for cap, metadata in installed.items():
            if not metadata.get("legacy"):
                validate_manifest(metadata["manifest"])
                if metadata["manifest"]["name"] != cap:
                    raise ValueError("catalog name does not match its manifest")
    except (ValueError, KeyError, TypeError) as exc:
        print("ERROR: invalid target catalog: %s" % exc)
        return EXIT_USAGE
    for cap in list(res.get("capabilities_installed", {})):
        if cap not in installed:
            del res["capabilities_installed"][cap]
            res["jobs"] = {key: job for key, job in res.get("jobs", {}).items() if job.get("capability") != cap}
    for cap, metadata in installed.items():
        if metadata.get("legacy"):
            print("LEGACY %s: reinstall once to publish its manifest; existing local jobs preserved" % cap)
            continue
        _record_capability(res, metadata["manifest"], metadata.get("digest"))
        if metadata.get("source"):
            res["capabilities_installed"][cap]["source"] = metadata["source"]
    reg["resources"][nick] = res
    save_registry(reg, touched=nick)
    print("SYNCED capability declarations from %s" % nick)
    return cmd_capabilities(nick)


def cmd_add_job(argv):
    nick, job_name = argv[0], argv[1]
    opts = _parse_opts(argv[1:], {"--workdir": None, "--cmd": None, "--env": None,
                                  "--description": ""},
                       repeat=("--param", "--param-default"))
    if not opts["--workdir"] or not opts["--cmd"]:
        print("ERROR: add-job needs --workdir and --cmd")
        sys.exit(EXIT_USAGE)
    reject_sudo(opts["--cmd"])
    params = {}
    for p in opts["--param"]:
        name, _, pattern = p.partition(":")
        params[name] = {"pattern": pattern or DEFAULT_PARAM_PATTERN}
    try:
        validate_manifest({"name": "custom", "jobs": {"recipe": {"cmd": opts["--cmd"], "params": params}}})
    except ValueError as exc:
        print("ERROR: %s" % exc)
        return EXIT_USAGE
    # --param-default NAME=VALUE declares an OPTIONAL param: callers may omit
    # it and get VALUE. The default must satisfy the pattern, otherwise the
    # job is a trap that only fails once someone omits the value.
    for d in opts["--param-default"]:
        name, _, value = d.partition("=")
        spec = params.setdefault(name, {"pattern": DEFAULT_PARAM_PATTERN})
        if not re.fullmatch(spec.get("pattern") or DEFAULT_PARAM_PATTERN, value):
            print("ERROR: default %r for param '%s' does not match its pattern %r"
                  % (value, name, spec.get("pattern")))
            sys.exit(EXIT_USAGE)
        spec["default"] = value
    try:
        validate_manifest({"name": "custom", "jobs": {"recipe": {"cmd": opts["--cmd"], "params": params}}})
    except ValueError as exc:
        print("ERROR: %s" % exc)
        return EXIT_USAGE
    reg = load_registry()
    res = reg["resources"].get(nick)
    if res is None:
        print("ERROR: '%s' is not registered" % nick)
        sys.exit(EXIT_USAGE)
    res.setdefault("jobs", {})[job_name] = {
        "description": opts["--description"], "workdir": opts["--workdir"],
        "cmd": opts["--cmd"], "env": opts["--env"], "params": params,
    }
    save_registry(reg, touched=nick)
    print("declared job '%s' on %s (params: %s)" % (job_name, nick, ", ".join(params) or "none"))
    return 0


def cmd_remove_job(nick, job_name):
    """Retire a declared job. Local-only: the remote machine keeps its payload
    and any job directories -- this just stops offering the job by name."""
    reg = load_registry()
    res = reg["resources"].get(nick)
    if res is None:
        print("ERROR: '%s' is not registered" % nick)
        sys.exit(EXIT_USAGE)
    jobs = res.get("jobs") or {}
    if job_name not in jobs:
        print("ERROR: '%s' has no job '%s' — declared jobs: %s"
              % (nick, job_name, ", ".join(jobs) or "none"))
        sys.exit(EXIT_USAGE)
    cap = jobs[job_name].get("capability")
    del jobs[job_name]
    save_registry(reg, touched=nick)
    print("removed job '%s' from %s (the machine is untouched)" % (job_name, nick))
    if cap:
        print("NOTE: it came from capability '%s' — re-installing that bundle "
              "will declare it again." % cap)
    return 0


def cmd_jobs(nick):
    res = get_resource(nick)
    jobs = res.get("jobs") or {}
    if not jobs:
        print("no jobs declared on %s (use: add-job %s NAME --workdir W --cmd TEMPLATE)" % (nick, nick))
        return 0
    for name, job in jobs.items():
        print("%-16s %s" % (name, job.get("description") or "(no description)"))
        rendered = []
        for pname, pspec in (job.get("params") or {}).items():
            if isinstance(pspec, dict) and "default" in pspec:
                rendered.append("%s (optional, default %s)" % (pname, pspec["default"]))
            else:
                rendered.append(pname)
        print("                 params: %s  workdir: %s" % (
            ", ".join(rendered) or "none", job.get("workdir")))
    return 0


def slug(value, limit=24):
    """A shell-inert, filename-safe fragment of a param value: lowercased,
    extension dropped, runs of non-alphanumerics collapsed to a single dash.
    Used only for building job ids, never for anything the remote executes."""
    text = str(value).rsplit(".", 1)[0] if "." in str(value) else str(value)
    text = re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-").lower()
    return text[:limit].strip("-")


def render_job_id(schema, given):
    """Build a job id from a capability's declared template, e.g.
    'img-{model}-{seed}'. Every substituted value is slugified, so a hostile
    param can never shape the id; the result still faces JOB_ID_RE."""
    template = (schema or {}).get("template")
    if not template:
        return None
    out = template
    for name, value in given.items():
        out = out.replace("{%s}" % name, slug(value))
    unfilled = re.search(r"\{[^}]*\}", out) is not None
    out = re.sub(r"\{[^}]*\}", "", out)          # drop unfilled placeholders
    out = re.sub(r"-{2,}", "-", out).strip("-")   # tidy the seams
    if unfilled or not out:
        # The template referenced params this job does not declare, so the id
        # would be a CONSTANT -- every run would reuse it and clobber the
        # previous run's state file. Fall back to a unique suffix.
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M%S%f")[:20]
        out = ("%s-%s" % (out, stamp)).strip("-")
    return out or None


def cmd_run(argv):
    nick, job_name = argv[0], argv[1] if len(argv) > 1 else None
    reg = load_registry()
    res = reg["resources"].get(nick)
    if res is None:
        print("ERROR: '%s' is not registered" % nick)
        sys.exit(EXIT_USAGE)
    jobs = res.get("jobs") or {}
    if not job_name or job_name.startswith("--") or job_name not in jobs:
        print("ERROR: unknown job '%s' on %s — declared jobs: %s" % (
            job_name, nick, ", ".join(jobs) or "none"))
        sys.exit(EXIT_USAGE)
    job = jobs[job_name]
    opts = _parse_opts(argv[1:], {"--job-id": None, "--holder": getpass.getuser(),
                                  "--inputs": None}, repeat=("--param",))
    given = {}
    for p in opts["--param"]:
        name, _, value = p.partition("=")
        given[name] = value
    declared = job.get("params") or {}
    for name in given:
        if name not in declared:
            print("ERROR: job '%s' declares no param '%s' (declared: %s)" % (
                job_name, name, ", ".join(declared) or "none"))
            sys.exit(EXIT_USAGE)
    for name, spec in declared.items():
        if name not in given:
            if "default" in spec:
                given[name] = spec["default"]
            else:
                print("ERROR: job '%s' requires param '%s' (pattern: %s)" % (
                    job_name, name, spec.get("pattern")))
                sys.exit(EXIT_USAGE)
        value = str(given[name])
        given[name] = value
        if not re.fullmatch(spec.get("pattern") or DEFAULT_PARAM_PATTERN, value):
            print("ERROR: param '%s' value %r does not match its declared pattern %r" % (
                name, value, spec.get("pattern")))
            sys.exit(EXIT_USAGE)
    job_id = opts["--job-id"]
    if not job_id and job.get("jobIdSchema"):
        # the capability declares how its artifact runs should be named, so a
        # batch is identifiable afterwards (which model, which seed) without
        # opening a single log
        job_id = render_job_id(job["jobIdSchema"], given)
        if job_id:
            job_id = job_id[:47].rstrip("-.") + "-" + uuid.uuid4().hex[:16]
    job_id = job_id or new_job_id()
    paths = {"jobdir": "%s/%s" % (REMOTE_JOBS_ROOT, job_id)}
    if job.get("capdir"):
        paths["capdir"] = job["capdir"]
    rendered = render_command(job["cmd"], given, paths)
    reject_sudo(rendered)
    launch_opts = {"--holder": opts["--holder"], "--job-id": job_id,
                   "--inputs": opts["--inputs"], "--env": job.get("env"), "--rendered": True,
                   "--capability": job.get("capability"), "--digest": job.get("digest")}
    return _launch_job(reg, res, nick, job["workdir"], rendered, launch_opts)


def load_job(job_id):
    if not JOB_ID_RE.fullmatch(job_id):
        print("ERROR: invalid job ID")
        sys.exit(EXIT_USAGE)
    path = os.path.join(jobs_dir(), "%s.json" % job_id)
    try:
        with open(path) as f:
            job = json.load(f)
    except FileNotFoundError:
        print("ERROR: no job state at %s" % path)
        sys.exit(EXIT_USAGE)
    except ValueError as e:
        print("ERROR: job state at %s is corrupt (%s) — the job may still be "
              "running; check the remote ~/.remote-compute/jobs/ directory" % (path, e))
        sys.exit(EXIT_USAGE)
    if not job.get("remoteDir") or not job.get("resource"):
        print("ERROR: job state at %s is incomplete (missing resource/remoteDir)" % path)
        sys.exit(EXIT_USAGE)
    return job


def cmd_job_status(job_id):
    job = load_job(job_id)
    if job.get("protocol"):
        rc, reply = remote_state(job["resource"], "status", {"id": job_id})
        if rc:
            print("state: unknown (resource unreachable: %s)" % reply.get("error"))
            return 1
        state = reply.get("state", "unknown")
        print("state: %s exitcode: %s" % ("completed" if state == "done" else state, reply.get("exitcode")))
        if state not in ("done", "failed", "cancelled", "lost"):
            return 0
        _finish_local_job(job_id, job)
        return 0
    rc, out, err = ssh_run(job["resource"],
                           "cat %s/exitcode 2>/dev/null || echo __RUNNING__" % remote_path(job["remoteDir"]))
    if rc != 0:
        print("state: unknown (resource unreachable: %s)" % (err or "ssh failed"))
        return 0
    if out == "__RUNNING__" or out == "":
        print("state: running (no exitcode yet; logs: job-logs %s)" % job_id)
        return 0
    code = out.splitlines()[-1].strip()
    state = "completed" if code == "0" else "failed"
    print("state: %s exitcode: %s" % (state, code))
    _finish_local_job(job_id, job)
    return 0


def _finish_local_job(job_id, job):
    reg = load_registry()
    res = reg["resources"].get(job["resource"])
    if res:
        lock = (res.get("state") or {}).get("lock")
        if lock and lock.get("reason") == "job %s" % job_id:
            res["state"]["lock"] = None
            save_registry(reg, touched=job["resource"])
    # record the terminal state so _running_jobs never re-probes this job
    _mark_job_finished(os.path.join(jobs_dir(), "%s.json" % job_id))


def cmd_job_logs(job_id):
    job = load_job(job_id)
    # through remote_path like every other remote path: correct as raw today
    # (an unquoted tilde does expand, and the id is JOB_ID_RE-validated), but
    # the job JSON is hand-editable in exactly the way the registry is, and we
    # defend that elsewhere. Consistency here is defence in depth.
    rc, out, err = ssh_run(job["resource"],
                           "tail -n 100 %s/job.log" % remote_path(job["remoteDir"]))
    print(out if rc == 0 else "ERROR: %s" % (err or "no log yet"))
    return 0


def cmd_job_pull(job_id, dest=None):
    job = load_job(job_id)
    dest = dest or os.path.join(os.getcwd(), "compute-artifacts", job_id)
    os.makedirs(dest, exist_ok=True)
    # pull the job's OWN directory (artifacts + job.log + exitcode), never the
    # shared workdir -- see the COMPUTE_JOB_DIR contract in _launch_job
    remote_dir = job.get("remoteDir") or ("%s/%s" % (REMOTE_JOBS_ROOT, job_id))
    rc = subprocess.run(rsync_argv("%s:%s/" % (job["resource"], remote_dir.replace("~/", "")),
                                   dest + "/"), check=False).returncode
    print("pulled %s -> %s" % (job_id, dest) if rc == 0 else "ERROR: rsync exit %s" % rc)
    return 0 if rc == 0 else 1


# --- misc verbs -------------------------------------------------------------

def cmd_list():
    reg = load_registry()
    if not reg["resources"]:
        print("no compute resources registered (use: register nickname user@host)")
        return 0
    for name, res in reg["resources"].items():
        gpu = (res.get("capabilities") or {}).get("gpu", {})
        lock = (res.get("state") or {}).get("lock")
        print("%-16s %-14s gpu: %-28s vramMB: %-7s lastProbe: %-22s %s" % (
            name, (res.get("platform") or {}).get("os", "?"),
            gpu.get("name", "-"), gpu.get("vramMB", "-"),
            (res.get("state") or {}).get("lastProbe", "-"),
            ("LOCKED by %s" % lock["holder"]) if lock else ""))
    return 0


def cmd_exec(nick, payload):
    get_resource(nick)
    reject_sudo(payload)
    rc, out, err = ssh_run(nick, payload, timeout=300)
    if out:
        print(out)
    if err:
        sys.stderr.write(err + "\n")
    return rc


# --- scan: re-find registered machines whose address moved (DHCP) -----------
# Identity is the PINNED host key, never the address: a candidate is "the same
# machine" only when ssh-keyscan returns a key already pinned in known_hosts
# for the machine's old address. So scan never widens trust — it pins an
# already-acked key under a new address, and a stranger that took the old
# address is reported as KEY_MISMATCH, not accepted.

def _known_host_keys(host, port=22):
    """(type, blob) pairs pinned for exactly `host` in known_hosts. EXACT match
    per comma-separated entry (never a substring of the line: "192.0.2.1" is
    inside "192.0.2.17"), brackets+port tolerated. Hashed |1| entries are
    opaque and skipped; register pins plain keyscan lines, so the machines this
    tool registered are always findable."""
    kh = known_hosts_path()
    keys = set()
    if not os.path.exists(kh):
        return keys
    with open(kh) as f:
        for line in f:
            parts = line.strip().split()
            if parts and parts[0].startswith("@"):   # CA and revoked entries are not individual host pins.
                continue
            if len(parts) < 3 or parts[0].startswith("#") or parts[0].startswith("|"):
                continue
            for entry in parts[0].split(","):
                entry = entry.strip()
                if entry == _host_token(host, port) or (port == 22 and entry == "[%s]:22" % host):
                    keys.add((parts[1], parts[2]))
                    break
    return keys


def _identity_payload(machine_id=False):
    return "cat %s 2>/dev/null" % remote_path(REMOTE_ROOT + "/.machine-id" if machine_id else IDENTITY_FILE)


def _read_identity(nick, machine_id=False):
    """Identity stamp via the registered alias: None if login failed, "" if no
    file yet, else the nick the machine believes it is."""
    rc, out, _ = ssh_run(nick, _identity_payload(machine_id), timeout=20)
    return out.strip() if rc == 0 else None


def _write_identity(nick):
    """Preserve the legacy nickname stamp; new clients also pin a stable UUID."""
    old = _read_identity(nick)
    if old and old != nick:
        print("NOTE %s: preserving target nickname '%s'; this client uses its machine UUID" % (nick, old))
        return True
    rc, _, err = ssh_run(nick, "mkdir -p %s && printf '%%s\\n' %s > %s"
                         % (remote_path(REMOTE_ROOT), shlex.quote(nick), remote_path(IDENTITY_FILE)))
    if rc != 0:
        print("WARN %s: could not write the identity file: %s" % (nick, err or rc))
    return rc == 0


def _read_identity_at(host, user, keys, timeout=15, port=22, machine_id=False, nick=None):
    """Read the identity stamp at an address not yet pinned under that
    address — but which presented a key already pinned for the old one. Those
    exact keys go into a throwaway known_hosts for this single connection, so
    trust never widens. None = login failed, "" = no file, else the nick."""
    fd, tmp = tempfile.mkstemp(prefix=".kh-scan.")
    try:
        with os.fdopen(fd, "w") as f:
            for ktype, blob in sorted(keys):
                f.write("%s %s %s\n" % (_host_token(host, port), ktype, blob))
        argv = [_bin("COMPUTE_SSH_BIN", "ssh"), "-F", ssh_config_path(), "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=%s" % tmp,
                "-o", "ConnectTimeout=8", "-p", str(port)]
        if nick:
            argv += ["-o", "HostName=%s" % host, "-o", "HostKeyAlias=%s" % _host_token(host, port), "-l", user, nick]
        else:
            argv += ["%s@%s" % (user, host)]
        argv += ["bash -lc %s" % shlex.quote(_identity_payload(machine_id))]
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return None
        return p.stdout.strip() if p.returncode == 0 else None
    finally:
        os.unlink(tmp)


def _keyscan_keys(host, timeout=4, port=22):
    """Live (type, blob) pairs sshd at `host` presents; empty when nothing answers."""
    try:
        p = subprocess.run([_bin("COMPUTE_KEYSCAN_BIN", "ssh-keyscan"), "-T", str(timeout), "-p", str(port), host],
                           capture_output=True, text=True, timeout=timeout + 6)
    except subprocess.TimeoutExpired:
        return set()
    keys = set()
    for line in p.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 3 and not parts[0].startswith("#"):
            keys.add((parts[1], parts[2]))
    return keys


def _port22_open(host, timeout=1.0, port=22):
    """TCP connect to port 22 — never ICMP (Windows blocks it). The hermetic
    suite routes this through the nc stub (COMPUTE_NC_BIN); for real sweeps an
    in-process socket is used, since a /24 through 254 nc processes is slow."""
    if os.environ.get("COMPUTE_NC_BIN"):
        return subprocess.run([_bin("COMPUTE_NC_BIN", "nc"), "-z", "-w%d" % max(1, int(timeout)), host, str(port)],
                              capture_output=True).returncode == 0
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _local_ipv4():
    """This machine's primary IPv4 (UDP connect sends no packet); None if offline."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("198.51.100.1", 9))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def _slash24(host):
    try:
        return str(ipaddress.ip_network("%s/24" % ipaddress.IPv4Address(host), strict=False))
    except (ipaddress.AddressValueError, ValueError):
        return None


SCAN_MAX_HOSTS = 1024


def _sweep(subnets, port=22):
    """Every address in `subnets` with port 22 open, in address order."""
    hosts = []
    for cidr in subnets:
        net = ipaddress.ip_network(cidr, strict=False)
        if net.num_addresses > SCAN_MAX_HOSTS:
            print("ERROR: %s is larger than /22 — pass a narrower --subnet" % cidr)
            sys.exit(EXIT_USAGE)
        hosts.extend(str(h) for h in net.hosts())
    if not hosts:
        return []
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(64, len(hosts))) as ex:
        flags = list(ex.map(lambda host: _port22_open(host, port=port), hosts))
    return [h for h, ok in zip(hosts, flags) if ok]


def cmd_scan(args):
    nicks, subnets, picks, dry_run = [], [], {}, "--dry-run" in args
    i = 0
    while i < len(args):
        if args[i] == "--subnet" and i + 1 < len(args):
            subnets.append(args[i + 1]); i += 2
        elif args[i] == "--pick" and i + 1 < len(args):
            if "=" not in args[i + 1]:
                print("ERROR: --pick takes NICK=HOST (got '%s')" % args[i + 1])
                return EXIT_USAGE
            n, h = args[i + 1].split("=", 1)
            picks[n] = h; i += 2
        elif args[i].startswith("--"):
            i += 1
        else:
            nicks.append(args[i]); i += 1
    for cidr in subnets:
        try:
            net = ipaddress.ip_network(cidr, strict=False)
        except ValueError:
            print("ERROR: --subnet must be CIDR like 192.0.2.0/24 (got '%s')" % cidr)
            return EXIT_USAGE
        if net.num_addresses > SCAN_MAX_HOSTS:
            print("ERROR: %s is larger than /22 — pass a narrower --subnet" % cidr)
            return EXIT_USAGE

    reg = load_registry()
    if not reg["resources"]:
        print("no compute resources registered (use: register nickname user@host)")
        return 0
    for n in nicks + list(picks):
        if n not in reg["resources"]:
            print("ERROR: '%s' is not a registered compute resource" % n)
            return EXIT_USAGE
    targets = nicks or list(reg["resources"])

    failures = identity_failures = 0
    claims = {}   # identity -> [(nick, host)] over everything read this run

    def claim(ident, nick, host):
        if ident:
            claims.setdefault(ident, []).append((nick, host))

    # pass 1: who is fine where they are (key AND identity agree), who needs finding
    stale = []   # (nick, old_host, pinned keys)
    for nick in targets:
        res = reg["resources"][nick]
        host = (res.get("ssh") or {}).get("host")
        if not host:
            host, _ = alias_target(nick)
        if not host:
            print("NO_HOST %s: registry has no address — run: register %s user@host" % (nick, nick))
            failures += 1
            continue
        endpoint = ssh_endpoint(nick, host, (res.get("ssh") or {}).get("user"))
        port = endpoint["port"]
        expected_identity = res.get("machineId") or nick
        if endpoint.get("proxyjump") or endpoint.get("proxycommand"):
            ident = _read_identity(nick, bool(res.get("machineId")))
            if ident == expected_identity:
                print("OK %s %s (configured SSH proxy)" % (nick, host))
            else:
                print("UNREACHABLE or IDENTITY_MISMATCH %s: check the configured SSH proxy; LAN scanning is not applicable" % nick)
                failures += 1
            continue
        pinned = _known_host_keys(endpoint.get("hostkeyalias") or host, port)
        if not pinned:
            print("NO_PINNED_KEY %s %s: no plain known_hosts entry to identify it by —"
                  " re-run register (it pins the key after your ack)" % (nick, host))
            failures += 1
            continue
        if _port22_open(host, timeout=3, port=port):
            live = _keyscan_keys(host, port=port)
            if live & pinned:
                ident = _read_identity(nick, bool(res.get("machineId")))
                claim(ident, nick, host)
                if ident is None:
                    print("NEEDS_KEY_AUTH %s %s: host key matches but BatchMode login failed" % (nick, host))
                    failures += 1
                elif ident and ident != expected_identity:
                    print("IDENTITY_MISMATCH %s %s: host key matches but its identity file says '%s'"
                          " — investigate the target identity with its owner; do not overwrite it to bypass this check"
                          % (nick, host, ident))
                    identity_failures += 1
                else:
                    print("OK %s %s%s" % (nick, host, "" if ident else
                                          "  (no identity file yet — run: install-tools %s)" % nick))
                continue
            print("KEY_MISMATCH %s %s: a different machine answers there now" % (nick, host))
        else:
            print("UNREACHABLE %s %s:%s" % (nick, host, port))
        stale.append((nick, host, pinned))

    if stale:
        # pass 2: one sweep covers every stale machine
        if not subnets:
            for _, host, _ in stale:
                cidr = _slash24(host)
                if cidr and cidr not in subnets:
                    subnets.append(cidr)
            mine = _local_ipv4()
            cidr = _slash24(mine) if mine else None
            if cidr and cidr not in subnets:
                subnets.append(cidr)
            if not subnets:
                print("ERROR: cannot infer a subnet (no IPv4 addresses, offline?) — pass --subnet CIDR")
                return EXIT_USAGE
        print("scanning %s for ssh ..." % ", ".join(subnets))
    port_cache = {}
    for nick, old, pinned in stale:
        res = reg["resources"][nick]
        endpoint = ssh_endpoint(nick, old)
        port = endpoint["port"]
        expected_identity = res.get("machineId") or nick
        if port not in port_cache:
            open_hosts = _sweep(subnets, port)
            with concurrent.futures.ThreadPoolExecutor(max_workers=min(16, max(1, len(open_hosts)))) as ex:
                live_keys = dict(zip(open_hosts, ex.map(lambda host: _keyscan_keys(host, port=port), open_hosts)))
            port_cache[port] = (open_hosts, live_keys)
        open_hosts, live_keys = port_cache[port]
        candidates = [host for host in open_hosts if host != old]
        user = (res.get("ssh") or {}).get("user") or alias_target(nick)[1]
        keyed = [h for h in candidates if live_keys.get(h, set()) & pinned]
        if not keyed:
            print("NOT_FOUND %s %s: %d address(es) answer ssh in %s, none presents its pinned host key"
                  % (nick, old, len(open_hosts), ", ".join(subnets)))
            failures += 1
            continue
        # second factor: the identity stamp, read with exactly the matched keys pinned
        idents = {h: _read_identity_at(h, user, live_keys[h] & pinned, port=port,
                                     machine_id=bool(res.get("machineId")), nick=nick if res.get("machineId") else None) for h in keyed}
        for h in keyed:
            claim(idents[h], nick, h)
        matched = [h for h in keyed if idents[h] == expected_identity]
        legacy = [h for h in keyed if idents[h] == "" and not res.get("machineId")]
        for h in keyed:
            if idents[h] and idents[h] != expected_identity:
                print("IDENTITY_MISMATCH %s %s: presents its host key but the identity file says '%s'"
                      " — not adopted" % (nick, h, idents[h]))
                identity_failures += 1
        if not matched and legacy:
            print("NOTE %s: %s has its host key but no identity file yet (stamped before this"
                  " existed) — accepting on the key; the move stamps it" % (nick, ", ".join(legacy)))
            matched = legacy
        if not matched:
            unreadable = [h for h in keyed if idents[h] is None]
            if unreadable:
                print("NOT_FOUND %s %s: %s present its host key but BatchMode login failed there"
                      % (nick, old, ", ".join(unreadable)))
            else:
                print("NOT_FOUND %s %s: no candidate carries both its host key and its identity" % (nick, old))
            failures += 1
            continue
        if len(matched) > 1:
            if nick in picks:
                if picks[nick] not in matched:
                    print("ERROR: --pick %s=%s: that address does not present %s's key+identity (candidates: %s)"
                          % (nick, picks[nick], nick, ", ".join(matched)))
                    return EXIT_USAGE
                new, others = picks[nick], [h for h in matched if h != picks[nick]]
                print("NOTE %s: %s also present its host key and claim '%s' — give each its own name:"
                      " register <newnick> %s@<host>" % (nick, ", ".join(others), nick, user))
            else:
                print("DUPLICATE_IDENTITY %s: %s all present its host key and claim '%s'."
                      " Ask the human which address is really %s, then:"
                      " scan %s --pick %s=<host>; and register the other(s) under their own"
                      " name (register <newnick> %s@<host>) so each carries its own identity"
                      % (nick, ", ".join(matched), nick, nick, nick, nick, user))
                identity_failures += 1
                continue
        else:
            new = matched[0]
        if dry_run:
            print("WOULD_MOVE %s %s -> %s (host key matches pinned %s; identity %s)"
                  % (nick, old, new, "/".join(sorted(t for t, _ in live_keys[new] & pinned)),
                     "'%s'" % idents[new] if idents[new] else "unstamped"))
            continue
        # converge: pin the already-acked key under the new address, alias, registry
        kh = known_hosts_path()
        already = _known_host_keys(new, port)
        with open(kh, "a") as f:
            for ktype, blob in sorted(pinned & live_keys[new]):
                if (ktype, blob) not in already:
                    f.write("%s %s %s\n" % (_host_token(new, port), ktype, blob))
        ensure_alias(nick, new, user)
        res.setdefault("ssh", {}).update({"configAlias": nick, "host": new, "previousHost": old,
                                          "hostMovedAt": now_iso()})
        rc, _, err = ssh_run(nick, "true", timeout=20)
        res["ssh"]["batchModeVerified"] = rc == 0
        if rc == 0:
            res.setdefault("state", {})["lastSeen"] = now_iso()
            if not idents[new]:
                _write_identity(nick)
                res.setdefault("tools", {})["identity"] = nick
        reg["resources"][nick] = res
        save_registry(reg, touched=nick)
        print("MOVED %s %s -> %s (host key + identity matched; known_hosts, ssh alias, registry updated)"
              % (nick, old, new))
        if rc != 0:
            print("NEEDS_KEY_AUTH %s: BatchMode login failed at the new address (%s)" % (nick, err or rc))
            failures += 1

    # the same identity seen on two different addresses is always a conflict
    for ident, seen in claims.items():
        hosts = sorted({h for _, h in seen})
        if len(hosts) > 1 and not any(n in picks for n, _ in seen):
            print("DUPLICATE_IDENTITY %s: claimed at %s (%s)" % (
                ident, ", ".join(hosts), ", ".join("%s@%s" % (n, h) for n, h in seen)))
            identity_failures += 1
    if identity_failures:
        return EXIT_IDENTITY
    return EXIT_UNREACHABLE if failures else 0


def cmd_identity(nick):
    res = get_resource(nick)
    ident = _read_identity(nick, bool(res.get("machineId")))
    if ident is None:
        print("NEEDS_KEY_AUTH %s: BatchMode login failed" % nick)
        return EXIT_KEYAUTH
    print("IDENTITY %s: %s" % (nick, ident or "(no identity file — run: install-tools %s)" % nick))
    if ident and ident != (res.get("machineId") or nick):
        print("IDENTITY_MISMATCH %s: the machine says it is '%s'" % (nick, ident))
        return EXIT_IDENTITY
    return 0


# --- on-machine tools: one `remote-compute` command on every registered box --
# Converged by register and re-shippable with install-tools. The command is
# bash (remote-compute-remote.sh), installed to ~/.remote-compute/bin and
# linked from ~/.local/bin so the human typing at the box and the orchestrator
# over ssh drive the machine the same way (`remote-compute top`, `jobs`, ...).

def _install_tools(nick, res):
    """Ship _shared/ to ~/.remote-compute/tools and install the command.
    Returns (ok, on_path) and records a `tools` block on the resource."""
    tools, bindir = remote_path(REMOTE_TOOLS_ROOT), remote_path(REMOTE_BIN_ROOT)
    ssh_run(nick, "mkdir -p %s %s" % (tools, bindir))
    rc = subprocess.run(rsync_argv(SHARED_TOOLS_DIR.rstrip("/") + "/",
                                   "%s:%s/" % (nick, REMOTE_TOOLS_ROOT.replace("~/", ""))),
                        capture_output=True).returncode
    if rc != 0:
        print("WARN: rsync of on-machine tools failed (exit %s) — run: install-tools %s" % (rc, nick))
        return False, False
    # cp+chmod rather than a symlink into tools/: rsync replaces tools/ files
    # wholesale, and a dangling command during the copy is worse than a stale one
    rc, _, err = ssh_run(nick, "cp %s/remote-compute-remote.sh %s/remote-compute && chmod 0755 %s/remote-compute"
                         " && mkdir -p \"$HOME\"/.local/bin"
                         " && ln -sfn %s/remote-compute \"$HOME\"/.local/bin/remote-compute"
                         " && ln -sfn %s/remote-compute \"$HOME\"/.local/bin/compute-top"
                         % (tools, bindir, bindir, bindir, bindir))
    if rc != 0:
        print("WARN: installing the remote-compute command failed: %s" % (err or rc))
        return False, False
    controller = REMOTE_ROOT + "/controller"
    rc, _, err = ssh_run(nick, "mkdir -p %s" % remote_path(controller))
    if rc:
        print("WARN: could not prepare controller: %s" % err)
        return False, False
    rc = subprocess.run(rsync_argv("--exclude=__pycache__", os.path.dirname(os.path.abspath(__file__)) + "/",
                                   "%s:%s/" % (nick, controller.replace("~/", "", 1))),
                        capture_output=True).returncode
    if rc:
        print("WARN: could not ship controller; run install-tools again")
        return False, False
    # PATH convergence: ssh runs a command through the login shell's -c, which
    # for zsh reads only ~/.zshenv and for bash -l reads ~/.bash_profile or
    # ~/.profile — so one idempotent, marker-fenced line goes into each file
    # that applies. The marker makes re-runs a no-op and removal a one-liner.
    ssh_run(nick, PATH_CONVERGE_SH)
    on_path = ssh_run(nick, "command -v remote-compute >/dev/null")[0] == 0
    stamped = _write_identity(nick)
    rc, reply = remote_state(nick, "identity", {"nickname": nick})
    if rc:
        print("WARN: could not establish target UUID: %s" % reply.get("error"))
        return False, on_path
    if reply.get("machineId"):
        res["machineId"] = reply["machineId"]
    res["tools"] = {"installedAt": now_iso(), "onPath": on_path,
                    "command": REMOTE_BIN_ROOT + "/remote-compute",
                    "identity": nick if stamped else None}
    return True, on_path


PATH_MARKER = "# >>> remote-compute (managed: PATH for the on-machine command) >>>"
PATH_CONVERGE_SH = (
    'for rc in "$HOME"/.zshenv "$HOME"/.profile "$HOME"/.bashrc "$HOME"/.bash_profile; do '
    '  case "$rc" in *bash_profile) [ -f "$rc" ] || continue ;; esac; '
    '  grep -qF %s "$rc" 2>/dev/null && continue; '
    '  printf %s >> "$rc"; '
    'done' % (shlex.quote(PATH_MARKER),
              shlex.quote("\n%s\ncase \":$PATH:\" in *\":$HOME/.local/bin:\"*) ;; *) export PATH=\"$HOME/.local/bin:$PATH\" ;; esac\n# <<< remote-compute <<<\n" % PATH_MARKER)))


def _path_note(res):
    shell = ((res.get("platform") or {}).get("quirks") or {}).get("defaultShell") or ""
    rc = "~/.zshrc" if "zsh" in shell else "~/.bashrc"
    return ("  NOTE: ~/.local/bin is not on the login PATH yet — the human adds to %s:\n"
            "        export PATH=\"$HOME/.local/bin:$PATH\"\n"
            "        (until then: ~/.remote-compute/bin/remote-compute <verb>)" % rc)


def cmd_install_tools(nick):
    reg = load_registry()
    res = get_resource(nick)
    ok, on_path = _install_tools(nick, res)
    if not ok:
        return EXIT_UNREACHABLE
    reg["resources"][nick] = res
    save_registry(reg, touched=nick)
    print("TOOLS %s: compute-top.py shipped, `remote-compute` command installed (on PATH: %s),"
          " identity stamped '%s'" % (nick, "yes" if on_path else "no", nick))
    if not on_path:
        print(_path_note(res))
    print("  try: ssh -t %s remote-compute top" % nick)
    return 0


# --- connect: the ssh one-liners for each machine ---------------------------

def cmd_connect(nicks):
    reg = load_registry()
    if not reg["resources"]:
        print("no compute resources registered (use: register nickname user@host)")
        return 0
    for n in nicks:
        if n not in reg["resources"]:
            print("ERROR: '%s' is not a registered compute resource" % n)
            return EXIT_USAGE
    for nick in (nicks or list(reg["resources"])):
        res = reg["resources"][nick]
        ssh = res.get("ssh") or {}
        host, user = ssh.get("host"), ssh.get("user")
        if not host:
            host, user = alias_target(nick)
        gpu = ((res.get("capabilities") or {}).get("gpu") or {}).get("name") or "no gpu"
        endpoint = ssh_endpoint(nick, host, user)
        state = "up" if ssh_run(nick, "true", timeout=15)[0] == 0 else "down"
        lock = (res.get("state") or {}).get("lock")
        print("%s  %s@%s  %s  %s  %s%s" % (nick, user or "?", host or "?",
                                           (res.get("platform") or {}).get("os", "?"), gpu, state,
                                           ("  LOCKED by %s" % lock["holder"]) if lock else ""))
        for cmd, what in (("ssh %s" % nick, "shell"),
                          ("ssh -t %s remote-compute top" % nick, "live job dashboard"),
                          ("ssh %s remote-compute jobs" % nick, "one-shot job table"),
                          ("ssh %s remote-compute gpu" % nick, "GPU summary")):
            print("  %-44s # %s" % (cmd, what))
        print("  %-44s # same dashboard, shorter" % ("ssh -t %s compute-top" % nick))
        if not (res.get("tools") or {}).get("installedAt"):
            print("  (on-machine command not installed yet: install-tools %s)" % nick)
        if state == "down":
            print("  (SSH unavailable on configured port %s — if its address may have changed: scan %s)" % (endpoint["port"], nick))
    return 0


def cmd_remove(nick):
    reg = load_registry()
    if nick in reg["resources"]:
        del reg["resources"][nick]
        save_registry(reg, touched=nick)
        print("removed %s from the registry (remote machine untouched;"
              " ssh alias kept in %s — delete by hand if unwanted)" % (nick, ssh_config_path()))
    else:
        print("'%s' was not registered" % nick)
    return 0


def cmd_install_cli(args):
    parser = argparse.ArgumentParser(prog="remote-compute install-cli")
    parser.add_argument("--prefix", default="~/.local")
    options = parser.parse_args(args)
    prefix = Path(options.prefix).expanduser().resolve()
    source = Path(__file__).resolve().parent
    destination = prefix / "share" / "remote-compute"
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".remote-compute-", dir=destination.parent))
    try:
        shutil.copytree(source, stage, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        previous = destination.with_name(".remote-compute-previous-" + uuid.uuid4().hex)
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
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    bindir = prefix / "bin"
    bindir.mkdir(parents=True, exist_ok=True)
    launcher = ("#!/usr/bin/env bash\nexport REMOTE_COMPUTE_CONTROLLER=%s\nexport REMOTE_COMPUTE_TOOLS=%s\nexec bash %s \"$@\"\n" % (
        shlex.quote(str(destination / "remote-compute.py")),
        shlex.quote(str(destination / "remote-capabilities" / "_shared")),
        shlex.quote(str(destination / "remote-capabilities" / "_shared" / "remote-compute-remote.sh"))))
    path = bindir / "remote-compute"
    fd, temporary = tempfile.mkstemp(dir=bindir, prefix=".remote-compute-")
    with os.fdopen(fd, "w") as stream:
        stream.write(launcher)
    os.chmod(temporary, 0o755)
    os.replace(temporary, path)
    print("INSTALLED %s (version %s)" % (path, VERSION))
    if str(bindir) not in os.environ.get("PATH", "").split(os.pathsep):
        print("Add to your shell PATH: export PATH=%s:\"$PATH\"" % shlex.quote(str(bindir)))
    return 0


def cmd_doctor(args):
    parser = argparse.ArgumentParser(prog="remote-compute doctor", description="Read-only registered / installed / ready diagnostics.")
    parser.add_argument("nickname", nargs="?")
    parser.add_argument("--json", action="store_true")
    options = parser.parse_args(args)
    registry = load_registry()
    names = [options.nickname] if options.nickname else list(registry["resources"])
    report = {"version": VERSION, "controller": {binary: shutil.which(binary) for binary in ("python3", "ssh", "rsync", "git")}, "machines": {}}
    failed = False
    for nick in names:
        res = registry["resources"].get(nick)
        checks = {"registered": res is not None, "ready": False, "issues": []}
        report["machines"][nick] = checks
        if res is None:
            checks["issues"].append("not registered; run register")
            failed = True
            continue
        endpoint = ssh_endpoint(nick, (res.get("ssh") or {}).get("host"), (res.get("ssh") or {}).get("user"))
        checks["endpoint"] = endpoint
        rc, reply = remote_state(nick, "doctor", {})
        checks["reachable"] = rc == 0
        if rc:
            checks["issues"].append(reply.get("error", "SSH/protocol unavailable"))
            failed = True
            continue
        checks["target"] = reply
        checks["issues"].extend(reply.get("payloadIssues", []))
        for cap in res.get("capabilities_installed", {}):
            if cap not in reply.get("capabilities", {}):
                checks["issues"].append("%s: absent from target catalog; run capabilities sync %s" % (cap, nick))
        rc, version, err = ssh_run(nick, "remote-compute version", timeout=20)
        checks["installed"] = rc == 0
        checks["installedVersion"] = version if rc == 0 else None
        if rc or VERSION not in version:
            checks["issues"].append("target CLI missing or older; run install-tools %s" % nick)
        if not reply.get("machineId"):
            checks["issues"].append("legacy target identity; run install-tools %s" % nick)
        for cap, installed in reply.get("capabilities", {}).items():
            if installed.get("legacy"):
                checks["issues"].append("%s: legacy payload without manifest metadata; reinstall once" % cap)
                continue
            local = (res.get("capabilities_installed") or {}).get(cap, {})
            if local.get("digest") != installed.get("digest"):
                checks["issues"].append("%s: client declarations out of date; run capabilities sync %s" % (cap, nick))
            manifest = installed.get("manifest") or {}
            for job_name, job in manifest.get("jobs", {}).items():
                env_name = job.get("env") or manifest.get("defaultEnv")
                env = (res.get("envs") or {}).get(env_name) if env_name else None
                if env_name and not env:
                    checks["issues"].append("%s:%s needs environment %s; configure it with add-env" % (cap, job_name, env_name))
        for env_name, env in (res.get("envs") or {}).items():
            if not env.get("activate"):
                continue
            # Environments are trusted recipes. Verification is explicit here;
            # doctor never saves a new registry snapshot or changes the host.
            reject_sudo(env["activate"])
            rc, out, err = ssh_run(nick, "%s && python -c %s" % (env["activate"], shlex.quote(env.get("verify") or "import sys; print(sys.version)")))
            if rc:
                checks["issues"].append("environment %s failed verification: %s" % (env_name, err or out))
        for job in reply.get("jobs", []):
            if job["state"] in ("lost", "unknown", "cancelling"):
                checks["issues"].append("job %s is %s; inspect its status/logs" % (job["id"], job["state"]))
        checks["ready"] = not checks["issues"]
        failed = failed or not checks["ready"]
    if options.json:
        print(json.dumps(report, indent=2))
    else:
        print("remote-compute doctor %s" % VERSION)
        for nick, checks in report["machines"].items():
            print("%s: registered=%s installed=%s ready=%s" % (nick, checks["registered"], checks.get("installed", False), checks["ready"]))
            for issue in checks["issues"]:
                print("  - %s" % issue)
        if not names:
            print("No registered machines. Run register <nickname> user@host.")
    return 1 if failed else 0


def cmd_policy(args):
    parser = argparse.ArgumentParser(prog="remote-compute policy")
    parser.add_argument("nickname")
    parser.add_argument("--max-concurrent-jobs", type=int, required=True)
    options = parser.parse_args(args)
    reg = load_registry()
    res = get_resource(options.nickname)
    rc, reply = remote_state(options.nickname, "policy", {"maxConcurrentJobs": options.max_concurrent_jobs})
    if rc:
        print("ERROR: %s" % reply.get("error"))
        return rc
    res.setdefault("policy", {})["maxConcurrentJobs"] = options.max_concurrent_jobs
    reg["resources"][options.nickname] = res
    save_registry(reg, touched=options.nickname)
    print("POLICY %s: maxConcurrentJobs=%s" % (options.nickname, options.max_concurrent_jobs))
    return 0


def cmd_job_cancel(job_id):
    job = load_job(job_id)
    rc, reply = remote_state(job["resource"], "cancel", {"id": job_id})
    print(json.dumps(reply))
    if rc == 0:
        _finish_local_job(job_id, job)
    return rc


SETUP_SHEETS = {
    "wsl2": """Windows + WSL2 setup (run on the Windows machine):
1. Install the latest NVIDIA driver on Windows (it supplies CUDA to WSL; install
   nothing CUDA-side inside Windows itself).
2. Admin PowerShell: wsl --install -d Ubuntu-24.04  — reboot, create the Linux user.
3. Mirrored networking — %UserProfile%\\.wslconfig:
       [wsl2]
       networkingMode=mirrored
   then: wsl --shutdown  and reopen (WSL then shares the host LAN IP).
4. In Ubuntu: nvidia-smi must show the GPU, then:
       sudo apt install -y openssh-server && sudo systemctl enable --now ssh
5. Firewall (admin PowerShell):
       New-NetFirewallRule -DisplayName "WSL SSH" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow
6. Router: DHCP reservation; find the IP via ipconfig (the Wi-Fi/Ethernet adapter's
   IPv4 — ignore vEthernet/172.x virtual adapters).
7. Power: never sleep on AC; lid-close = do nothing if it runs closed.
8. Keep venvs/datasets on ext4 (home dir), not /mnt/* — DrvFs is 5-10x slower for
   Python imports and small-file IO (probe marks such mounts slow: true).""",
    "linux": """Linux setup (bare metal or server):
1. NVIDIA driver + nvidia-smi working (or the registry records gpu.present: false, honestly).
2. sudo apt install -y openssh-server && sudo systemctl enable --now ssh  (or distro equivalent).
3. Firewall: sudo ufw allow 22/tcp  (if ufw is active).
4. DHCP reservation or static IP; find it with: ip -4 addr
5. Power: disable suspend (systemctl mask sleep.target suspend.target on a dedicated
   box, or the desktop environment's power settings).""",
    "macos": """macOS setup (e.g. an M-series Mac for MPS/MLX work):
1. System Settings, General, Sharing: turn Remote Login ON (that is sshd); restrict to your user.
2. Power: prevent sleeping on the power adapter (or, printed for you to run yourself:
   sudo pmset -c sleep 0).
3. DHCP reservation; find the IP via: ipconfig getifaddr en0
4. Probes differ here: GPU via system_profiler (chip + unified memory; cuda: none,
   mps: true); envs verified with torch.backends.mps.is_available(); MLX presence
   recorded as its own capability.""",
}


def main(argv):
    if not argv:
        print(__doc__)
        return 0
    verb, rest = argv[0], argv[1:]
    if verb in ("help", "-h", "--help"):
        print(__doc__)
        return 0
    if verb in ("version", "--version") and rest in ([], ["--json"]):
        print(json.dumps({"version": VERSION}) if rest else "remote-compute %s" % VERSION)
        return 0
    if rest in (["--help"], ["-h"]):
        print(__doc__)
        return 0
    if verb == "controller":
        return main(rest)
    if verb == "install-cli":
        return cmd_install_cli(rest)
    if verb == "doctor":
        return cmd_doctor(rest)
    if verb == "policy":
        return cmd_policy(rest)
    if verb == "job-cancel" and len(rest) == 1:
        return cmd_job_cancel(rest[0])
    arities = {"probe": 1, "install-tools": 1, "identity": 1, "envs": 1,
               "jobs": 1, "job-status": 1, "job-logs": 1, "remove": 1,
               "remove-job": 2, "setup-sheet": 1, "parse": 1}
    if verb in arities and len(rest) != arities[verb]:
        print("ERROR: %s requires exactly %s argument(s); see --help" % (verb, arities[verb]))
        return EXIT_USAGE
    if verb == "parse":
        kind = rest[0] if rest else ""
        fn = {"gpu": parse_gpu, "gpu-csv": parse_gpu_csv, "free": parse_free,
              "df": parse_df, "profiler": parse_profiler}.get(kind)
        if not fn:
            print("ERROR: parse kind must be gpu|gpu-csv|free|df|profiler")
            return EXIT_USAGE
        print(json.dumps(fn(sys.stdin.read())))
        return 0
    if verb == "setup-sheet":
        sheet = SETUP_SHEETS.get(rest[0] if rest else "")
        if not sheet:
            print("ERROR: setup-sheet takes wsl2|linux|macos")
            return EXIT_USAGE
        print(sheet)
        return 0
    if verb == "register" and rest:
        return cmd_register(rest)
    if verb == "probe" and rest:
        reg = load_registry()
        res = reg["resources"].get(rest[0])
        if res is None:
            print("ERROR: '%s' is not registered" % rest[0])
            return EXIT_USAGE
        probe_resource(rest[0], res)
        reg["resources"][rest[0]] = res
        save_registry(reg, touched=rest[0])
        print(json.dumps({"capabilities": res.get("capabilities", {}),
                          "platform": res.get("platform", {}),
                          "envs": {k: v.get("verified") for k, v in (res.get("envs") or {}).items()}}))
        return 0
    if verb == "install-tools" and rest:
        return cmd_install_tools(rest[0])
    if verb == "connect":
        return cmd_connect(rest)
    if verb == "identity" and rest:
        return cmd_identity(rest[0])
    if verb == "scan":
        return cmd_scan(rest)
    if verb in ("list", "status") and not rest:
        return cmd_list()
    if verb == "status" and len(rest) == 1:
        res = get_resource(rest[0])
        print(json.dumps(res, default=str))
        return 0
    if verb == "enable" and rest:
        return cmd_enable(rest)
    if verb == "disable" and rest:
        return cmd_disable(rest)
    if verb == "exec" and rest:
        nick = rest[0]
        argv = rest[2:] if len(rest) > 1 and rest[1] == "--" else rest[1:]
        # Two legitimate shapes:
        #  - ONE argument is already a whole command line ("ls ~/x"): pass it
        #    through, since quoting it would make it a single command NAME.
        #  - MULTIPLE argv words came pre-split by the caller's shell: rejoin
        #    with shlex.join so quoting survives (python -c 'import os; print(1)'
        #    must not be re-split remotely).
        payload = argv[0] if len(argv) == 1 else (shlex.join(argv) if argv else "")
        if not payload:
            print("ERROR: exec needs a command after --")
            return EXIT_USAGE
        return cmd_exec(nick, payload)
    if verb == "lock" and rest:
        opts = _parse_opts(rest, {"--holder": getpass.getuser(), "--reason": "manual"})
        return cmd_lock(rest[0], opts["--holder"], opts["--reason"])
    if verb == "unlock" and rest:
        parser = argparse.ArgumentParser(prog="remote-compute unlock")
        parser.add_argument("nickname")
        parser.add_argument("--holder", default=getpass.getuser())
        parser.add_argument("--force", action="store_true")
        options = parser.parse_args(rest)
        return cmd_unlock(options.nickname, options.holder, options.force)
    if verb == "dispatch" and rest:
        return cmd_dispatch(rest)
    if verb == "install-capability" and len(rest) >= 2:
        return cmd_install_capability(rest)
    if verb == "remove-capability" and len(rest) >= 2:
        return cmd_remove_capability(rest)
    if verb == "capabilities":
        return cmd_capability_cli(rest)
    if verb == "add-env" and len(rest) >= 2:
        return cmd_add_env(rest)
    if verb == "envs" and rest:
        return cmd_envs(rest[0])
    if verb == "add-job" and len(rest) >= 2:
        return cmd_add_job(rest)
    if verb == "remove-job" and len(rest) >= 2:
        return cmd_remove_job(rest[0], rest[1])
    if verb == "jobs" and rest:
        return cmd_jobs(rest[0])
    if verb == "run" and rest:
        return cmd_run(rest)
    if verb == "job-status" and rest:
        return cmd_job_status(rest[0])
    if verb == "job-logs" and rest:
        return cmd_job_logs(rest[0])
    if verb == "job-pull" and rest:
        opts = _parse_opts(rest, {"--dest": None})
        return cmd_job_pull(rest[0], opts["--dest"])
    if verb == "remove" and rest:
        return cmd_remove(rest[0])
    print("ERROR: unknown verb '%s' (see --help in the module docstring)" % verb)
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
