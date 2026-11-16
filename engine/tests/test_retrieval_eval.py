"""Parallel FI/EN retrieval eval (see tests/eval). Thresholds are deliberately loose
so that a real regression fails but ordinary noise does not."""
import sys
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE / "eval"))

import run_eval  # noqa: E402


def test_finnish_monolingual_within_5_points_of_english():
    r = run_eval.evaluate("intfloat/multilingual-e5-small", stemming=True)["buckets"]
    assert r["FI"]["recall5"] >= r["EN"]["recall5"] - 0.05, r
    assert r["FI"]["mrr"] >= 0.9, r["FI"]
    assert r["EN"]["mrr"] >= 0.9, r["EN"]


def test_exact_ids_still_perfect():
    r = run_eval.evaluate("intfloat/multilingual-e5-small", stemming=True)["buckets"]
    assert r["ID"]["recall5"] == 1.0, r["ID"]


def test_changing_keyword_settings_rebuilds_index(tmp_path, monkeypatch):
    from semsearch import config, indexer
    from semsearch.embed import Embedder
    from semsearch.store import Store

    emb = Embedder(config.DEFAULTS["model"], config.models_dir())
    docs = run_eval.DOCS
    logs = []
    with Store(tmp_path / "x.db") as s:
        s.add_folder(str(docs))
        cfg = dict(config.DEFAULTS, stemming=False)
        indexer.sync(s, emb, cfg, [str(docs)], log=logs.append)
        cfg["stemming"] = True
        indexer.sync(s, emb, cfg, [str(docs)], log=logs.append)
        assert any("rebuilding" in m for m in logs)
        # stems let an inflected Finnish query find the tomato note
        from semsearch.search import query
        top = query(s, emb, "tomaattien istutus", 3, cfg)[0]["path"]
        assert top.endswith("t07_fi.txt")
