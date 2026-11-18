"""Huge and data-like files: only the first max_chunks_per_file chunks are embedded, the file name always counts,
and the partial state is kept: status (files_partial), the event log (files_truncated, files_data_like)."""
import json
import sqlite3

import pytest

from semsearch import config, events, indexer
from semsearch.embed import Embedder
from semsearch.store import Store, read_partial


@pytest.fixture
def emb(tmp_path, monkeypatch):
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    return Embedder(config.load()["model"], config.models_dir())


def _cfg(cap=3):
    return dict(config.load(), max_chunks_per_file=cap)


def _prose(n_paragraphs=12):
    para = ("Muistiinpano tasa-arvosta ja työllisyydestä kunnassa, sosiaalisesta oikeudenmukaisuudesta "
            "ja kotitalouksien talouden suunnittelusta vuosikymmenen aikana. ") * 14
    return "\n".join(f"{para} Kappale {i}." for i in range(n_paragraphs)) + "\n"


def _csv(rows=2000):
    return "id,a,b,c\n" + "\n".join(f"{i},{i * 7919 % 1000},{i * 31 % 97},{i % 5}" for i in range(rows)) + "\n"


def test_data_like_detection_separates_dumps_from_prose():
    assert indexer._data_like(_csv()) is True
    assert indexer._data_like("x" * 5000) is True  # one line far too long
    assert indexer._data_like('{"a":' + "1," * 3000 + '"b":2}') is True  # minified JSON, one long line
    assert indexer._data_like(_prose()) is False
    assert indexer._data_like("") is False


def test_huge_prose_file_keeps_its_first_chunks_and_its_name_is_searchable(tmp_path, emb):
    root = tmp_path / "docs"
    root.mkdir()
    (root / "Sowell kirja.txt").write_text(_prose(), encoding="utf-8")
    with Store() as s:
        s.add_folder(str(root))
        st = indexer.sync(s, emb, _cfg(), [str(root)], log=lambda m: None)
        assert s.counts()[1] == 3 and s.partial_files() == 1
    assert st["files_truncated"] == 1 and st["files_data_like"] == 0
    from semsearch.search import query
    with Store() as s:
        hits = [r["path"] for r in query(s, emb, "Sowell kirja", 5, _cfg())]
    assert str(root / "Sowell kirja.txt") in hits  # a name-only query still finds the capped file


def test_data_like_file_is_capped_and_flagged(tmp_path, emb):
    root = tmp_path / "dumps"
    root.mkdir()
    (root / "export.csv").write_text(_csv(), encoding="utf-8")
    (root / "notes.txt").write_text("Lasagnelevyt uunissa.\n", encoding="utf-8")
    with Store() as s:
        s.add_folder(str(root))
        st = indexer.sync(s, emb, _cfg(), [str(root)], log=lambda m: None)
        assert s.partial_files() == 1
    assert st["files_data_like"] == 1 and st["files_truncated"] == 1


def test_a_small_data_like_file_is_flagged_but_not_partial(tmp_path, emb):
    root = tmp_path / "small"
    root.mkdir()
    (root / "a.csv").write_text("1,2,3\n4,5,6\n7,8,9\n", encoding="utf-8")
    with Store() as s:
        s.add_folder(str(root))
        st = indexer.sync(s, emb, _cfg(), [str(root)], log=lambda m: None)
        assert s.partial_files() == 0
    assert st["files_data_like"] == 1 and st["files_truncated"] == 0


def test_partial_flag_survives_an_unchanged_rerun(tmp_path, emb):
    root = tmp_path / "docs"
    root.mkdir()
    (root / "big.txt").write_text(_prose(), encoding="utf-8")
    with Store() as s:
        s.add_folder(str(root))
        indexer.sync(s, emb, _cfg(), [str(root)], log=lambda m: None)
        st = indexer.sync(s, emb, _cfg(), [str(root)], log=lambda m: None)
        assert s.partial_files() == 1
    assert st["files_truncated"] == 0  # nothing re-embedded, the flag is still there


def test_an_index_from_before_the_flag_is_migrated_on_open(tmp_path, emb, monkeypatch):
    with Store() as s:
        s.db.execute("ALTER TABLE files DROP COLUMN partial")
        s.commit()
    with Store() as s:  # the column comes back on open
        assert s.partial_files() == 0
    assert read_partial() == 0


def test_schema_is_bumped_for_the_capped_index_and_the_new_vectors():
    assert indexer.SCHEMA_VERSION == 6
    assert "schema=6" in indexer.index_signature(config.DEFAULTS, config.DEFAULTS["model"])


def test_index_end_reports_the_truncation(tmp_path, emb, monkeypatch):
    monkeypatch.setattr(events, "_enabled", True)
    root = tmp_path / "docs"
    root.mkdir()
    (root / "big.txt").write_text(_prose(), encoding="utf-8")
    with Store() as s:
        s.add_folder(str(root))
        indexer.sync(s, emb, _cfg(), [str(root)], log=lambda m: None)
    home = config.home()
    recs = [json.loads(x) for x in (home / "events.jsonl").read_text(encoding="utf-8").splitlines()]
    end = [r for r in recs if r["event"] == "index_end"][-1]
    assert end["files_truncated"] == 1 and end["files_data_like"] == 0
