import os
import re
import time
from collections import defaultdict

import numpy as np

from . import config, events
from .textnorm import stem, tokens

RRF_K = 60
POOL = 100  # candidates taken from each ranker before fusion
# Exact-looking terms (ERR-40417, NIK-7731, 2026): a keyword hit containing one is never dropped by the floor.
EXACT = re.compile(r"[A-Za-z]*\d[A-Za-z0-9]*(?:[-_][A-Za-z0-9]+)*|[A-Za-z]+[-_][A-Za-z0-9]+")
QUOTED = re.compile(r'"([^"]+)"')
NAME_CAP = 8  # a single query word is a name match only while at most this many file NAMES hold it
PREFIX_MIN = 2  # the last word of a query may be unfinished ("thomas sow"); shorter fragments are not prefixes


def _name_words(path):
    return tokens(os.path.splitext(os.path.basename(path))[0])


def _name_has(path, word, prefix, norm):
    """Whether a name token of `path` is `word` (after stemming), or starts with it when `prefix` is set."""
    w = norm(word)
    return any(norm(t) == w or (prefix and t.startswith(word)) for t in _name_words(path))


def _name_hit(store, path, words, phrases, cfg, prefix=False, cache=None):
    """True when the file NAME holds the whole query: a quoted phrase, or every word of 2+ letters, the last one
    possibly unfinished (`prefix`). One word alone also needs to be in at most NAME_CAP names, so the word "notes"
    does not pull in every file named "Notes ..." while a first name held by a few files is found."""
    name = os.path.splitext(os.path.basename(path))[0].lower()
    if any(p in name for p in phrases):
        return True
    norm = stem if cfg.get("stemming") else (lambda w: w)
    names = _name_words(path)
    have = {norm(t) for t in names}
    last = len(words) - 1

    def holds(i, w):
        return norm(w) in have or (prefix and i == last and any(t.startswith(w) for t in names))

    if not words or not all(holds(i, w) for i, w in enumerate(words)):
        return False
    if len(words) > 1:
        return True
    key = (words[0], prefix)
    if cache is None:
        cache = {}
    if key not in cache:
        cache[key] = sum(1 for p in store.file_paths() if _name_has(p, words[0], prefix, norm))
    return cache[key] <= NAME_CAP


def _match(terms, prefix_word):
    """FTS5 expression: the terms as alternatives, and the unfinished last word as a prefix ("sow"*)."""
    m = _or_match(terms)
    if prefix_word:
        p = '"' + prefix_word.replace('"', '""') + '"*'
        m = f"{m} OR {p}" if m else p
    return m


def _or_match(terms):
    seen, out = set(), []
    for t in terms:
        if t and t not in seen:
            seen.add(t)
            out.append('"' + t.replace('"', '""') + '"')
    return " OR ".join(out)


def _snippet(text, terms, width=300):
    low = text.lower()
    hits = [low.find(t.lower()) for t in terms if t and low.find(t.lower()) >= 0]
    centre = min(hits) if hits else 0
    a = max(0, centre - 100)
    return " ".join(text[a:a + width].split())


NAME_FLOOR = 0.83  # a file's name vector must be at least this close to the query to count as a name hit


def _common_name_word(store, word, prefix, norm) -> bool:
    """A single query word held by more than NAME_CAP file names is generic: it is not a name hit."""
    return sum(1 for p in store.file_paths() if _name_has(p, word, prefix, norm)) > NAME_CAP


def _name_ranking(store, nfids, nmat, qv, toks, prefix, scope, cfg):
    """Files whose NAME vector is close to the query, best first, as their first chunk ids (the third list in
    the fusion, and exempt from the chunk floor). A single common word is not used: 'notes' is not a name hit
    for every 'Notes NN' file."""
    if qv is None or not len(nfids):
        return [], set()
    sims = nmat @ qv
    floor = float(cfg.get("name_min_similarity", NAME_FLOOR))
    order = np.argsort(-sims)[:POOL]
    chosen = [int(nfids[i]) for i in order if sims[i] >= floor]
    words = [t for t in toks if len(t) >= 2]
    if not chosen or (len(words) == 1 and _common_name_word(
            store, words[0], prefix, stem if cfg.get("stemming") else (lambda w: w))):
        return [], set()
    first = store.first_chunks(chosen)
    cids = [first[f] for f in chosen if f in first]
    if scope is not None:
        inside = set(int(c) for c in scope)
        cids = [c for c in cids if c in inside]
    return cids, set(cids)


