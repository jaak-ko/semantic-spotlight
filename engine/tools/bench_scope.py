"""Query latency with and without a folder scope.

  .venv/bin/python engine/tools/bench_scope.py real        # ~464 chunks, real model (needs engine/dist/models)
  .venv/bin/python engine/tools/bench_scope.py synthetic   # 50k chunks with random vectors and text

Uses a temp engine home and temp folders only.
"""
import os
import random
import statistics
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
os.environ.setdefault("SEMSEARCH_MODELS", str(HERE.parent / "dist" / "models"))
os.environ["SEMSEARCH_HOME"] = tempfile.mkdtemp(prefix="bench-", dir="/tmp") + "/home"


def median_ms(fn, runs=20):
    fn()  # warm: first call builds the vector and scope caches
    t = []
    for _ in range(runs):
        a = time.perf_counter()
        fn()
        t.append((time.perf_counter() - a) * 1000)
    return statistics.median(t), max(t)


def report(store, emb, folders, label):
    from semsearch import config
    from semsearch.search import query
    cfg = config.load()
    qs = ["kalastusreissu järvelle verkot", "lasten unirytmi iltarutiini", "sähkölasku eräpäivä"]
    cases = [("no scope", None), ("1 of 4 folders", folders[:1]), ("2 of 4 folders", folders[:2])]
    for name, scope in cases:
        med, worst = median_ms(lambda: [query(store, emb, q, 10, cfg, scope) for q in qs])
        print(f"  {name:16s} median {med / len(qs):7.1f} ms/query  (worst run {worst / len(qs):.1f} ms/query)")


def real():
    from semsearch import config, indexer
    from semsearch.embed import Embedder
    from semsearch.store import Store
    topics = ["kalastusreissu järvelle verkot", "lasten unirytmi iltarutiini", "sähkölasku eräpäivä",
              "kardemummapullan resepti", "nivelreuman lääkitys", "auton katsastus jarrupalat"]
    root = Path(tempfile.mkdtemp(prefix="benchreal-", dir="/tmp"))
    folders = []
    for f in range(4):
        d = root / f"folder{f}"
        d.mkdir()
        folders.append(d)
        for i in range(116):  # 4 x 116 = 464 files, one chunk each
            t = topics[(i + f) % len(topics)]
            (d / f"note{i:03d}.md").write_text(f"Muistio {f}-{i}: {t}. Lisätietoja ja muistiinpanoja numero {i}.\n")
    emb = Embedder(config.DEFAULTS["model"], config.models_dir())
    with Store() as s:
        for d in folders:
            s.add_folder(str(d))
        s.commit()
        t0 = time.time()
        indexer.sync(s, emb, config.load(), None, log=lambda m: None)
        print(f"indexed {s.counts()} (files, chunks) in {time.time() - t0:.1f} s")
        report(s, emb, [str(d) for d in folders], "real")


class FakeEmbedder:
    name = "fake"

    def __init__(self, rng):
        self.rng = rng

    def count(self, text):
        return 10

    def embed(self, texts, kind):
        import numpy as np
        v = np.array([[self.rng.gauss(0, 1) for _ in range(384)] for _ in texts], dtype=np.float32)
        return v / np.linalg.norm(v, axis=1, keepdims=True)


def synthetic():
    import numpy as np
    from semsearch import config
    from semsearch.store import Store
    rng = random.Random(1)
    nprng = np.random.default_rng(1)
    vocab = ["".join(rng.choice("abcdefghijklmnoprstuvyäö") for _ in range(rng.randint(4, 9))) for _ in range(20000)]
    folders = []
    root = Path(tempfile.mkdtemp(prefix="benchsyn-", dir="/tmp"))
    with Store() as s:
        for f in range(4):
            folder = root / f"folder{f}"
            folder.mkdir()
            folders.append(folder)
            s.add_folder(str(folder))
            for i in range(625):  # 4 x 625 files x 20 chunks = 50,000 chunks
                fid = s.add_file(str(folder / f"doc{i:04d}.md"), 1.0, 1, f"sha{f}-{i}")
                for seq in range(20):
                    text = " ".join(rng.choice(vocab) for _ in range(60))
                    v = nprng.standard_normal(384).astype(np.float32)
                    v /= np.linalg.norm(v)
                    s.add_chunk(fid, seq, 0, len(text), text, v.tobytes(), text)
        s.commit()
        print(f"built {s.counts()} (files, chunks)")
        emb = FakeEmbedder(random.Random(2))
        report(s, emb, [str(d) for d in folders], "synthetic")
        cold = time.perf_counter()
        s.db.execute("SELECT 1")
        from semsearch import store as st_mod
        st_mod._SCOPE_CACHE.clear()
        a = time.perf_counter()
        s.folder_chunk_ids([str(folders[0])])
        print(f"  scope build for one folder, cold: {(time.perf_counter() - a) * 1000:.1f} ms")
        a = time.perf_counter()
        s.folder_chunk_ids([str(folders[0])])
        print(f"  scope lookup for one folder, warm: {(time.perf_counter() - a) * 1000:.3f} ms")


if __name__ == "__main__":
    {"real": real, "synthetic": synthetic}[sys.argv[1] if len(sys.argv) > 1 else "real"]()
