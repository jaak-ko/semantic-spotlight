#!/usr/bin/env python3
# Guard for the user's real engine home (~/.semsearch). Read-only: it lists names, sizes and modification times (never
# contents). `snap <file>` records the listing; `compare <file>` fails with the diff if the home changed during the run.
# While the user's own app (a SemanticSpotlight process that is not a test run) is running, only the names are compared,
# because that app writes its index and logs on its own. The app may start during a run: `watch` samples for it while the
# run goes on (check_all.sh starts it) and leaves a marker file that `compare` reads. In that mode the names the app and
# its engine create themselves are not compared; any other name that appears or disappears still fails.
import os, subprocess, sys, time

HOME_DIR = os.path.expanduser("~/.semsearch")
# The app's and the engine's own files and folders (the names that may change while the user's app runs).
APP_OWNED = {"daemon.sock", "daemon.lock", "app-daemon.log", "index.db", "index.db-wal", "index.db-shm", "cache", "hf",
             "st", "torch", "tmp", "models", "config.json"}

def listing():
    out = {}
    if not os.path.isdir(HOME_DIR):
        return out
    for dirpath, dirnames, filenames in os.walk(HOME_DIR):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, HOME_DIR)
            try:
                st = os.lstat(path)
                out[rel] = (st.st_size, int(st.st_mtime)) if not os.path.isdir(path) else ("dir", 0)
            except OSError:
                out[rel] = ("gone", 0)
    return out

def user_app_running():
    ps = subprocess.run(["ps", "-axww", "-o", "command="], capture_output=True, text=True).stdout
    for line in ps.splitlines():
        if "SemanticSpotlight.app/Contents/MacOS/SemanticSpotlight" in line and "-test-for-test" not in line \
                and "-capture-for-test" not in line and "-dump-ui" not in line:
            return True
    return False

def owned(key):
    return key.split(os.sep)[0] in APP_OWNED or key.startswith("daemon.")


def main():
    mode, path = sys.argv[1], sys.argv[2]
    if mode == "running":   # prints yes when the user's app runs now (the checks skip the prefs mtime then)
        print("yes" if user_app_running() else "no")
        return 0
    if mode == "watch":   # samples for the user's app for the whole run; leaves a marker when it is seen, then stops
        while True:
            if user_app_running():
                open(path + ".seen", "w").close()
                return 0
            time.sleep(2)
    if mode == "snap":
        with open(path, "w") as f:
            for k, v in sorted(listing().items()):
                f.write(f"{k}\t{v[0]}\t{v[1]}\n")
        return 0
    before = {}
    with open(path) as f:
        for line in f:
            k, size, mtime = line.rstrip("\n").split("\t")
            before[k] = (size, mtime)
    after = {k: (str(v[0]), str(v[1])) for k, v in listing().items()}
    names_only = os.path.exists(path + ".seen") or user_app_running()   # running now, or seen during the run
    if names_only:
        before = {k: v for k, v in before.items() if not owned(k)}
        after = {k: v for k, v in after.items() if not owned(k)}
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    changed = [] if names_only else sorted(k for k in set(after) & set(before) if after[k] != before[k])
    if not (added or removed or changed):
        print("real engine home: unchanged during the run" + (" (names only: the user's app is running)" if names_only else ""))
        return 0
    print("FAIL: the real engine home (~/.semsearch) changed during the run:")
    for k in added[:20]: print(f"  added   {k}")
    for k in removed[:20]: print(f"  removed {k}")
    for k in changed[:20]: print(f"  changed {k}: {before[k]} -> {after[k]}")
    return 1

if __name__ == "__main__":
    sys.exit(main())
