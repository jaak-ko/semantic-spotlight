import os
import threading
from pathlib import Path

import numpy as np

_lock = threading.Lock()  # model is shared by the daemon's query and indexing threads
SLICE = 32  # texts per lock hold
_models: dict = {}


def _load(name: str, cache: Path):
    if name not in _models:
        # Offline by default: only `fetch-model` (and the explicit SEMSEARCH_DOWNLOAD dev flag) may use the network.
        if os.environ.get("SEMSEARCH_DOWNLOAD") != "1":
            os.environ["HF_HUB_OFFLINE"] = "1"
        import torch
        from sentence_transformers import SentenceTransformer
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        from .modelfiles import PATTERNS, REV
        rev = REV if name in PATTERNS else None  # load exactly the pinned snapshot
        _models[name] = SentenceTransformer(name, cache_folder=str(cache), device=device, revision=rev)
    return _models[name]


class Embedder:
    def __init__(self, name: str, cache: Path):
        from .modelfiles import ModelMissing, verify_install
        if os.environ.get("SEMSEARCH_DOWNLOAD") != "1" and not verify_install(name):  # checked on every construction (an unmarked install is checked once)
            raise ModelMissing(f"model {name} is not installed; run `semsearch fetch-model`")
        self.name = name
        self.model = _load(name, cache)
        self.tok = self.model.tokenizer
        self.tok.model_max_length = 10**6  # we count tokens only; truncation is the model's own concern
        # e5 models were trained with these prefixes; bge-m3 uses none.
        self.prefix = {"passage": "", "query": ""}
        if "e5" in name:
            self.prefix = {"passage": "passage: ", "query": "query: "}

    def count(self, text: str) -> int:
        with _lock:  # the fast tokenizer is not reentrant: indexing counts tokens while a query encodes
            return len(self.tok.encode(text, add_special_tokens=False))

    def _encode(self, batch):
        try:
            return self.model.encode(batch, batch_size=16, normalize_embeddings=True, convert_to_numpy=True)
        except RuntimeError:
            # MPS can fail on some ops; fall back to CPU for the rest of the process.
            self.model = self.model.to("cpu")
            return self.model.encode(batch, batch_size=16, normalize_embeddings=True, convert_to_numpy=True)

    def embed(self, texts, kind: str) -> np.ndarray:
        if not texts:
            return np.zeros((0, self.model.get_sentence_embedding_dimension()), dtype=np.float32)
        pre = self.prefix[kind]
        out = []
        for i in range(0, len(texts), SLICE):  # the lock is taken per slice, so a query waits for one slice at most
            batch = [pre + t for t in texts[i:i + SLICE]]
            with _lock:
                out.append(self._encode(batch))
        return np.concatenate(out).astype(np.float32)
