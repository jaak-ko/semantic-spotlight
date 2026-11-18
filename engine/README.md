# semsearch engine

Offline semantic file search: indexer, hybrid search (vectors + Finnish-stemmed BM25), CLI and a Unix-socket daemon.
Index: `~/.semsearch/index.db`. Models: `~/.semsearch/models`. Socket: `~/.semsearch/daemon.sock` (0600).

## Commands

| Command | Network | Notes |
|---|---|---|
| `semsearch fetch-model` | **yes, the only one** | downloads `intfloat/multilingual-e5-small` (~493 MB), verifies it, prints JSON progress |
| `semsearch status [--json]` | no | includes `model_ready` and `model_verifying` |
| `semsearch add <folder>` / `index` / `remove <folder>` | no | exit 3 with a message if the model is not installed |
| `semsearch query "<text>" [-n N] [--json]` | no | exit 3 with a message if the model is not installed |
| `semsearch daemon` | no | model loaded once; starts without a model and reports `model_ready: false` |
| `semsearch log [--days N] [--json]` | no | prints the retained event log (below), oldest first; nothing else. Creates nothing |
| `semsearch uninstall [--yes]` | no | lists, then removes, the whole engine home (`~/.semsearch`); stops a running daemon first. Refuses (exit 1, names the files) when the home holds anything the engine did not create |

Every command except `fetch-model` sets `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1` and `HF_HUB_DISABLE_TELEMETRY=1`.

## `fetch-model` contract

One JSON object per line on stdout. Nothing else goes to stdout; diagnostics go to stderr.

```
{"event": "progress", "done": 0, "total": 492795290, "speed": 0}
{"event": "progress", "done": 257474490, "total": 492795290, "speed": 11725380}
{"event": "progress", "done": 492795290, "total": 492795290, "speed": 0}
{"event": "done"}
```

- `done` and `total` are bytes. `total` is the sum of the files to download. A progress event comes each time the byte count changed, at most every 100 ms.
- `speed` is bytes per second, averaged over about the last second (0 at the start and at the end). The app can interpolate between events with it.
- Success ends with `{"event": "done"}` and exit code 0.
- Cancel: SIGTERM (or SIGINT) stops the download. The last line is `{"event": "cancelled", "done": N, "total": M}` (the last progress seen) and the exit code is 130, within about a second. Partial files stay on disk, so the next run resumes from them. `model_ready()` stays false until the download is complete and every file passed its check: a cancelled run never counts as installed.
- Transient network failures (SSL/EOF, connection reset or timeout, HTTP 429 and 5xx) are retried transparently: up to 5 attempts, with backoff of 0.5, 1, 2 and 4 seconds. Before each retry the command prints `{"event": "retry", "attempt": n, "max": 5}`, where `n` is the attempt about to start (2 to 5). Partial files stay on disk, so each attempt resumes. Unknown events can be ignored.
- Failure ends with `{"event": "error", "message": "<friendly text>", "detail": "<ExceptionType>: <technical text>"}` and exit code 1. `message` is what the app shows. `detail` is for a "Show details" control or logs. Examples of `message`:
  - "Couldn't reach huggingface.co. Check your internet connection and try again." (transient, after 5 attempts)
  - "Not enough disk space to download the model. Free some space and try again." (disk full)
  - "The model could not be found on huggingface.co. Try again later, or update Semantic Spotlight." (HTTP 401, 403, 404)
  - "The download was interrupted and could not be verified. Try again." (size or sha256 mismatch, or missing file)
- Not retried: HTTP 401, 403, 404, disk full, and checksum or size mismatch. They fail at once.
- Re-running is idempotent and resumes partial downloads. The download is verified afterwards: file sizes match the Hub metadata, and sha256 matches for LFS files. Only then is the `verified` marker written in the model folder, and `model_ready()` requires it. Installs made before the marker existed are checked by the engine itself, offline (see below), and marked then.
- Only `intfloat/multilingual-e5-small` is supported by `fetch-model` (`--model` for others returns an error event).

