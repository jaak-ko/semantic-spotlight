"""MPS keeps a compiled graph per tensor shape. Sentence-transformers pads each batch to its own longest text, so
shapes never repeat and host memory grew to ~11 GB in a 940-file run (peak RSS, MPS). The bucketed path pads the
length to a few fixed sizes and the rows to 16, so the set of shapes stays small. Embeddings must not change."""
import numpy as np
import pytest

from semsearch import config
from semsearch.embed import BUCKETS, Embedder


@pytest.fixture
def emb(tmp_path, monkeypatch):
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    return Embedder(config.load()["model"], config.models_dir())


def _texts():
    rng = np.random.default_rng(3)
    words = ["kardemumma", "lasagne", "muistio", "vesivahinko", "sopimus", "matka", "a", "tulvariski"]
    return ["passage: " + " ".join(rng.choice(words, size=int(n))) for n in rng.integers(2, 300, size=40)]


def _record_shapes(emb, monkeypatch):
    shapes = set()
    real = emb.model.forward

    def forward(features):
        shapes.add(tuple(features["input_ids"].shape))
        return real(features)
    monkeypatch.setattr(emb.model, "forward", forward)
    return shapes


def test_bucketed_encoding_matches_plain_encode(emb):
    texts = _texts()
    plain = emb.model.encode(texts, batch_size=16, normalize_embeddings=True, convert_to_numpy=True)
    bucketed = emb._encode_bucketed(texts)
    assert bucketed.shape == plain.shape
    assert np.allclose(bucketed, plain, atol=1e-5)


def test_bucketed_encoding_uses_few_shapes(emb, monkeypatch):
    shapes = _record_shapes(emb, monkeypatch)
    emb._encode_bucketed(_texts())
    assert shapes and all(length in BUCKETS for _, length in shapes)
    assert all(rows in (1, 16) for rows, _ in shapes)
    assert len(shapes) <= 2 * len(BUCKETS)


@pytest.mark.skipif(not __import__("torch").backends.mps.is_available(), reason="MPS only")
def test_mps_embed_uses_the_bucketed_path(emb, monkeypatch):
    assert emb.model.device.type == "mps"
    shapes = _record_shapes(emb, monkeypatch)
    emb.embed([t[len("passage: "):] for t in _texts()], "passage")
    assert all(length in BUCKETS for _, length in shapes)
