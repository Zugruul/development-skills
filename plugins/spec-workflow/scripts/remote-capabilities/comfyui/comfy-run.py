#!/usr/bin/env python3
"""comfy-run.py — submit a PRE-AUTHORED ComfyUI API-format workflow and wait.

The remote half of the remote-compute ComfyUI demo job (design:
docs/design/remote-compute-plan.md; E7 hard rule from compute-registry-plan-v3
§3.6 / SPEC-ASSISTANT §14.2): this script only ever POSTs a workflow file that
already exists on disk, with the positive-prompt text substituted — it never
composes or mutates graph structure. ComfyUI is reached on 127.0.0.1 only
(never a LAN address): run this ON the machine hosting ComfyUI, e.g. via
`remote-compute run <nick> <job>` which executes it over SSH.

Usage:
    comfy-run.py --workflow PATH.json [--prompt TEXT] [--port 8188]
                 [--prompt-node ID] [--timeout 600] [--out DIR]
                 [--set NODE.INPUT=VALUE]...
    comfy-run.py --list-models [--port 8188]

- --prompt replaces inputs.text of the node given by --prompt-node, or of the
  FIRST CLIPTextEncode node whose inputs.text is a string when omitted.
- --set changes the VALUE of an input that already exists, addressing the node
  by id or by _meta.title (ambiguous titles are refused). Types are preserved.
  Any input the server declares as an enum (ckpt_name, sampler_name, ...) is
  checked against /object_info BEFORE submitting, so a bad model name fails in
  milliseconds naming every available option instead of after a queue round
  trip. --list-models prints the checkpoints this server offers.
- Blocks until the prompt leaves ComfyUI's queue, then prints one line per
  produced image: `ARTIFACT <subfolder>/<filename>` (files are in ComfyUI's
  own output dir; pull them with `remote-compute job-pull`, or pass --out to
  also copy them into the job workdir).
Exit codes: 0 ok · 1 ComfyUI unreachable/error · 2 usage.
stdlib only (urllib) — no pip installs on the remote machine.
"""
import argparse
import json
import shutil
import sys
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:%d"


def substitute_prompt(workflow, text, node_id=None):
    """Replace the positive prompt text in an API-format workflow dict.
    Returns the node id used. Raises KeyError if no suitable node exists."""
    if node_id is not None:
        workflow[node_id]["inputs"]["text"] = text
        return node_id
    for nid, node in workflow.items():
        if node.get("class_type") == "CLIPTextEncode" and isinstance(
                node.get("inputs", {}).get("text"), str):
            node["inputs"]["text"] = text
            return nid
    raise KeyError("no CLIPTextEncode node with a string inputs.text found")


def find_node(workflow, name):
    """Resolve a node by exact id, else by unique _meta.title."""
    if name in workflow:
        return name
    matches = [nid for nid, n in workflow.items()
               if (n.get("_meta") or {}).get("title") == name]
    if len(matches) == 1:
        return matches[0]
    titles = sorted({(n.get("_meta") or {}).get("title") or nid for nid, n in workflow.items()})
    if not matches:
        raise KeyError("no node with id or title %r — available: %s" % (name, ", ".join(titles)))
    raise KeyError("title %r matches nodes %s — use the node id" % (name, ", ".join(matches)))


def apply_set(workflow, spec):
    """--set NAME.INPUT=VALUE — NAME is a node id or _meta.title. Only the
    VALUE of an existing input changes (type-preserved: int/float/bool inputs
    are cast); graph structure is never touched. Returns the node id."""
    name_input, _, value = spec.partition("=")
    name, _, input_name = name_input.rpartition(".")
    if not name or not input_name:
        raise KeyError("--set needs NAME.INPUT=VALUE (got %r)" % spec)
    nid = find_node(workflow, name)
    inputs = workflow[nid].setdefault("inputs", {})
    old = inputs.get(input_name)
    if isinstance(old, bool):
        value = value.lower() in ("1", "true", "yes")
    elif isinstance(old, int):
        value = int(value)
    elif isinstance(old, float):
        value = float(value)
    inputs[input_name] = value
    return nid


def enum_options(object_info, class_type, input_name):
    """The allowed values for an enum-typed input (ckpt_name, sampler_name,
    scheduler, lora_name, ...), or None when the input isn't an enum."""
    node = (object_info or {}).get(class_type) or {}
    spec = ((node.get("input") or {}).get("required") or {}).get(input_name)
    if not spec:
        spec = ((node.get("input") or {}).get("optional") or {}).get(input_name)
    if isinstance(spec, list) and spec and isinstance(spec[0], list):
        return spec[0]
    return None


def validate_enums(workflow, object_info, touched):
    """For every input we SET, if the server declares it as an enum, check the
    value is offered. Returns a list of human-readable problems (empty = ok):
    a bad checkpoint name fails here in milliseconds instead of after a queue
    round trip, and the message names what IS available."""
    problems = []
    for nid, input_name in touched:
        node = workflow.get(nid) or {}
        options = enum_options(object_info, node.get("class_type"), input_name)
        if options is None:
            continue
        value = (node.get("inputs") or {}).get(input_name)
        if isinstance(value, list):  # a link, not a literal
            continue
        if value not in options:
            problems.append(
                "node %s (%s).%s = %r is not offered by this server. Available: %s"
                % (nid, node.get("class_type"), input_name, value, ", ".join(map(str, options))))
    return problems


