"""Engine-owned command audit; no transport or additional host authority.

Only background workers call run(). The trace worker acknowledges committed
intent before the supplied operation can run. AST-081 must bind its own approved
transport and engine-constructed artifact destination to this same boundary.
"""
from dataclasses import dataclass, replace
import json
import os
import re
import uuid

from assistant import adapters, capability_index, discovery, observability

NAME = "remote-compute-control"
KIND = "remote-command"
OPERATIONS = frozenset({"inventory", "status", "logs", "cancel", "submit", "transfer"})
CONTROL_OPERATIONS = frozenset({"inventory", "status", "logs", "cancel"})
STATES = frozenset({"queued", "started", "progress", "running", "reserved", "done",
                    "completed", "failed", "lost", "cancelled", "cancelling", "unknown"})
TRANSFER_OUTCOMES = {"done": "success", "completed": "success", "failed": "failure",
                     "cancelled": "cancelled", "unknown": "unknown", "lost": "unknown",
                     **dict.fromkeys(("queued", "started", "progress", "running", "reserved",
                                      "pending", "cancelling"), "pending")}
REASONS = frozenset({"invalid_params", "disabled", "unavailable", "unprovisioned", "reload_failed",
                     "internal_exception", "queue_full", "invalid_response", "remote_refused",
                     "remote_failed", "timeout", "invalid_operation", "task_setup_failed"})
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
COMMAND_ID = re.compile(r"[a-f0-9]{32}\Z")
SENSITIVE_KEY = re.compile(r"password|passwd|token|secret|credential|authorization|api.?key|known.?hosts|^keys$", re.I)
# Consume whole unquoted tokens, including prefixes, without retrying each dash suffix.
ASSIGNMENT = re.compile(r'''(?<![A-Za-z0-9_])((?<!\\)(?:"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*')|(?<!-)[A-Za-z0-9_-]+)\s*[:=]\s*''')
ASSIGNMENT_VALUE = re.compile(r'''"(?:\\[\s\S]|[^"\\])*(?:"|$)|'(?:\\[\s\S]|[^'\\])*(?:'|$)|[^\s,;}]+''')
TEXT_LIMIT = 65536
JSON_DEPTH_LIMIT = 16
JSON_SCAN_LIMIT = 256


class AuditError(Exception):
    """Sanitized diagnostic safe for task/error persistence."""

    def __init__(self, code="failed"):
        messages = {
            "admission": "remote operation refused: audit admission unavailable; no effect attempted",
            "uncertain": "remote outcome uncertain: terminal audit unavailable; do not replay; reconcile durable task IDs",
            "timeout": "remote operation failed: timeout; inspect status before retry",
            "failed": "remote operation failed; inspect status before retry",
            "context": "remote operation refused: engine-owned audit context unavailable; use the task worker",
            "transfer_incomplete": "remote transfer incomplete: do not replay; reconcile durable task IDs",
            "transfer_unknown": "remote transfer outcome unknown: do not replay; reconcile durable task IDs",
            "transfer_cancelled": "remote transfer cancelled: do not replay; inspect durable task IDs",
        }
        super().__init__(messages.get(code, messages["failed"]))


class Refused(AuditError):
    def __init__(self, reason):
        self.reason = reason if reason in REASONS else "internal_exception"
        Exception.__init__(self, "remote operation refused: " + self.reason)


class RemoteFailure(AuditError):
    def __init__(self, reason="remote_failed"):
        self.reason = reason if reason in {"remote_failed", "invalid_response", "timeout"} else "remote_failed"
        super().__init__("timeout" if self.reason == "timeout" else "failed")


@dataclass(frozen=True)
class Context:
    # Constructed from the task worker's envelope, never from its payload.
    root: str
    traces_queue: object
    turn_id: str = None
    task_id: str = None
    timeout: float = 2.0
    command_id: str = None


def is_remote(name):
    return isinstance(name, str) and name.strip().lower() == NAME


def identifier(value):
    return isinstance(value, str) and bool(IDENTIFIER.fullmatch(value))


