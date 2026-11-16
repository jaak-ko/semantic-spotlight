#!/usr/bin/env bash
# Compiles the pure redaction function with its assert-based tests and runs them. No app, no I/O beyond a temp dir.
set -euo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-redact.XXXXXX")"
tl_init "$W"
cp tools/redact_tests.swift "$W/main.swift"   # top-level test code is only allowed in main.swift
swiftc -o "$W/redact_tests" Sources/SemanticSpotlight/Redact.swift "$W/main.swift"
"$W/redact_tests"
