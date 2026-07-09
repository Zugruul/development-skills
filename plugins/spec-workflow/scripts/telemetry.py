#!/usr/bin/env python3
"""telemetry.py — per-iteration build-loop telemetry (JSONL) + metrics.

Storage — OQ-5 (SPEC §12, decided): fixed at `.claude/telemetry.jsonl` under
the repo root. Gitignored; no config knob. One JSON object per line.

Record kinds (all require `task` and `ts`; `ts` is an INPUT, an ISO 8601
string — this script never reads the clock in tested paths; callers such as
board.sh/gate.sh stamp real wall-clock time when they record):

    transition    {"kind": "transition", "task": <id>, "from": <status>,
                   "to": <status>, "ts": <iso8601>}
                  `from` may be "" (board.sh does not track the prior status;
                  metrics only uses `to` + `ts` pairs, so an empty `from`
                  does not affect any computed number).
    gate          {"kind": "gate", "task": <id>, "ok": <bool>, "ts": <iso8601>}
    review-round  {"kind": "review-round", "task": <id>, "round": <int>,
                   "verdict": <str>, "ts": <iso8601>}
    task-close    {"kind": "task-close", "task": <id>, "estimate": <number>,
                   "ts": <iso8601>}

CLI:
    telemetry.py <root> record <event-json-or-@file>   # validate + append
    telemetry.py <root> metrics                        # report
"""
import json
import os
import sys
from collections import defaultdict
from datetime import datetime

KINDS = {"transition", "gate", "review-round", "task-close", "retro-skip"}
TELEMETRY_REL = os.path.join(".claude", "telemetry.jsonl")


def telemetry_path(root):
    return os.path.join(root, TELEMETRY_REL)


def validate_event(rec):
    """Return a list of error strings; empty = valid."""
    if not isinstance(rec, dict):
        return ["record must be a JSON object"]
    errs = []
    kind = rec.get("kind")
    if kind not in KINDS:
        errs.append(f"kind must be one of {sorted(KINDS)} (got {kind!r})")
        return errs  # nothing more to check without a known kind
    if not rec.get("task"):
        errs.append("task is required")
    if not rec.get("ts"):
        errs.append("ts is required")

    if kind == "transition":
        if "from" not in rec or not isinstance(rec.get("from"), str):
            errs.append("transition.from is required (string; '' allowed — the initial status has no prior)")
        if not rec.get("to") or not isinstance(rec.get("to"), str):
            errs.append("transition.to is required (non-empty string)")
    elif kind == "gate":
        if not isinstance(rec.get("ok"), bool):
            errs.append("gate.ok must be a boolean")
    elif kind == "review-round":
        if not isinstance(rec.get("round"), int) or isinstance(rec.get("round"), bool):
            errs.append("review-round.round must be an integer")
        if not rec.get("verdict"):
            errs.append("review-round.verdict is required")
    elif kind == "task-close":
        est = rec.get("estimate")
        if not isinstance(est, (int, float)) or isinstance(est, bool):
            errs.append("task-close.estimate must be a number")
    elif kind == "retro-skip":
        if not rec.get("reason"):
            errs.append("retro-skip.reason is required — a skip always needs a stated reason")
    return errs


