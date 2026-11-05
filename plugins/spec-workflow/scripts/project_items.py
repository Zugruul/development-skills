#!/usr/bin/env python3
"""Slim GraphQL board read for gh_project_items_json (paginate.sh, #544).

`gh project item-list` requests fieldValues(first:100) on every item, which costs
~101 GraphQL points per 100 items. The query below uses fieldValueByName aliases (no
per-item field connection; the one nested connection left is the content's labels(first: 20),
kept for output-shape compatibility) and costs about 1 point per 100 items.

  project_items.py fields-query [--viewer]
      print the field-name resolution query (one extra point per board read).
  project_items.py resolve [page options]
      stdin = the fields-query response. stdout = "status=Status,priority=..."
      with the project's REAL field names (matched case-insensitively, like
      init-config.sh and gh). Exit 4 (names still printed) when the project has no
      Status field; Exit 5 (names still printed, exact-case Status used if present) when
      several Status fields differ only by case; Priority/Estimate missing is not an error.
  project_items.py query [--viewer] [--dry-run] [--names status=Status,...]
      print the items query (--viewer: the authenticated user's projects, for
      an "@me" owner; --dry-run: also ask rateLimit(dryRun: true) for its cost;
      --names: the resolved field names, default Status/Priority/Estimate).
  project_items.py page [--rc N] [--err FILE] [--reset-file FILE] [--owner O --number N]
      stdin = what `gh api -i graphql` printed (headers + body; bare JSON also works).
      stdout = one normalised page {"items":[...],"totalCount","hasNextPage","endCursor"}
      in the JSON shape `gh project item-list --format json` produces. Any error,
      including a 200 response carrying `errors`, prints GitHub's real message (plus
      the reset time: Retry-After if present, else X-Ratelimit-Reset) on stderr, nothing on stdout,
      and exits 1.
  project_items.py merge DIR
      concatenate DIR/*.json pages into {"items":[...],"totalCount":N}.
"""
import datetime
import glob
import json
import os
import sys
import time

# Board fields callers read. Output keys are the lowercase keys gh produces; the field NAME
# used in fieldValueByName is the project's real one (the lookup is case-sensitive).
SINGLE_SELECT = ("status", "priority")
NUMBER = ("estimate",)
DEFAULT_NAMES = {"status": "Status", "priority": "Priority", "estimate": "Estimate"}

_CONTENT = ("number title body url repository { nameWithOwner } "
            "labels(first: 20) { nodes { name } }")


def build_query(viewer=False, dry_run=False, names=None):
    names = DEFAULT_NAMES if names is None else names
    fields = "".join(
        f'{k}: fieldValueByName(name: "{names[k]}") {{ ... on ProjectV2ItemFieldSingleSelectValue {{ name }} }}\n'
        for k in SINGLE_SELECT if k in names)
    fields += "".join(
        f'{k}: fieldValueByName(name: "{names[k]}") {{ ... on ProjectV2ItemFieldNumberValue {{ number }} }}\n'
        for k in NUMBER if k in names)
    project = f"""projectV2(number: $number) {{
      items(first: $first, after: $after) {{
        totalCount
        pageInfo {{ hasNextPage endCursor }}
        nodes {{
          id
          {fields}
          content {{
            __typename
            ... on Issue {{ {_CONTENT} }}
            ... on PullRequest {{ {_CONTENT} }}
            ... on DraftIssue {{ title body }}
          }}
        }}
      }}
    }}"""
    if viewer:
        root = f"viewer {{ {project} }}"
        head = "query($number: Int!, $first: Int!, $after: String)"
    else:
        root = f"repositoryOwner(login: $owner) {{ ... on ProjectV2Owner {{ {project} }} }}"
        head = "query($owner: String!, $number: Int!, $first: Int!, $after: String)"
    cost = "rateLimit(dryRun: true) { cost remaining resetAt }\n  " if dry_run else ""
    return f"{head} {{\n  {cost}{root}\n}}\n"


def build_fields_query(viewer=False):
    project = ("projectV2(number: $number) { fields(first: 100) "
               "{ nodes { ... on ProjectV2FieldCommon { name } } } }")
    if viewer:
        return f"query($number: Int!) {{\n  viewer {{ {project} }}\n}}\n"
    return ("query($owner: String!, $number: Int!) {\n  repositoryOwner(login: $owner) "
            f"{{ ... on ProjectV2Owner {{ {project} }} }}\n}}\n")


