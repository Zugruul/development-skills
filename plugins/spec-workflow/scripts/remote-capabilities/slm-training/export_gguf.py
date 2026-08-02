#!/usr/bin/env python3
"""export_gguf.py — merge adapters into a base SLM and export GGUF.

The remote half of the slm-training capability's `export-gguf` job. Loads the
model named by the config (a trained adapter dir from a previous sft job, or
a bare base model), then exports one GGUF per requested quantization via
unsloth's save_pretrained_gguf (which drives llama.cpp's converter inside the
training env — nothing is installed globally on the machine).

Config keys (JSON or YAML):
    base_model      HF id or local path (required)
    adapters        path to a trained adapter dir; omit to export base as-is
    quantizations   list, default ["q8_0"] (e.g. q4_k_m, q5_k_m, q8_0, f16)
    max_seq_length  default 2048
    smoke           OPTIONAL: {prompt, json_schema, max_tokens, llama_cli} —
                    see "Smoke test" below. Absent entirely -> no smoke step
                    runs at all (fully backward compatible with pre-smoke
                    configs and callers).

Outputs (in --out, default $COMPUTE_JOB_DIR, else cwd):
    gguf/                   one .gguf per quantization
    export-summary.json     files, sizes, sha256, and (when `smoke` was
                             configured) per-file smoke results — see below.

Smoke test: a caller-requested pre-packaging gate — "smoke-test each
artifact in llama.cpp (load + one JSON-schema-constrained completion) before
it is eligible for packaging." When the config carries a `smoke` section, EVERY
produced GGUF is loaded in llama-cli and asked to complete `smoke.prompt`
under grammar-constrained decoding against `smoke.json_schema`, via
llama-cli's real, verified `-j`/`--json-schema SCHEMA` flag (confirmed
against the current llama.cpp docs: "-j, --json-schema SCHEMA  JSON schema
to constrain generations (https://json-schema.org/)" — an inline schema
string, distinct from the file-based `--json-schema-file`). `-m`/`--model`,
`-p`/`--prompt`, and `-n`/`--n-predict` are the other llama-cli flags used
here; all four are documented, stable llama-cli flags, not inferred.

    smoke.prompt        the single completion prompt (required if smoke set)
    smoke.json_schema   a JSON-Schema object (required if smoke set)
    smoke.max_tokens    default 128 (-> llama-cli's -n)
    smoke.llama_cli     default "~/llama.cpp/build/bin/llama-cli"; if that
                         path doesn't exist/isn't executable, falls back to
                         DISCOVERY: search (1) the current working directory,
                         then (2) $HOME, each for entries named `llama.cpp*`
                         (sorted alphabetically), and within each such dir
                         try, in order, build/bin/llama-cli, build/bin/main,
                         llama-cli, main — the first existing+executable path
                         wins. This is where unsloth's own from-source
                         llama.cpp build (used internally by
                         save_pretrained_gguf) typically lands.

Per produced GGUF, smoke records {file, loaded, constrainedOutputRaw
(truncated to 2000 chars), parsedOk} into export-summary.json's
`smoke.perFile` (alongside `smoke.schema`, an echo of smoke.json_schema).
`loaded` is true iff llama-cli exited 0 (a nonzero exit — bad GGUF, OOM, wrong
arch, etc. — means it never loaded). `parsedOk` is true iff a JSON object
could be extracted from stdout AND round-trips through json.loads AND passes
a SHALLOW, stdlib-only, TOP-LEVEL-ONLY structural check against the schema:
required keys present, and each present property whose schema declares a
`type` among {string,number,integer,boolean,array,object,null} matches that
type (nested schemas, $ref, oneOf/anyOf/allOf, and array item schemas are NOT
checked — full JSON-Schema validation is out of scope for a load-bearing
smoke gate; APP-022's eval harness is where real answer-quality validation
belongs). Extraction rule: llama-cli's stdout carries the echoed prompt
followed by the grammar-constrained continuation (no flag here strips the
echo) — since the continuation is the only part guaranteed to be valid JSON,
the extractor scans for the LAST balanced `{...}` object in stdout (brace-
depth counting that ignores braces inside quoted strings) and parses that.

IF `smoke` is configured AND any produced file fails either loaded or
parsedOk THEN this script exits 1 — a GGUF that can't load or produce
parseable constrained output must never look eligible for packaging — but
export-summary.json (including the failing file's real diagnostics) is
still written first, so the failure is auditable rather than discarded.

Exit codes: 0 ok · 1 export/env error (or smoke failure) · 2 config error.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

SMOKE_TIMEOUT_SEC = 300  # safety net only, not a config knob: a hung llama-cli
                          # must not hold the shared GPU resource lock forever.
CONSTRAINED_OUTPUT_TRUNCATE = 2000
JSON_SCHEMA_TYPE_CHECKS = {
    "string": lambda v: isinstance(v, str),
    "boolean": lambda v: isinstance(v, bool),
    # bool is a subclass of int in Python — excluded explicitly so a real
    # bool never satisfies a number/integer type check.
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "array": lambda v: isinstance(v, list),
    "object": lambda v: isinstance(v, dict),
    "null": lambda v: v is None,
}


def load_config(path):
    with open(path) as f:
        raw = f.read()
    if path.endswith((".yaml", ".yml")):
        import yaml
        return yaml.safe_load(raw) or {}
    return json.loads(raw)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def resolve_llama_cli(smoke_cfg):
    """Returns an existing, executable llama-cli path, or None if nothing
    was found (configured default + discovery both missed). See this
    module's top doc comment for the exact discovery order."""
    configured = smoke_cfg.get("llama_cli") or "~/llama.cpp/build/bin/llama-cli"
    expanded = os.path.expanduser(configured)
    if os.path.isfile(expanded) and os.access(expanded, os.X_OK):
        return expanded
    print("WARNING: llama_cli not found/executable at %s — searching cwd/$HOME for a llama.cpp*/ build" % expanded)

    for base in (os.getcwd(), os.path.expanduser("~")):
        if not os.path.isdir(base):
            continue
        try:
            names = sorted(os.listdir(base))
        except OSError:
            continue
        for name in names:
            if not name.startswith("llama.cpp"):
                continue
            root = os.path.join(base, name)
            for rel in ("build/bin/llama-cli", "build/bin/main", "llama-cli", "main"):
                candidate = os.path.join(root, rel)
                if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                    return candidate
    return None


