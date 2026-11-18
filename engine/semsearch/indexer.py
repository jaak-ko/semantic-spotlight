import collections
import hashlib
import logging
import os
import re
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from dataclasses import dataclass, field

import numpy as np

from . import chunk, config, events, modelfiles, ocr
from .store import Store
from .textnorm import keyword_text, name_text

log_debug = logging.getLogger("semsearch")
TEXTUTIL = "/usr/bin/textutil"  # built into macOS; converts RTF to plain text
SCHEMA_VERSION = 6  # bump when the stored index layout or keyword text changes (5: separators split words; 6: chunk cap, data-like flag, file name in the embedded text)
COMMIT_EVERY_FILES = 50   # a crash loses at most this many files, re-indexed next run
COMMIT_EVERY_SECONDS = 5.0
SF_DATALESS = 0x40000000  # macOS st_flags: iCloud keeps the content in the cloud; reading the file downloads it
CLOUD_WORKERS = 4  # downloads in parallel
CLOUD_AHEAD = 8  # cloud-only files read ahead of the embedder: bounded, so no hundreds of GB are queued
CLOUD_TIMEOUT = 300.0  # seconds one download may take before the file is skipped
_stat = os.stat  # indirection so tests can present files as cloud-only
RSS_LIMIT_MB = None  # a fixed limit for tests; None: rss_limit_mb(model), from this Mac's RAM
RSS_BASE_SHARE = 0.25  # the budget is this share of physical RAM ...
RSS_BASE_CAP_MB = 6144  # ... capped at 6 GB, and at least 2 GB, so the tiniest Mac still indexes
RSS_CEILING_SHARE = 0.5  # with the model's weights added, never more than half the RAM
# Resident weights (fp32 on MPS) and activations of each model, on top of the base. Unknown models get 1 GB.
MODEL_EXTRA_MB = {"intfloat/multilingual-e5-small": 0, "intfloat/multilingual-e5-base": 1024, "BAAI/bge-m3": 2048}
_RAM_MB = None


def physical_ram_mb() -> int:
    """Physical memory of this Mac in MB (sysctl hw.memsize). Unknown: 8 GB, the smallest Mac most people use."""
    global _RAM_MB
    if _RAM_MB is None:
        try:
            _RAM_MB = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], timeout=5).strip()) // (1 << 20)
        except (subprocess.SubprocessError, OSError, ValueError):
            _RAM_MB = 8192
    return _RAM_MB


def rss_limit_mb(model=None, ram_mb=None) -> int:
    """The resident memory an index run may reach before it stops after a commit and the daemon restarts:
    25% of RAM, between 2 and 6 GB, plus what the model needs resident, and never above half the RAM."""
    ram = ram_mb or physical_ram_mb()
    base = min(max(ram * RSS_BASE_SHARE, 2048), RSS_BASE_CAP_MB)
    limit = min(base + MODEL_EXTRA_MB.get(model, 1024), ram * RSS_CEILING_SHARE)
    return int(max(limit, 2048))


def rss_mb() -> int:
    """Resident memory of this process in MB (ps, no extra dependency); 0 if ps is unavailable."""
    try:
        return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())], timeout=5).strip()) // 1024
    except (subprocess.SubprocessError, OSError, ValueError):
        return 0
MIN_OCR_CHARS = 10        # an image with less recognised text than this is treated as having none
KEEP = object()           # "leave this file's row as it is" (e.g. OCR helper unavailable)


def index_signature(cfg, model):
    """Anything that changes stored content forces a rebuild."""
    rev = modelfiles.REV if model in modelfiles.PATTERNS else ""
    return (f"{model}|rev={rev}|schema={SCHEMA_VERSION}"
            f"|stem={int(bool(cfg.get('stemming')))}"
            f"|ocr={','.join(cfg.get('ocr_languages', []))}")


