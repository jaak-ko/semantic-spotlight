#!/usr/bin/env python3
"""A stub engine for tests: answers the daemon protocol from a state file, with made-up numbers only.

  fake_engine.py <home> <state.json> <requests.log>

Listens on <home>/.semsearch/daemon.sock. Every request is answered from <state.json> (re-read each time, so a test
can change the state while the app polls). Each status request appends a timestamp to <requests.log>.
A state file without a "progress" key is an older engine: only the "indexing" flag is there.
A state with "exit_on_index": N exits with code N right after its first index request (a marker file in <home> keeps it
to one exit), as the real daemon does at its memory restart (75). Index requests are logged too.
"""
import json
import os
import socket
import sys
import time

home, state_path, log_path = sys.argv[1:4]
sock_path = os.path.join(home, ".semsearch", "daemon.sock")
os.makedirs(os.path.dirname(sock_path), exist_ok=True)
if os.path.exists(sock_path):
    os.unlink(sock_path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(8)


def state():
    with open(state_path) as f:
        return json.load(f)


exit_code = None


def answer(req):
    global exit_code
    if req.get("cmd") == "index":
        with open(log_path, "a") as log:
            log.write("index\n")
        marker = os.path.join(home, ".semsearch", "exited-once")
        code = state().get("exit_on_index")
        if code is not None and not os.path.exists(marker):
            open(marker, "w").close()
            exit_code = code
    if req.get("cmd") == "status":
        with open(log_path, "a") as log:
            log.write(f"{time.time():.3f}\n")
        s = state()
        reply = {"ok": True, "files": s.get("files", 0), "chunks": s.get("chunks", 0),
                 "folders": s.get("folders", []), "indexing": s.get("indexing", False),
                 "model": "fake-model", "model_ready": s.get("model_ready", True)}
        if "progress" in s:
            reply["progress"] = s["progress"]
        return reply
    if req.get("cmd") == "add":
        # A scripted refusal for the folder tests: the state file may name, per folder path, the error an add answers with.
        error = (state().get("add_errors") or {}).get(req.get("path"))
        if error:
            return {"ok": False, "error": error}
    return {"ok": True}


while True:
    conn, _ = srv.accept()
    with conn, conn.makefile("rwb") as f:
        for line in f:
            try:
                resp = answer(json.loads(line))
            except Exception as e:  # a bad request must not stop the stub
                resp = {"ok": False, "error": str(e)}
            f.write((json.dumps(resp) + "\n").encode())
            f.flush()
            if exit_code is not None:
                os._exit(exit_code)
