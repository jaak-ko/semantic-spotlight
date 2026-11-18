"""The durable event log: sanitized, one JSON line per event, rotated and kept 60 days, never raises into the
caller, safe with concurrent writers, detects an unclean daemon exit, and is covered by uninstall."""
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

from semsearch import events

ENGINE = Path(__file__).resolve().parents[1]


@pytest.fixture
def home(tmp_path, monkeypatch):
    h = tmp_path / "home" / ".semsearch"
    h.mkdir(parents=True)
    monkeypatch.setenv("SEMSEARCH_HOME", str(h))
    monkeypatch.setattr(events, "_enabled", True)
    return h


def _lines(home):  # oldest first: .7 .. .1, then the current file
    out = []
    for p in [home / f"events.jsonl.{i}" for i in range(7, 0, -1)] + [home / "events.jsonl"]:
        if not p.exists():
            continue
        out += [json.loads(x) for x in p.read_text(encoding="utf-8").splitlines() if x.strip()]
    return out


# ---- sanitizer --------------------------------------------------------------------------------------------------

def test_absolute_paths_with_spaces_and_unicode_are_removed():
    s = events.sanitize("failed reading /Users/jaakko/Documents/omia tekstejä/Muistio 2026.txt now")
    assert s == "failed reading <path>"
    for leak in ("jaakko", "omia", "tekstej", "Muistio", ".txt"):
        assert leak not in s


def test_home_relative_and_windows_paths_are_removed():
    assert "<path>" in events.sanitize("skip ~/Documents/secret.pdf")
    assert "secret" not in events.sanitize("skip ~/Documents/secret.pdf")
    assert "secret" not in events.sanitize("C:\\Users\\Ann\\secret.pdf")


def test_relative_path_tokens_are_removed():
    s = events.sanitize("moved notes/2026/plan.md and tekstejä/x.txt")
    for leak in ("notes", "plan.md", "tekstej", "x.txt"):
        assert leak not in s


def test_quoted_names_are_removed():
    s = events.sanitize("No such file: 'Salainen kansio.txt' and \"Lasku.pdf\"")
    assert "Salainen" not in s and "Lasku" not in s


def test_emails_are_removed_including_unicode_local_parts():
    s = events.sanitize("account junttu.j@gmail.com or käyttäjä+x@esimerkki.fi said")
    assert "gmail" not in s and "esimerkki" not in s and "junttu" not in s
    assert s == "account <email> or <email> said"


def test_unicode_text_is_kept_and_long_text_is_cut_to_200():
    assert events.sanitize("päivitys käynnissä äöå") == "päivitys käynnissä äöå"
    assert len(events.sanitize("x" * 1000)) == 200


def test_nested_strings_are_sanitized_and_other_values_untouched():
    out = events.sanitize({"top_errors": [{"class": "PermissionError", "count": 3}],
                           "message": "bad /tmp/a/b.txt", "n": 7, "ok": True, "f": 1.5})
    assert out == {"top_errors": [{"class": "PermissionError", "count": 3}], "message": "bad <path>",
                   "n": 7, "ok": True, "f": 1.5}


# ---- writer -----------------------------------------------------------------------------------------------------

def test_writes_one_json_line_with_the_fixed_fields(home):
    events.write("info", "daemon_start", pid=123, previous_run_clean=True)
    (line,) = (home / "events.jsonl").read_text(encoding="utf-8").splitlines()
    rec = json.loads(line)
    assert set(rec) == {"ts", "level", "event", "run", "pid", "previous_run_clean"}
    assert rec["level"] == "info" and rec["event"] == "daemon_start" and rec["pid"] == 123
    assert re.fullmatch(r"[0-9a-f]{8}", rec["run"])
    datetime.datetime.fromisoformat(rec["ts"])  # ISO 8601 with the local offset
    assert rec["ts"][-6] in "+-"
    assert oct((home / "events.jsonl").stat().st_mode & 0o777) == "0o600"


