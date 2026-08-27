import Foundation
import simd

// (GameState.swift is compiled into the harness now — it supplies `verboseDebugLog`.)

/// GameState references two pure constants from TextureLoader (Metal-bound, not compiled here):
/// the CausticSymbol slice ids and progressMaskBase. This shim mirrors them EXACTLY — if the real
/// enum in TextureLoader.swift gains/reorders cases, update this copy (the compiler can't catch it).
enum TextureLoader {
    enum CausticSymbol: Int, CaseIterable {
        case blank = 0, one, two, three, four, swirl, portal, square, threeOfFour, fourFilled, vessel
    }
    static let progressMaskBase = CausticSymbol.allCases.count
}

// Standalone coordinate-math test runner (Phase 0 / R4).
//
// Compiles the pure-Swift model sources (no Metal) together with this file and
// exercises the invariants that the M8 rotation bug violated, across cube sizes
// 3/5/7/9. Run with Tests/run-tests.sh — exits non-zero on any failure.
//
// Covered:
//   1. Projection is a bijection — every (face,row,col) maps to one unique facelet.
//   2. gridPosition ↔ worldMatrix consistency — adjacent grid cells belong to
//      cubies whose integer positions differ by exactly the face tangent/bitangent.
//      (This is the exact invariant that broke in M8.)
//   3. EdgeCrossing round-trips — crossing an edge and coming back returns you home.
//   4. Slice rotation — projection stays bijective after a turn; four quarter turns
//      restore every cubie position.
//   5. DirectionMask.rotated — rotation algebra (identity, composition, negatives).
//   6. Prop.rotate — a placed prop stays glued to its tile: four quarter-turns restore
//      its sub-cell + facing, 0 turns is a no-op, −1 == 3, and the rotation sense matches
//      DirectionMask (N→E). Guards the Rubik's split's correctness at the math level (the
//      cheap insurance the M12-E house-split verification called for).

@main
struct CoordinateMathTests {
    static var passed = 0
    static var failed = 0
    static var failures: [String] = []

    static func check(_ cond: Bool, _ msg: @autoclosure () -> String) {
        if cond { passed += 1 } else { failed += 1; failures.append(msg()) }
    }

    static func main() {
        let sizes = [3, 5, 7, 9, 11, 25]   // 11 = the garden world; 25 = the R2.16 hard cap — the math must hold at the ceiling
        for n in sizes {
            testProjectionBijection(size: n)
            testGridWorldConsistency(size: n)
            testEdgeCrossingRoundTrip(size: n)
            testSliceRotation(size: n)
            testBandagedLegality(size: n)
            testRestPlacement(size: n)
            testFootprintContinuity(size: n)
            testInteriorPlacement(size: n)
            testEdgeContinuity(size: n, interior: false)
            testEdgeContinuity(size: n, interior: true)
            testStandGridCrossing(size: n, interior: false)
            testStandGridCrossing(size: n, interior: true)
        }
        testStandableRules()
        testPropFootprint()
        testPropConnectivity()
        testReliefField()
        testPlayerKnowledge()
        testDirectionMaskRotation()
        testPropRotation()
        testInflateGoldens()
        testSizeCap()
        testStandGridPathCross()
        testWalkThroughPortalGating()
        testTopologyVersionCaches()
        testFaceletAtBoundsFullFace()
        testPortalTransitionsAreExplicit()
        testSceneTwoHiddenFaceTurnsIntoView()
        testSceneTwoLockGatesTheTurn()
        testSceneTwoSpawnsInTheMaze()
        testSceneTwoExitIsWalkableOnlyAfterTheTurn()
        testSceneFourAnchorsGateThePlayersTwist()
        testEveryPrologueSceneHasADarsitDoor()
        testSceneFourBondBandsTraceTheLock()
        testSceneFourStrainGrowsAsAnchorsRelease()
        testSceneFourHangsSceneTwoOverhead()
        testSkyCounterpartIsTheSameWorldYouCanVisit()
        testSceneFourVesselReadsTheLock()
        testVesselCanBeApproached()
        testSceneOneCanBeWalkedFromClearingToArch()
        testSceneOneAmbienceTriggers()
        testWorldsPlaceThePlayerWhereTheySay()
        testInteriorsDoNotSpin()
        testSceneFiveIsSolvableAndCanBeMadeWorse()
        testSceneFiveVesselsMirrorLocalTruthNotProgress()
        testTheWorldModelFollowsItsPlinthThroughATwist()
        testTheWorldModelTurnsItsFaceToTheViewer()
        testAPrologueWorldIsTheSamePlaceHoweverYouReachIt()
        testTheInteriorStaysSolvedBetweenVisits()
        testAWorldCanNameADifferentDoorPerRoute()
        testSceneSixArrivesWhereSceneTwoCouldNotReach()
        testSceneTwoCanActuallyBeSolved()
        testSceneOneCanBeWalkedToItsArch()
        testSceneThreeCanBeSolvedByPressingItsPlinths()
        testSceneFourReleasesItsAnchorsAndThenTurns()
        testSceneFourCannotBeStrandedByOrder()
        testSceneFiveCanBeSolvedByTurningItBack()
        testNoSceneHandsOutItsExitEarly()
        testEveryDoorKnowsWhatItIsCalled()
        testTheUndersideIsDressedWithoutChangingIt()
        testAScriptedTurnWaitsRatherThanVanishing()
        testSceneFiveCanBeSolvedByItsRotatorsAlone()
        testSceneFiveFixturesAndCompletion()
        testSceneSixLatchesHatchAndRouteKeyedPortal()
        testTheSurveyorBuildsOnlyFromLiveCurrent()
        testInteractionOrderIsTheContract()
        testThePropIndexMatchesAFullSweep()
        testSceneFivePulseStopsWhereTheRouteDoes()
        testSceneFiveExitStandsAtTheEndOfTheCurrent()
        testTwistsLeaveTheTopologyConsistent()
        testThePrologueScenesLeadToEachOther()
        testSceneTwoQuadrantsDifferButAreNotColourCoded()
        testOnlySceneThreeAsksForAtmosphericDepth()
        testSceneThreePairsPlinthsToDistantObelisks()
        testSceneThreeWakesInStagesAndFiresItsWaveOnce()
        testSealedWorldsCannotBeWalkedOutOf()
        testSealSurvivesTheScriptedTurn()
        testSightGoesDownCorridorsNotJustOntoTheNextTile()
        testVesselsMoveOnlyWhenNotWatched()
        testInteractPicksTheNearestThingNotThePortal()
        testCrossingAnOpenEdgeAlwaysFindsSomewhereToLand()
        testFlatPropsDoNotWallOffTheirOwnTile()
        testEveryStampHasConsistentEdges()
        testClosingDoorwayLeavesTheRealPortalAlone()
        testSceneFourRouteCompletesOnlyAfterTheTurn()
        testAudioEmittersRideTwistsAndAreOccludedByWalls()
        testVesselInspectionGrantsTheTwist()
        testDressedWorldsDoNotFenceOffOpenEdges()
        testJitteredSolidPropsBlockWhereTheyAreDrawn()
        testDressedWallDressingIsNotAFence()

        print("")
        if failed == 0 {
            print("✅ All \(passed) checks passed across sizes \(sizes).")
        } else {
            print("❌ \(failed) checks FAILED (\(passed) passed):")
            for f in failures.prefix(50) { print("   - \(f)") }
            if failures.count > 50 { print("   … and \(failures.count - 50) more") }
            exit(1)
        }
    }

}
