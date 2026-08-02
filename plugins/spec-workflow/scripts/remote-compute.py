#!/usr/bin/env python3
"""remote-compute.py — register remote machines as user-level
compute resources and advertise their availability to projects.

Design: docs/design/remote-compute-plan.md. This is the HUMAN dev-workflow
layer (the orchestrator session operating machines the human owns, under the
human's own key). It implements nothing of SPEC-ASSISTANT §14/E7 and must not
be cited as satisfying any §14 requirement.

Registry lives at $COMPUTE_HOME (default ~/.claude/compute)/resources.yaml —
machine-local, never committed. `enable` advertises a machine to a project —
non-exclusive, capability-style (mirrors assistant.capabilities.<name>): the
repo's .claude/project.yaml `compute:` section gets a map keyed by alias with
{enabled, roles, probedAt, informational capability snapshot}; never
host/user/secrets. Many projects may enable the same machine — the machine-
local cooperative lock serializes actual use. Consumers re-probe before real
dispatch.

Hard rules enforced here: every ssh invocation carries -o BatchMode=yes (key
auth only, never a password prompt); sudo-containing payloads are rejected;
no dispatch to a resource locked by someone else; probes record real command
output or a verbatim error — never a guess.

CLI verbs (machine-readable output; interactivity is the calling agent's job):
    register <nick> [user@host] [--accept-hostkey]   converge to end-state
    probe <nick> | status [<nick>] | list
    enable <nick> --root <repo> [--role R]...     advertise to a project
    disable <nick> --root <repo>                  keep entry, enabled: false
    add-env <nick> NAME --activate CMD [--verify SNIPPET] | envs <nick>
    install-capability <nick> <bundle-dir> | capabilities <nick>
    exec <nick> -- <cmd...>
    lock <nick> [--holder H] [--reason R] | unlock <nick> [--force]
    dispatch <nick> --workdir W --cmd C [--env E] [--inputs DIR]
             [--job-id ID] [--holder H]
    job-status <id> | job-logs <id> | job-pull <id> [--dest D]
    remove <nick>
    setup-sheet wsl2|linux|macos
    parse gpu|free|df|profiler   (stdin -> JSON; unit-test surface)

Exit codes: 0 ok · 1 unreachable · 2 usage · 3 NEEDS_KEY_AUTH ·
4 NEEDS_HOSTKEY_ACK · 5 sudo rejected · 6 locked.
"""
import datetime
import getpass
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:  # same hard-environment stance as config.py
    sys.stderr.write("PREFLIGHT FAIL: PyYAML is required (pip install pyyaml)\n")
    sys.exit(1)

EXIT_UNREACHABLE, EXIT_USAGE, EXIT_KEYAUTH, EXIT_HOSTKEY, EXIT_SUDO, EXIT_LOCKED = 1, 2, 3, 4, 5, 6


def _env(name, default):
    return os.environ.get(name) or default


def compute_home():
    return _env("COMPUTE_HOME", os.path.expanduser("~/.claude/compute"))


def ssh_config_path():
    return _env("COMPUTE_SSH_CONFIG", os.path.expanduser("~/.ssh/config"))


def known_hosts_path():
    return os.path.join(os.path.dirname(ssh_config_path()), "known_hosts")


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


# --- registry ---------------------------------------------------------------

def registry_path():
    return os.path.join(compute_home(), "resources.yaml")


def load_registry():
    try:
        with open(registry_path()) as f:
            data = yaml.safe_load(f) or {}
    except FileNotFoundError:
        data = {}
    data.setdefault("schemaVersion", 1)
    data.setdefault("resources", {})
    return data


