#!/usr/bin/env python3
"""next.py — pick the next task from board items, applying priority order, epic
sequencing, blockedBy guards, and the work-in-progress resume guard.

Usage: next.py <config-path> <board-id-or-empty> <item-list.json> [spec-id]
<item-list.json> is `gh project item-list --format json` output.
Prints candidates and either "=> PICK: #N" or "=> RESUME: #N" (WIP limit reached).
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config as C  # noqa: E402


def main(cfg_path, bid, items_path, only_spec=""):
    cfg = C.load_config(path=cfg_path, warn=False)
    data = json.load(open(items_path))
    board = next((x for x in cfg["boards"] if x["id"] == bid), cfg["boards"][0])
    flow = board["statusFlow"]
    prios = list(board["fields"]["priority"]["options"])  # order = rank
    specs = [s for s in cfg["specs"] if s["board"] == board["id"] and (not only_spec or s["id"] == only_spec)]
    max_wip = cfg.get("methodology", {}).get("maxInProgress", 1)
    wip_status = flow[1] if len(flow) > 1 else flow[0]
    review_status = flow[2] if len(flow) > 2 else None
    serial_delivery = bool(cfg.get("methodology", {}).get("serialDelivery", False))

    def title_of(it):
        return it.get("title") or it.get("content", {}).get("title", "")

    wip = [it for it in data["items"] if it.get("status") == wip_status]
    review_wip = [it for it in data["items"] if review_status and it.get("status") == review_status]

    def num_of(it):
        return it.get("content", {}).get("number")

    # #423: serialDelivery x maxInProgress>1 as ONE coherent mode — N parallel
    # implementation lanes, merges strictly ONE at a time. A slot is occupied
    # from PICK until MERGE: both In-progress AND In-review count toward
    # maxInProgress. Slots are COUNT-based, not identified — the board (this
    # item list) is the sole state; there is no slot-id side-car file.
    #
    #   occupied = count(In progress) + count(In review)
    #   occupied <  maxInProgress -> headroom exists, PICK proceeds normally
    #   occupied >= maxInProgress -> an In-progress item is the actionable
    #                                 next step (RESUME — finishing it is
    #                                 real progress even though the slot only
    #                                 frees at merge); WAIT only when EVERY
    #                                 occupying item is In review (nothing to
    #                                 resume — only a merge unblocks the loop)
    #
    # This generalizes #272's old "any WIP under serialDelivery blocks" rule,
    # which was exactly the maxInProgress=1 special case of this same formula
    # (occupied >= 1 whenever anything occupies a slot at all).
    #
    # Merge-queue ordering (#423 HOW — inspected live `gh project item-list
    # --format json`): its item/content shape carries NO per-item timestamp
    # field at all — content: {body, number, repository, title, type, url};
    # item: {content, estimate, id, labels, priority, repository, status,
    # title}. No updatedAt/createdAt anywhere. The only deterministic,
    # monotonic, immutable field available is content.number (the GitHub
    # issue number, assigned once at creation) — so the merge-dance queue
    # below sorts In-review items ascending by issue number as the "oldest
    # first by In-review entry" proxy.
    review_queue = sorted(review_wip, key=lambda it: (num_of(it) is None, num_of(it)))

    if serial_delivery and review_queue:
        print("Merge queue (In review, oldest-first by issue number):")
        for it in review_queue:
            print(f'  #{num_of(it)}  {title_of(it)}')

    if serial_delivery:
        occupied = len(wip) + len(review_wip)
        if occupied >= max_wip:
            if wip:
                print(f"Work already {wip_status} (limit {max_wip}) — finish or move it before starting new work:")
                for it in wip:
                    print(f'  #{num_of(it)}  {title_of(it)}')
                print(f'\n=> RESUME: #{num_of(wip[0])}  {title_of(wip[0])}')
            else:
                names = ",".join(f"#{num_of(it)}" for it in review_queue)
                print(f'\nWAIT: merge-dance — {names} In review; slots {max_wip}/{max_wip} occupied — '
                      "run the dance (merge oldest first) to free a slot")
            return
        # occupied < max_wip: headroom exists — fall through to the normal
        # picking logic below (the merge queue, if any, was already printed).

    def classify(title):
        """title -> (spec, epic, epic_rank, tasknum) or None for untagged (bugs)."""
        for s in specs:
            m = re.match(re.escape(s["taskPrefix"]) + r"-(\d+)", title)
            if not m:
                continue
            n = int(m.group(1))
            for rank, e in enumerate(s["epics"]):
                if any(lo <= n <= hi for lo, hi in e["taskRanges"]):
                    return s, e, rank, n
            return s, None, len(s["epics"]), n
        return None

    def at_least(status, wanted):
        try:
            return flow.index(status) >= flow.index(wanted)
        except ValueError:
            return False

    # resume guard (non-serial mode; serialDelivery's own occupied-vs-max_wip
    # check above already returned when it applies): WIP at/over the
    # configured limit -- finish that work first.
    if len(wip) >= max_wip:
        print(f"Work already {wip_status} (limit {max_wip}) — finish or move it before starting new work:")
        for it in wip:
            print(f'  #{it.get("content", {}).get("number")}  {title_of(it)}')
        print(f'\n=> RESUME: #{wip[0].get("content", {}).get("number")}  {title_of(wip[0])}')
        return

    # epic completion map: (spec_id, epic_id) -> [statuses of its tasks]
    epic_status = {}
    for it in data["items"]:
        c = classify(title_of(it))
        if c and c[1] is not None:
            epic_status.setdefault((c[0]["id"], c[1]["id"]), []).append(it.get("status") or flow[0])

    def blocked(spec, epic):
        if epic is None:
            return None
        for g in epic.get("blockedBy", []):
            sts = epic_status.get((spec["id"], g["epic"]), [])
            if not sts:
                return f'epic {g["epic"]} unseeded — run seed-board'
            if not all(at_least(st, g["untilStatus"]) for st in sts):
                return f'epic {g["epic"]} not fully {g["untilStatus"]}'
        return None

    rows, held = [], []
    for it in data["items"]:
        if it.get("status") != flow[0]:
            continue  # Backlog only
        title = title_of(it)
        num = it.get("content", {}).get("number")
        pr = prios.index(it["priority"]) if it.get("priority") in prios else len(prios)
        c = classify(title)
        if c is None:  # untagged (bugs): priority decides, near front
            rows.append((pr, -1, 0, num, title))
            continue
        spec, epic, erank, n = c
        why = blocked(spec, epic)
        if why:
            held.append((num, title, why))
            continue
        rows.append((pr, erank, n, num, title))
    rows.sort()
    if not rows:
        print("(backlog empty" + (" or fully blocked)" if held else ")"))
    else:
        print("Next candidates (prioritized + sequenced):")
        for pr, _, _, num, title in rows[:5]:
            p = prios[pr] if pr < len(prios) else "P?"
            print(f"  #{num}  [{p}]  {title}")
        print(f"\n=> PICK: #{rows[0][3]}  {rows[0][4]}")
    for num, title, why in held[:5]:
        print(f"  BLOCKED #{num} {title}  ({why})")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