def test_nothing_is_written_when_not_enabled_or_home_is_missing(home, monkeypatch, tmp_path):
    monkeypatch.setattr(events, "_enabled", False)
    events.write("info", "x")
    assert not (home / "events.jsonl").exists()
    monkeypatch.setattr(events, "_enabled", True)
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "absent" / ".semsearch"))
    events.write("info", "x")
    assert not (tmp_path / "absent").exists()  # never creates the home


def test_never_raises_into_the_caller(home, monkeypatch):
    (home / "events.jsonl").mkdir()  # cannot be opened for appending
    events.write("error", "x")  # swallowed
    monkeypatch.setattr(events, "_enabled", True)
    events.write("info", "y", obj=object())  # not JSON: written as text, still no raise


def test_a_path_that_reaches_a_field_never_reaches_the_file(home):
    events.write("error", "index_error", **{"class": "OSError", "message": "/Users/jaakko/Salaiset/a.txt"})
    raw = (home / "events.jsonl").read_text(encoding="utf-8")
    assert "Salaiset" not in raw and "/Users" not in raw and "<path>" in raw


# ---- rotation and retention -------------------------------------------------------------------------------------

def test_rotation_keeps_eight_files_and_every_line_is_whole(home, monkeypatch):
    monkeypatch.setattr(events, "MAX_BYTES", 2000)
    for i in range(300):
        events.write("info", "tick", i=i, pad="p" * 60)
    names = sorted(p.name for p in home.glob("events.jsonl*"))
    assert len(names) == 8 and "events.jsonl" in names and "events.jsonl.7" in names
    for p in home.glob("events.jsonl*"):
        assert p.stat().st_size <= 2000
    recs = _lines(home)
    assert [r["i"] for r in recs] == sorted(r["i"] for r in recs)  # newest last
    assert recs[-1]["i"] == 299


def test_rotated_files_older_than_60_days_are_deleted_and_the_current_file_never(home):
    now = time.time()
    (home / "events.jsonl").write_text('{"event":"now"}\n')
    old, recent = home / "events.jsonl.3", home / "events.jsonl.2"
    old.write_text('{"event":"old"}\n')
    recent.write_text('{"event":"recent"}\n')
    os.utime(old, (now - 61 * 86400, now - 61 * 86400))
    os.utime(recent, (now - 10 * 86400, now - 10 * 86400))
    events.prune(home)
    assert not old.exists() and recent.exists() and (home / "events.jsonl").exists()


# ---- concurrency -------------------------------------------------------------------------------------------------

CHILD = """
import sys
from semsearch import events
events._enabled = True
events.MAX_BYTES = 20000
pid = sys.argv[1]
for i in range(150):
    events.write("info", "tick", writer=pid, i=i, pad="q" * 150)
"""


def test_concurrent_writers_never_interleave_lines(home):
    env = {**os.environ, "SEMSEARCH_HOME": str(home.parent / ".semsearch"), "PYTHONDONTWRITEBYTECODE": "1"}
    procs = [subprocess.Popen([sys.executable, "-c", CHILD, str(w)], env=env, cwd=str(ENGINE)) for w in range(4)]
    assert [p.wait(timeout=120) for p in procs] == [0, 0, 0, 0]
    recs = _lines(home)  # every retained line parses: no torn or merged lines
    assert recs
    for w in {r["writer"] for r in recs}:
        seq = [r["i"] for r in recs if r["writer"] == w]
        assert seq == sorted(seq)  # each writer's own order is kept


# ---- crash detection ---------------------------------------------------------------------------------------------

def test_an_unclean_exit_is_seen_at_the_next_start(home):
    assert events.mark_running() is True  # first start: no marker
    assert events.mark_running() is False  # the marker is still there: the last run did not stop cleanly
    events.clear_running()
    assert events.mark_running() is True


def _daemon(home, *args, extra_env=None):
    env = {**os.environ, "SEMSEARCH_HOME": str(home), "SEMSEARCH_MODELS": str(home.parent / "no-models"),
           "PYTHONDONTWRITEBYTECODE": "1", **(extra_env or {})}
    return subprocess.Popen([sys.executable, "-c", "import sys; from semsearch.cli import main; sys.exit(main(sys.argv[1:]))",
                             "daemon"], env=env, cwd=str(ENGINE), stderr=subprocess.DEVNULL)


