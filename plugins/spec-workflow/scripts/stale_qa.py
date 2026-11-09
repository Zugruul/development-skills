#!/usr/bin/env python3
"""stale_qa.py — report QA items that have waited too long for validation (#567).

LOCAL data only: the item list `next` already fetched plus the telemetry
`transition` events board.sh move records. It makes no GitHub call.

Called by next.py with the config, flow, items and root it already loaded.
Oldest first, at most 5 lines then "+N more"; age-unknown items fold into one line. Never fails.
"""
import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from telemetry import _load_events, _parse_ts, telemetry_path  # noqa: E402

DEFAULT_HOURS = 24
MAX_LINES = 5
ADVICE = "validate and move on, or record why not"


def _norm(s):
    return " ".join(str(s or "").lower().split())


def qa_since(events, qa="qa"):
    """task -> datetime of its LATEST transition into QA, or None when that
    latest transition has an unreadable ts (age unknown; never an older entry)."""
    since = {}
    for e in events:
        if e.get("kind") != "transition" or _norm(e.get("to")) != qa:
            continue
        try:
            ts = _parse_ts(e["ts"])
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
        except Exception:  # noqa: BLE001
            ts = None
        task = str(e.get("task"))
        prev = since.get(task, False)
        if prev is False or ts is None or prev is None or ts > prev:
            since[task] = ts
    return since


def human_age(hours):
    return f"{int(hours // 24)}d" if hours >= 48 else f"{int(hours)}h"


def lines(nums, since, stale_hours, now):
    known, unknown = [], []
    for num in nums:
        ts = since.get(str(num))
        if ts is None:
            unknown.append(num)
            continue
        hours = (now - ts).total_seconds() / 3600
        if hours > stale_hours:
            known.append((hours, num))
    known.sort(key=lambda r: -r[0])
    out = [f"STALE QA: #{n} in QA for {human_age(h)} — {ADVICE}" for h, n in known[:MAX_LINES]]
    if len(known) > MAX_LINES:
        out.append(f"STALE QA: +{len(known) - MAX_LINES} more")
    if unknown:
        shown = ", ".join(f"#{n}" for n in unknown[:MAX_LINES])
        if len(unknown) > MAX_LINES:
            shown += f", +{len(unknown) - MAX_LINES} more"
        noun = "item" if len(unknown) == 1 else "items"
        out.append(f"STALE QA: {len(unknown)} {noun} with age unknown: {shown}")
    return out


def stale_hours_of(cfg):
    val = (cfg.get("methodology") or {}).get("qaStaleHours", DEFAULT_HOURS)
    return val if isinstance(val, int) and not isinstance(val, bool) and val >= 1 else DEFAULT_HOURS


def report(cfg, flow, items, root, now=None):
    """cfg/flow/items/root are what next.py already loaded: nothing is re-read
    except the local telemetry log, and only when a QA item exists."""
    if len(flow) < 4:
        return []  # no QA slot in this board's flow
    qa = _norm(flow[3])  # the fourth statusFlow entry, like wip.Policy's work/review
    nums = [it.get("content", {}).get("number") for it in items if _norm(it.get("status")) == qa]
    nums = [n for n in nums if n is not None]
    if not nums:
        return []
    events = []
    try:
        events, _ = _load_events(telemetry_path(root))
    except Exception:  # noqa: BLE001  (no log yet == no records)
        pass
    return lines(nums, qa_since(events, qa), stale_hours_of(cfg), now or datetime.now(timezone.utc))


def main(cfg, flow, items, root):
    try:
        for line in report(cfg, flow, items, root):
            print(line)
    except Exception as exc:  # noqa: BLE001  (advisory only: never break next)
        print(f"(stale QA report unavailable: {exc})", file=sys.stderr)
