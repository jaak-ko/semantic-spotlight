#!/bin/bash
# Builds engine/dist/runtime: a relocatable Python 3.12 + the semsearch engine + pinned dependencies.
# Network is used only here, at build time (python-build-standalone + PyPI). The result runs with no
# project .venv and no system Python, from any path:  dist/runtime/bin/semsearch status
# Requires: macOS on Apple Silicon, curl, shasum, tar. Idempotent: reuses the cached tarball.
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")" && pwd -P)"
DIST="$ENGINE_DIR/dist"
OUT="${RUNTIME_OUT:-$DIST/runtime}"  # RUNTIME_OUT: build elsewhere (tests)
CACHE="$DIST/cache"

# Pinned standalone interpreter: python-build-standalone 20261026 (18 days old), CPython 3.12.16, arm64 macOS.
PBS_TAG="20261026"
PBS_ASSET="cpython-3.12.16+20261026-aarch64-apple-darwin-install_only.tar.gz"
PBS_SHA256="fbf4afef53c2a6b72bb741bc06d5671a9dfaf87bd84e5aa73ac9b3d0d589f14e"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_ASSET//+/%2B}"

[ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] || { echo "error: needs macOS on arm64" >&2; exit 1; }

mkdir -p "$CACHE"
TARBALL="$CACHE/$PBS_ASSET"
if [ ! -f "$TARBALL" ]; then
  echo "fetching $PBS_ASSET"
  curl -fL --retry 3 -o "$TARBALL.part" "$PBS_URL"
  mv "$TARBALL.part" "$TARBALL"
fi
if ! echo "$PBS_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null 2>&1; then
  rm -f "$TARBALL"
  echo "error: sha256 mismatch for $PBS_ASSET (file removed; re-run to fetch again)" >&2
  exit 1
fi
echo "sha256 ok: $PBS_ASSET"

rm -rf "$OUT"
mkdir -p "$OUT"
tar -xzf "$TARBALL" -C "$OUT"          # yields $OUT/python/
PY="$OUT/python/bin/python3"
export PYTHONNOUSERSITE=1 PIP_DISABLE_PIP_VERSION_CHECK=1

# Every package is pinned with hashes (runtime-requirements.txt): --require-hashes refuses anything else,
# --no-deps installs exactly that set, and --only-binary refuses source builds. hf-xet is not in the file:
# huggingface_hub runs without it, since xet downloads are disabled in code (HF_HUB_DISABLE_XET).
"$PY" -m pip install --no-cache-dir --no-compile --no-deps --require-hashes --only-binary=:all: \
  --no-warn-script-location -q -r "$ENGINE_DIR/runtime-requirements.txt"

# The engine itself: copy the package (no wheel build, no build artifacts in engine/).
SITE="$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
rm -rf "$SITE/semsearch"
cp -R "$ENGINE_DIR/semsearch" "$SITE/semsearch"
find "$SITE/semsearch" -name __pycache__ -prune -exec rm -rf {} +

# Relocatable launcher (pip console scripts would embed this build machine's paths).
mkdir -p "$OUT/bin"
cat > "$OUT/bin/semsearch" <<'LAUNCHER'
#!/bin/sh
# Runs the bundled interpreter with its own packages only (-I: no env vars, user site or cwd on sys.path).
DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
export PYTHONDONTWRITEBYTECODE=1  # never write .pyc into the (signed) app bundle
exec "$DIR/python/bin/python3" -I -B -c 'import sys; from semsearch.cli import main; sys.exit(main())' "$@"
LAUNCHER
chmod +x "$OUT/bin/semsearch"

# OCR helper: Apple Vision text recognition for images. Compiled with swiftc; links only system frameworks
# and the OS Swift runtime, so nothing extra is bundled. The engine finds it at bin/ocr-helper.
command -v swiftc >/dev/null || { echo "error: swiftc is required to build the OCR helper" >&2; exit 1; }
# Debug info would carry this checkout's path: map it, then strip. Stripping invalidates the linker's
# ad-hoc signature, so sign again.
swiftc -O -file-prefix-map "$ENGINE_DIR=/src" -debug-prefix-map "$ENGINE_DIR=/src" \
  -o "$OUT/bin/ocr-helper" "$ENGINE_DIR/ocr/ocr.swift"
strip -x "$OUT/bin/ocr-helper"
codesign --force -s - "$OUT/bin/ocr-helper"

# Strip what the product never uses (every removal here is checked by verify_runtime.sh).
LIB="$OUT/python/lib/python3.12"
rm -rf "$OUT/python/include" "$OUT/python/share" "$LIB/config-3.12-darwin" \
       "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/ensurepip" "$LIB/lib2to3" \
       "$LIB/test" "$OUT/python/bin/pip"* "$OUT/python/bin/idle"* "$OUT/python/bin/2to3"* 2>/dev/null || true
find "$OUT/python/lib" -name "*.a" -delete
find "$OUT/python/lib" \( -name tests -o -name test \) -type d -prune -exec rm -rf {} +
find "$OUT/python/lib" -name "*.pyi" -delete
rm -rf "$LIB/site-packages/pip" "$LIB/site-packages/pip-"*.dist-info \
       "$LIB/site-packages/setuptools" "$LIB/site-packages/setuptools-"*.dist-info \
       "$LIB/site-packages/_distutils_hack" "$LIB/site-packages/pkg_resources" 2>/dev/null || true
