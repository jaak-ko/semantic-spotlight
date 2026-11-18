"""iCloud cloud-only files and per-folder progress. Cloud-only is faked with st_flags (SF_DATALESS) on the stat
result; no real iCloud is used. Downloads are real reads of local files, or fakes that fail or hang."""
import errno
import os
import time
import types
from pathlib import Path

import pytest

from semsearch import config, indexer
from semsearch.embed import Embedder
from semsearch.store import Store


@pytest.fixture
def emb(tmp_path, monkeypatch):
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    return Embedder(config.load()["model"], config.models_dir())


def _mk(root: Path, names):
    root.mkdir(parents=True, exist_ok=True)
    for name in names:
        (root / name).write_text(f"Lasagnelevyt uunissa, {name}.\n", encoding="utf-8")
    return root


def _cloud(monkeypatch, paths):
    """The given paths report SF_DATALESS (cloud-only) in their stat, the others are local."""
    real = os.stat
    cloud = {str(p) for p in paths}

    def stat(path):
        st = real(path)
        flags = indexer.SF_DATALESS if str(path) in cloud else 0
        return types.SimpleNamespace(st_mtime=st.st_mtime, st_size=st.st_size, st_flags=flags)
    monkeypatch.setattr(indexer, "_stat", stat)


def _sync(store, emb, folders, progress=None):
    return indexer.sync(store, emb, config.load(), [str(f) for f in folders], log=lambda m: None,
                        progress=progress)


def test_icloud_files_are_processed_after_the_local_ones(tmp_path, emb, monkeypatch):
    root = _mk(tmp_path / "docs", ["a.txt", "b.txt", "c1.txt", "c2.txt"])
    _cloud(monkeypatch, [root / "c1.txt", root / "c2.txt"])
    order = []
    real_index = indexer._index_file
    monkeypatch.setattr(indexer, "_index_file",
                        lambda ctx, path, folder: (order.append(Path(path).name), real_index(ctx, path, folder)))
    with Store() as s:
        s.add_folder(str(root))
        st = _sync(s, emb, [root])
        assert s.counts()[0] == 4
    assert order[-2:] == ["c1.txt", "c2.txt"] or set(order[-2:]) == {"c1.txt", "c2.txt"}
    assert set(order[:2]) == {"a.txt", "b.txt"}
    assert st["files_cloud_only"] == 2 and st["files_prefetched"] == 2


def test_an_unchanged_evicted_file_is_not_read_or_downloaded(tmp_path, emb, monkeypatch):
    root = _mk(tmp_path / "docs", ["a.txt", "evicted.txt"])
    with Store() as s:
        s.add_folder(str(root))
        _sync(s, emb, [root])  # indexed while local
        _cloud(monkeypatch, [root / "evicted.txt"])  # now evicted to the cloud, same size and mtime
        fetched, read = [], []
        monkeypatch.setattr(indexer, "_fetch", lambda path: fetched.append(path))
        real_read = indexer._read
        monkeypatch.setattr(indexer, "_read", lambda path, *a, **k: (read.append(path), real_read(path, *a, **k))[1])
        st = _sync(s, emb, [root])
    assert fetched == [] and read == [] and st["files_cloud_only"] == 0


def test_a_failed_download_is_a_skipped_file_and_the_run_goes_on(tmp_path, emb, monkeypatch):
    root = _mk(tmp_path / "docs", ["a.txt", "c1.txt", "c2.txt"])
    _cloud(monkeypatch, [root / "c1.txt", root / "c2.txt"])
    real_fetch = indexer._fetch

    def fetch(path):
        if path.endswith("c1.txt"):
            raise OSError(errno.EIO, "I/O error")
        return real_fetch(path)
    monkeypatch.setattr(indexer, "_fetch", fetch)
    with Store() as s:
        s.add_folder(str(root))
        st = _sync(s, emb, [root])
        assert s.counts()[0] == 2  # a.txt and c2.txt: c1.txt is skipped, not fatal
    assert st["error_classes"] == {"OSError": 1} and st["files_skipped"] == 1


def test_a_download_that_takes_too_long_is_skipped(tmp_path, emb, monkeypatch):
    root = _mk(tmp_path / "docs", ["slow.txt", "a.txt"])
    _cloud(monkeypatch, [root / "slow.txt"])
    monkeypatch.setattr(indexer, "CLOUD_TIMEOUT", 0.3)
    real_fetch = indexer._fetch

    def fetch(path):
        if path.endswith("slow.txt"):
            time.sleep(1.5)
        return real_fetch(path)
    monkeypatch.setattr(indexer, "_fetch", fetch)
    with Store() as s:
        s.add_folder(str(root))
        t0 = time.time()
        st = _sync(s, emb, [root])
        assert time.time() - t0 < 1.5
        assert s.counts()[0] == 1
    assert st["error_classes"] == {"TimeoutError": 1}


