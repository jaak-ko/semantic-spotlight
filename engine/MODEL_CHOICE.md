# Embedding model and keyword-side choices

Default: **`intfloat/multilingual-e5-small`** (384 dims, `query: ` / `passage: ` prefixes applied automatically),
with **Snowball Finnish stemming** on the keyword side (`stemming: true`).

## Finnish vs English eval (`engine/tests/eval/`)

60 documents: 20 topics each written once in Finnish and once in English, plus 10 Finnish-only and
10 English-only distractors (150-200 words each, Finnish with natural inflection and compounds).
60 queries: 20 Finnish and 20 English monolingual (relevant = same-language twin), 5 + 5 cross-lingual
(FI query → EN doc, EN query → FI doc), 10 exact codes (e.g. `PULLA-204`, `NIK-7731`).
Metrics: MRR and recall@5. Hybrid search (vector + BM25, RRF k=60). Run:
`.venv/bin/python engine/tests/eval/run_eval.py [--model M] [--no-stem] [--trigram]` (stemming is on by default).

Caveat: the eval was written by the same team as the engine, so it is small and somewhat optimistic.
The FI monolingual bucket is saturated at 1.0 after stemming, so it cannot separate further changes.

| Configuration | FI MRR / R@5 | EN MRR / R@5 | FI−EN gap (MRR / R@5) | XL FI→EN MRR / R@5 | XL EN→FI MRR / R@5 | ID R@5 |
|---|---|---|---|---|---|---|
| e5-small, no stemming (before) | 0.955 / 0.95 | 1.00 / 1.00 | −0.045 / −0.05 | 0.10 / 0.20 | 0.02 / 0.00 | 1.00 |
| e5-small + trigram only (no stem) | 0.930 / 0.95 | 1.00 / 1.00 | −0.07 / −0.05 | 0.10 / 0.20 | 0.02 / 0.00 | 1.00 |
| **e5-small + stemming (chosen)** | **1.00 / 1.00** | **1.00 / 1.00** | **0 / 0** | 0.10 / 0.20 | 0.02 / 0.00 | 1.00 |
| e5-small + stemming + trigram | 1.00 / 1.00 | 1.00 / 1.00 | 0 / 0 | 0.10 / 0.20 | 0.02 / 0.00 | 1.00 |
| bge-m3 + stemming | 1.00 / 1.00 | 1.00 / 1.00 | 0 / 0 | 0.33 / 0.80 | 0.07 / 0.20 | 1.00 |

### Keyword-side decisions

- **(a) Snowball Finnish stemming: kept, default on.** Stems are appended to the indexed text and applied to
  query tokens (`snowballstemmer` 3.1.1, pure Python). It closed the FI−EN monolingual gap (0.955 → 1.0 MRR).
  Indexing cost is within noise: 19.1 s vs 20.2 s for 300 files / 4,201 chunks.
- **(b) Trigram FTS as a third list: implemented, off by default.** It gave no gain on top of stemming and
  was slightly worse alone (0.93 MRR). It costs index size, so it is only populated when `trigram: true`.
- **(c) libvoikko: not used.** The FI monolingual bucket reached 1.0 without it, so the extra native dependency
  is not justified yet.
- Exact-ID queries stay at 1.0 recall@5 with every configuration.
- Changing the model, `stemming` or `trigram` changes the index signature, so the index rebuilds
  automatically (`indexer.index_signature`).

### Model decision

- bge-m3 ties e5-small on the primary metric (both 1.0 FI and EN monolingual, with stemming).
- bge-m3 is clearly better only on cross-lingual queries: FI→EN MRR 0.33 vs 0.10, EN→FI 0.07 vs 0.02.
  That rests on 5 queries per direction, so it is not decisive. Neither model handles EN→FI well.
- Cost of bge-m3: about 2.4x slower indexing and about 2.7x slower queries (earlier measurement: index 3.29 s vs
  1.39 s on 22 files; query 271 ms vs 103 ms), 1024-dim vectors (4x the storage and scan cost), and a 2.2 GB download
  (4.3 GB on disk with both weight formats).
- Rule applied: the default goes to the model with the better FI score and no bad EN score. FI is tied, so the
  cheaper model wins. **Switch to bge-m3** by setting `"model": "BAAI/bge-m3"` in `~/.semsearch/config.json` if
  cross-lingual search matters more than speed; the index rebuilds automatically.

### Not evaluated

- `intfloat/multilingual-e5-base`: not downloaded. Its size is about 1.1 GB (278M parameters in fp32), which is
  over the 1 GB limit for downloads other than bge-m3.

## Remaining gap

- **Cross-lingual EN→FI is poor with either model** (MRR 0.02 e5-small, 0.07 bge-m3). An English query often
  does not surface the Finnish note. The fix is probably a larger cross-lingual training set or a
  query-translation step, which is outside this change.
- The FI and EN monolingual results are equal on this eval, but the eval is small and self-written. Expect a
  gap on real Finnish notes that use more slang, abbreviations and mixed Finnish-English terms.

## Earlier measurements (22-file corpus, MPS, hybrid, before the eval set)

| | e5-small | bge-m3 |
|---|---|---|
| Vector dims | 384 | 1024 |
| Index time (22 files / 22 chunks) | 1.39 s | 3.29 s |
| Query latency, in-process, avg of 6 | 103 ms | 271 ms |
| Model on disk | 470 MB | 4.3 GB (both weight formats) |

