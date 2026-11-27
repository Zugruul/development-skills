#!/usr/bin/env python3
"""Names for one lane: its branch, its Herdr workspace label and its agent.

  lane_name.py --desc TEXT [--source SOURCE --id TASKID]
               [--kind KIND [--role lane|review] [--taken NAME ...]] [--json]
  lane_name.py --sources

With a task:     branch feat/<taskid>-<desc>    label <TAG>-<taskid>-<desc>
                 agent  <kind>-lane-<taskid, lowercased>
Without a task:  branch feat/<desc>             label <desc>
                 agent  <kind>-lane-<desc>

The agent name starts with the agent kind (claude, codex, opencode, ...), so
Herdr's sidebar still shows which kind of agent runs the lane. --role review
names the lane's reviewer: <kind>-review-<taskid or desc>. Herdr allows 32
characters of lowercase letters, digits, '-' and '_'. When the name would be
longer, only the part after the role is shortened: it is cut and ends in
-<4 hex digits> taken from the whole id or slug, so two long names stay
different. The kind is never cut. A name listed in --taken (the live agents'
names) gets -2, -3, ... instead, within the same limit.

<desc> is a short lowercase kebab-case slug of TEXT (the task title or the
user's description). <TAG> says where the task lives and comes from
SOURCE_TAGS below: add a line there to support a new source.

The task id is used as the source gives it and may itself contain hyphens
(a ClickUp custom id, a Jira key). Never recover the id or the slug by
splitting a branch or label on hyphens: read them from --json, or keep the
values you passed in.

Exit codes: 0 ok, 2 usage, 6 a name cannot be built from the input.
Offline: reads nothing and calls nothing. Python 3.9+, stdlib only.
"""
import argparse
import hashlib
import json
import re
import sys

# Where a task lives -> the tag that starts its lane's workspace label.
SOURCE_TAGS = {
    "clickup": "CU",
    "github": "GH",
    "jira": "J",
}

BRANCH_PREFIX = "feat"
DESC_MAX = 40
AGENT_MAX = 32


def slug(text, limit=DESC_MAX):
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    if len(s) <= limit:
        return s
    cut = s[:limit + 1]
    if "-" in cut:
        cut = cut[:cut.rindex("-")]
    return cut[:limit].strip("-")


def agent_name(kind, role, tail, taken=()):
    """<kind>-<role>-<tail> within Herdr's limit; only the tail is ever shortened."""
    k = (kind or "").strip().lower()
    if not re.match(r"^[a-z][a-z0-9_]*$", k):
        raise ValueError("agent kind %r is not a lowercase word (claude, codex, opencode, ...)" % kind)
    head = "%s-%s-" % (k, role)
    tail = re.sub(r"[^a-z0-9]+", "-", tail.lower()).strip("-")
    digest = hashlib.sha1(tail.encode("utf-8")).hexdigest()[:4]

    def fit(suffix=""):
        room = AGENT_MAX - len(head) - len(suffix)
        if len(tail) <= room:
            return head + tail + suffix
        keep = room - len(digest) - 1
        if keep < 1:
            raise ValueError("agent kind %r leaves no room for the lane in a %d-character name" % (kind, AGENT_MAX))
        return head + tail[:keep].rstrip("-") + "-" + digest + suffix

    name, n = fit(), 1
    taken = set(taken or ())
    while name in taken:
        n += 1
        name = fit("-%d" % n)
    return name


def names(desc, source=None, task_id=None, kind=None, role="lane", taken=()):
    d = slug(desc)
    if not d:
        raise ValueError("the description %r leaves nothing for the name: give a few plain words" % desc)
    if bool(source) != bool(task_id):
        raise ValueError("--source and --id go together: a lane either has a task (both) or has none (neither)")
    if not task_id:
        return dict(task=False, source=None, tag=None, id=None, desc=d,
                    branch="%s/%s" % (BRANCH_PREFIX, d), label=d,
                    agent=agent_name(kind, role, d, taken) if kind else None)
    tag = SOURCE_TAGS.get(source.lower())
    if not tag:
        raise ValueError("unknown task source %r (known: %s)" % (source, ", ".join(sorted(SOURCE_TAGS))))
    tid = task_id.strip().lstrip("#")
    if not re.match(r"^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$", tid):
        raise ValueError("task id %r is not letters and digits, optionally hyphen-separated" % task_id)
    return dict(task=True, source=source.lower(), tag=tag, id=tid, desc=d,
                branch="%s/%s-%s" % (BRANCH_PREFIX, tid, d), label="%s-%s-%s" % (tag, tid, d),
                agent=agent_name(kind, role, tid, taken) if kind else None)


def main():
    ap = argparse.ArgumentParser(prog="lane_name.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("--desc"); ap.add_argument("--source"); ap.add_argument("--id")
    ap.add_argument("--kind"); ap.add_argument("--role", choices=("lane", "review"), default="lane")
    ap.add_argument("--taken", nargs="*", default=[])
    ap.add_argument("--json", action="store_true"); ap.add_argument("--sources", action="store_true")
    a = ap.parse_args()
    if a.sources:
        for k in sorted(SOURCE_TAGS):
            print("%-8s %s" % (k, SOURCE_TAGS[k]))
        return
    if not a.desc:
        ap.error("--desc is required")
    try:
        n = names(a.desc, a.source, a.id, a.kind, a.role, a.taken)
    except ValueError as e:
        print("lane_name: %s" % e, file=sys.stderr)
        sys.exit(6)
    if a.json:
        print(json.dumps(n, indent=2))
        return
    print("BRANCH %s" % n["branch"])
    print("LABEL  %s" % n["label"])
    print("AGENT  %s" % (n["agent"] or "(give --kind to get the agent name)"))
    print("TASK   %s" % ("%s %s" % (n["source"], n["id"]) if n["task"] else "none"))


if __name__ == "__main__":
    main()
