"""Regression tests for the repo audit. Every test uses a temp SEMSEARCH_HOME and temp folders."""
import json
import os
import stat
import threading
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
PIN = "614241f622f53c4eeff9890bdc4f31cfecc418b3"


@pytest.fixture
def home(tmp_path, monkeypatch):
    h = tmp_path / "home"
    monkeypatch.setenv("SEMSEARCH_HOME", str(h))
    return h


@pytest.fixture
def emb(home):
    from semsearch import config
    from semsearch.embed import Embedder
    return Embedder(config.DEFAULTS["model"], config.models_dir())


def _sync(store, emb, folder, cfg=None, log=lambda m: None):
    from semsearch import config, indexer
    return indexer.sync(store, emb, cfg or config.load(), [str(folder)], log=log)


# ---- item 1: one bad file must not abort indexing ---------------------------------
def test_bad_files_do_not_abort_indexing(home, emb, tmp_path):
    from semsearch.store import Store
    if os.geteuid() == 0:
        pytest.skip("root ignores chmod 000")
    folder = tmp_path / "notes"
    folder.mkdir()
    (folder / "good1.md").write_text("Kalastusreissu järvelle.\n")
    (folder / "good2.md").write_text("Pizzan resepti kotona.\n")
    os.symlink(str(tmp_path / "missing.txt"), folder / "dangling.txt")          # dangling symlink
    locked = folder / "locked.txt"
    locked.write_text("salainen")
    locked.chmod(0)                                                             # permission denied
    outside = tmp_path / "outside.txt"
    outside.write_text("ulkopuolinen")
    os.symlink(str(outside), folder / "escape.txt")                             # resolves outside folder
    logs = []
    with Store() as s:
        s.add_folder(str(folder))
        st = _sync(s, emb, folder, log=logs.append)
        names = sorted(Path(p).name for _, p in s.files_under(str(folder)))
    locked.chmod(0o600)
    assert names == ["good1.md", "good2.md"], names
    assert st["files_embedded"] == 2
    assert any("locked.txt" in m for m in logs) and any("dangling.txt" in m for m in logs)


def test_unreadable_file_keeps_its_existing_row(home, emb, tmp_path):
    from semsearch.store import Store
    if os.geteuid() == 0:
        pytest.skip("root ignores chmod 000")
    folder = tmp_path / "notes"
    folder.mkdir()
    f = folder / "a.md"
    f.write_text("první versio\n")
    with Store() as s:
        s.add_folder(str(folder))
        _sync(s, emb, folder)
        f.write_text("toinen versio, pitempi\n")  # mtime changes -> re-read attempted
        f.chmod(0)
        _sync(s, emb, folder)
        remaining = [p for _, p in s.files_under(str(folder))]
    f.chmod(0o600)
    assert remaining == [str(f)]


# ---- item 2: privacy of the index directory and database ------------------------
def test_home_dir_is_0700_fresh_and_existing(tmp_path, monkeypatch):
    from semsearch import config
    fresh = tmp_path / "fresh"
    monkeypatch.setenv("SEMSEARCH_HOME", str(fresh))
    config.ensure_home()  # the write path creates it; a lookup alone does not (see test_paths)
    assert stat.S_IMODE(fresh.stat().st_mode) == 0o700
    old = tmp_path / "old"
    old.mkdir(mode=0o755)
    old.chmod(0o755)
    monkeypatch.setenv("SEMSEARCH_HOME", str(old))
    config.ensure_home()
    assert stat.S_IMODE(old.stat().st_mode) == 0o700


def test_index_db_and_wal_files_are_0600(home, tmp_path):
    from semsearch.store import Store
    folder = tmp_path / "f"
    folder.mkdir()
    with Store() as s:
        s.add_folder(str(folder))
        s.set_meta("x", "1")
        s.commit()
        base = s.path
        for suffix in ("", "-wal", "-shm"):
            p = Path(str(base) + suffix)
            if p.exists():
                assert stat.S_IMODE(p.stat().st_mode) == 0o600, p
        assert stat.S_IMODE(base.stat().st_mode) == 0o600


# ---- item 3: concurrent index requests are never lost ---------------------------
def test_add_during_indexing_is_indexed(home, tmp_path):
    from semsearch.daemon import Daemon
    from semsearch.store import Store
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir(), b.mkdir()
    for i in range(60):  # enough work that the second add arrives mid-run
        (a / f"n{i}.md").write_text(f"Muistio numero {i} kalastuksesta ja metsästä.\n" * 20)
    (b / "second.md").write_text("Toisen kansion tiedosto, kuutamo ja järvi.\n")
    d = Daemon()
    assert d.dispatch({"cmd": "add", "path": str(a)})["ok"]
    assert d.dispatch({"cmd": "add", "path": str(b)})["ok"]
    deadline = time.time() + 300
    while d.indexing and time.time() < deadline:
        time.sleep(0.1)
    with Store() as s:
        names = {Path(r[0]).name for r in s.db.execute("SELECT path FROM files")}
    assert "second.md" in names and "n0.md" in names, names