def _iter_files(folder, cfg):
    exts = set(cfg["extensions"])
    skip = set(cfg["skip_dirs"])
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d not in skip and not d.startswith(".")]
        for f in files:
            if f.startswith(".") or os.path.splitext(f)[1].lower() not in exts:
                continue
            yield os.path.join(root, f)


def _rtf_text(path, log):
    """Plain text of an RTF file via textutil, or None (logged) on failure."""
    try:
        out = subprocess.run([TEXTUTIL, "-convert", "txt", "-stdout", path],
                             capture_output=True, timeout=60, check=True)
        return out.stdout.decode("utf-8")
    except (subprocess.SubprocessError, OSError, UnicodeDecodeError) as e:
        log(f"warning: skipping {path}: rtf conversion failed ({type(e).__name__})")
        return None


def _read(path, max_bytes, log=print):
    """Return (raw bytes, text) or None for oversized, binary or non-UTF-8 files.
    Raises OSError for unreadable files (the caller skips them)."""
    if os.stat(path).st_size > max_bytes:
        return None
    with open(path, "rb") as fh:
        raw = fh.read()
    if os.path.splitext(path)[1].lower() == ".rtf":
        text = _rtf_text(path, log)  # hash stays on the raw bytes, so edits are still detected
        return None if text is None else (raw, text)
    if b"\0" in raw[:8192]:
        return None
    try:
        return raw, raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def _ocr_timed(ctx, helper, path, languages):
    t0 = time.perf_counter()
    try:
        return ocr.ocr_image(helper, path, languages)
    finally:
        ctx["timing"]["ocr"] += time.perf_counter() - t0


def _image(ctx, path, st):
    """(raw bytes, OCR text), None to drop the file's row, or KEEP when OCR is unavailable."""
    store, cfg, log, stats = ctx["store"], ctx["cfg"], ctx["log"], ctx["stats"]
    if st.st_size > cfg["max_image_bytes"]:
        log(f"skip {path}: image larger than max_image_bytes")
        stats["files_skipped"] += 1
        return None
    helper = _helper(ctx)
    if helper is None:
        stats["images_skipped"] += 1
        return KEEP
    with open(path, "rb") as fh:
        raw = fh.read()
    sha = hashlib.sha256(raw).hexdigest()
    languages = cfg["ocr_languages"]
    key = f"{sha}|{','.join(languages)}"
    text = store.get_ocr(key, path)
    if text is None:
        try:
            text = _ocr_timed(ctx, helper, path, languages)
        except ocr.OcrError as e:
            log(f"skip {path}: OCR failed ({e})")
            stats["images_skipped"] += 1
            if e.permanent:
                store.put_ocr(key, "", path)  # the file itself is unreadable: do not retry it every run
            return None
        store.put_ocr(key, text, path)  # cached by content: unchanged or renamed images are never re-OCRed
        stats["images_ocred"] += 1
    text = text.strip()
    if len(text) < MIN_OCR_CHARS:
        log_debug.debug("no text recognised in %s", path)
        stats["images_no_text"] += 1
        return raw, ""  # kept with no text: one empty chunk, so the file name still finds it (as for empty files)
    return raw, text


def _inside(path, root):
    real = os.path.realpath(path)
    return real == root or real.startswith(root + os.sep)


def _helper(ctx):
    """The OCR helper, looked up once per run; warns once when it is missing."""
    h = ctx["helper"]
    if not h["resolved"]:
        h["resolved"] = True
        h["path"] = ocr.find_helper(ctx["log"])
        if h["path"] is None:
            ctx["log"]("warning: OCR helper unavailable: images will not be indexed")
    return h["path"]


def _extract(ctx, path, st):
    """(raw bytes, text), None to drop the row, or KEEP to leave it as it is."""
    if os.path.splitext(path)[1].lower() in ocr.IMAGE_EXT:
        return _image(ctx, path, st)
    return _read(path, ctx["cfg"]["max_file_bytes"], ctx["log"])


