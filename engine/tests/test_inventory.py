"""Nothing the engine writes under a home directory lands outside its own .semsearch folder.
See engine/UNINSTALL_INVENTORY.md for the full list, including the macOS paths we cannot redirect."""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

ENGINE = Path(__file__).resolve().parents[1]
CORPUS = Path(__file__).parent / "corpus"


def _tree(root: Path) -> set:
    return {str(p) for p in root.rglob("*")} if root.exists() else set()


def _cli(home: Path, *args):
    env = {"HOME": str(home), "PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1",
           "SEMSEARCH_MODELS": os.environ["SEMSEARCH_MODELS"]}  # the session's private model clone
    return subprocess.run([sys.executable, "-c", "import sys; from semsearch.cli import main; sys.exit(main(sys.argv[1:]))", *args],
                          env=env, capture_output=True, text=True, cwd=str(ENGINE))


def test_engine_writes_only_inside_semsearch_under_home(tmp_path):
    if not os.environ.get("SEMSEARCH_MODELS"):
        pytest.skip("no model clone available")
    home = Path(tempfile.mkdtemp(prefix="ss-", dir="/tmp")) / "h"  # short: the daemon socket path must fit
    home.mkdir()
    folder = tmp_path / "notes"
    shutil.copytree(CORPUS, folder)
    before = _tree(home)

    assert _cli(home, "add", str(folder)).returncode == 0
    assert _cli(home, "query", "ERR-40417", "-n", "1").returncode == 0

    env = {"HOME": str(home), "PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1",
           "SEMSEARCH_MODELS": os.environ["SEMSEARCH_MODELS"]}
    proc = subprocess.Popen([sys.executable, "-c", "import sys; from semsearch.cli import main; sys.exit(main(sys.argv[1:]))", "daemon"],
                            env=env, cwd=str(ENGINE), stderr=subprocess.PIPE)
    try:
        sock = home / ".semsearch" / "daemon.sock"
        deadline = time.time() + 120
        while not sock.exists() and time.time() < deadline and proc.poll() is None:
            time.sleep(0.2)
        with socket.socket(socket.AF_UNIX) as s:
            s.connect(str(sock))
            s.sendall(b'{"cmd": "query", "q": "ERR-40417", "n": 1}\n')
            assert json.loads(s.recv(1 << 20))["ok"] is True
        with socket.socket(socket.AF_UNIX) as s:
            s.connect(str(sock))
            s.sendall(b'{"cmd": "shutdown"}\n')
            s.recv(4096)
        assert proc.wait(timeout=60) == 0
    finally:
        if proc.poll() is None:
            proc.kill()

    new = _tree(home) - before - {str(home), str(home / ".semsearch")}  # the two container folders
    outside = sorted(p for p in new if not p.startswith(str(home / ".semsearch") + os.sep))
    assert outside == [], outside
    assert any(p.endswith("index.db") for p in new)  # the check ran against a real index
