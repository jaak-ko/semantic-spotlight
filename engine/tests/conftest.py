"""Tests never touch the user's engine home or models.

The home is a temp folder for the whole session. Models come from the project-local, git-ignored
engine/dist/models (filled once with `SEMSEARCH_MODELS=engine/dist/models semsearch fetch-model`),
unless SEMSEARCH_MODELS already names another folder outside ~/.semsearch.
"""
import os
from pathlib import Path

import pytest

PROJECT_MODELS = Path(__file__).resolve().parents[1] / "dist" / "models"
REAL_HOME = Path.home() / ".semsearch"


@pytest.fixture(scope="session", autouse=True)
def _private_home_and_models(tmp_path_factory):
    real_before = REAL_HOME.exists()
    base = tmp_path_factory.mktemp("engine")
    old = {k: os.environ.get(k) for k in ("SEMSEARCH_HOME", "SEMSEARCH_MODELS")}
    os.environ["SEMSEARCH_HOME"] = str(base / "session-home")  # a test may still override it per test
    current = os.environ.get("SEMSEARCH_MODELS")
    if not current or Path(current).resolve().is_relative_to(REAL_HOME.resolve()):
        os.environ["SEMSEARCH_MODELS"] = str(PROJECT_MODELS)
    yield Path(os.environ["SEMSEARCH_MODELS"])
    for k, v in old.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    # The suite must not create or change the user's engine home.
    assert REAL_HOME.exists() == real_before, f"tests changed {REAL_HOME}"