rm -f "$LIB/site-packages/distutils-precedence.pth"  # imports _distutils_hack, which is removed above
rm -rf "$LIB/site-packages/torch/include"           # C++ headers for building extensions: 51 MB, unused at runtime
rm -rf "$LIB/site-packages/torch/share"             # cmake configs with the upstream CI build paths
find "$LIB/site-packages" -type d -name sboms -prune -exec rm -rf {} +  # SBOM json with upstream CI paths
rm -rf "$LIB/site-packages/torch/bin/protoc"*       # protobuf compiler CLI: torch never runs it
find "$LIB/site-packages" \( -name '*.pyx' -o -name '*.pxd' -o -name '*.pxi' \) -delete  # Cython sources: build-time only
rm -f "$LIB/lib-dynload/_tkinter"*.so                # tkinter is removed above
rm -rf "$OUT/python/lib/libtcl9"* "$OUT/python/lib/tcl9" "$OUT/python/lib/tcl9.0" "$OUT/python/lib/tk9.0" \
       "$OUT/python/lib/itcl4.3.8" "$OUT/python/lib/thread3.0.6" "$OUT/python/lib/pkgconfig"  # Tcl/Tk: tkinter only

# pip console scripts in python/bin carry this build's absolute paths and are never used: drop text scripts.
for f in "$OUT"/python/bin/*; do
  if [ -f "$f" ] && [ ! -L "$f" ] && [ "$(head -c 2 "$f")" = "#!" ]; then rm -f "$f"; fi
done

# Stripping can leave symlinks pointing at removed files (python3-config, pydoc3): drop them,
# or codesign --deep fails on the bundle.
find "$OUT" -type l ! -exec test -e {} \; -print -delete

# Debug symbols: strip -x keeps every exported symbol, so linking and dlopen are unchanged. Stripping
# invalidates the ad-hoc signature, so each file is signed again (verify_runtime.sh checks all of them).
find "$OUT/python" -type f \( -name '*.so' -o -name '*.dylib' -o -path "$OUT/python/bin/python3.12" \) -print0 |
  while IFS= read -r -d '' f; do
    strip -x "$f" 2>/dev/null || { echo "error: strip failed: $f" >&2; exit 1; }
    codesign --force -s - "$f" >/dev/null
  done

# Bytecode: compile once, so first launch does not pay for it. Clear old pycs first (pip or the engine copy
# may have left some): compileall skips up-to-date files, which would keep their build-machine co_filename.
# -s/-p rewrite each code object's source path to /runtime/..., so no build path or username is embedded.
find "$OUT" -name __pycache__ -prune -exec rm -rf {} +
"$PY" -m compileall -q -j 0 -s "$OUT" -p /runtime "$LIB" "$SITE" >/dev/null || true
# Third-party .pyc only for the modules a model load imports; the rest (about 100 MB) is never loaded, and a
# module without a .pyc still runs from its .py. The list is checked by verify_runtime.sh. semsearch/ keeps all.
"$PY" -I -B - "$SITE" <<'PY'
import importlib, os, sys
root = os.path.abspath(sys.argv[1])
for name in ("semsearch.cli", "sentence_transformers", "torch", "sklearn.metrics", "PIL.Image", "huggingface_hub",
             "transformers.models.bert.modeling_bert", "transformers.models.xlm_roberta.modeling_xlm_roberta",
             "transformers.models.auto.modeling_auto", "transformers.models.auto.tokenization_auto",
             "transformers.models.xlm_roberta.tokenization_xlm_roberta_fast",
             "transformers.models.kosmos2", "transformers.models.metaclip_2"):
    importlib.import_module(name)
keep = set()
for m in list(sys.modules.values()):
    f = getattr(m, "__file__", None)
    if f and f.startswith(root + os.sep) and f.endswith(".py"):
        d, b = os.path.split(f)
        keep.add(os.path.join(d, "__pycache__", b[:-3] + ".cpython-312.pyc"))
own = os.path.join(root, "semsearch") + os.sep
removed = 0
for dp, dn, fn in os.walk(root):
    for x in fn:
        p = os.path.join(dp, x)
        if x.endswith(".pyc") and "__pycache__" in dp and p not in keep and not p.startswith(own):
            os.remove(p)
            removed += 1
print(f"bytecode pruned: {removed} files")
PY
find "$SITE" -name __pycache__ -empty -delete

echo "runtime built: $OUT"
du -sh "$OUT" | awk '{print "size: " $1}'

# Checks the result the way the app uses it (tests, model on MPS, OCR, daemon). Needs dist/models and .venv.
# SEMSEARCH_SKIP_VERIFY=1 only for a build that is verified later on purpose.
if [ "${SEMSEARCH_SKIP_VERIFY:-0}" != 1 ]; then "$ENGINE_DIR/tools/verify_runtime.sh" "$OUT"; fi