def save_registry(data, touched=None):
    """Persist the registry. `touched` names the resource this caller actually
    modified: the file is re-read immediately before writing and only that
    resource is applied, so a long-running verb (dispatch holds its copy across
    many seconds of ssh) cannot silently erase another process's concurrent
    write to a different resource — or to jobs/envs on the same one."""
    os.makedirs(compute_home(), mode=0o700, exist_ok=True)
    if touched:
        fresh = load_registry()
        if touched in data.get("resources", {}):
            fresh.setdefault("resources", {})[touched] = data["resources"][touched]
        else:
            fresh.get("resources", {}).pop(touched, None)
        data = fresh
    fd, tmp = tempfile.mkstemp(dir=compute_home(), prefix=".resources.")
    with os.fdopen(fd, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False, indent=4)
    os.replace(tmp, registry_path())


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
    nick = args[0]
    target = args[1] if len(args) > 1 and not args[1].startswith("--") else None
    accept_hostkey = "--accept-hostkey" in args
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

    # 1. connectivity: TCP port 22, never ping (Windows blocks ICMP)
    rc = subprocess.run([_bin("COMPUTE_NC_BIN", "nc"), "-z", "-w4", host, "22"],
                        capture_output=True).returncode
    if rc != 0:
        print("UNREACHABLE %s:22 — machine off, asleep, or sshd not listening." % host)
        print("If this box is new, print its setup sheet: setup-sheet wsl2|linux|macos")
        sys.exit(EXIT_UNREACHABLE)

    # 2. host key: pinned known_hosts; fingerprint shown, human-acked keyscan
    kh = known_hosts_path()
    # EXACT host match per entry, never a substring of the file: "192.0.2.1"
    # occurs inside "192.0.2.17", and any short name can collide with a base64
    # key blob, which silently skipped the acknowledgement gate and left the
    # new host unpinned. known_hosts' first field may list comma-separated
    # hosts and may be bracketed with a port.
    host_known = False
    if os.path.exists(kh):
        with open(kh) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                for entry in line.split()[0].split(","):
                    entry = entry.strip()
                    if entry.startswith("[") and "]" in entry:
                        entry = entry[1:entry.index("]")]
                    if entry == host:
                        host_known = True
                        break
                if host_known:
                    break
    if not host_known:
        scan = subprocess.run([_bin("COMPUTE_KEYSCAN_BIN", "ssh-keyscan"), "-T", "5", host],
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
    res.setdefault("ssh", {}).update({"configAlias": nick, "host": host, "user": user})

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
    ssh_run(nick, "mkdir -p ~/.compute-jobs")
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
    """Availability lives in .claude/project.local.yaml — the gitignored,
    machine-local overlay config.py merges over project.yaml (compute key
    only). Missing local file is normal: created on first enable. The repo
    must still be a spec-workflow repo (project.yaml present)."""
    if not os.path.exists(os.path.join(root, ".claude", "project.yaml")):
        print("ERROR: %s/.claude/project.yaml not found — this verb runs inside a spec-workflow repo" % root)
        sys.exit(EXIT_USAGE)
    return os.path.join(root, ".claude", "project.local.yaml")


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
    root = os.getcwd()
    roles = []
    i = 1
    while i < len(args):
        if args[i] == "--root" and i + 1 < len(args):
            root = args[i + 1]; i += 2
        elif args[i] == "--role" and i + 1 < len(args):
            roles.append(args[i + 1]); i += 2
        else:
            i += 1
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
    print("Snapshot is informational — consumers re-probe before real dispatch.")
    return 0


def cmd_disable(args):
    nick = args[0]
    root = os.getcwd()
    i = 1
    while i < len(args):
        if args[i] == "--root" and i + 1 < len(args):
            root = args[i + 1]; i += 2
        else:
            i += 1
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
    if not lock:
        print("not locked")
        return 0
    if lock.get("holder") != holder and not force:
        print("LOCKED: held by %s (reason: %s, since %s) — use --force to override" % (
            lock.get("holder"), lock.get("reason"), lock.get("since")))
        sys.exit(EXIT_LOCKED)
    if lock.get("holder") != holder:
        print("WARNING: force-unlocking %s — was held by %s (reason: %s, since %s)" % (
            nick, lock.get("holder"), lock.get("reason"), lock.get("since")))
    res["state"]["lock"] = None
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
            i += 1
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
    lock = (res.get("state") or {}).get("lock")
    if lock and lock.get("holder") != holder:
        print("LOCKED: %s is held by %s (reason: %s, since %s) — refusing dispatch" % (
            nick, lock.get("holder"), lock.get("reason"), lock.get("since")))
        sys.exit(EXIT_LOCKED)
    job_id = opts["--job-id"] or datetime.datetime.now(datetime.timezone.utc).strftime("j%Y%m%d%H%M%S")
    # --job-id is interpolated into the remote payload AND used as a local
    # filename: an unvalidated value is remote command injection plus path
    # traversal, and it lands after the sudo check on --cmd.
    if not JOB_ID_RE.fullmatch(job_id):
        print("ERROR: --job-id must match [A-Za-z0-9][A-Za-z0-9._-]{0,63} (got %r)" % job_id)
        sys.exit(EXIT_USAGE)
    # workdir reaches the remote shell too, via `cd <workdir>`; it faces the
    # same sudo guard as --cmd and is quoted at the interpolation site below.
    reject_sudo(workdir)
    remote_dir = "~/.compute-jobs/%s" % job_id
    # {jobdir} is engine-supplied and can only be resolved HERE, once the job
    # id exists. Without this the placeholder reached the remote shell
    # literally, breaking every bundle job that used it. $COMPUTE_JOB_DIR is
    # the equivalent for payloads that prefer reading the environment.
    cmd = cmd.replace("{jobdir}", remote_path(remote_dir))

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
        subprocess.run(rsync_argv(opts["--inputs"].rstrip("/") + "/",
                                  "%s:%s/" % (nick, workdir)), check=False)

    env_prefix = ""
    envs = res.get("envs") or {}
    if opts["--env"]:
        env = envs.get(opts["--env"])
        if not env or not env.get("activate"):
            print("ERROR: env '%s' is not configured on %s" % (opts["--env"], nick))
            sys.exit(EXIT_USAGE)
        # re-check here, not only at add-env: the registry is a plain YAML file
        # a human can edit, so an install-time check alone is defeatable
        reject_sudo(env["activate"])
        env_prefix = env["activate"] + " && "
    # COMPUTE_JOB_DIR is the per-job artifact contract: payloads write outputs
    # there (never into the shared workdir), so job-pull returns THIS job's
    # results instead of every previous job's leftovers.
    # workdir and remote_dir are QUOTED here: both carry operator-supplied
    # text into a remote shell. cmd is already built from regex-validated,
    # shell-quoted params (or an explicit --cmd the caller dictated).
    q_wd, q_rd = remote_path(workdir), remote_path(remote_dir)
    inner = "cd %s && export COMPUTE_JOB_DIR=%s && %s%s > %s/job.log 2>&1; echo $? > %s/exitcode" % (
        q_wd, q_rd, env_prefix, cmd, q_rd, q_rd)
    launch = ("mkdir -p %s && if command -v tmux >/dev/null 2>&1; then "
              "tmux new-session -d -s cj-%s %s && tmux list-panes -t cj-%s -F '#{pane_pid}' > %s/pid; "
              "else setsid nohup bash -c %s >/dev/null 2>&1 & echo $! > %s/pid; fi") % (
        q_rd, job_id, shlex.quote("bash -lc %s" % shlex.quote(inner)), job_id, q_rd,
        shlex.quote(inner), q_rd)
    rc, out, err = ssh_run(nick, launch, timeout=120)
    if rc != 0:
        # release the lock we just took: otherwise a failed launch leaves the
        # resource LOCKED with no job state, recoverable only via --force
        if not manual_lock:
            res.setdefault("state", {})["lock"] = None
            save_registry(reg, touched=nick)
        print("ERROR: launch failed on %s: %s" % (nick, err or out))
        sys.exit(1)

    state = {"id": job_id, "resource": nick, "workdir": workdir, "cmd": cmd,
             "env": opts["--env"], "holder": holder, "remoteDir": remote_dir,
             "submittedAt": now_iso()}
    _atomic_json(os.path.join(jobs_dir(), "%s.json" % job_id), state)
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
# to ~/.compute-jobs/_caps/<name>/ and declares the manifest's jobs through the
# same add-job machinery a human would use. The engine stays domain-agnostic —
# supporting a new domain means adding a bundle, never editing this file.
# Templates may use {capdir} (the installed payload dir) and {jobdir} (the
# per-job directory, resolved at dispatch); everything else is a job param.

CAPS_REMOTE_ROOT = "~/.compute-jobs/_caps"


def cmd_install_capability(argv):
    nick, bundle = argv[0], argv[1]
    opts = _parse_opts(argv[1:], {"--env": None})
    manifest_path = os.path.join(bundle, "capability.yaml")
    try:
        with open(manifest_path) as f:
            manifest = yaml.safe_load(f) or {}
    except FileNotFoundError:
        print("ERROR: no capability.yaml in %s" % bundle)
        sys.exit(EXIT_USAGE)
    cap = manifest.get("name")
    jobs = manifest.get("jobs") or {}
    if not cap or not jobs:
        print("ERROR: %s must declare a name and at least one job" % manifest_path)
        sys.exit(EXIT_USAGE)
    for job in jobs.values():
        reject_sudo(job.get("cmd") or "")

    reg = load_registry()
    res = reg["resources"].get(nick)
    if res is None:
        print("ERROR: '%s' is not registered" % nick)
        sys.exit(EXIT_USAGE)

    capdir = "%s/%s" % (CAPS_REMOTE_ROOT, cap)
    ssh_run(nick, "mkdir -p %s" % remote_path(capdir))
    for rel in (manifest.get("payload") or []):
        src = os.path.join(bundle, rel)
        if not os.path.exists(src):
            print("ERROR: payload file %s declared in the manifest is missing" % src)
            sys.exit(EXIT_USAGE)
        rc = subprocess.run(rsync_argv(src, "%s:%s/" % (nick, capdir.replace("~/", ""))),
                            check=False).returncode
        if rc != 0:
            print("ERROR: rsync of %s failed (exit %s)" % (rel, rc))
            sys.exit(1)

    declared = []
    for job_name, job in jobs.items():
        key = "%s:%s" % (cap, job_name)
        res.setdefault("jobs", {})[key] = {
            "description": job.get("description") or "",
            "workdir": job.get("workdir") or capdir,
            "cmd": (job.get("cmd") or "").replace("{capdir}", remote_path(capdir)),
            "env": job.get("env") or opts["--env"],
            "params": {k: (dict(v) if isinstance(v, dict) else {"pattern": v})
                       for k, v in (job.get("params") or {}).items()},
            "capability": cap,
        }
        declared.append(key)
    res.setdefault("capabilities_installed", {})[cap] = {
        "version": manifest.get("version"), "installedAt": now_iso(),
        "description": manifest.get("description") or "", "jobs": declared,
    }
    save_registry(reg, touched=nick)
    print("installed capability '%s' on %s (payload -> %s)" % (cap, nick, capdir))
    for key in declared:
        print("  job: %s" % key)
    return 0


def cmd_capabilities(nick):
    res = get_resource(nick)
    caps = res.get("capabilities_installed") or {}
    if not caps:
        print("no capabilities installed on %s "
              "(use: install-capability %s <bundle-dir>)" % (nick, nick))
        return 0
    for name, cap in caps.items():
        print("%-12s v%-3s %s" % (name, cap.get("version"), (cap.get("description") or "").strip()))
        print("             jobs: %s" % ", ".join(cap.get("jobs") or []))
    return 0


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
    rendered = job["cmd"]
    for name, spec in declared.items():
        if name not in given:
            if "default" in spec:
                given[name] = spec["default"]
            else:
                print("ERROR: job '%s' requires param '%s' (pattern: %s)" % (
                    job_name, name, spec.get("pattern")))
                sys.exit(EXIT_USAGE)
        value = given[name]
        if not re.fullmatch(spec.get("pattern") or DEFAULT_PARAM_PATTERN, value):
            print("ERROR: param '%s' value %r does not match its declared pattern %r" % (
                name, value, spec.get("pattern")))
            sys.exit(EXIT_USAGE)
        # substitution is always shell-quoted — a validated value still never
        # reaches the remote shell unquoted (mirrors SPEC-ASSISTANT §11.5)
        rendered = rendered.replace("{%s}" % name, shlex.quote(value))
    reject_sudo(rendered)
    launch_opts = {"--holder": opts["--holder"], "--job-id": opts["--job-id"],
                   "--inputs": opts["--inputs"], "--env": job.get("env")}
    return _launch_job(reg, res, nick, job["workdir"], rendered, launch_opts)


def load_job(job_id):
    path = os.path.join(jobs_dir(), "%s.json" % job_id)
    try:
        with open(path) as f:
            job = json.load(f)
    except FileNotFoundError:
        print("ERROR: no job state at %s" % path)
        sys.exit(EXIT_USAGE)
    except ValueError as e:
        print("ERROR: job state at %s is corrupt (%s) — the job may still be "
              "running; check the remote ~/.compute-jobs/ directory" % (path, e))
        sys.exit(EXIT_USAGE)
    if not job.get("remoteDir") or not job.get("resource"):
        print("ERROR: job state at %s is incomplete (missing resource/remoteDir)" % path)
        sys.exit(EXIT_USAGE)
    return job


def cmd_job_status(job_id):
    job = load_job(job_id)
    rc, out, err = ssh_run(job["resource"],
                           "cat %s/exitcode 2>/dev/null || echo __RUNNING__" % job["remoteDir"])
    if rc != 0:
        print("state: unknown (resource unreachable: %s)" % (err or "ssh failed"))
        return 0
    if out == "__RUNNING__" or out == "":
        print("state: running (no exitcode yet; logs: job-logs %s)" % job_id)
        return 0
    code = out.splitlines()[-1].strip()
    state = "completed" if code == "0" else "failed"
    print("state: %s exitcode: %s" % (state, code))
    # job over: release the cooperative lock this dispatch took
    reg = load_registry()
    res = reg["resources"].get(job["resource"])
    if res:
        lock = (res.get("state") or {}).get("lock")
        if lock and lock.get("reason") == "job %s" % job_id:
            res["state"]["lock"] = None
            save_registry(reg, touched=job["resource"])
    # record the terminal state so _running_jobs never re-probes this job
    _mark_job_finished(os.path.join(jobs_dir(), "%s.json" % job_id))
    return 0


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
    remote_dir = job.get("remoteDir") or ("~/.compute-jobs/%s" % job_id)
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
        return EXIT_USAGE
    verb, rest = argv[0], argv[1:]
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
    if verb in ("list", "status") and not rest:
        return cmd_list()
    if verb == "status" and rest:
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
        holder, reason = getpass.getuser(), "manual"
        for i, a in enumerate(rest):
            if a == "--holder" and i + 1 < len(rest):
                holder = rest[i + 1]
            if a == "--reason" and i + 1 < len(rest):
                reason = rest[i + 1]
        return cmd_lock(rest[0], holder, reason)
    if verb == "unlock" and rest:
        holder = getpass.getuser()
        for i, a in enumerate(rest):
            if a == "--holder" and i + 1 < len(rest):
                holder = rest[i + 1]
        return cmd_unlock(rest[0], holder, "--force" in rest)
    if verb == "dispatch" and rest:
        return cmd_dispatch(rest)
    if verb == "install-capability" and len(rest) >= 2:
        return cmd_install_capability(rest)
    if verb == "capabilities" and rest:
        return cmd_capabilities(rest[0])
    if verb == "add-env" and len(rest) >= 2:
        return cmd_add_env(rest)
    if verb == "envs" and rest:
        return cmd_envs(rest[0])
    if verb == "add-job" and len(rest) >= 2:
        return cmd_add_job(rest)
    if verb == "jobs" and rest:
        return cmd_jobs(rest[0])
    if verb == "run" and rest:
        return cmd_run(rest)
    if verb == "job-status" and rest:
        return cmd_job_status(rest[0])
    if verb == "job-logs" and rest:
        return cmd_job_logs(rest[0])
    if verb == "job-pull" and rest:
        dest = None
        for i, a in enumerate(rest):
            if a == "--dest" and i + 1 < len(rest):
                dest = rest[i + 1]
        return cmd_job_pull(rest[0], dest)
    if verb == "remove" and rest:
        return cmd_remove(rest[0])
    print("ERROR: unknown verb '%s' (see --help in the module docstring)" % verb)
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
