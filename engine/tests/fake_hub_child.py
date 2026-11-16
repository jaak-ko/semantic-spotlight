"""Child process for test_fetch_cancel.py: `semsearch fetch-model` against a fake Hub, no network.

argv[1] "slow" streams the large file slowly, so a test can send SIGTERM mid-download; "fast" finishes at once.
Each run appends its starting offset of the large file to <models>/attempts.log (0 on a cold start), the way
HF's resume would start from the .incomplete partial."""
import hashlib
import os
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import huggingface_hub

from semsearch import modelfiles
from semsearch.modelfiles import run_fetch_cli

BIG = "model.safetensors"
REQUIRED = ["config.json", BIG, "modules.json", "sentence_bert_config.json", "sentencepiece.bpe.model",
            "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "1_Pooling/config.json"]


def content(f):
    size = 3000 if f == BIG else 10
    return (f.encode() * size)[:size]


slow = sys.argv[1] == "slow"
log = Path(os.environ["SEMSEARCH_MODELS"]) / "attempts.log"


def model_info(name, revision, files_metadata):
    sibs = [SimpleNamespace(rfilename=f, size=len(content(f)),
                            lfs=SimpleNamespace(sha256=hashlib.sha256(content(f)).hexdigest()) if f == BIG else None)
            for f in REQUIRED]
    return SimpleNamespace(sha=modelfiles.REV, siblings=sibs)


def snapshot_download(name, revision, cache_dir, allow_patterns):
    blobs = modelfiles.model_dir(name) / "blobs"
    blobs.mkdir(parents=True, exist_ok=True)
    part = blobs / "big.incomplete"
    have = part.stat().st_size if part.exists() else 0
    with open(log, "a") as fh:
        fh.write(f"{have}\n")
    data = content(BIG)
    with open(part, "ab") as fh:
        while have < len(data):
            step = data[have:have + 100]
            fh.write(step)
            fh.flush()
            have += len(step)
            if slow:
                time.sleep(0.05)
    part.replace(blobs / "big")
    snap = modelfiles.model_dir(name) / "snapshots" / modelfiles.REV
    for f in REQUIRED:
        (snap / f).parent.mkdir(parents=True, exist_ok=True)
        (snap / f).write_bytes(content(f))


huggingface_hub.model_info = model_info
huggingface_hub.snapshot_download = snapshot_download
sys.exit(run_fetch_cli(modelfiles.DEFAULT_MODEL))
