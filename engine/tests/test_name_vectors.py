"""Each file has a name vector (its name words, embedded once, also for files with no text). Chunk vectors are the
text's own vectors: the name is not part of any chunk's embedded text."""
import numpy as np
import pytest

from semsearch import config, indexer
from semsearch.embed import Embedder
from semsearch.store import Store


@pytest.fixture
def emb(tmp_path, monkeypatch):
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    return Embedder(config.load()["model"], config.models_dir())


def test_every_file_gets_a_name_vector_including_empty_ones(tmp_path, emb):
    root = tmp_path / "docs"
    root.mkdir()
    (root / "Thomas Sowell.txt").write_text("Tasa-arvo ja työllisyys.\n", encoding="utf-8")
    (root / "IMG_1723.txt").write_text("", encoding="utf-8")
    with Store() as s:
        s.add_folder(str(root))
        indexer.sync(s, emb, config.load(), [str(root)], log=lambda m: None)
        fids, mat = s.name_vectors()
        assert len(fids) == 2 and mat.shape == (2, emb.model.get_sentence_embedding_dimension())
        assert np.allclose(np.linalg.norm(mat, axis=1), 1.0, atol=1e-3)  # normalised like chunk vectors


def test_chunk_vectors_embed_the_text_without_the_name(tmp_path, emb, monkeypatch):
    root = tmp_path / "docs"
    root.mkdir()
    (root / "poliittinen_meta.txt").write_text("Lasagnelevyt uunissa.\n", encoding="utf-8")
    sent = []
    real = emb.embed

    def record(texts, kind):
        sent.append(list(texts))
        return real(texts, kind)
    monkeypatch.setattr(emb, "embed", record)
    with Store() as s:
        s.add_folder(str(root))
        indexer.sync(s, emb, config.load(), [str(root)], log=lambda m: None)
    chunk_texts = sent[0][:-1]  # the last text of the batch is the name vector's input
    assert chunk_texts == ["Lasagnelevyt uunissa.\n"] or chunk_texts == ["Lasagnelevyt uunissa."]
    assert sent[0][-1] == "poliittinen meta"
