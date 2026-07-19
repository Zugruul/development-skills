"""Shared per-role identity resolution for identity.sh (normal + on-behalf modes).

One source of truth for the built-in role defaults, template resolution
({name}/{local}/{domain}), monorepo covers routing, and single-identity
resolution — so both identity.sh modes agree on who a role resolves to.
"""
import fnmatch

import config as C

DEFAULTS = {
    "dev":           {"name": "Dev Agent - {name}",          "email": "{local}+dev_agent@{domain}",          "models": ["claude-sonnet-5"]},
    "reviewer":      {"name": "Reviewer Agent - {name}",     "email": "{local}+reviewer_agent@{domain}",     "models": ["claude-sonnet-5", "claude-sonnet-5[1m]"]},
    "orchestrator":  {"name": "Orchestrator Agent - {name}", "email": "{local}+orchestrator_agent@{domain}"},
    "peer-reviewer": {"name": "Peer Reviewer (codex) - {name}", "email": "{local}+peer_reviewer@{domain}"},
}


def resolve_template(template, gitname, gitemail):
    """Fill {name}/{local}/{domain} -> (value, error). error if a needed git field is empty."""
    local, _, domain = gitemail.rpartition("@")
    for p in ("{name}", "{local}", "{domain}"):
        if p in template and not {"{name}": gitname, "{local}": local, "{domain}": domain}[p]:
            src = "user.name" if p == "{name}" else "user.email"
            return None, f"template needs {p} but git config {src} is empty"
    return template.replace("{name}", gitname).replace("{local}", local).replace("{domain}", domain), None


def shellquote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'


CODEX_CAPABILITIES = ("fast", "balanced", "deep-review", "large-context")


def normalize_models(spec):
    """One identity's `models` value (None | flat Claude list | {claude, codex.capability}
    object) -> (claude_models: list[str], codex_capability: str|None, error: str|None).

    Standalone and not yet called from resolve_role()/identity.sh -- CDX-021 wires
    it into the live briefing path. See docs/design/cdx-E2.md CDX-020 for the
    full contract (including why a bad capability is a sentinel error, never a
    silent default).
    """
    if spec is None:
        return [], None, None
    if isinstance(spec, list):
        return list(spec), None, None
    if isinstance(spec, dict):
        claude = spec.get("claude")
        claude = claude if isinstance(claude, list) else []
        cap = (spec.get("codex") or {}).get("capability")
        if cap is not None and cap not in CODEX_CAPABILITIES:
            return None, None, (
                f"unrecognized models.codex.capability {cap!r} (valid: {', '.join(CODEX_CAPABILITIES)})"
            )
        return claude, cap, None
    return [], None, None


def as_list(spec):
    """A role spec is one identity dict or a list of them -> always a list of dicts."""
    if isinstance(spec, list):
        return [x for x in spec if isinstance(x, dict)]
    return [spec] if isinstance(spec, dict) else []


def select(idents, path):
    """Covers globs decide when a path is given (fnmatch, ** crosses dirs);
    fallback = first entry without covers, else the first entry."""
    if path:
        for it in idents:
            if any(fnmatch.fnmatch(path, g) for g in (it.get("covers") or [])):
                return it
    for it in idents:
        if not it.get("covers"):
            return it
    return idents[0]


def merged_roles(root):
    """Built-in DEFAULTS overlaid with configured delegation.identities.
    Returns the merged dict, or False when identities is disabled for all roles."""
    try:
        cfg = C.load_config(root, warn=False) or {}
    except C.ConfigError:
        cfg = {}
    configured = cfg.get("delegation", {}).get("identities", {})
    if configured is False:
        return False
    if not isinstance(configured, dict):
        configured = {}
    roles = dict(DEFAULTS)
    for k, v in configured.items():
        roles[k] = v  # None (opt-out), a dict, or a list of dicts
    return roles


def resolve_role(roles, role, gitname, gitemail, path=""):
    """Resolve ONE role to a single identity.
    Returns (info, status, error): status in {ok, off, unresolved, unknown, invalid};
    info = {'name', 'email', 'models', 'codexCapability'} when status == 'ok', else None."""
    if role not in roles:
        return None, "unknown", f"unknown role '{role}' (known: {', '.join(sorted(roles))})"
    spec = roles[role]
    idents = as_list(spec)
    if spec is None or not idents:
        return None, "off", None
    it = select(idents, path)
    dflt = DEFAULTS.get(role, {})
    name, en = resolve_template(it.get("name") or dflt.get("name") or "{name}", gitname, gitemail)
    email, ee = resolve_template(it.get("email") or dflt.get("email") or "{local}@{domain}", gitname, gitemail)
    if en or ee:
        return None, "unresolved", (en or ee)
    models_spec = it["models"] if "models" in it else dflt.get("models")
    claude_models, codex_capability, err = normalize_models(models_spec)
    if err:
        return None, "invalid", err
    return {"name": name, "email": email, "models": claude_models, "codexCapability": codex_capability}, "ok", None