Daemon: `{"cmd":"status"}` returns `model_ready` and `model_verifying`. Queries, `index` and `add` without a model return `{"ok": false, "error": "... run `semsearch fetch-model`"}`.

## Packaging a relocatable runtime

```bash
engine/package_runtime.sh          # writes engine/dist/runtime (arm64 macOS)
engine/dist/runtime/bin/semsearch status
```

- Downloads python-build-standalone 3.12.16 (release 20261026, asset sha256 pinned in the script) and reuses the tarball in `engine/dist/cache` on rebuilds.
- Installs the hash-pinned set in `engine/runtime-requirements.txt` with `pip install --require-hashes --no-deps --only-binary=:all:`. Every package and version is pinned with sha256 hashes for arm64 macOS, cp312. `torch==2.6.0`, `sentence-transformers==3.3.1`, `numpy==1.26.4` and `snowballstemmer==3.1.1` are the direct requirements. `hf-xet` is deliberately not in the set: `huggingface_hub` runs without it, and xet downloads are disabled in code.
- The launcher `bin/semsearch` runs the bundled interpreter with `-I`, so it ignores the environment, user site-packages and the current directory. It works from any path with no `.venv` and no system Python.
- Size: about 514 MB uncompressed (about 144 MB as `.tgz`), down from about 719 MB. Stripped: test suites, `include/` headers, the stdlib test and tkinter packages (and Tcl/Tk), pip and setuptools, `protoc`, Cython sources, text console scripts. Debug symbols are stripped from every `.so`/`.dylib` with `strip -x`, and each file is signed again (about 80 MB). Bytecode (`.pyc`) is compiled for the modules a model load imports; the rest (about 105 MB) is dropped, and a module without a `.pyc` still imports from its `.py` (it is compiled in memory on each start).
- The launcher passes `-B` as well as the environment variable: under `-I` the variable is ignored, so `-B` is what keeps the signed bundle free of new `.pyc` files.
- `engine/tools/verify_runtime.sh` runs at the end of the build (skip with `SEMSEARCH_SKIP_VERIFY=1`) and fails loudly: code signatures, no user name or checkout path in the runtime (upstream CI paths such as `/Users/runner` are allowed by name), loaded modules have bytecode, a model on MPS, a CPU embed and a forced CPU fallback, every top-level module of the dependencies imports, a module without bytecode still imports, the no-model error path, OCR, the full test suite on the runtime, CLI add/index/query, the daemon over its socket, and fetch-model with no model offline.

Only the build script uses the network. The Python tarball is sha256-checked and every wheel is hash-pinned, so a changed upstream file fails the build.

## Tests

```bash
.venv/bin/python -m pytest engine/tests -q        # 95 tests, ~70 s
# Tests and the eval read the model from engine/dist/models (git-ignored) and never touch ~/.semsearch.
# Fill it once, with a temp engine home:
SEMSEARCH_HOME=$(mktemp -d) SEMSEARCH_MODELS=$PWD/engine/dist/models .venv/bin/semsearch fetch-model
.venv/bin/python engine/tests/eval/run_eval.py    # FI/EN retrieval eval
```

Model choice and the eval numbers: [MODEL_CHOICE.md](MODEL_CHOICE.md).

## Query results (protocol)

`{"cmd":"query","q":str,"n":int}` returns `{"ok":true,"results":[...]}`. Each result has:

- `path` (str), `snippet` (str), `start` / `end` (int): the file's best chunk and its character offsets.
- `score` (float): reciprocal-rank fusion of vector and keyword lists. 1.0 means first in both. Kept for compatibility.
- `similarity` (float): raw cosine between the query and that best chunk (about 0.78 to 0.91 for real matches).

Results below `min_similarity` (config, default 0.81) are dropped. Keyword hits that contain an exact-looking
term of the query (for example `ERR-40417`) are kept regardless, so codes are always found.

