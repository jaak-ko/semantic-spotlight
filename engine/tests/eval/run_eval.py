"""Parallel FI/EN retrieval eval. Usage:
  .venv/bin/python engine/tests/eval/run_eval.py [--model M] [--no-stem] [--json]
  .venv/bin/python engine/tests/eval/run_eval.py --sweep      # similarity floor sweep incl. off-topic queries
Builds a throwaway index over tests/eval/docs and reports MRR and recall@5 per bucket."""
import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).parent
# Same default as the test suite: the project-local models folder, never the user's ~/.semsearch.
os.environ.setdefault("SEMSEARCH_MODELS", str(HERE.parents[1] / "dist" / "models"))
sys.path.insert(0, str(HERE))
from queries import JUNK, QUERIES  # noqa: E402

DOCS = HERE / "docs"
BUCKETS = {"FI": lambda x: x["kind"] == "mono" and x["lang"] == "fi",
           "EN": lambda x: x["kind"] == "mono" and x["lang"] == "en",
           "XL fi->en": lambda x: x["kind"] == "xl" and x["lang"] == "fi",
           "XL en->fi": lambda x: x["kind"] == "xl" and x["lang"] == "en",
           "ID": lambda x: x["kind"] == "id",
           "NAME": lambda x: x["kind"] == "name"}


class _Index:
    """A throwaway index over the eval documents; one build serves many query configurations."""

    def __init__(self, model, stemming=True):
        from semsearch import config, indexer
        from semsearch.embed import Embedder
        from semsearch.store import Store
        self.cfg = dict(config.DEFAULTS)
        self.cfg.update(model=model, stemming=stemming)
        self.emb = Embedder(model, config.models_dir())
        self._td = tempfile.TemporaryDirectory()
        self.store = Store(Path(self._td.name) / "eval.db")
        self.store.add_folder(str(DOCS))
        indexer.sync(self.store, self.emb, self.cfg, [str(DOCS)], log=lambda m: None)

    def run(self, items, min_similarity=None):
        from semsearch.search import query
        cfg = dict(self.cfg)
        if min_similarity is not None:
            cfg["min_similarity"] = min_similarity
        return [query(self.store, self.emb, q if isinstance(q, str) else q["q"], 10, cfg) for q in items]

    def close(self):
        self.store.db.close()
        self._td.cleanup()


def _metrics(rows):
    out = {}
    for name, pred in BUCKETS.items():
        sel = [r for r in rows if pred(r)]
        out[name] = {"n": len(sel),
                     "mrr": round(sum(1 / r["rank"] for r in sel if r["rank"]) / len(sel), 3),
                     "recall5": round(sum(1 for r in sel if r["rank"] and r["rank"] <= 5) / len(sel), 3)}
    out["mono FI-EN gap"] = {
        "mrr": round(out["FI"]["mrr"] - out["EN"]["mrr"], 3),
        "recall5": round(out["FI"]["recall5"] - out["EN"]["recall5"], 3)}
    return out


def _rank_rows(index, min_similarity=None):
    results = index.run(QUERIES, min_similarity)
    rows = []
    for item, res in zip(QUERIES, results):
        names = [os.path.basename(r["path"]) for r in res]
        rank = names.index(item["rel"]) + 1 if item["rel"] in names else None
        sim = res[names.index(item["rel"])]["similarity"] if rank else None
        rows.append({**item, "rank": rank, "sim": sim})
    return rows


def evaluate(model, stemming=True, min_similarity=None) -> dict:
    idx = _Index(model, stemming)
    try:
        rows = _rank_rows(idx, min_similarity)
        junk = idx.run(JUNK, min_similarity)  # off-topic queries must return nothing at the floor in use
        return {"model": model, "stemming": stemming,
                "min_similarity": idx.cfg["min_similarity"] if min_similarity is None else min_similarity,
                "buckets": _metrics(rows),
                "junk_queries_with_hits": sum(1 for r in junk if r),
                "misses": [(r["q"], r["rel"], r["rank"]) for r in rows if not r["rank"] or r["rank"] > 5]}
    finally:
        idx.close()


def sweep(model, floors) -> dict:
    """For each similarity floor: relevant recall@5 per bucket and how much off-topic noise remains."""
    idx = _Index(model)
    try:
        base = _rank_rows(idx, 0.0)
        rel_sims = sorted(r["sim"] for r in base if r["sim"] is not None and r["kind"] != "id")
        junk_top = sorted(res[0]["similarity"] for res in idx.run(JUNK, 0.0) if res)
        table = []
        for f in floors:
            rows = _rank_rows(idx, f)
            m = _metrics(rows)
            junk_res = idx.run(JUNK, f)
            table.append({"floor": round(f, 3),
                          "FI": m["FI"]["recall5"], "EN": m["EN"]["recall5"],
                          "XL": round((m["XL fi->en"]["recall5"] + m["XL en->fi"]["recall5"]) / 2, 3),
                          "ID": m["ID"]["recall5"],
                          "junk_queries_with_hits": sum(1 for r in junk_res if r),
                          "junk_hits": sum(len(r) for r in junk_res)})
        return {"rel_sim_min": rel_sims[0], "rel_sim_median": rel_sims[len(rel_sims) // 2],
                "junk_top_max": junk_top[-1], "junk_top_median": junk_top[len(junk_top) // 2],
                "table": table}
    finally:
        idx.close()


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="intfloat/multilingual-e5-small")
    p.add_argument("--no-stem", action="store_true", help="disable Finnish stemming")
    p.add_argument("--json", action="store_true")
    p.add_argument("--sweep", action="store_true", help="similarity floor sweep")
    a = p.parse_args(argv)
    if a.sweep:
        floors = [round(0.70 + 0.01 * i, 2) for i in range(21)]
        r = sweep(a.model, floors)
        print(json.dumps(r, ensure_ascii=False, indent=1) if a.json else
              f"relevant sim min={r['rel_sim_min']} median={r['rel_sim_median']}; "
              f"off-topic top sim max={r['junk_top_max']} median={r['junk_top_median']}")
        if not a.json:
            print(" floor   FI    EN    XL    ID    junk_queries  junk_hits")
            for t in r["table"]:
                print(f" {t['floor']:.2f}  {t['FI']:.2f}  {t['EN']:.2f}  {t['XL']:.2f}  {t['ID']:.2f}"
                      f"  {t['junk_queries_with_hits']:>5}/{len(JUNK)}  {t['junk_hits']:>8}")
        return 0
    r = evaluate(a.model, stemming=not a.no_stem)
    if a.json:
        print(json.dumps(r, ensure_ascii=False, indent=1))
    else:
        print(f"model={a.model} stemming={not a.no_stem} min_similarity={r['min_similarity']}")
        for k, v in r["buckets"].items():
            print(f"  {k:16s} " + "  ".join(f"{kk}={vv}" for kk, vv in v.items()))
        print(f"  off-topic queries with hits: {r['junk_queries_with_hits']}/{len(JUNK)}")
        print("  misses (query, relevant doc, rank):")
        for q, rel, rank in r["misses"]:
            print(f"    {q!r} -> {rel} rank={rank}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