def _count_and_maybe_commit(ctx):
    ctx["pending"][0] += 1
    _maybe_commit(ctx)


def _maybe_commit(ctx, force=False):
    pending = ctx["pending"]
    if force or pending[0] >= COMMIT_EVERY_FILES or time.time() - pending[1] >= COMMIT_EVERY_SECONDS:
        ctx["store"].commit()
        pending[0], pending[1] = 0, time.time()
        rss = rss_mb()
        ctx["peak_rss"] = max(ctx.get("peak_rss", 0), rss)  # sampled at each commit: the run's peak
        if rss > ctx["rss_limit"]:
            ctx["memory_limit"] = True


def _spans(text, emb, cfg):
    """Chunk spans of `text`, trimmed of surrounding whitespace."""
    spans = []
    for s, e in chunk.chunk_spans(text, emb.count, cfg["chunk_tokens"], cfg["chunk_overlap"]):
        piece = text[s:e]
        a = len(piece) - len(piece.lstrip())
        b = len(piece.rstrip())
        if a < b:
            spans.append((s + a, s + b))
    return spans


_PROSE_PUNCT = set(".,;:!?'\"()-")
DATA_LIKE_SHARE = 0.6  # letters and prose punctuation among the non-space characters of the first 64 KB
DATA_LIKE_LINE = 4000  # a line this long (minified JSON, one-line dumps) is data, whatever its share


def _data_like(text: str) -> bool:
    """True for CSV/JSON/log dumps and similar: mostly digits and symbols, or very long lines. Prose is not."""
    head = text[:65536]
    nonspace = [c for c in head if not c.isspace()]
    if not nonspace:
        return False
    prose = sum(c.isalpha() or c in _PROSE_PUNCT for c in nonspace)
    return prose / len(nonspace) < DATA_LIKE_SHARE or max(len(line) for line in head.split("\n")) > DATA_LIKE_LINE


def _name_words(path) -> str:
    """The file name without its extension, as words for its name vector: 'poliittinen_meta-kartta.txt' ->
    'poliittinen meta kartta'."""
    return " ".join(re.sub(r"[_\-]+", " ", os.path.splitext(os.path.basename(path))[0]).split())


def _index_file(ctx, path, folder):
    """Index one file if it is new or changed. Raises OSError for files that cannot be read.
    Nothing is written if `folder` was removed while the file was being embedded."""
    store, emb, cfg, stats = ctx["store"], ctx["emb"], ctx["cfg"], ctx["stats"]
    st = _stat(path)
    row = store.file_row(path)
    if row and row[1] == st.st_mtime and row[2] == st.st_size:
        return  # unchanged: no read, no hash, no embedding
    ocr0, t0 = ctx["timing"]["ocr"], time.perf_counter()
    got = _extract(ctx, path, st)
    ctx["timing"]["read"] += time.perf_counter() - t0 - (ctx["timing"]["ocr"] - ocr0)
    if got is KEEP:
        return
    if got is None:
        if row:
            store.delete_file(row[0])
        return
    raw, text = got
    sha = hashlib.sha256(raw).hexdigest()
    stats["files_hashed"] += 1
    if row and row[3] == sha:  # touched but same content: keep chunks
        store.touch_file(row[0], st.st_mtime, st.st_size)
        _count_and_maybe_commit(ctx)
        return
    spans = _spans(text, emb, cfg)
    limit = cfg.get("max_chunks_per_file", 150)
    partial = len(spans) > limit  # a huge or data-like file: its first chunks only, the name still counts
    spans = spans[:limit]
    data_like = _data_like(text)
    words = _name_words(path)
    if spans:
        t0 = time.perf_counter()  # the name's vector rides in the same batch as the chunks
        allv = emb.embed([text[s:e] for s, e in spans] + [words], "passage")
        vecs, name_vec = allv[:-1], allv[-1]
        ctx["timing"]["embed"] += time.perf_counter() - t0
    else:
        # No text (an empty file, or an image without OCR text): one empty chunk with a zero vector, so the
        # file name is still a keyword match. Its zero cosine never passes the floor on its own.
        spans = [(0, 0)]
        vecs = np.zeros((1, emb.model.get_sentence_embedding_dimension()), dtype=np.float32)
        name_vec = emb.embed([words], "passage")[0]
    name = name_text(path, cfg)
    # The name goes into the first chunk only: a long file is not favoured by having its name in every chunk.
    fts_texts = [keyword_text(text[s:e], cfg) + ("\n" + name if seq == 0 else "") for seq, (s, e) in enumerate(spans)]
    if row:
        store.delete_file(row[0])
    fid = store.add_file(path, st.st_mtime, st.st_size, sha, folder, partial=partial,
                         name_vec=np.asarray(name_vec, dtype=np.float32).tobytes())
    if fid is None:
        return
    for seq, ((s, e), v, ft) in enumerate(zip(spans, vecs, fts_texts)):
        store.add_chunk(fid, seq, s, e, text[s:e], v.tobytes(), ft)
    stats["files_embedded"] += 1
    stats["chunks_embedded"] += len(spans)
    stats["files_truncated"] += int(partial)
    stats["files_data_like"] += int(data_like)
    _count_and_maybe_commit(ctx)