def test_read_ahead_of_cloud_files_is_bounded(tmp_path, emb, monkeypatch):
    names = [f"c{i:02d}.txt" for i in range(12)]
    root = _mk(tmp_path / "docs", names)
    _cloud(monkeypatch, [root / n for n in names])
    monkeypatch.setattr(indexer, "CLOUD_AHEAD", 3)
    started, at_first = [0], []
    real_fetch, real_index = indexer._fetch, indexer._index_file

    def fetch(path):
        started[0] += 1
        return real_fetch(path)

    def index(ctx, path, folder):
        if not at_first:
            at_first.append(started[0])
        return real_index(ctx, path, folder)
    monkeypatch.setattr(indexer, "_fetch", fetch)
    monkeypatch.setattr(indexer, "_index_file", index)
    with Store() as s:
        s.add_folder(str(root))
        _sync(s, emb, [root])
    assert at_first and at_first[0] <= indexer.CLOUD_AHEAD + 1 < len(names)


def test_progress_has_per_folder_totals_and_a_finished_folder_shows_done(tmp_path, emb):
    a = _mk(tmp_path / "small", [f"s{i}.txt" for i in range(3)])
    b = _mk(tmp_path / "big", [f"b{i}.txt" for i in range(7)])

    class Rec(indexer.Progress):
        def __init__(self):
            super().__init__()
            self.seen = []

        def tick(self, folder=None):
            super().tick(folder)
            self.seen.append(self.status())
    p = Rec()
    with Store() as s:
        s.add_folder(str(a))
        s.add_folder(str(b))
        _sync(s, emb, [a, b], progress=p)
    final = {f["path"]: f for f in p.status()["folders"]}
    assert final[str(a)] == {"path": str(a), "done": 3, "total": 3, "phase": "done"}
    assert final[str(b)] == {"path": str(b), "done": 7, "total": 7, "phase": "done"}
    assert any(
        {f["path"]: f for f in st["folders"]}[str(a)]["phase"] == "done"
        and {f["path"]: f for f in st["folders"]}[str(b)]["phase"] == "indexing"
        and {f["path"]: f for f in st["folders"]}[str(b)]["done"] < 7
        for st in p.seen)


def test_payload_shape_is_the_app_contract(tmp_path, emb):
    root = _mk(tmp_path / "docs", ["a.txt"])
    p = indexer.Progress()
    p.start_session()
    p.add_folder_work(str(root), 1)
    st = p.status()
    assert set(st) == {"phase", "done", "total", "waiting_cloud", "folders"}
    assert set(st["folders"][0]) == {"path", "done", "total", "phase"}
    assert set(p.snapshot()) == {"phase", "done", "total"}  # the run-level snapshot is unchanged


def test_waiting_cloud_counts_down_during_the_run(tmp_path, emb, monkeypatch):
    names = [f"c{i}.txt" for i in range(3)]
    root = _mk(tmp_path / "docs", names)
    _cloud(monkeypatch, [root / n for n in names])
    seen = []

    class Rec(indexer.Progress):
        def tick(self, folder=None):
            super().tick(folder)
            seen.append(self.waiting_cloud)
    with Store() as s:
        s.add_folder(str(root))
        _sync(s, emb, [root], progress=Rec())
    assert seen == [2, 1, 0]  # one file less waiting after each download


def test_adding_a_folder_mid_run_is_tracked_and_does_not_reread_the_first(tmp_path, emb, monkeypatch):
    a = _mk(tmp_path / "first", ["a1.txt", "a2.txt"])
    b = _mk(tmp_path / "second", ["b1.txt"])
    p = indexer.Progress()
    with Store() as s:
        s.add_folder(str(a))
        p.start_session()
        _sync(s, emb, [a], progress=p)  # the session is still running
        s.add_folder(str(b))
        read = []
        real_read = indexer._read
        monkeypatch.setattr(indexer, "_read", lambda path, *x, **k: (read.append(path), real_read(path, *x, **k))[1])
        _sync(s, emb, [b], progress=p)
    assert read == [str(b / "b1.txt")]
    folders = {f["path"]: f for f in p.status()["folders"]}
    assert folders[str(a)]["total"] == 2 and folders[str(b)]["total"] == 1
    assert p.status()["total"] == 3


def test_index_end_has_timing_fields_and_no_paths(tmp_path, emb):
    root = _mk(tmp_path / "docs", ["a.txt", "b.txt"])
    with Store() as s:
        s.add_folder(str(root))
        st = _sync(s, emb, [root])
    for key in ("seconds_scan", "seconds_read", "seconds_embed", "seconds_ocr", "slowest_file_seconds"):
        assert isinstance(st[key], (int, float)) and st[key] >= 0, key
    assert st["files_per_minute"] >= 0
    assert st["files_cloud_only"] == 0 and st["files_prefetched"] == 0
