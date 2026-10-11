#!/usr/bin/env python3
"""Import a trusted, bounded core-txt2img-v1 UI save without executing it.

The profile is a reviewed serializer contract, not frontend autodetection.
See docs/remote-compute.md and tests/fixtures/comfy-import/README.md for evidence.
Only GET /object_info is used; --object-info is entirely offline. Stdlib only.
"""
import argparse
from collections import deque
import http.client
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import sys
import tempfile
import threading

MAX_BYTES = 4 * 1024 * 1024
MAX_NODES = 1024
MAX_LINKS = 8192
TIMEOUT = 5
GUIDANCE = "Use ComfyUI: Workflow -> Export (API) for unsupported workflows."

# Widget order comes from the reviewed frontend, never object_info map order.
# Each profile is (widget names/types, connection names/types, output variants).
PROFILES = {
    "CheckpointLoaderSimple": (
        [("ckpt_name", "ENUM")], {}, [("MODEL", "CLIP", "VAE")]),
    "CLIPTextEncode": (
        [("text", "STRING")], {"clip": "CLIP"}, [("CONDITIONING",)]),
    "EmptyLatentImage": (
        [("width", "INT"), ("height", "INT"), ("batch_size", "INT")],
        {}, [("LATENT",)]),
    "KSampler": (
        [("seed", "INT"), ("control_after_generate", "CONTROL"),
         ("steps", "INT"), ("cfg", "FLOAT"), ("sampler_name", "ENUM"),
         ("scheduler", "ENUM"), ("denoise", "FLOAT")],
        {"model": "MODEL", "positive": "CONDITIONING",
         "negative": "CONDITIONING", "latent_image": "LATENT"}, [("LATENT",)]),
    "VAEDecode": ([], {"samples": "LATENT", "vae": "VAE"}, [("IMAGE",)]),
    "SaveImage": ([("filename_prefix", "STRING")], {"images": "IMAGE"},
                  [(), ("IMAGE",)]),
    "PreviewImage": ([], {"images": "IMAGE"}, [(), ("IMAGE",)]),
}

# Presence of these options opts into frontend behavior at a specific widget.
SITE_FLAGS = {
    ("CLIPTextEncode", "text"): {"multiline": True, "dynamicPrompts": True},
    ("KSampler", "seed"): {"control_after_generate": True},
}
SITE_NUMERIC_OPTIONS = {
    ("EmptyLatentImage", "width"): {"step"},
    ("EmptyLatentImage", "height"): {"step"},
    ("KSampler", "cfg"): {"step", "round"},
    ("KSampler", "denoise"): {"step"},
}


class Invalid(ValueError):
    """Invalid data or an unsupported serialization shape."""


def require(condition, where, message):
    if not condition:
        raise Invalid("%s: %s" % (where, message))


def mapping(value, where):
    require(isinstance(value, dict), where, "expected an object")
    return value


def fields(value, allowed, where):
    mapping(value, where)
    unknown = set(value) - set(allowed)
    require(not unknown, where, "unsupported field(s): " + ", ".join(sorted(unknown)))


def integer(value):
    return type(value) is int


def number(value):
    return type(value) in (int, float) and (integer(value) or math.isfinite(value))


def identity(value, where, node=False):
    valid = integer(value) and 0 <= value <= 9007199254740991
    if node and isinstance(value, str):
        valid = bool(re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value))
    require(valid, where, "invalid id")
    return value


def strict_json(data, where):
    require(len(data) <= MAX_BYTES, where, "JSON exceeds 4 MiB")

    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, where, "duplicate JSON key " + repr(key))
            result[key] = value
        return result

    def nonfinite(value):
        raise Invalid("%s: nonfinite JSON number %s" % (where, value))

    def floating(value):
        result = float(value)
        return result if math.isfinite(result) else nonfinite(value)

    try:
        result = json.loads(data.decode("utf-8"), object_pairs_hook=pairs,
                            parse_constant=nonfinite, parse_float=floating)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise Invalid("%s: invalid JSON (%s)" % (where, exc)) from exc
    mapping(result, where)
    # Bound nested metadata too, and reject unpaired UTF-16 surrogates in JSON strings.
    pending = [(result, 0)]
    while pending:
        value, depth = pending.pop()
        require(depth <= 64, where, "JSON nesting exceeds 64")
        if isinstance(value, dict):
            pending.extend((item, depth + 1) for item in value.keys())
            pending.extend((item, depth + 1) for item in value.values())
        elif isinstance(value, list):
            pending.extend((item, depth + 1) for item in value)
        elif isinstance(value, str):
            require(not any(0xD800 <= ord(c) <= 0xDFFF for c in value),
                    where, "unpaired Unicode surrogate")
    return result


