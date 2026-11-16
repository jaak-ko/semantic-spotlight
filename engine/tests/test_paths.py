"""Path lookups and read-only commands create nothing; only writes create the engine home (0700)."""
import os
import stat
from pathlib import Path

import pytest


@pytest.fixture
def missing_user_home(tmp_path, monkeypatch):
    """HOME points at a temp folder with no .semsearch in it; no overrides, so the defaults are exercised."""
    user_home = tmp_path / "user"
    user_home.mkdir()
    monkeypatch.setenv("HOME", str(user_home))
    monkeypatch.delenv("SEMSEARCH_HOME", raising=False)
    monkeypatch.delenv("SEMSEARCH_MODELS", raising=False)
    return user_home / ".semsearch"


def test_lookups_and_status_do_not_create_the_home(missing_user_home, capsys):
    from semsearch import config, modelfiles
    from semsearch.cli import main
    base = missing_user_home
    assert not base.exists()
    assert config.home() == base
    assert config.models_dir() == base / "models"
    assert config.load()["model"]
    assert modelfiles.model_ready() is False
    assert main(["status", "--json"]) == 0
    assert '"files": 0' in capsys.readouterr().out
    assert main(["query", "anything"]) == 3  # no model: a clear error, and still nothing created
    assert not base.exists(), list(base.parent.iterdir())


def test_write_paths_create_the_home_private(missing_user_home):
    from semsearch import config
    from semsearch.store import Store
    base = missing_user_home
    with Store() as s:  # opening the default index is a write
        s.set_meta("x", "1")
        s.commit()
    assert base.is_dir() and stat.S_IMODE(base.stat().st_mode) == 0o700
    assert (base / "index.db").is_file()
    assert not (base / "models").exists()  # the models folder is created by fetch-model, not by opening the index


def test_ensure_home_fixes_permissions_of_an_existing_folder(tmp_path, monkeypatch):
    from semsearch import config
    old = tmp_path / "old"
    old.mkdir(mode=0o755)
    old.chmod(0o755)
    monkeypatch.setenv("SEMSEARCH_HOME", str(old))
    assert config.home() == old and stat.S_IMODE(old.stat().st_mode) == 0o755  # lookup changes nothing
    config.ensure_home()
    assert stat.S_IMODE(old.stat().st_mode) == 0o700
