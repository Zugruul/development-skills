"""capability.yaml schema + version negotiation (SPEC-ASSISTANT.md §11.1, §11.6, AST-060).

Per §11.1 a skill directory may carry a capability.yaml shaped
`{version, provisioning: {check, ttlSeconds}, permissions, invoke}`. Per
§11.6 `version` is checked against the engine's supported range and an
out-of-range (or otherwise malformed) capability.yaml is
unavailable-with-reason -- it is NEVER best-effort executed. This module
validates STRUCTURE + version only: it does not run `provisioning.check`
(AST-062), does not execute `invoke` (AST-063/AST-064), and does not compile
the per-turn roster (AST-061) -- those are later E6 tasks layered on top of
the `Capability`/`CapabilityError` values this module returns.

Library:
    SUPPORTED_VERSION_RANGE -- (lo, hi) inclusive `version` range the engine
        currently accepts. v1 ships exactly one supported version (1, 1);
        the range shape is future-proofing for §11.6's "supported range"
        wording, not present multi-version support.

    validate_capability(capability, where="capability.yaml") -> list[str]
        Structural validation of one parsed capability.yaml mapping.
        Returns a list of path-precise error strings (empty list == valid).
        Never raises on a malformed mapping -- matches
        `assistant.config.validate_assistant`'s check/record/continue style
        so callers can extend errs in place. Does NOT check `version`
        against SUPPORTED_VERSION_RANGE -- that is load_capability's job,
        since an out-of-range version is a distinct failure reason
        (unsupported, not malformed) per §11.6.

    Capability(version, provisioning, permissions, invoke) -- namedtuple,
        a structurally valid, version-supported capability.yaml.

    CapabilityError(reason) -- namedtuple, the "unavailable-with-reason"
        sentinel §11.6 requires: a human-readable reason string, nothing
        else. Never raised -- always returned.

    load_capability(skill_dir) -> Capability | CapabilityError
        Reads `<skill_dir>/capability.yaml`, validates its structure, then
        checks `version` against SUPPORTED_VERSION_RANGE. Any failure
        (unreadable file, unparseable YAML, malformed structure,
        out-of-range version) returns a CapabilityError -- this function
        never raises and never attempts to execute anything the capability
        declares.
"""
import collections
import os

SUPPORTED_VERSION_RANGE = (1, 1)

_TOP_LEVEL_KEYS = {"version", "provisioning", "permissions", "invoke"}

Capability = collections.namedtuple("Capability", ["version", "provisioning", "permissions", "invoke"])
CapabilityError = collections.namedtuple("CapabilityError", ["reason"])


def _need(obj, key, typ, where, errs):
    if key not in obj:
        errs.append(f"{where}: missing required key '{key}'")
        return None
    val = obj[key]
    if typ and not isinstance(val, typ):
        errs.append(f"{where}.{key}: expected {typ.__name__}, got {type(val).__name__}")
        return None
    return val


def _check_argv(argv, where, errs):
    if not isinstance(argv, list) or not argv:
        errs.append(f"{where}: must be a non-empty argv array")
        return
    for i, arg in enumerate(argv):
        if not isinstance(arg, str):
            errs.append(f"{where}[{i}]: must be a string (got {type(arg).__name__})")


def _check_provisioning(prov, where, errs):
    check = _need(prov, "check", list, where, errs)
    if check is not None:
        _check_argv(check, f"{where}.check", errs)
    ttl = _need(prov, "ttlSeconds", int, where, errs)
    if ttl is not None and isinstance(ttl, bool):
        errs.append(f"{where}.ttlSeconds: expected int, got bool")


def _check_permissions(perms, where, errs):
    if not isinstance(perms, list):
        errs.append(f"{where}: must be a list")
        return
    for i, p in enumerate(perms):
        if not isinstance(p, str):
            errs.append(f"{where}[{i}]: must be a string (got {type(p).__name__})")


def _check_invoke(invoke, where, errs):
    has_exec = "exec" in invoke
    has_mcp = "mcp" in invoke
    if not has_exec and not has_mcp:
        errs.append(f"{where}: must have one of 'exec' or 'mcp' (§11.5, §11.7)")
        return
    if has_exec and has_mcp:
        errs.append(f"{where}: must have exactly one of 'exec' or 'mcp', got both")
        return
    if has_exec:
        _check_argv(invoke["exec"], f"{where}.exec", errs)
    else:
        if not isinstance(invoke["mcp"], dict):
            errs.append(f"{where}.mcp: must be a mapping")


def validate_capability(capability, where="capability.yaml"):
    errs = []
    if not isinstance(capability, dict):
        errs.append(f"{where}: must be a mapping")
        return errs

    for k in capability:
        if k not in _TOP_LEVEL_KEYS:
            errs.append(f"{where}.{k}: unknown key (allowed: {sorted(_TOP_LEVEL_KEYS)})")

    if "version" in capability:
        v = capability["version"]
        if isinstance(v, bool) or not isinstance(v, int):
            errs.append(f"{where}.version: must be an integer (got {v!r})")
    else:
        errs.append(f"{where}: missing required key 'version'")

    prov = _need(capability, "provisioning", dict, where, errs)
    if prov is not None:
        _check_provisioning(prov, f"{where}.provisioning", errs)

    perms = _need(capability, "permissions", list, where, errs)
    if perms is not None:
        _check_permissions(perms, f"{where}.permissions", errs)

    invoke = _need(capability, "invoke", dict, where, errs)
    if invoke is not None:
        _check_invoke(invoke, f"{where}.invoke", errs)

    return errs


def load_capability(skill_dir):
    path = os.path.join(skill_dir, "capability.yaml")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        return CapabilityError(f"cannot read {path}: {e}")

    import yaml  # local import: mirrors config.py's lazy PyYAML import

    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as e:
        return CapabilityError(f"cannot parse {path}: {e}")

    errs = validate_capability(data, where="capability.yaml")
    if errs:
        return CapabilityError("; ".join(errs))

    version = data["version"]
    lo, hi = SUPPORTED_VERSION_RANGE
    if not (lo <= version <= hi):
        return CapabilityError(
            f"capability.yaml version {version} is not supported "
            f"(engine supports {lo}-{hi}); unavailable, never executed"
        )

    return Capability(
        version=version,
        provisioning=data["provisioning"],
        permissions=data["permissions"],
        invoke=data["invoke"],
    )