def prepare(params, refusal=None, command_id=None):
    """Freeze the narrow nonsecret task descriptor BEFORE any queue or SQL.

    Invalid/extra values cause refusal; they never become diagnostic strings.
    Keep independently valid operational identifiers for useful refusal evidence.
    """
    params = params if isinstance(params, dict) else {}
    safe = {}
    if identifier(params.get("host")):
        safe["host"] = params["host"]
    operation = params.get("operation")
    if isinstance(operation, str) and operation in CONTROL_OPERATIONS:
        safe["operation"] = operation
    job_id = params.get("job_id")
    if job_id == "" or identifier(job_id):
        safe["job_id"] = job_id
    valid = (set(params) == {"host", "operation", "job_id"} and len(safe) == 3
             and ((operation == "inventory" and job_id == "")
                  or (operation != "inventory" and bool(job_id))))
    reason = refusal if isinstance(refusal, str) and refusal in REASONS else None
    if not valid:
        reason = "invalid_params"
    return {"name": NAME, "params": safe, "refusal": reason,
            "command_id": command_id if isinstance(command_id, str) and COMMAND_ID.fullmatch(command_id)
            else uuid.uuid4().hex}


def task_payload(payload):
    payload = payload if isinstance(payload, dict) else {}
    return prepare(payload.get("params"), payload.get("refusal"), payload.get("command_id"))


def secret_values(value, sensitive=False, depth=0):
    """Known credentials supplement textual credential patterns, in memory only."""
    if depth > 16:
        return []
    if isinstance(value, dict):
        return [secret for key, child in value.items() for secret in
                secret_values(child, sensitive or bool(SENSITIVE_KEY.search(str(key))), depth + 1)]
    if isinstance(value, (list, tuple)):
        return [secret for child in value for secret in secret_values(child, sensitive, depth + 1)]
    return [value] if sensitive and isinstance(value, str) and value else []


def _redact_json_value(value, secrets, depth):
    if depth >= JSON_DEPTH_LIMIT:
        return "[redacted: JSON depth limit]"
    if isinstance(value, dict):
        # Classify the original decoded field name, even if sanitizing changes it.
        return {_redact_text(key, secrets, depth + 1): "[redacted]" if SENSITIVE_KEY.search(key) else
                _redact_json_value(child, secrets, depth + 1) for key, child in value.items()}
    if isinstance(value, list):
        return [_redact_json_value(child, secrets, depth + 1) for child in value]
    if isinstance(value, str):
        return _redact_text(value, secrets, depth)
    return value


def _redact_assignments(text, secrets, depth):
    """Decode JSON keys/values, with escape-aware fallback for mixed log syntax."""
    decoder = json.JSONDecoder()
    pieces, consumed = [], 0
    for match in ASSIGNMENT.finditer(text):
        if match.start() < consumed:
            continue
        key = match[1]
        if key.startswith('"'):
            try:
                key = json.loads(key)
            except ValueError:
                continue
        elif key.startswith("'"):
            key = key[1:-1]
        else:
            # Recover the first suffix eligible under the legacy matcher in one
            # pass; ordinary names like abc-keys must not become exact "keys".
            boundary = r"-" if match.start() and text[match.start() - 1] == "\\" else r"(?:^|-)"
            eligible = re.search(boundary + r"([A-Za-z_][A-Za-z0-9_-]*)", key)
            if eligible is None:
                continue
            key = eligible[1]
        sensitive = bool(SENSITIVE_KEY.search(key))
        start = match.end()
        if start == len(text):
            continue
        end = None
        replacement = '"[redacted]"'
        if text[start] in '{["':
            try:
                value, end = decoder.raw_decode(text, start)
                if not sensitive:
                    replacement = json.dumps(_redact_json_value(value, secrets, depth + 1))
            except (ValueError, RecursionError):
                # A malformed credential container has no safe delimiter.
                if text[start] in '{[':
                    end = len(text)
        if end is None:
            if not sensitive:
                continue
            value = ASSIGNMENT_VALUE.match(text, start)
            if value is None:
                continue
            end = value.end()
        pieces.extend((text[consumed:start], replacement))
        consumed = end
    pieces.append(text[consumed:])
    return "".join(pieces)


