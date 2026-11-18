"""Audit fixes: queries racing indexing, removal during a run, embed slices, caches, uninstall and daemon guards."""
import fcntl
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import numpy as np
import pytest

SRC_CORPUS = Path(__file__).parent / "corpus"
BIN = Path(os.environ.get("SEMSEARCH_BIN") or Path(sys.executable).parent / "semsearch")  # verify_runtime.sh sets it


@pytest.fixture
def env(tmp_path, monkeypatch):
    home = Path(tempfile.mkdtemp(prefix="ss-", dir="/tmp")) / "home"  # short: AF_UNIX path limit
    monkeypatch.setenv("SEMSEARCH_HOME", str(home))
    corpus = tmp_path / "corpus"
    shutil.copytree(SRC_CORPUS, corpus)
    return {"home": home, "corpus": corpus}


@pytest.fixture
def emb(env):
    from semsearch import config
    from semsearch.embed import Embedder
    return Embedder(config.load()["model"], config.models_dir())


def _sync(store, emb, folders, log=lambda m: None):
    from semsearch import config, indexer
    return indexer.sync(store, emb, config.load(), folders, log=log)


# 1. search: a chunk id that is not in the vector list must not index past the end or pick a neighbour

class _FakeStore:
    def __init__(self, ids, mat, kw, info):
        self.ids, self.mat, self.kw, self.info = ids, mat, kw, info

    def vectors(self):
        return self.ids, self.mat

    def name_vectors(self):  # no file names in this fake index
        return np.zeros(0, dtype=np.int64), np.zeros((0, 0), dtype=np.float32)

    def fts_ids(self, match, limit, scope=None):
        return self.kw

    def chunk_info(self, ids):
        return {i: self.info[i] for i in ids if i in self.info}


class _FakeEmb:
    def embed(self, texts, kind):
        return np.ones((len(texts), 2), dtype=np.float32)


def test_keyword_hit_missing_from_vector_list_is_keyword_only():
    from semsearch import config
    from semsearch.search import query
    info = {1: {"path": "/c/a.txt", "start": 0, "end": 5, "text": "alpha"},
            2: {"path": "/c/b.txt", "start": 0, "end": 4, "text": "beta"},
            3: {"path": "/c/c.txt", "start": 0, "end": 5, "text": "gamma"},
            99: {"path": "/c/ghost.txt", "start": 0, "end": 12, "text": "ERR-40417 gh"}}
    store = _FakeStore(np.array([1, 2, 3], dtype=np.int64),
                       np.array([[1, 0], [0, 1], [0.5, 0.5]], dtype=np.float32), [99], info)
    res = query(store, _FakeEmb(), "ERR-40417", n=5, cfg=dict(config.DEFAULTS))
    ghost = [r for r in res if r["path"] == "/c/ghost.txt"]
    assert ghost and ghost[0]["similarity"] == 0.0  # no vector: kept only by its exact term


def test_queries_while_indexing_do_not_fail(env, emb):
    from semsearch import config
    from semsearch.search import query
    from semsearch.store import Store
    corpus = env["corpus"]
    cfg = config.load()
    with Store() as s:
        s.add_folder(str(corpus))
        _sync(s, emb, [str(corpus)])
    for i in range(30):
        (corpus / f"late{i:02d}.md").write_text(f"late note {i} about ERR-40417 and pipelines\n")
    errors = []

    def index():
        try:
            for _ in range(3):
                with Store() as s:
                    _sync(s, emb, [str(corpus)])
        except Exception as e:  # reported by the assert below
            errors.append(e)

    t = threading.Thread(target=index)
    t.start()
    with Store() as qs:
        while t.is_alive():
            try:
                query(qs, emb, "ERR-40417 pipelines", 5, cfg)
            except Exception as e:
                errors.append(e)
                break
    t.join()
    assert errors == []


# 2. a folder removed during a run leaves none of its files behind