def extract_last_json_object(text):
    """Scans for the LAST balanced {...} object in text (brace-depth
    counting that ignores braces inside quoted strings) and returns the
    substring, or None if no balanced object is found. See this module's
    top doc comment for why "last" and why this is the documented
    extraction rule."""
    depth = 0
    in_string = False
    escape = False
    start = None
    last_start, last_end = None, None
    for i, ch in enumerate(text):
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start is not None:
                    last_start, last_end = start, i + 1
    if last_start is None:
        return None
    return text[last_start:last_end]


def check_schema_shallow(parsed, schema):
    """Shallow, stdlib-only, top-level-only structural check — see this
    module's top doc comment for exactly what is and isn't checked."""
    if schema.get("type") == "object" and not isinstance(parsed, dict):
        return False
    if not isinstance(parsed, dict):
        return True  # nothing further to check without a dict to index into
    for key in schema.get("required", []):
        if key not in parsed:
            return False
    for key, subschema in (schema.get("properties") or {}).items():
        if key not in parsed:
            continue
        expected_type = subschema.get("type") if isinstance(subschema, dict) else None
        checker = JSON_SCHEMA_TYPE_CHECKS.get(expected_type)
        if checker is not None and not checker(parsed[key]):
            return False
    return True


def run_smoke_for_file(gguf_path, smoke_cfg, llama_cli):
    prompt = smoke_cfg["prompt"]
    schema = smoke_cfg["json_schema"]
    max_tokens = int(smoke_cfg.get("max_tokens") or 128)
    cmd = [llama_cli, "-m", gguf_path, "-p", prompt, "--json-schema", json.dumps(schema), "-n", str(max_tokens)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=SMOKE_TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        return {"loaded": False, "constrainedOutputRaw": "", "parsedOk": False}
    except OSError as e:
        return {"loaded": False, "constrainedOutputRaw": str(e)[:CONSTRAINED_OUTPUT_TRUNCATE], "parsedOk": False}

    loaded = proc.returncode == 0
    raw = (proc.stdout or "")[:CONSTRAINED_OUTPUT_TRUNCATE]
    parsed_ok = False
    if loaded:
        candidate = extract_last_json_object(proc.stdout or "")
        if candidate is not None:
            try:
                parsed = json.loads(candidate)
            except ValueError:
                parsed = None
            if parsed is not None:
                parsed_ok = check_schema_shallow(parsed, schema)
    return {"loaded": loaded, "constrainedOutputRaw": raw, "parsedOk": parsed_ok}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--out", default=None,
                    help="output dir (default: $COMPUTE_JOB_DIR, else cwd)")
    args = ap.parse_args()
    out_dir = args.out or os.environ.get("COMPUTE_JOB_DIR") or "."

    try:
        cfg = load_config(args.config)
    except Exception as e:
        print("ERROR: could not load config %s: %s" % (args.config, e))
        return 2
    base_model = cfg.get("base_model")
    if not base_model:
        print("ERROR: config needs base_model")
        return 2
    adapters = cfg.get("adapters")
    if adapters and adapters.startswith("/mnt/"):
        print("WARNING: adapters under /mnt/* (DrvFs, slow) — prefer ext4 paths")
    quants = cfg.get("quantizations") or ["q8_0"]
    smoke_cfg = cfg.get("smoke")
    if smoke_cfg is not None:
        if not smoke_cfg.get("prompt") or not isinstance(smoke_cfg.get("json_schema"), dict):
            print("ERROR: config.smoke needs both prompt and json_schema (object)")
            return 2

    try:
        import torch  # noqa: F401 — env sanity before the heavy load
        from unsloth import FastLanguageModel
    except ImportError as e:
        print("ERROR: training env not active (torch/unsloth unavailable): %s" % e)
        return 1

    t_start = time.time()
    # loading the adapter dir directly rehydrates base+LoRA in one step (the
    # dir's adapter_config.json names the base); a bare base model exports as-is
    model_name = adapters or base_model
    print("loading %s" % model_name)
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=model_name,
        max_seq_length=int(cfg.get("max_seq_length") or 2048),
        load_in_4bit=False,  # merge/export needs the full-precision weights
    )

    gguf_dir = os.path.join(out_dir, "gguf")
    os.makedirs(gguf_dir, exist_ok=True)
    produced = []
    for quant in quants:
        print("exporting %s…" % quant)
        model.save_pretrained_gguf(gguf_dir, tokenizer, quantization_method=quant)
        # save_pretrained_gguf names files itself; pick up whatever is new
        for name in sorted(os.listdir(gguf_dir)):
            path = os.path.join(gguf_dir, name)
            if name.endswith(".gguf") and all(p["file"] != name for p in produced):
                produced.append({"file": name, "quantization": quant,
                                 "sizeBytes": os.path.getsize(path),
                                 "sha256": sha256_file(path)})
                print("ARTIFACT %s" % path)

    if not produced:
        print("ERROR: no .gguf files were produced")
        return 1

    summary = {
        "baseModel": base_model,
        "adapters": adapters,
        "quantizations": quants,
        "files": produced,
        "wallClockSec": round(time.time() - t_start, 1),
    }

    smoke_failed = False
    if smoke_cfg is not None:
        llama_cli = resolve_llama_cli(smoke_cfg)
        per_file = []
        for entry in produced:
            gguf_path = os.path.join(gguf_dir, entry["file"])
            if llama_cli is None:
                result = {"loaded": False, "constrainedOutputRaw": "", "parsedOk": False}
                print("ERROR: no llama-cli binary found (configured/default path missing and discovery found none)")
            else:
                print("smoke-testing %s via %s…" % (entry["file"], llama_cli))
                result = run_smoke_for_file(gguf_path, smoke_cfg, llama_cli)
            per_file.append({"file": entry["file"], **result})
            if not (result["loaded"] and result["parsedOk"]):
                smoke_failed = True
                print("SMOKE FAIL %s: loaded=%s parsedOk=%s" % (entry["file"], result["loaded"], result["parsedOk"]))
        summary["smoke"] = {"schema": smoke_cfg["json_schema"], "perFile": per_file}

    summary_path = os.path.join(out_dir, "export-summary.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print("ARTIFACT %s" % summary_path)

    if smoke_failed:
        print("ERROR: one or more GGUFs failed the llama.cpp smoke test — see export-summary.json's smoke.perFile")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
