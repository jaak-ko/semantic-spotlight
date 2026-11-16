# Uninstall inventory

Every file and folder the product creates, who creates it, and whether it lives under the engine home (`~/.semsearch`, or `SEMSEARCH_HOME`). `semsearch uninstall --yes` removes everything under the engine home. The macOS paths at the end are the only exception and are listed with the commands that remove them.

## Method

Measured with a temporary `HOME` in a clean environment (`env -i`), and a marker file for `find -newer`:

- The models folder is an APFS clone of the real models folder, so the run never writes to it. A clean run then executes `fetch-model` (verification only, no download), `add`, `index` (26 files, including 3 images), `query`, and the daemon for about a minute (queries, `status`, `shutdown`).
- Run twice: once from the venv (`.venv/bin/semsearch`), and once from the packaged runtime (`runtime/bin/semsearch`, built into a temp directory).
- Paths were compared against the marker, for the temp `HOME`, the per-user temp and cache folders (`getconf DARWIN_USER_TEMP_DIR` and `DARWIN_USER_CACHE_DIR`), and the real home's caches.
- The real home's changes in the same window came from other apps (Spotify, OpenAI, Find My, system services). They are not the engine's and are not listed.

The engine's own `__pycache__` folders (dev only, `engine/semsearch/__pycache__`) are not listed. The runtime never writes bytecode (`PYTHONDONTWRITEBYTECODE=1` in the launcher), and in development, Python writes them next to the sources.

## Under the engine home (`~/.semsearch`)

Both runs produced the same set. `uninstall` removes all of it.

| Path | Created by | Notes |
|---|---|---|
| `index.db` (+ `-wal`, `-shm` while open) | `store.py` (`Store`) | The index. About 136 KB for 26 files. Mode 0600; the folder is 0700. |
| `daemon.sock` | `daemon.py` | Mode 0600. Present only while the daemon runs; removed on clean exit. |
| `daemon.lock` | `daemon.py` | Empty, mode 0600. Held with `flock` by the running daemon; left in place after exit, the lock is released by the OS. |
| `models/models--intfloat--multilingual-e5-small/` | `fetch-model` (`modelfiles.py`), `huggingface_hub`, `sentence-transformers` | The model, about 470 MB: `blobs/`, `snapshots/<pinned commit>/`, `refs/`, and `.no_exist/<commit>` markers. |
| `models/.locks/` | `huggingface_hub` during `fetch-model` and model loads | Lock files only. |
| `models/models--BAAI--bge-m3/` | Only if you point `model` at bge-m3 (developer setting) | Not created by default. |
| `hf/` | `cli._caches_under_home()` sets `HF_HOME` here | Empty in the runs. Anything the Hugging Face libraries cache lands here. |
| `torch/` | `TORCH_HOME` | Empty in the runs. |
| `st/` | `SENTENCE_TRANSFORMERS_HOME` | Empty in the runs. |
| `cache/` | `XDG_CACHE_HOME` | Empty in the runs. |
| `tmp/` | `TMPDIR` | Python's temporary files. Empty in the runs. |

Written by the frontend app, not the engine, but in the same folder, so `uninstall` removes them too: `config.json` (contains `engine_path`), `app-daemon.log`.

## Outside the engine home (macOS, per-user, shared)

These are written by macOS frameworks when the model runs on the GPU (the MPS device), not by the engine. Environment variables did not redirect them in a test: with `DARWIN_USER_CACHE_DIR`, `DARWIN_USER_TEMP_DIR` and `TMPDIR` set to temp folders, nothing appeared in those folders.

| Path | Created by | Removed by `uninstall`? |
|---|---|---|
| `$(getconf DARWIN_USER_CACHE_DIR)org.python.python/com.apple.metal/` | Metal shader cache for the Python interpreter, under a folder named for the interpreter's identity (`org.python.python` in both runs). 4 to 6 small files. | No |
| `$(getconf DARWIN_USER_CACHE_DIR)com.apple.metal/` | Metal shader cache shared by all Metal apps. | No (shared; left in place) |
| `$(getconf DARWIN_USER_TEMP_DIR)com.apple.MetalPerformanceShadersGraph/` | MPSGraph temporary folders, one `mpsgraph-<pid>-…` per process. | No (created per process; left in place) |
| `$(getconf DARWIN_USER_CACHE_DIR)local.semanticspotlight.app/` | GPU cache keyed by the app's bundle identifier, written by the bundled runtime. | Yes: removed by the app's Uninstall |

Avoiding the GPU avoids the Metal caches entirely. A CPU-only run wrote nothing there (measured). The engine uses MPS when available (`embed.py`), so this is a performance trade-off, not a bug.

## What the app's Uninstall removes, and what it leaves

- **Removed:** the engine home (everything under `~/.semsearch`, listed above) and the GPU cache keyed by the app's own bundle identifier, `local.semanticspotlight.app`. That cache is written by the app's bundled runtime and belongs to the app alone.
- **Left in place on purpose:** the Metal shader cache `com.apple.metal` and the interpreter's `org.python.python/com.apple.metal` folder, which other Metal apps and Python builds share, and the MPSGraph temp folders, which the system creates per process. Deleting them would affect other software. They are small and rebuilt on demand if anything needs them.
- Nothing else is removed. The engine does not delete the shared macOS folders and the inventory gives no commands that do.

## What we could not eliminate

- The Metal and MPSGraph folders above, because macOS chooses their location and environment variables do not change it. They are small and rebuilt on demand.
- The model cache is inside the engine home, but it is large (about 470 MB). Keeping it is intentional, so `fetch-model` does not repeat on every run.

## Verification

`engine/tests/test_inventory.py` runs `add`, `query` and a daemon session with a temporary `HOME`, then asserts that every new path under that `HOME` is inside `.semsearch`. The macOS paths above sit outside `HOME` by definition and are not checked there.
