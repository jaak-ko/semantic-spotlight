import json
import os
import sys
from pathlib import Path

DEFAULTS = {
    "model": "intfloat/multilingual-e5-small",
    "stemming": True,        # Snowball Finnish stems added to the keyword index (FI 0.955 -> 1.0 MRR)
    "min_similarity": 0.81,  # floor on the best chunk's cosine (sweep: off-topic 0/10, recall unchanged); exact-ID keyword hits are exempt
    "chunk_tokens": 400,
    "chunk_overlap": 60,
    "max_file_bytes": 1024 * 1024,
    "max_image_bytes": 25 * 1024 * 1024,
    "ocr_languages": ["sv-SE", "en-US"],  # Vision has no Finnish; Swedish covers ä, ö, å
    "extensions": [
        ".txt", ".md", ".rst", ".rtf", ".csv", ".json", ".log",
        ".py", ".js", ".ts", ".go", ".rs", ".java", ".c", ".h", ".cpp",
        ".sh", ".sql", ".yaml", ".toml",
        ".png", ".jpg", ".jpeg", ".heic", ".tiff", ".gif", ".bmp", ".webp",
    ],
    "skip_dirs": [".git", "node_modules", ".venv", "venv", "__pycache__", "dist", "build"],
}


def home() -> Path:
    """The engine home. Pure: a lookup creates nothing. SEMSEARCH_HOME lets tests use a temp folder."""
    return Path(os.environ.get("SEMSEARCH_HOME", Path.home() / ".semsearch"))


def ensure_home() -> Path:
    """Create the engine home before something is written into it. Private: 0700, also when it already existed."""
    p = home()
    p.mkdir(parents=True, exist_ok=True)
    os.chmod(p, 0o700)
    return p


def load() -> dict:
    cfg = dict(DEFAULTS)
    f = home() / "config.json"
    if not f.exists():
        return cfg
    try:
        data = json.loads(f.read_text())
    except (OSError, ValueError) as e:
        print(f"warning: {f} is not valid JSON, using defaults ({e})", file=sys.stderr)
        return cfg  # never overwrite or delete the user's file
    if not isinstance(data, dict):
        print(f"warning: {f} must hold a JSON object, using defaults", file=sys.stderr)
        return cfg
    cfg.update(data)
    return cfg


def models_dir() -> Path:
    """Where the model is cached. Pure: fetch-model creates it. Own setting so a temp home can reuse models."""
    return Path(os.environ.get("SEMSEARCH_MODELS", Path.home() / ".semsearch" / "models"))