def cmd_record(root, arg):
    if arg.startswith("@"):
        fpath = arg[1:]
        try:
            with open(fpath) as fh:
                raw = fh.read()
        except OSError as e:
            print(f"ERROR: cannot read {fpath}: {e}")
            return 1
    else:
        raw = arg
    try:
        rec = json.loads(raw)
    except Exception as e:  # noqa: BLE001
        print(f"INVALID: not valid JSON: {e}")
        return 1
    errs = validate_event(rec)
    if errs:
        for e in errs:
            print(f"INVALID: {e}")
        return 1

    path = telemetry_path(root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as fh:
        fh.write(json.dumps(rec, sort_keys=True) + "\n")
    print(f"OK: recorded {rec['kind']} event for task {rec['task']} -> {path}")
    return 0


def _parse_ts(ts):
    s = ts[:-1] + "+00:00" if ts.endswith("Z") else ts
    return datetime.fromisoformat(s)


def _load_events(path):
    """Return (events, skipped-count). Malformed/unknown-kind lines are
    skipped, not fatal — one bad line must not hide the rest of the log."""
    events = []
    skipped = 0
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:  # noqa: BLE001
                skipped += 1
                continue
            if validate_event(rec):
                skipped += 1
                continue
            events.append(rec)
    return events, skipped


def cmd_metrics(root):
    path = telemetry_path(root)
    if not os.path.exists(path):
        print("no telemetry yet")
        return 0
    events, skipped = _load_events(path)
    if skipped:
        sys.stderr.write(f"telemetry.py: skipped {skipped} malformed line(s)\n")
    if not events:
        print("no telemetry yet")
        return 0

    tasks = {e["task"] for e in events}

    by_task_transitions = defaultdict(list)
    for e in events:
        if e["kind"] == "transition":
            by_task_transitions[e["task"]].append(e)
    for lst in by_task_transitions.values():
        lst.sort(key=lambda e: _parse_ts(e["ts"]))

    status_durations = defaultdict(list)
    for trs in by_task_transitions.values():
        for i in range(len(trs) - 1):
            status = trs[i]["to"]
            hours = (_parse_ts(trs[i + 1]["ts"]) - _parse_ts(trs[i]["ts"])).total_seconds() / 3600.0
            status_durations[status].append(hours)

    by_task_gates = defaultdict(list)
    for e in events:
        if e["kind"] == "gate":
            by_task_gates[e["task"]].append(e)
    for lst in by_task_gates.values():
        lst.sort(key=lambda e: _parse_ts(e["ts"]))
    total_gate_tasks = len(by_task_gates)
    first_try_ok = sum(1 for lst in by_task_gates.values() if lst[0]["ok"])

    by_task_reviews = defaultdict(list)
    for e in events:
        if e["kind"] == "review-round":
            by_task_reviews[e["task"]].append(e)
    total_review_tasks = len(by_task_reviews)
    rework_tasks = sum(1 for lst in by_task_reviews.values() if len(lst) > 1)

    by_task_close = {}
    for e in events:
        if e["kind"] == "task-close":
            by_task_close[e["task"]] = e  # last one wins if duplicated

    retro_skips = [e for e in events if e["kind"] == "retro-skip"]

    print(f"tasks={len(tasks)} events={len(events)} skipped={skipped}")
    print()
    print("cycle time per status (avg over closed transitions):")
    if status_durations:
        for status in sorted(status_durations):
            vals = status_durations[status]
            avg = sum(vals) / len(vals)
            print(f"  {status}  avg={avg:.1f}h  n={len(vals)}")
    else:
        print("  (no completed transitions)")
    print()

    if total_gate_tasks:
        pct = 100.0 * first_try_ok / total_gate_tasks
        print(f"gate first-try rate: {pct:.1f}% ({first_try_ok}/{total_gate_tasks} tasks)")
    else:
        print("gate first-try rate: no gate events")
    print()

    if total_review_tasks:
        pct = 100.0 * rework_tasks / total_review_tasks
        print(f"rework rate: {pct:.1f}% ({rework_tasks}/{total_review_tasks} tasks with review rounds)")
    else:
        print("rework rate: no review-round events")
    print()

    print("estimate vs actual (closed tasks):")
    if by_task_close:
        for task in sorted(by_task_close):
            close_e = by_task_close[task]
            trs = by_task_transitions.get(task, [])
            if not trs:
                print(f"  task={task}  estimate={close_e['estimate']}  actual=insufficient data (no transitions)")
                continue
            actual = (_parse_ts(close_e["ts"]) - _parse_ts(trs[0]["ts"])).total_seconds() / 3600.0
            print(f"  task={task}  estimate={close_e['estimate']}  actual={actual:.1f}h")
    else:
        print("  (no closed tasks)")
    print()

    if retro_skips:
        print(f"retro skips: {len(retro_skips)} (retro is MANDATORY at PR close — investigate)")
        for e in retro_skips:
            print(f"  task={e['task']}  reason={e.get('reason', '?')}  ts={e['ts']}")
    else:
        print("retro skips: none")
    return 0


def _cli(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: telemetry.py <root> {record <event-json-or-@file>|metrics}\n")
        return 2
    root, verb = argv[0], argv[1]
    if verb == "record":
        if len(argv) < 3:
            sys.stderr.write("usage: telemetry.py <root> record <event-json-or-@file>\n")
            return 2
        return cmd_record(root, argv[2])
    if verb == "metrics":
        return cmd_metrics(root)
    sys.stderr.write(f"telemetry.py: unknown verb {verb!r}\n")
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