def _wait_started(home, proc, n, timeout=60):
    """Until the n-th daemon_start line is written, then a moment for its signal handlers (a stale socket from
    a killed daemon exists before any start)."""
    deadline = time.time() + timeout
    while sum(r["event"] == "daemon_start" for r in _lines(home)) < n and time.time() < deadline and proc.poll() is None:
        time.sleep(0.1)
    assert sum(r["event"] == "daemon_start" for r in _lines(home)) >= n, "daemon did not start"
    time.sleep(0.5)


def test_daemon_killed_hard_is_reported_unclean_at_the_next_start():
    home = Path(tempfile.mkdtemp(prefix="ss-", dir="/tmp")) / ".semsearch"  # short: the daemon socket path limit
    first = _daemon(home)
    _wait_started(home, first, 1)
    first.kill()  # no clean stop: no daemon_stop line
    first.wait()
    second = _daemon(home)
    _wait_started(home, second, 2)
    second.terminate()
    second.wait(timeout=60)
    starts = [r for r in _lines(home) if r["event"] == "daemon_start"]
    assert [r["previous_run_clean"] for r in starts] == [True, False]
    stops = [r for r in _lines(home) if r["event"] == "daemon_stop"]
    assert [r["reason"] for r in stops] == ["signal"]  # the second run's SIGTERM is logged as a signal stop


# ---- uninstall guard ---------------------------------------------------------------------------------------------

def test_uninstall_accepts_the_event_files(home, monkeypatch, capsys):
    from semsearch import cli
    for name in ("events.jsonl", "events.jsonl.1", "events.jsonl.7", "events.lock", "daemon.running"):
        (home / name).write_text("x")
    monkeypatch.setattr(cli.Path, "home", staticmethod(lambda: home.parent.parent))
    assert cli.cmd_uninstall(type("A", (), {"yes": False})()) == 0
    assert "refusing" not in capsys.readouterr().err


# ---- semsearch log -----------------------------------------------------------------------------------------------

def test_log_prints_retained_events_newest_last_and_respects_days(home, monkeypatch, capsys):
    from semsearch import cli
    old = (datetime.datetime.now().astimezone() - datetime.timedelta(days=40)).isoformat(timespec="seconds")
    recent = (datetime.datetime.now().astimezone() - datetime.timedelta(days=1)).isoformat(timespec="seconds")
    (home / "events.jsonl.1").write_text(json.dumps({"ts": old, "level": "info", "event": "old_one", "run": "00000001"}) + "\n")
    (home / "events.jsonl").write_text(
        json.dumps({"ts": recent, "level": "warn", "event": "recent_one", "run": "00000002", "message": "see /Users/a/b.txt"}) + "\n")
    assert cli.main(["log", "--json", "--days", "30"]) == 0
    out = [json.loads(x) for x in capsys.readouterr().out.splitlines()]
    assert [r["event"] for r in out] == ["recent_one"]
    assert out[0]["message"] == "see <path>"
    assert cli.main(["log", "--days", "60"]) == 0
    text = capsys.readouterr().out
    assert "old_one" in text and "recent_one" in text and text.index("old_one") < text.index("recent_one")


def test_log_does_not_create_anything(tmp_path, monkeypatch, capsys):
    from semsearch import cli
    monkeypatch.setenv("SEMSEARCH_HOME", str(tmp_path / "none" / ".semsearch"))
    assert cli.main(["log"]) == 0
    assert not (tmp_path / "none").exists()


# ---- search_slow ------------------------------------------------------------------------------------------------

def test_slow_query_is_logged_fast_query_is_not(home, monkeypatch):
    from semsearch import search
    monkeypatch.setattr(search, "_query", lambda *a, **k: [])
    search.query(None, None, "rychtig", 10, {})
    assert not [r for r in _lines(home) if r["event"] == "search_slow"]
    monkeypatch.setattr(search, "_query", lambda *a, **k: time.sleep(1.05) or [])
    search.query(None, None, "hidas kysely", 10, {})
    (rec,) = [r for r in _lines(home) if r["event"] == "search_slow"]
    assert rec["level"] == "warn" and rec["ms"] > 1000 and rec["query_chars"] == len("hidas kysely")
    assert "hidas" not in json.dumps(rec)