@dataclass
class Progress:
    """What the status endpoint reports while indexing. Counts only: never file names or paths.
    Written by the index worker, read by request handlers, hence the lock."""
    phase: str = "idle"          # "idle" | "scanning" | "indexing"
    done: int = 0                # files fully processed in this run (indexed, skipped or removed)
    total: int = 0               # files that need work in this run; 0 until the scan finishes
    lock: threading.Lock = field(default_factory=threading.Lock, repr=False, compare=False)
    waiting_cloud: int = 0       # cloud-only files of this run not yet downloaded and processed
    folders: dict = field(default_factory=dict, repr=False, compare=False)  # path -> [done, total, phase]

    def start_session(self):
        with self.lock:
            self.phase, self.done, self.total = "scanning", 0, 0
            self.waiting_cloud = 0
            self.folders.clear()

    def add_folder_work(self, folder, n):
        with self.lock:
            f = self.folders.setdefault(folder, [0, 0, "scanning"])
            f[1] += n
            f[2] = "indexing" if f[1] else "done"

    def set_waiting(self, n):
        with self.lock:
            self.waiting_cloud = n

    def cloud_done(self):
        with self.lock:
            self.waiting_cloud = max(0, self.waiting_cloud - 1)

    def begin_scan(self):
        with self.lock:
            self.phase = "scanning"

    def add_work(self, n):
        with self.lock:
            self.total += n
            self.phase = "indexing"

    def tick(self, folder=None):
        with self.lock:
            if self.done < self.total:
                self.done += 1
            f = self.folders.get(folder)
            if f and f[0] < f[1]:
                f[0] += 1
                if f[0] == f[1]:
                    f[2] = "done"

    def abandon(self):
        """A folder's run failed: its unrun items leave the total, so done == total for the work that ran.
        Later folders in the same batch still run and add their own work."""
        with self.lock:
            self.total = self.done

    def end_session(self):
        with self.lock:
            self.phase = "idle"  # done and total keep their last values

    def snapshot(self) -> dict:
        with self.lock:
            return {"phase": self.phase, "done": self.done, "total": self.total}

    def status(self) -> dict:
        """The app's progress payload: the run's counts, waiting_cloud, and per folder path, done, total, phase."""
        with self.lock:
            return {"phase": self.phase, "done": self.done, "total": self.total, "waiting_cloud": self.waiting_cloud,
                    "folders": [{"path": p, "done": d, "total": t, "phase": ph}
                                for p, (d, t, ph) in self.folders.items()]}


