import Metal
import MetalKit
import simd

/// B1 — the MAZEN_BENCH reporting path, out of the frame code's way. The counters themselves are
/// stored properties and stay declared on the class; this is the logging and the cadence.
extension Renderer {
    func logBenchSample() {
        let p = gameState.perf
        NSLog("BENCH   cull kills/frame: horizon %d, frustum %d  |  KILLED WHILE PLAINLY IN VIEW: %d",
              Renderer.benchHorizonKills / 120, Renderer.benchFrustumKills / 120,
              Renderer.benchInViewKilled / 120)
        Renderer.benchHorizonKills = 0; Renderer.benchFrustumKills = 0; Renderer.benchInViewKilled = 0
        NSLog("BENCH   camera: %@", gameState.camera.mode == .orbit ? "orbit" : "first-person")
        NSLog("BENCH   cull: enabled=%d horizon=%d eye=(%.2f %.2f %.2f) |eye|=%.2f faceDist=%.2f roundness=%.2f",
              cullPlanes.count == 6 ? 1 : 0, gameState.worldScale.interior ? 0 : 1,
              cullEye.x, cullEye.y, cullEye.z, simd_length(cullEye),
              gameState.worldScale.faceDistance, gameState.cubeModel.roundness)
        NSLog("BENCH   assets: clearBuckets %.2f  dressedWalls %.2f  (buckets %d, dressed rebuilds %d/120 frames, style %@)",
              benchClearMs / 120, benchDressedMs / 120, assetBuckets.count,
              CubeModel.benchDressedRebuilds, String(describing: gameState.cubeModel.wallStyle))
        benchDressedMs = 0; CubeModel.benchDressedRebuilds = 0
        benchClearMs = 0
        NSLog("BENCH   assets: propTiles() %.2f  placeProp %.2f  pack %.2f  |  %d tiles, %.0f props/frame, %d drawn of %d (culled %d, cap %d)",
              benchPropTilesMs / 120, benchPlaceMs / 120, benchPackMs / 120,
              benchPropTileCount, Float(benchPropCount) / 120, benchAssetInstances, benchAssetDemand,
              benchCulled / 120, assetInstanceBuffers[0].length / MemoryLayout<InstanceDataSwift>.stride)
        benchCulled = 0
        benchPropTilesMs = 0; benchPlaceMs = 0; benchPackMs = 0; benchPropCount = 0
        NSLog("BENCH   build split: frameUniforms %.2f  assetInstances %.2f  buildDrawCalls %.2f",
              subUniformsMs / 120, subAssetsMs / 120, subDrawCallsMs / 120)
        subUniformsMs = 0; subAssetsMs = 0; subDrawCallsMs = 0
        NSLog("BENCH   phases/frame: tileLoop %.2f ms  rest %.2f ms  (counterpart build %.2f ms)",
              SceneBuilder.phaseTileLoopMs / 120, SceneBuilder.phaseRestMs / 120, counterpartBuildMs / 120)
        SceneBuilder.phaseTileLoopMs = 0; SceneBuilder.phaseRestMs = 0; counterpartBuildMs = 0
        NSLog("BENCH %@ size=%d  frame %.2f ms (%.0f fps)  cpu %.2f = update %.2f + build %.2f + encode %.2f  |  wait-on-gpu %.2f  |  draws %d  instances %d",
              gameState.name, gameState.cubeModel.size, gameState.avgFrameTimeMs,
              gameState.avgFrameTimeMs > 0 ? 1000 / gameState.avgFrameTimeMs : 0,
              p.cpuTotal, p.update, p.build, p.encode, p.wait, p.drawCalls, p.instances)
        benchFramesRemaining -= 120
        if benchFramesRemaining <= 0 { NSLog("BENCH done"); exit(0) }
    }

}
