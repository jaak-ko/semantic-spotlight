#!/usr/bin/env bash
# Shared by the check scripts. Every process a test starts is recorded with tl_track. On EXIT, INT or TERM the
# test stops what it started, however it was re-parented: the processes it tracked and their children (pgrep -P),
# every process holding a socket inside its temp directory (the engine daemon listens on ~/.semsearch/daemon.sock,
# and the app starts it as a child that can outlive the app), and any disk image mounted inside the temp directory
# (hdiutil detach -force). Then it removes its temp directory and checks that all of that is gone.
# The exit status of the test is kept unless cleanup fails.
# Note: macOS here does not show another process's environment (ps eww and KERN_PROCARGS2 omit it), so HOME cannot
# be used to find a process; the socket path can (lsof -U).
# Every check runs headless: the app puts no status item, menu or window on the user's screen (see Headless.swift).
export SS_HEADLESS=1
TL_PIDS=()
TL_DIR=""
TL_REAL=""   # the temp directory with symlinks resolved (pwd -P)
TL_LSOF=""

tl_init() {   # tl_init <the test's temp directory>
    TL_DIR="$1"
    TL_REAL="$(cd "$1" && pwd -P)"
    TL_LSOF="${TL_REAL#/private}"   # lsof and mount name the path without /private
    trap tl_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

tl_track() {   # tl_track <pid>: a process the test started
    TL_PIDS+=("$1")
}

tl_kill_tree() {   # kills a process and everything it started
    local kid
    for kid in $(pgrep -P "$1" 2>/dev/null); do tl_kill_tree "$kid"; done
    kill -TERM "$1" 2>/dev/null
}

tl_inside_pids() {   # pids of processes that hold a socket or a mounted volume inside TL_DIR
    [ -n "$TL_REAL" ] || return 0
    lsof -U 2>/dev/null | awk -v d="$TL_LSOF/" 'index($0, d) {print $2}' | sort -u
}

tl_cleanup() {
    local status=$? pid bad=0 p mp
    for pid in ${TL_PIDS[@]+"${TL_PIDS[@]}"}; do tl_kill_tree "$pid"; done
    for p in $(tl_inside_pids); do tl_kill_tree "$p"; done
    sleep 1
    for pid in ${TL_PIDS[@]+"${TL_PIDS[@]}"}; do
        for kid in $(pgrep -P "$pid" 2>/dev/null); do kill -KILL "$kid" 2>/dev/null; done
        kill -KILL "$pid" 2>/dev/null
    done
    for p in $(tl_inside_pids); do kill -KILL "$p" 2>/dev/null; done
    sleep 0.5
    for pid in ${TL_PIDS[@]+"${TL_PIDS[@]}"}; do wait "$pid" 2>/dev/null; done   # reap them: a zombie still answers kill -0
    for pid in ${TL_PIDS[@]+"${TL_PIDS[@]}"}; do
        if kill -0 "$pid" 2>/dev/null; then echo "cleanup: process $pid is still running" >&2; bad=1; fi
    done
    if [ -n "$TL_DIR" ]; then
        # Detach any image mounted inside the temp directory. mount prints "<dev> on <mount point> (...)".
        mount | awk -v d="$TL_LSOF/" 'index($0, " on " d) {sub(/^.* on /, ""); sub(/ \(.*$/, ""); print}' | while IFS= read -r mp; do
            hdiutil detach -force -quiet "$mp" 2>/dev/null
        done
        chmod -R u+w "$TL_DIR" 2>/dev/null
        rm -rf "$TL_DIR"
        if [ -e "$TL_DIR" ]; then echo "cleanup: $TL_DIR is still there" >&2; bad=1; fi
        if mount | grep -q -F " on $TL_LSOF/"; then echo "cleanup: an image is still mounted in $TL_REAL" >&2; bad=1; fi
    fi
    if [ "$bad" -eq 0 ]; then echo "cleanup: no test process left running, no temp directory left"
    else echo "cleanup: FAILED" >&2; status=1; fi
    exit "$status"
}

# Samples a process's main thread until one sample shows it idle in the run loop, with no alert and no constraint
# layout. One sample can land on normal layout work (a sheet being drawn for the first time), so up to four samples
# are taken. A real stall shows layout in all of them. Prints the path of the idle sample (or the last one) and
# returns 0 if one was idle, 1 if every sample showed layout work, 2 if the process exited before a sample.
tl_idle_sample() {   # tl_idle_sample <pid> <file prefix> [most samples, default 4]
    local i f main="" max="${3:-4}"
    for i in $(seq "$max"); do
        f="$2-$i.txt"
        kill -0 "$1" 2>/dev/null || { echo "$f"; return 2; }
        sample "$1" 1 -file "$f" >/dev/null 2>&1
        main="$(awk '/com.apple.main-thread|Main Thread/ {on=1; print; next} on && /Thread_[0-9]+/ {on=0} on' "$f" 2>/dev/null)"
        if echo "$main" | grep -q "CFRunLoop" && ! echo "$main" | grep -q -E "NSAlert|NSISEngine|updateConstraintsForSubtreeIfNeeded|layoutSubtreeIfNeeded"; then
            echo "$f"; return 0
        fi
        sleep 0.5
    done
    echo "$f"; return 1
}
