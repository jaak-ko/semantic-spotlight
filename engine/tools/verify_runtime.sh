#!/bin/bash
# Verifies the packaged runtime the way the app uses it: the full engine test suite run by the runtime's own
# interpreter, a model load on MPS, a CPU and a forced-fallback embed, OCR, index and query, the daemon over
# its socket, fetch-model offline, code signatures, and a scan for the user's name or home path.
# Fails loudly (exit 1) at the first failed check. Usage: engine/tools/verify_runtime.sh [runtime-dir]
# Needs: dist/models (the pinned model, see tests/conftest.py) and the project .venv (for pytest only).
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
ROOT="$(cd "$ENGINE_DIR/.." && pwd -P)"
RT="$(cd "${1:-$ENGINE_DIR/dist/runtime}" && pwd -P)"
PY="$RT/python/bin/python3"
LAUNCH="$RT/bin/semsearch"
MODELS="$ENGINE_DIR/dist/models"
PYTEST_SRC="$ROOT/.venv/lib/python3.12/site-packages"
WORK="$(mktemp -d /tmp/ssverify-XXXX)"  # short path: the daemon socket's AF_UNIX path limit
DPID=""

cleanup() {
  if [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null; then kill "$DPID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "== $*"; }

[ -x "$PY" ] && [ -x "$LAUNCH" ] || fail "no runtime at $RT (build it with engine/package_runtime.sh)"
[ -d "$MODELS" ] || fail "no model at $MODELS (run: SEMSEARCH_MODELS=$MODELS semsearch fetch-model, with a dev venv)"
[ -d "$PYTEST_SRC/pytest" ] || fail "no pytest in $PYTEST_SRC (install the dev requirements into .venv)"

step "code signatures"
find "$RT" -type f \( -name '*.so' -o -name '*.dylib' -o -path "$RT/python/bin/python3.12" -o -path "$RT/bin/ocr-helper" \) -print0 |
  while IFS= read -r -d '' f; do
    codesign --verify --strict "$f" 2>/dev/null || fail "signature invalid: $f"
  done

step "no user name, checkout path or unknown /Users/ path in the runtime"
USER_NAME="$(id -un)"
hits="$(LC_ALL=C grep -rla -e "$USER_NAME" -e "$ROOT" "$RT" || true)"
[ -z "$hits" ] || fail "user name or checkout path found in: $(echo "$hits" | head -20 | tr '\n' ' ')"
# Upstream wheels and python-build-standalone carry their CI paths (/Users/runner, a docstring example name).
# Those are listed here; any other /Users/ path is new and fails.
unknown="$(LC_ALL=C grep -rhao '/Users/[A-Za-z0-9_.-]*' "$RT" | sort -u | grep -vxE '/Users/(runner|lucain|Barney)' || true)"
[ -z "$unknown" ] || fail "unexpected /Users/ paths: $(echo "$unknown" | tr '\n' ' ')"

step "clean copies of the inputs (APFS clones: no writes to the project)"
cp -cR "$MODELS" "$WORK/models"
cp -cR "$ENGINE_DIR/tests/corpus" "$WORK/corpus"
cp "$ENGINE_DIR/tests/ocr_fixtures/en_screenshot.png" "$WORK/corpus/"
export SEMSEARCH_HOME="$WORK/home/.semsearch" SEMSEARCH_MODELS="$WORK/models"  # never the user's home

step "loaded third-party modules have bytecode (the build prunes the rest)"
"$PY" -I -B - "$RT/python/lib/python3.12/site-packages" <<'PY'
import os, sys
root = os.path.abspath(sys.argv[1])
from semsearch import config
from semsearch.embed import Embedder
e = Embedder(config.load()["model"], config.models_dir())
missing = []
for m in list(sys.modules.values()):
    f = getattr(m, "__file__", None)
    if f and f.startswith(root + os.sep) and f.endswith(".py") and not f.startswith(os.path.join(root, "semsearch") + os.sep):
        d, b = os.path.split(f)
        if not os.path.exists(os.path.join(d, "__pycache__", b[:-3] + ".cpython-312.pyc")):
            missing.append(f[len(root) + 1:])
if missing:
    print("modules loaded without .pyc (add them to the build's import list in package_runtime.sh):", file=sys.stderr)
    print("\n".join(sorted(missing)[:40]), file=sys.stderr)
    sys.exit(1)
print(f"ok: {len(sys.modules)} modules loaded")
PY

step "model on MPS, CPU embed agrees, forced fallback to CPU"
SEMSEARCH_MODELS="$WORK/models" "$PY" -I -B - <<'PY' || fail "model checks (see traceback above)"
import numpy as np, torch
from semsearch import config
from semsearch.embed import Embedder
e = Embedder(config.load()["model"], config.models_dir())
want = "mps" if torch.backends.mps.is_available() else "cpu"
assert str(e.model.device).startswith(want), (str(e.model.device), want)
texts = ["Kardemummapullan resepti", "Quarterly sales report"]
v = e.embed(texts, "passage")
assert v.shape == (2, 384), v.shape
assert np.allclose(np.linalg.norm(v, axis=1), 1.0, atol=1e-3)
e.model = e.model.to("cpu")
c = e.embed(texts, "passage")
cos = (v * c).sum(axis=1)
assert (cos > 0.99).all(), cos
orig = e.model.encode
calls = {"n": 0}
def flaky(*a, **k):
    calls["n"] += 1
    if calls["n"] == 1:
        raise RuntimeError("simulated device failure")
    return orig(*a, **k)
e.model.encode = flaky
f = e.embed(texts, "passage")
assert calls["n"] == 2 and str(e.model.device) == "cpu", calls
assert np.allclose(f, c, atol=1e-5)
print("ok:", want, "embed", v.shape, "cpu cos", round(float(cos.min()), 5))
PY

step "every top-level module of the engine's dependencies imports"
"$PY" -I -B - "$RT/python/lib/python3.12/site-packages" <<'PY' || fail "imports (see above)"
import importlib, pkgutil, sys
failed, count = [], 0
def check(name):
    global count
    count += 1
    try:
        importlib.import_module(name)
    except Exception as e:
        failed.append(f"{name}: {type(e).__name__}: {e}")
for pkg in ["sentence_transformers", "huggingface_hub", "requests", "tokenizers", "numpy", "snowballstemmer"]:
    m = importlib.import_module(pkg)
    check(pkg)
    for info in pkgutil.iter_modules(m.__path__, prefix=pkg + "."):
        if info.name.endswith(".conftest"):  # pytest's config file shipped by numpy: never imported at runtime
            continue
        check(info.name)
for name in ["transformers", "transformers.models.bert.modeling_bert", "transformers.models.xlm_roberta.modeling_xlm_roberta",
             "transformers.models.auto.modeling_auto", "transformers.models.auto.tokenization_auto",
             "transformers.models.xlm_roberta.tokenization_xlm_roberta_fast"]:
    check(name)
if failed:
    print("\n".join(failed), file=sys.stderr)
    sys.exit(1)
print(f"ok: {count} modules imported")
PY

step "a module without bytecode still imports (the clone's kosmos2 and metaclip_2 .pyc removed)"
rm -rf "$WORK/rt-clone" && cp -cR "$RT" "$WORK/rt-clone"
find "$WORK/rt-clone/python/lib/python3.12/site-packages/transformers/models/kosmos2" \
     "$WORK/rt-clone/python/lib/python3.12/site-packages/transformers/models/metaclip_2" -name '*.pyc' -delete
PYC_DIR="$WORK/rt-clone/python/lib/python3.12/site-packages/transformers/models"
before="$(find "$PYC_DIR" -name '*.pyc' | wc -l)"
"$WORK/rt-clone/python/bin/python3" -I -B -c "import transformers.models.kosmos2, transformers.models.metaclip_2" \
  || fail "import of a module without bytecode"
after="$(find "$PYC_DIR" -name '*.pyc' | wc -l)"
[ "$before" = "$after" ] || fail "an import wrote bytecode into the runtime ($before -> $after .pyc files)"

step "error path: no model installed raises ModelMissing with the fetch hint"
SEMSEARCH_MODELS="$WORK/empty-models" "$PY" -I -B - <<'PY' || fail "ModelMissing path (see above)"
from semsearch import config
from semsearch.embed import Embedder
from semsearch.modelfiles import ModelMissing
try:
    Embedder(config.load()["model"], config.models_dir())
except ModelMissing as e:
    assert "fetch-model" in str(e), e
    print("ok: ModelMissing:", e)
else:
    raise SystemExit("no ModelMissing raised for an empty models folder")
PY

step "OCR helper directly (Vision, the engine's languages: sv-SE, en-US)"
out="$("$RT/bin/ocr-helper" "$WORK/corpus/en_screenshot.png" sv-SE,en-US)"
echo "$out" | grep -qi "quarterly" || fail "ocr-helper output: $out"
out="$("$RT/bin/ocr-helper" "$ENGINE_DIR/tests/ocr_fixtures/fi_resepti.png" sv-SE,en-US)"
echo "$out" | grep -qi "kardemumma" || fail "ocr-helper (fi) output: $out"

step "test suite on the runtime interpreter (about 75 s)"
mkdir -p "$WORK/pytest-libs"
for pkg in pytest _pytest pluggy iniconfig py.py; do cp -R "$PYTEST_SRC/$pkg" "$WORK/pytest-libs/"; done
(cd "$WORK" && SEMSEARCH_BIN="$LAUNCH" PYTHONPATH="$WORK/pytest-libs" PYTHONDONTWRITEBYTECODE=1 \
  "$PY" -s -m pytest -q -p no:cacheprovider "$ENGINE_DIR/tests") || fail "test suite failed on the runtime"

step "engine CLI: add, index (text and OCR), query, status, from a neutral cwd"
(cd / && "$LAUNCH" add "$WORK/corpus" >/dev/null) || fail "add"
(cd / && "$LAUNCH" index >/dev/null) || fail "index"
res="$(cd / && "$LAUNCH" query "Quarterly sales report northern region" --json)" || fail "query"
echo "$res" | "$PY" -I -B -c 'import json,sys; r=json.load(sys.stdin)["results"]; assert any(x["path"].endswith("en_screenshot.png") for x in r), r' \
  || fail "query did not find the OCR'd image: $res"
res="$(cd / && "$LAUNCH" query "pulla kardemumma" --json)" || fail "query 2"
echo "$res" | "$PY" -I -B -c 'import json,sys; r=json.load(sys.stdin)["results"]; assert r, r' || fail "query 2 empty"
(cd / && "$LAUNCH" status --json >/dev/null) || fail "status"

step "daemon over its socket: start, query, shutdown"
SOCK="$SEMSEARCH_HOME/daemon.sock"
(cd / && "$LAUNCH" daemon >"$WORK/daemon.log" 2>&1) &
DPID=$!
for _ in $(seq 1 120); do [ -S "$SOCK" ] && break; sleep 1; done
[ -S "$SOCK" ] || fail "daemon socket never appeared: $(tail -5 "$WORK/daemon.log")"
live="$(cd / && "$LAUNCH" query "pulla kardemumma" --json)" || fail "query through the daemon"
echo "$live" | "$PY" -I -B -c 'import json,sys; assert json.load(sys.stdin)["results"], "empty"' || fail "daemon query empty"
"$PY" -I -B - "$SOCK" <<'PY' || fail "shutdown request"
import socket, sys
with socket.socket(socket.AF_UNIX) as s:
    s.settimeout(10)
    s.connect(sys.argv[1])
    s.sendall(b'{"cmd": "shutdown"}\n')
    s.recv(4096)
PY
for _ in $(seq 1 30); do kill -0 "$DPID" 2>/dev/null || break; sleep 1; done
if kill -0 "$DPID" 2>/dev/null; then fail "daemon still running after shutdown"; fi
wait "$DPID" || fail "daemon exited with an error: $(tail -5 "$WORK/daemon.log")"
DPID=""
[ ! -e "$SOCK" ] || fail "daemon socket left behind"

step "fetch-model: imports and runs; fails cleanly offline when the model is missing (no network is used)"
(cd / && "$LAUNCH" fetch-model --help >/dev/null) || fail "fetch-model --help"
set +e
miss="$(cd / && HF_HUB_OFFLINE=1 SEMSEARCH_MODELS="$WORK/empty" "$LAUNCH" fetch-model 2>"$WORK/fetch.err")"
code=$?
set -e
[ "$code" -ne 0 ] || fail "fetch-model with no model and no network should fail"
echo "$miss" | grep -q '"event": "error"' || fail "fetch-model offline: no error event: $miss"
grep -q "Traceback" "$WORK/fetch.err" && fail "fetch-model offline printed a traceback"

echo "runtime verified: $RT"