## Audit follow-up: similarity floor, trigram removal, pinned revision

### Similarity floor (`min_similarity`, default 0.81)

Measured with `.venv/bin/python engine/tests/eval/run_eval.py --sweep` on the eval set plus 10 off-topic
queries (5 FI, 5 EN) about things the corpus does not contain (pizza, rockets, crypto mining, guitar, hockey).

- Relevant hits (monolingual and cross-lingual) have best-chunk cosine min 0.784, median 0.907.
- Off-topic queries have top cosine max 0.809, median 0.778. Keyword overlap alone does not separate them.

| floor | FI | EN | ID | XL (avg) | off-topic queries with hits (hits) |
|---|---|---|---|---|---|
| none (0.00) | 1.00 | 1.00 | 1.00 | 0.10 | 10/10 (100) |
| 0.78 | 1.00 | 1.00 | 1.00 | 0.30 | 6/10 (32) |
| 0.80 | 1.00 | 1.00 | 1.00 | 0.20 | 2/10 (3) |
| **0.81** | **1.00** | **1.00** | **1.00** | **0.30** | **0/10 (0)** |
| 0.88 | 0.95 | 0.95 | 1.00 | 0.00 | 0/10 |
| 0.90 | 0.60 | 0.80 | 1.00 | 0.00 | 0/10 |

Chosen 0.81: the lowest floor that removes all off-topic hits without losing monolingual or ID recall@5.
Above about 0.87 monolingual recall falls.

Relevant hits below 0.81: 4 of 52. Three are exact-ID hits (NIK-7731, LASKU-88213, AIKA-3307) that the
exemption keeps: a keyword hit containing an exact-looking term is never dropped. One is a cross-lingual hit
that was already at rank 9. Removing higher-ranked off-topic hits also moves cross-lingual relevant docs
into the top 5 (XL EN→FI recall@5 0.0 → 0.4).

Caveat: the floor was chosen on this 60-query eval. Real notes can score differently, so re-run the sweep if
the model or the corpus changes a lot.

### Trigram removed

The trigram FTS table was tried as a third ranking list. It added nothing on top of stemming (FI stayed at
1.0) and alone it was slightly worse (FI 0.93 MRR). It was removed (`fts_tri`, the `trigram` setting, and the
branch in `add_chunk`). Existing databases drop the leftover table on open.

### Pinned model revision

`modelfiles.REV` is pinned to the commit of the tested install, `614241f622f53c4eeff9890bdc4f31cfecc418b3`,
instead of `main`. The commit is part of the index signature, so a revision change rebuilds the index.
Existing installs have `refs/main` pointing at the same commit, so they stay ready with no download. A ref file
that says `main` is ignored for the pinned model. The embedder loads exactly the pinned snapshot.

## Images: on-device OCR (Apple Vision)

Decision: text inside images is extracted with the macOS Vision framework (`VNRecognizeTextRequest`, accurate
mode, language correction on) through the Swift helper `engine/ocr/ocr.swift`. No Python dependency, no network.

Language choice: Vision on this Mac has no Finnish model. The supported list includes `sv-SE` and `en-US` (checked
with `supportedRecognitionLanguages`). Swedish covers ä, ö and å, and the default is `["sv-SE", "en-US"]`.

Measured on the fixtures in `engine/tests/ocr_fixtures/` (ground truth in `ground_truth.json`):

| Image | Character accuracy | ä / ö / å read (truth → OCR) | Median time per image (fresh process) |
|---|---|---|---|
| English screenshot-like PNG, 3 lines | 1.000 | - | 252 ms |
| Finnish recipe PNG, 4 lines, Arial 34 px | 1.000 | ä 5 → 5, ö 1 → 1 | 319 ms |
| Finnish recipe, phone-photo style (rotated 1.5°, blurred, JPEG q50, 24 px) | 0.987 | ä 5 → 4 (one `ä` read as `ă`), ö 1 → 1 | 309 ms |
| Photo without text (JPEG) | - (no text, not indexed) | - | 149 ms |

Errors seen: `dl` read as `di`, one `ä` read as `ă`. Accuracy is measured on two of my own renders, not on
real Finnish screenshots or documents, so treat it as an upper bound for clean text and a rough guide for photos.

Not measured: the same images with `usesLanguageCorrection` off (it may change the `dl`/`di` error), other fonts
and UI screenshots, scans at low resolution, and handwriting (not supported by Vision's printed-text mode).

## Folder scope (search only chosen folders)

The scope is applied before ranking: vector candidates come only from the chosen folders' chunks, and the
keyword ranking is restricted the same way. Measured with `engine/tools/bench_scope.py`
(warm index, median per query, the 3 test queries):

| Corpus | No scope | 1 of 4 folders | 2 of 4 folders |
|---|---|---|---|
| 464 chunks, real model (query embedding included) | 24.6 ms | 24.3 ms | 20.6 ms |
| 50,000 chunks, synthetic vectors (no embedding cost) | 1.8 ms | 3.0 ms | 3.9 ms |

- The per-folder chunk id sets are cached per index generation. Building one for a 12,500-chunk folder takes about 24 ms cold; a warm lookup takes about 0.1 ms.
- An earlier version joined the scope through a temp table on every query. It cost 7 to 13 ms at 50k chunks and was replaced by ranking first and then filtering (`Store.fts_ids`).
- The embedding of the query dominates real queries, so the scope adds no visible cost there.