def _dataless(st) -> bool:
    return bool(getattr(st, "st_flags", 0) & SF_DATALESS)


def _scan_folder(ctx, folder):
    """Walk one folder and return the work items for this run. Every item ends with its folder:
    ("index", path, folder), ("cloud", path, folder) for iCloud files that must download first,
    ("skip", path, reason, folder), ("remove", file_id, folder). Unchanged files produce no item and are
    never read (the stat alone decides), so an evicted iCloud file that is unchanged costs nothing."""
    store, cfg, stats, log = ctx["store"], ctx["cfg"], ctx["stats"], ctx["log"]
    root = os.path.realpath(folder)
    items, seen = [], set()
    for path in _iter_files(folder, cfg):
        stats["files_scanned"] += 1
        seen.add(path)
        try:
            if not _inside(path, root):
                items.append(("skip", path, f"symlink resolves outside {folder}", folder))
                continue
            st = _stat(path)
            row = store.file_row(path)
        except OSError as e:  # dangling symlink, permission denied, vanished mid-run
            items.append(("skip", path, e.strerror or type(e).__name__, folder))
            _error(ctx, e, ctx["folder_no"].get(folder, -1))
            continue
        if row and row[1] == st.st_mtime and row[2] == st.st_size:
            continue  # unchanged: nothing to do
        items.append(("cloud" if _dataless(st) else "index", path, folder))
    for fid, p in store.files_under(folder):
        if p not in seen:
            items.append(("remove", fid, folder))
    return items


def _process(ctx, item):
    """Carry out one work item. Every item is counted as done by the caller, whatever happens here."""
    store, log, stats = ctx["store"], ctx["log"], ctx["stats"]
    if item[0] in ("index", "cloud"):
        if item[2] not in store.folders():  # removed during this run: its files stay out
            return
        try:
            _index_file(ctx, item[1], item[2])
        except OSError as e:
            log(f"skip {item[1]}: {e.strerror or type(e).__name__}")
            stats["files_skipped"] += 1  # an existing row is left as it was
            _error(ctx, e, ctx["folder_no"].get(item[2], -1))
    elif item[0] == "skip":
        log(f"skip {item[1]}: {item[2]}")
        stats["files_skipped"] += 1
    else:
        store.delete_file(item[1])
        stats["files_removed"] += 1


def _schema(sig) -> int:
    m = re.search(r"schema=(\d+)", sig or "")
    return int(m.group(1)) if m else 0


_REBUILDING: set = set()  # index paths whose rebuild is running in this process (status: rebuilding)


def is_rebuilding() -> bool:
    """True from the moment a schema, model or settings rebuild starts until its indexing has finished."""
    return bool(_REBUILDING)


def _check_signature(store, emb, cfg, log):
    sig = index_signature(cfg, emb.name)
    old = store.get_meta("sig")
    if old != sig:  # also rebuilds indexes written before signatures existed
        if store.counts()[0]:  # a new, empty index has nothing to rebuild
            _REBUILDING.add(str(store.path))
            log(f"index settings changed ({sig}): rebuilding index")
            events.write("info", "schema_rebuild", reason="schema" if _schema(old) != SCHEMA_VERSION else "settings",
                         **{"from": _schema(old), "to": SCHEMA_VERSION})
        store.reset()
    store.set_meta("sig", sig)
    store.set_meta("model", emb.name)


_LOGGED: set = set()  # skip messages already printed by this process


def _once(log):
    """Skip messages are printed once per process: a daemon re-scans the same skipped files on every run."""
    def inner(msg):
        if msg.startswith(("skip ", "warning: skipping")):
            if msg in _LOGGED:
                return
            _LOGGED.add(msg)
        log(msg)
    return inner


ERROR_EVENTS = 50  # index_error events per run; later failures are only counted (index_end has the count)


