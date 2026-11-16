"""Daemon protocol limits, the shutdown command, and uninstall."""
import io
import json
import os
import socket
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


def test_huge_request_line_is_rejected_without_reading_it_all(home):
    from semsearch import daemon
    h = daemon.Handler.__new__(daemon.Handler)
    h.rfile = io.BytesIO(b"x" * (8 << 20))  # 8 MB with no newline
    h.wfile = io.BytesIO()
    daemon.Handler.handle(h)
    assert h.rfile.tell() <= daemon.MAX_REQUEST + 1  # never read past the limit
    assert json.loads(h.wfile.getvalue())["ok"] is False


def test_n_is_clamped_to_1_50(home, monkeypatch):
    from semsearch import daemon, search
    seen = []
    monkeypatch.setattr(search, "query", lambda store, emb, q, n, cfg, folders=None: seen.append(n) or [])
    d = daemon.Daemon()
    monkeypatch.setattr(d, "embedder", lambda: None)  # the clamp needs no model
    from semsearch.store import Store
    with Store() as s:  # query() only runs when an index exists
        pass
    for n in (0, -5, 1000, 7):
        assert d.dispatch({"cmd": "query", "q": "x", "n": n})["ok"] is True
    assert seen == [1, 1, 50, 7]


def test_shutdown_command_stops_the_daemon(tmp_path):
    home = Path(tempfile.mkdtemp(prefix="ss-", dir="/tmp")) / "h"  # short: the daemon socket path must fit
    env = {**os.environ, "SEMSEARCH_HOME": str(home), "HOME": str(tmp_path / "home")}
    proc = subprocess.Popen([str(BIN), "daemon"], env=env, stderr=subprocess.PIPE)
    try:
        sock = home / "daemon.sock"
        deadline = time.time() + 120
        while not sock.exists() and time.time() < deadline and proc.poll() is None:
            time.sleep(0.2)
        with socket.socket(socket.AF_UNIX) as s:
            s.connect(str(sock))
            s.sendall(b'{"cmd": "shutdown"}\n')
            assert json.loads(s.recv(4096))["ok"] is True
        assert proc.wait(timeout=30) == 0
        assert not sock.exists()
    finally:
        if proc.poll() is None:
            proc.kill()


def test_uninstall_lists_then_removes_only_the_home(home, tmp_path, monkeypatch, capsys):
    from semsearch.cli import main
    home.mkdir(parents=True)
    (home / "index.db").write_text("x")
    assert main(["uninstall"]) == 0
    assert (home / "index.db").exists() and "index.db" in capsys.readouterr().out
    assert main(["uninstall", "--yes"]) == 0
    assert not home.exists()


def test_uninstall_refuses_the_user_home(tmp_path, monkeypatch, capsys):
    from semsearch.cli import main
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setenv("HOME", str(fake_home))
    monkeypatch.setenv("SEMSEARCH_HOME", str(fake_home))  # pointing the engine home at $HOME must not delete it
    assert main(["uninstall", "--yes"]) == 1
    assert fake_home.exists()
