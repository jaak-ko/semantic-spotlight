import fcntl
import json
import os
import signal
import socket
import socketserver
import sys
import threading

from . import config, events, indexer, modelfiles
from .store import Store, index_path, read_folder_stats, read_partial, read_summary

TRIGGERS = ("manual", "watch", "startup")  # what asked for an index run (`index` requests may say which)
STOP_REASON = "shutdown"  # daemon_stop reason: "signal" when SIGTERM or SIGINT stops the daemon


MAX_REQUEST = 1 << 20  # bytes per request line; a longer line is rejected and the connection closed
SERVER = None          # set by run(); the shutdown command stops it


def _clamp_n(n) -> int:
    return max(1, min(50, int(n)))


def _folders_arg(v):
    """None (search everything) or a list of folder paths. Anything else is a request error."""
    if v is None:
        return None
    if not isinstance(v, list):
        raise ValueError("folders must be a list of paths, or null")
    return [os.path.abspath(os.path.expanduser(str(x))) for x in v]


class Daemon:
    def __init__(self):
        self.cfg = config.load()
        self.emb = None  # kept warm once loaded; loads lazily if the model is installed later
        self.progress = indexer.Progress()  # counts only; the app reads it through `status`
        self._lock = threading.Lock()   # guards _pending, _running and the progress session
        self._pending = []              # index requests waiting for the worker; None = all folders
        self._running = False

    @property
    def indexing(self) -> bool:
        return self.progress.snapshot()["phase"] != "idle"

    def embedder(self):
        if self.emb is None:
            from .embed import Embedder
            self.emb = Embedder(self.cfg["model"], config.models_dir())  # raises ModelMissing if not installed
        return self.emb

    def dispatch(self, req: dict) -> dict:
        cmd = req.get("cmd")
        if cmd == "ping":
            return {"ok": True}
        if cmd == "query":
            if "q" not in req:
                return {"ok": False, "error": "query needs the search text in q"}
            from .search import query
            emb = self.embedder()
            folders = _folders_arg(req.get("folders"))
            if not index_path().exists():  # no index yet: no results, and nothing is created
                return {"ok": True, "results": []}
            with Store() as s:
                return {"ok": True, "results": query(s, emb, str(req["q"]), _clamp_n(req.get("n", 10)),
                                                     self.cfg, folders)}
        if cmd == "status":
            prog = self.progress.status()  # one read: `indexing` and `progress` always agree (folders: paths, app only)
            f, c, folders = read_summary()
            return {"ok": True, "files": f, "chunks": c, "folders": folders,
                    "folder_stats": read_folder_stats(),
                    "indexing": prog["phase"] != "idle", "progress": prog, "files_partial": read_partial(), "rebuilding": indexer.is_rebuilding(), "rss_limit_mb": indexer.rss_limit_mb(self.cfg["model"]),
                    "model": self.cfg["model"],
                    "model_ready": modelfiles.model_ready(self.cfg["model"]), "rss_mb": indexer.rss_mb(),
                    "model_verifying": modelfiles.model_verifying(self.cfg["model"])}
        if cmd == "index":
            modelfiles.verify_install(self.cfg["model"], force=True)  # an unmarked install is checked now, not cached
            self.embedder()
            self._start_index(None, req.get("trigger") if req.get("trigger") in TRIGGERS else "manual")
            return {"ok": True}
        if cmd == "add":
            path = os.path.abspath(os.path.expanduser(str(req["path"])))
            if not os.path.isdir(path):
                return {"ok": False, "error": f"not a folder: {path}"}
            modelfiles.verify_install(self.cfg["model"], force=True)
            self.embedder()
            with Store() as s:
                s.add_folder(path)
                s.commit()
                events.write("info", "folder_added", folders=len(s.folders()))
            self._start_index([path], "add")
            return {"ok": True}
        if cmd == "shutdown":
            threading.Thread(target=SERVER.shutdown, daemon=True).start()  # serve_forever must stop off its own thread
            return {"ok": True}
        if cmd == "remove":
            path = os.path.abspath(os.path.expanduser(str(req["path"])))
            with Store() as s:
                s.remove_folder(path)
                events.write("info", "folder_removed", folders=len(s.folders()))
            return {"ok": True}
        return {"ok": False, "error": f"unknown cmd: {cmd!r}"}

    def _start_index(self, folders, trigger="manual"):
        """Queue an index request. One worker thread drains the queue, so requests that arrive
        while it runs are never lost and two workers never run at once."""
        with self._lock:
            self._pending.append((folders, trigger))
            if self._running:
                return  # the running worker picks this up before it exits
            self._running = True
            self.progress.start_session()
        threading.Thread(target=self._worker, daemon=True).start()

    def _worker(self):
        while True:
            with self._lock:
                if not self._pending:
                    self._running = False
                    self.progress.end_session()
                    return
                batch, self._pending = self._pending, []
            for folders, trigger in batch:
                try:
                    with Store() as s:
                        st = indexer.sync(s, self.embedder(), self.cfg, folders,
                                          log=lambda m: print(m, file=sys.stderr, flush=True),
                                          progress=self.progress, trigger=trigger)
                    if st.get("memory_limit"):
                        _restart("memory")  # what was committed stays; the next run continues
                        return
                except Exception as e:  # keep the daemon alive; report on stderr
                    print(f"index failed: {e}", file=sys.stderr, flush=True)
                    self.progress.abandon()  # this folder's unrun items leave the total; the next folder still runs


