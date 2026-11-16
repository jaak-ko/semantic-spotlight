<p align="center"><img src="app/Resources/icon/logo.png" width="128" alt="Semantic Spotlight logo"></p>

<h1 align="center">Semantic Spotlight</h1>

**Find your files by what they mean, not by what you named them.**

You remember writing something about "the municipality data pipeline migration". You do
not remember that the file is called `notes_final_v3_REAL.md`. Semantic Spotlight does
the remembering: press **Option+Space**, describe the thing, get the file.

It runs entirely on your Mac. No cloud, no account, no telemetry. Your files are read,
never changed, and their contents never leave the machine. (The only network request
the product ever makes is a one-time model download that you start by clicking a button.)

## What it does

- **Searches by meaning, in Finnish and English.** A query is matched against the
  *content* of your files, so it finds the note even when no words are shared.
  Finnish gets its own treatment (stemming), because `kardemummapullan` should find
  `kardemummapulla`, as any Finn would expect.
- **Still handles exact terms.** Hybrid ranking mixes vector similarity with SQLite
  FTS5 keyword search (reciprocal rank fusion), so IDs and error codes such as
  `ERR-40417` are found the boring, reliable way.
- **Finds files by name.** File names are searched too, so `Thomas Sowell` finds
  `Thomas Sowell, sosiaalinen oikeudenmukaisuus.txt` even when its text never says the name.
- **Finds half-typed names.** The last word may be unfinished: `thomas sow` finds the file while you type.
- **Knows when it has nothing.** Results below a similarity floor are dropped, so a
  query about lasagna in a folder of tax notes returns nothing instead of eight
  confident guesses.
- **Stays current.** Re-indexing skips unchanged files (mtime and content hash) and
  removes deleted ones. The app watches your folders and updates on its own.
- **Reads** `.txt .md .rst .rtf .csv .json .log` and common source code. It skips
  `.git`, `node_modules`, virtual environments, hidden files, binaries and text files
  over 1 MB.
- **Reads images, too.** Screenshots, scans and photos of documents (`.png .jpg .jpeg
  .heic .tiff .gif .bmp .webp`) are searched by the text inside them. Recognition uses
  the Vision framework built into macOS, so it is on-device like everything else.
  A picture with no text in it (your holiday snaps) is found by its file name only, for example
  `Holiday Rome 2024.jpg`; searching by what a photo *shows* is not supported. Finnish is not on Vision's official language
  list, so the engine reads it with the Swedish model, which handles ä and ö. On my
  test images that gave 1.00 character accuracy on clean text and 0.99 on a blurred
  phone-style photo. Handwriting and tiny print are untested and likely weaker.
  PDF and DOCX are not supported yet.

## Install

### The easy way (Apple Silicon, macOS 14+)

1. Download `SemanticSpotlight.dmg` from the **Releases** page of this repository.
2. Drag the app to **Applications**.
3. Right-click it, choose **Open**, and confirm once. (It is ad-hoc signed, not
   notarized, so macOS asks before trusting it. That is the price of not having a
   paid Apple developer account.)
4. In the welcome window, click **Download language model** (about 470 MB, once), pick
   a folder, and wait for the checkmark.

Then press **Option+Space** from anywhere.

| Key | Action |
| --- | --- |
| Up / Down | Move through results |
| Return | Open the file |
| Cmd+Return | Reveal in Finder |
| Tab, then Space | Quick Look preview |
| Esc | Dismiss |

### From source

You need an Apple Silicon Mac, Python 3.12+ and the Xcode Command Line Tools.

```bash
python3 -m venv .venv
.venv/bin/pip install -e engine
.venv/bin/semsearch fetch-model        # one-time model download (about 470 MB)
```

The command-line tool:

```bash
.venv/bin/semsearch add ~/Documents/notes      # register a folder
.venv/bin/semsearch index                      # index what is new, forget what is gone
.venv/bin/semsearch query "notes about the municipality data pipeline migration"
.venv/bin/semsearch query "ERR-40417" -n 5 --json
.venv/bin/semsearch status
.venv/bin/semsearch remove ~/Documents/notes
```

