"""Compare embedding models on the test corpus. Usage: python compare_models.py MODEL [MODEL...]
Prints rank of the expected file per query and index/query timings. Writes nothing into the real index."""
import json
import os
import sys
import time
from pathlib import Path

from semsearch import config, indexer, search
from semsearch.embed import Embedder
from semsearch.store import Store

CORPUS = Path(__file__).parent / "corpus"
QUERIES = [  # (query, expected file)
    ("notes about the municipality data pipeline migration", "en_municipal_pipeline_migration.md"),
    ("kunnan datankäsittelyn siirtosuunnitelma", "fi_kunnan_datan_siirto.md"),
    ("which log shows the disk is full", "sync_error_log.log"),
    ("ERR-40417", "sync_error_log.log"),
    ("mikä on kardemummapullan resepti", "pulla_resepti.md"),
    ("where should I hike in Lapland with a tent", "hiking_lapland.md"),
]


def run(model):
    cfg = config.load()
    cfg["model"] = model
    scratch = Path(os.environ.get("SCRATCH", "/tmp")) / ("cmp_" + model.replace("/", "_") + ".db")
    if scratch.exists():
        scratch.unlink()
    t0 = time.time()
    emb = Embedder(model, config.models_dir())
    load_s = time.time() - t0
    with Store(scratch) as s:
        s.add_folder(str(CORPUS))
        st = indexer.sync(s, emb, cfg, [str(CORPUS)], log=lambda m: None)
    rows, lat = [], []
    for q, want in QUERIES:
        t = time.time()
        with Store(scratch) as s:
            res = search.query(s, emb, q, 10)
        lat.append(time.time() - t)
        paths = [Path(r["path"]).name for r in res]
        rank = paths.index(want) + 1 if want in paths else None
        rows.append({"query": q, "expected": want, "rank": rank, "top1": paths[0]})
    mrr = sum((1 / r["rank"]) if r["rank"] else 0 for r in rows) / len(rows)
    out = {"model": model, "dim": emb.model.get_sentence_embedding_dimension(),
           "device": str(emb.model.device), "load_s": round(load_s, 1),
           "index_s": st["seconds"], "chunks": st["chunks_embedded"],
           "chunks_per_s": round(st["chunks_embedded"] / st["seconds"], 2),
           "query_ms_avg": round(1000 * sum(lat) / len(lat), 1),
           "mrr": round(mrr, 3), "top1": sum(r["rank"] == 1 for r in rows), "rows": rows}
    print(json.dumps(out, ensure_ascii=False, indent=1))
    return out


if __name__ == "__main__":
    os.environ["SEMSEARCH_DOWNLOAD"] = "1"  # comparison may download the candidate model
    results = [run(m) for m in sys.argv[1:]]
    Path(os.environ.get("SCRATCH", "/tmp")).joinpath("compare_results.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=1))
