#!/usr/bin/env bash
# identity.sh — resolve per-role git author identities from .claude/project.json.
#   identity.sh                # all roles
#   identity.sh <role>         # one role (dev|reviewer|orchestrator or any configured key)
#   identity.sh --check        # preflight mode: one ok/WARN line, always exit 0
# Templates in delegation.identities.<role>.{name,email}:
#   {name}   -> git config user.name
#   {local}  -> git config user.email local part      (before the last @)
#   {domain} -> git config user.email domain part     (after the last @)
# Values without placeholders are used literally. Defaults are ON for
# dev/reviewer/orchestrator; a role set to null — or delegation.identities
# set to false — means OFF: that role commits as the human.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONFIG="${PROJECT_CONFIG:-$ROOT/.claude/project.json}"

python3 - "$CONFIG" "${1:-}" "$(git config user.name 2>/dev/null || true)" "$(git config user.email 2>/dev/null || true)" <<'PY'
import json, os, sys

cfg_path, arg, gitname, gitemail = sys.argv[1:5]
check = arg == "--check"
role_filter = "" if check else arg

DEFAULTS = {
    "dev":          {"name": "Dev Agent - {name}",          "email": "{local}+dev_agent@{domain}"},
    "reviewer":     {"name": "Reviewer Agent - {name}",     "email": "{local}+reviewer_agent@{domain}"},
    "orchestrator": {"name": "Orchestrator Agent - {name}", "email": "{local}+orchestrator_agent@{domain}"},
}

configured = {}
if os.path.exists(cfg_path):
    try:
        configured = json.load(open(cfg_path)).get("delegation", {}).get("identities", {})
    except Exception as e:  # noqa: BLE001
        print(f"IDENTITY WARN: cannot parse {cfg_path} ({e}) — using built-in defaults")

if configured is False:
    print("identities: OFF for all roles (delegation.identities=false) — every role commits as the human")
    sys.exit(0)
if not isinstance(configured, dict):
    configured = {}

roles = dict(DEFAULTS)
for k, v in configured.items():
    roles[k] = v  # may be None (explicit opt-out) or {name,email} overriding the default

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

wanted = [role_filter] if role_filter else sorted(roles)
if role_filter and role_filter not in roles:
    print(f"ERROR: unknown role '{role_filter}' (known: {', '.join(sorted(roles))})", file=sys.stderr)
    sys.exit(1)

warns, ok = [], 0
for r in wanted:
    spec = roles[r]
    if spec is None:
        if not check:
            print(f"role: {r}\nOFF (identities.{r} is null — commits as the human)\n")
        continue
    name_t = spec.get("name") or DEFAULTS.get(r, {}).get("name") or "{name}"
    email_t = spec.get("email") or DEFAULTS.get(r, {}).get("email") or "{local}@{domain}"
    name, err_n = resolve(name_t)
    email, err_e = resolve(email_t)
    if err_n or err_e:
        warns.append(f"{r}: {err_n or err_e}")
        if not check:
            print(f"role: {r}\nUNRESOLVED ({err_n or err_e}) — commits will fall back to the human identity\n")
        continue
    ok += 1
    if not check:
        print(f"role: {r}\nname: {name}\nemail: {email}\nflags: -c user.name={shellquote(name)} -c user.email={shellquote(email)}\n")

if check:
    if warns:
        print("IDENTITY WARN: " + "; ".join(warns) + " — set git config user.name/user.email (agent commits fall back to the human default)")
    else:
        print(f"identities ok: {ok} role(s) resolvable")
sys.exit(0 if check or not role_filter else (0 if ok or roles.get(role_filter) is None else 1))
PY
