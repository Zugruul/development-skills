#!/usr/bin/env python3
"""Restricted assistant SSH client and explicit data-only skill installer (WSL)."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile

import yaml

# Python -I deliberately excludes cwd and PYTHONPATH, including this directory.
# Load the trusted sibling by its engine-owned absolute path, never from a repo.
_spec = importlib.util.spec_from_file_location("_remote_control_protocol", Path(__file__).resolve().with_name("remote_control_server.py"))
_protocol = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_protocol)
Refusal = _protocol.Refusal
bounded_run = _protocol.bounded_run
SSH = "/usr/bin/ssh"
SSH_TIMEOUT = 15
SKILL_NAME = "remote-compute-control"
SAFE_PATH = re.compile(r"/[A-Za-z0-9_ ./:-]+")


def _local_file(value):
    if not isinstance(value, str) or not SAFE_PATH.fullmatch(value) or ".." in Path(value).parts:
        raise Refusal("credential path must be absolute ASCII without expansions or options")
    return _protocol.checked_path(value)


def load_policy(manifest):
    try:
        path = _protocol.checked_path(manifest)
        data = yaml.safe_load(path.read_text())
        if not isinstance(data, dict) or type(data.get("version")) is not int or data["version"] != 1:
            raise Refusal("unsupported capability manifest version")
        hosts = data.get("provisioning", {}).get("hosts")
        if not isinstance(hosts, dict) or not hosts or len(hosts) > 32:
            raise Refusal("host allowlist is empty or invalid")
        return hosts
    except (OSError, ValueError, TypeError, AttributeError, yaml.YAMLError) as exc:
        raise Refusal(f"cannot read installed host allowlist: {exc}") from exc


def validate_host(policy, nickname):
    _protocol.identifier(nickname)
    if not isinstance(policy, dict) or nickname not in policy:
        raise Refusal("host is not in installed provisioning allowlist")
    entry = policy[nickname]
    if not isinstance(entry, dict) or set(entry) != {"host", "port", "user", "knownHosts", "keys"}:
        raise Refusal("host entry requires exact fields")
    host, user, port = entry["host"], entry["user"], entry["port"]
    if not isinstance(host, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}", host):
        raise Refusal("host must be a literal IPv4 address or DNS name without options")
    if not isinstance(user, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]{0,63}", user):
        raise Refusal("invalid SSH user")
    if type(port) is not int or not 1 <= port <= 65535:
        raise Refusal("invalid SSH port")
    _local_file(entry["knownHosts"])
    keys = entry["keys"]
    if not isinstance(keys, dict) or set(keys) != {"inspect", "cancel"}:
        raise Refusal("dedicated inspect and cancel keys are required")
    files = [_local_file(keys[cls]) for cls in ("inspect", "cancel")]
    if os.path.samefile(*files):
        raise Refusal("operation classes require distinct dedicated keys")
    for path in files:
        if path.stat().st_mode & 0o077:
            raise Refusal("dedicated private key must have mode 0600 or stricter")
    return entry


def build_ssh_argv(policy, nickname, operation, job_id=""):
    token = _protocol.encode_request(operation, job_id)
    entry = validate_host(policy, nickname)
    cls = "cancel" if operation == "cancel" else "inspect"
    # -o paths use OpenSSH config grammar, not shell quoting. The path validator
    # excludes quotes, escapes, percent/env expansions; spaces remain supported.
    options = [
        "BatchMode=yes", "IdentitiesOnly=yes", "IdentityAgent=none", "IdentityFile=none",
        f'IdentityFile="{entry["keys"][cls]}"', "CertificateFile=none",
        "PubkeyAuthentication=yes", "PreferredAuthentications=publickey",
        "PubkeyAcceptedAlgorithms=ssh-ed25519,rsa-sha2-512,rsa-sha2-256,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521",
        "PasswordAuthentication=no", "KbdInteractiveAuthentication=no", "GSSAPIAuthentication=no",
        "HostbasedAuthentication=no", "NumberOfPasswordPrompts=0", "StrictHostKeyChecking=yes",
        f'UserKnownHostsFile="{entry["knownHosts"]}"', "GlobalKnownHostsFile=/dev/null",
        "KnownHostsCommand=none", "VerifyHostKeyDNS=no", "UpdateHostKeys=no", "CheckHostIP=no",
        "ProxyCommand=none", "ProxyJump=none", "CanonicalizeHostname=no", "PermitLocalCommand=no",
        "ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes", "Tunnel=no",
        "RequestTTY=no", "StdinNull=yes", "ControlMaster=no", "ControlPath=none", "ControlPersist=no",
        "ConnectionAttempts=1", "ConnectTimeout=5", "ServerAliveInterval=5", "ServerAliveCountMax=1",
    ]
    return [SSH, "-F", "/dev/null", "-T", "-n", *[part for option in options for part in ("-o", option)],
            "-p", str(entry["port"]), "-l", entry["user"], entry["host"], token]


def invoke(manifest, nickname, operation, job_id=""):
    argv = build_ssh_argv(load_policy(manifest), nickname, operation, job_id)
    output = bounded_run(argv, timeout=SSH_TIMEOUT, env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
    try:
        result = json.loads(output)
        if not isinstance(result, dict) or set(result) != {"version", "ok", "operation", "data"}:
            raise ValueError("unexpected response fields")
        if type(result["version"]) is not int or result["version"] != 1 or result["ok"] is not True or result["operation"] != operation:
            raise ValueError("response does not match request")
        return result
    except (ValueError, TypeError, RecursionError) as exc:
        raise Refusal("invalid bounded remote response") from exc


def check(manifest):
    policy = load_policy(manifest)
    for nickname in policy:
        validate_host(policy, nickname)
    if not Path(SSH).is_file() or not os.access(SSH, os.X_OK):
        raise Refusal("POSIX OpenSSH client is unavailable")
    return {"ok": True, "scope": "local prerequisites only; server enforcement not verified"}


def install(assistant_root):
    root = _protocol.checked_path(assistant_root, directory=True)
    engine = Path(__file__).resolve()
    template = engine.parents[2] / "skills" / SKILL_NAME
    destination = root / ".claude/skills" / SKILL_NAME
    manifest = str(destination / "capability.yaml")
    # Preserve venv identity, but reject literal paths the adapter would template.
    interpreter = os.path.abspath(sys.executable)
    for binding, path in (("interpreter", interpreter), ("engine", str(engine)), ("manifest", manifest)):
        if "{" in path or "}" in path:
            raise Refusal(f"{binding} binding path contains braces; use a path without braces before installing")
    prefix = [interpreter, "-I", str(engine)]
    if destination.exists() or destination.is_symlink():
        raise Refusal("installation exists; preserve it and review any update explicitly")
    try:
        for parent in (root / ".claude", root / ".claude/skills"):
            if not parent.exists() and not parent.is_symlink():
                parent.mkdir(mode=0o700)
            _protocol.checked_path(parent, directory=True)
        data = yaml.safe_load((template / "capability.yaml").read_text())
        data["provisioning"]["check"] = prefix + ["check", "--manifest", manifest]
        data["invoke"]["exec"] = prefix + ["invoke", "--manifest", manifest, "--host={host}",
                                                  "--operation={operation}", "--job-id={job_id}"]
        with tempfile.TemporaryDirectory(prefix=".remote-control-", dir=destination.parent) as stage:
            staging = Path(stage) / SKILL_NAME
            staging.mkdir(mode=0o700)
            (staging / "SKILL.md").write_text((template / "SKILL.md").read_text())
            (staging / "capability.yaml").write_text(yaml.safe_dump(data, sort_keys=False))
            # An existing nonempty installation cannot be replaced by rename.
            if destination.exists() or destination.is_symlink():
                raise Refusal("installation appeared during install; refusing replacement")
            staging.rename(destination)
        return destination
    except (OSError, ValueError, yaml.YAMLError) as exc:
        raise Refusal(f"data-only installation failed: {exc}") from exc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    installation = commands.add_parser("install")
    installation.add_argument("--assistant-root", required=True)
    for command in ("check", "invoke"):
        sub = commands.add_parser(command)
        sub.add_argument("--manifest", required=True)
        if command == "invoke":
            sub.add_argument("--host", required=True)
            sub.add_argument("--operation", required=True)
            sub.add_argument("--job-id", default="")
    args = parser.parse_args()
    try:
        if os.name != "posix":
            raise Refusal("WSL/POSIX required; native PowerShell is unsupported")
        if args.command == "install":
            result = {"installed": str(install(args.assistant_root)), "enabled": False}
        elif args.command == "check":
            result = check(args.manifest)
        else:
            result = invoke(args.manifest, args.host, args.operation, args.job_id)
        print(json.dumps(result, ensure_ascii=True))
        return 0
    except Refusal as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stdout)
        print(f"refused: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