def _api(port, path, payload=None, timeout=30):
    url = (BASE % port) + path
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode() or "{}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workflow")  # required except for --list-models
    ap.add_argument("--prompt")
    ap.add_argument("--prompt-node")
    ap.add_argument("--port", type=int, default=8188)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--out")
    ap.add_argument("--set", action="append", default=[], dest="sets",
                    metavar="NAME.INPUT=VALUE",
                    help="set an existing input's value by node id or _meta.title (repeatable)")
    ap.add_argument("--list-models", action="store_true",
                    help="print the checkpoints this ComfyUI offers, then exit")
    args = ap.parse_args()

    if not args.workflow and not args.list_models:
        print("ERROR: --workflow is required (except with --list-models)")
        return 2

    if args.list_models:
        try:
            info = _api(args.port, "/object_info/CheckpointLoaderSimple")
        except (urllib.error.URLError, OSError) as e:
            print("ERROR: ComfyUI unreachable on 127.0.0.1:%d — %s" % (args.port, e))
            return 1
        for name in (enum_options(info, "CheckpointLoaderSimple", "ckpt_name") or []):
            print(name)
        return 0

    with open(args.workflow) as f:
        workflow = json.load(f)
    # ComfyUI's /prompt accepts ONLY the API format (a flat map of
    # node-id -> {class_type, inputs}). A UI save carries nodes/links arrays
    # and is silently unusable here — say so with the exact fix.
    if not isinstance(workflow, dict) or "nodes" in workflow or "links" in workflow:
        print("ERROR: %s is not API format (it looks like a UI workflow save with "
              "nodes/links arrays). ComfyUI's /prompt endpoint accepts only the API "
              "format. In ComfyUI: Workflow -> Export (API) (older builds: enable "
              "Settings -> Dev mode, then 'Save (API Format)'), and point --workflow "
              "at that file." % args.workflow)
        return 2
    if args.prompt is not None:
        nid = substitute_prompt(workflow, args.prompt, args.prompt_node)
        print("prompt -> node %s" % nid)
    touched = []
    for spec in args.sets:
        try:
            nid = apply_set(workflow, spec)
        except (KeyError, ValueError) as e:
            print("ERROR: %s" % e)
            return 2
        touched.append((nid, spec.split("=", 1)[0].rpartition(".")[2]))
        print("set %s -> node %s" % (spec.split("=", 1)[0], nid))

    # fail fast on an unavailable checkpoint/sampler/etc, naming the options
    if touched:
        try:
            problems = validate_enums(workflow, _api(args.port, "/object_info"), touched)
        except (urllib.error.URLError, OSError) as e:
            print("ERROR: ComfyUI unreachable on 127.0.0.1:%d — %s" % (args.port, e))
            return 1
        if problems:
            for p in problems:
                print("ERROR: %s" % p)
            return 2

    try:
        resp = _api(args.port, "/prompt", {"prompt": workflow})
    except (urllib.error.URLError, OSError) as e:
        print("ERROR: ComfyUI unreachable on 127.0.0.1:%d — %s" % (args.port, e))
        return 1
    prompt_id = resp.get("prompt_id")
    if not prompt_id:
        print("ERROR: ComfyUI rejected the workflow: %s" % json.dumps(resp)[:500])
        return 1
    print("queued prompt_id %s" % prompt_id)

    deadline = time.time() + args.timeout
    history = None
    while time.time() < deadline:
        hist = _api(args.port, "/history/" + prompt_id)
        if prompt_id in hist:
            history = hist[prompt_id]
            break
        time.sleep(2)
    if history is None:
        print("ERROR: timed out after %ss waiting for prompt %s" % (args.timeout, prompt_id))
        return 1

    status = (history.get("status") or {}).get("status_str", "")
    if status == "error":
        print("ERROR: ComfyUI reported an execution error: %s" %
              json.dumps(history.get("status"))[:500])
        return 1
    # download every produced image through ComfyUI's own /view endpoint into
    # --out (default cwd = the job workdir), so remote-compute job-pull can
    # rsync them back without knowing ComfyUI's filesystem layout
    import os
    import urllib.parse
    out_dir = args.out or "."
    os.makedirs(out_dir, exist_ok=True)
    artifacts = 0
    for node_out in (history.get("outputs") or {}).values():
        for img in node_out.get("images", []):
            q = urllib.parse.urlencode({"filename": img["filename"],
                                        "subfolder": img.get("subfolder") or "",
                                        "type": img.get("type") or "output"})
            dest = os.path.join(out_dir, img["filename"])
            try:
                with urllib.request.urlopen((BASE % args.port) + "/view?" + q,
                                            timeout=60) as r, open(dest, "wb") as f:
                    shutil.copyfileobj(r, f)
                print("ARTIFACT %s" % dest)
                artifacts += 1
            except (urllib.error.URLError, OSError) as e:
                print("ERROR: could not download %s: %s" % (img["filename"], e))
    if not artifacts:
        print("NOTE: prompt finished but produced no image outputs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
