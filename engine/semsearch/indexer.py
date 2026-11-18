import hashlib
import logging
import os
import re
import subprocess
import threading
import time
from dataclasses import dataclass, field

import numpy as np

from . import chunk, config, events, modelfiles, ocr
from .store import Store
from .textnorm import keyword_text, name_text

log_debug = logging.getLogger("semsearch")
TEXTUTIL = "/usr/bin/textutil"  # built into macOS; converts RTF to plain text
SCHEMA_VERSION = 5  # bump when the stored index layout or keyword text changes (5: separators split words)
COMMIT_EVERY_FILES = 50   # a crash loses at most this many files, re-indexed next run
COMMIT_EVERY_SECONDS = 5.0
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
            text = ocr.ocr_image(helper, path, languages)
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


def _index_file(ctx, path, folder):
    """Index one file if it is new or changed. Raises OSError for files that cannot be read.
    Nothing is written if `folder` was removed while the file was being embedded."""
    store, emb, cfg, stats = ctx["store"], ctx["emb"], ctx["cfg"], ctx["stats"]
    st = os.stat(path)
    row = store.file_row(path)
    if row and row[1] == st.st_mtime and row[2] == st.st_size:
        return  # unchanged: no read, no hash, no embedding
    got = _extract(ctx, path, st)
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
    if spans:
        vecs = emb.embed([text[s:e] for s, e in spans], "passage")
    else:
        # No text (an empty file, or an image without OCR text): one empty chunk with a zero vector, so the
        # file name is still a keyword match. Its zero cosine never passes the floor on its own.
        spans = [(0, 0)]
        vecs = np.zeros((1, emb.model.get_sentence_embedding_dimension()), dtype=np.float32)
    name = name_text(path, cfg)
    # The name goes into the first chunk only: a long file is not favoured by having its name in every chunk.
    fts_texts = [keyword_text(text[s:e], cfg) + ("\n" + name if seq == 0 else "") for seq, (s, e) in enumerate(spans)]
    if row:
        store.delete_file(row[0])
    fid = store.add_file(path, st.st_mtime, st.st_size, sha, folder)
    if fid is None:
        return
    for seq, ((s, e), v, ft) in enumerate(zip(spans, vecs, fts_texts)):
        store.add_chunk(fid, seq, s, e, text[s:e], v.tobytes(), ft)
    stats["files_embedded"] += 1
    stats["chunks_embedded"] += len(spans)
    _count_and_maybe_commit(ctx)


@dataclass
class Progress:
    """What the status endpoint reports while indexing. Counts only: never file names or paths.
    Written by the index worker, read by request handlers, hence the lock."""
    phase: str = "idle"          # "idle" | "scanning" | "indexing"
    done: int = 0                # files fully processed in this run (indexed, skipped or removed)
    total: int = 0               # files that need work in this run; 0 until the scan finishes
    lock: threading.Lock = field(default_factory=threading.Lock, repr=False, compare=False)

    def start_session(self):
        with self.lock:
            self.phase, self.done, self.total = "scanning", 0, 0

    def begin_scan(self):
        with self.lock:
            self.phase = "scanning"

    def add_work(self, n):
        with self.lock:
            self.total += n
            self.phase = "indexing"

    def tick(self):
        with self.lock:
            if self.done < self.total:
                self.done += 1

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


def _scan_folder(ctx, folder):
    """Walk one folder and return the work items for this run: ("index", path), ("skip", path, reason)
    or ("remove", file_id). Unchanged files produce no item."""
    store, cfg, stats, log = ctx["store"], ctx["cfg"], ctx["stats"], ctx["log"]
    root = os.path.realpath(folder)
    items, seen = [], set()
    for path in _iter_files(folder, cfg):
        stats["files_scanned"] += 1
        seen.add(path)
        try:
            if not _inside(path, root):
                items.append(("skip", path, f"symlink resolves outside {folder}"))
                continue
            st = os.stat(path)
            row = store.file_row(path)
        except OSError as e:  # dangling symlink, permission denied, vanished mid-run
            items.append(("skip", path, e.strerror or type(e).__name__))
            _error(ctx, e, ctx["folder_no"].get(folder, -1))
            continue
        if row and row[1] == st.st_mtime and row[2] == st.st_size:
            continue  # unchanged: nothing to do
        items.append(("index", path, folder))
    for fid, p in store.files_under(folder):
        if p not in seen:
            items.append(("remove", fid))
    return items


def _process(ctx, item):
    """Carry out one work item. Every item is counted as done by the caller, whatever happens here."""
    store, log, stats = ctx["store"], ctx["log"], ctx["stats"]
    if item[0] == "index":
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


def _check_signature(store, emb, cfg, log):
    sig = index_signature(cfg, emb.name)
    old = store.get_meta("sig")
    if old != sig:  # also rebuilds indexes written before signatures existed
        if store.counts()[0]:  # a new, empty index has nothing to rebuild
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
        events.write("warn", "index_error", **{"class": cls, "message": e.strerror or str(e),
                                              "folder_index": folder_index})


def sync(store: Store, emb, cfg: dict, folders=None, log=print, progress=None, trigger="manual") -> dict:
    """Index the given folders (default: all registered) with the event log: index_start, then index_end, or
    index_error if the run itself fails."""
    events.write("info", "index_start", trigger=trigger, folders=len(folders or store.folders()))
    try:
        st = _sync(store, emb, cfg, folders, log, progress)
    except Exception as e:
        events.write("error", "index_error", **{"class": type(e).__name__, "message": str(e), "folder_index": -1})
        raise
    errors = st["error_classes"]
    events.write("warn" if errors else "info", "index_end", files_scanned=st["files_scanned"],
                 files_embedded=st["files_embedded"], files_removed=st["files_removed"], chunks=store.counts()[1],
                 seconds=st["seconds"], errors=sum(errors.values()),
                 top_errors=[{"class": c, "count": n} for c, n in sorted(errors.items(), key=lambda kv: -kv[1])[:5]])
    return st


def _sync(store: Store, emb, cfg: dict, folders=None, log=print, progress=None) -> dict:
    """Bring the index up to date with the given folders (default: all registered).
    Scans every folder first (the total for `progress` is known before any file is read), then processes."""
    progress = progress or Progress()
    log = _once(log)
    _check_signature(store, emb, cfg, log)
    ctx = {"store": store, "emb": emb, "cfg": cfg, "log": log,
           "stats": {"files_scanned": 0, "files_hashed": 0, "files_embedded": 0,
                     "chunks_embedded": 0, "files_removed": 0, "files_skipped": 0,
                     "images_ocred": 0, "images_no_text": 0, "images_skipped": 0},
           "pending": [0, time.time()],  # files since last commit, time of last commit
           "errors": {}, "folder_no": {f: i for i, f in enumerate(store.folders())},
           "helper": {"resolved": False, "path": None}}
    t0 = time.time()
    progress.begin_scan()
    items = []
    for folder in folders or store.folders():
        folder = os.path.abspath(folder)
        if not os.path.isdir(folder):
            log(f"skip missing folder {folder}")
            continue
        items += _scan_folder(ctx, folder)
    progress.add_work(len(items))
    for item in items:
        try:
            _process(ctx, item)
        finally:
            progress.tick()
        _maybe_commit(ctx)
    if not folders:  # every folder was synced: OCR results of vanished images can go
        store.prune_ocr(store.folders())
    _maybe_commit(ctx, force=True)
    ctx["stats"]["seconds"] = round(time.time() - t0, 2)
    ctx["stats"]["error_classes"] = dict(ctx["errors"])
    return ctx["stats"]
