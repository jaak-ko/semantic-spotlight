import argparse
import json
import os
import shutil
import socket
import sys
import time
from pathlib import Path

from . import config, events, indexer, modelfiles
from .store import Store, read_folder_stats, read_partial, read_summary, index_path


WRITES = {"add", "index", "remove", "daemon", "fetch-model"}  # commands that create the engine home


def _caches_under_home():
    """Point the caches of the libraries we load at folders inside the engine home: one root to uninstall.
    Only once the home exists, so a read-only command never creates it."""
    root = config.home()
    if root.is_dir():
        for var, sub in (("HF_HOME", "hf"), ("TORCH_HOME", "torch"), ("SENTENCE_TRANSFORMERS_HOME", "st"),
                         ("XDG_CACHE_HOME", "cache"), ("TMPDIR", "tmp")):
            (root / sub).mkdir(exist_ok=True)
            os.environ[var] = str(root / sub)
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"  # for child processes; this one has already imported what it needs


def _embedder(cfg):
    from .embed import Embedder  # imported lazily: keeps `status` fast
    return Embedder(cfg["model"], config.models_dir())


def cmd_add(a):
    cfg = config.load()
    folder = os.path.abspath(os.path.expanduser(a.folder))
    if not os.path.isdir(folder):
        print(f"not a folder: {folder}", file=sys.stderr)
        return 1
    with Store() as s:
        s.add_folder(folder)
        s.commit()
        events.write("info", "folder_added", folders=len(s.folders()))
    return _index(cfg, [folder], trigger="add")


def cmd_index(a):
    return _index(config.load(), None)


def _index(cfg, folders, trigger="manual"):
    emb = _embedder(cfg)
    with Store() as s:
        t0 = time.time()
        st = indexer.sync(s, emb, cfg, folders, log=lambda m: print(m, file=sys.stderr), trigger=trigger)
        f, c = s.counts()
    secs = time.time() - t0
    rate = (f"{st['files_embedded'] / st['seconds']:.1f} files/s, "
            f"{st['chunks_embedded'] / st['seconds']:.1f} chunks/s") if st["seconds"] and st["chunks_embedded"] else ""
    print(f"scanned {st['files_scanned']}, hashed {st['files_hashed']}, "
          f"embedded {st['files_embedded']} files / {st['chunks_embedded']} chunks, "
          f"removed {st['files_removed']} in {secs:.1f}s {rate}")
    print(f"index: {f} files, {c} chunks")
    if st.get("memory_limit"):
        print("stopped at the memory limit after a commit: run `semsearch index` again to continue", file=sys.stderr)
        return 75  # EX_TEMPFAIL, as the daemon uses for its restart
    return 0


def cmd_query(a):
    from .search import query
    cfg = config.load()
    emb = _embedder(cfg)
    folders = None if not a.folder else [os.path.abspath(os.path.expanduser(f)) for f in a.folder]
    results = []
    if index_path().exists():  # no index yet: no results, and nothing is created
        with Store() as s:
            results = query(s, emb, a.text, a.n, folders=folders)
    if a.json:
        print(json.dumps({"ok": True, "results": results}, ensure_ascii=False))
    else:
        for r in results:
            print(f"{r['score']:.3f}  {r['path']}\n       {r['snippet'][:160]}")
    return 0


def _daemon_status(root):
    """The running daemon's status response, or None when no daemon answers."""
    sock = root / "daemon.sock"
    if not sock.exists():
        return None
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(5)
            s.connect(str(sock))
            s.sendall(b'{"cmd": "status"}\n')
            data = b""
            while not data.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                data += chunk
        return json.loads(data)
    except (OSError, ValueError):
        return None


def cmd_status(a):
    cfg = config.load()
    f, c, folders = read_summary()  # reads only: a status check never creates the home or the index
    model = cfg["model"]
    if index_path().exists():
        with Store() as s:
            model = s.get_meta("model") or model
    modelfiles.verify_install(cfg["model"])  # a one-shot command checks an unmarked install now (a few seconds once)
    st = {"ok": True, "files": f, "chunks": c, "folders": folders, "model": model,
          "model_ready": modelfiles.model_ready(cfg["model"]), "model_verifying": modelfiles.model_verifying(cfg["model"])}
    st["folder_stats"] = read_folder_stats()
    st["files_partial"] = read_partial()  # files indexed only partly (max_chunks_per_file)
    live = _daemon_status(config.home())
    if live and live.get("ok") and "progress" in live:
        st["progress"] = live["progress"]  # only when a daemon answered: counts, waiting_cloud, per-folder counts
    if a.json:
        print(json.dumps(st, ensure_ascii=False))
    else:
        print(f"model: {st['model']} ({'ready' if st['model_ready'] else 'NOT INSTALLED: run semsearch fetch-model'})\n"
              f"files: {f}\nchunks: {c}\nfolders: {', '.join(st['folders']) or '-'}")
    return 0


