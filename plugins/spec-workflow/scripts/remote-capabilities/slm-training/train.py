#!/usr/bin/env python3
"""train.py — config-driven SLM fine-tuning (unsloth QLoRA, SFT or DPO).

The remote half of the slm-training capability's `sft` job. Everything a run
needs comes from ONE config file (JSON or YAML) so the bundle stays fully
project-agnostic: a project authors a config + dataset, ships them to the
machine (remote-compute `--inputs`, or any path already on ext4), and this
script fine-tunes and drops artifacts into the per-job dir.

Config keys (JSON or YAML; only base_model is required):
    base_model      HF id or local path, e.g. "unsloth/Qwen3-0.6B"
    stage           "sft" (default) or "dpo"
    max_seq_length  default 2048
    load_in_4bit    default true (QLoRA)
    lora            {r: 16, alpha: 16, dropout: 0.0, target_modules: [...]}
    dataset         {path: "<jsonl on ext4>"} or {samples: [...inline rows...]}
                    sft rows: {"messages": [{role, content}, ...]}
                              or {"prompt": ..., "completion": ...}
                              or {"text": ...}
                    dpo rows: {"prompt": ..., "chosen": ..., "rejected": ...}
    train           {max_steps | num_epochs, batch_size: 2, grad_accum: 4,
                     lr: 2e-4, warmup_steps: 5, seed: 3407, logging_steps: 1}

Outputs (in --out, default $COMPUTE_JOB_DIR, else cwd — the per-job dir is
what `remote-compute job-pull` retrieves):
    adapters/            LoRA adapters + tokenizer (save_pretrained)
    train-summary.json   steps, loss history tail, runtime, versions, config echo

Exit codes: 0 ok · 1 training/env error · 2 config error.
Heavy imports (torch/unsloth/trl/datasets) happen inside main and only under
the declared training env — the script itself stays importable anywhere.
"""
import argparse
import json
import os
import sys
import time

DEFAULT_TARGET_MODULES = [
    "q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj",
]


def load_config(path):
    """JSON or YAML by extension; YAML needs pyyaml (present in any env that
    can run transformers). Config errors are exit-2 usage errors."""
    with open(path) as f:
        raw = f.read()
    if path.endswith((".yaml", ".yml")):
        import yaml
        return yaml.safe_load(raw) or {}
    return json.loads(raw)


def warn_if_drvfs(path):
    if path and str(path).startswith("/mnt/"):
        print("WARNING: %s is under /mnt/* (DrvFs — marked slow on this machine); "
              "keep datasets and checkpoints on the ext4 home filesystem" % path)


def load_rows(dataset_cfg):
    """Rows from an inline `samples` list or a JSONL file — no other shapes,
    so a config is always explicit about where its data came from."""
    if not dataset_cfg:
        raise ValueError("config needs a dataset {path: ...} or {samples: [...]}")
    if dataset_cfg.get("samples") is not None:
        return list(dataset_cfg["samples"])
    path = dataset_cfg.get("path")
    if not path:
        raise ValueError("dataset needs either samples: [...] or path: <jsonl>")
    warn_if_drvfs(path)
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    if not rows:
        raise ValueError("dataset %s is empty" % path)
    return rows


