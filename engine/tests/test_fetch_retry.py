"""fetch-model against a fake Hub: transient failures are retried, the rest are not, errors are friendly."""
import errno
import json
from types import SimpleNamespace

import pytest
import requests

from semsearch import modelfiles

REQUIRED = ["config.json", "model.safetensors", "modules.json", "sentence_bert_config.json",
            "sentencepiece.bpe.model", "special_tokens_map.json", "tokenizer.json",
            "tokenizer_config.json", "1_Pooling/config.json"]


class FakeResp:
    def __init__(self, status):
        self.status_code = status
        self.headers = {}
        self.request = None  # HfHubHTTPError reads it
        self.text = ""


def http_error(status):
    from huggingface_hub.utils import HfHubHTTPError
    return HfHubHTTPError(f"HTTP {status}", response=FakeResp(status))


def ssl_eof():
    return requests.exceptions.SSLError("EOF occurred in violation of protocol (_ssl.c:1011)")


@pytest.fixture
def fake_hub(tmp_path, monkeypatch):
    """Temp folders only; a fake model_info and snapshot_download that write the expected files."""
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("SEMSEARCH_MODELS", str(tmp_path / "models"))
    sleeps = []
    monkeypatch.setattr(modelfiles, "_backoff", lambda s: sleeps.append(s))
    hub = SimpleNamespace(info_failures=[], download_failures=[], info_calls=0, download_calls=0,
                          sleeps=sleeps, partial_seen=[], wrong_size=False)
    sibs = [SimpleNamespace(rfilename=f, size=10, lfs=None) for f in REQUIRED]

    def model_info(name, revision, files_metadata):
        hub.info_calls += 1
        if hub.info_failures:
            raise hub.info_failures.pop(0)
        return SimpleNamespace(sha=modelfiles.REV, siblings=sibs)

    def snapshot_download(name, revision, cache_dir, allow_patterns):
        hub.download_calls += 1
        blobs = modelfiles.model_dir(name) / "blobs"
        blobs.mkdir(parents=True, exist_ok=True)
        partial = blobs / "partial.incomplete"
        hub.partial_seen.append(partial.exists())
        if hub.download_failures:
            partial.write_bytes(b"x" * 5)  # bytes already on disk: the next attempt resumes from here
            raise hub.download_failures.pop(0)
        snap = modelfiles.model_dir(name) / "snapshots" / modelfiles.REV
        for f in REQUIRED:
            (snap / f).parent.mkdir(parents=True, exist_ok=True)
            (snap / f).write_bytes(b"x" * (9 if (hub.wrong_size and f == "model.safetensors") else 10))

    import huggingface_hub
    monkeypatch.setattr(huggingface_hub, "model_info", model_info)
    monkeypatch.setattr(huggingface_hub, "snapshot_download", snapshot_download)
    return hub


def run(capsys):
    from semsearch.modelfiles import run_fetch_cli
    code = run_fetch_cli(modelfiles.DEFAULT_MODEL)
    events = [json.loads(line) for line in capsys.readouterr().out.splitlines() if line.strip()]
    return code, events


def test_two_eof_failures_then_success_emits_two_retries(fake_hub, capsys):
    fake_hub.info_failures = [ssl_eof(), ssl_eof()]
    code, events = run(capsys)
    assert code == 0 and events[-1] == {"event": "done"}
    assert [e for e in events if e["event"] == "retry"] == [
        {"event": "retry", "attempt": 2, "max": 5}, {"event": "retry", "attempt": 3, "max": 5}]
    assert fake_hub.sleeps == [0.5, 1.0]
    assert fake_hub.info_calls == 3


def test_download_failures_resume_from_the_partial_file(fake_hub, capsys):
    fake_hub.download_failures = [ssl_eof(), ConnectionResetError("reset by peer")]
    code, events = run(capsys)
    assert code == 0 and events[-1] == {"event": "done"}
    assert fake_hub.download_calls == 3
    assert fake_hub.partial_seen == [False, True, True]  # the partial survives each failed attempt
    assert [e["attempt"] for e in events if e["event"] == "retry"] == [2, 3]
    assert fake_hub.sleeps == [0.5, 1.0]


def test_five_failures_give_a_friendly_error_and_a_detail(fake_hub, capsys):
    fake_hub.info_failures = [ssl_eof() for _ in range(5)]
    code, events = run(capsys)
    assert code == 1
    assert fake_hub.info_calls == 5
    assert len([e for e in events if e["event"] == "retry"]) == 4
    err = events[-1]
    assert err["event"] == "error"
    assert err["message"] == "Couldn't reach huggingface.co. Check your internet connection and try again."
    assert err["detail"].startswith("SSLError: ")
    assert fake_hub.sleeps == [0.5, 1.0, 2.0, 4.0]


def test_not_found_is_not_retried(fake_hub, capsys):
    fake_hub.info_failures = [http_error(404)]
    code, events = run(capsys)
    assert code == 1 and fake_hub.info_calls == 1
    assert not [e for e in events if e["event"] == "retry"]
    assert events[-1]["message"].startswith("The model could not be found on huggingface.co")


def test_server_error_is_retried_but_unauthorized_is_not(fake_hub, capsys):
    fake_hub.info_failures = [http_error(503), http_error(401)]
    code, events = run(capsys)
    assert code == 1 and fake_hub.info_calls == 2  # 503 retried once, 401 stops at once


def test_checksum_mismatch_is_not_retried(fake_hub, capsys):
    fake_hub.wrong_size = True
    code, events = run(capsys)
    assert code == 1 and fake_hub.download_calls == 1
    assert not [e for e in events if e["event"] == "retry"]
    assert events[-1]["message"] == "The download was interrupted and could not be verified. Try again."
    assert "size mismatch" in events[-1]["detail"]


def test_disk_full_is_not_retried(fake_hub, capsys, monkeypatch):
    def full(name, revision, cache_dir, allow_patterns):
        fake_hub.download_calls += 1
        raise OSError(errno.ENOSPC, "No space left on device")
    import huggingface_hub
    monkeypatch.setattr(huggingface_hub, "snapshot_download", full)
    code, events = run(capsys)
    assert code == 1 and fake_hub.download_calls == 1
    assert events[-1]["message"].startswith("Not enough disk space")
