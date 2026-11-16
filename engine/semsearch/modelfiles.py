"""Model presence, first-launch download and verification. Network use lives only in fetch()."""
import collections
import errno
import fnmatch
import hashlib
import json
import os
import signal
import sys
import threading
import time
from pathlib import Path

from . import config

DEFAULT_MODEL = "intfloat/multilingual-e5-small"
# Pinned commit of the default model: the snapshot directory name of the tested install.
# Pinned (not "main") so the bytes we verify and index are always the same; changing it rebuilds the index.
REV = "614241f622f53c4eeff9890bdc4f31cfecc418b3"
# Only what sentence-transformers loads (safetensors weights, no onnx/openvino/tf copies).
PATTERNS = {
    DEFAULT_MODEL: ["config.json", "model.safetensors", "modules.json", "sentence_bert_config.json",
                    "sentencepiece.bpe.model", "special_tokens_map.json", "tokenizer.json",
                    "tokenizer_config.json", "1_Pooling/*"],
}


class ModelMissing(RuntimeError):
    pass


def model_dir(name: str) -> Path:
    return config.models_dir() / ("models--" + name.replace("/", "--"))


def _snapshot(name: str):
    """Pinned snapshot for known models. Other models fall back to the refs/main pointer.
    Migration: installs from before the pin have refs/main -> the same commit, so they stay ready
    without a download; a ref file that says "main" is ignored for the pinned model."""
    if name in PATTERNS:
        return model_dir(name) / "snapshots" / REV
    ref = model_dir(name) / "refs" / "main"
    if not ref.is_file():
        return None
    return model_dir(name) / "snapshots" / ref.read_text().strip()


VERIFIED = "verified"  # file in the model folder holding REV once every file passed its content check
_check_lock = threading.Lock()  # one content check at a time; a caller that waits finds the result ready
_state_lock = threading.Lock()  # guards _verifying
_verdicts: dict = {}  # name -> result of this process's content check (set by verify_install)
_verifying: set = set()  # names with a background check running (model_verifying)


def _verified(name: str) -> bool:
    try:
        return (model_dir(name) / VERIFIED).read_text().strip() == REV
    except OSError:
        return False


def _files_linked(name: str) -> bool:
    snap = _snapshot(name)
    return snap is not None and all((snap / p).exists() for p in _required(name))


def _required(name: str) -> list:
    return [p for p in PATTERNS[name] if "*" not in p] + ["1_Pooling/config.json"]


def model_ready(name: str = DEFAULT_MODEL) -> bool:
    """True when the pinned install is marked verified and its files are linked. Never hashes: an install
    without the marker is checked in the background, once per process, and reads as not ready until then."""
    snap = _snapshot(name)
    if snap is None:
        return False
    if name not in PATTERNS:
        return snap.is_dir()
    if _ready(name):
        return True
    if name not in _verdicts:
        start_verify(name)  # lazily, on the first question about this install
    return False


def _ready(name: str) -> bool:
    return _files_linked(name) and (_verified(name) or _verdicts.get(name) is True)


def model_verifying(name: str = DEFAULT_MODEL) -> bool:
    return name in _verifying


def _write_marker(name: str) -> None:
    tmp = model_dir(name) / (VERIFIED + ".tmp")
    tmp.write_text(REV)
    os.replace(tmp, model_dir(name) / VERIFIED)  # atomic: the marker either exists whole or not at all


def _is_name(s: str, n: int) -> bool:
    return len(s) == n and all(c in "0123456789abcdef" for c in s)


def _git_sha1(path: Path) -> str:
    """The git object id of a file's bytes: how HF names small (non-LFS) blobs."""
    h = hashlib.sha1(b"blob %d\0" % path.stat().st_size)
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _blob_matches(blob: Path) -> bool:
    """A blob's name is its content hash: sha256 for LFS files (64 hex), git blob sha1 for the rest (40 hex)."""
    if _is_name(blob.name, 64):
        return _sha256(blob) == blob.name
    if _is_name(blob.name, 40):
        return _git_sha1(blob) == blob.name
    return False