def sft_text(row, tokenizer):
    """One training text per row, whatever shape the row uses."""
    if "text" in row:
        return row["text"]
    if "messages" in row:
        return tokenizer.apply_chat_template(
            row["messages"], tokenize=False, add_generation_prompt=False)
    if "prompt" in row and "completion" in row:
        return row["prompt"] + row["completion"]
    raise ValueError("sft row needs text, messages, or prompt+completion: %r"
                     % {k: str(v)[:40] for k, v in row.items()})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--out", default=None,
                    help="output dir (default: $COMPUTE_JOB_DIR, else cwd)")
    args = ap.parse_args()
    out_dir = args.out or os.environ.get("COMPUTE_JOB_DIR") or "."

    try:
        cfg = load_config(args.config)
    except Exception as e:  # config problems are usage errors, not crashes
        print("ERROR: could not load config %s: %s" % (args.config, e))
        return 2
    base_model = cfg.get("base_model")
    if not base_model:
        print("ERROR: config needs base_model")
        return 2
    stage = cfg.get("stage") or "sft"
    if stage not in ("sft", "dpo"):
        print("ERROR: stage must be sft or dpo (got %r)" % stage)
        return 2

    try:
        import torch
        from unsloth import FastLanguageModel
    except ImportError as e:
        print("ERROR: training env not active (torch/unsloth unavailable): %s" % e)
        return 1

    t_start = time.time()
    max_seq = int(cfg.get("max_seq_length") or 2048)
    lora = cfg.get("lora") or {}
    train = cfg.get("train") or {}
    print("loading %s (max_seq_length=%d, load_in_4bit=%s)"
          % (base_model, max_seq, cfg.get("load_in_4bit", True)))
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=base_model,
        max_seq_length=max_seq,
        load_in_4bit=bool(cfg.get("load_in_4bit", True)),
    )
    model = FastLanguageModel.get_peft_model(
        model,
        r=int(lora.get("r") or 16),
        lora_alpha=int(lora.get("alpha") or 16),
        lora_dropout=float(lora.get("dropout") or 0.0),
        target_modules=lora.get("target_modules") or DEFAULT_TARGET_MODULES,
        random_state=int(train.get("seed") or 3407),
    )

    try:
        rows = load_rows(cfg.get("dataset"))
    except (ValueError, OSError, json.JSONDecodeError) as e:
        print("ERROR: %s" % e)
        return 2
    print("dataset: %d rows (stage=%s)" % (len(rows), stage))

    from datasets import Dataset
    from transformers import TrainingArguments

    common_args = dict(
        output_dir=os.path.join(out_dir, "trainer-state"),
        per_device_train_batch_size=int(train.get("batch_size") or 2),
        gradient_accumulation_steps=int(train.get("grad_accum") or 4),
        learning_rate=float(train.get("lr") or 2e-4),
        warmup_steps=int(train.get("warmup_steps") or 5),
        logging_steps=int(train.get("logging_steps") or 1),
        seed=int(train.get("seed") or 3407),
        report_to="none",
        # The trainer never checkpoints: adapters are saved explicitly after
        # train() (below), trainer-state is scratch, and a trainer checkpoint
        # would torch.save(TrainingArguments) — which crashes with a
        # class-identity PicklingError once unsloth has patched trl's config
        # classes (observed live: "Can't pickle SFTConfig: it's not the same
        # object as trl.trainer.sft_config.SFTConfig").
        save_strategy="no",
    )
    if train.get("max_steps"):
        common_args["max_steps"] = int(train["max_steps"])
    else:
        common_args["num_train_epochs"] = float(train.get("num_epochs") or 1)

    if stage == "sft":
        from trl import SFTTrainer
        try:
            texts = [sft_text(r, tokenizer) for r in rows]
        except ValueError as e:
            print("ERROR: %s" % e)
            return 2
        trainer = SFTTrainer(
            model=model,
            tokenizer=tokenizer,
            train_dataset=Dataset.from_dict({"text": texts}),
            dataset_text_field="text",
            max_seq_length=max_seq,
            args=TrainingArguments(**common_args),
        )
    else:
        from trl import DPOConfig, DPOTrainer
        bad = [r for r in rows if not all(k in r for k in ("prompt", "chosen", "rejected"))]
        if bad:
            print("ERROR: %d dpo row(s) missing prompt/chosen/rejected" % len(bad))
            return 2
        trainer = DPOTrainer(
            model=model,
            tokenizer=tokenizer,
            train_dataset=Dataset.from_list(rows),
            args=DPOConfig(**common_args),
        )

    print("training…")
    result = trainer.train()

    adapters_dir = os.path.join(out_dir, "adapters")
    model.save_pretrained(adapters_dir)
    tokenizer.save_pretrained(adapters_dir)
    print("ARTIFACT %s" % adapters_dir)

    log_tail = [e for e in trainer.state.log_history if "loss" in e][-20:]
    summary = {
        "stage": stage,
        "baseModel": base_model,
        "rows": len(rows),
        "globalSteps": trainer.state.global_step,
        "trainRuntimeSec": round(getattr(result, "metrics", {}).get("train_runtime", 0), 1),
        "lossTail": log_tail,
        "torch": torch.__version__,
        "wallClockSec": round(time.time() - t_start, 1),
        "config": cfg,
    }
    summary_path = os.path.join(out_dir, "train-summary.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print("ARTIFACT %s" % summary_path)
    print("done: %d steps in %ss" % (trainer.state.global_step, summary["wallClockSec"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