File names are searched as well as content. The name (without its extension) is added to the keyword text of
the first chunk of the file, Finnish-stemmed like the content, so `Thomas Sowell` finds `Thomas Sowell, sosiaalinen
oikeudenmukaisuus.txt` even when the text never says the name. The name also keeps a result above the floor when
it holds the whole query: every word of 2 or more letters is in the name, or a quoted phrase is. A single word
must also be in at most 8 file names, so a common word such as `notes` (in 20 names) does not pull in every
file named "Notes ...", while a first name held by a few files is found. The count is over file names, not
contents: about nine files named after the same first name stop the single-word rule, while a multi-word query
still finds them. The last word of a query may be unfinished, as the search box sends it while you type: `thomas sow`
and `poliittinen meta kar` match as prefixes, in the keyword index and in the name rule. A single letter is not a
prefix. Two-letter fragments such as `xy` or `ko` cannot flood the results: a single word needs to be in at most 8
names, and keyword hits below the floor are dropped. A file with no text (an empty file, an image without OCR text) gets one empty chunk with a
zero vector, so its name is still found. Folder names are not searched. The vector of a chunk is still the text
alone: prefixing the file name to the embedded text was tried and returned hits for 3 of 10 off-topic queries, so
it was not kept. Words are split at underscores, hyphens, dots and spaces, so `poliittinen_meta_kartta.txt` is found by `poliittinen meta kartta`. Schema version 5 rebuilds existing indexes once.

## Index safety and settings

- `~/.semsearch` is created at mode 0700 by the first write (`index`, `add`, `daemon`, `fetch-model`), and `index.db` (with `-wal`/`-shm`) is 0600. Lookups and read-only commands (`status`, `query`) never create anything.
- An unreadable, dangling or outside-folder file is logged and skipped. Its existing rows are left alone. Each skip message is printed once per process, so a daemon does not repeat it on every run.
- A folder removed during an index run is not indexed any further: the insert checks the folder is still registered in the same statement, so no file of it is left behind.
- Queries read a snapshot of the vectors. It is rebuilt at most every 5 seconds while the index changes, so a file indexed a moment ago can take up to 5 seconds to appear in results.
- The model lock is taken per slice of 32 texts, so a query waits for one slice, not for a whole large file.
- One daemon per home: a `daemon.lock` file is held with `flock` for the process lifetime. A second `semsearch daemon` exits with "daemon already running".
- After a full sync (no `--folder`, all folders), OCR results whose image is gone or outside every registered folder are dropped from `ocr_cache`.
- `config.json` that is not valid JSON, or not an object, gives a warning on stderr and uses defaults. The file is never overwritten.
- Index requests are queued. One worker runs at a time and drains the queue, so a folder added during an index run is indexed too.
- The index is committed every 50 files or every 5 seconds. A crash loses at most that batch, which is re-indexed next run.
- An index is rebuilt automatically when the model, the pinned revision, the schema version or the stemming setting changes.

## Protocol limits

- A request is one JSON line, at most 1 MiB. A longer line gets `{"ok": false, "error": "request too large"}` and the connection is closed.
- `n` is clamped to 1..50 for `query`.
- `{"cmd": "shutdown"}` stops the daemon cleanly (the socket is removed). `semsearch uninstall` uses it.
- A `query` without `q` gets `{"ok": false, "error": "query needs the search text in q"}`.

## Searching chosen folders

`{"cmd": "query", "q": str, "n": int, "folders": [abs path, ...]}`: `folders` is optional.

- Omitted or `null`: search every registered folder.
- `[]`: no folders, so the result list is empty (not an error).
- Paths are matched exactly against the registered folders. A path that is not registered (or does not exist) is ignored; if none are left, the result is empty. `/a/foo` never matches `/a/foobar`.
- The scope is applied before ranking, so the top `n` come only from the chosen folders. `min_similarity` and the exact-ID rule (a keyword hit containing a code such as `ERR-40417` is always kept) still apply inside the scope.
- A non-list `folders` value (other than null) is a request error.
- The CLI: `semsearch query "<text>" --folder PATH` (repeatable). No `--folder`: all folders.