def test_folder_removed_during_sync_leaves_no_files(env, emb, monkeypatch):
    from semsearch import indexer
    from semsearch.search import query
    from semsearch.store import Store
    corpus = str(env["corpus"])
    with Store() as s:
        s.add_folder(corpus)
    real_extract = indexer._extract
    fired = []

    def remove_midway(ctx, path, st):
        if not fired:
            fired.append(path)
            ctx["store"].commit()  # release the sync's write lock so the other connection can remove
            with Store() as other:
                other.remove_folder(corpus)
        return real_extract(ctx, path, st)

    monkeypatch.setattr(indexer, "_extract", remove_midway)
    with Store() as s:
        _sync(s, emb, [corpus])
    assert fired, "the removal never ran"
    with Store() as s:
        assert s.files_under(corpus) == []
        assert query(s, emb, "ERR-40417", 5) == []


# 3. embedding slices: a query waits for one slice, not for a whole file

def test_query_not_starved_by_large_embed():
    # Counts texts, not seconds: the query is served before the large embed has covered all 320 texts.
    from semsearch import embed
    served = []  # one entry per encode call: "q" for the query, else how many large-embed texts it covered

    class Slow:
        def encode(self, batch, **kw):
            served.append("q" if batch[0] == "q" else len(batch))
            time.sleep(0.01 * len(batch))  # keeps the model busy while a query could wait
            return np.ones((len(batch), 4), dtype=np.float32)

    e = object.__new__(embed.Embedder)
    e.name, e.model, e.prefix = "x", Slow(), {"passage": "", "query": ""}
    t = threading.Thread(target=e.embed, args=(["t"] * 320, "passage"))
    t.start()
    deadline = time.time() + 60
    while not served and time.time() < deadline:  # the large embed has started
        time.sleep(0.001)
    e.embed(["q"], "query")
    big_before_query = sum(served[:served.index("q")])
    t.join()
    assert big_before_query < 320, f"query waited behind {big_before_query} of 320 large-embed texts"


# 4. folder_stats cached by generation; opening the index does not re-run the schema

def test_folder_stats_not_rescanned_without_change(env):
    from semsearch.store import Store
    with Store() as s:
        s.add_folder(str(env["corpus"]))
        s.commit()
    with Store() as s:
        first = s.folder_stats()
    seen = []
    with Store() as s:
        s.db.set_trace_callback(seen.append)
        second = s.folder_stats()
    assert second == first
    assert not [q for q in seen if "LIKE" in q]


def test_open_does_not_rerun_schema(env, monkeypatch):
    from semsearch import store as store_mod
    from semsearch.store import Store
    with Store() as s:
        s.add_folder(str(env["corpus"]))
    monkeypatch.setattr(store_mod, "SCHEMA", "THIS IS NOT SQL")  # would fail if executed again
    with Store() as s:
        assert s.folders() == [str(env["corpus"])]


# 5. the vector matrix is not rebuilt on every commit

def test_new_chunk_appears_after_refresh_interval(env, monkeypatch):
    from semsearch import store as store_mod
    from semsearch.store import Store
    vec = np.ones(4, dtype=np.float32).tobytes()
    with Store() as a:
        fid = a.add_file("/c/one.txt", 1.0, 1, "s1")
        a.add_chunk(fid, 0, 0, 3, "one", vec, "one")
        a.commit()
        assert len(a.vectors()[0]) == 1
        with Store() as b:  # another writer commits a new chunk
            fid2 = b.add_file("/c/two.txt", 1.0, 1, "s2")
            b.add_chunk(fid2, 0, 0, 3, "two", vec, "two")
        monkeypatch.setattr(store_mod, "VEC_REFRESH_SECONDS", 1000.0)
        assert len(a.vectors()[0]) == 1  # within the interval: the snapshot is reused
        monkeypatch.setattr(store_mod, "VEC_REFRESH_SECONDS", 0.0)
        assert len(a.vectors()[0]) == 2  # after it: the new chunk is found


# 6. uninstall never removes a folder that holds the user's own files