def _check_install(name: str) -> bool:
    """Offline proof that the pinned snapshot is complete and intact: every required file (and every file the
    patterns match) links to a finished blob whose bytes hash to the blob's name. No network, no hash list."""
    base = model_dir(name)
    snap, blobs = base / "snapshots" / REV, (base / "blobs").resolve()
    if not snap.is_dir():
        return False
    files = set(_required(name))
    globs = [p for p in PATTERNS[name] if "*" in p]
    for f in snap.rglob("*"):
        rel = f.relative_to(snap).as_posix()
        if any(fnmatch.fnmatch(rel, g) for g in globs):
            files.add(rel)
    for rel in files:
        if not (snap / rel).exists():
            return False
        blob = (snap / rel).resolve()  # the snapshot entry is a link into blobs/
        if blob.parent != blobs or blob.name.endswith(".incomplete") or not blob.is_file():
            return False
        if blob.stat().st_size == 0 or not _blob_matches(blob):
            return False
    return True


def verify_install(name: str = DEFAULT_MODEL, force: bool = False) -> bool:
    """Synchronous and offline: ready after the check, and the marker is written when the install is intact.
    The result is kept for this process (force=True checks again). An install already marked is not hashed."""
    if name not in PATTERNS:
        return model_ready(name)
    if _files_linked(name) and _verified(name):
        return True
    with _check_lock:
        if _files_linked(name) and _verified(name):
            return True  # another thread finished the check while this one waited
        if force or name not in _verdicts:
            ok = _check_install(name)
            if ok:
                try:
                    _write_marker(name)
                except OSError:
                    pass  # the result still holds for this process; the next start checks again
            _verdicts[name] = ok
        return _verdicts[name] is True and _files_linked(name)


def start_verify(name: str = DEFAULT_MODEL, force: bool = False) -> bool:
    """Runs verify_install in a worker thread (the daemon's start, index and add; model_ready's first question).
    Returns False when nothing was started: already running, or ready."""
    with _state_lock:
        if name in _verifying or name not in PATTERNS or _ready(name):
            return False
        _verifying.add(name)

    def run():
        try:
            verify_install(name, force=force)
        finally:
            with _state_lock:
                _verifying.discard(name)

    threading.Thread(target=run, daemon=True, name=f"verify-{name}").start()
    return True


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


MAX_ATTEMPTS = 5
BACKOFF = (0.5, 1.0, 2.0, 4.0)  # seconds before attempts 2..5


def _backoff(seconds: float) -> None:
    time.sleep(seconds)


def _is_transient(e: BaseException) -> bool:
    """Network hiccups and server-side errors that a fresh attempt can fix. Not 401/404, not disk full."""
    import requests
    import ssl
    if isinstance(e, (requests.exceptions.SSLError, requests.exceptions.ConnectionError,
                      requests.exceptions.Timeout, requests.exceptions.ChunkedEncodingError,
                      ssl.SSLError, ConnectionError, TimeoutError)):
        return True
    status = getattr(getattr(e, "response", None), "status_code", None)
    return status == 429 or (isinstance(status, int) and 500 <= status <= 599)


def _retry(action, emit):
    """Run action(). A transient failure is retried after a short backoff; each retry is announced first."""
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            return action()
        except Exception as e:
            if attempt == MAX_ATTEMPTS or not _is_transient(e):
                raise
            emit({"event": "retry", "attempt": attempt + 1, "max": MAX_ATTEMPTS})
            _backoff(BACKOFF[attempt - 1])


PROGRESS_EVERY = 0.1  # seconds: a progress event when the byte count changed
POLL = 0.05
SPEED_WINDOW = 1.0


def _download_once(name, patterns, total, emit, snapshot_download):
    """One download attempt, with progress. Partial files stay on disk, so the next attempt resumes."""
    blobs = model_dir(name) / "blobs"

    def done_bytes() -> int:
        # completed blobs plus .incomplete partials: resumes count from what is already on disk
        if not blobs.exists():
            return 0
        n = 0
        for f in blobs.iterdir():
            try:
                n += f.stat().st_size if f.is_file() else 0
            except FileNotFoundError:
                pass
        return min(n, total)

    errors = []

    def work():
        try:
            snapshot_download(name, revision=REV, cache_dir=str(config.models_dir()), allow_patterns=patterns)
        except BaseException as e:  # re-raised in the calling thread
            errors.append(e)

    t = threading.Thread(target=work, daemon=True)
    t.start()
    last, last_t = None, 0.0
    samples = collections.deque()  # (time, done) for the speed: bytes/s over about the last second
    while t.is_alive():
        d = done_bytes()
        now = time.time()
        samples.append((now, d))
        while len(samples) > 2 and now - samples[1][0] >= SPEED_WINDOW:
            samples.popleft()
        if d != last and now - last_t >= PROGRESS_EVERY:
            t0, d0 = samples[0]
            speed = int((d - d0) / (now - t0)) if now > t0 else 0
            emit({"event": "progress", "done": d, "total": total, "speed": speed})
            last, last_t = d, now
        time.sleep(POLL)
    t.join()
    if errors:
        raise errors[0]


