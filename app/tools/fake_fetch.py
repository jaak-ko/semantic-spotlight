#!/usr/bin/env python3
"""A stand-in for `semsearch fetch-model` in the welcome-window tests. No network: it prints the events of the
scenario named by FAKE_FETCH_SCENARIO, then exits. Scenarios:
  transient   retry, retry, progress, progress, done (a first failure that succeeds on retry)
  five-errors retry 1..5, then an error with a friendly message and a technical detail
  old-contract an error with only a message (the old contract: the message is the technical text)
  crash       no events; the process exits 3 with a line on stderr
  slow        progress about every 100 ms in bursts, until SIGTERM: then a cancelled line and exit 130 (partial bytes stay)
  slow-retry  one retry line, then as slow
  stubborn    as slow, but ignores SIGTERM (the app must kill it after its grace period)
FAKE_FETCH_START sets the bytes already on disk (a resumed download continues from them). Total: 470 MB.
"""
import json
import os
import signal
import sys
import time

scenario = os.environ.get("FAKE_FETCH_SCENARIO", "transient")
SSL = ("SSLError: MaxRetryError(\"HTTPSConnectionPool(host='huggingface.co', port=443): Max retries exceeded with url: "
       "/api/models/intfloat/multilingual-e5-small (Caused by SSLError(SSLEOFError(8, '[SSL: UNEXPECTED_EOF_WHILE_READING] "
       "EOF occurred in violation of protocol (_ssl.c:1011)')))\")")


def emit(obj):
    print(json.dumps(obj), flush=True)


TOTAL = 470_000_000
# Bytes arrive in bursts, as a real download does: quiet ticks, then a large chunk.
BURSTS = [0, 0, 40_000_000, 3_000_000, 0, 0, 0, 25_000_000, 0, 0, 0, 0, 8_000_000, 0, 0, 60_000_000]
done = int(os.environ.get("FAKE_FETCH_START", "0") or 0)
cancelled = False


def on_term(signum, frame):
    global cancelled
    cancelled = True
    emit({"event": "cancelled", "done": done, "total": TOTAL})
    sys.exit(130)


def stream(retry_first):
    global done
    if retry_first:
        emit({"event": "retry", "attempt": 1, "max": 5})
        time.sleep(1.5)   # a retry waits before it tries again: the app shows the retrying state for that time
    if scenario != "stubborn":   # the stubborn one keeps ignoring SIGTERM
        signal.signal(signal.SIGTERM, on_term)
    i = 0
    deadline = time.time() + 60
    while time.time() < deadline:
        done = min(TOTAL, done + BURSTS[i % len(BURSTS)])
        i += 1
        emit({"event": "progress", "done": done, "total": TOTAL, "speed": 9_000_000.0})
        time.sleep(0.1)
    emit({"event": "error", "message": "the test stream timed out", "detail": "no SIGTERM in 60 s"})


if scenario == "slow":
    stream(False)
elif scenario == "slow-retry":
    stream(True)
elif scenario == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)   # the app must SIGKILL it
    stream(False)
elif scenario == "transient":
    emit({"event": "retry", "attempt": 1, "max": 5})
    emit({"event": "retry", "attempt": 2, "max": 5})
    emit({"event": "progress", "done": 10, "total": 100})
    emit({"event": "progress", "done": 100, "total": 100})
    emit({"event": "done"})
elif scenario == "five-errors":
    for n in range(1, 6):
        emit({"event": "retry", "attempt": n, "max": 5})
    emit({"event": "error", "message": "Could not reach the model server. Check the network connection, then try again.",
          "detail": SSL})
elif scenario == "old-contract":
    emit({"event": "error", "message": SSL})
elif scenario == "crash":
    print("boom: unexpected failure in the download helper", file=sys.stderr, flush=True)
    sys.exit(3)
else:
    emit({"event": "error", "message": "unknown scenario", "detail": scenario})