def split_response(raw):
    """-> (status, headers{lower: value}, body) from `gh api -i` output."""
    status, headers = 200, {}
    text = raw.replace("\r\n", "\n")
    while text.startswith("HTTP/"):
        head, _, text = text.partition("\n\n")
        lines = head.split("\n")
        parts = lines[0].split()
        status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        headers = {}
        for line in lines[1:]:
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
    return status, headers, text


def iso(epoch):
    return datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def reset_epoch(headers):
    # Retry-After applies to a secondary limit and can be far LATER than the primary reset: it wins.
    # It may also be an HTTP date (not supported): that must fail on its own and fall through to
    # X-Ratelimit-Reset rather than discard the whole header set.
    if "retry-after" in headers:
        try:
            return int(time.time()) + int(headers["retry-after"])
        except ValueError:
            pass
    if "x-ratelimit-reset" in headers:
        try:
            return int(headers["x-ratelimit-reset"])
        except ValueError:
            pass
    return None


def fail(message, headers=None, rate_limited=False, reset_file=None):
    epoch = reset_epoch(headers or {})
    if epoch and (rate_limited or (headers or {}).get("x-ratelimit-remaining") == "0"):
        message += f" (resets {iso(epoch)})"
        if reset_file:
            try:
                with open(reset_file, "w") as f:
                    f.write(str(epoch))
            except OSError:
                pass
    print(message, file=sys.stderr)
    return 1


def is_rate_limit(text):
    t = text.lower()
    return "rate limit" in t or "rate_limit" in t or "ratelimit" in t


def num(v):
    return int(v) if isinstance(v, float) and v == int(v) else v


def normalise(node):
    content = node.get("content")
    item = {"id": node["id"]}
    c = {"type": "REDACTED"}
    if isinstance(content, dict):
        c = {"type": content.get("__typename") or ""}
        for key in ("body", "number", "title", "url"):
            if key in content:
                c[key] = content[key]
        repo = (content.get("repository") or {}).get("nameWithOwner")
        if repo:
            c["repository"] = repo
            item_repo = "https://github.com/" + repo
        else:
            item_repo = None
        labels = [n["name"] for n in ((content.get("labels") or {}).get("nodes") or [])]
    else:
        item_repo, labels = None, []
    item["title"] = c.get("title", "")
    for key in SINGLE_SELECT:
        v = node.get(key)
        if isinstance(v, dict) and v.get("name") is not None:
            item[key] = v["name"]
    for key in NUMBER:
        v = node.get(key)
        if isinstance(v, dict) and v.get("number") is not None:
            item[key] = num(v["number"])
    if labels:
        item["labels"] = labels
    if item_repo:
        item["repository"] = item_repo
    item["content"] = c
    return item


def read_response(args):
    """Shared by `page` and `resolve`: -> (opts, data, None) or (opts, None, exit_code) after reporting."""
    opts = {"--rc": "0", "--err": None, "--reset-file": None, "--owner": "", "--number": ""}
    it = iter(args)
    for a in it:
        if a in opts:
            opts[a] = next(it, "")
    rc = int(opts["--rc"])
    rf = opts["--reset-file"]
    status, headers, body = split_response(sys.stdin.buffer.read().decode("utf-8", errors="replace"))
    try:
        doc = json.loads(body)
        if not isinstance(doc, dict):
            raise ValueError("not an object")
    except ValueError:
        doc = None

    def stderr_text():
        try:
            return open(opts["--err"]).read().strip() if opts["--err"] else ""
        except OSError:
            return ""

    if doc is None:
        detail = stderr_text() or f"gh api graphql failed (exit {rc}, HTTP {status}) without a JSON body"
        return opts, None, fail(detail, headers, is_rate_limit(detail), rf)
    errors = doc.get("errors")
    if errors or status >= 400 or rc != 0:
        # Any nonzero gh exit is a failed read, whatever the body holds (a partial `data` is not a board).
        msgs = []
        for e in errors if isinstance(errors, list) else []:
            if isinstance(e, dict):
                tag = " ".join(x for x in (e.get("type"), e.get("code")) if x)
                msgs.append(f"GraphQL: {e.get('message') or 'error'}" + (f" [{tag}]" if tag else ""))
            else:
                msgs.append(f"GraphQL: {e}")
        if not msgs:
            detail = doc.get("message") or stderr_text() or "no error message"
            msgs.append(f"GitHub API error (HTTP {status}, gh exit {rc}): {detail}")
        text = "; ".join(msgs)
        return opts, None, fail(text, headers, is_rate_limit(text), rf)
    return opts, doc.get("data") or {}, None


