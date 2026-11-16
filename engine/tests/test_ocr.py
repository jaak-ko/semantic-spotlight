"""OCR indexing tests. Fixtures are copied to a temp folder; the Vision helper is used for real
(tests are skipped when no helper can be built, i.e. no swiftc)."""
import json
import shutil
from pathlib import Path

import pytest

FIXTURES = Path(__file__).parent / "ocr_fixtures"


@pytest.fixture(scope="module")
def helper():
    from semsearch import ocr
    h = ocr.find_helper(log=lambda m: None)
    if h is None:
        pytest.skip("no OCR helper (needs swiftc on macOS)")
    return h


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    return tmp_path


@pytest.fixture
def pics(home):
    d = home / "pics"
    d.mkdir()
    for f in FIXTURES.glob("*.png"):
        shutil.copy(f, d)
    for f in FIXTURES.glob("*.jpg"):
        shutil.copy(f, d)
    (d / "bad.png").write_bytes(b"\x89PNG not really an image")
    (d / "empty.png").write_bytes(b"")
    return d


@pytest.fixture
def emb(home):
    from semsearch import config
    from semsearch.embed import Embedder
    return Embedder(config.DEFAULTS["model"], config.models_dir())


def _sync(store, emb, folder, log=lambda m: None):
    from semsearch import config, indexer
    return indexer.sync(store, emb, config.load(), [str(folder)], log=log)


def test_finnish_and_english_images_are_found_in_their_language(helper, home, pics, emb):
    from semsearch.search import query
    from semsearch.store import Store
    with Store() as s:
        s.add_folder(str(pics))
        _sync(s, emb, pics)
        fi = [Path(r["path"]).name for r in query(s, emb, "kardemummapullan resepti", 3)]
        en = [Path(r["path"]).name for r in query(s, emb, "quarterly sales report northern region", 3)]
    assert fi[0] in {"fi_resepti.png", "fi_photo.jpg"}, fi
    assert en[0] == "en_screenshot.png", en


def test_image_without_text_is_kept_with_an_empty_chunk(helper, home, pics, emb):
    # Kept so that its file name finds it (test_names.py); its text is empty, so no content query matches it.
    from semsearch.store import Store
    with Store() as s:
        s.add_folder(str(pics))
        _sync(s, emb, pics)
        rows = s.db.execute("SELECT f.path, c.text FROM files f JOIN chunks c ON c.file_id = f.id").fetchall()
        names = {Path(r[0]).name for r in rows}
        photo = [text for path, text in rows if path.endswith("photo_no_text.jpg")]
    assert {"en_screenshot.png", "fi_resepti.png", "photo_no_text.jpg"} <= names
    assert photo == [""]


def test_corrupt_and_zero_byte_images_are_skipped_without_aborting(helper, home, pics, emb):
    from semsearch.store import Store
    logs = []
    with Store() as s:
        s.add_folder(str(pics))
        st = _sync(s, emb, pics, log=logs.append)
        names = {Path(r[0]).name for r in s.db.execute("SELECT path FROM files")}
    assert "bad.png" not in names and "empty.png" not in names
    assert "en_screenshot.png" in names and "fi_resepti.png" in names  # sync completed
    assert any("bad.png" in m for m in logs) and any("empty.png" in m for m in logs)
    assert st["images_skipped"] >= 2


def test_unchanged_and_renamed_images_are_never_reocred(helper, home, pics, emb, monkeypatch):
    from semsearch import ocr
    from semsearch.store import Store
    calls = []
    real = ocr.ocr_image

    def counting(*a, **k):
        calls.append(a[1])
        return real(*a, **k)

    monkeypatch.setattr(ocr, "ocr_image", counting)
    with Store() as s:
        s.add_folder(str(pics))
        _sync(s, emb, pics)
        first = len(calls)
        assert first >= 3
        _sync(s, emb, pics)                       # nothing changed
        assert len(calls) == first
        src = pics / "en_screenshot.png"
        src.rename(pics / "renamed_copy.png")     # same bytes, new name
        _sync(s, emb, pics)
        assert len(calls) == first
        names = {Path(r[0]).name for r in s.db.execute("SELECT path FROM files")}
    assert "renamed_copy.png" in names and "en_screenshot.png" not in names


def test_missing_helper_warns_once_and_indexes_text_files(home, pics, emb, monkeypatch):
    from semsearch import ocr
    from semsearch.store import Store
    monkeypatch.setattr(ocr, "find_helper", lambda log=print: None)
    (pics / "notes.md").write_text("Tavallinen tekstitiedosto kalastuksesta järvellä.\n")
    logs = []
    with Store() as s:
        s.add_folder(str(pics))
        _sync(s, emb, pics, log=logs.append)
        names = {Path(r[0]).name for r in s.db.execute("SELECT path FROM files")}
    assert "notes.md" in names and "en_screenshot.png" not in names
    assert sum("OCR helper unavailable" in m for m in logs) == 1


def test_ocr_accuracy_floor(helper):
    from semsearch import ocr
    truth = json.loads((FIXTURES / "ground_truth.json").read_text())
    from difflib import SequenceMatcher
    for name in ("en_screenshot.png", "fi_resepti.png"):
        got = ocr.ocr_image(helper, FIXTURES / name, ["sv-SE", "en-US"]).strip()
        ratio = SequenceMatcher(None, truth[name], got).ratio()
        assert ratio >= 0.95, (name, ratio, got)
