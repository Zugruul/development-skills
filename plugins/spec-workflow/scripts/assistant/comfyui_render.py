#!/usr/bin/env python3
"""Managed ComfyUI jobs: pinned API graphs, owned requests and audited tunnels."""
import argparse
from dataclasses import dataclass, replace
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
from urllib.parse import urlencode
import uuid

import yaml

# The installed data binds this absolute plugin entry point under python -I.
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from assistant import adapters, capability_index, discovery, remote_audit, remote_control
from assistant.comfyui_transport import Tunnel, TransportError

NAME = KIND = "comfyui-render"
UUID = re.compile(r"[a-f0-9]{32}\Z")
HASH = re.compile(r"[a-f0-9]{64}\Z")
IDENT = remote_audit.identifier
PARAMS = {"host": {"type": "string"}, "operation": {"type": "string", "allowlist": ["render", "cancel"]},
          "workflow": {"type": "string"}, "values": {"type": "string"}, "task_id": {"type": "string"}}


class RenderError(remote_audit.AuditError):
    """Only engine-selected reason text and validated dependency identifiers."""
    def __init__(self, reason, dependencies=()):
        reasons = {"policy", "template", "parameters", "dependencies", "out_of_memory", "execution_failed",
                   "artifact", "ownership", "deadline", "binding", "unavailable"}
        reason = reason if reason in reasons else "unavailable"
        message = "ComfyUI " + reason
        if reason == "deadline":
            message += ": deadline expired; running remote work may continue"
        if reason == "dependencies":
            names = [d for d in dependencies if isinstance(d, str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", d)]
            message += ": missing or incompatible " + ", ".join(names[:16])
        Exception.__init__(self, message)
        self.refusal = reason in {"policy", "template", "parameters", "dependencies", "binding", "ownership"}


@dataclass(frozen=True)
class Deferred:
    """Opt-in worker result; legacy executor dicts keep their existing meaning."""
    pass


def is_render(name):
    return isinstance(name, str) and name.strip().lower() == NAME


def _plain(value):
    return type(value) in (str, int, float, bool) and (type(value) is not float or math.isfinite(value))


def prepare(params, refusal=None, root=None):
    """Validate and freeze before queueing. Refuse credential syntax, don't mutate prompts."""
    safe = {}
    try:
        if not isinstance(params, dict) or set(params) != set(PARAMS) or adapters.validate_params(PARAMS, params):
            raise ValueError()
        if not IDENT(params["host"]) or not IDENT(params["workflow"]):
            raise ValueError()
        if len(params["values"]) > 8192:
            raise ValueError()
        values = json.loads(params["values"])
        if not isinstance(values, dict) or len(values) > 32:
            raise ValueError()
        for key, value in values.items():
            if not IDENT(key) or remote_audit.SENSITIVE_KEY.search(key) or not _plain(value):
                raise ValueError()
            if isinstance(value, str) and (len(value) > 4096 or remote_audit.redact_text(value) != value):
                raise ValueError()
        if params["operation"] == "cancel":
            if not UUID.fullmatch(params["task_id"]) or values:
                raise ValueError()
        elif params["task_id"]:
            raise ValueError()
        safe = {**params, "values": json.dumps(values, sort_keys=True, allow_nan=False)}
        if root is not None:
            secrets = []
            candidate = discovery.classify_repo(root)
            secrets.extend(remote_audit.secret_values(candidate.section))
            manifest = Path(root) / ".claude/skills" / NAME / "capability.yaml"
            if manifest.exists():
                if manifest.stat().st_size > 1048576:
                    raise ValueError()
                secrets.extend(remote_audit.secret_values(yaml.safe_load(manifest.read_text())))
            leaves = [value for key, value in params.items() if key != "values"] + list(values) + list(values.values())
            if any(remote_audit.redact_text(leaf, secrets) != leaf for leaf in leaves if isinstance(leaf, str)):
                raise ValueError()
    except Exception:
        safe = {}
        refusal = "invalid_params"
    return {"name": NAME, "params": safe, "refusal": refusal if isinstance(refusal, str) and refusal in remote_audit.REASONS else None}


def task_payload(payload, root=None):
    payload = payload if isinstance(payload, dict) else {}
    return prepare(payload.get("params"), payload.get("refusal"), root=root)


def recovery(value):
    """The only durable render metadata, separate from all prunable traces."""
    if (not isinstance(value, dict) or set(value) != {"request_id", "deadline", "binding", "phase"}
            or not isinstance(value["request_id"], str) or not UUID.fullmatch(value["request_id"])
            or type(value["deadline"]) not in (int, float) or not math.isfinite(value["deadline"]) or value["deadline"] <= 0
            or not isinstance(value["binding"], str) or not HASH.fullmatch(value["binding"])
            or value["phase"] not in {"prepared", "posting", "submitted", "cancelled"}):
        raise RenderError("ownership")
    return dict(value)


def progress(value):
    result = {"state": "running"}
    if isinstance(value, dict):
        if IDENT(value.get("node")):
            result["node"] = value["node"]
        a, b = value.get("value"), value.get("max")
        if type(a) is int and type(b) is int and 0 <= a <= b <= 1000000 and b > 0:
            result.update(value=a, max=b)
    return result


def _exact(value, fields):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise RenderError("policy")


def _file(path, limit=1048576):
    checked = remote_control._local_file(path)
    if checked.stat().st_size > limit:
        raise RenderError("policy")
    return checked


def validate_host(entry):
    _exact(entry, {"host", "port", "user", "knownHosts", "keys", "comfyPort"})
    if not isinstance(entry["host"], str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}", entry["host"]):
        raise RenderError("policy")
    if not isinstance(entry["user"], str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]{0,63}", entry["user"]):
        raise RenderError("policy")
    for port in (entry["port"], entry["comfyPort"]):
        if type(port) is not int or not 1 <= port <= 65535:
            raise RenderError("policy")
    _exact(entry["keys"], {"tunnel"})
    key = _file(entry["keys"]["tunnel"])
    if key.stat().st_mode & 0o077:
        raise RenderError("policy")
    _file(entry["knownHosts"])
    return entry


def load_workflow(spec, values):
    _exact(spec, {"template", "sha256", "timeout", "inputs", "output"})
    if type(spec["timeout"]) is not int or not 1 <= spec["timeout"] <= 86400:
        raise RenderError("policy")
    raw = _file(spec["template"]).read_bytes()
    if not isinstance(spec["sha256"], str) or not HASH.fullmatch(spec["sha256"]) or hashlib.sha256(raw).hexdigest() != spec["sha256"]:
        raise RenderError("template")
    graph = json.loads(raw)
    # Same pre-authored API JSON used by comfy-run/import; no graph generation or UI importer.
    if not isinstance(graph, dict) or not 1 <= len(graph) <= 256 or {"nodes", "links"} & graph.keys():
        raise RenderError("template")
    for node_id, node in graph.items():
        if not IDENT(node_id) or not isinstance(node, dict) or set(node) - {"class_type", "inputs", "_meta"}:
            raise RenderError("template")
        if not IDENT(node.get("class_type")) or not isinstance(node.get("inputs"), dict):
            raise RenderError("template")
        for name, value in node["inputs"].items():
            if not IDENT(name):
                raise RenderError("template")
            if isinstance(value, list):
                if len(value) != 2 or not isinstance(value[0], str) or value[0] not in graph or type(value[1]) is not int or value[1] < 0:
                    raise RenderError("template")
            elif not _plain(value):
                raise RenderError("template")
    bindings = spec["inputs"]
    if not isinstance(bindings, dict) or len(bindings) > 32 or set(values) - set(bindings):
        raise RenderError("parameters")
    seen = set()
    types = {"string": str, "integer": int, "number": float, "boolean": bool}
    for name, binding in bindings.items():
        if not IDENT(name) or not isinstance(binding, dict) or not {"node", "input", "type"} <= set(binding):
            raise RenderError("policy")
        if set(binding) - {"node", "input", "type", "minimum", "maximum", "maxLength", "allowlist"}:
            raise RenderError("policy")
        node_id, key, kind = binding["node"], binding["input"], binding["type"]
        if not isinstance(node_id, str) or not isinstance(key, str) or kind not in types or node_id not in graph:
            raise RenderError("policy")
        # Path-like node inputs must remain pre-authored even when scalar-valued.
        if re.search(r"path|file|folder|directory|prefix", key, re.I):
            raise RenderError("policy")
        old = graph[node_id]["inputs"].get(key)
        if (node_id, key) in seen or type(old) is not types[kind]:
            raise RenderError("policy")
        seen.add((node_id, key))
        value = values.get(name, old)
        if type(value) is not type(old):
            raise RenderError("parameters")
        if kind == "string":
            bound = binding.get("maxLength")
            if type(bound) is not int or not 0 <= bound <= 4096 or len(value) > bound:
                raise RenderError("parameters")
        if kind in {"integer", "number"}:
            lo, hi = binding.get("minimum"), binding.get("maximum")
            if type(lo) not in (int, float) or type(hi) not in (int, float) or not all(math.isfinite(x) for x in (lo, hi, value)) or not lo <= value <= hi:
                raise RenderError("parameters")
        if "allowlist" in binding and (not isinstance(binding["allowlist"], list) or value not in binding["allowlist"]):
            raise RenderError("parameters")
        graph[node_id]["inputs"][key] = value
    output = spec["output"]
    _exact(output, {"node", "field", "index", "type", "maxBytes"})
    if (output["node"] not in graph or output["field"] != "images" or output["type"] != "png"
            or type(output["index"]) is not int or not 0 <= output["index"] <= 64
            or type(output["maxBytes"]) is not int or not 1 <= output["maxBytes"] <= 64 * 1024 * 1024):
        raise RenderError("policy")
    return graph


def authority(root, params, binding=None):
    try:
        candidate = discovery.classify_repo(root)
        if candidate.kind != "candidate" or candidate.section.get("capabilities", {}).get(NAME, {}).get("enabled") is not True:
            raise remote_audit.Refused("disabled")
        skill = Path(root) / ".claude/skills" / NAME
        manifest = skill / "capability.yaml"
        cap = capability_index.load_capability(skill)
        if isinstance(cap, capability_index.CapabilityError):
            raise RenderError("policy")
        if adapters.validate_params(cap.invoke.get("params"), params):
            raise RenderError("parameters")
        expected = [os.path.abspath(sys.executable), "-I", str(Path(__file__).resolve()), "invoke", "--manifest", str(manifest)]
        if cap.invoke.get("exec") != expected:
            raise RenderError("policy")
        adapters.substitute_argv(cap.invoke["exec"], params)
        provision = cap.provisioning
        if set(provision) - {"check", "ttlSeconds", "hosts", "workflows"}:
            raise RenderError("policy")
        hosts, workflows = provision.get("hosts"), provision.get("workflows")
        if not isinstance(hosts, dict) or not isinstance(workflows, dict) or not 1 <= len(hosts) <= 32 or not 1 <= len(workflows) <= 64:
            raise RenderError("policy")
        entry = validate_host(hosts[params["host"]])
        spec = workflows[params["workflow"]]
        graph = load_workflow(spec, json.loads(params["values"]))
        secrets = remote_audit.secret_values(candidate.section) + remote_audit.secret_values(provision)
        values = json.loads(params["values"])
        leaves = [v for k, v in params.items() if k != "values"] + list(values) + list(values.values())
        if any(remote_audit.redact_text(leaf, secrets) != leaf for leaf in leaves if isinstance(leaf, str)):
            raise RenderError("parameters")
        # Hash trust material as well as endpoints: rotation requires explicit reconciliation.
        canonical = json.dumps({"host": entry, "workflow": spec}, sort_keys=True).encode()
        canonical += _file(entry["knownHosts"]).read_bytes() + _file(entry["keys"]["tunnel"]).read_bytes()
        current = hashlib.sha256(canonical).hexdigest()
        if binding is not None and current != binding:
            raise RenderError("binding")
        return entry, spec, graph, current
    except (RenderError, remote_audit.Refused):
        raise
    except Exception:
        raise RenderError("policy") from None


def check_dependencies(graph, info):
    if not isinstance(info, dict):
        raise RenderError("dependencies")
    missing = []
    for node in graph.values():
        cls = node["class_type"]
        schema = info.get(cls)
        if not isinstance(schema, dict) or not isinstance(schema.get("input"), dict):
            missing.append(cls)
            continue
        required, optional = schema["input"].get("required", {}), schema["input"].get("optional", {})
        inputs = {**required, **optional}
        for key in set(required) - set(node["inputs"]):
            missing.append(cls + "." + key)
        for key, value in node["inputs"].items():
            declared = inputs.get(key)
            if not isinstance(declared, list) or not declared:
                missing.append(cls + "." + key)
            elif isinstance(declared[0], list) and not isinstance(value, list) and value not in declared[0]:
                missing.append(cls + "." + key)
    if missing:
        raise RenderError("dependencies", missing)


def _context(report):
    ctx = getattr(report, "audit_context", None)
    if not isinstance(ctx, remote_audit.Context) or not UUID.fullmatch(ctx.task_id or ""):
        raise remote_audit.AuditError("context")
    return replace(ctx, skill=NAME)


def _audited(ctx, params, operation, effect, job_id=None):
    safe_failure = []
    def call():
        try:
            return effect()
        except RenderError as exc:
            safe_failure.append(exc)
            if exc.refusal:
                raise remote_audit.Refused("invalid_params") from None
            raise
    try:
        return remote_audit.run(ctx, operation, call, host=params.get("host"), job_id=job_id)
    except remote_audit.AuditError as exc:
        # Preserve actionable engine-created diagnostics only after terminal ack.
        if safe_failure and (isinstance(exc, remote_audit.Refused) or str(exc) == str(remote_audit.AuditError("failed"))):
            raise safe_failure[0] from None
        raise


def run_task(payload, report_progress):
    ctx = _context(report_progress)
    descriptor = task_payload(payload)
    params = descriptor["params"]
    if descriptor["refusal"]:
        return remote_audit.run(ctx, "submit", lambda: {}, refusal=descriptor["refusal"])
    if params["operation"] == "cancel":
        return cancel_task(ctx, params, report_progress)
    state = {}
    def submit():
        entry, spec, graph, binding = authority(ctx.root, params)
        state.update(request_id=uuid.uuid4().hex, deadline=time.time() + spec["timeout"], binding=binding, phase="prepared")
        report_progress(recovery=state)
        with Tunnel(entry, timeout=min(5, spec["timeout"])) as tunnel:
            try:
                check_dependencies(graph, tunnel.json("/object_info"))
            except TransportError:
                if time.time() >= state["deadline"]:
                    raise RenderError("deadline") from None
                raise
            authority(ctx.root, params, binding)
            if time.time() >= state["deadline"]:
                raise RenderError("deadline")
            state["phase"] = "posting"
            report_progress(recovery=state)
            try:
                receipt = tunnel.json("/prompt", {"prompt": graph, "client_id": state["request_id"],
                    "extra_data": {"assistant_request_id": state["request_id"], "client_id": state["request_id"]}})
            except TransportError:
                # POST may have been accepted. Never POST again, even with no receipt.
                return {"state": "unknown"}
            prompt_id = receipt.get("prompt_id") if isinstance(receipt, dict) else None
            if not IDENT(prompt_id):
                return {"state": "unknown"}
            state["phase"] = "submitted"
            report_progress(external_job_id=prompt_id, recovery=state)
            return {"state": "queued", "id": prompt_id}
    _audited(ctx, params, "submit", submit)
    return Deferred()


def _owned(item, request_id, prompt_id=None):
    return (isinstance(item, list) and len(item) >= 5 and IDENT(item[1])
            and (prompt_id is None or item[1] == prompt_id) and isinstance(item[3], dict)
            and item[3].get("assistant_request_id") == request_id and item[3].get("client_id") == request_id)


def snapshot(tunnel, state, prompt_id):
    if prompt_id is not None and not IDENT(prompt_id):
        raise RenderError("ownership")
    queues, history = tunnel.json("/queue"), tunnel.json("/history?max_items=256")
    if not isinstance(queues, dict) or not isinstance(history, dict) or len(history) > 256:
        raise RenderError("ownership")
    if prompt_id is not None:
        # Recent history remains useful for duplicate ownership detection, but
        # a persisted backend ID must be inspected even outside that window.
        exact = tunnel.json("/history/" + prompt_id)
        if not isinstance(exact, dict) or set(exact) - {prompt_id}:
            raise RenderError("ownership")
        history.pop(prompt_id, None)
        history.update(exact)
    matches = {}
    for field, stage in (("queue_running", "running"), ("queue_pending", "pending")):
        items = queues.get(field)
        if not isinstance(items, list) or len(items) > 256:
            raise RenderError("ownership")
        for item in items:
            if _owned(item, state["request_id"]):
                matches.setdefault(item[1], (stage, item, None))
    for identifier, result in history.items():
        item = result.get("prompt") if isinstance(result, dict) else None
        if _owned(item, state["request_id"]) and identifier == item[1]:
            matches[identifier] = ("history", item, result)
    if len(matches) != 1 or (prompt_id is not None and prompt_id not in matches):
        return None
    return next(iter(matches.values()))


def _safe_delete(tunnel, state, prompt_id):
    match = snapshot(tunnel, state, prompt_id)
    if match is None:
        return "unknown"
    if match[0] != "pending":
        return "cancelling" if match[0] == "running" else "unknown"
    # Upstream returns an empty 200; the receipt alone is NOT cancellation proof.
    tunnel.request("/queue", {"delete": [prompt_id]}, limit=16384)
    after = snapshot(tunnel, state, prompt_id)
    if after is None:
        # An empty native receipt plus absence cannot distinguish deletion from
        # fast completion/history eviction. Never invent cancellation evidence.
        return "unknown"
    return "cancelling" if after[0] in {"pending", "running"} else "unknown"


def cancel_task(ctx, params, report):
    from assistant import tasks
    target = tasks.get_task(ctx.root, params["task_id"])
    def cancel():
        authority(ctx.root, params)
        if not target or target["kind"] != KIND or target["state"] not in {"started", "progress"}:
            raise RenderError("ownership")
        target_params = task_payload(target["payload"])["params"]
        if any(target_params.get(k) != params[k] for k in ("host", "workflow")):
            raise RenderError("ownership")
        state = recovery(target["recovery"])
        entry, _, _, _ = authority(ctx.root, target_params, state["binding"])
        with Tunnel(entry) as tunnel:
            match = snapshot(tunnel, state, target["external_job_id"])
            if match is None:
                return {"state": "unknown"}
            prompt_id = match[1][1]
            authority(ctx.root, target_params, state["binding"])
            result = _safe_delete(tunnel, state, prompt_id)
        if result == "cancelled":
            report.cancel_owned(target["id"], {**state, "phase": "cancelled"}, prompt_id)
        return {"id": prompt_id, "state": result}
    return {"result": _audited(ctx, params, "cancel", cancel)}


def _publish(tunnel, ctx, params, state, spec, result):
    from assistant import artifacts
    output = spec["output"]
    try:
        choice = result["outputs"][output["node"]][output["field"]][output["index"]]
        filename, subfolder, kind = choice["filename"], choice["subfolder"], choice["type"]
        if (not isinstance(filename, str) or not re.fullmatch(r"[A-Za-z0-9_. -]{1,200}", filename)
                or filename in {".", ".."} or not filename.lower().endswith(".png")
                or not isinstance(subfolder, str) or len(subfolder) > 256 or subfolder.startswith("/")
                or any(p in {".", ".."} for p in subfolder.split("/"))
                or not re.fullmatch(r"[A-Za-z0-9_ /.-]*", subfolder) or kind != "output"):
            raise ValueError()
    except (KeyError, IndexError, TypeError, ValueError):
        raise RenderError("artifact") from None
    relative = ctx.task_id + ".png"
    directory = Path(ctx.root) / artifacts.ARTIFACTS_DIR_REL
    # Reject symlink components before opening a pinned directory descriptor.
    for parent in (Path(ctx.root), Path(ctx.root) / ".claude", Path(ctx.root) / ".claude/assistant", directory):
        if parent.is_symlink():
            raise RenderError("artifact")
        parent.mkdir(exist_ok=True, mode=0o700)
    dirfd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = "." + ctx.task_id + "." + uuid.uuid4().hex + ".part"
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dirfd)
        with os.fdopen(descriptor, "wb") as sink:
            size, mime = tunnel.request("/view?" + urlencode({"filename": filename, "subfolder": subfolder, "type": kind}),
                limit=output["maxBytes"], timeout=max(.05, min(5, state["deadline"] - time.time())), sink=sink)
            sink.flush()
            os.fsync(sink.fileno())
        fd = os.open(temporary, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd)
        with os.fdopen(fd, "rb") as check:
            header = check.read(24)
            check.seek(-12, os.SEEK_END) if size >= 12 else None
            tail = check.read()
        if (mime != "image/png" or size < 45 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR"
                or tail != b"\x00\x00\x00\x00IEND\xaeB`\x82"):
            raise RenderError("artifact")
        authority(ctx.root, params, state["binding"])
        try:
            os.link(temporary, relative, src_dir_fd=dirfd, dst_dir_fd=dirfd, follow_symlinks=False)
        except FileExistsError:
            # Opening an existing FIFO for reading blocks before fstat can reject
            # it. Inspect the opened descriptor without waiting for a writer.
            try:
                existing = os.open(relative, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dirfd)
            except OSError:
                raise RenderError("artifact") from None
            with os.fdopen(existing, "rb") as handle:
                metadata = os.fstat(handle.fileno())
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size != size:
                    raise RenderError("artifact")
                checkfd = os.open(temporary, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd)
                with os.fdopen(checkfd, "rb") as new:
                    while True:
                        chunk = handle.read(65536)
                        if chunk != new.read(65536):
                            raise RenderError("artifact")
                        if not chunk:
                            break
        os.fsync(dirfd)
        return {"state": "completed", "bytes": size}
    finally:
        try:
            os.unlink(temporary, dir_fd=dirfd)
        except FileNotFoundError:
            pass
        os.close(dirfd)


def resolve_task(external_job_id, payload, *, audit_context, recovery_state, report_progress):
    ctx = replace(audit_context, skill=NAME)
    params = task_payload(payload)["params"]
    state = recovery(recovery_state)
    result = {}
    def inspect():
        entry, spec, graph, _ = authority(ctx.root, params, state["binding"])
        if state["phase"] == "cancelled":
            result.update(state="completed", result={"state": "cancelled"})
            return {"state": "cancelled"}
        # Expiration still permits one bounded inspection/safe pending deletion.
        with Tunnel(entry, timeout=3) as tunnel:
            match = snapshot(tunnel, state, external_job_id)
            if match is None:
                result["state"] = "not_found"
                return {"state": "unknown"}
            stage, item, history = match
            prompt_id = item[1]
            state["phase"] = "submitted"
            report_progress(external_job_id=prompt_id, recovery=state)
            if time.time() >= state["deadline"]:
                def expire():
                    authority(ctx.root, params, state["binding"])
                    return {"state": _safe_delete(tunnel, state, prompt_id)}
                _audited(ctx, params, "cancel", expire, prompt_id)
                result.update(state="failed", error=str(RenderError("deadline")))
                return {"state": "failed"}
            if stage != "history":
                for event in tunnel.progress(state["request_id"], prompt_id, set(graph)):
                    report_progress(event)
                result["state"] = "in_progress"
                return {"state": "running"}
            status = history.get("status", {})
            if status.get("status_str") == "error":
                oom = any(isinstance(m, list) and len(m) == 2 and isinstance(m[1], dict)
                          and m[1].get("exception_type") in {"torch.OutOfMemoryError", "OutOfMemoryError"}
                          for m in status.get("messages", []))
                result.update(state="failed", error=str(RenderError("out_of_memory" if oom else "execution_failed")))
                return {"state": "failed"}
            if status.get("completed") is not True or status.get("status_str") != "success":
                result["state"] = "not_found"
                return {"state": "unknown"}
            def transfer():
                authority(ctx.root, params, state["binding"])
                return _publish(tunnel, ctx, params, state, spec, history)
            receipt = _audited(ctx, params, "transfer", transfer, prompt_id)
            result.update(state="completed", artifact_path=ctx.task_id + ".png", result=receipt)
            return {"state": "completed"}
    _audited(ctx, params, "status", inspect, external_job_id)
    return result


def install(assistant_root):
    root = remote_control._protocol.checked_path(assistant_root, directory=True)
    entry = Path(__file__).resolve()
    destination = root / ".claude/skills" / NAME
    manifest = str(destination / "capability.yaml")
    interpreter = os.path.abspath(sys.executable)
    for binding, path in (("interpreter", interpreter), ("engine", str(entry)), ("manifest", manifest)):
        if "{" in path or "}" in path:
            raise ValueError(binding + " binding must be without braces")
    if destination.exists() or destination.is_symlink():
        raise ValueError("installation exists; review updates explicitly")
    for parent in (root / ".claude", root / ".claude/skills"):
        parent.mkdir(exist_ok=True, mode=0o700)
        remote_control._protocol.checked_path(parent, directory=True)
    template = entry.parents[2] / "skills" / NAME
    data = yaml.safe_load((template / "capability.yaml").read_text())
    prefix = [interpreter, "-I", str(entry)]
    data["provisioning"]["check"] = prefix + ["check", "--manifest", manifest]
    data["invoke"]["exec"] = prefix + ["invoke", "--manifest", manifest]
    with tempfile.TemporaryDirectory(prefix=".comfyui-", dir=destination.parent) as staging:
        stage = Path(staging) / NAME
        stage.mkdir(mode=0o700)
        (stage / "SKILL.md").write_text((template / "SKILL.md").read_text())
        (stage / "capability.yaml").write_text(yaml.safe_dump(data, sort_keys=False))
        if destination.exists() or destination.is_symlink():
            raise ValueError("installation appeared; refusing replacement")
        stage.rename(destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["install", "check", "invoke"])
    parser.add_argument("--assistant-root")
    parser.add_argument("--manifest")
    args = parser.parse_args()
    try:
        if os.name != "posix":
            raise ValueError("WSL/POSIX required")
        if args.command == "install":
            print(json.dumps({"installed": str(install(args.assistant_root)), "enabled": False}))
        elif args.command == "invoke":
            raise ValueError("requires engine-owned task context; invoke through assistant")
        else:
            data = yaml.safe_load(_file(args.manifest).read_text())
            if type(data.get("version")) is not int or data["version"] != 1:
                raise ValueError()
            provision = data["provisioning"]
            if not provision["hosts"] or not provision["workflows"]:
                raise ValueError()
            for entry in provision["hosts"].values():
                validate_host(entry)
            for spec in provision["workflows"].values():
                load_workflow(spec, {})
            print("local prerequisites verified; server grants and loopback bind require administrator verification")
        return 0
    except Exception:
        print("ComfyUI local provisioning refused; review installed policy and bindings", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