Build the app and a shareable disk image:

```bash
engine/package_runtime.sh   # self-contained Python runtime, about 514 MB unpacked (verified at the end)
app/build.sh                # app/dist/SemanticSpotlight.app
app/make_dmg.sh             # app/dist/SemanticSpotlight.dmg (about 236 MB before the smaller runtime; rebuild to measure)
```

## Uninstall

Open **Settings → Uninstall**. The confirmation lists exactly what goes, with sizes: the
index, the downloaded model, preferences, caches, the GPU shader caches macOS made for
it, the login item, and finally the app itself. Your own files and folders are never
touched. Afterwards it re-checks every path and lists anything it could not remove, and
the result can be copied or saved as a redacted report. Anything the app created that it could not remove is listed afterwards, with how to finish it
(see [app/README.md](app/README.md#what-the-uninstall-does-not-remove)); your own files are left alone.
From source, `semsearch uninstall --yes` removes everything under `~/.semsearch`. The
full list of files the product creates is in
[engine/UNINSTALL_INVENTORY.md](engine/UNINSTALL_INVENTORY.md).

For a support request, **Settings → Diagnostics → Copy diagnostics…** shows a redacted text (no file names, queries or contents) to read first; nothing is sent automatically.

## How it works

```
 Menu-bar app (SwiftUI)  --Unix socket-->  Python daemon  -->  ~/.semsearch/
  Option+Space panel       newline JSON     model kept warm      index.db (SQLite)
  FSEvents folder watch                     hybrid search        config.json, models/
```

- **Embeddings:** `intfloat/multilingual-e5-small`, via sentence-transformers on Apple
  GPU (MPS) with a CPU fallback. Chunks are about 400 tokens with 60 tokens of overlap.
- **Storage:** one SQLite file holds chunks, vectors (float32 blobs) and an FTS5
  index. Vector search is plain numpy cosine, which is comfortable up to roughly
  100,000 chunks. Beyond that, swap in an ANN index; the spot is marked in the code.
- **Privacy:** `~/.semsearch` is `0700` and the index is `0600`. The daemon listens on
  a Unix socket that only you can reach, not on a network port.

The model comparison and its numbers are in
[engine/MODEL_CHOICE.md](engine/MODEL_CHOICE.md). Engine details are in
[engine/README.md](engine/README.md); app details are in [app/README.md](app/README.md).

## Numbers, honestly reported

Measured on an Apple Silicon MacBook (48 GB), small corpora:

- **Indexing:** about 27 files per second on a 300-file generated corpus
  (`engine/tools/bench_index.py`, 300 chunks). Unchanged files are skipped without being read.
- **Query latency:** a median of about 22 ms per query in the same benchmark (real model,
  in-process); about 3 s from a cold command line, which is mostly loading the model.
- **Quality:** on a 63-document, 64-query bilingual test set, Finnish and English both
  score 1.00 MRR and recall@5, exact-ID queries find their file every time, and the
  file-name queries find their file (4 of 4). Off-topic queries return nothing (0 of 10 with hits).

Please apply the appropriate pinch of salt: that test set is small and was written by
the same people who wrote the search engine. Real notes with slang, abbreviations and
mixed languages will be harder. The similarity floor was tuned on the same set, so
if you notice a good result missing, it is the first thing to suspect.

## Known limits

- **Same-language search only.** An English query will not reliably find a Finnish file
  or the other way round. The index does not translate.
- **No PDF or DOCX** yet, and no searching photos by what they show (OCR reads text only).
- **Apple Silicon and macOS 14+ only.**
- **Not notarized,** hence the one-time right-click.
- The per-folder file counts in the app are totals across all folders.

## Tests

```bash
.venv/bin/pytest engine/tests                       # 95 tests, about 70 seconds
.venv/bin/python engine/tests/eval/run_eval.py      # bilingual retrieval evaluation
```

Built with Python, SQLite and SwiftUI, and a firm belief that your notes are nobody
else's business.

## License

MIT, see [LICENSE](LICENSE). Bundled third-party software and its licenses:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
