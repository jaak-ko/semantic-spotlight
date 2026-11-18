"""The memory budget comes from this Mac's RAM and the model, not from a fixed number: 25% of RAM, between 2 and
6 GB, plus what the model keeps resident, never above half the RAM."""
import pytest

from semsearch import indexer

E5S, E5B, BGE = "intfloat/multilingual-e5-small", "intfloat/multilingual-e5-base", "BAAI/bge-m3"


@pytest.mark.parametrize("gb, expected", [(4, 2048), (8, 2048), (16, 4096), (32, 6144), (64, 6144), (128, 6144)])
def test_the_base_is_a_quarter_of_ram_between_2_and_6_gb(gb, expected):
    assert indexer.rss_limit_mb(E5S, ram_mb=gb * 1024) == expected


def test_bigger_models_get_their_weights_on_top():
    assert indexer.rss_limit_mb(E5B, ram_mb=16 * 1024) == 5120
    assert indexer.rss_limit_mb(BGE, ram_mb=16 * 1024) == 6144
    assert indexer.rss_limit_mb(BGE, ram_mb=32 * 1024) == 8192


def test_never_above_half_the_ram_and_never_below_2_gb():
    assert indexer.rss_limit_mb(BGE, ram_mb=8 * 1024) == 4096  # 2 GB base + 2 GB weights = the 50% ceiling
    assert indexer.rss_limit_mb(BGE, ram_mb=4 * 1024) == 2048  # the floor wins on a 4 GB machine
    assert indexer.rss_limit_mb("unknown/model", ram_mb=16 * 1024) == 5120  # unknown: 1 GB allowance


def test_ram_is_read_from_sysctl_and_has_a_conservative_fallback(monkeypatch):
    monkeypatch.setattr(indexer, "_RAM_MB", None)
    monkeypatch.setattr(indexer.subprocess, "check_output", lambda *a, **k: b"17179869184\n")
    assert indexer.physical_ram_mb() == 16384
    monkeypatch.setattr(indexer, "_RAM_MB", None)

    def boom(*a, **k):
        raise OSError("no sysctl")
    monkeypatch.setattr(indexer.subprocess, "check_output", boom)
    assert indexer.physical_ram_mb() == 8192  # unknown: treated as the smallest common Mac


def test_a_run_uses_the_limit_for_its_model(tmp_path, monkeypatch):
    from semsearch import config
    from semsearch.embed import Embedder
    from semsearch.store import Store
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    monkeypatch.setattr(indexer, "RSS_LIMIT_MB", None)
    monkeypatch.setattr(indexer, "physical_ram_mb", lambda: 16384)
    asked = []
    real = indexer.rss_limit_mb
    monkeypatch.setattr(indexer, "rss_limit_mb", lambda model=None, ram_mb=None: asked.append(model) or real(model, ram_mb))
    emb = Embedder(config.load()["model"], config.models_dir())
    cfg = dict(config.load(), model=E5B)
    with Store() as s:
        indexer.sync(s, emb, cfg, [], log=lambda m: None)
    assert asked == [E5B] and real(E5B, ram_mb=16384) == 5120
