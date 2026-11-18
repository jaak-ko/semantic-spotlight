<p align="center"><img src="app/Resources/icon/logo.png" width="128" alt="Semantic Spotlight logo"></p>

<h1 align="center">Semantic Spotlight</h1>

<p align="center"><b>Private, on-device semantic search for the files on your Mac.</b><br>
Describe what you are looking for. Find the file, even when you do not remember its name.</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-blue">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green">
</p>

<p align="center"><a href="https://github.com/jaak-ko/semantic-spotlight/releases/latest"><b>Download for macOS</b></a></p>

---

## Overview

Semantic Spotlight is a menu-bar app with a global search panel (**Option+Space**). It
indexes the folders you choose and ranks files by meaning, by exact terms, and by file
name. Searching for "the municipality data pipeline migration" finds the note even when it
is saved as `notes_final_v3.md` and never uses those words.

Everything runs locally. There is no account, no cloud service and no telemetry. Files are
read and never modified, and their contents never leave the machine. The only network
request the product makes is a one-time download of the language model, which starts only
when you click the button for it.

## Features

- **Semantic search in Finnish and English.** Queries are matched against file content by
  meaning. Finnish text is stemmed, so `kardemummapullan` finds `kardemummapulla`.
- **Exact-term search.** Hybrid ranking combines vector similarity with SQLite FTS5
  keyword search (reciprocal rank fusion), so identifiers and error codes such as
  `ERR-40417` are found reliably.
- **File-name search.** Names are indexed too. `Thomas Sowell` finds
  `Thomas Sowell, sosiaalinen oikeudenmukaisuus.txt`, and the last word may be unfinished
  (`thomas sow`).
- **Image text (OCR).** Screenshots, scans and photos of documents are searched by the text
  inside them, using the Vision framework built into macOS. Images without text are found
  by file name only.
- **No false confidence.** Results below a similarity threshold are dropped, so a query
  with no real match returns nothing instead of weak guesses.
- **Always current.** The app watches your folders and re-indexes changes. Unchanged files
  are skipped using modification time and a content hash; deleted files are removed.
- **Keyboard first.** Open, reveal in Finder and Quick Look without leaving the keyboard.

### Supported content

| Type | Extensions |
| --- | --- |
| Text and code | `.txt` `.md` `.rst` `.rtf` `.csv` `.json` `.log` and common source files |
| Images (OCR) | `.png` `.jpg` `.jpeg` `.heic` `.tiff` `.gif` `.bmp` `.webp` |

`.git`, `node_modules`, virtual environments, hidden files, binaries and text files over
1 MB are skipped. PDF and DOCX are not supported yet.

Finnish is not on Vision's official language list, so the engine reads Finnish images with
the Swedish model, which covers `ä` and `ö`. On the project's test images this gave 1.00
character accuracy on clean text and 0.99 on a blurred phone-style photo. Handwriting and
very small print have not been tested.

## Install

**Requirements:** Apple Silicon Mac, macOS 14 or later.