def _error(ctx, e, folder_index):
    cls = type(e).__name__
    ctx["errors"][cls] = ctx["errors"].get(cls, 0) + 1
    if sum(ctx["errors"].values()) <= ERROR_EVENTS:
        events.write("warn", "index_error", **{"class": cls, "message": getattr(e, "strerror", None) or str(e),
                                              "folder_index": folder_index})


def sync(store: Store, emb, cfg: dict, folders=None, log=print, progress=None, trigger="manual") -> dict:
    """Index the given folders (default: all registered) with the event log: index_start, then index_end, or
    index_error if the run itself fails."""
    events.write("info", "index_start", trigger=trigger, folders=len(folders or store.folders()), rss_mb=rss_mb())
    try:
        st = _sync(store, emb, cfg, folders, log, progress)
    except Exception as e:
        events.write("error", "index_error", **{"class": type(e).__name__, "message": str(e), "folder_index": -1})
        raise
    finally:
        _REBUILDING.discard(str(store.path))  # the rebuild's indexing is over, or it failed
    errors = st["error_classes"]
    events.write("warn" if errors else "info", "index_end", rss_mb=rss_mb(), peak_rss_mb=st["peak_rss_mb"],
                 files_scanned=st["files_scanned"], files_cloud_only=st["files_cloud_only"],
                 files_truncated=st["files_truncated"], files_data_like=st["files_data_like"],
                 files_prefetched=st["files_prefetched"], seconds_scan=st["seconds_scan"],
                 seconds_read=st["seconds_read"], seconds_embed=st["seconds_embed"], seconds_ocr=st["seconds_ocr"],
                 slowest_file_seconds=st["slowest_file_seconds"], files_per_minute=st["files_per_minute"],
                 files_embedded=st["files_embedded"], files_removed=st["files_removed"], chunks=store.counts()[1],
                 seconds=st["seconds"], errors=sum(errors.values()),
                 top_errors=[{"class": c, "count": n} for c, n in sorted(errors.items(), key=lambda kv: -kv[1])[:5]])
    return st


def _run_item(ctx, progress, item):
    """One work item, counted in the progress and in the slowest-file timing."""
    t0 = time.perf_counter()
    try:
        _process(ctx, item)
    finally:
        progress.tick(item[-1])
    ctx["slowest"] = max(ctx["slowest"], time.perf_counter() - t0)
    _maybe_commit(ctx)


def _fetch(path):
    """Read a cloud-only file to the end, which makes iCloud download it. Read-only; the bytes are discarded."""
    with open(path, "rb") as fh:
        while fh.read(1 << 20):
            pass


def _run_cloud(ctx, progress, items):
    """iCloud files. Each read downloads its file, so the reads run ahead on a few threads (at most CLOUD_AHEAD
    waiting) and the embedder works on local files and downloaded ones meanwhile. A download that fails or
    takes longer than CLOUD_TIMEOUT is a skipped file with its error class; the run goes on."""
    if not items:
        return
    store, stats, cfg = ctx["store"], ctx["stats"], ctx["cfg"]
    limit = max(cfg["max_file_bytes"], cfg["max_image_bytes"])
    pool = ThreadPoolExecutor(max_workers=CLOUD_WORKERS, thread_name_prefix="icloud")
    queue, todo = collections.deque(), iter(items)

    def top_up():
        while len(queue) < CLOUD_AHEAD:
            item = next(todo, None)
            if item is None:
                return
            try:
                small = _stat(item[1]).st_size <= limit  # bigger files are never read: no download needed
            except OSError:
                small = False
            queue.append((item, pool.submit(_fetch, item[1]) if small else None))

    try:
        top_up()
        while queue:
            item, fut = queue.popleft()
            top_up()
            t0 = time.perf_counter()
            err = None
            if fut is not None:
                try:
                    fut.result(timeout=CLOUD_TIMEOUT)
                    stats["files_prefetched"] += 1
                except FutureTimeout:
                    err = TimeoutError(f"download took longer than {CLOUD_TIMEOUT:g} s")
                except Exception as e:  # a failed download, offline or evicted again: skipped, never fatal
                    err = e
            progress.cloud_done()  # downloaded (or failed): no longer waiting in the cloud
            if err is None:
                _run_item(ctx, progress, item)
            else:
                ctx["log"](f"skip {item[1]}: download failed ({type(err).__name__})")
                stats["files_skipped"] += 1
                _error(ctx, err, ctx["folder_no"].get(item[-1], -1))
                progress.tick(item[-1])
            ctx["slowest"] = max(ctx["slowest"], time.perf_counter() - t0)
            if ctx.get("memory_limit"):
                break
    finally:
        pool.shutdown(wait=False, cancel_futures=True)