def read_json(path):
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NONBLOCK", 0))
    with os.fdopen(fd, "rb") as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), str(path),
                "expected a regular JSON file")
        return strict_json(stream.read(MAX_BYTES + 1), str(path))


def fetch_info(port):
    # Direct HTTPConnection neither uses proxies nor follows redirects. A socket
    # timeout alone does not bound a peer that keeps trickling header/body bytes.
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=TIMEOUT)
    timer = None
    expired = threading.Event()
    try:
        connection.connect()
        transport = connection.sock

        def expire():
            expired.set()
            try:
                transport.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        timer = threading.Timer(TIMEOUT, expire)
        timer.daemon = True
        timer.start()
        connection.request("GET", "/object_info")
        with connection.getresponse() as response:
            if response.status != 200:
                raise OSError("object_info HTTP status %d (redirects disabled)" % response.status)
            data = response.read(MAX_BYTES + 1)
        if expired.is_set():
            raise OSError("object_info response exceeded timeout")
        return strict_json(data, "object_info")
    finally:
        if timer is not None:
            timer.cancel()
            timer.join()
        connection.close()


def validate_options(opts, kind, name, input_kind, widget, spec, where):
    flags = SITE_FLAGS.get((kind, name), {})
    numeric_options = SITE_NUMERIC_OPTIONS.get((kind, name), set())
    allowed = {"tooltip"} | set(flags) | numeric_options
    if widget:
        allowed.add("default")
    if input_kind in ("INT", "FLOAT"):
        allowed.update(("min", "max"))
    fields(opts, allowed, where + ".options")
    if "tooltip" in opts:
        require(isinstance(opts["tooltip"], str), where, "tooltip must be a string")
    for flag, expected in flags.items():
        if flag in opts:
            require(opts[flag] is expected, where, "unsupported " + flag + " option")
    for bound in ("min", "max"):
        if bound in opts:
            require(integer(opts[bound]) if input_kind == "INT" else number(opts[bound]),
                    where, "invalid numeric " + bound)
    if "min" in opts and "max" in opts:
        require(opts["min"] <= opts["max"], where, "inverted numeric bounds")
    for option in numeric_options:
        if option in opts:
            require(number(opts[option]) and opts[option] > 0, where,
                    option + " must be a positive finite number")
    if "default" in opts:
        literal(opts["default"], input_kind, spec, where + ".default")


def schema_for(info, kind, where):
    widgets, connections, variants = PROFILES[kind]
    schema = mapping(info.get(kind), where + ".object_info")
    require(schema.get("python_module", "nodes") == "nodes", where,
            "object_info identifies a custom package")
    require(schema.get("input_is_list", False) is False, where,
            "input_is_list must be false")
    output_node = kind in ("SaveImage", "PreviewImage")
    require(schema.get("output_node", output_node) is output_node, where,
            "output_node differs from profile")
    inputs = schema.get("input")
    fields(inputs, ("required", "optional", "hidden"), where + ".object_info.input")
    required = mapping(inputs.get("required"), where + ".object_info.required")
    optional = mapping(inputs.get("optional", {}), where + ".object_info.optional")
    require(not optional, where, "unsupported optional inputs")
    hidden = mapping(inputs.get("hidden", {}), where + ".object_info.hidden")
    allowed_hidden = {"prompt": "PROMPT", "extra_pnginfo": "EXTRA_PNGINFO"}
    require(all(key in allowed_hidden and value == allowed_hidden[key]
                for key, value in hidden.items()), where, "unsupported hidden inputs")
    expected = dict(connections)
    expected.update((name, kind) for name, kind in widgets if kind != "CONTROL")
    require(set(required) == set(expected), where,
            "required schema inputs differ from profile")
    for name, expected_kind in expected.items():
        spec = required[name]
        at = where + "." + name
        require(isinstance(spec, list) and 1 <= len(spec) <= 2, at, "invalid input schema")
        opts = mapping(spec[1] if len(spec) == 2 else {}, at + ".options")
        actual = spec[0]
        if expected_kind == "ENUM":
            require(isinstance(actual, list) and bool(actual)
                    and all(isinstance(v, str) for v in actual)
                    and len(set(actual)) == len(actual), at, "expected string enum schema")
        else:
            require(actual == expected_kind, at, "input type differs from profile")
        validate_options(opts, kind, name, expected_kind, name not in connections, spec, at)
    outputs = schema.get("output")
    require(isinstance(outputs, list) and tuple(outputs) in variants, where,
            "output schema differs from profile")
    lists = schema.get("output_is_list", [False] * len(outputs))
    require(isinstance(lists, list) and len(lists) == len(outputs)
            and all(v is False for v in lists), where, "unsupported list outputs")
    return required, outputs