def project_of(data, opts):
    root = data.get("repositoryOwner") if "repositoryOwner" in data else data.get("viewer")
    project = (root or {}).get("projectV2")
    if not isinstance(project, dict):
        fail(f"project {opts['--number'] or '?'} not found for owner {opts['--owner'] or '?'} "
             "(owner or project does not exist, or the token cannot see it)")
        return None
    return project


def cmd_resolve(args):
    opts, data, code = read_response(args)
    if code is not None:
        return code
    project = project_of(data, opts)
    if project is None:
        return 1
    real = [n.get("name") for n in ((project.get("fields") or {}).get("nodes") or []) if isinstance(n, dict) and n.get("name")]
    found, ambiguous = {}, False
    for key in (*SINGLE_SELECT, *NUMBER):
        loose = [n for n in real if n.lower() == key]
        exact = [n for n in loose if n == DEFAULT_NAMES[key]]
        if exact:
            found[key] = exact[0]
        elif len(loose) == 1:
            found[key] = loose[0]
        elif loose and key != "status":
            found[key] = loose[0]
        if key == "status" and len(loose) > 1:
            ambiguous = True
    print(",".join(f"{k}={v}" for k, v in found.items()))
    if ambiguous:
        print("project has more than one Status field differing only by case (ambiguous): "
              + ("using the exact-case 'Status'" if "status" in found else "none is an exact match, Status is unresolved"),
              file=sys.stderr)
        return 5
    if "status" not in found:
        print("project has no Status field (matched case-insensitively): board statuses cannot be read", file=sys.stderr)
        return 4
    return 0


def cmd_page(args):
    opts, data, code = read_response(args)
    if code is not None:
        return code
    project = project_of(data, opts)
    if project is None:
        return 1
    items = project.get("items") or {}
    info = items.get("pageInfo") or {}
    has_next, cursor = info.get("hasNextPage"), info.get("endCursor")
    if type(has_next) is not bool:
        # hasNextPage false is the ONLY proof of exhaustion: absent or odd proves nothing.
        return fail("malformed board page: pageInfo.hasNextPage is missing or not a boolean")
    if has_next and not cursor:
        return fail("incomplete board read: hasNextPage is true but GitHub returned no endCursor")
    try:
        out = [normalise(n) for n in items.get("nodes") or []]
    except (KeyError, TypeError, AttributeError):
        return fail("malformed board page: item without an id")
    if has_next and not out:
        return fail("incomplete board read: hasNextPage is true but the page has no items (no progress)")
    total = items.get("totalCount")
    if type(total) is not int:
        return fail("malformed board page: totalCount is not an integer")
    print(json.dumps({"items": out, "totalCount": total,
                      "hasNextPage": has_next, "endCursor": cursor}))
    return 0


def cmd_merge(args):
    items, total = [], 0
    for path in sorted(glob.glob(os.path.join(args[0], "*.json"))):
        with open(path) as f:
            page = json.load(f)
        items.extend(page["items"])
        total = page.get("totalCount", total)
    print(json.dumps({"items": items, "totalCount": total}))
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = argv[1], argv[2:]
    if cmd == "query":
        names = None
        if "--names" in rest:
            raw = rest[rest.index("--names") + 1] if rest.index("--names") + 1 < len(rest) else ""
            names = dict(p.split("=", 1) for p in raw.split(",") if "=" in p)
        sys.stdout.write(build_query("--viewer" in rest, "--dry-run" in rest, names))
        return 0
    if cmd == "fields-query":
        sys.stdout.write(build_fields_query("--viewer" in rest))
        return 0
    if cmd == "resolve":
        return cmd_resolve(rest)
    if cmd == "page":
        return cmd_page(rest)
    if cmd == "merge":
        return cmd_merge(rest)
    print(f"unknown action {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
