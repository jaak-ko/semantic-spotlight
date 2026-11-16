import json
import os

import pytest


@pytest.fixture
def empty_models(tmp_path, monkeypatch):
    """No model installed anywhere the engine looks."""
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("SEMSEARCH_MODELS", str(tmp_path / "models"))
    return tmp_path


def test_model_not_ready_when_absent(empty_models):
    from semsearch import modelfiles
    assert modelfiles.model_ready(modelfiles.DEFAULT_MODEL) is False


def test_status_reports_model_ready_false_without_crashing(empty_models, capsys):
    from semsearch.cli import main
    assert main(["status", "--json"]) == 0
    st = json.loads(capsys.readouterr().out)
    assert st["model_ready"] is False and st["ok"] is True


def test_query_without_model_is_a_clear_error_not_a_crash(empty_models, capsys):
    from semsearch.cli import main
    assert main(["query", "anything"]) == 3
    assert "fetch-model" in capsys.readouterr().err


def test_daemon_status_and_query_without_model(empty_models):
    from semsearch.daemon import Daemon
    d = Daemon()
    st = d.dispatch({"cmd": "status"})
    assert st["ok"] is True and st["model_ready"] is False
    with pytest.raises(Exception) as e:
        d.dispatch({"cmd": "query", "q": "x", "n": 3})
    assert "fetch-model" in str(e.value)


def test_fetch_model_error_contract(empty_models, capsys):
    """Unsupported model names fail before any network call and emit one error event."""
    from semsearch.cli import main
    assert main(["fetch-model", "--model", "nobody/none"]) == 1
    lines = [json.loads(x) for x in capsys.readouterr().out.splitlines() if x.strip()]
    assert lines[-1]["event"] == "error" and "message" in lines[-1]