DAEMON: Daemon | None = None
EXIT_RESTART = 75  # EX_TEMPFAIL: the daemon stopped to free memory; the app relaunches it
EXIT_CODE = 0  # what run() returns; EXIT_RESTART after a memory restart


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        while True:  # one request line -> one response line
            line = self.rfile.readline(MAX_REQUEST + 1)  # bounded read: a huge line cannot exhaust memory
            if not line:
                return
            if len(line) > MAX_REQUEST:
                self._send({"ok": False, "error": "request too large"})
                return
            try:
                resp = DAEMON.dispatch(json.loads(line))
            except modelfiles.ModelMissing as e:
                resp = {"ok": False, "error": f"{e}"}
            except Exception as e:
                resp = {"ok": False, "error": str(e)}
            self._send(resp)

    def _send(self, resp):
        self.wfile.write((json.dumps(resp, ensure_ascii=False) + "\n").encode())


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def _sock_path():
    return str(config.home() / "daemon.sock")


def _alive(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
        return True
    except OSError:
        return False
    finally:
        s.close()


LOCK_FD = None  # held for the process lifetime; the OS releases the lock when the daemon exits


def _signal_stop(server):
    global STOP_REASON
    STOP_REASON = "signal"
    threading.Thread(target=server.shutdown).start()  # shutdown() must run off the serving thread


def _restart(reason):
    global STOP_REASON, EXIT_CODE
    STOP_REASON, EXIT_CODE = reason, EXIT_RESTART
    events.write("warn", "memory_restart", rss_mb=indexer.rss_mb(), limit_mb=indexer.rss_limit_mb(config.load()["model"]))
    threading.Thread(target=SERVER.shutdown, daemon=True).start()


def run():
    global DAEMON, SERVER, LOCK_FD
    config.ensure_home()  # the socket lives in the home
    # One daemon per home. Checked under a lock, so two starts cannot both unlink a stale socket.
    LOCK_FD = os.open(config.home() / "daemon.lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(LOCK_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("daemon already running", file=sys.stderr)
        return 1
    path = _sock_path()
    if len(path.encode()) >= 104:  # macOS limit for AF_UNIX paths
        print(f"socket path too long ({len(path)} chars): {path}; set SEMSEARCH_HOME to a shorter path", file=sys.stderr)
        return 1
    if os.path.exists(path):
        if _alive(path):
            print("daemon already running", file=sys.stderr)
            return 1
        os.unlink(path)  # stale socket from a crashed run

    previous_clean = events.mark_running()  # False: the last daemon never reached daemon_stop
    events.install_excepthooks()
    events.prune()
    DAEMON = Daemon()
    events.write("info", "daemon_start", pid=os.getpid(), version=events.engine_version(), rss_mb=indexer.rss_mb(),
                 model_ready=modelfiles.model_ready(DAEMON.cfg["model"]), previous_run_clean=previous_clean)
    modelfiles.start_verify(DAEMON.cfg["model"])  # an unmarked install is checked off the start path
    if not modelfiles.model_verifying(DAEMON.cfg["model"]):
        try:
            DAEMON.embedder()  # warm start
        except modelfiles.ModelMissing as e:
            print(f"warning: {e}; starting without a model", file=sys.stderr, flush=True)
    old = os.umask(0o177)  # socket is created 0600
    try:
        server = Server(path, Handler)
    finally:
        os.umask(old)
    SERVER = server

    # shutdown() must run off the serving thread, so the signal handler spawns it.
    signal.signal(signal.SIGTERM, lambda *_: _signal_stop(server))
    signal.signal(signal.SIGINT, lambda *_: _signal_stop(server))
    print(f"semsearch daemon listening on {path}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        if os.path.exists(path):
            os.unlink(path)
    events.write("info", "daemon_stop", reason=STOP_REASON)  # an exception above leaves the marker: unclean
    events.clear_running()
    return EXIT_CODE