def literal(value, kind, spec, where):
    opts = spec[1] if len(spec) == 2 else {}
    if kind == "ENUM":
        require(isinstance(value, str) and value in spec[0], where,
                "value is not in the server enum")
    elif kind == "STRING":
        require(isinstance(value, str), where, "expected string")
    elif kind == "INT":
        require(integer(value), where, "expected integer (not boolean)")
    elif kind == "FLOAT":
        require(number(value), where, "expected finite number")
    if kind in ("INT", "FLOAT"):
        for bound in ("min", "max"):
            if bound in opts:
                require(value >= opts[bound] if bound == "min" else value <= opts[bound],
                        where, "value outside server " + bound)
    return value


def convert(workflow, info):
    fields(workflow, ("version", "nodes", "links", "last_node_id", "last_link_id",
                      "groups", "config", "extra", "definitions", "reroutes", "id",
                      "revision"), "workflow")
    require(type(workflow.get("version")) in (int, float)
            and workflow["version"] == 0.4, "version", "requires numeric workflow v0.4")
    require(not workflow.get("definitions"), "definitions", "subgraphs unsupported")
    require(not workflow.get("reroutes"), "reroutes", "reroutes unsupported")
    fields(workflow.get("config", {}), (), "config")
    fields(workflow.get("extra", {}), ("ds", "frontendVersion"), "extra")
    nodes = workflow.get("nodes")
    links = workflow.get("links")
    require(isinstance(nodes, list) and 1 <= len(nodes) <= MAX_NODES,
            "nodes", "expected 1..1024 nodes")
    require(isinstance(links, list) and len(links) <= MAX_LINKS,
            "links", "expected at most 8192 six-field links")
    by_id, ids, api, input_refs, output_refs = {}, set(), {}, {}, {}
    for node in nodes:
        mapping(node, "node")
        nid = identity(node.get("id"), "node.id", node=True)
        where = "node %s" % nid
        require(nid not in ("nodes", "links"), where + ".id",
                "reserved API runner id")
        require(str(nid) not in ids, where, "duplicate or colliding node id")
        ids.add(str(nid))
        fields(node, ("id", "type", "pos", "size", "flags", "order", "mode",
                      "inputs", "outputs", "properties", "widgets_values", "title",
                      "color", "bgcolor", "shape"), where)
        kind = node.get("type")
        require(isinstance(kind, str) and kind in PROFILES, where,
                "unsupported node class " + repr(kind))
        require(integer(node.get("mode")) and node["mode"] == 0, where + ".mode",
                "only mode 0 is supported")
        fields(node.get("flags", {}), ("collapsed", "pinned"), where + ".flags")
        props = node.get("properties", {})
        fields(props, ("Node name for S&R", "cnr_id", "ver"), where + ".properties")
        require(props.get("cnr_id", "comfy-core") == "comfy-core", where,
                "custom package metadata unsupported")
        for key, value in props.items():
            require(isinstance(value, str), where + ".properties." + key, "expected string")
        widgets, connections, _ = PROFILES[kind]
        schema, signature = schema_for(info, kind, where)
        values = node.get("widgets_values", [])
        require(isinstance(values, list) and len(values) == len(widgets),
                where + ".widgets_values", "widget count/shape differs from profile")
        authored = {}
        for (name, widget_kind), value in zip(widgets, values):
            at = where + "." + name
            if widget_kind == "CONTROL":
                require(value == "fixed", at, "only fixed seed control is supported")
                continue
            authored[name] = literal(value, widget_kind, schema[name], at)
            if kind == "CLIPTextEncode" and name == "text":
                require(not any(token in value for token in ("{", "}", "__", "//", "/*", "*/")),
                        at, "dynamic prompts/comments unsupported")
                trailing_slashes = len(value) - len(value.rstrip("\\"))
                require("\\|" not in value and trailing_slashes % 2 == 0,
                        at, "dynamic-prompt escape syntax unsupported")
            if kind == "SaveImage" and name == "filename_prefix":
                require(not re.search(r"%[^%]+%", value), at,
                        "filename substitution tokens unsupported")
        inputs = node.get("inputs", [])
        outputs = node.get("outputs", [])
        require(isinstance(inputs, list), where + ".inputs", "expected slot array")
        require(isinstance(outputs, list) and len(outputs) == len(signature),
                where + ".outputs", "saved outputs differ from server schema")
        seen = set()
        for slot, inp in enumerate(inputs):
            at = where + ".inputs[%d]" % slot
            fields(inp, ("name", "type", "link", "label", "localized_name", "shape"), at)
            name = inp.get("name")
            require(isinstance(name, str) and name in connections and name not in seen,
                    at, "duplicate/unsupported input or converted widget")
            seen.add(name)
            require(inp.get("type") == connections[name], at, "input type mismatch")
            input_refs[(nid, slot)] = identity(inp.get("link"), at + ".link")
        require(seen == set(connections), where + ".inputs", "missing required connections")
        for slot, out in enumerate(outputs):
            at = where + ".outputs[%d]" % slot
            fields(out, ("name", "type", "links", "slot_index", "label", "localized_name", "shape"), at)
            require(out.get("type") == signature[slot], at, "output type mismatch")
            if "slot_index" in out:
                require(integer(out["slot_index"]) and out["slot_index"] == slot,
                        at, "output slot_index mismatch")
            refs = out.get("links")
            if refs is None:
                refs = []
            require(isinstance(refs, list), at + ".links", "expected link ids")
            for ref in refs:
                identity(ref, at + ".links")
            require(len(refs) == len(set(refs)), at + ".links", "duplicate link reference")
            output_refs[(nid, slot)] = set(refs)
        entry = {"class_type": kind, "inputs": authored}
        if "title" in node:
            require(isinstance(node["title"], str), where + ".title", "expected string")
            entry["_meta"] = {"title": node["title"]}
        by_id[nid] = node
        api[str(nid)] = entry

    used_links, destinations = set(), set()
    actual_outputs = {key: set() for key in output_refs}
    incoming = dict.fromkeys(by_id, 0)
    outgoing = {nid: [] for nid in by_id}
    for index, link in enumerate(links):
        where = "link[%d]" % index
        require(isinstance(link, list) and len(link) == 6, where, "expected six fields")
        lid, src, src_slot, dst, dst_slot, kind = link
        identity(lid, where + ".id")
        identity(src, where + ".source id", node=True)
        identity(dst, where + ".destination id", node=True)
        require(lid not in used_links, where, "duplicate link id")
        used_links.add(lid)
        require(src in by_id and dst in by_id, where, "dangling node id")
        require(integer(src_slot) and (src, src_slot) in output_refs,
                where, "source slot out of bounds")
        require(integer(dst_slot) and (dst, dst_slot) in input_refs,
                where, "destination slot out of bounds")
        require((dst, dst_slot) not in destinations, where, "duplicate destination assignment")
        destinations.add((dst, dst_slot))
        inp = by_id[dst]["inputs"][dst_slot]
        out = by_id[src]["outputs"][src_slot]
        require(kind == inp["type"] == out["type"], where, "incompatible link types")
        require(input_refs[(dst, dst_slot)] == lid, where, "input link reference mismatch")
        actual_outputs[(src, src_slot)].add(lid)
        api[str(dst)]["inputs"][inp["name"]] = [str(src), src_slot]
        outgoing[src].append(dst)
        incoming[dst] += 1
    require(destinations == set(input_refs), "links", "missing required input links")
    for key, refs in output_refs.items():
        require(refs == actual_outputs[key], "node %s.outputs[%s]" % key,
                "output link references disagree with top-level links")
    queue = deque(nid for nid, count in incoming.items() if count == 0)
    visited = 0
    while queue:
        visited += 1
        for dst in outgoing[queue.popleft()]:
            incoming[dst] -= 1
            if incoming[dst] == 0:
                queue.append(dst)
    require(visited == len(nodes), "links", "cycle in workflow")
    return api


