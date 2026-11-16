"""fetch-model is cancelled by SIGTERM: one cancelled event, exit 130 within a second, model_ready stays false,
the partial bytes stay on disk, and the next run resumes from them and verifies (no network: fake Hub child)."""
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

CHILD = Path(__file__).with_name("fake_hub_child.py")
TOTAL = 3000 + 8 * 10  # the large file plus the eight small ones (fake_hub_child.py)


def _child(mode, models, home):
    env = {**os.environ, "SEMSEARCH_HOME": str(home), "SEMSEARCH_MODELS": str(models)}
    return subprocess.Popen([sys.executable, "-B", str(CHILD), mode], stdout=subprocess.PIPE, text=True, env=env)


def test_sigterm_mid_download_cancels_then_next_run_resumes_and_verifies(tmp_path, monkeypatch):
    models, home = tmp_path / "models", tmp_path / "home"
    p = _child("slow", models, home)
    events, sent, t_sig = [], False, 0.0
    for line in p.stdout:  # read to the end: the child's last line is the cancelled event
        ev = json.loads(line)
        events.append(ev)
        if not sent and ev["event"] == "progress" and ev["done"] >= 0.3 * ev["total"]:
            sent, t_sig = True, time.monotonic()
            p.send_signal(signal.SIGTERM)
    code = p.wait(timeout=10)
    assert sent, events
    assert code == 130
    assert time.monotonic() - t_sig < 1.0
    assert events[-1]["event"] == "cancelled" and events[-1]["total"] == TOTAL
    assert 0.3 * TOTAL <= events[-1]["done"] < TOTAL
    assert not [e for e in events if e["event"] in ("done", "error")]

    monkeypatch.setenv("SEMSEARCH_HOME", str(home))
    monkeypatch.setenv("SEMSEARCH_MODELS", str(models))
    from semsearch import modelfiles
    assert modelfiles.model_ready() is False  # partial files never count as installed
    partial = modelfiles.model_dir(modelfiles.DEFAULT_MODEL) / "blobs" / "big.incomplete"
    have = partial.stat().st_size
    assert 0 < have < 3000

    p2 = _child("fast", models, home)
    out = [json.loads(line) for line in p2.stdout if line.strip()]
    assert p2.wait(timeout=30) == 0 and out[-1] == {"event": "done"}
    assert (models / "attempts.log").read_text().split() == ["0", str(have)]  # resumed, not restarted
    assert modelfiles.model_ready() is True
