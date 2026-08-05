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
    "$SHARED/Stamps/StampSceneOne.swift" \
    "$SHARED/Stamps/StampSceneTwo.swift" \
    "$SHARED/Stamps/StampSceneThree.swift" \
    "$SHARED/Stamps/StampSceneFour.swift" \
    "$SHARED/Stamps/StampSceneFive.swift" \
    "$SHARED/Stamps/StampSceneSix.swift" \
    "$SHARED/PlayerState.swift" \
    "$SHARED/PlayerKnowledge.swift" \
    "$SHARED/CameraState.swift" \
    "$SHARED/CelestialSystem.swift" \
    "$SHARED/GameState.swift" \
    "$SHARED/GameStateSceneFive.swift" \
    "$SHARED/GameStateSceneSix.swift" \
    "$SHARED/WorldGraph.swift" \
    "Tests/CoordinateMathTests.swift" \
    -o "$OUT"

"$OUT"
