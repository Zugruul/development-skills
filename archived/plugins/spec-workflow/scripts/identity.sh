#!/usr/bin/env bash
# identity.sh — resolve per-role git author identities + allowed models from config.
#   identity.sh                  # all roles
#   identity.sh <role>           # one role (dev|reviewer|orchestrator|peer-reviewer or any configured key)
#   identity.sh <role> <path>    # resolve the covering identity for a changed path (monorepo routing)
#   identity.sh --check          # preflight mode: one ok/WARN line, always exit 0
#   identity.sh on-behalf <author-role> [--committer <role=orchestrator>] [--co <role>]...
#                                # recipe for a commit that credits ALL participating roles:
#                                #   author = who did the work · committer = who recorded it ·
#                                #   Co-authored-by trailers = every other contributing role
#                                # Prints three pieces, in PASTE ORDER: a `flags:`
#                                # line (global -c options, go BEFORE `commit`), a
#                                # `commit-flags:` line (--author=, goes AFTER
#                                # `commit`), and a `trailers:` block (message body).
# A role maps to ONE identity or an ARRAY of identities (delegation.identities.<role>).
# Identity fields: name, email (templates), models (allowed model ids), covers (path globs).
#   {name}   -> git config user.name
#   {local}  -> git config user.email local part      (before the last @)
#   {domain} -> git config user.email domain part     (after the last @)
# Values without placeholders are used literally. Defaults are ON for
# dev/reviewer/orchestrator/peer-reviewer; a role set to null — or
# delegation.identities set to false — means OFF: that role commits as the human.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GITNAME="$(git config user.name 2>/dev/null || true)"
GITEMAIL="$(git config user.email 2>/dev/null || true)"

if [[ "${1:-}" == "on-behalf" ]]; then
    shift
    author="${1:-}"; shift || true
    committer="orchestrator"; cos=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --committer) committer="${2:-}"; shift 2 || { echo "usage: identity.sh on-behalf <author-role> [--committer <role>] [--co <role>]..." >&2; exit 1; } ;;
            --co)        cos+=("${2:-}");    shift 2 || { echo "usage: identity.sh on-behalf <author-role> [--committer <role>] [--co <role>]..." >&2; exit 1; } ;;
            *) echo "ERROR: unexpected argument '$1'. usage: identity.sh on-behalf <author-role> [--committer <role>] [--co <role>]..." >&2; exit 1 ;;
        esac
    done
    [[ -n "$author" ]] || { echo "usage: identity.sh on-behalf <author-role> [--committer <role>] [--co <role>]..." >&2; exit 1; }
    python3 - "$ROOT" "$author" "$committer" "${cos[*]:-}" "$GITNAME" "$GITEMAIL" <<'PY'
import sys
import identity_lib as I

root, author, committer, co_csv, gitname, gitemail = sys.argv[1:7]
co_roles = [c for c in co_csv.split(" ") if c]

roles = I.merged_roles(root)
if roles is False:
    print("ERROR: delegation.identities is false (all roles OFF) — no agent identity to commit on behalf of; commit as the human.", file=sys.stderr)
    sys.exit(1)


def need(role):
    info, status, err = I.resolve_role(roles, role, gitname, gitemail)
    if status == "ok":
        return info
    reason = {"unknown": err,
              "off": f"role '{role}' is OFF (identities.{role} is null or disabled)",
              "unresolved": f"role '{role}' UNRESOLVED ({err})",
              "invalid": f"role '{role}' has an invalid models config ({err})"}[status]
    print(f"ERROR: cannot commit on behalf — {reason}.", file=sys.stderr)
    sys.exit(1)


auth = need(author)
comm = need(committer)

# Co-authored-by trailers: every contributing role, minus anyone already credited
# as author or committer (a duplicate trailer just adds a redundant GitHub avatar).
credited = {auth["email"].lower(), comm["email"].lower()}
trailers = []
for r in co_roles:
    info = need(r)
    key = info["email"].lower()
    if key in credited:
        continue
    credited.add(key)
    trailers.append(f"Co-authored-by: {info['name']} <{info['email']}>")


def sq(s):
    return I.shellquote(s)


print(f"on-behalf: author={author} committer={committer} co={','.join(co_roles) or '(none)'}")
# Two lines, not one: -c user.name/-c user.email are GLOBAL git options (belong
# BEFORE the `commit` subcommand); --author is a `git commit` option (belongs
# AFTER it). Printing them pre-joined once produced a recipe that failed
# verbatim in its own documented paste position ("unknown option: --author").
print(f"flags: -c user.name={sq(comm['name'])} -c user.email={sq(comm['email'])}")
print(f"commit-flags: --author={sq(auth['name'] + ' <' + auth['email'] + '>')}")
print("trailers:")
for t in trailers:
    print(t)
if not trailers:
    print("(none)")
PY
    exit $?
fi

host="claude"
if [[ "${1:-}" == "--host" ]]; then
    host="${2:-}"
    shift 2 || { echo "usage: identity.sh --host <claude|codex> [<role>] [<path>]" >&2; exit 1; }
fi

python3 - "$ROOT" "${1:-}" "${2:-}" "$GITNAME" "$GITEMAIL" "$host" <<'PY'
import sys

import identity_lib as I

root, arg, path_arg, gitname, gitemail, host = sys.argv[1:7]
check = arg == "--check"
role_filter = "" if check else arg
codex_host = host == "codex"

roles = I.merged_roles(root)
if roles is False:
    print("identities: OFF for all roles (delegation.identities=false) — every role commits as the human")
    sys.exit(0)


def render(role, ident):
    """Resolve one identity dict -> (lines, error, resolved_name)."""
    dflt = I.DEFAULTS.get(role, {})
    name, err_n = I.resolve_template(ident.get("name") or dflt.get("name") or "{name}", gitname, gitemail)
    email, err_e = I.resolve_template(ident.get("email") or dflt.get("email") or "{local}@{domain}", gitname, gitemail)
    if err_n or err_e:
        return None, (err_n or err_e), None
    models_spec = ident["models"] if "models" in ident else dflt.get("models")
    claude_models, codex_capability, models_err = I.normalize_models(models_spec)
    if models_err:
        return None, models_err, None
    lines = [
        f"name: {name}",
        f"email: {email}",
        f"flags: -c user.name={I.shellquote(name)} -c user.email={I.shellquote(email)}",
    ]
    if codex_host:
        lines.append("codex-capability: " + (codex_capability or "(unset — host default)"))
    elif claude_models:
        lines.append("models: " + ", ".join(claude_models))
    return lines, None, name


wanted = [role_filter] if role_filter else sorted(roles)
if role_filter and role_filter not in roles:
    print(f"ERROR: unknown role '{role_filter}' (known: {', '.join(sorted(roles))})", file=sys.stderr)
    sys.exit(1)

warns, ok = [], 0
for r in wanted:
    idents = I.as_list(roles[r])
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

    chosen = I.select(idents, path_arg)
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