Speed: the chunk ids of each folder are cached per index generation, so toggling folders in the UI does not re-scan the index. Measured with `engine/tools/bench_scope.py` (warm, median per query, including the query embedding):

- 464 chunks, real model: about 20 to 25 ms per query with or without a scope (the query embedding dominates).
- 50,000 chunks (synthetic vectors): about 1.8 ms with no scope, 3.0 to 3.9 ms with one or two of four folders. Table in `MODEL_CHOICE.md`, section "Folder scope".

## Per-folder counts (`status`)

`folder_stats` in the daemon `status` response, and in `semsearch status --json`: `[{"path": str, "files": int}]`, one entry per registered folder, counting the files under that folder. Folders can overlap, so the counts are per folder and do not add up to `files`. No file names.

## Index progress (`status`)

`{"cmd": "status"}` returns, among the other fields:

```
"indexing": true,
"progress": {"phase": "indexing", "done": 12, "total": 40}
```

- `phase` is `"idle"`, `"scanning"` or `"indexing"`. `indexing` is always `phase != "idle"`, read from the same snapshot.
- `scanning`: the folders are being walked and compared by mtime and size. `total` is 0 until the scan finishes.
- `indexing`: `total` is the number of files that need work in this run: new or changed files (images needing OCR included) plus files to remove. Unchanged files are not counted. `done` goes up by one after each counted file is handled, whether it was indexed, skipped (unreadable, oversized, outside the folder) or removed. So `done <= total` always.
- Requests queued while a run is going are merged into the same session: `total` grows, `done` never goes back. When nothing is left, `phase` returns to `"idle"` with `done == total`; the last values stay until the next run starts.
- A folder whose run fails drops its unrun items from `total`, so the bar still reaches `done == total` for the work that ran. Later folders in the queue run and add their own work.
- Only counts are sent: never file names or paths.
- `semsearch status --json` adds the same `progress` object when a daemon answers, and nothing when none does.

## Where things live, and uninstalling

Everything the engine writes lives under its home, `~/.semsearch` (or `SEMSEARCH_HOME`): the index, models, socket, and the caches of the libraries it loads (`hf/`, `torch/`, `st/`, `cache/`, `tmp/`). Only two things are written outside it, both by macOS and not by the engine: Metal shader caches under `/var/folders/…/C`, written when the model runs on the GPU (MPS), and MPSGraph temp files under `/var/folders/…/T`. Environment variables cannot redirect them. The full, measured list is in [UNINSTALL_INVENTORY.md](UNINSTALL_INVENTORY.md). `semsearch uninstall` lists the home folder and removes it with `--yes`. It removes only a home that holds the engine's own files (`index.db*`, `config.json`, `daemon.sock`, `daemon.lock`, `models`, `hf`, `torch`, `st`, `cache`, `tmp`, `app-daemon.log`); anything else in it makes it refuse, with the names.

## Images (OCR)

Images are searched by the text inside them: screenshots, scans, photos of documents.

- Supported: `.png .jpg .jpeg .heic .tiff .gif .bmp .webp` (whatever ImageIO decodes). Size cap `max_image_bytes`, default 25 MB.
- Text comes from Apple's Vision framework through a small Swift helper, `engine/ocr/ocr.swift`. It runs on-device with no network and no Python dependencies.
- Languages: `ocr_languages`, default `["sv-SE", "en-US"]`. Vision has no Finnish. Swedish covers ä, ö and å, and the measured Finnish results are in `MODEL_CHOICE.md`.
- Images with fewer than 10 recognised characters (photos, icons) keep no text: they get one empty chunk, so they are found by their file name only, never by content. Costs: one chunk row and a zero vector of 1,536 bytes per such image, about 1.5 MB per 1,000 photos. The OCR result is cached by content hash (plus the language list), so unchanged, touched or renamed images are never re-OCRed. Files the helper cannot decode (corrupt or zero-byte) are cached as "no text" and not retried. Each entry remembers the path the image was last seen at; entries of images that are gone are pruned after a full sync (indexes written before this change have no path yet, so their entries go on the first full sync, and those images are re-OCRed only if they change).
- Helper location: `<runtime>/bin/ocr-helper` in the packaged runtime. In development, `engine/dist/ocr` is built with `swiftc -O` on first use. If no helper is available, images are skipped and one warning is logged per sync. Text files are unaffected.
- Changing `ocr_languages` rebuilds the index (it is part of the index signature). The cache is kept, so the rebuild does not re-run OCR.