def _redact_embedded_json(text, secrets, depth):
    """Sanitize bounded JSON values in logs without dropping surrounding prose."""
    decoder = json.JSONDecoder()
    pieces, consumed, attempts = [], 0, 0
    for match in re.finditer(r'[\[{"]', text):
        start = match.start()
        if start < consumed:
            continue
        if attempts >= JSON_SCAN_LIMIT:
            pieces.extend((text[consumed:start], "[redacted: JSON scan limit]"))
            return "".join(pieces)
        attempts += 1
        try:
            value, end = decoder.raw_decode(text, start)
        except ValueError:
            continue
        except RecursionError:
            pieces.extend((text[consumed:start], "[redacted: JSON depth limit]"))
            return "".join(pieces)
        pieces.extend((text[consumed:start],
                       json.dumps(_redact_json_value(value, secrets, depth + 1))))
        consumed = end
    pieces.append(text[consumed:])
    return "".join(pieces)


def _redact_text(value, secrets, depth):
    if depth >= JSON_DEPTH_LIMIT:
        return "[redacted: JSON depth limit]"
    try:
        decoded = json.loads(value)
    except ValueError:
        pass
    except RecursionError:
        return "[redacted: JSON depth limit]"
    else:
        if isinstance(decoded, (dict, list, str)):
            return json.dumps(_redact_json_value(decoded, secrets, depth + 1))
    # Redact before truncating, including multi-line key blocks and quoted values.
    text = re.sub(r"-----BEGIN [^-]*PRIVATE KEY-----.*?(?:-----END [^-]*PRIVATE KEY-----|$)",
                  "[redacted]", value, flags=re.S)
    text = re.sub(r"(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9+/=_~.-]+", "[redacted]", text)
    text = _redact_assignments(text, secrets, depth)
    text = _redact_embedded_json(text, secrets, depth)
    text = re.sub(r"(?<![A-Za-z0-9+.-])([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@:]*:[^\s/@]*@",
                  r"\1[redacted]@", text)
    for secret in sorted(set(secrets), key=len, reverse=True):
        text = text.replace(secret, "[redacted]")
    return text


def redact_text(value, secrets=(), limit=TEXT_LIMIT):
    if not isinstance(value, str):
        return ""
    return _redact_text(value, secrets, 0)[:limit]


