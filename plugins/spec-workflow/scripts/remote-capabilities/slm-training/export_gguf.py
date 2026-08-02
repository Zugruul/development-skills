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

Outputs (in --out, default $COMPUTE_JOB_DIR, else cwd):
    gguf/                   one .gguf per quantization
    export-summary.json     files, sizes, sha256 — manifest-friendly

Exit codes: 0 ok · 1 export/env error · 2 config error.
"""
import argparse
import hashlib
import json
import os
import sys
import time


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
    summary_path = os.path.join(out_dir, "export-summary.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print("ARTIFACT %s" % summary_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