def _sync(store: Store, emb, cfg: dict, folders=None, log=print, progress=None) -> dict:
    """Bring the index up to date with the given folders (default: all registered).
    Scans every folder first (the total for `progress` is known before any file is read), then processes."""
    progress = progress or Progress()
    log = _once(log)
    _check_signature(store, emb, cfg, log)
    ctx = {"store": store, "emb": emb, "cfg": cfg, "log": log,
           "stats": {"files_scanned": 0, "files_hashed": 0, "files_embedded": 0,
                     "chunks_embedded": 0, "files_removed": 0, "files_skipped": 0,
                     "images_ocred": 0, "images_no_text": 0, "images_skipped": 0,
                     "files_truncated": 0, "files_data_like": 0},
           "pending": [0, time.time()],  # files since last commit, time of last commit
           "errors": {}, "folder_no": {f: i for i, f in enumerate(store.folders())},
           "timing": {"read": 0.0, "ocr": 0.0, "embed": 0.0}, "slowest": 0.0,
           "rss_limit": RSS_LIMIT_MB or rss_limit_mb(cfg["model"]),
           "helper": {"resolved": False, "path": None}}
    t0 = time.time()
    progress.begin_scan()
    local, cloud = [], []
    for folder in folders or store.folders():
        folder = os.path.abspath(folder)
        if not os.path.isdir(folder):
            log(f"skip missing folder {folder}")
            continue
        scanned = _scan_folder(ctx, folder)
        progress.add_folder_work(folder, len(scanned))
        for item in scanned:
            (cloud if item[0] == "cloud" else local).append(item)
    t_scan = time.time() - t0
    progress.add_work(len(local) + len(cloud))
    progress.set_waiting(len(cloud))
    ctx["stats"].update(files_cloud_only=len(cloud), files_prefetched=0)
    for item in local:  # local files first: the index grows while the cloud downloads run
        _run_item(ctx, progress, item)
        if ctx.get("memory_limit"):
            break  # committed so far; the rest waits for the next run
    if not ctx.get("memory_limit"):
        _run_cloud(ctx, progress, cloud)
    progress.set_waiting(0)
    if not folders:  # every folder was synced: OCR results of vanished images can go
        store.prune_ocr(store.folders())
    _maybe_commit(ctx, force=True)
    ctx["stats"]["seconds"] = round(time.time() - t0, 2)
    st = ctx["stats"]
    st["error_classes"] = dict(ctx["errors"])
    st["memory_limit"] = bool(ctx.get("memory_limit"))
    st["peak_rss_mb"] = ctx.get("peak_rss", 0)
    st["seconds_scan"] = round(t_scan, 2)
    st["seconds_read"] = round(ctx["timing"]["read"], 2)
    st["seconds_embed"] = round(ctx["timing"]["embed"], 2)
    st["seconds_ocr"] = round(ctx["timing"]["ocr"], 2)
    st["slowest_file_seconds"] = round(ctx["slowest"], 2)
    st["files_per_minute"] = round(st["files_embedded"] / (st["seconds"] / 60), 1) if st["seconds"] else 0.0
    return st