def project_result(operation, data, job_id=None, secrets=()):
    """Explicit output fields; private/unknown output cannot supply any path."""
    if not isinstance(data, dict):
        raise RemoteFailure("invalid_response")
    fields = {
        "inventory": {"capabilities"},
        "status": {"id", "job_id", "state", "pid", "exitcode"},
        "cancel": {"id", "job_id", "state", "pid", "exitcode", "cancelled"},
        "logs": {"id", "job_id", "text", "truncated"},
        "submit": {"id", "job_id", "state"},
        "transfer": {"bytes", "state"},
    }
    data = {key: value for key, value in data.items() if key in fields.get(operation, set())}
    state = data.get("state")
    if operation in {"status", "cancel", "submit"} and (not isinstance(state, str) or state not in STATES):
        raise RemoteFailure("invalid_response")
    if operation == "transfer" and (not isinstance(state, str) or state not in TRANSFER_OUTCOMES):
        raise RemoteFailure("invalid_response")
    for key in ("id", "job_id"):
        if key in data and (not identifier(data[key]) or (identifier(job_id) and data[key] != job_id)):
            raise RemoteFailure("invalid_response")
    for key in ("pid", "exitcode", "bytes"):
        if key in data and data[key] is not None:
            value = data[key]
            if type(value) is not int or not -(2 ** 63) < value < 2 ** 63:
                raise RemoteFailure("invalid_response")
            if key in {"pid", "bytes"} and value < 0:
                raise RemoteFailure("invalid_response")
    if operation == "transfer" and type(data.get("bytes")) is not int:
        raise RemoteFailure("invalid_response")
    if operation == "logs" and not isinstance(data.get("text"), str):
        raise RemoteFailure("invalid_response")
    result = {}
    if operation != "inventory" and identifier(job_id):
        result["id"] = job_id
    elif identifier(data.get("id")):
        result["id"] = redact_text(data["id"], secrets, 64)
    if isinstance(state, str) and (state in STATES or operation == "transfer"):
        result["state"] = state
    for key in ("pid", "exitcode", "bytes"):
        value = data.get(key)
        if type(value) is int and -(2 ** 63) < value < 2 ** 63:
            result[key] = value
        elif key in data and value is None:
            result[key] = None
    for key in ("cancelled", "truncated"):
        if type(data.get(key)) is bool:
            result[key] = data[key]
    if operation == "logs" and isinstance(data.get("text"), str):
        result["text"] = redact_text(data["text"], secrets)
        result["truncated"] = bool(data.get("truncated")) or len(data["text"]) > TEXT_LIMIT
    if operation == "inventory":
        catalog = data.get("capabilities")
        if not isinstance(catalog, dict) or len(catalog) > 128:
            raise RemoteFailure("invalid_response")
        result["capabilities"] = {}
        for name, metadata in catalog.items():
            if not identifier(name) or not isinstance(metadata, dict):
                continue
            clean = {}
            for key in ("description", "version", "schemaVersion"):
                if isinstance(metadata.get(key), str):
                    clean[key] = redact_text(metadata[key], secrets, 2048)
            if type(metadata.get("active")) is bool:
                clean["active"] = metadata["active"]
            result["capabilities"][redact_text(name, secrets, 64)] = clean
    return result


def _event(context, command_id, operation, host, job_id, phase, status, reason=None):
    payload = {"command_id": command_id, "task_id": context.task_id, "operation": operation}
    if identifier(host):
        payload["host"] = host
    if identifier(job_id):
        payload["job_id"] = job_id
    if reason in REASONS:
        payload["reason"] = reason
    return {"kind": "remote.command." + phase, "session_id": os.path.realpath(context.root),
            "turn_id": context.turn_id, "span_id": command_id,
            "parent_span_id": context.task_id or context.turn_id, "skill": NAME,
            "modality": "text", "status": status, "payload": payload}


def record_refusal(context, descriptor, reason):
    """Best-effort evidence when local admission fails before an executor runs."""
    descriptor = task_payload(descriptor)
    params = descriptor["params"]
    observability.emit(context.traces_queue, context.root, _event(
        context, descriptor["command_id"], params.get("operation", "invalid"),
        params.get("host"), params.get("job_id"), "outcome", "refused", reason))


def run(context, operation, effect, *, host=None, job_id=None, refusal=None, secrets=()):
    """Audit one managed operation, with no retry and no transport assumptions.

    The callback must persist new external job IDs through its engine-owned
    progress reporter before returning. A crash or failed terminal ack must be
    reconciled from tasks.sqlite, never from the continued presence of traces.
    """
    if not isinstance(context, Context):
        raise AuditError("context")
    command_id = context.command_id or uuid.uuid4().hex
    if not isinstance(operation, str) or operation not in OPERATIONS:
        operation, refusal = "invalid", "invalid_operation"
    intent = _event(context, command_id, operation, host, job_id, "intent", "intent")
    try:
        observability.emit_ack(context.traces_queue, context.root, intent, timeout=context.timeout)
    except observability.AuditWriteError:
        raise AuditError("admission") from None

    failure = None
    reason = None
    result = None
    try:
        if refusal:
            raise Refused(refusal)
        result = project_result(operation, effect(), job_id, secrets)
        status = "success"
        if operation == "cancel":
            status = {"cancelled": "cancelled", "cancelling": "pending"}.get(result.get("state"), "unknown")
        elif operation == "transfer":
            status = TRANSFER_OUTCOMES[result["state"]]
            if status != "success":
                reason = "remote_failed" if status == "failure" else None
                failure = AuditError({"pending": "transfer_incomplete", "unknown": "transfer_unknown",
                                      "cancelled": "transfer_cancelled"}.get(status, "failed"))
    except (Refused, capability_index.CapabilityDisabledError, adapters.ParamValidationError) as exc:
        reason = exc.reason if isinstance(exc, Refused) else (
            "disabled" if isinstance(exc, capability_index.CapabilityDisabledError) else "invalid_params")
        status, failure = "refused", Refused(reason)
    except Exception as exc:
        reason = (exc.reason if isinstance(exc, RemoteFailure) else
                  "timeout" if isinstance(exc, adapters.Timeout) else "remote_failed")
        status = "unknown" if operation == "cancel" else "failure"
        failure = AuditError("timeout" if reason == "timeout" else "failed")
    outcome = _event(context, command_id, operation, host, job_id, "outcome", status, reason)
    try:
        observability.emit_ack(context.traces_queue, context.root, outcome, timeout=context.timeout)
    except observability.AuditWriteError:
        raise AuditError("uncertain") from None
    if failure is not None:
        raise failure from None
    return result