def _sim(ids, sims, cid):
    """Cosine of chunk `cid` in this snapshot. 0.0 when it has no vector here: it was indexed after the snapshot."""
    if sims is None:
        return 0.0
    pos = int(np.searchsorted(ids, cid))
    return float(sims[pos]) if pos < len(ids) and ids[pos] == cid else 0.0


SLOW_MS = 1000  # a query slower than this is logged as search_slow


def query(store, emb, text: str, n: int = 10, cfg=None, folders=None) -> list:
    """Runs _query and logs it when it took longer than SLOW_MS (no text is logged: only its length)."""
    t0 = time.perf_counter()
    res = _query(store, emb, text, n, cfg, folders)
    ms = (time.perf_counter() - t0) * 1000
    if ms > SLOW_MS:
        events.write("warn", "search_slow", ms=round(ms), query_chars=len(text))
    return res


def _query(store, emb, text: str, n: int = 10, cfg=None, folders=None) -> list:
    """Hybrid search: vector cosine, BM25 (over Finnish stems) fused by reciprocal rank, aggregated
    per file. `score` is 1.0 when a chunk ranks first in both lists. `similarity` is the raw cosine
    of the file's best chunk. Chunks below `min_similarity` are dropped unless they are keyword hits
    that contain an exact-looking term of the query."""
    cfg = cfg or config.DEFAULTS
    toks = tokens(text)
    terms = toks + ([stem(t) for t in toks] if cfg.get("stemming") else [])
    exact = [t.lower() for t in EXACT.findall(text) if len(t) >= 3]
    # The folder scope is applied before ranking, so the top n come only from the chosen folders.
    scope = None if folders is None else store.folder_chunk_ids(folders)
    if scope is not None and not len(scope):
        return []
    ids, mat = store.vectors()
    nfids, nmat = store.name_vectors()
    sims = None
    vec_ids = []
    qv = emb.embed([text], "query")[0] if (len(ids) or len(nfids)) else None
    if len(ids):
        sims = mat @ qv
        cand = np.arange(len(ids))
        if scope is not None:
            pos = np.searchsorted(ids, scope)
            inside = pos < len(ids)
            pos, wanted = pos[inside], scope[inside]
            cand = pos[ids[pos] == wanted]  # row numbers of the scoped chunks that have vectors
        if len(cand):
            sub = sims[cand]
            k = min(POOL, len(cand))
            top = np.argpartition(-sub, k - 1)[:k]
            vec_ids = [int(ids[cand[i]]) for i in top[np.argsort(-sub[top])]]

    # The last word is an unfinished prefix when the text does not end in a space or punctuation.
    prefix_word = toks[-1] if toks and re.search(r"[^\W_]$", text) and len(toks[-1]) >= PREFIX_MIN else None
    kw_ids = store.fts_ids(_match(terms, prefix_word), POOL, scope=scope)
    name_ids, name_set = _name_ranking(store, nfids, nmat, qv, toks, prefix_word, scope, cfg)
    scores = defaultdict(float)
    for ranking in (vec_ids, kw_ids, name_ids):
        for r, cid in enumerate(ranking):
            scores[cid] += 1.0 / (RRF_K + r + 1)
    norm = 2.0 / (RRF_K + 1)

    ordered = sorted(scores.items(), key=lambda kv: -kv[1])
    info = store.chunk_info([cid for cid, _ in ordered])
    floor = float(cfg.get("min_similarity", 0.0))
    kw_set = set(kw_ids)
    words = [t for t in toks if len(t) >= 2]
    phrases = [p.lower() for p in QUOTED.findall(text)]
    named = {}  # path -> whether its name holds the query (checked once per file)
    name_counts = {}  # shared by the files of this query: how many names hold a word
    results, seen = [], set()
    for cid, s in ordered:
        c = info.get(cid)
        if c is None or c["path"] in seen:
            continue  # first chunk per file is its best one
        sim = _sim(ids, sims, cid)
        if sim < floor and cid not in name_set and not (cid in kw_set and any(t in c["text"].lower() for t in exact)):
            if cid not in kw_set:
                continue
            if c["path"] not in named:
                named[c["path"]] = _name_hit(store, c["path"], words, phrases, cfg,
                                             prefix=prefix_word is not None, cache=name_counts)
            if not named[c["path"]]:
                continue
        seen.add(c["path"])
        results.append({"path": c["path"], "score": round(s / norm, 4), "similarity": round(sim, 4),
                        "snippet": _snippet(c["text"], toks), "start": c["start"], "end": c["end"]})
        if len(results) == n:
            break
    return results