# ---- indexer, daemon trigger, uncaught exceptions ----------------------------------------------------------------

@pytest.fixture
def emb(home):
    from semsearch import config
    from semsearch.embed import Embedder
    return Embedder(config.load()["model"], config.models_dir())


def _sync(store, emb, folders, trigger):
    from semsearch import config, indexer
    return indexer.sync(store, emb, config.load(), folders, log=lambda m: None, trigger=trigger)


def test_index_run_logs_start_end_and_an_unreadable_file_without_its_name(home, emb, tmp_path):
    from semsearch.store import Store
    folder = tmp_path / "Salainen kansio"
    folder.mkdir()
    (folder / "avoin.txt").write_text("Lasagnelevyt uunissa.\n", encoding="utf-8")
    secret = folder / "Salainen lasku.txt"
    secret.write_text("tilinumero 123\n", encoding="utf-8")
    secret.chmod(0)
    try:
        with Store() as s:
            s.add_folder(str(folder))
            _sync(s, emb, [str(folder)], "watch")
    finally:
        secret.chmod(0o600)
    recs = _lines(home)
    (start,) = [r for r in recs if r["event"] == "index_start"]
    assert start["trigger"] == "watch" and start["folders"] == 1
    (end,) = [r for r in recs if r["event"] == "index_end"]
    assert end["level"] == "warn" and end["errors"] == 1
    assert end["top_errors"] == [{"class": "PermissionError", "count": 1}]
    assert end["files_scanned"] == 2 and end["files_embedded"] == 1 and end["chunks"] >= 1
    (err,) = [r for r in recs if r["event"] == "index_error"]
    assert err["class"] == "PermissionError" and err["message"] == "Permission denied" and err["folder_index"] == 0
    raw = (home / "events.jsonl").read_text(encoding="utf-8")
    for leak in ("Salainen", "lasku", "tilinumero", "tmp", "pytest"):
        assert leak not in raw


def test_a_settings_change_that_rebuilds_the_index_is_logged(home, emb, tmp_path):
    from semsearch.store import Store
    folder = tmp_path / "rebuild"
    folder.mkdir()
    (folder / "a.txt").write_text("Lasagnelevyt uunissa.\n", encoding="utf-8")
    with Store() as s:
        s.add_folder(str(folder))
        _sync(s, emb, [str(folder)], "manual")
        s.set_meta("sig", "old|schema=4")  # an index written by an older schema
        s.commit()
        _sync(s, emb, [str(folder)], "manual")
    (rb,) = [r for r in _lines(home) if r["event"] == "schema_rebuild"]
    from semsearch import indexer
    assert rb["from"] == 4 and rb["to"] == indexer.SCHEMA_VERSION and rb["reason"] == "schema"


def test_daemon_index_request_names_its_trigger(home, emb, tmp_path, monkeypatch):
    from semsearch.daemon import Daemon
    d = Daemon()
    assert d.dispatch({"cmd": "index", "trigger": "watch"})["ok"] is True
    deadline = time.time() + 120
    while not [r for r in _lines(home) if r["event"] == "index_end"] and time.time() < deadline:
        time.sleep(0.1)
    (start,) = [r for r in _lines(home) if r["event"] == "index_start"]
    assert start["trigger"] == "watch"


def test_uncaught_exception_keeps_class_and_function_names_only(home):
    def inner_secret(path):
        raise ValueError("bad /Users/jaakko/Salaiset/tiedosto.txt")

    try:
        inner_secret("/Users/jaakko/Salaiset/tiedosto.txt")
    except ValueError as e:
        events._uncaught(type(e), e, e.__traceback__)
    (rec,) = [r for r in _lines(home) if r["event"] == "uncaught_exception"]
    assert rec["level"] == "error" and rec["class"] == "ValueError"
    assert rec["stack"] == ["test_uncaught_exception_keeps_class_and_function_names_only", "inner_secret"]
    assert "Salaiset" not in json.dumps(rec) and "jaakko" not in json.dumps(rec)
