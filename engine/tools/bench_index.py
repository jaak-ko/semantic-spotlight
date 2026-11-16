"""Indexing speed and query latency on a deterministic 300-file corpus (real model, temp home only).

  .venv/bin/python engine/tools/bench_index.py            # prints files/s, chunks, query median and max

The corpus is made from the eval documents and the test corpus: file i is 2-4 paragraphs drawn with a seeded
RNG, so every run indexes the same bytes. Nothing outside a temp folder is read or written.
"""
import os
import random
import statistics
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent
os.environ.setdefault("SEMSEARCH_MODELS", str(ENGINE / "dist" / "models"))
os.environ["SEMSEARCH_HOME"] = tempfile.mkdtemp(prefix="bench-", dir="/tmp") + "/home"
sys.path.insert(0, str(ENGINE))

N_FILES = 300
QUERIES = ["kardemummapullan resepti", "nivelreuman lääkitys", "how to bake cardamom buns",
           "rocket launch schedule", "Sowell", "IMG_1723", "vesivahingon korvaus", "tulvariski kaupungissa"]


def _paragraphs():
    out = []
    for src in list((ENGINE / "tests" / "eval" / "docs").glob("*.txt")) + \
            [p for p in (ENGINE / "tests" / "corpus").iterdir() if p.is_file() and p.suffix in {".txt", ".md"}]:
        out += [p for p in src.read_text(errors="ignore").split("\n\n") if p.strip()]
    return out


def make_corpus(root: Path):
    rng = random.Random(7)
    paras = _paragraphs()
    root.mkdir(parents=True)
    for i in range(N_FILES):
        body = "\n\n".join(rng.choice(paras) for _ in range(rng.randint(2, 4)))
        (root / f"doc_{i:03d}.txt").write_text(body + "\n", encoding="utf-8")


def median_ms(fn, runs=20):
    fn()  # warm: first call builds the vector and scope caches
    t = []
    for _ in range(runs):
        a = time.perf_counter()
        fn()
        t.append((time.perf_counter() - a) * 1000)
    return statistics.median(t), max(t)


def main():
    from semsearch import config, indexer
    from semsearch.embed import Embedder
    from semsearch.search import query
    from semsearch.store import Store

    corpus = Path(tempfile.mkdtemp(prefix="benchc-", dir="/tmp")) / "corpus"
    make_corpus(corpus)
    cfg = config.load()
    emb = Embedder(cfg["model"], config.models_dir())
    with Store() as s:
        s.add_folder(str(corpus))
        t0 = time.perf_counter()
        indexer.sync(s, emb, cfg, [str(corpus)], log=lambda m: None)
        secs = time.perf_counter() - t0
    with Store() as s:
        files, chunks = s.counts()
    print(f"index: {files} files in {secs:.1f} s = {files / secs:.1f} files/s, {chunks} chunks")
    with Store() as s:
        meds = [median_ms(lambda q=q: query(s, emb, q, 10, cfg)) for q in QUERIES]
    print(f"query: median {statistics.median(m for m, _ in meds):.1f} ms, worst {max(x for _, x in meds):.1f} ms "
          f"over {len(QUERIES)} queries")


if __name__ == "__main__":
    main()
