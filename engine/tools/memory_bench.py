"""Memory regression benchmark: indexes a seeded mixed corpus (text, RTF, PNG with text) in a temp home with the
real model and fails when peak resident memory exceeds the bound.

  .venv/bin/python engine/tools/memory_bench.py                 # 2400 text, 800 RTF, 60 images, bound: RSS limit
  .venv/bin/python engine/tools/memory_bench.py --quick         # 300 text, 120 RTF, 20 images (about a minute)

Peak RSS is sampled with `ps` every 2 s and also taken from getrusage. The bound is the safety-net limit for this Mac. Nothing outside the temp folders is read or
written. The corpus is generated from a fixed seed, so every run indexes the same bytes.
"""
import argparse
import json
import os
import random
import shutil
import string
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENGINE = Path(next((sys.argv[i + 1] for i, x in enumerate(sys.argv[:-1]) if x == "--engine"), HERE.parent))
os.environ.setdefault("SEMSEARCH_MODELS", str(ENGINE / "dist" / "models"))
sys.path.insert(0, str(ENGINE))


def _rss_mb() -> int:
    """This process's resident memory in MB, from ps (the same measure as the daemon's status rss_mb)."""
    return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())]).strip()) // 1024


def make_corpus(root: Path, n_text: int, n_rtf: int, n_img: int) -> None:
    from PIL import Image, ImageDraw, ImageFont
    rng = random.Random(7)
    vocab = ["".join(rng.choice(string.ascii_lowercase) for _ in range(rng.randint(3, 11))) for _ in range(900)]
    vocab += ["kardemumma", "vesivahinko", "lasagne", "muistio", "sopimus", "laskutus", "kotitalous", "matka"]

    def words(n):
        return " ".join(rng.choice(vocab) for _ in range(n))

    def paragraphs(nbytes):
        parts, size = [], 0
        while size < nbytes:
            p = words(rng.randint(30, 120)).capitalize() + "."
            parts.append(p)
            size += len(p) + 2
        return "\n\n".join(parts)

    for sub in ("text", "rtf", "img"):
        (root / sub).mkdir(parents=True)
    for i in range(n_text):
        r = rng.random()  # mostly small files; a few long ones, and rarely one near the 1 MB cap
        size = rng.randint(900_000, 1_000_000) if r < 0.002 else (
            rng.randint(100_000, 900_000) if r < 0.01 else int(rng.lognormvariate(8.0, 1.0)))
        (root / "text" / f"muistio {i:05d}.txt").write_text(paragraphs(min(size, 1_000_000)), encoding="utf-8")
    for i in range(n_rtf):
        body = paragraphs(rng.randint(2_000, 40_000)).replace("\n\n", "\\par\n")
        (root / "rtf" / f"kirje {i:05d}.rtf").write_text("{\\rtf1\\ansi\\deff0 " + body + "}", encoding="utf-8")
    font = ImageFont.load_default()
    for i in range(n_img):
        im = Image.new("RGB", (1200, 400), "white")
        d = ImageDraw.Draw(im)
        for line in range(8):
            d.text((20, 20 + line * 40), words(8), fill="black", font=font)
        im.save(root / "img" / f"kuva {i:04d}.png")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", type=int, default=2400)
    ap.add_argument("--rtf", type=int, default=800)
    ap.add_argument("--img", type=int, default=60)
    ap.add_argument("--bound-mb", type=int, default=None, help="default: the daemon's RSS limit for this Mac and model")
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--engine", default=str(ENGINE), help="the engine folder to measure (default: this checkout)")
    a = ap.parse_args(argv)
    if a.quick:
        a.text, a.rtf, a.img = 300, 120, 20

    work = Path(tempfile.mkdtemp(prefix="membench-", dir="/tmp"))
    os.environ["SEMSEARCH_HOME"] = str(work / "home")
    try:
        make_corpus(work / "corpus", a.text, a.rtf, a.img)
        from semsearch import config, indexer
        from semsearch.embed import Embedder
        from semsearch.store import Store

        peak, samples = [0], []
        stop = threading.Event()

        def sample():
            while not stop.is_set():
                r = _rss_mb()
                peak[0] = max(peak[0], r)
                samples.append(r)
                stop.wait(2)
        threading.Thread(target=sample, daemon=True).start()

        cfg = config.load()
        if a.bound_mb is None:
            a.bound_mb = indexer.rss_limit_mb(cfg["model"])
        emb = Embedder(cfg["model"], config.models_dir())
        folders = [str(work / "corpus" / s) for s in ("text", "rtf", "img")]
        t0 = time.time()
        with Store() as s:
            for f in folders:
                s.add_folder(f)
            s.commit()
            st = indexer.sync(s, emb, cfg, folders, log=lambda m: None)
            files, chunks = s.counts()
        secs = time.time() - t0
        stop.set()
        import resource
        peak_rusage = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // (1024 * 1024)  # bytes on macOS
        result = {"files": files, "chunks": chunks, "seconds": round(secs, 1),
                  "files_per_s": round(files / secs, 2), "peak_rss_mb": max(peak[0], peak_rusage),
                  "bound_mb": a.bound_mb, "memory_limit_hit": st.get("memory_limit", False)}
        print(json.dumps(result))
        if result["peak_rss_mb"] > a.bound_mb:
            print(f"FAIL: peak RSS {result['peak_rss_mb']} MB is over the bound of {a.bound_mb} MB", file=sys.stderr)
            return 1
        print("PASS")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
