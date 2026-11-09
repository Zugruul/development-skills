#!/usr/bin/env python3
"""Test double for `gh`, used by the audit --fix sections (#564).

One mutable board in $AF_STATE ({"items":[{"id","number","status","title"}],"issues":[N,...]}),
a call log in $AF_LOG (one normalized line per TOP-LEVEL call; the graphql adapter's inner
`project item-list` is not logged), REST pull lists in $AF_PULLS_OPEN / $AF_PULLS_CLOSED.

Logged tokens: graphql:fields, graphql:items, rest:pulls-open, rest:pulls-closed, rest:pulls-head,
rest:issue-get, rest:comment, rest:patch, issue-create, item-add, item-edit <id> <status>,
and the raw argv for anything unexpected (which also exits 1).
Anything that looks like `pr list` / `issue comment` / `issue view` (GraphQL commands) is logged
as GRAPHQL-CMD so a test can assert there are none.
"""
import json
import os
import subprocess
import sys

STATUS = {"aaaa0001": "Backlog", "aaaa0002": "In progress", "aaaa0003": "In review",
          "aaaa0004": "QA", "aaaa0005": "Ready", "aaaa0006": "Deployed"}
argv = sys.argv[1:]
state_path = os.environ["AF_STATE"]
log_path = os.environ["AF_LOG"]


def log(line):
    with open(log_path, "a") as fh:
        fh.write(line + "\n")


def load():
    with open(state_path) as fh:
        return json.load(fh)


def save(st):
    with open(state_path, "w") as fh:
        json.dump(st, fh)


def arg_after(flag):
    return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else ""


def emit_file(env):
    path = os.environ.get(env, "")
    sys.stdout.write(open(path).read() if path and os.path.exists(path) else "[]")


a = " ".join(argv)
if os.environ.get("BOARD_AUDIT_TOKEN") or os.environ.get("BOARD_AUDIT_SNAP_FILE"):
    open(log_path + ".leak", "a").write("ENV-LEAK\n")  # a child of a trusted move inherited the audit's trust variables
if argv[:2] == ["api", "graphql"] and os.environ.get("AF_NO_STATUS") and "fields(first" in a:
    log("graphql:fields")
    names = [{"name": n} for n in ("Title", "Priority", "Estimate")]
    sys.stdout.write("HTTP/2.0 200 OK\nX-Ratelimit-Remaining: 4000\n\n" + json.dumps(
        {"data": {"repositoryOwner": {"projectV2": {"fields": {"nodes": names}}}}}))
    sys.exit(0)
if argv[:2] == ["api", "graphql"] and os.environ.get("AF_GRAPHQL_FAIL"):
    log("graphql:fail")
    sys.stderr.write("gh: API rate limit exceeded for user\n" if os.environ["AF_GRAPHQL_FAIL"] == "ratelimit"
                     else "gh: Bad Gateway (HTTP 502)\n")
    sys.exit(1)
if argv[:2] == ["api", "graphql"]:
    q = " ".join(argv)
    log("graphql:fields" if "fields(first" in q else "graphql:items")
    os.execvp("python3", ["python3", os.environ["GH_GQL_ADAPTER"], sys.argv[0]] + argv)
if argv[:2] == ["project", "item-list"]:
    st = load()
    items = [{"id": i["id"], "status": i.get("status") or None, "title": i.get("title", ""),
              "content": {"number": i["number"], "type": "Issue"}} for i in st["items"]]
    print(json.dumps({"items": items, "totalCount": len(items)}))
    sys.exit(0)
if argv[:2] == ["project", "item-edit"]:
    st = load()
    item_id = arg_after("--id")
    status = STATUS.get(arg_after("--single-select-option-id"))
    for i in st["items"]:
        if i["id"] == item_id and status:
            i["status"] = status
    save(st)
    log(f"item-edit {item_id} {status}")
    print("edited")
    sys.exit(0)
if argv[:2] == ["project", "item-add"]:
    st = load()
    num = int(arg_after("--url").rsplit("/", 1)[1])
    st["items"].append({"id": f"ITEM_{num}", "number": num, "status": "", "title": ""})
    save(st)
    log(f"item-add {num}")
    sys.exit(0)
if argv[:2] == ["issue", "create"]:
    st = load()
    num = st.get("next", 900)
    st["next"] = num + 1
    st.setdefault("issues", []).append(num)
    save(st)
    log("issue-create " + arg_after("--title"))
    print(f"https://github.com/fixture-owner/fixture-project/issues/{num}")
    sys.exit(0)
if argv[:1] == ["api"] and "rate_limit" in a:
    log("rest:rate_limit")
    print(json.dumps({"resources": {"graphql": {"remaining": 5000, "reset": 0}}}))
    sys.exit(0)
if argv[:1] == ["api"]:
    if "-X" in argv and arg_after("-X") == "POST":
        log("rest:comment " + [x for x in argv if x.startswith("repos/")][0])
        sys.exit(0)
    if "-X" in argv and arg_after("-X") == "PATCH":
        log("rest:patch")
        sys.exit(0)
    path = next((x for x in argv if x.startswith("repos/")), "")
    if "/pulls" in path and "state=open" in path and "head=" not in a:
        log("rest:pulls-open " + path)
        emit_file("AF_PULLS_OPEN")
        sys.exit(0)
    if "/pulls" in path and "state=closed" in path:
        log("rest:pulls-closed " + path)
        emit_file("AF_PULLS_CLOSED")
        sys.exit(0)
    if "/pulls" in path:
        log("rest:pulls-head")
        print("[]")
        sys.exit(0)
    if "/issues/" in path:
        log("rest:issue-get " + path)
        num = int(path.rsplit("/", 1)[1])
        if num in load().get("issues", []) or any(i["number"] == num for i in load()["items"]):
            print(json.dumps({"number": num, "state": "open"}))
            sys.exit(0)
        sys.stderr.write("gh: Not Found (HTTP 404)\n")
        sys.exit(1)
if argv[:2] in (["pr", "list"], ["issue", "comment"], ["issue", "view"], ["issue", "list"], ["pr", "view"]):
    log("GRAPHQL-CMD " + a)
    print("[]")
    sys.exit(0)
log("UNEXPECTED " + a)
sys.stderr.write("fake gh: unexpected: " + a + "\n")
sys.exit(1)