def _invoke(context, params, secrets):
    classification = discovery.classify_repo(context.root)
    if classification.kind != "candidate":
        raise Refused("unavailable")
    config = classification.section
    skill_dir = os.path.join(context.root, ".claude", "skills", NAME)
    capability = capability_index.load_capability(skill_dir)
    if isinstance(capability, capability_index.CapabilityError):
        raise Refused("reload_failed")
    secrets.extend(secret_values(config))
    secrets.extend(secret_values(capability.provisioning))
    result = capability_index.invoke_capability(NAME, capability, params, config,
                                               skill_dir=skill_dir, timeout=30)
    if result.returncode != 0:
        if result.returncode == 2 and params["operation"] != "cancel":
            raise Refused("remote_refused")
        raise RemoteFailure("remote_failed")
    try:
        if len(result.stdout) > 131072:
            raise ValueError()
        response = json.loads(result.stdout)
        if (not isinstance(response, dict) or set(response) != {"version", "ok", "operation", "data"}
                or type(response["version"]) is not int or response["version"] != 1
                or response["ok"] is not True or response["operation"] != params["operation"]):
            raise ValueError()
        return response["data"]
    except (ValueError, TypeError, RecursionError):
        raise RemoteFailure("invalid_response") from None


def run_task(payload, report_progress):
    """Worker executor: reload authority; never deserialize config from a task."""
    context = getattr(report_progress, "audit_context", None)
    if not isinstance(context, Context):
        raise AuditError("context")
    descriptor = task_payload(payload)
    context = replace(context, command_id=descriptor["command_id"])
    params = descriptor["params"]
    secrets = []
    job_id = params.get("job_id")
    if identifier(job_id) and not descriptor["refusal"]:
        report_progress({"state": "started"}, external_job_id=job_id)
    result = run(context, params.get("operation"), lambda: _invoke(context, params, secrets),
                 host=params.get("host"), job_id=job_id, refusal=descriptor["refusal"], secrets=secrets)
    return {"result": result}


def resolve_task(external_job_id, payload, *, audit_context):
    """Re-poll status after restart; never repeat the original operation."""
    descriptor = task_payload(payload)
    params = descriptor["params"]
    params.update(operation="status", job_id=external_job_id)
    checked = prepare(params)
    secrets = []
    result = run(audit_context, "status", lambda: _invoke(audit_context, checked["params"], secrets),
                 host=params.get("host"), job_id=external_job_id, refusal=checked["refusal"], secrets=secrets)
    state = result.get("state")
    if state in {"running", "reserved", "cancelling", "queued", "started", "progress", "unknown"}:
        return {"state": "in_progress"}
    if state in {"done", "completed", "cancelled"}:
        return {"state": "completed", "result": result}
    if state == "failed":
        return {"state": "failed", "error": "remote job reported failure"}
    return {"state": "not_found"}
