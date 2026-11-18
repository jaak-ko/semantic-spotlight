"""Durable event log for support reports: <home>/events.jsonl, one JSON object per line (0600, UTF-8).

Each line: {"ts": ISO 8601 with the local offset, "level": "info"|"warn"|"error", "event": name,
"run": 8 hex digits, one per process, ...event fields}. Read it with `semsearch log`.
Privacy: every string goes through sanitize(): e-mail addresses, path-like tokens and quoted names are replaced,
and text is cut to 200 characters. Writes never raise into the caller."""
import contextlib
import datetime
import fcntl
import importlib.metadata
import json
import os
import re
import secrets
import sys
import threading
import time
import traceback
from pathlib import Path

from . import config

FILE = "events.jsonl"
LOCK = "events.lock"  # serializes writers (daemon and CLI) around rotation and the append
RUNNING = "daemon.running"  # present while a daemon runs; still there at the next start = no clean stop
MAX_BYTES = 512 * 1024
KEEP = 7  # rotated files events.jsonl.1 .. .7, next to the current file
MAX_AGE = 60 * 86400  # seconds: rotated files older than this are deleted
MAX_TEXT = 200
RUN = secrets.token_hex(4)  # one per process
_enabled = False  # set by the write commands and the daemon; read-only commands never write

_EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
_TAIL = re.compile(r"(?<![\w.])(?:~|\.{1,2})?/.*|[A-Za-z]:\\.*", re.S)  # from a path to the end of the text
_SLASH = re.compile(r"\S*/\S*")  # any other token with a slash: a relative path
_QUOTED = re.compile(r"'[^']*'|\"[^\"]*\"")  # quoted names, as in "No such file: 'name'"


def sanitize(value):
    """Strings lose e-mail addresses, paths and quoted names, and are cut to MAX_TEXT. Containers are walked.
    Anything else that is not a number, bool or None is written as sanitized text."""
    if isinstance(value, bool) or value is None or isinstance(value, (int, float)):
        return value
    if isinstance(value, dict):
        return {k: sanitize(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [sanitize(v) for v in value]
    s = _EMAIL.sub("<email>", str(value))
    s = _TAIL.sub("<path>", s)
    s = _SLASH.sub("<path>", s)
    return _QUOTED.sub("<text>", s)[:MAX_TEXT]


def enable() -> None:
    global _enabled
    _enabled = True


def write(level: str, event: str, **fields) -> None:
    """Append one event. Silent when not enabled, when the home does not exist, or on any error."""
    if not _enabled:
        return
    try:
        root = config.home()
        if not root.is_dir():
            return
        rec = {"ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
               "level": level, "event": event, "run": RUN}
        rec.update(sanitize(fields))
        data = (json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")  # one write per line
        with _locked(root):
            cur = root / FILE
            if cur.exists() and cur.stat().st_size + len(data) > MAX_BYTES:
                _rotate(root)
                prune(root)
            fd = os.open(cur, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                view = memoryview(data)
                while view:
                    view = view[os.write(fd, view):]
            finally:
                os.close(fd)
    except Exception:  # logging must never break the daemon or a command
        pass


@contextlib.contextmanager
def _locked(root: Path):
    fd = os.open(root / LOCK, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)  # closing the descriptor releases the lock


def _rotate(root: Path) -> None:
    (root / f"{FILE}.{KEEP}").unlink(missing_ok=True)  # the oldest one goes
    for i in range(KEEP - 1, 0, -1):
        src = root / f"{FILE}.{i}"
        if src.exists():
            os.replace(src, root / f"{FILE}.{i + 1}")
    os.replace(root / FILE, root / f"{FILE}.1")


def prune(root: Path = None) -> None:
    """Delete rotated files not written for MAX_AGE. The current file is never deleted here."""
    root = root or config.home()
    now = time.time()
    for i in range(1, KEEP + 1):
        p = root / f"{FILE}.{i}"
        try:
            if p.exists() and now - p.stat().st_mtime > MAX_AGE:
                p.unlink()
        except OSError:
            pass


def mark_running() -> bool:
    """Daemon start: True when the previous daemon stopped cleanly (no marker was left behind)."""
    root = config.home()
    try:
        clean = not (root / RUNNING).exists()
        fd = os.open(root / RUNNING, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, RUN.encode())
        finally:
            os.close(fd)
        return clean
    except OSError:
        return True


def clear_running() -> None:
    try:
        (config.home() / RUNNING).unlink(missing_ok=True)
    except OSError:
        pass


def engine_version() -> str:
    try:
        return importlib.metadata.version("semsearch")
    except importlib.metadata.PackageNotFoundError:
        return "unknown"


def _uncaught(tp, val, tb) -> None:
    names = [f.name for f in traceback.extract_tb(tb)][-8:]  # function names only
    write("error", "uncaught_exception", **{"class": tp.__name__, "message": str(val), "stack": names})


def install_excepthooks() -> None:
    """Uncaught exceptions in the main thread and in worker threads are logged, then reported as before."""
    prev, prev_thread = sys.excepthook, threading.excepthook

    def hook(tp, val, tb):
        _uncaught(tp, val, tb)
        prev(tp, val, tb)

    def thread_hook(args):
        _uncaught(args.exc_type, args.exc_value, args.exc_traceback)
        prev_thread(args)

    sys.excepthook, threading.excepthook = hook, thread_hook


def read(days: float = None, root: Path = None) -> list:
    """Retained events, oldest first, sanitized again on the way out. `days`: only those newer than that."""
    root = root or config.home()
    cutoff = None if days is None else datetime.datetime.now().astimezone() - datetime.timedelta(days=days)
    out = []
    for p in [root / f"{FILE}.{i}" for i in range(KEEP, 0, -1)] + [root / FILE]:
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            try:
                rec = json.loads(line)
                if not isinstance(rec, dict):
                    continue
                if cutoff and datetime.datetime.fromisoformat(rec["ts"]) < cutoff:
                    continue
            except (ValueError, KeyError, TypeError):
                continue
            out.append(sanitize(rec))
    return out