1. Download `SemanticSpotlight.dmg` from the [latest release](https://github.com/jaak-ko/semantic-spotlight/releases/latest).
2. Drag **Semantic Spotlight** to **Applications**.
3. Right-click the app, choose **Open**, and confirm once. The app is ad-hoc signed and not
   notarized, so macOS asks before trusting it the first time.
4. In the welcome window, click **Download language model** (about 470 MB, once), choose a
   folder, and wait for indexing to finish.

Press **Option+Space** from anywhere to search. Folders and launch at login
are managed in **Settings**.

| Key | Action |
| --- | --- |
| Up / Down | Move through results |
| Return | Open the file |
| Cmd+Return | Reveal in Finder |
| Tab, then Space | Quick Look preview |
| Esc | Dismiss |

## Privacy and security

- **Local only.** The index, the model and all caches live under `~/.semsearch`. The
  folder is `0700` and the index file is `0600`.
- **No network port.** The search engine runs as a daemon on a Unix socket that only your
  user can reach.
- **One network use.** The model download from huggingface.co, started by you. Every other
  command sets the offline flags of the underlying libraries.
- **Verified model.** The download is checked against the Hub's file sizes and SHA-256
  hashes before the model is used.
- **Diagnostics are opt-in and redacted.** **Settings → Advanced → Copy diagnostics…** produces
  text with no file names, queries or contents for you to review. Nothing is sent
  automatically.

## Uninstall

**Settings → Advanced → Uninstall** lists exactly what will be removed, with sizes: the
index, the downloaded model, preferences, caches (including GPU shader caches macOS
created for the app), the login item, and the app itself. Your own files and folders are
never touched. Afterwards every path is re-checked, and anything that could not be removed
is listed with instructions (see
[app/README.md](app/README.md#what-the-uninstall-does-not-remove)). The result can be
copied or saved as a redacted report.

From source, `semsearch uninstall --yes` removes everything under `~/.semsearch`. The full
inventory of files the product creates is in
[engine/UNINSTALL_INVENTORY.md](engine/UNINSTALL_INVENTORY.md).

## How it works

```
 Menu-bar app (SwiftUI)  --Unix socket-->  Python daemon  -->  ~/.semsearch/
  Option+Space panel       newline JSON     model kept warm      index.db (SQLite)
  FSEvents folder watch                     hybrid search        config.json, models/
```

- **Embeddings:** `intfloat/multilingual-e5-small` through sentence-transformers, on the
  Apple GPU (MPS) with a CPU fallback. Chunks are about 400 tokens with 60 tokens of
  overlap.
- **Storage:** one SQLite file holds chunks, vectors (float32 blobs) and an FTS5 index.
  Vector search is exact cosine similarity in NumPy, which is comfortable up to roughly
  100,000 chunks. Beyond that, an approximate-nearest-neighbour index can replace it; the
  place is marked in the code.
- **Ranking:** vector and keyword rankings are fused with reciprocal rank fusion, then
  aggregated per file. A similarity floor drops weak matches, with exemptions for
  exact-identifier hits and file-name hits.
- **App:** a SwiftUI menu-bar app that owns the UI, folder watching and the daemon's
  lifecycle. The bundled Python runtime is self-contained and relocatable.

Further reading: [engine/README.md](engine/README.md) (CLI, daemon protocol, packaging),
[app/README.md](app/README.md) (app architecture, build, tests) and
[engine/MODEL_CHOICE.md](engine/MODEL_CHOICE.md) (model comparison and numbers).

## Performance and evaluation

Measured on an Apple Silicon MacBook (48 GB) with small corpora:

| Measure | Result |
| --- | --- |
| Indexing | about 25 chunks per second on a 300-file generated corpus (`engine/tools/bench_index.py`, measured 23 to 26); chunks per second, not files, because files differ in size |
| Query latency | median about 22 ms in-process; about 3 s from a cold command line (model load) |
| Retrieval quality | 1.00 MRR and recall@5 for both Finnish and English on a 63-document, 64-query set |
| Exact identifiers | found every time |
| File-name queries | 4 of 4 |
| Off-topic queries | 0 of 10 returned results |

The evaluation set is small and was written together with the engine, and the similarity
threshold was tuned on it. Treat it as a regression suite rather than a benchmark of
real-world quality: notes with slang, abbreviations and mixed languages will be harder. If
a relevant result is missing, the threshold is the first thing to check.

## Known limitations

- **Same-language search.** An English query will not reliably find a Finnish file, or the
  reverse. The index does not translate.
- **No PDF or DOCX** yet, and no search by what a photo shows (OCR reads text only).
- **Apple Silicon and macOS 14 or later** only.
- **Not notarized**, hence the one-time right-click on first launch.

## Development

Requires an Apple Silicon Mac, Python 3.12+ and the Xcode Command Line Tools.

```bash
python3 -m venv .venv
.venv/bin/pip install -e engine
.venv/bin/semsearch fetch-model        # one-time model download (about 470 MB)
```

Command-line tool:

```bash
.venv/bin/semsearch add ~/Documents/notes      # register a folder
.venv/bin/semsearch index                      # index what is new, forget what is gone
.venv/bin/semsearch query "notes about the municipality data pipeline migration"
.venv/bin/semsearch query "ERR-40417" -n 5 --json
.venv/bin/semsearch status
.venv/bin/semsearch remove ~/Documents/notes
```

Build the app and a disk image:

```bash
engine/package_runtime.sh   # self-contained Python runtime, about 514 MB unpacked, verified at the end
app/build.sh                # app/dist/SemanticSpotlight.app
app/make_dmg.sh             # app/dist/SemanticSpotlight.dmg (about 175 MB)
```

Tests:

```bash
.venv/bin/pytest engine/tests                       # engine tests, about 70 seconds
.venv/bin/python engine/tests/eval/run_eval.py      # bilingual retrieval evaluation
```

## License

MIT, see [LICENSE](LICENSE). Bundled third-party software and its licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