def publish(output, data):
    # Same-directory hard-link publication is atomic and refuses existing paths,
    # including dangling symlinks. Nothing final is visible during a failed write.
    output = Path(output)
    fd, temporary = tempfile.mkstemp(prefix=".comfy-import-", dir=output.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, output)
    finally:
        try:
            os.unlink(temporary)
        except OSError as exc:
            # Publication has committed if link succeeded. Otherwise preserve the
            # original write/link exception rather than replacing it with cleanup.
            print("WARNING: temporary-file cleanup failed for %s: %s" %
                  (temporary, exc), file=sys.stderr)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        super().error(message + ". " + GUIDANCE)


def main():
    parser = Parser(description=__doc__)
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--profile", required=True, choices=["core-txt2img-v1"])
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--port", type=int, default=8188)
    source.add_argument("--object-info")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    try:
        workflow = read_json(args.workflow)
        info = read_json(args.object_info) if args.object_info else fetch_info(args.port)
        result = convert(workflow, info)
        data = (json.dumps(result, ensure_ascii=True, allow_nan=False, indent=2) + "\n").encode("utf-8")
        require(len(data) <= MAX_BYTES, "output", "API JSON exceeds 4 MiB")
        publish(args.output, data)
    except Invalid as exc:
        print("ERROR: %s. %s" % (exc, GUIDANCE), file=sys.stderr)
        return 2
    except (OSError, http.client.HTTPException) as exc:
        print("ERROR: service/I/O failure: %s. %s" % (exc, GUIDANCE), file=sys.stderr)
        return 1
    print("ARTIFACT %s" % args.output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
