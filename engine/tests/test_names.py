"""File names are searchable: a query made only of name words finds the file with no content match, a common
word in many names does not, and off-topic queries still return nothing."""
import tempfile
from pathlib import Path

import pytest


@pytest.fixture
def env(monkeypatch):
    home = Path(tempfile.mkdtemp(prefix="ss-", dir="/tmp")) / "home"  # short: AF_UNIX path limit
    monkeypatch.setenv("SEMSEARCH_HOME", str(home))
    return home


@pytest.fixture
def emb(env):
    from semsearch import config
    from semsearch.embed import Embedder
    return Embedder(config.load()["model"], config.models_dir())


def _index(folder: Path, emb):
    from semsearch import config, indexer
    from semsearch.store import Store
    with Store() as s:
        s.add_folder(str(folder))
        indexer.sync(s, emb, config.load(), [str(folder)], log=lambda m: None)


def _query(text, emb):
    from semsearch import config
    from semsearch.search import query
    from semsearch.store import Store
    with Store() as s:
        return query(s, emb, text, 10, config.load())


def _paths(res):
    return [Path(r["path"]).name for r in res]


@pytest.fixture
def corpus(tmp_path):
    root = tmp_path / "corpus"
    root.mkdir()
    (root / "Thomas Sowell, sosiaalinen oikeudenmukaisuus.txt").write_text(
        "Tämä muistiinpano käsittelee tasa-arvoa ja työllisyyttä kunnassa.\n", encoding="utf-8")
    (root / "IMG_1723.txt").write_text("", encoding="utf-8")  # no text at all: found by its name only
    (root / "garden_plan.txt").write_text("Tomaatit kasvavat parvekkeella auringossa.\n", encoding="utf-8")
    (root / "lasagna.txt").write_text("Lasagnelevyt, jauheliha ja juusto uunissa.\n", encoding="utf-8")
    return root


def test_query_of_name_words_finds_file_with_no_content_match(corpus, emb):
    content = (corpus / "Thomas Sowell, sosiaalinen oikeudenmukaisuus.txt").read_text(encoding="utf-8").lower()
    assert "sowell" not in content and "thomas" not in content  # the name is only in the file name
    _index(corpus, emb)
    for q in ("Thomas Sowell", "Sowell", "sosiaalinen oikeudenmukaisuus", "oikeudenmukaisuutta sosiaalisen"):
        assert "Thomas Sowell, sosiaalinen oikeudenmukaisuus.txt" in _paths(_query(q, emb)), q


def test_empty_file_is_found_by_its_name(corpus, emb):
    _index(corpus, emb)
    res = _query("IMG_1723", emb)
    assert "IMG_1723.txt" in _paths(res)
    assert [r for r in res if r["path"].endswith("IMG_1723.txt")][0]["snippet"] == ""


def test_common_word_in_many_names_is_not_a_name_hit(tmp_path, emb):
    root = tmp_path / "many"
    root.mkdir()
    for i in range(30):
        (root / f"Notes {i:02d}.txt").write_text(f"Lasagnelevyt ja juusto uunissa, osa {i}.\n", encoding="utf-8")
    _index(root, emb)
    assert _query("notes", emb) == []  # "notes" is in 30 names: not a name match on its own


def test_off_topic_queries_still_return_nothing(corpus, emb):
    _index(corpus, emb)
    for q in ("best pizza place in Rome", "rocket launch schedule for SpaceX", "kitaran soinnut bluesiin"):
        assert _query(q, emb) == [], q


def test_names_with_separators_are_found_by_their_words(tmp_path, emb):
    root = tmp_path / "separators"
    root.mkdir()
    for name, text in [("poliittinen_meta_kartta.txt", "Lasagnelevyt uunissa, juusto päällä.\n"),
                       ("Thomas-Sowell muistio.txt", "Lasagnelevyt uunissa, juusto päällä.\n"),
                       ("report.v2.final.txt", "Lasagnelevyt uunissa, juusto päällä.\n"),
                       ("Lasku 2026 tammikuu.txt", "Lasagnelevyt uunissa, juusto päällä.\n")]:
        (root / name).write_text(text, encoding="utf-8")
    _index(root, emb)
    for q, name in [("poliittinen meta kartta", "poliittinen_meta_kartta.txt"),
                    ("Thomas Sowell", "Thomas-Sowell muistio.txt"),
                    ("report final", "report.v2.final.txt"),
                    ("lasku tammikuu", "Lasku 2026 tammikuu.txt")]:
        assert name in _paths(_query(q, emb)), q


def test_snake_case_identifiers_are_found_by_parts_and_whole(tmp_path, emb):
    root = tmp_path / "code"
    root.mkdir()
    (root / "weights.py").write_text("def load_model_weights(path):\n    return read_bytes(path)\n", encoding="utf-8")
    (root / "other.txt").write_text("Lasagnelevyt uunissa.\n", encoding="utf-8")
    _index(root, emb)
    for q in ("load model weights", "model weights", "load_model_weights"):
        assert "weights.py" in _paths(_query(q, emb)), q


def test_photo_without_text_is_found_by_its_name(tmp_path, emb):
    root = tmp_path / "photos"
    root.mkdir()
    photo = Path(__file__).parent / "ocr_fixtures" / "photo_no_text.jpg"  # OCR finds no text in it
    (root / "Holiday Rome 2024.jpg").write_bytes(photo.read_bytes())
    (root / "holiday_rome_2024.jpg").write_bytes(photo.read_bytes())
    (root / "other.txt").write_text("Lasagnelevyt uunissa.\n", encoding="utf-8")
    _index(root, emb)
    assert "Holiday Rome 2024.jpg" in _paths(_query("Holiday Rome", emb))
    assert "holiday_rome_2024.jpg" in _paths(_query("holiday rome 2024", emb))
    assert "holiday_rome_2024.jpg" in _paths(_query("holiday_rome", emb))


