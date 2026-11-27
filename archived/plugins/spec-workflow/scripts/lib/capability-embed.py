#!/usr/bin/env python3
"""capability-embed.py -- the `embed` entrypoint of the embeddings capability.

Copied verbatim into an installed capability dir (as `embed.py`) by
capability.sh and run by that dir's isolated venv python. NOT part of the
stdlib-only core: it imports onnxruntime/tokenizers/numpy, which live only in
the capability's own venv (SPEC-MEMORY §12: capability modules own their deps).

Contract (SPEC-MEMORY §9.1): reads text lines from stdin, one text per line,
and prints one JSON array of floats per line to stdout -- the L2-normalized,
CLS-pooled 384-dim embedding of that line, matching the model pinned in
../manifest.json. Output is line-delimited so N input lines yield N output
lines in order.

Empty / whitespace-only input lines yield a zero vector (a valid 384-dim JSON
array of 0.0). This keeps the stdin/stdout line correspondence 1:1 -- the
caller never has to reconcile "which output belongs to which input" -- and a
zero vector is a harmless neutral neighbor (cosine similarity 0 to everything),
so a blank query line simply contributes nothing rather than erroring.
"""
import json
import os
import sys

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.join(HERE, "model")
DIM = 384
MAX_LEN = 512


def _load():
    tok = Tokenizer.from_file(os.path.join(MODEL_DIR, "tokenizer.json"))
    tok.enable_truncation(max_length=MAX_LEN)
    sess = ort.InferenceSession(
        os.path.join(MODEL_DIR, "model.onnx"),
        providers=["CPUExecutionProvider"],
    )
    return tok, sess


def _embed(tok, sess, input_names, text):
    enc = tok.encode(text)
    ids = np.array([enc.ids], dtype=np.int64)
    mask = np.array([enc.attention_mask], dtype=np.int64)
    feed = {"input_ids": ids, "attention_mask": mask}
    if "token_type_ids" in input_names:
        feed["token_type_ids"] = np.zeros_like(ids)
    # bge uses CLS pooling: token 0 of the last hidden state, then L2-normalize.
    last_hidden = sess.run(None, feed)[0]
    cls = last_hidden[0, 0, :].astype(np.float64)
    norm = float(np.linalg.norm(cls))
    if norm > 0.0:
        cls = cls / norm
    return [round(float(x), 6) for x in cls.tolist()]


def main():
    tok, sess = _load()
    input_names = {i.name for i in sess.get_inputs()}
    zero = [0.0] * DIM
    for raw in sys.stdin:
        text = raw.rstrip("\n")
        if not text.strip():
            print(json.dumps(zero))
        else:
            print(json.dumps(_embed(tok, sess, input_names, text)))
        sys.stdout.flush()


if __name__ == "__main__":
    main()