Limits: printed text only (no handwriting), very small text (roughly under 12 px) reads poorly, and the language coverage is Vision's (no Finnish model).

## Model install check (no network)

An install is ready when its `verified` marker holds the pinned revision and its files are linked. The marker is written by `fetch-model` after its size and SHA-256 checks, or by the engine's offline check of an install that has none (from before the marker, or cut short). That check needs no hash list: in the Hugging Face cache the blob's file name is its content hash (64 hex = sha256 for LFS files, 40 hex = git blob sha1 for small files). Every file the patterns match must link to a finished blob whose bytes hash to its name. A corrupt or truncated file fails, and no marker is written. A marked install is not hashed again.

- `semsearch status` (CLI) and the embedder check an unmarked install synchronously, once per process. A few seconds on a 470 MB model.
- The daemon checks it in a worker thread at start, and `model_ready` also starts that check lazily on its first question. Until the check finishes, status reports `model_ready: false` and `model_verifying: true`. The app should show "checking", not the download button, while `model_verifying` is true.
- `index` and `add` re-check an install that is not marked (synchronously, so the reply waits for it). A marked install returns at once.
- The check never touches the network.

## Event log (`events.jsonl`)

For support reports: what happened over weeks (indexing trouble, restarts, crashes). File `~/.semsearch/events.jsonl` (mode 0600, UTF-8), one JSON object per line:

```
{"ts":"2026-11-18T13:11:05+02:00","level":"info","event":"index_start","run":"3f9a0c21","trigger":"manual","folders":2}
```

