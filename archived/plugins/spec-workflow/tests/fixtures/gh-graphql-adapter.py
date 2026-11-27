#!/usr/bin/env python3
"""Test helper: answer the slim `gh api graphql` board read (#544) from a stub's
OWN `project item-list` answer, so the ~15 fake `gh` scripts keep testing the same
fixture data / failure modes after production moved off `gh project item-list`.

Used by a stub as:  "api graphql") exec python3 "$GH_GQL_ADAPTER" "$0" "$@" ;;

It invokes the stub's `project item-list` branch (page window via --limit), converts
the gh-shaped items back into GraphQL nodes, and prints what `gh api -i graphql`
would print. A stub failure becomes either a RATE_LIMIT payload (when its stderr
says "rate limit": exit 1 like gh) or a plain nonzero exit with the stub's stderr
(transport / masked errors), mirroring how real gh reports each.
"""
import json
import shutil
import subprocess
import sys

stub, args = sys.argv[1], sys.argv[3:]
if "/" not in stub:  # bash sets $0 to the bare name when found via PATH
    stub = shutil.which(stub) or stub
var = {}
for i, a in enumerate(args):
    if a in ("-f", "-F") and i + 1 < len(args) and "=" in args[i + 1]:
        k, _, v = args[i + 1].partition("=")
        var[k] = v
owner, number = var.get("owner", "@me"), var.get("number", "0")
if "fields(first" in var.get("query", ""):  # field-name resolution (#544): stubs model the default board
    nodes = [{"name": n} for n in ("Title", "Status", "Priority", "Estimate")]
    sys.stdout.write("HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 4000\n\n" + json.dumps(
        {"data": {"repositoryOwner": {"projectV2": {"fields": {"nodes": nodes}}}}}))
    sys.exit(0)
first = int(var.get("first", "100"))
after = var.get("after", "")
off = int(after[3:]) if after.startswith("cur") else 0

r = subprocess.run([stub, "project", "item-list", number, "--owner", owner, "--format", "json",
                    "--limit", str(off + first)], capture_output=True, text=True)
HEAD = "HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 4000\n\n"  # no Reset header: stubs model gh text, not headers
if r.returncode != 0:
    err = r.stderr.strip()
    if "rate limit" in err.lower():
        sys.stdout.write(HEAD.replace("4000", "0") + json.dumps(
            {"errors": [{"type": "RATE_LIMIT", "code": "graphql_rate_limit", "message": err}]}))
    sys.stderr.write(r.stderr)
    sys.exit(r.returncode or 1)

try:
    doc = json.loads(r.stdout)
except ValueError:
    sys.stdout.write(HEAD + r.stdout)  # unparseable stub output: let the reader fail closed
    sys.exit(0)
raw = doc.get("items") if isinstance(doc, dict) else None
if not isinstance(raw, list):
    nodes, total, more = None, 0, False
else:
    window = raw[off:off + first]
    more = len(raw) > off + first  # stubs return their whole fixture; the window is cut here
    total = doc.get("totalCount", len(raw)) if isinstance(doc, dict) else len(raw)
    nodes = []
    for it in window:
        if not isinstance(it, dict):
            nodes.append(None)
            continue
        c = it.get("content") if isinstance(it.get("content"), dict) else {}
        content = {"__typename": c.get("type", "Issue")}
        for key in ("number", "body", "url"):
            if key in c:
                content[key] = c[key]
        content["title"] = c.get("title", it.get("title", ""))
        if c.get("repository"):
            content["repository"] = {"nameWithOwner": c["repository"]}
        content["labels"] = {"nodes": [{"name": n} for n in it.get("labels", [])]}
        node = {"id": it.get("id"), "content": content}
        for key in ("status", "priority"):
            if key in it:
                node[key] = {"name": it[key]}
        if "estimate" in it:
            node["estimate"] = {"number": it["estimate"]}
        nodes.append(node)
items = {"totalCount": total, "pageInfo": {"hasNextPage": more, "endCursor": "cur%d" % (off + first)}, "nodes": nodes}
sys.stdout.write(HEAD + json.dumps({"data": {"repositoryOwner": {"projectV2": {"items": items}}}}))