def fetch(name: str, emit) -> None:
    """Download and verify `name`. `emit` receives event dicts. Raises on failure; re-running resumes."""
    # Plain HTTP writes measurable .incomplete files (xet keeps its bytes elsewhere) and resumes them.
    os.environ["HF_HUB_DISABLE_XET"] = "1"
    from huggingface_hub import model_info, snapshot_download

    config.ensure_home()  # the download is a write: the home and the models folder come into existence here
    config.models_dir().mkdir(parents=True, exist_ok=True)
    if name not in PATTERNS:
        raise ValueError(f"fetch-model supports only {', '.join(PATTERNS)}")
    patterns = PATTERNS[name]
    info = _retry(lambda: model_info(name, revision=REV, files_metadata=True), emit)
    wanted = {s.rfilename: s for s in info.siblings
              if any(fnmatch.fnmatch(s.rfilename, p) for p in patterns)}
    required = [p for p in patterns if "*" not in p] + ["1_Pooling/config.json"]
    for p in required:
        if p not in wanted:
            raise RuntimeError(f"remote repo has no required file {p}")
    total = sum(int(s.size or 0) for s in wanted.values())
    _retry(lambda: _download_once(name, patterns, total, emit, snapshot_download), emit)

    snap = model_dir(name) / "snapshots" / info.sha
    for rfile, s in wanted.items():
        p = snap / rfile
        if not p.exists():
            raise RuntimeError(f"missing after download: {rfile}")
        if s.size is not None and p.stat().st_size != s.size:
            raise RuntimeError(f"size mismatch: {rfile}")
        lfs = getattr(s, "lfs", None)
        if lfs is not None and getattr(lfs, "sha256", None):
            if _sha256(p) != lfs.sha256:
                raise RuntimeError(f"sha256 mismatch: {rfile}")
    _write_marker(name)  # the marker is the last step: model_ready() needs it
    emit({"event": "progress", "done": total, "total": total, "speed": 0})
    if not model_ready(name):
        raise RuntimeError("model files incomplete after download")


def friendly_message(e: BaseException) -> str:
    """What the app shows. The technical text goes in `detail`."""
    if isinstance(e, OSError) and getattr(e, "errno", None) == errno.ENOSPC:
        return "Not enough disk space to download the model. Free some space and try again."
    if _is_transient(e):
        return "Couldn't reach huggingface.co. Check your internet connection and try again."
    if getattr(getattr(e, "response", None), "status_code", None) in (401, 403, 404):
        return "The model could not be found on huggingface.co. Try again later, or update Semantic Spotlight."
    if isinstance(e, ValueError):
        return "This model can't be downloaded by this version of Semantic Spotlight."
    if isinstance(e, RuntimeError):
        return "The download was interrupted and could not be verified. Try again."
    return "The model download failed. Try again."


CANCEL_EXIT = 130  # 128 + SIGINT, the shell's convention for an interrupted command


class Cancelled(BaseException):
    """Raised in the main thread by SIGTERM/SIGINT. BaseException, so the retry logic does not catch it."""


def _on_signal(signum, frame):
    raise Cancelled()


def run_fetch_cli(name: str) -> int:
    """Entry for `semsearch fetch-model`: one JSON object per stdout line.
    Events: progress, retry, done, cancelled, error (error carries `message` for people and `detail` for logs).
    SIGTERM (the app's Cancel) or SIGINT: one cancelled event, exit 130. Partial files stay for the next run."""
    last = {"done": 0, "total": 0}

    def emit(obj):
        if obj["event"] == "progress":
            last.update(done=obj["done"], total=obj["total"])
        print(json.dumps(obj, ensure_ascii=False), flush=True)

    main_thread = threading.current_thread() is threading.main_thread()
    old = {s: signal.signal(s, _on_signal) for s in (signal.SIGTERM, signal.SIGINT)} if main_thread else {}
    try:
        try:
            fetch(name, emit)
        except Cancelled:
            emit({"event": "cancelled", "done": last["done"], "total": last["total"]})
            # os._exit: the download thread may still hold the process (huggingface_hub's own pool); it is abandoned.
            os._exit(CANCEL_EXIT)
        except Exception as e:  # any failure becomes one error event
            emit({"event": "error", "message": friendly_message(e), "detail": f"{type(e).__name__}: {e}"})
            return 1
        emit({"event": "done"})
        return 0
    finally:
        for s, h in old.items():
            signal.signal(s, h)