def cmd_fetch_model(a):
    return modelfiles.run_fetch_cli(a.model or config.load()["model"])


def _stop_daemon(root):
    sock = root / "daemon.sock"
    if not sock.exists():
        return
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(5)
            s.connect(str(sock))
            s.sendall(b'{"cmd": "shutdown"}\n')
            s.recv(4096)
    except OSError:
        return  # stale socket: no daemon to stop
    for _ in range(100):
        if not sock.exists():
            return
        time.sleep(0.1)


ENGINE_FILES = {"config.json", "daemon.sock", "daemon.lock", "events.lock", "daemon.running", "models", "hf", "torch",
                "st", "cache", "tmp", "app-daemon.log"}  # what the engine creates in its home; index.db* and events.jsonl* by prefix


def cmd_log(a):
    for rec in events.read(days=a.days):
        if a.json:
            print(json.dumps(rec, ensure_ascii=False))
        else:
            head = " ".join(str(rec.get(k, "")) for k in ("ts", "level", "event"))
            rest = " ".join(f"{k}={v}" for k, v in rec.items() if k not in ("ts", "level", "event"))
            print(f"{head} {rest}".rstrip())
    return 0


def cmd_uninstall(a):
    root = config.home()
    if root in (Path.home(), Path("/")):
        print(f"refusing to remove {root}", file=sys.stderr)
        return 1
    if not root.exists():
        print(f"nothing to remove: {root} does not exist")
        return 0
    foreign = sorted(p.name for p in root.iterdir()
                     if p.name not in ENGINE_FILES and not p.name.startswith(("index.db", "events.jsonl")))
    if foreign:  # a folder that is not only ours is never removed
        print(f"refusing to remove {root}: it also holds files the engine did not create: {', '.join(foreign)}",
              file=sys.stderr)
        return 1
    if not a.yes:
        print(f"would remove {root} with:")
        for p in sorted(root.iterdir()):
            print(f"  {p.name}")
        print("also remove by hand (macOS creates these, shared with other apps): see engine/UNINSTALL_INVENTORY.md")
        print("run `semsearch uninstall --yes` to remove the folder above")
        return 0
    _stop_daemon(root)
    shutil.rmtree(root)
    print(f"removed {root}")
    return 0


def cmd_remove(a):
    folder = os.path.abspath(os.path.expanduser(a.folder))
    with Store() as s:
        s.remove_folder(folder)
        events.write("info", "folder_removed", folders=len(s.folders()))
    print(f"removed {folder}")
    return 0


def cmd_daemon(a):
    from .daemon import run
    return run()


def main(argv=None):
    p = argparse.ArgumentParser(prog="semsearch", description="Offline semantic file search")
    sub = p.add_subparsers(dest="cmd", required=True)

    x = sub.add_parser("add", help="register a folder and index it")
    x.add_argument("folder")
    x.set_defaults(fn=cmd_add)

    sub.add_parser("index", help="re-index all registered folders").set_defaults(fn=cmd_index)

    x = sub.add_parser("query", help="search")
    x.add_argument("text")
    x.add_argument("-n", type=int, default=10)
    x.add_argument("--folder", action="append", metavar="PATH",
                   help="search only this registered folder (repeatable); default: all folders")
    x.add_argument("--json", action="store_true")
    x.set_defaults(fn=cmd_query)

    x = sub.add_parser("status", help="show index stats")
    x.add_argument("--json", action="store_true")
    x.set_defaults(fn=cmd_status)

    x = sub.add_parser("remove", help="unregister a folder and drop its files")
    x.add_argument("folder")
    x.set_defaults(fn=cmd_remove)

    sub.add_parser("daemon", help="serve over ~/.semsearch/daemon.sock").set_defaults(fn=cmd_daemon)

    x = sub.add_parser("fetch-model", help="download the embedding model (the only network use)")
    x.add_argument("--model", default=None)
    x.set_defaults(fn=cmd_fetch_model)

    x = sub.add_parser("log", help="print the retained event log (sanitized, newest last)")
    x.add_argument("--days", type=float, help="only events from the last N days")
    x.add_argument("--json", action="store_true")
    x.set_defaults(fn=cmd_log)

    x = sub.add_parser("uninstall", help="remove everything the engine created under its home")
    x.add_argument("--yes", action="store_true", help="remove it (default: list it)")
    x.set_defaults(fn=cmd_uninstall)

    a = p.parse_args(argv)
    if a.cmd in WRITES:
        config.ensure_home()
        events.enable()
    _caches_under_home()
    # Everything except fetch-model runs fully offline.
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    if a.cmd == "fetch-model":
        os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"  # keep stdout pure JSON
    else:
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
    try:
        return a.fn(a)
    except modelfiles.ModelMissing as e:
        print(f"error: {e}", file=sys.stderr)
        return 3
