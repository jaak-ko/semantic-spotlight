"""An install from before the `verified` marker is checked offline (blob names are content hashes) and marked.
A corrupt or truncated install is not marked. A marked install is not hashed again. No network is touched."""
import hashlib
import json
import os
import socket
import threading
import time
from pathlib import Path

import pytest

from semsearch import modelfiles

REPO = modelfiles.DEFAULT_MODEL
LFS = "model.safetensors"  # its blob name is the sha256 of the bytes (LFS)
FILES = [f for f in modelfiles.PATTERNS[REPO] if "*" not in f] + ["1_Pooling/config.json"]


def _git_sha1(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


@pytest.fixture(autouse=True)
def fresh_state(monkeypatch):
    monkeypatch.setattr(modelfiles, "_verdicts", {})
    monkeypatch.setattr(modelfiles, "_verifying", set())


@pytest.fixture
def models(tmp_path, monkeypatch):
    m = tmp_path / "models"
    monkeypatch.setenv("SEMSEARCH_MODELS", str(m))
    return m


@pytest.fixture
def old_install(models):
    """An HF-cache install as fetch-model left it before the marker: blobs named by hash, snapshot links to them."""
    base = modelfiles.model_dir(REPO)
    blobs, snap = base / "blobs", base / "snapshots" / modelfiles.REV
    blobs.mkdir(parents=True)
    for f in FILES:
        data = (f.encode() * 400)[:3000 if f == LFS else 60]
        name = hashlib.sha256(data).hexdigest() if f == LFS else _git_sha1(data)
        (blobs / name).write_bytes(data)
        (snap / f).parent.mkdir(parents=True, exist_ok=True)
        (snap / f).symlink_to(os.path.relpath(blobs / name, (snap / f).parent))
    return base


def _blob(base, f):
    return (base / "blobs" / (base / "snapshots" / modelfiles.REV / f).resolve().name)


def _no_network(monkeypatch):
    def refuse(*a, **k):
        raise AssertionError("network used")
    monkeypatch.setattr(socket.socket, "connect", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)
    import huggingface_hub
    monkeypatch.setattr(huggingface_hub, "snapshot_download", refuse)
    monkeypatch.setattr(huggingface_hub, "model_info", refuse)


def test_old_install_is_migrated_offline_and_is_ready(old_install, monkeypatch):
    _no_network(monkeypatch)
    assert not (old_install / modelfiles.VERIFIED).exists()
    assert modelfiles.verify_install(REPO) is True
    assert (old_install / modelfiles.VERIFIED).read_text() == modelfiles.REV
    assert modelfiles.model_ready(REPO) is True


def test_first_model_ready_call_migrates_in_the_background(old_install, monkeypatch):
    _no_network(monkeypatch)
    assert modelfiles.model_ready(REPO) is False  # never hashes on this path: starts the check and answers at once
    deadline = time.time() + 30
    while modelfiles.model_verifying(REPO) and time.time() < deadline:
        time.sleep(0.02)
    assert modelfiles.model_ready(REPO) is True


def test_flipped_byte_in_a_blob_is_not_marked(old_install, monkeypatch):
    _no_network(monkeypatch)
    blob = _blob(old_install, LFS)
    data = bytearray(blob.read_bytes())
    data[100] ^= 0x01
    blob.write_bytes(bytes(data))
    assert modelfiles.verify_install(REPO) is False
    assert not (old_install / modelfiles.VERIFIED).exists()
    assert modelfiles.model_ready(REPO) is False


def test_truncated_file_is_not_marked(old_install, monkeypatch):
    _no_network(monkeypatch)
    blob = _blob(old_install, LFS)
    blob.write_bytes(blob.read_bytes()[:-1])
    assert modelfiles.verify_install(REPO) is False
    assert not (old_install / modelfiles.VERIFIED).exists()


def test_small_file_with_wrong_bytes_is_not_marked(old_install, monkeypatch):
    _no_network(monkeypatch)
    _blob(old_install, "config.json").write_bytes(b"{}")  # git blob name, other bytes
    assert modelfiles.verify_install(REPO) is False


def test_missing_required_file_is_not_marked(old_install, monkeypatch):
    _no_network(monkeypatch)
    (old_install / "snapshots" / modelfiles.REV / "tokenizer.json").unlink()
    assert modelfiles.verify_install(REPO) is False


def test_a_marked_install_is_not_hashed_again(old_install, monkeypatch):
    _no_network(monkeypatch)
    assert modelfiles.verify_install(REPO) is True
    _blob(old_install, LFS).write_bytes(b"corrupt")  # would fail a check, but the marker decides
    monkeypatch.setattr(modelfiles, "_check_install", lambda name: pytest.fail("hashed a marked install"))
    assert modelfiles.model_ready(REPO) is True
    assert modelfiles.verify_install(REPO) is True


def test_status_reports_verifying_until_the_worker_finishes(old_install, monkeypatch):
    _no_network(monkeypatch)
    gate = threading.Event()
    real = modelfiles._check_install

    def slow(name):
        gate.wait(30)
        return real(name)
    monkeypatch.setattr(modelfiles, "_check_install", slow)
    assert modelfiles.start_verify(REPO) is True
    assert modelfiles.model_verifying(REPO) is True
    assert modelfiles.model_ready(REPO) is False
    gate.set()
    deadline = time.time() + 30
    while modelfiles.model_verifying(REPO) and time.time() < deadline:
        time.sleep(0.02)
    assert modelfiles.model_verifying(REPO) is False and modelfiles.model_ready(REPO) is True


def test_daemon_status_has_the_verifying_field(old_install, monkeypatch, tmp_path):
    _no_network(monkeypatch)
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    from semsearch.daemon import Daemon
    st = Daemon().dispatch({"cmd": "status"})
    assert st["ok"] is True and isinstance(st["model_verifying"], bool) and st["model_ready"] is False  # kicks the check

