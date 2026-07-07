#!/usr/bin/env bash
# identity.sh — resolve per-role git author identities + allowed models from config.
#   identity.sh                  # all roles
#   identity.sh <role>           # one role (dev|reviewer|orchestrator or any configured key)
#   identity.sh <role> <path>    # resolve the covering identity for a changed path (monorepo routing)
#   identity.sh --check          # preflight mode: one ok/WARN line, always exit 0
# A role maps to ONE identity or an ARRAY of identities (delegation.identities.<role>).
# Identity fields: name, email (templates), models (allowed model ids), covers (path globs).
#   {name}   -> git config user.name
#   {local}  -> git config user.email local part      (before the last @)
#   {domain} -> git config user.email domain part     (after the last @)
# Values without placeholders are used literally. Defaults are ON for
# dev/reviewer/orchestrator; a role set to null — or delegation.identities
# set to false — means OFF: that role commits as the human.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

PYTHONPATH="$HERE" python3 - "$ROOT" "${1:-}" "${2:-}" "$(git config user.name 2>/dev/null || true)" "$(git config user.email 2>/dev/null || true)" <<'PY'
import fnmatch
import sys

import config as C

root, arg, path_arg, gitname, gitemail = sys.argv[1:6]
check = arg == "--check"
role_filter = "" if check else arg

DEFAULTS = {
    "dev":          {"name": "Dev Agent - {name}",          "email": "{local}+dev_agent@{domain}",          "models": ["claude-sonnet-5"]},
    "reviewer":     {"name": "Reviewer Agent - {name}",     "email": "{local}+reviewer_agent@{domain}",     "models": ["claude-sonnet-5", "claude-sonnet-5[1m]"]},
    "orchestrator": {"name": "Orchestrator Agent - {name}", "email": "{local}+orchestrator_agent@{domain}"},
}

try:
    cfg = C.load_config(root, warn=False) or {}
except C.ConfigError as e:
    print(f"IDENTITY WARN: cannot parse config ({e}) — using built-in defaults")
    cfg = {}

configured = cfg.get("delegation", {}).get("identities", {})
if configured is False:
    print("identities: OFF for all roles (delegation.identities=false) — every role commits as the human")
    sys.exit(0)
if not isinstance(configured, dict):
    configured = {}

roles = dict(DEFAULTS)
for k, v in configured.items():
    roles[k] = v  # None (opt-out), a dict, or a list of dicts

local, _, domain = gitemail.rpartition("@")


def resolve(template):
    needed = [p for p in ("{name}", "{local}", "{domain}") if p in template]
    for p in needed:
        val = {"{name}": gitname, "{local}": local, "{domain}": domain}[p]
        if not val:
            src = "user.name" if p == "{name}" else "user.email"
            return None, f"template needs {p} but git config {src} is empty"
    return template.replace("{name}", gitname).replace("{local}", local).replace("{domain}", domain), None


def shellquote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'


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


def render(role, ident):
    """Resolve one identity dict -> (lines, error, resolved_name)."""
    dflt = DEFAULTS.get(role, {})
    name_t = ident.get("name") or dflt.get("name") or "{name}"
    email_t = ident.get("email") or dflt.get("email") or "{local}@{domain}"
    name, err_n = resolve(name_t)
    email, err_e = resolve(email_t)
    if err_n or err_e:
        return None, (err_n or err_e), None
    models = ident.get("models") or dflt.get("models") or []
    lines = [
        f"name: {name}",
        f"email: {email}",
        f"flags: -c user.name={shellquote(name)} -c user.email={shellquote(email)}",
    ]
    if models:
        lines.append("models: " + ", ".join(models))
    return lines, None, name


wanted = [role_filter] if role_filter else sorted(roles)
if role_filter and role_filter not in roles:
    print(f"ERROR: unknown role '{role_filter}' (known: {', '.join(sorted(roles))})", file=sys.stderr)
    sys.exit(1)

warns, ok = [], 0
for r in wanted:
    idents = as_list(roles[r])
    if roles[r] is None:
        if not check:
            print(f"role: {r}\nOFF (identities.{r} is null — commits as the human)\n")
        continue
    if not idents:
        continue

    # No path + several identities: list them all (the orchestrator picks among them).
    if len(idents) > 1 and not path_arg:
        any_ok = False
        if not check:
            print(f"role: {r}")
        for i, it in enumerate(idents):
            lines, err, name = render(r, it)
            if err:
                warns.append(f"{r}[{i}]: {err}")
                continue
            any_ok = True
            if not check:
                covers = it.get("covers")
                cov = f"covers: {', '.join(covers)}" if covers else "covers: (fallback — no globs)"
                print(f"id: {name}\n" + "\n".join(lines) + f"\n{cov}\n")
        if any_ok:
            ok += 1
        continue

    chosen = select(idents, path_arg)
    lines, err, _ = render(r, chosen)
    if err:
        warns.append(f"{r}: {err}")
        if not check:
            print(f"role: {r}\nUNRESOLVED ({err}) — commits will fall back to the human identity\n")
        continue
    ok += 1
    if not check:
        print(f"role: {r}\n" + "\n".join(lines) + "\n")

if check:
    if warns:
        print("IDENTITY WARN: " + "; ".join(warns) + " — set git config user.name/user.email (agent commits fall back to the human default)")
    else:
        print(f"identities ok: {ok} role(s) resolvable")
sys.exit(0 if check or not role_filter else (0 if ok or roles.get(role_filter) is None else 1))
PY