def test_uninstall_refuses_home_with_foreign_file(env):
    home = env["home"]
    home.mkdir(parents=True)
    (home / "index.db").write_bytes(b"")
    (home / "notes.txt").write_text("mine")
    r = subprocess.run([str(BIN), "uninstall", "--yes"], capture_output=True, text=True,
                       env={**os.environ, "SEMSEARCH_HOME": str(home)})
    assert r.returncode == 1 and "notes.txt" in r.stderr
    assert (home / "notes.txt").exists() and (home / "index.db").exists()


def test_uninstall_removes_home_with_only_engine_files(env):
    home = env["home"]
    home.mkdir(parents=True)
    for name in ("index.db", "index.db-wal", "config.json", "daemon.sock", "app-daemon.log"):
        (home / name).write_bytes(b"")
    (home / "models").mkdir()
    r = subprocess.run([str(BIN), "uninstall", "--yes"], capture_output=True, text=True,
                       env={**os.environ, "SEMSEARCH_HOME": str(home)})
    assert r.returncode == 0 and not home.exists()


# 7. nice-to-haves

def test_skipped_file_logged_once_across_syncs(env, emb):
    from semsearch.store import Store
    corpus = env["corpus"]
    os.symlink("/nonexistent/none.txt", corpus / "dangling.txt")
    with Store() as s:
        s.add_folder(str(corpus))
    lines = []
    with Store() as s:
        _sync(s, emb, [str(corpus)], log=lines.append)
    with Store() as s:
        _sync(s, emb, [str(corpus)], log=lines.append)
    assert sum("dangling.txt" in m for m in lines) == 1


def test_ocr_cache_drops_entries_of_vanished_images(env):
    from semsearch.store import Store
    corpus = env["corpus"]
    kept = corpus / "scan.png"
    kept.write_bytes(b"x")
    with Store() as s:
        s.add_folder(str(corpus))
        s.put_ocr("a|sv", "text one", str(kept))
        s.put_ocr("b|sv", "gone", str(corpus / "old.png"))
        s.commit()
    with Store() as s:
        s.prune_ocr([str(corpus)])
    with Store() as s:
        assert s.get_ocr("a|sv", str(kept)) == "text one"
        assert s.get_ocr("b|sv", str(corpus / "old.png")) is None


def test_sync_prunes_ocr_only_when_all_folders_were_synced(env, emb, monkeypatch):
    from semsearch import store as store_mod
    from semsearch.store import Store
    calls = []
    monkeypatch.setattr(store_mod.Store, "prune_ocr", lambda self, folders: calls.append(folders))
    with Store() as s:
        s.add_folder(str(env["corpus"]))
        _sync(s, emb, [str(env["corpus"])])
    assert calls == []
    with Store() as s:
        _sync(s, emb, None)
    assert len(calls) == 1


def test_second_daemon_refuses_while_lock_held(env):
    home = env["home"]
    home.mkdir(parents=True)
    fd = os.open(home / "daemon.lock", os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        r = subprocess.run([str(BIN), "daemon"], capture_output=True, text=True, timeout=60,
                           env={**os.environ, "SEMSEARCH_HOME": str(home)})
    finally:
        os.close(fd)
    assert r.returncode == 1 and "already running" in r.stderr


def test_query_without_text_gets_clear_error():
    from semsearch.daemon import Daemon
    r = Daemon().dispatch({"cmd": "query"})
    assert r == {"ok": False, "error": "query needs the search text in q"}


def test_abandon_drops_unrun_items_from_total():
    from semsearch.indexer import Progress
    p = Progress()
    p.start_session()
    p.add_work(5)
    p.tick()
    p.tick()
    p.abandon()  # 3 items of a failed folder never run: they leave the total
    assert p.snapshot() == {"phase": "indexing", "done": 2, "total": 2}
    p.add_work(3)  # the next folder in the batch still runs and counts
    for _ in range(3):
        p.tick()
    assert p.snapshot() == {"phase": "indexing", "done": 5, "total": 5}
