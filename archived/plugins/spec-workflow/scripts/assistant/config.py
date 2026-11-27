"""`assistant:` project.yaml section schema (SPEC-ASSISTANT.md §6, §6.1, §6.5).

Per §6.1 the `assistant:` section is the SOLE authority for assistant
identity/enabled state -- there is no cross-validation against the
`.neural-network` marker here (see assistant.marker, which is deliberately
permissive and carries no assistant flags). This module validates STRUCTURE
only: it never resolves binaries or auth (that is AST-006 preflight) and
never allowlists `llm.model` (per §6.5 the model string is passed verbatim
to the adapter).

Library:
    validate_assistant(assistant, where="assistant") -> list[str]
        Structural + cross-field validation of one `assistant:` section
        value. Returns a list of path-precise error strings (empty list ==
        valid). Never raises on a malformed section -- every check here is
        defensive (check, record, continue), matching validate-config.py's
        `need()` helper style so callers can extend errs in place.
"""

# provider -> the capability its runtime requires enabled (§6.5).
PROVIDER_CAPABILITY = {
    "openai": "codex",
    "claude": "claude-code",
}

_TOP_LEVEL_KEYS = {"version", "enabled", "names", "systemPrompt", "llm", "capabilities", "observability"}


def _need(obj, key, typ, where, errs):
    if key not in obj:
        errs.append(f"{where}: missing required key '{key}'")
        return None
    val = obj[key]
    if typ and not isinstance(val, typ):
        errs.append(f"{where}.{key}: expected {typ.__name__}, got {type(val).__name__}")
        return None
    return val


def _check_names(names, where, errs):
    if not names:
        errs.append(f"{where}.names: must be a non-empty list")
        return
    for i, n in enumerate(names):
        if isinstance(n, str) and n.strip():
            continue
        if i == 0:
            errs.append(f"{where}.names: first entry (the main name) must be a non-empty string")
        else:
            errs.append(f"{where}.names[{i}]: must be a non-empty string")


def _check_llm(llm, where, errs):
    provider = _need(llm, "provider", str, where, errs)
    if provider is not None and provider not in PROVIDER_CAPABILITY:
        errs.append(
            f"{where}.provider: {provider!r} is not a recognized provider "
            f"(valid: {', '.join(sorted(PROVIDER_CAPABILITY))})"
        )
    _need(llm, "model", str, where, errs)  # opaque string, passed verbatim per §6.5
    return provider


def _check_capabilities(caps, where, errs):
    """Returns {capability-name: bool(enabled)} for whatever validated cleanly."""
    cap_enabled = {}
    if not isinstance(caps, dict):
        errs.append(f"{where}: must be a mapping")
        return cap_enabled
    for name, entry in caps.items():
        cw = f"{where}.{name}"
        if not isinstance(entry, dict):
            errs.append(f"{cw}: must be a mapping")
            continue
        enabled = _need(entry, "enabled", bool, cw, errs)
        cap_enabled[name] = bool(enabled) if isinstance(enabled, bool) else False
    return cap_enabled


def _check_retention_backend(entry, where, errs):
    """One observability backend entry, e.g. observability.traces.sqlite (§10.3)."""
    if not isinstance(entry, dict):
        errs.append(f"{where}: must be a mapping")
        return
    if "enabled" in entry and not isinstance(entry["enabled"], bool):
        errs.append(f"{where}.enabled: must be a boolean (got {entry['enabled']!r})")
    for key in ("retainDays", "maxMB"):  # 0 = unlimited, defaults 30/500 (§10.3)
        if key not in entry:
            continue
        val = entry[key]
        if isinstance(val, bool) or not isinstance(val, int):
            errs.append(f"{where}.{key}: must be an integer >= 0 (0 = unlimited) (got {val!r})")
        elif val < 0:
            errs.append(f"{where}.{key}: must be >= 0 (0 = unlimited) (got {val})")
    if "host" in entry and not isinstance(entry["host"], str):
        errs.append(f"{where}.host: must be a string (got {entry['host']!r})")
    if "port" in entry and (isinstance(entry["port"], bool) or not isinstance(entry["port"], int)):
        errs.append(f"{where}.port: must be an integer (got {entry['port']!r})")


def _check_observability_group(group, where, errs):
    if group is None:
        return
    if not isinstance(group, dict):
        errs.append(f"{where}: must be a mapping")
        return
    for backend, entry in group.items():
        _check_retention_backend(entry, f"{where}.{backend}", errs)


def validate_assistant(assistant, where="assistant"):
    errs = []
    if not isinstance(assistant, dict):
        errs.append(f"{where}: must be a mapping")
        return errs

    for k in assistant:
        if k not in _TOP_LEVEL_KEYS:
            errs.append(f"{where}.{k}: unknown key (allowed: {sorted(_TOP_LEVEL_KEYS)})")

    if "version" in assistant:
        v = assistant["version"]
        if isinstance(v, bool) or not isinstance(v, int):
            errs.append(f"{where}.version: must be an integer (got {v!r})")

    if "enabled" in assistant and not isinstance(assistant["enabled"], bool):
        errs.append(f"{where}.enabled: must be a boolean (got {assistant['enabled']!r})")

    names = _need(assistant, "names", list, where, errs)
    if names is not None:
        _check_names(names, where, errs)

    sp = _need(assistant, "systemPrompt", str, where, errs)
    if sp is not None and not sp.strip():
        errs.append(f"{where}.systemPrompt: must be a non-empty string")

    llm = _need(assistant, "llm", dict, where, errs)
    provider = _check_llm(llm, f"{where}.llm", errs) if llm is not None else None

    caps = assistant.get("capabilities")
    cap_enabled = _check_capabilities(caps, f"{where}.capabilities", errs) if caps is not None else {}

    if provider in PROVIDER_CAPABILITY:
        needed_cap = PROVIDER_CAPABILITY[provider]
        if not cap_enabled.get(needed_cap):
            errs.append(
                f"{where}.llm.provider: {provider!r} requires capabilities.{needed_cap}.enabled: true "
                f"({where}.capabilities.{needed_cap} is absent or disabled)"
            )

    obs = assistant.get("observability")
    if obs is not None:
        if not isinstance(obs, dict):
            errs.append(f"{where}.observability: must be a mapping")
        else:
            for k in obs:
                if k not in ("metrics", "traces"):
                    errs.append(f"{where}.observability.{k}: unknown key (allowed: ['metrics', 'traces'])")
            _check_observability_group(obs.get("metrics"), f"{where}.observability.metrics", errs)
            _check_observability_group(obs.get("traces"), f"{where}.observability.traces", errs)

    return errs