def test_two_index_workers_never_run_at_once(home, tmp_path, monkeypatch):
    from semsearch import indexer
    from semsearch.daemon import Daemon
    active, peak, lock = [0], [0], threading.Lock()
    real = indexer.sync

    def tracked(*a, **k):
        with lock:
            active[0] += 1
            peak[0] = max(peak[0], active[0])
        try:
            time.sleep(0.2)
            return real(*a, **k)
        finally:
            with lock:
                active[0] -= 1

    monkeypatch.setattr(indexer, "sync", tracked)
    d = Daemon()
    for i in range(3):
        p = tmp_path / f"d{i}"
        p.mkdir()
        (p / "x.md").write_text("tekstiä\n")
        d.dispatch({"cmd": "add", "path": str(p)})
    deadline = time.time() + 300
    while d.indexing and time.time() < deadline:
        time.sleep(0.1)
    assert peak[0] == 1


# ---- item 4: similarity field and floor ---------------------------------------------
def test_results_expose_similarity_and_floor_keeps_exact_id(home, emb, tmp_path):
    from semsearch import config
    from semsearch.search import query
    from semsearch.store import Store
    folder = tmp_path / "n"
    folder.mkdir()
    (folder / "err.log").write_text("ERROR ERR-40417 levy täynnä\n")
    (folder / "ruoka.md").write_text("Kardemummapullan resepti, voita ja sokeria.\n")
    cfg = config.load()
    with Store() as s:
        s.add_folder(str(folder))
        _sync(s, emb, folder, cfg)
        res = query(s, emb, "ERR-40417", 3, cfg)
        assert res and isinstance(res[0]["similarity"], float)
        assert -1.0 <= res[0]["similarity"] <= 1.0
        strict = dict(cfg, min_similarity=1.01)  # nothing passes a similarity floor of 1.01
        kept = query(s, emb, "ERR-40417", 3, strict)
        assert [Path(r["path"]).name for r in kept] == ["err.log"]
        assert query(s, emb, "pizzeria Roomassa", 3, strict) == []


def test_min_similarity_default_exists():
    from semsearch import config
    assert isinstance(config.DEFAULTS["min_similarity"], float)
    assert "trigram" not in config.DEFAULTS


# ---- item 6: pinned model revision --------------------------------------------------
def test_model_revision_is_pinned_and_in_signature():
    from semsearch import indexer, modelfiles, config
    assert modelfiles.REV == PIN
    assert PIN in indexer.index_signature(config.DEFAULTS, config.DEFAULTS["model"])


def test_model_ready_with_pinned_snapshot_regardless_of_ref(tmp_path, monkeypatch):
    from semsearch import modelfiles
    monkeypatch.setenv("SEMSEARCH_MODELS", str(tmp_path / "m"))
    base = tmp_path / "m" / "models--intfloat--multilingual-e5-small"
    snap = base / "snapshots" / PIN
    (snap / "1_Pooling").mkdir(parents=True)
    for f in ["config.json", "model.safetensors", "modules.json", "sentence_bert_config.json",
              "sentencepiece.bpe.model", "special_tokens_map.json", "tokenizer.json",
              "tokenizer_config.json", "1_Pooling/config.json"]:
        (snap / f).write_text("x")
    assert not modelfiles.model_ready(modelfiles.DEFAULT_MODEL)      # files linked but not verified yet
    (base / "verified").write_text(PIN)                               # written by fetch() after the SHA-256 checks
    assert modelfiles.model_ready(modelfiles.DEFAULT_MODEL)           # no refs/ file at all
    (base / "refs").mkdir()
    (base / "refs" / "main").write_text("main")                       # legacy ref naming
    assert modelfiles.model_ready(modelfiles.DEFAULT_MODEL)
    (base / "refs" / "main").write_text("0" * 40)                     # other commit: not our pinned one
    assert modelfiles.model_ready(modelfiles.DEFAULT_MODEL)


# ---- item 7: bad config.json ---------------------------------------------------------
@pytest.mark.parametrize("content", ["{not json", "[1, 2, 3]"])
def test_bad_config_falls_back_to_defaults_and_is_not_overwritten(home, capsys, content):
    from semsearch import config
    home.mkdir(parents=True)
    f = home / "config.json"
    f.write_text(content)
    cfg = config.load()
    assert cfg["chunk_tokens"] == config.DEFAULTS["chunk_tokens"]
    assert f.read_text() == content
    assert "warning" in capsys.readouterr().err


# ---- item 8: batched commits -----------------------------------------------------------
def test_sync_commits_in_batches(home, emb, tmp_path, monkeypatch):
    from semsearch.store import Store
    folder = tmp_path / "many"
    folder.mkdir()
    for i in range(120):
        (folder / f"f{i:03d}.md").write_text(f"Tiedosto {i} metsästä ja järvistä.\n")
    commits = [0]
    real = Store.commit

    def counting(self):
        if self._dirty:
            commits[0] += 1
        real(self)

    monkeypatch.setattr(Store, "commit", counting)
    with Store() as s:
        s.add_folder(str(folder))
        _sync(s, emb, folder)
        n = s.counts()[0]
    assert n == 120
    assert commits[0] <= 6, commits[0]


# ---- item 9: remove_folder keeps files still under another folder ----------------------
def test_remove_nested_folder_keeps_parent_files(home, emb, tmp_path):
    from semsearch.store import Store
    parent = tmp_path / "parent"
    child = parent / "child"
    child.mkdir(parents=True)
    (parent / "p.md").write_text("isän tiedosto\n")
    (child / "c.md").write_text("lapsen tiedosto\n")
    with Store() as s:
        s.add_folder(str(parent))
        s.add_folder(str(child))
        _sync(s, emb, parent)
        s.remove_folder(str(child))
        s.commit()
        left = sorted(Path(p).name for _, p in s.files_under(str(parent)))
    assert left == ["c.md", "p.md"], left  # child is still under the registered parent
