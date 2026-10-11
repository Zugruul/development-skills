"""Behavioral contract for the explicit, non-executing ComfyUI importer."""
import contextlib
import copy
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import yaml

BUNDLE = Path(__file__).resolve().parents[1] / "scripts/remote-capabilities/comfyui"
FIX = Path(__file__).resolve().parent / "fixtures/comfy-import"
HELPER = BUNDLE / "comfy-import.py"
GUIDANCE = "Workflow -> Export (API)"


class ImportTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.ui = json.loads((FIX / "ui.json").read_text())
        self.info = json.loads((FIX / "object-info.json").read_text())
        self.expected = json.loads((FIX / "api.json").read_text())
        self.source = self.root / "ui.json"
        self.schema = self.root / "info.json"
        self.output = self.root / "api.json"

    def args(self, online=None):
        return ["--workflow", str(self.source), "--output", str(self.output),
                "--profile", "core-txt2img-v1"] + (
                    ["--port", str(online)] if online else
                    ["--object-info", str(self.schema)])

    def save(self):
        self.source.write_text(json.dumps(self.ui), encoding="utf-8")
        self.schema.write_text(json.dumps(self.info), encoding="utf-8")

    def run_cli(self, online=None):
        self.save()
        return self.raw_cli(self.args(online))

    def raw_cli(self, args):
        return subprocess.run([sys.executable, str(HELPER)] + args,
                              capture_output=True, text=True, timeout=15)

    def refused(self, result, context=None, code=2):
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertIn(GUIDANCE, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        if context:
            self.assertIn(context, result.stderr)
        self.assertFalse(self.output.exists())

    def load_helper(self):
        self.assertTrue(HELPER.is_file(), "standalone importer must exist")
        spec = importlib.util.spec_from_file_location("comfy_import", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    @contextlib.contextmanager
    def server(self, redirect=False, body=None, render=False):
        calls = []
        schema = json.dumps(self.info).encode() if body is None else body

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                calls.append(("GET", self.path))
                if redirect:
                    self.send_response(302)
                    self.send_header("Location", "/must-not-follow")
                    self.end_headers()
                    return
                self.send_response(200)
                self.end_headers()
                if self.path == "/history/test":
                    self.wfile.write(b'{"test":{"status":{"status_str":"success"},"outputs":{}}}')
                else:
                    try:
                        self.wfile.write(schema)
                    except (BrokenPipeError, ConnectionResetError):
                        pass

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                calls.append(("POST", self.path, json.loads(self.rfile.read(length))))
                self.send_response(200 if render else 405)
                self.end_headers()
                self.wfile.write(b'{"prompt_id":"test"}')

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server.server_port, calls
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_exact_pair_and_preserved_source(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text()), self.expected)
        self.assertEqual(json.loads(self.source.read_text()), self.ui)
        self.assertIn("ARTIFACT " + str(self.output), result.stdout)

    def test_schema_order_is_not_widget_order(self):
        for schema in self.info.values():
            req = schema["input"]["required"]
            schema["input"]["required"] = dict(reversed(list(req.items())))
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text()), self.expected)

    def test_legacy_output_variant_requires_matching_schema(self):
        for node in self.ui["nodes"]:
            if node["type"] in ("SaveImage", "PreviewImage"):
                node["outputs"] = []
                self.info[node["type"]]["output"] = []
                self.info[node["type"]]["output_is_list"] = []
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text()), self.expected)

    def test_required_profile_and_port_range(self):
        self.save()
        for args in (self.args()[:4], self.args()[:5] + ["auto"],
                     self.args()[:6] + ["--port", "0"],
                     self.args()[:6] + ["--port", "65536"]):
            with self.subTest(args=args):
                self.refused(self.raw_cli(args))

    def test_graph_refusals(self):
        cases = [
            ("version", lambda g: g.update(version="0.4")),
            ("nodes", lambda g: g.update(nodes=[])),
            ("nodes", lambda g: g.update(nodes=[g["nodes"][0]] * 1025)),
            ("links", lambda g: g.update(links=g["links"] * 820)),
            ("definitions", lambda g: g.update(definitions={"subgraphs": [{}]})),
            ("reroutes", lambda g: g.update(reroutes=[{}])),
            ("node 4", lambda g: g["nodes"][0].update(type="PrimitiveNode")),
            ("node 4", lambda g: g["nodes"][0].update(type="Reroute")),
            ("node 4", lambda g: g["nodes"][0].update(type="CustomLoader")),
            ("node 4", lambda g: g["nodes"][0].update(mode=2)),
            ("node 4", lambda g: g["nodes"][0].update(mode=4)),
            ("node 4", lambda g: g["nodes"][0].update(mode=False)),
            ("node 4", lambda g: g["nodes"][0].update(isVirtualNode=True)),
            ("node 4", lambda g: g["nodes"][0].update(serialize_widgets=False)),
            ("node 4", lambda g: g["nodes"][0]["properties"].update(cnr_id="custom-package")),
            ("node 4", lambda g: g["nodes"][0]["properties"].update(aux_id="author/custom")),
            ("node 4", lambda g: g["nodes"][0]["properties"].update(widget_ue_connectable={})),
            ("node 4", lambda g: g["nodes"][0].update(widgets_values={})),
            ("node 4", lambda g: g["nodes"][0]["widgets_values"].append("extra")),
            ("node 4", lambda g: g["nodes"][0].update(title=[])),
            ("node 6", lambda g: g["nodes"][1]["inputs"].append({"name": "text", "type": "STRING", "link": None, "widget": {"name": "text"}})),
            ("node 6", lambda g: g["nodes"][1]["inputs"].append(copy.deepcopy(g["nodes"][1]["inputs"][0]))),
            ("node 6", lambda g: g["nodes"][1]["inputs"][0].update(link=None)),
            ("node 4", lambda g: g["nodes"].append(copy.deepcopy(g["nodes"][0]))),
            ("id", lambda g: g["nodes"][0].update(id=True)),
            ("id", lambda g: g["nodes"][0].update(id=4.0)),
            ("id", lambda g: g["nodes"][0].update(id="4")),
            ("link", lambda g: g["links"].append(g["links"][0])),
            ("link", lambda g: g["links"][0].append("extra")),
            ("link", lambda g: g["links"][0].__setitem__(1, 999)),
            ("link", lambda g: g["links"][0].__setitem__(2, 99)),
            ("link", lambda g: g["links"][0].__setitem__(4, -1)),
            ("link", lambda g: g["links"][0].__setitem__(2, False)),
            ("link", lambda g: g["links"][0].__setitem__(5, "IMAGE")),
            ("link", lambda g: g["links"].append([11, 4, 0, 3, 0, "MODEL"])),
            ("node 4", lambda g: g["nodes"][0]["outputs"][0].update(links=[])),
            ("node 4", lambda g: g["nodes"][0]["outputs"][0].update(links=[1, 1])),
            ("node 4", lambda g: g["nodes"][0]["outputs"][0].update(slot_index=1)),
            ("node 9", lambda g: g["nodes"][6].update(outputs=[])),
        ]
        original = copy.deepcopy(self.ui)
        for context, mutate in cases:
            with self.subTest(context=context, mutation=cases.index((context, mutate))):
                self.ui = copy.deepcopy(original)
                mutate(self.ui)
                self.refused(self.run_cli(), context)

    def test_cycle_with_consistent_link_references(self):
        self.ui["links"][5] = [6, 3, 0, 3, 3, "LATENT"]
        self.ui["nodes"][3]["outputs"][0]["links"] = []
        self.ui["nodes"][4]["outputs"][0]["links"].append(6)
        self.refused(self.run_cli(), "cycle")

    def test_invalid_widget_literals(self):
        original = copy.deepcopy(self.ui)
        cases = [(4, 0, True), (4, 0, -1), (4, 0, 18446744073709551616),
                 (4, 1, True), (4, 1, "randomize"), (4, 1, "increment"),
                 (4, 2, 0), (4, 2, 1.5), (4, 3, "7.5"), (4, 3, -1),
                 (4, 4, "invented"), (4, 5, []), (4, 6, 1.1),
                 (3, 0, False), (3, 1, 8), (3, 2, 0), (0, 0, "missing.ckpt"),
                 (1, 0, ["text"]), (1, 0, "{red|blue}"),
                 (1, 0, "__wildcard__"), (1, 0, "hello // stripped comment"),
                 (1, 0, "hello /* comment */"),
                 (6, 0, "%date:yyyy-MM-dd%"), (6, 0, "%Sampler.seed%")]
        for node, widget, value in cases:
            with self.subTest(node=node, widget=widget, value=value):
                self.ui = copy.deepcopy(original)
                self.ui["nodes"][node]["widgets_values"][widget] = value
                self.refused(self.run_cli(), "node " + str(self.ui["nodes"][node]["id"]))

    def test_schema_drift(self):
        original = copy.deepcopy(self.info)
        cases = [
            lambda s: s["KSampler"]["input"]["required"].update(new_input=["INT"]),
            lambda s: s["KSampler"]["input"].update(optional={"new_input": ["INT"]}),
            lambda s: s["KSampler"]["input"]["required"].pop("seed"),
            lambda s: s["KSampler"]["input"]["required"].update(seed=["FLOAT"]),
            lambda s: s["KSampler"]["input"]["required"].update(seed=["INT", {"min": True}]),
            lambda s: s["KSampler"]["input"]["required"]["seed"][1].update(forceInput=True),
            lambda s: s["KSampler"].update(output=["IMAGE"]),
            lambda s: s["KSampler"].update(output_is_list=[True]),
            lambda s: s["KSampler"].update(python_module="custom_nodes.fake"),
            lambda s: s["SaveImage"].update(output=[]),
            lambda s: s["SaveImage"]["input"].update(hidden={"secret": "UNKNOWN"}),
            lambda s: s.update(KSampler=[]),
        ]
        for index, mutate in enumerate(cases):
            with self.subTest(index=index):
                self.info = copy.deepcopy(original)
                mutate(self.info)
                self.refused(self.run_cli(), "node")

    def test_behavioral_schema_options_are_validated_at_each_input(self):
        original = copy.deepcopy(self.info)
        cases = [
            ("SaveImage", "filename_prefix", "dynamicPrompts", True),
            ("SaveImage", "filename_prefix", "dynamicPrompts", False),
            ("SaveImage", "filename_prefix", "multiline", True),
            ("CLIPTextEncode", "clip", "dynamicPrompts", True),
            ("KSampler", "seed", "dynamicPrompts", True),
            ("CLIPTextEncode", "text", "dynamicPrompts", "true"),
            ("CLIPTextEncode", "text", "dynamicPrompts", 1),
            ("CLIPTextEncode", "text", "dynamicPrompts", False),
            ("CLIPTextEncode", "text", "multiline", []),
            ("CLIPTextEncode", "text", "multiline", 1),
            ("CLIPTextEncode", "text", "multiline", False),
            ("KSampler", "seed", "control_after_generate", "true"),
            ("KSampler", "seed", "control_after_generate", False),
            ("KSampler", "steps", "control_after_generate", True),
            ("KSampler", "seed", "advanced", True),
            ("CLIPTextEncode", "text", "advanced", False),
            ("KSampler", "seed", "display", "slider"),
            ("KSampler", "cfg", "display", []),
            ("KSampler", "seed", "default", True),
            ("KSampler", "seed", "default", -1),
            ("KSampler", "model", "default", "invented"),
            ("SaveImage", "filename_prefix", "default", 123),
            ("CheckpointLoaderSimple", "ckpt_name", "default", "missing.ckpt"),
            ("KSampler", "cfg", "step", False),
            ("KSampler", "cfg", "step", 0),
            ("KSampler", "cfg", "step", -0.1),
            ("KSampler", "cfg", "round", -0.01),
            ("EmptyLatentImage", "width", "round", 1),
            ("KSampler", "model", "step", 1),
            ("KSampler", "seed", "min", 0.5),
            ("KSampler", "model", "tooltip", []),
        ]
        self.ui["nodes"][6]["widgets_values"][0] = "{red|blue}"
        for node_class, name, option, value in cases:
            with self.subTest(node=node_class, input=name, option=option, value=value):
                self.output.unlink(missing_ok=True)
                self.info = copy.deepcopy(original)
                self.info[node_class]["input"]["required"][name][1][option] = value
                self.refused(self.run_cli(), name)

    def test_schema_list_and_output_flags_have_boolean_types_and_profile_values(self):
        original = copy.deepcopy(self.info)
        for node_class, option, value in [
                ("KSampler", "input_is_list", 0),
                ("KSampler", "input_is_list", []),
                ("KSampler", "output_node", True),
                ("SaveImage", "output_node", False),
                ("SaveImage", "output_node", 1)]:
            with self.subTest(node=node_class, option=option, value=value):
                self.output.unlink(missing_ok=True)
                self.info = copy.deepcopy(original)
                self.info[node_class][option] = value
                self.refused(self.run_cli(), "node")

    def test_reviewed_schema_options_still_preserve_authored_values(self):
        self.info["KSampler"]["input"]["required"]["cfg"][1]["round"] = 0.01
        for node_class, schema in self.info.items():
            schema["input_is_list"] = False
            schema["output_node"] = node_class in ("SaveImage", "PreviewImage")
            for spec in schema["input"]["required"].values():
                if len(spec) == 1:
                    spec.append({})
                spec[1]["tooltip"] = "Descriptive metadata"
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text()), self.expected)

    def test_source_derived_dynamic_prompt_escape_refusals(self):
        # Reviewer-supplied formatUtil.ts evidence, not an upstream runtime test:
        # final replace(/\\([{}|])/g, '$1'); handleEscape consumes the next char.
        for value in (r"left \| right", r"left \\| right", "tail" + "\\",
                      "tail" + "\\" * 3):
            with self.subTest(value=value):
                self.output.unlink(missing_ok=True)
                self.ui["nodes"][1]["widgets_values"][0] = value
                self.refused(self.run_cli(), "node 6.text")

    def test_ordinary_prompt_backslashes_are_preserved(self):
        for value in (r"C:\models\image", "tail" + "\\" * 2, "tail" + "\\" * 4):
            with self.subTest(value=value):
                self.output.unlink(missing_ok=True)
                self.ui["nodes"][1]["widgets_values"][0] = value
                self.expected["6"]["inputs"]["text"] = value
                result = self.run_cli()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.output.read_text()), self.expected)

    def rename_checkpoint(self, new_id):
        self.ui["nodes"][0]["id"] = new_id
        for link in self.ui["links"]:
            if link[1] == 4:
                link[1] = new_id
        self.expected[new_id] = self.expected.pop("4")
        for node in self.expected.values():
            for value in node["inputs"].values():
                if isinstance(value, list) and value[0] == "4":
                    value[0] = new_id

    def test_api_runner_reserved_ids_are_refused_before_publication(self):
        original_ui, original_api = copy.deepcopy(self.ui), copy.deepcopy(self.expected)
        for new_id in ("nodes", "links"):
            with self.subTest(node_id=new_id):
                self.output.unlink(missing_ok=True)
                self.ui, self.expected = copy.deepcopy(original_ui), copy.deepcopy(original_api)
                self.rename_checkpoint(new_id)
                self.refused(self.run_cli(), "node " + new_id)

    def test_other_string_ids_keep_links_and_work_with_existing_api_runner(self):
        self.rename_checkpoint("checkpoint-v1")
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text()), self.expected)
        listed = subprocess.run([sys.executable, str(BUNDLE / "comfy-run.py"),
                                 "--workflow", str(self.output), "--list-nodes"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn("checkpoint-v1", listed.stdout)

    def test_post_publication_cleanup_failure_reports_committed_success(self):
        helper = self.load_helper()
        self.save()
        with patch.object(sys, "argv", [str(HELPER)] + self.args()), \
                patch.object(os, "unlink", side_effect=PermissionError("forced cleanup refusal")), \
                contextlib.redirect_stdout(io.StringIO()) as output, \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            code = helper.main()
        self.assertEqual(code, 0, errors.getvalue())
        self.assertEqual(output.getvalue(), "ARTIFACT " + str(self.output) + "\n")
        self.assertIn("WARNING", errors.getvalue())
        self.assertIn("cleanup", errors.getvalue())
        self.assertIn("forced cleanup refusal", errors.getvalue())
        self.assertNotIn("ERROR", errors.getvalue())
        self.assertEqual(json.loads(self.output.read_text()), self.expected)
        self.assertEqual(json.loads(self.source.read_text()), self.ui)
        temporaries = list(self.root.glob(".comfy-import-*"))
        self.assertEqual(len(temporaries), 1)
        self.assertIn(str(temporaries[0]), errors.getvalue())

    def test_pre_publication_failure_is_not_masked_by_cleanup_failure(self):
        helper = self.load_helper()
        self.save()
        with patch.object(sys, "argv", [str(HELPER)] + self.args()), \
                patch.object(os, "link", side_effect=PermissionError("forced publication refusal")), \
                patch.object(os, "unlink", side_effect=PermissionError("forced cleanup refusal")), \
                contextlib.redirect_stdout(io.StringIO()) as output, \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            code = helper.main()
        self.assertEqual(code, 1, errors.getvalue())
        self.assertNotIn("ARTIFACT", output.getvalue())
        self.assertIn("forced publication refusal", errors.getvalue())
        self.assertIn("forced cleanup refusal", errors.getvalue())
        self.assertIn(GUIDANCE, errors.getvalue())
        self.assertFalse(self.output.exists())

    def test_existing_output_is_protected_even_when_cleanup_fails(self):
        helper = self.load_helper()
        self.save()
        self.output.write_bytes(b"existing artifact")
        with patch.object(sys, "argv", [str(HELPER)] + self.args()), \
                patch.object(os, "unlink", side_effect=PermissionError("forced cleanup refusal")), \
                contextlib.redirect_stdout(io.StringIO()) as output, \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            code = helper.main()
        self.assertEqual(code, 1, errors.getvalue())
        self.assertNotIn("ARTIFACT", output.getvalue())
        self.assertIn("File exists", errors.getvalue())
        self.assertEqual(self.output.read_bytes(), b"existing artifact")

    def test_strict_bounded_json_on_both_inputs(self):
        invalid = [b'{"nodes":[],"nodes":[]}', b'NaN', b'Infinity', b'1e999',
                   b'"\xff"', b'{', b'[]', b' ' * (4 * 1024 * 1024 + 1),
                   b'[' * 1100 + b'0' + b']' * 1100]
        for path in (self.source, self.schema):
            for value in invalid:
                with self.subTest(path=path.name, size=len(value)):
                    self.save()
                    path.write_bytes(value)
                    self.refused(self.raw_cli(self.args()))

    def test_existing_source_output_and_symlinks_untouched(self):
        self.save()
        source = self.source.read_bytes()
        self.output.write_bytes(b"keep existing output")
        result = self.raw_cli(self.args())
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(GUIDANCE, result.stderr)
        self.assertEqual(self.output.read_bytes(), b"keep existing output")
        self.output.unlink()
        self.output.symlink_to(self.source)
        result = self.raw_cli(self.args())
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertTrue(self.output.is_symlink())
        self.assertEqual(self.source.read_bytes(), source)
        self.output.unlink()
        self.output.symlink_to(self.root / "absent.json")
        self.assertEqual(self.raw_cli(self.args()).returncode, 1)
        self.assertTrue(self.output.is_symlink())
        self.output = self.source
        self.assertEqual(self.raw_cli(self.args()).returncode, 1)
        self.assertEqual(self.source.read_bytes(), source)

    def test_offline_never_opens_network(self):
        helper = self.load_helper()
        self.save()
        with patch.object(sys, "argv", [str(HELPER)] + self.args()), \
                patch.object(socket, "socket", side_effect=AssertionError("network forbidden")), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(helper.main(), 0)
        self.assertEqual(json.loads(self.output.read_text()), self.expected)

    def test_failed_publication_leaves_no_final_or_temporary_output(self):
        helper = self.load_helper()
        self.save()
        before = set(self.root.iterdir())
        with patch.object(sys, "argv", [str(HELPER)] + self.args()), \
                patch.object(os, "fsync", side_effect=OSError("forced write failure")), \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(helper.main(), 1)
        self.assertIn("forced write failure", errors.getvalue())
        self.assertEqual(set(self.root.iterdir()), before)

    def test_loopback_get_only(self):
        with self.server() as (port, calls):
            result = self.run_cli(port)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [("GET", "/object_info")])
        self.assertEqual(json.loads(self.output.read_text()), self.expected)

    def test_redirect_refusal(self):
        with self.server(redirect=True) as (port, calls):
            self.refused(self.run_cli(port), code=1)
        self.assertEqual(calls, [("GET", "/object_info")])

    def test_bounded_http_json(self):
        for data in (b'x' * (4 * 1024 * 1024 + 1), b'{"a":1,"a":2}', b'NaN'):
            with self.subTest(size=len(data)), self.server(body=data) as (port, calls):
                self.refused(self.run_cli(port))
                self.assertEqual(calls, [("GET", "/object_info")])

    def test_unavailable_service(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
            self.refused(self.run_cli(port), code=1)

    def test_total_http_deadline_even_when_headers_keep_arriving(self):
        helper = self.load_helper()
        self.save()

        class SlowHandler(http.server.BaseHTTPRequestHandler):
            def handle(self):
                self.rfile.readline()
                try:
                    for byte in b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{}":
                        self.wfile.write(bytes([byte]))
                        self.wfile.flush()
                        time.sleep(0.02)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SlowHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            started = time.monotonic()
            with patch.object(helper, "TIMEOUT", 0.15), \
                    patch.object(sys, "argv", [str(HELPER)] + self.args(server.server_port)), \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(helper.main(), 1)
            self.assertLess(time.monotonic() - started, 0.8, errors.getvalue())
            self.assertFalse(self.output.exists())
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_concurrent_publish_has_one_winner(self):
        self.save()
        command = [sys.executable, str(HELPER)] + self.args()
        processes = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True) for _ in range(4)]
        results = [process.communicate(timeout=15) for process in processes]
        self.assertEqual(sorted(p.returncode for p in processes), [0, 1, 1, 1], results)
        self.assertEqual(json.loads(self.output.read_text()), self.expected)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()),
                         ["api.json", "info.json", "ui.json"])

    def test_bundle_recipe_and_existing_render_contract(self):
        manifest = yaml.safe_load((BUNDLE / "capability.yaml").read_text())
        self.assertIn("comfy-import.py", manifest["payload"])
        job = manifest["jobs"].get("import-workflow", {})
        self.assertEqual(job.get("cmd"), "python3 {capdir}/comfy-import.py --workflow {workflow} --output {jobdir}/workflow_api.json --profile core-txt2img-v1 --port {port}")
        self.assertEqual(set(job.get("params", {})), {"workflow", "port"})
        self.assertEqual(manifest["jobs"]["render"]["cmd"], "python3 {capdir}/comfy-run.py --workflow {workflow} --port {port} --timeout 900 --out {jobdir} --sets {sets}")

    def test_imported_api_lists_and_renders_with_value_only_override(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        run = [sys.executable, str(BUNDLE / "comfy-run.py"), "--workflow", str(self.output)]
        listed = subprocess.run(run + ["--list-nodes"], capture_output=True, text=True, timeout=10)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn("Positive", listed.stdout)
        with self.server(render=True) as (port, calls):
            rendered = subprocess.run(run + ["--port", str(port), "--set", "Sampler.seed=42", "--out", str(self.root)], capture_output=True, text=True, timeout=10)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        expected = copy.deepcopy(self.expected)
        expected["3"]["inputs"]["seed"] = 42
        self.assertEqual(calls, [("GET", "/object_info"), ("POST", "/prompt", {"prompt": expected}), ("GET", "/history/test")])
        rejected = subprocess.run(run[:3] + [str(self.source), "--list-nodes"], capture_output=True, text=True, timeout=10)
        self.assertEqual(rejected.returncode, 2)
        self.assertIn(GUIDANCE, rejected.stdout)


if __name__ == "__main__":
    unittest.main()