def test_name_cap_counts_names_not_content_in_large_indexes():
    from semsearch.search import _name_hit

    paths = [f"/c/Notes {i:02d}.txt" for i in range(20)] + ["/c/Sowell.txt"] + [f"/c/Muistio {i}.txt" for i in range(4979)]

    class FakeStore:  # 5000 files: 20 names hold "notes", one holds "sowell"
        def file_paths(self):
            return paths

    cfg = {"stemming": False}
    assert not _name_hit(FakeStore(), "/c/Notes 01.txt", ["notes"], [], cfg)
    assert _name_hit(FakeStore(), "/c/Sowell.txt", ["sowell"], [], cfg)


def test_common_word_in_many_names_is_not_rare_in_a_500_file_index(tmp_path, emb):
    root = tmp_path / "large"
    root.mkdir()
    for i in range(20):
        (root / f"Notes {i:02d}.txt").write_text(f"Lasagnelevyt uunissa, osa {i}.\n", encoding="utf-8")
    for i in range(479):
        (root / f"Muistio {i:03d}.txt").write_text(f"Kunnan tietoaineisto, osa {i}.\n", encoding="utf-8")
    (root / "Sowell.txt").write_text("Kunnan datan siirto ohje.\n", encoding="utf-8")
    _index(root, emb)
    assert _query("notes", emb) == []  # 20 of 500 files: a common word
    assert "Sowell.txt" in _paths(_query("Sowell", emb))  # one file: rare, so the name is a hit


def test_underscore_error_code_is_still_an_exact_id(tmp_path, emb):
    root = tmp_path / "ids"
    root.mkdir()
    (root / "virhe.txt").write_text("Laitteen virhekoodi ERR_40417 tuli eilen illalla.\n", encoding="utf-8")
    (root / "other.txt").write_text("Lasagnelevyt uunissa.\n", encoding="utf-8")
    _index(root, emb)
    assert "virhe.txt" in _paths(_query("ERR_40417", emb))


def test_name_of_a_long_file_is_found_though_only_its_first_chunk_has_it(tmp_path, emb):
    root = tmp_path / "long"
    root.mkdir()
    body = "\n".join(f"Lasagnelevyt uunissa, juusto päällä, rivi {i}." for i in range(400))
    (root / "Sowell kirja.txt").write_text(body, encoding="utf-8")  # several chunks, none with the name in it
    (root / "other.txt").write_text("Lasagnelevyt uunissa.\n", encoding="utf-8")
    _index(root, emb)
    from semsearch.store import Store
    with Store() as s:
        assert s.counts()[1] > 2  # really several chunks
    assert "Sowell kirja.txt" in _paths(_query("Sowell kirja", emb))


UNRELATED = "Lasagnelevyt uunissa, juusto päällä.\n"


def test_partial_last_word_finds_the_file(tmp_path, emb):
    # The search box searches as you type: the last word may be unfinished. Other files mention "thomas".
    root = tmp_path / "partial"
    root.mkdir()
    (root / "Thomas Sowell, sosiaalinen oikeudenmukaisuus.txt").write_text(UNRELATED, encoding="utf-8")
    (root / "poliittinen_meta_kartta.txt").write_text(UNRELATED, encoding="utf-8")
    (root / "other.txt").write_text("Thomas kertoi lasagnesta.\n", encoding="utf-8")
    photo = Path(__file__).parent / "ocr_fixtures" / "photo_no_text.jpg"
    (root / "Holiday Rome 2024.jpg").write_bytes(photo.read_bytes())
    _index(root, emb)
    for q, name in [("thomas sow", "Thomas Sowell, sosiaalinen oikeudenmukaisuus.txt"),
                    ("sow", "Thomas Sowell, sosiaalinen oikeudenmukaisuus.txt"),
                    ("thomas", "Thomas Sowell, sosiaalinen oikeudenmukaisuus.txt"),
                    ("poliittinen meta kar", "poliittinen_meta_kartta.txt"),
                    ("Holiday Ro", "Holiday Rome 2024.jpg")]:
        assert name in _paths(_query(q, emb)), q


def test_short_fragments_do_not_flood(tmp_path, emb):
    root = tmp_path / "flood"
    root.mkdir()
    for i in range(30):
        (root / f"Kotitalous {i:02d}.txt").write_text(UNRELATED, encoding="utf-8")
    _index(root, emb)
    assert _query("xy", emb) == []
    assert _query("ko", emb) == []  # 30 names start with "ko": too common to be a name match
    assert _query("kot", emb) == []


def test_first_name_is_found_while_few_names_hold_it(tmp_path, emb):
    from semsearch import config, indexer
    from semsearch.store import Store
    few, many = tmp_path / "few", tmp_path / "many"
    few.mkdir()
    many.mkdir()
    for i in range(3):
        (few / f"Thomas kirja {i}.txt").write_text(UNRELATED, encoding="utf-8")
    for i in range(9):
        (many / f"Thomas kirja {i}.txt").write_text(UNRELATED, encoding="utf-8")
    with Store() as s:
        s.add_folder(str(few))
        indexer.sync(s, emb, config.load(), [str(few)], log=lambda m: None)
    names = _paths(_query("thomas", emb))
    assert {f"Thomas kirja {i}.txt" for i in range(3)} <= set(names)  # 3 names hold it: found
    with Store() as s:
        s.add_folder(str(many))
        indexer.sync(s, emb, config.load(), [str(few), str(many)], log=lambda m: None)
    assert not [p for p in _paths(_query("thomas", emb)) if p.startswith("Thomas kirja")]  # 12 names: too common
