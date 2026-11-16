import os
import sqlite3
import time
from pathlib import Path

import numpy as np

from . import config

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS folders (path TEXT PRIMARY KEY);
CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL,
    mtime REAL, size INTEGER, sha256 TEXT);
CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY,
    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    seq INTEGER, start INTEGER, end INTEGER, text TEXT, vec BLOB);
CREATE INDEX IF NOT EXISTS chunks_file ON chunks(file_id);
-- rowid of fts == chunks.id; kept in sync by Store.add_chunk / delete_file
CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(text, tokenize='unicode61 remove_diacritics 2');
-- OCR output by "<sha256>|<languages>": unchanged, touched or renamed images are never re-OCRed.
-- `path` is where the image was last seen; prune_ocr drops entries whose image is gone.
CREATE TABLE IF NOT EXISTS ocr_cache (key TEXT PRIMARY KEY, text TEXT NOT NULL, path TEXT);
"""
STORE_MARK = "1"  # meta 'schema': the schema script has run; later opens skip it
VEC_REFRESH_SECONDS = 5.0  # the vector matrix is rebuilt at most this often while the index changes

# Vector matrix cache per DB path: (gen, ids, matrix, loaded_at). Rebuilt when the gen changes, at most every few seconds.
_VEC_CACHE: dict = {}
# Folder path -> sorted chunk ids under it, per DB path and generation: toggling folders in the UI costs no re-scan.
_SCOPE_CACHE: dict = {}
# DB path -> (gen, folder stats): status runs twice a second while indexing.
_STATS_CACHE: dict = {}


def _prefix(folder):
    """A folder as a path prefix with a trailing slash: /a/foo does not match /a/foobar."""
    return folder.rstrip("/") + "/"


def inside(path, folder):
    """True when `path` is `folder` or lies under it. The one definition of 'under a folder' in Python."""
    return path == folder or path.startswith(_prefix(folder))


def _prefix_pattern(folder):
    """The same test as `inside`, as a LIKE pattern for SQL."""
    return _prefix(folder).replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"


def index_path() -> Path:
    return config.home() / "index.db"


def read_folder_stats():
    """[{"path", "files"}] without creating an index: empty when there is none."""
    if not index_path().exists():
        return []
    with Store() as s:
        return s.folder_stats()


def read_summary():
    """(files, chunks, folders) from the index without creating one: zeros when there is no index yet."""
    if not index_path().exists():
        return 0, 0, []
    with Store() as s:
        f, c = s.counts()
        return f, c, s.folders()


class Store:
    def __init__(self, path: Path | None = None):
        if path is None:
            config.ensure_home()  # opening the default index is a write: it creates the home
        self.path = Path(path) if path else index_path()
        old = os.umask(0o077)  # new db, -wal and -shm files are private from creation
        try:
            self.db = sqlite3.connect(self.path, timeout=30)
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("PRAGMA foreign_keys=ON")
            self._ensure_schema()
        finally:
            os.umask(old)
        self._dirty = False
        self._secure()

    def _ensure_schema(self):
        try:
            done = self.db.execute("SELECT value FROM meta WHERE key='schema'").fetchone()
        except sqlite3.OperationalError:  # a new file has no tables yet
            done = None
        if done:
            return
        self.db.executescript(SCHEMA)
        cols = [r[1] for r in self.db.execute("PRAGMA table_info(ocr_cache)")]
        if "path" not in cols:  # OCR caches written before paths were kept
            self.db.execute("ALTER TABLE ocr_cache ADD COLUMN path TEXT")
        self.db.execute("INSERT OR REPLACE INTO meta VALUES ('schema', ?)", (STORE_MARK,))
        self.db.commit()

    def _secure(self):
        for suffix in ("", "-wal", "-shm"):
            p = Path(str(self.path) + suffix)
            if p.exists():
                os.chmod(p, 0o600)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.commit()
        self.db.close()

    # --- meta / folders -------------------------------------------------
    def get_meta(self, key):
        row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key, value):
        self.db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (key, str(value)))
        self._dirty = True

    def folders(self):
        return [r[0] for r in self.db.execute("SELECT path FROM folders ORDER BY path")]

    def add_folder(self, path):
        self.db.execute("INSERT OR IGNORE INTO folders VALUES (?)", (path,))
        self._dirty = True

    def remove_folder(self, path):
        self.db.execute("DELETE FROM folders WHERE path=?", (path,))
        self._dirty = True
        remaining = self.folders()
        for fid, p in self.files_under(path):
            # keep files that a still-registered folder (e.g. a parent) also covers
            if not any(inside(p, f) for f in remaining):
                self.delete_file(fid)

    # --- files / chunks -------------------------------------------------
    def file_row(self, path):
        return self.db.execute(
            "SELECT id, mtime, size, sha256 FROM files WHERE path=?", (path,)).fetchone()

    def files_under(self, folder):
        return self.db.execute(
            "SELECT id, path FROM files WHERE path LIKE ? ESCAPE '\\'", (_prefix_pattern(folder),)).fetchall()

    def folder_stats(self):
        """[{"path", "files"}] per registered folder: files under it (folders can overlap, so counts are per folder).
        Cached per generation: a status call with no change runs no LIKE scan."""
        gen = self.get_meta("gen")
        key = str(self.path)
        hit = _STATS_CACHE.get(key)
        if hit and hit[0] == gen and not self._dirty:
            return [dict(x) for x in hit[1]]
        out = [{"path": f, "files": self.db.execute(
            "SELECT COUNT(*) FROM files WHERE path LIKE ? ESCAPE '\\'", (_prefix_pattern(f),)).fetchone()[0]}
            for f in self.folders()]
        if not self._dirty:
            _STATS_CACHE[key] = (gen, out)
        return [dict(x) for x in out]

    def folder_chunk_ids(self, folders):
        """Sorted chunk ids under the given folders. Only registered folders count: other paths are ignored.
        Each folder's ids are cached per generation, so repeated queries and toggles never re-scan."""
        gen = self.get_meta("gen")
        registered = set(self.folders())
        wanted = sorted({f for f in folders if f in registered})
        key = str(self.path)
        hit = _SCOPE_CACHE.get(key)
        if not hit or hit[0] != gen:
            hit = (gen, {})
            _SCOPE_CACHE[key] = hit
        per = hit[1]
        parts = []
        for f in wanted:
            if f not in per:
                rows = self.db.execute(
                    "SELECT c.id FROM chunks c JOIN files fl ON fl.id = c.file_id "
                    "WHERE fl.path LIKE ? ESCAPE '\\' ORDER BY c.id", (_prefix_pattern(f),)).fetchall()
                per[f] = np.array([r[0] for r in rows], dtype=np.int64)
            parts.append(per[f])
        if not parts:
            return np.zeros(0, dtype=np.int64)
        return np.unique(np.concatenate(parts))

    def touch_file(self, fid, mtime, size):
        self.db.execute("UPDATE files SET mtime=?, size=? WHERE id=?", (mtime, size, fid))
        self._dirty = True

    def add_file(self, path, mtime, size, sha, folder=None):
        """Insert a file row. With `folder`, the insert happens only while that folder is still registered
        (checked in the same statement), so a removal cannot leave the file behind. Returns None when refused."""
        cur = self.db.execute(
            "INSERT INTO files (path, mtime, size, sha256) SELECT ?,?,?,? "
            "WHERE ? IS NULL OR EXISTS (SELECT 1 FROM folders WHERE path=?)",
            (path, mtime, size, sha, folder, folder))
        self._dirty = True
        return cur.lastrowid if cur.rowcount else None

    def delete_file(self, fid):
        ids = [(r[0],) for r in self.db.execute("SELECT id FROM chunks WHERE file_id=?", (fid,))]
        self.db.executemany("DELETE FROM fts WHERE rowid=?", ids)
        self.db.execute("DELETE FROM files WHERE id=?", (fid,))  # cascades to chunks
        self._dirty = True

    def add_chunk(self, fid, seq, start, end, text, vec: bytes, fts_text: str):
        cur = self.db.execute(
            "INSERT INTO chunks (file_id, seq, start, end, text, vec) VALUES (?,?,?,?,?,?)",
            (fid, seq, start, end, text, vec))
        self.db.execute("INSERT INTO fts (rowid, text) VALUES (?,?)", (cur.lastrowid, fts_text))
        self._dirty = True

    def get_ocr(self, key, path):
        row = self.db.execute("SELECT text, path FROM ocr_cache WHERE key=?", (key,)).fetchone()
        if row is None:
            return None
        if row[1] != path:  # seen at this path now: the entry is kept for it
            self.db.execute("UPDATE ocr_cache SET path=? WHERE key=?", (path, key))
            self._dirty = True
        return row[0]

    def put_ocr(self, key, text, path):
        self.db.execute("INSERT OR REPLACE INTO ocr_cache VALUES (?,?,?)", (key, text, path))
        self._dirty = True

    def prune_ocr(self, folders):
        """Drop OCR results whose image is gone or no longer under a registered folder. Run after a full sync."""
        dead = [(k,) for k, p in self.db.execute("SELECT key, path FROM ocr_cache")
                if not p or not os.path.exists(p) or not any(inside(p, f) for f in folders)]
        if dead:
            self.db.executemany("DELETE FROM ocr_cache WHERE key=?", dead)
            self._dirty = True

    def reset(self):
        """Drop all indexed content (used when the index signature changes)."""
        for fid, _ in self.db.execute("SELECT id, path FROM files").fetchall():
            self.delete_file(fid)

    def counts(self):
        f = self.db.execute("SELECT COUNT(*) FROM files").fetchone()[0]
        c = self.db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        return f, c

    # --- search helpers -------------------------------------------------
    def commit(self):
        if self._dirty:
            self.db.execute("INSERT OR REPLACE INTO meta VALUES ('gen', ?)", (str(time.time_ns()),))
            self.db.commit()
            self._dirty = False
            self._secure()  # -wal/-shm may have appeared with this write

    def file_paths(self):
        return [r[0] for r in self.db.execute("SELECT path FROM files")]

    def fts_ids(self, match, limit, scope=None):
        """Best keyword hits. With `scope` (sorted chunk ids) only those chunks count toward the top `limit`.
        The ranking is the same as without a scope; the scope is applied to it, so no temp table is needed."""
        if not match:
            return []
        if scope is None:
            rows = self.db.execute(
                "SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY rank LIMIT ?", (match, limit))
            return [r[0] for r in rows]
        ranked = np.fromiter((r[0] for r in self.db.execute(
            "SELECT rowid FROM fts WHERE fts MATCH ? ORDER BY rank", (match,))), dtype=np.int64)
        return ranked[np.isin(ranked, scope, assume_unique=True)][:limit].tolist()

    def vectors(self):
        """(chunk ids ascending, float32 matrix) for all chunks. Reused until the index changes, and
        then rebuilt at most once per VEC_REFRESH_SECONDS: a snapshot is consistent, only a little stale."""
        gen = self.get_meta("gen")
        key = str(self.path)
        hit = _VEC_CACHE.get(key)
        if hit and (hit[0] == gen or time.monotonic() - hit[3] < VEC_REFRESH_SECONDS):
            return hit[1], hit[2]
        rows = self.db.execute("SELECT id, vec FROM chunks WHERE vec IS NOT NULL ORDER BY id").fetchall()
        if not rows:
            return np.zeros(0, dtype=np.int64), np.zeros((0, 0), dtype=np.float32)
        ids = np.array([r[0] for r in rows], dtype=np.int64)
        mat = np.frombuffer(b"".join(r[1] for r in rows), dtype=np.float32).reshape(len(rows), -1)
        # shortcut: brute-force cosine over all chunks held in RAM; fine to ~100k chunks, then add an ANN index (e.g. sqlite-vec or hnswlib)
        _VEC_CACHE[key] = (gen, ids, mat, time.monotonic())
        return ids, mat

    def chunk_info(self, ids):
        if not ids:
            return {}
        q = ",".join("?" * len(ids))
        rows = self.db.execute(
            f"SELECT c.id, f.path, c.start, c.end, c.text FROM chunks c "
            f"JOIN files f ON f.id=c.file_id WHERE c.id IN ({q})", ids).fetchall()
        return {r[0]: {"path": r[1], "start": r[2], "end": r[3], "text": r[4]} for r in rows}
