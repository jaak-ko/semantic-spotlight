"""Memory safety net: above RSS_LIMIT_MB, an index run stops after its current commit (nothing half-written), and
the daemon exits with EXIT_RESTART so the app relaunches it. Status reports rss_mb."""
import pytest

from semsearch import config, daemon, indexer
from semsearch.embed import Embedder
from semsearch.store import Store


@pytest.fixture
def emb(tmp_path, monkeypatch):
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    return Embedder(config.load()["model"], config.models_dir())


def _folder(tmp_path, n):
    root = tmp_path / "docs"
    root.mkdir()
    for i in range(n):
        (root / f"doc {i}.txt").write_text(f"Lasagnelevyt uunissa {i}.\n", encoding="utf-8")
    return root


def test_sync_stops_after_a_commit_above_the_limit(tmp_path, emb, monkeypatch):
    root = _folder(tmp_path, 6)
    monkeypatch.setattr(indexer, "COMMIT_EVERY_FILES", 2)
    monkeypatch.setattr(indexer, "RSS_LIMIT_MB", 1000)
    monkeypatch.setattr(indexer, "rss_mb", lambda: 4000)
    with Store() as s:
        s.add_folder(str(root))
        st = indexer.sync(s, emb, config.load(), [str(root)], log=lambda m: None)
        files, _ = s.counts()
    assert st["memory_limit"] is True
    assert 0 < files < 6  # some files committed, the rest left for the next run
    assert st["files_embedded"] < 6


def test_sync_runs_to_the_end_under_the_limit(tmp_path, emb, monkeypatch):
    root = _folder(tmp_path, 4)
    monkeypatch.setattr(indexer, "rss_mb", lambda: 10)
    with Store() as s:
        s.add_folder(str(root))
        st = indexer.sync(s, emb, config.load(), [str(root)], log=lambda m: None)
        assert s.counts()[0] == 4
    assert st["memory_limit"] is False and st["files_embedded"] == 4


def test_daemon_worker_restarts_on_memory_limit(tmp_path, monkeypatch):
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    monkeypatch.setattr(daemon, "EXIT_CODE", 0)
    monkeypatch.setattr(daemon, "SERVER", type("S", (), {"shutdown": lambda self: None})())
    monkeypatch.setattr(indexer, "sync", lambda *a, **k: {"memory_limit": True})
    d = daemon.Daemon()
    d.embedder = lambda: None
    monkeypatch.setattr(daemon, "Store", lambda: type("St", (), {"__enter__": lambda s: s, "__exit__": lambda s, *e: None})())
    d._start_index(None)
    import time
    deadline = time.time() + 10
    while daemon.EXIT_CODE == 0 and time.time() < deadline:
        time.sleep(0.05)
    assert daemon.EXIT_CODE == daemon.EXIT_RESTART == 75
    assert daemon.STOP_REASON == "memory"


def test_index_events_carry_memory_fields(tmp_path, emb, monkeypatch):
    import json
    from semsearch import events
    root = _folder(tmp_path, 3)
    home = tmp_path / "home"  # SEMSEARCH_HOME (the emb fixture sets it)
    monkeypatch.setattr(events, "_enabled", True)
    monkeypatch.setattr(indexer, "rss_mb", lambda: 500)
    with Store() as s:
        s.add_folder(str(root))
        st = indexer.sync(s, emb, config.load(), [str(root)], log=lambda m: None)
    assert st["peak_rss_mb"] == 500
    recs = [json.loads(x) for x in (home / "events.jsonl").read_text(encoding="utf-8").splitlines()]
    start = [r for r in recs if r["event"] == "index_start"][0]
    end = [r for r in recs if r["event"] == "index_end"][0]
    assert start["rss_mb"] == 500
    assert end["rss_mb"] == 500 and end["peak_rss_mb"] == 500
