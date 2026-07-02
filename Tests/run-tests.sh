#!/bin/sh
# Phase 0 / R4 — standalone coordinate-math test runner.
# Compiles the pure-Swift model sources (no Metal) together with the test file
# and runs them. Exits non-zero on any failed check.
set -e
cd "$(dirname "$0")/.."
SHARED="Mazen_Claude Shared"
OUT="$(mktemp -d)/mazen-coord-tests"

swiftc -O \
    "$SHARED/WorldScale.swift" \
    "$SHARED/CubeTypes.swift" \
    "$SHARED/EdgeCrossing.swift" \
    "$SHARED/CubeModel.swift" \
    "Tests/CoordinateMathTests.swift" \
    -o "$OUT"

"$OUT"
