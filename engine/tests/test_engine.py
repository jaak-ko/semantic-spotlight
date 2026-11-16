import json
import os
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

HERE = Path(__file__).parent
SRC_CORPUS = HERE / "corpus"
BIN = Path(os.environ.get("SEMSEARCH_BIN") or Path(sys.executable).parent / "semsearch")  # verify_runtime.sh sets it


@pytest.fixture
def env(tmp_path, monkeypatch):
    """Isolated index home plus a private copy of the corpus (sources are never modified)."""
    # AF_UNIX paths are capped at ~104 bytes on macOS, so keep the home short
    home = Path(tempfile.mkdtemp(prefix="ss-", dir="/tmp")) / "home"
    monkeypatch.setenv("SEMSEARCH_HOME", str(home))
    corpus = tmp_path / "corpus"
    shutil.copytree(SRC_CORPUS, corpus)
    return {"home": home, "corpus": corpus}


@pytest.fixture
def engine(env):
    from semsearch import config
    from semsearch.embed import Embedder
    from semsearch.store import Store

    emb = Embedder(config.load()["model"], config.models_dir())
    store = Store()
    yield {"emb": emb, "store": store, "cfg": config.load()}
    store.commit()
    store.db.close()


def _sync(engine, env):
    from semsearch import indexer
    return indexer.sync(engine["store"], engine["emb"], engine["cfg"], [str(env["corpus"])],
                        log=lambda m: None)


def _query(engine, text, n=5):
    from semsearch.search import query
    return [Path(r["path"]).name for r in query(engine["store"], engine["emb"], text, n)]


def _index(engine, env):
    engine["store"].add_folder(str(env["corpus"]))
    engine["store"].commit()
    return _sync(engine, env)


def test_semantic_query_finds_file_without_shared_keywords(engine, env):
    _index(engine, env)
    assert _query(engine, "notes about the municipality data pipeline migration")[0] == \
        "en_municipal_pipeline_migration.md"
    # Finnish: "notes on the municipality's data processing transfer"
    assert _query(engine, "muistiinpanot kunnan datankäsittelyn siirrosta")[0] == \
        "fi_kunnan_datan_siirto.md"


def test_exact_id_query(engine, env):
    _index(engine, env)
    assert _query(engine, "ERR-40417")[0] == "sync_error_log.log"


def test_reindex_unchanged_embeds_nothing(engine, env, monkeypatch):
    _index(engine, env)
    calls = []
    orig = engine["emb"].embed
    monkeypatch.setattr(engine["emb"], "embed", lambda *a, **k: calls.append(a) or orig(*a, **k))
    st = _sync(engine, env)
    assert st["files_embedded"] == 0 and st["chunks_embedded"] == 0 and st["files_hashed"] == 0
    assert calls == []


def test_deleted_file_vanishes(engine, env):
    _index(engine, env)
    assert "sync_error_log.log" in _query(engine, "ERR-40417")
    (env["corpus"] / "sync_error_log.log").unlink()
    st = _sync(engine, env)
    assert st["files_removed"] == 1
    assert "sync_error_log.log" not in _query(engine, "ERR-40417")


def test_chunk_spans_cover_text_with_overlap():
    from semsearch.chunk import chunk_spans
    text = "".join(f"line {i} with some words here\n" for i in range(200))
    spans = chunk_spans(text, lambda s: len(s.split()), max_tokens=40, overlap=10)
    assert len(spans) > 1
    assert spans[0][0] == 0 and spans[-1][1] == len(text)
    for (s1, e1), (s2, e2) in zip(spans, spans[1:]):
        assert s2 < e1 and s2 > s1  # overlapping, always progressing


def test_daemon_answers_over_socket(env):
    subprocess.run([str(BIN), "add", str(env["corpus"])], check=True, capture_output=True,
                   env={**os.environ, "SEMSEARCH_HOME": str(env["home"])})
    sock_path = env["home"] / "daemon.sock"
    proc = subprocess.Popen([str(BIN), "daemon"], stderr=subprocess.PIPE,
                            env={**os.environ, "SEMSEARCH_HOME": str(env["home"])})
    try:
        deadline = time.time() + 120
        while not sock_path.exists() and time.time() < deadline and proc.poll() is None:
            time.sleep(0.2)
        assert stat.S_IMODE(sock_path.stat().st_mode) == 0o600

        def call(req):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(str(sock_path))
            s.sendall((json.dumps(req) + "\n").encode())
            data = b""
            while not data.endswith(b"\n"):
                data += s.recv(65536)
            s.close()
            return json.loads(data)

        assert call({"cmd": "ping"}) == {"ok": True}
        st = call({"cmd": "status"})
        assert st["ok"] and st["files"] == 23 and st["model"].endswith("e5-small")
        q = call({"cmd": "query", "q": "ERR-40417", "n": 3})
        assert q["ok"] and Path(q["results"][0]["path"]).name == "sync_error_log.log"
        assert set(q["results"][0]) == {"path", "score", "similarity", "snippet", "start", "end"}
        assert call({"cmd": "bogus"})["ok"] is False
    finally:
        proc.send_signal(signal.SIGTERM)
        assert proc.wait(timeout=30) == 0
    assert not sock_path.exists()


def test_rtf_indexed_as_plain_text(engine, env):
    _index(engine, env)
    assert _query(engine, "pumppaamon huoltotauko")[0] == "maintenance_memo.rtf"
    snippet = engine["store"].db.execute(
        "SELECT text FROM chunks c JOIN files f ON f.id=c.file_id WHERE f.path LIKE '%.rtf'").fetchone()[0]
    assert "pumppaamon" in snippet and "\\rtf" not in snippet  # markup must not be indexed


def test_rtf_conversion_failure_is_skipped_with_warning(env, monkeypatch):
    from semsearch import indexer
    bad = env["corpus"] / "broken.rtf"
    bad.write_bytes(b"not an rtf")
    logs = []
    monkeypatch.setattr(indexer, "TEXTUTIL", "/usr/bin/false")  # any non-zero exit
    assert indexer._read(str(bad), 10**6, logs.append) is None
    assert any("skipping" in m for m in logs)
