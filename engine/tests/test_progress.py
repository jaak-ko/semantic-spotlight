"""Index progress for the app's progress bar: counts only, phases scanning -> indexing -> idle."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

BIN = Path(os.environ.get("SEMSEARCH_BIN") or Path(sys.executable).parent / "semsearch")  # verify_runtime.sh sets it


@pytest.fixture
def home(tmp_path, monkeypatch):
    h = tmp_path / "home" / ".semsearch"
    monkeypatch.setenv("SEMSEARCH_HOME", str(h))
    return h


@pytest.fixture
def emb(home):
    from semsearch import config
    from semsearch.embed import Embedder
    return Embedder(config.DEFAULTS["model"], config.models_dir())


def _notes(folder, n):
    folder.mkdir(parents=True, exist_ok=True)
    for i in range(n):
        (folder / f"note{i:02d}.md").write_text(f"Muistio {i}: kalastus järvellä ja metsäretki numero {i}.\n")


class Recording(__import__("semsearch.indexer", fromlist=["Progress"]).Progress):
    """Progress that remembers every transition, so the test can check the whole sequence."""

    def __init__(self):
        super().__init__()
        self.events = []

    def begin_scan(self):
        super().begin_scan()
        self.events.append(self.snapshot())

    def add_work(self, n):
        super().add_work(n)
        self.events.append(self.snapshot())

    def tick(self):
        super().tick()
        self.events.append(self.snapshot())


def _sync(store, emb, folder, progress, cfg=None):
    from semsearch import config, indexer
    return indexer.sync(store, emb, cfg or config.load(), [str(folder)], log=lambda m: None, progress=progress)


def test_progress_goes_scanning_to_indexing_and_reaches_total(home, emb, tmp_path):
    from semsearch.store import Store
    folder = tmp_path / "notes"
    _notes(folder, 4)
    p = Recording()
    with Store() as s:
        s.add_folder(str(folder))
        _sync(s, emb, folder, p)
    phases = [e["phase"] for e in p.events]
    assert phases[0] == "scanning" and p.events[0]["total"] == 0
    assert p.events[1] == {"phase": "indexing", "done": 0, "total": 4}
    dones = [e["done"] for e in p.events[2:]]
    assert dones == [1, 2, 3, 4]
    assert all(e["done"] <= e["total"] for e in p.events)
    p.end_session()
    assert p.snapshot() == {"phase": "idle", "done": 4, "total": 4}
    assert set(p.snapshot()) == {"phase", "done", "total"}  # counts only: no names or paths


def test_unchanged_rerun_reports_total_zero(home, emb, tmp_path):
    from semsearch.store import Store
    folder = tmp_path / "notes"
    _notes(folder, 3)
    with Store() as s:
        s.add_folder(str(folder))
        _sync(s, emb, folder, Recording())
        p = Recording()
        _sync(s, emb, folder, p)
    added = [e["total"] for e in p.events if e["phase"] == "indexing"]
    assert added == [0]
    assert p.snapshot()["done"] == 0


def test_bad_files_still_count_as_done(home, emb, tmp_path):
    from semsearch.store import Store
    if os.geteuid() == 0:
        pytest.skip("root ignores chmod 000")
    folder = tmp_path / "notes"
    _notes(folder, 2)
    os.symlink(str(tmp_path / "missing.txt"), folder / "dangling.txt")  # skipped during the scan
    locked = folder / "locked.txt"
    locked.write_text("salainen")
    locked.chmod(0)  # fails while reading
    p = Recording()
    try:
        with Store() as s:
            s.add_folder(str(folder))
            _sync(s, emb, folder, p)
    finally:
        locked.chmod(0o600)
    p.end_session()
    assert p.snapshot() == {"phase": "idle", "done": 4, "total": 4}


def test_status_during_a_daemon_run_never_shows_done_above_total(home, tmp_path):
    from semsearch.daemon import Daemon
    folder = tmp_path / "notes"
    _notes(folder, 40)
    d = Daemon()
    assert d.dispatch({"cmd": "add", "path": str(folder)})["ok"]
    seen = []
    deadline = time.time() + 300
    while time.time() < deadline:
        st = d.dispatch({"cmd": "status"})
        seen.append(st)
        if not st["indexing"] and seen and len(seen) > 1 and st["progress"]["total"] > 0:
            break
        time.sleep(0.01)
    assert seen
    for st in seen:
        pr = st["progress"]
        assert pr["done"] <= pr["total"], pr
        assert st["indexing"] == (pr["phase"] != "idle")
    assert seen[-1]["progress"] == {"phase": "idle", "done": 40, "total": 40}


def test_cli_status_adds_progress_only_when_a_daemon_answers(home, tmp_path, capsys):
    from semsearch.cli import main
    assert main(["status", "--json"]) == 0
    assert "progress" not in json.loads(capsys.readouterr().out)
    short = Path(tempfile.mkdtemp(prefix="ss-", dir="/tmp")) / "h"  # short: the socket path must fit
    env = {**os.environ, "SEMSEARCH_HOME": str(short), "HOME": str(tmp_path / "home")}
    proc = subprocess.Popen([str(BIN), "daemon"], env=env, stderr=subprocess.PIPE)
    try:
        deadline = time.time() + 120
        while not (short / "daemon.sock").exists() and time.time() < deadline and proc.poll() is None:
            time.sleep(0.2)
        os.environ["SEMSEARCH_HOME"] = str(short)
        try:
            assert main(["status", "--json"]) == 0
        finally:
            os.environ["SEMSEARCH_HOME"] = str(home)
        st = json.loads(capsys.readouterr().out)
        assert st["progress"] == {"phase": "idle", "done": 0, "total": 0}
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=30)
        shutil.rmtree(short.parent, ignore_errors=True)