- `ts` is ISO 8601 with the local offset. `level` is `info`, `warn` or `error`. `run` is 8 hex digits, one per process (daemon or command), so one daemon's lines can be told apart from the next one's.
- Events: `daemon_start` (pid, version, model_ready, previous_run_clean), `daemon_stop` (reason: `shutdown` or `signal`), `model_verified` (source: `check` or `fetch`), `model_missing` (reason: `absent` or `unverified`), `index_start` (trigger: `manual`, `watch`, `startup` or `add`; folders: count), `index_end` (files_scanned, files_embedded, files_removed, chunks, seconds, errors: count, top_errors: `[{class, count}]`), `index_error` (class, message, folder_index: the folder's position in the registered list, -1 for all folders or none), `schema_rebuild` (from, to, reason: `schema` or `settings`), `folder_added` / `folder_removed` (folders: count after), `search_slow` (ms, query_chars; only over 1000 ms), `uncaught_exception` (class, message, stack: function names only).
- A `watch` trigger is sent when an `index` request carries `"trigger": "watch"` (any other value counts as `manual`). Nothing sends `startup` yet.
- Privacy, enforced in the writer: no file names, paths, folder names, queries, contents or e-mail addresses. Every string is sanitized: e-mail addresses become `<email>`, path-like tokens (anything with a slash, `~/`, `C:\`) become `<path>`, quoted names become `<text>`, and text is cut to 200 characters. Messages from the OS use the error text without the path. Only counts and error classes are kept.
- `index_error` is logged for at most 50 files per run; `index_end` carries the full count.
- Rotation at 512 KB: `events.jsonl.1` … `.7` are kept (8 files). Rotated files not written for 60 days are deleted at each daemon start and at each rotation.
- Writers are serialized by `events.lock` (one `flock` per line, so the daemon and a CLI command can both write). A write never raises into the caller; a failed write is dropped.
- A daemon that ends without `daemon_stop` leaves `daemon.running` behind. The next start logs `previous_run_clean: false`. A daemon that ends in an uncaught exception is reported by `uncaught_exception` and stays unclean.
- Only the write commands and the daemon log (`status`, `query` and `log` never write). `semsearch uninstall` removes all of these files.

## Memory

- On MPS (Apple GPU) PyTorch keeps one compiled graph per tensor shape in host memory. Sentence-transformers pads each batch to its own longest text, so every batch had a new shape and resident memory grew with the corpus (measured: 15.9 GB peak indexing 4,650 mixed files; 4.3 GB after 440 files). The embedder now pads the length to fixed buckets (64, 128, 256, 384, 512 tokens) and the rows to 16, so only a few shapes exist. The embeddings are the same as before (checked: identical).
- Safety net: indexing checks resident memory at every commit. The limit depends on this Mac and the model: 25% of physical RAM (`sysctl hw.memsize`), between 2 GB and 6 GB, plus what the model keeps resident (e5-small +0, e5-base +1 GB, bge-m3 +2 GB), and never more than half the RAM. On a 16 GB Mac: 4 GB for e5-small, 6 GB for bge-m3. Above the limit the run stops after that commit (nothing half-written, the rest waits for the next run); the daemon then exits with code 75 and logs `memory_restart`. `semsearch index` returns 75 in the same case. `status` reports `rss_limit_mb`.
- `status` reports `rss_mb` (the daemon's resident memory). The event log has `rss_mb` at `daemon_start` and `index_start`, and `rss_mb` and `peak_rss_mb` (the highest value sampled at the run's commits) at `index_end`.
- `engine/tools/memory_bench.py` indexes a generated mixed corpus (text, RTF, PNG with text) in a temp home and fails when the peak exceeds the bound, which defaults to this Mac's limit for the model. `--quick` is a smaller run.

## iCloud files and progress

- Files that are only in iCloud (macOS `st_flags` has `SF_DATALESS`) are found by the stat alone: an unchanged one is never read, so nothing is downloaded for it. A changed or new one is a cloud item. Local files are indexed first; the cloud items are read ahead on 4 threads (at most 8 read ahead, read-only), so downloads overlap embedding. A download that fails or takes more than 300 s is a skipped file with its error class in `index_error`/`index_end`; the run goes on. Downloads already running at the end of a run cannot be stopped, so a hung download can delay the daemon's exit.
- `status` (daemon) returns `progress` as `{"phase", "done", "total", "waiting_cloud", "folders": [{"path", "done", "total", "phase"}]}`. `phase` per folder is `scanning`, `indexing` or `done`; `waiting_cloud` is the number of cloud-only files of the run not yet downloaded. The run-level `phase`, `done` and `total` are unchanged. The folder paths are for the app only: they are never in the event log or diagnostics.
- `index_end` carries `seconds_scan`, `seconds_read` (reading and decoding, without OCR), `seconds_embed`, `seconds_ocr`, `files_cloud_only`, `files_prefetched`, `slowest_file_seconds` (one file's time, a number only) and `files_per_minute` (files embedded per minute of the run).
- Adding a folder while a run is going joins the same session: the new folder gets its own entry, and the first folder's unchanged files are not read again.

## Huge and data-like files

- A file is indexed up to `max_chunks_per_file` chunks (default 150, about 60k tokens or 240 KB of prose). The rest of a huge file is not embedded; its first chunks and its file name are. Measured: prose files have a median of 9 chunks and a 90th percentile of 29; a 1 MB CSV, JSON or log dump gives 1,500 to 1,900 chunks, so the cap matters only for those.
- A file is data-like when, in its first 64 KB, letters and prose punctuation are under 60% of the non-space characters, or a line is longer than 4000 characters (minified JSON, one-line dumps). Data-like files get the same cap and are counted.
- The cap is never silent: `status` reports `files_partial` (files indexed only partly, persisted per file), and `index_end` in the event log reports `files_truncated` and `files_data_like` for the run.
- Changing `max_chunks_per_file` takes effect for files indexed after the change; re-index to apply it to files already indexed. Schema 6 (this version) rebuilds the index once.
