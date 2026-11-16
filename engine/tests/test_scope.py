"""Searching only chosen folders: the scope is applied before ranking, and folder_stats is per folder."""
import time
from pathlib import Path

import pytest

SAME = "Kalastusreissu järvelle, verkot ja onkiminen aamulla rannalla."


@pytest.fixture
def daemon(tmp_path, monkeypatch):
    from semsearch.daemon import Daemon
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "home" / ".semsearch"))
    return Daemon()


def _index(d, *folders):
    for f in folders:
        assert d.dispatch({"cmd": "add", "path": str(f)})["ok"]
    deadline = time.time() + 300
    while d.indexing and time.time() < deadline:
        time.sleep(0.05)


def _names(res):
    return sorted(Path(r["path"]).name for r in res)


@pytest.fixture
def two_folders(daemon, tmp_path):
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir(), b.mkdir()
    (a / "alpha_note.md").write_text(SAME + "\n")
    (a / "err.log").write_text("ERROR ERR-40417 levy täynnä kirjoitettaessa\n")
    (b / "beta_note.md").write_text(SAME + "\n")
    _index(daemon, a, b)
    return daemon, a, b


def test_results_are_limited_to_the_chosen_folder(two_folders):
    d, a, b = two_folders
    q = "kalastusreissu järvelle verkot"
    only_a = d.dispatch({"cmd": "query", "q": q, "n": 10, "folders": [str(a)]})["results"]
    only_b = d.dispatch({"cmd": "query", "q": q, "n": 10, "folders": [str(b)]})["results"]
    assert only_a and all(Path(r["path"]).is_relative_to(a) for r in only_a)
    assert _names(only_b) == ["beta_note.md"]
    everything = _names(d.dispatch({"cmd": "query", "q": q, "n": 10})["results"])
    assert "alpha_note.md" in everything and "beta_note.md" in everything


def test_prefix_trap_foo_does_not_match_foobar(daemon, tmp_path):
    root = tmp_path / "root"
    (root / "foo").mkdir(parents=True)
    (root / "foobar").mkdir()
    (root / "foo" / "n.md").write_text(SAME + "\n")
    (root / "foobar" / "n.md").write_text(SAME + "\n")
    _index(daemon, root / "foo", root / "foobar")
    res = daemon.dispatch({"cmd": "query", "q": "kalastusreissu järvelle", "n": 10,
                           "folders": [str(root / "foo")]})["results"]
    assert res and all(Path(r["path"]).is_relative_to(root / "foo") for r in res)
    assert not any("foobar" in r["path"] for r in res)


def test_empty_list_means_no_folders(two_folders):
    d, a, b = two_folders
    assert d.dispatch({"cmd": "query", "q": "kalastus", "n": 10, "folders": []}) == {"ok": True, "results": []}


def test_unknown_or_unregistered_paths_are_ignored(two_folders, tmp_path):
    d, a, b = two_folders
    unknown = d.dispatch({"cmd": "query", "q": "kalastus", "n": 10, "folders": ["/nonexistent/zzz"]})
    assert unknown == {"ok": True, "results": []}
    mixed = d.dispatch({"cmd": "query", "q": "kalastus järvelle", "n": 10,
                        "folders": [str(a), "/nonexistent/zzz", str(tmp_path / "not-registered")]})
    alone = d.dispatch({"cmd": "query", "q": "kalastus järvelle", "n": 10, "folders": [str(a)]})
    assert _names(mixed["results"]) == _names(alone["results"])


def test_exact_id_is_found_inside_scope_and_not_outside(two_folders):
    d, a, b = two_folders
    inside = d.dispatch({"cmd": "query", "q": "ERR-40417", "n": 3, "folders": [str(a)]})["results"]
    assert inside and Path(inside[0]["path"]).name == "err.log"
    outside = d.dispatch({"cmd": "query", "q": "ERR-40417", "n": 3, "folders": [str(b)]})["results"]
    assert "err.log" not in _names(outside)


def test_n_is_still_respected_with_a_scope(two_folders):
    d, a, b = two_folders
    res = d.dispatch({"cmd": "query", "q": "kalastusreissu", "n": 1, "folders": [str(a), str(b)]})["results"]
    assert len(res) == 1


def test_folders_must_be_a_list_or_null(two_folders):
    d, a, b = two_folders
    with pytest.raises(ValueError, match="folders"):  # the socket handler turns this into {"ok": false, ...}
        d.dispatch({"cmd": "query", "q": "kalastus", "n": 3, "folders": str(a)})


def test_status_reports_files_per_folder(two_folders):
    d, a, b = two_folders
    stats = {s["path"]: s["files"] for s in d.dispatch({"cmd": "status"})["folder_stats"]}
    assert stats == {str(a): 2, str(b): 1}
    assert set(d.dispatch({"cmd": "status"})["folder_stats"][0]) == {"path", "files"}  # counts only
