"""status.rebuilding is true from the start of a schema, model or settings rebuild until its indexing has finished,
and false otherwise. files_partial and rebuilding are top-level keys of the daemon's status."""
import pytest

from semsearch import config, indexer
from semsearch.daemon import Daemon
from semsearch.embed import Embedder
from semsearch.store import Store


@pytest.fixture
def emb(tmp_path, monkeypatch):
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home"))
    return Embedder(config.load()["model"], config.models_dir())


def _folder(tmp_path):
    root = tmp_path / "docs"
    root.mkdir()
    (root / "a.txt").write_text("Lasagnelevyt uunissa.\n", encoding="utf-8")
    (root / "b.txt").write_text("Juusto päällä.\n", encoding="utf-8")
    return root


def test_rebuilding_is_true_while_a_rebuild_indexes_and_false_after(tmp_path, emb, monkeypatch):
    root = _folder(tmp_path)
    seen = []
    real = indexer._index_file

    def index(ctx, path, folder):
        seen.append(indexer.is_rebuilding())
        return real(ctx, path, folder)
    with Store() as s:
        s.add_folder(str(root))
        indexer.sync(s, emb, config.load(), [str(root)], log=lambda m: None)  # the current index
        s.set_meta("sig", "old|schema=4")  # an index from an older schema
        s.commit()
        monkeypatch.setattr(indexer, "_index_file", index)
        assert not indexer.is_rebuilding()
        indexer.sync(s, emb, config.load(), [str(root)], log=lambda m: None)
    assert seen and all(seen)  # every file of the rebuild was indexed while rebuilding
    assert not indexer.is_rebuilding()


def test_a_new_index_is_not_a_rebuild(tmp_path, emb, monkeypatch):
    root = _folder(tmp_path)
    seen = []
    real = indexer._index_file
    monkeypatch.setattr(indexer, "_index_file", lambda ctx, path, folder: (seen.append(indexer.is_rebuilding()),
                                                                          real(ctx, path, folder))[1])
    with Store() as s:
        s.add_folder(str(root))
        indexer.sync(s, emb, config.load(), [str(root)], log=lambda m: None)
    assert seen and not any(seen)


def test_a_failed_rebuild_clears_the_flag(tmp_path, emb, monkeypatch):
    root = _folder(tmp_path)
    with Store() as s:
        s.add_folder(str(root))
        indexer.sync(s, emb, config.load(), [str(root)], log=lambda m: None)
        s.set_meta("sig", "old|schema=4")
        s.commit()

        def boom(*a, **k):
            raise RuntimeError("embedder broke")
        monkeypatch.setattr(indexer, "_index_file", boom)
        with pytest.raises(RuntimeError):
            indexer.sync(s, emb, config.load(), [str(root)], log=lambda m: None)
    assert not indexer.is_rebuilding()


def test_daemon_status_has_rebuilding_and_files_partial_at_the_top(tmp_path, emb):
    st = Daemon().dispatch({"cmd": "status"})
    assert st["ok"] is True
    assert isinstance(st["rebuilding"], bool) and st["rebuilding"] is False
    assert isinstance(st["files_partial"], int)
