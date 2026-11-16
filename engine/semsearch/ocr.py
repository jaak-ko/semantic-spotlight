"""On-device OCR through the Vision-based `ocr` helper (engine/ocr/ocr.swift). No network, no Python deps."""
import os
import shutil
import subprocess
import sys
from pathlib import Path

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".heic", ".tiff", ".gif", ".bmp", ".webp"}
TIMEOUT = 60  # seconds per image


class OcrError(RuntimeError):
    """`permanent` means the helper rejected the file itself (corrupt, empty, unsupported): cache that
    result. Timeouts and launch failures are transient and are retried next run."""

    def __init__(self, message, permanent=False):
        super().__init__(message)
        self.permanent = permanent


def _engine_dir() -> Path:
    return Path(__file__).resolve().parents[1]  # engine/ in development


def _runtime_helper() -> Path:
    # Packaged runtime: <runtime>/python/bin/python3 -> <runtime>/bin/ocr-helper
    return Path(sys.executable).parents[2] / "bin" / "ocr-helper"


def build_helper(log=print):
    """Compile engine/ocr/ocr.swift into engine/dist/ocr with swiftc. Returns the path or None."""
    src = _engine_dir() / "ocr" / "ocr.swift"
    out = _engine_dir() / "dist" / "ocr"
    if not src.exists():
        return None
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        return None
    out.parent.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run([swiftc, "-O", "-o", str(out), str(src)], capture_output=True, timeout=600, check=True)
    except (subprocess.SubprocessError, OSError) as e:
        log(f"warning: could not build the OCR helper: {e}")
        return None
    return out


def find_helper(log=print):
    """Runtime helper, then the dev build, then a first-use build. None if unavailable."""
    for p in (_runtime_helper(), _engine_dir() / "dist" / "ocr"):
        if p.is_file() and os.access(p, os.X_OK):
            return p
    return build_helper(log)


def ocr_image(helper, path, languages, timeout=TIMEOUT) -> str:
    """Text recognised in `path`. Raises OcrError on failure (corrupt or empty file, timeout, ...)."""
    try:
        out = subprocess.run([str(helper), str(path), ",".join(languages)],
                             capture_output=True, timeout=timeout, check=False)
    except (subprocess.SubprocessError, OSError) as e:
        raise OcrError(f"{type(e).__name__}: {e}") from e
    if out.returncode != 0:
        raise OcrError(out.stderr.decode("utf-8", "replace").strip() or f"exit {out.returncode}",
                       permanent=True)
    return out.stdout.decode("utf-8")
