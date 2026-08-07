import Metal
import MetalKit
import simd

/// B1 — the imported-prop half of the Renderer: pack palettes, the instance buckets and their
/// cache, and the pack-time culling. Moved verbatim from Renderer.swift. A1 (shadow-caster
/// subset) and A2 (LOD) land in this file.
extension Renderer {
    func packIndices(_ prefix: String) -> [Int] {
        importedProps.enumerated().filter { $0.element.name.hasPrefix(prefix) }.map { $0.offset }
    }

    /// M20 — resolve one imported model by its exact registry name (e.g. "Ruins Arch_Round"), for
    /// composing the portal-style prototypes. `nil` if the pack/model isn't loaded.
    func namedProp(_ name: String) -> Int? { importedProps.firstIndex { $0.name == name } }

    /// M20 — the MegaKit's rock-path stone models, for the gallery path-stone prototype.
    func pathStones() -> [Int] {
        importedProps.enumerated()
            .filter { $0.element.name.hasPrefix("MegaKit ") && $0.element.name.contains("RockPath") }
            .map { $0.offset }
    }

    /// M20 — group the flat-shaded Nature pack models by kind (from their registry `name`, e.g.
    /// "Nature PineTree_2") so the garden scatter can place trees/bushes/flowers/grass/rocks. Snow
    /// and dead variants are held back to keep the garden lush and temperate (easy to add later).
    func gardenFlora() -> CubeModel.GardenFlora {
        var f = CubeModel.GardenFlora()
        for (i, p) in importedProps.enumerated() {
            let name = p.name
            func has(_ s: String) -> Bool { name.range(of: s, options: .caseInsensitive) != nil }
            if !name.hasPrefix("Nature ") || has("Snow") || has("Dead") { continue }
            if has("Rock")                                    { f.rocks.append(i) }
            else if has("Bush")                               { f.bushes.append(i) }
            else if has("Tree") || has("Willow")              { f.trees.append(i) }   // Palm/Pine/Birch/Common/Willow
            else if has("Grass") || has("Wheat") || has("Corn") { f.grasses.append(i) }
            else if has("Flower")                             { f.flowers.append(i) }
            else if has("Plant")                              { f.grasses.append(i) }
        }
        return f
    }

    /// M20 — the wall-builder's palette (Eddie): a natural/ruined wall built from **Ruins `Wall`
    /// pieces** for the structural backbone, plus **rocks** (Nature) and **bushes** (Nature + Ruins)
    /// packed at the base to overgrow it. Snow variants excluded (temperate). Reuses `GardenFlora`'s
    /// `walls`/`rocks`/`bushes` fields.
    /// SCENE 6C — the machinery under a world's skin. Quaternius' Cyberpunk kit, structural half
    /// only: "The player can see supports, seams, braces, and machinery that were never visible from
    /// the original route." Grouped by what a piece IS, so the stamp can put uprights where a floor
    /// needs holding up and runs where something has to be carried across.
    func undersideMachinery() -> CubeModel.UndersideMachinery {
        var m = CubeModel.UndersideMachinery()
        for (i, p) in importedProps.enumerated() where p.name.hasPrefix("Cyberpunk ") {
            let name = p.name
            func has(_ s: String) -> Bool { name.range(of: s, options: .caseInsensitive) != nil }
            if has("Support") || has("Antenna")            { m.uprights.append(i) }
            else if has("Pipe") || has("Cable")            { m.runs.append(i) }
            else if has("AC") || has("Computer")           { m.boxes.append(i) }
            else if has("Rail") || has("Fence")            { m.rails.append(i) }
            else if has("Platform")                        { m.plates.append(i) }
            else if has("Light")                           { m.lamps.append(i) }
        }
        return m
    }

    func wallFlora() -> CubeModel.GardenFlora {
        var f = CubeModel.GardenFlora()
        for (i, p) in importedProps.enumerated() {
            let name = p.name
            func has(_ s: String) -> Bool { name.range(of: s, options: .caseInsensitive) != nil }
            if has("Snow") { continue }
            if name.hasPrefix("Ruins ") && has("Wall") && !has("Flag") && !has("Arch") { f.walls.append(i) }   // ArchRound + ArchGothic too holey (Eddie); Wall_Half kept (clean half-width)
            else if has("Path")                                                   { continue }   // MegaKit RockPath = paths, not wall rocks
            else if (has("Rock") && name.hasPrefix("Nature "))
                 || (name.hasPrefix("MegaKit ") && (has("Rock") || has("Pebble"))) {
                f.rocks.append(i)                                                                 // + textured MegaKit rocks
                if name.hasPrefix("MegaKit ") && (has("Rock_Big") || has("Rock_Medium")) { f.bigRocks.append(i) }   // big/medium boulders
            }
            else if has("Bush")                                                    { f.bushes.append(i) }   // Nature / Ruins / MegaKit bushes
        }
        return f
    }

    /// Place every imported prop for the frame. Both the decorations (`.importedAsset`, single mesh
    /// from the registry) and the modular house (`.houseCorner`, kit assembly) are now anchored to
    /// facelets and scanned here, so they ride the slice `animMat` (worldMatrix → animMat → spin →
    /// sub-cell → facing) and are carried by `Prop.rotate` — the arena decorations turn with their
    /// slice exactly like the house. Scans by (face,row,col) so a prop carried to a neighbouring
    /// face reports its new position.
    /// Is this prop worth submitting? Two tests, both with a generous margin, because an instance
    /// dropped here loses its SHADOW as well as itself — the shadow pass draws from the same buffer.
    ///
    ///   - Behind the planet. Props sit on the surface of a world centred at the origin, so a point
    ///     whose outward normal turns away from the eye is over the horizon. This is the one that
    ///     matters in orbit, where the frustum holds the whole world and half of it is the far side.
    ///   - Outside the frustum. This is the one that matters on foot, where nearly everything on a
    ///     19 m-tile world is somewhere behind you.
    /// Everything the test needs, in registers. The first version of this called a method that did
    /// `ablate.contains("cull")` and walked an `[SIMD4]` — a string hash and an array bounds-check
    /// per instance, 20,000 times a frame, which cost 10 ms of CPU to save 3 ms of GPU. Hoisting the
    /// lot into locals is the whole difference between a win and a loss.
    private struct CullFrustum {
        var p0, p1, p2, p3, p4, p5: SIMD4<Float>
        /// The eye in the world's OWN (unspun) frame, so a prop can be tested against the geometry
        /// it was authored in — see `surfaceNormal`.
        var eyeRest: SIMD3<Float>
        var enabled: Bool
        /// The far-side test runs only from ORBIT, and only from outside the world's bounding
        /// sphere. It used to be gated on `|eye| > faceDistance × 1.35`, which a WALKING PLAYER
        /// crosses: on a 5³ world the eye is 2.59 units out at the middle of a face and 4.38 at a
        /// corner, so the test switched itself on as Eddie walked toward one and took the walls with
        /// it. A threshold that the thing it is meant to exclude can wander across is not a gate.
        var horizon: Bool
        var roundness: Float
        var backface: Float

        /// The OUTWARD NORMAL at a surface point, in the rest frame. `p̂` is exact on a sphere and
        /// wrong by up to 55° at a cube's corners — which is why chunks went missing near the edges
        /// of faces seen obliquely from orbit: their `p̂` tilts away from the face they belong to.
        /// A cube's normal is its dominant axis; blend the two by roundness and both worlds are right.
        @inline(__always) func surfaceNormal(_ pr: SIMD3<Float>, _ inv: Float) -> SIMD3<Float> {
            let a = abs(pr)
            let axis: SIMD3<Float> = (a.x >= a.y && a.x >= a.z) ? SIMD3(pr.x < 0 ? -1 : 1, 0, 0)
                                   : (a.y >= a.z)               ? SIMD3(0, pr.y < 0 ? -1 : 1, 0)
                                                                : SIMD3(0, 0, pr.z < 0 ? -1 : 1)
            let radial = pr * inv
            let n = axis + (radial - axis) * roundness
            let l = simd_length(n)
            return l > 1e-6 ? n / l : radial
        }

        /// `pr` is the prop in the rest frame; `p` the same prop spun into the world, for the planes.
        @inline(__always) func hides(rest pr: SIMD3<Float>, world p: SIMD3<Float>) -> Bool {
            guard enabled else { return false }
            let r2 = simd_length_squared(pr)
            if horizon, r2 > 1e-8 {
                let toEye = eyeRest - pr
                let t2 = simd_length_squared(toEye)
                if t2 > 1e-8 {
                    let n = surfaceNormal(pr, 1 / r2.squareRoot())
                    if simd_dot(n, toEye * (1 / t2.squareRoot())) < backface {
                        Renderer.benchHorizonKills += 1
                        return true
                    }
                }
            }
            let m = Renderer.cullMargin
            if simd_dot(SIMD3(p0.x, p0.y, p0.z), p) + p0.w < -m { Renderer.benchFrustumKills += 1; return true }
            if simd_dot(SIMD3(p1.x, p1.y, p1.z), p) + p1.w < -m { Renderer.benchFrustumKills += 1; return true }
            if simd_dot(SIMD3(p2.x, p2.y, p2.z), p) + p2.w < -m { Renderer.benchFrustumKills += 1; return true }
            if simd_dot(SIMD3(p3.x, p3.y, p3.z), p) + p3.w < -m { Renderer.benchFrustumKills += 1; return true }
            if simd_dot(SIMD3(p4.x, p4.y, p4.z), p) + p4.w < -m { Renderer.benchFrustumKills += 1; return true }
            if simd_dot(SIMD3(p5.x, p5.y, p5.z), p) + p5.w < -m { Renderer.benchFrustumKills += 1; return true }
            return false
        }
    }

    /// World units. A tile is 1.0 and the tallest dressed props stand well under half of one, so
    /// this is roughly two tiles of slack for shadows cast in from off-screen.
    private static let cullMargin: Float = 2.0

    /// The ACTIVE world's imported props — and, since 2026-08-06, the SKY world's as well.
    ///
    /// See `Mazen Docs/Sky Worlds — Dressing the Counterpart.md`. The counterpart is "the real world
    /// hanging overhead, with every twist baked in", but only its `SceneBuilder` geometry was ever
    /// drawn; everything imported lives on this path, which read `gameState` and nothing else. So the
    /// sky showed no portal frames, no dressed walls, no vegetation, no machinery — and a `.dressed`
    /// world, whose hedge mesh is suppressed *because* its walls are imported props, hung up there as
    /// a bare plate. It got worse with every world we dressed, which is what Eddie noticed.
    func updateAssetInstances() {
        assetDrawCmds.removeAll(keepingCapacity: true)
        guard !importedProps.isEmpty || !houseAssembly.isEmpty else { return }
        assetDrawCmds = buildAssetInstances(for: gameState, offset: matrix_identity_float4x4,
                                            buffer: assetInstanceBuffers[currentBufferIndex],
                                            isCounterpart: false)
        counterpartAssetDrawCmds = []
        if let cp = frameCounterpart, skyWorldIsOnScreen(cp) {
            let t0 = CACurrentMediaTime()
            counterpartAssetDrawCmds = buildAssetInstances(
                for: cp.world, offset: cp.offset,
                buffer: counterpartAssetInstanceBuffers[currentBufferIndex], isCounterpart: true)
            benchCounterpartAssetMs += Float(CACurrentMediaTime() - t0) * 1000
        }
        pruneAssetCaches()
    }

    /// Is the sky world anywhere on screen? Measured: with it off-screen the props pass still cost
    /// 4.2 ms a frame (Debug) testing ~19,000 instances against the frustum one at a time, for a
    /// world nobody could see. One sphere test answers for all of them.
    ///
    /// The sphere is the world's CORNER radius (`faceDistance·√3`, the same bound the horizon cull
    /// uses) times the orbital scale, centred on the offset's translation. Deliberately generous:
    /// culling a sky world that is actually visible would reproduce the exact bug this change fixes.
    func skyWorldIsOnScreen(_ cp: (world: GameState, offset: float4x4)) -> Bool {
        // `MAZEN_BENCH_ABLATE=cull` must reach this too, or the one lever that can force the sky
        // world's props through the whole pipeline stops working — which is exactly how I verified
        // this feature in the first place, the bench camera never happening to face the moon.
        guard cullPlanes.count == 6, !ablate.contains("cull") else { return true }
        let c = cp.offset.position
        let scale = simd_length(SIMD3(cp.offset.columns.0.x, cp.offset.columns.0.y, cp.offset.columns.0.z))
        let r = cp.world.worldScale.faceDistance * 1.732 * scale + Renderer.cullMargin
        for plane in cullPlanes where simd_dot(SIMD3(plane.x, plane.y, plane.z), c) + plane.w < -r {
            return false
        }
        return true
    }

    /// Drop the bucket cache of any world that is neither underfoot nor overhead. Without this every
    /// world the player has ever visited keeps a full set of instance arrays alive for the life of
    /// the app — and the garden's is 1,500+ props.
    private func pruneAssetCaches() {
        guard assetCaches.count > worldStack.count + 1 else { return }
        var live = Set(worldStack.map(ObjectIdentifier.init))
        if let cp = frameCounterpart { live.insert(ObjectIdentifier(cp.world)) }
        assetCaches = assetCaches.filter { live.contains($0.key) }
    }

    /// Build one world's props into `buffer`. `offset` pushes the whole world out to its orbital
    /// position (identity for the world you are standing in).
    private func buildAssetInstances(for world: GameState, offset: float4x4, buffer: MTLBuffer,
                                     isCounterpart: Bool) -> [AssetDrawCmd] {
        var cmds: [AssetDrawCmd] = []
        let cache = assetCaches[ObjectIdentifier(world)] ?? {
            let c = WorldAssetCache(); assetCaches[ObjectIdentifier(world)] = c; return c
        }()
        let cap = buffer.length / MemoryLayout<InstanceDataSwift>.stride
        let ptr = buffer.contents().bindMemory(to: InstanceDataSwift.self, capacity: cap)
        let ws = world.worldScale
        // The offset is folded into the spin — the SAME single injection point `SceneBuilder.build`
        // uses for the counterpart's maze, and for the same reason: every prop matrix is built as
        // `spin * …`, so one multiply moves the whole world into the sky.
        let spin = offset * world.worldSpinMatrix()
        let model = world.cubeModel
        let sr = world.sliceRotation
        let sliceMat = sr.currentMatrix   // single source: SliceRotation (R2.3)
        let step = ws.subCellStep
        // PERF — clear the persistent buckets, keeping their capacity (entries persist across frames).
        // PERF — the buckets are a CACHE now. Rebuilding them was 18 of Scene 2's 28 ms per frame
        // (measured: `MAZEN_BENCH=scene-2`), and almost none of it was ever different from the frame
        // before. A twist rebuilds every frame while it is in flight, because the slice matrix moves
        // the props it carries; everything else waits for the world to actually change.
        let token = AssetCacheToken(world: ObjectIdentifier(world),
                                    worldName: world.name,
                                    topology: model.topologyVersion,
                                    twisting: sr.isActive,
                                    twistFrame: sr.isActive ? frameIndex : 0,
                                    roundness: model.roundness,
                                    relief: model.reliefAmplitude,
                                    paletteSize: wallDressingPalette.walls.count
                                        + wallDressingPalette.rocks.count + wallDressingPalette.bushes.count,
                                    assetsLoaded: importedProps.count + houseAssembly.count)
        let rebuild = token != cache.token || ablate.contains("assetcache")
        cache.token = token
        let tClear0 = CACurrentMediaTime()
        if rebuild {
            // `Array(keys)` deliberately: iterating the dictionary's own keys view while mutating it
            // through the subscript keeps a second reference to the storage alive, which turns every
            // in-place mutation into a full copy of the dictionary.
            for key in Array(cache.buckets.keys) { cache.buckets[key]?.instances.removeAll(keepingCapacity: true) }
        }
        benchClearMs += Float(CACurrentMediaTime() - tClear0) * 1000

        // Accumulate one instance into its (mesh, submesh, texture) bucket — packed + drawn instanced below.
        func bucketAppend(_ mesh: AssetMesh, indexOffset: Int, indexCount: Int,
                          diffuse: MTLTexture?, cutout: Bool, _ data: InstanceDataSwift) {
            let key = AssetBucketKey(indexBuffer: ObjectIdentifier(mesh.indexBuffer),
                                     indexOffset: indexOffset,
                                     diffuse: diffuse.map(ObjectIdentifier.init))
            if cache.buckets[key] == nil {
                let dim = max(mesh.size.x, max(mesh.size.y, mesh.size.z))
                cache.buckets[key] = AssetBucket(vertexBuffer: mesh.vertexBuffer, indexBuffer: mesh.indexBuffer,
                                                indexOffset: indexOffset, indexCount: indexCount,
                                                diffuse: diffuse, cutout: cutout, meshMaxDim: dim)
            }
            cache.buckets[key]?.instances.append(data)
        }

        // Emit one flat-colour sub-mesh or a whole textured mesh at `m`.
        func emit(_ mesh: AssetMesh, _ m: float4x4, diffuse: MTLTexture?, submeshMaterials: [SubmeshMaterial] = []) {
            // Per-sub-mesh textures (a Quaternius tree: bark map + leaf map). One bucket per sub-mesh,
            // each binding its own diffuse; a sub-mesh with no texture keeps its flat `Kd` colour.
            // A diffuse carrying alpha (leaves/flowers) uses the cutout material (20) instead of 11.
            if !submeshMaterials.isEmpty {
                for (i, sm) in mesh.submeshes.enumerated() {
                    let mat = i < submeshMaterials.count ? submeshMaterials[i] : SubmeshMaterial(diffuse: nil, cutout: false)
                    let matID: UInt32 = mat.diffuse == nil ? 10 : (mat.cutout ? 20 : 11)
                    bucketAppend(mesh, indexOffset: sm.indexOffset, indexCount: sm.indexCount,
                                 diffuse: mat.diffuse, cutout: mat.cutout,
                                 InstanceDataSwift(modelMatrix: m,
                                                   baseColor: mat.diffuse != nil ? SIMD4(1, 1, 1, 1) : sm.color,
                                                   materialID: matID,
                                                   tileID: 0, discoveryAmount: 1.0, styleSeed: 0))
                }
                return
            }
            if let diff = diffuse {
                bucketAppend(mesh, indexOffset: 0, indexCount: mesh.totalIndexCount, diffuse: diff, cutout: false,
                             InstanceDataSwift(modelMatrix: m, baseColor: SIMD4(1,1,1,1), materialID: 11, tileID: 0, discoveryAmount: 1.0, styleSeed: 0))
            } else {
                for sm in mesh.submeshes {
                    bucketAppend(mesh, indexOffset: sm.indexOffset, indexCount: sm.indexCount, diffuse: nil, cutout: false,
                                 InstanceDataSwift(modelMatrix: m, baseColor: sm.color, materialID: 10, tileID: 0, discoveryAmount: 1.0, styleSeed: 0))
                }
            }
        }

        // Place ONE prop on the tile whose rest matrix is `base`. M14b: seat each rigid asset at the
        // inflated sub-cell footprint, tilted to the local surface normal (roundness==0 → flat, exactly
        // as before). Then facing + slice animation + spin. The asset stays rigid (its instance
        // roundness stays 0); only its anchor rides the curve. Shared by the stored props and the
        // dynamic dressed walls. PERF: `base` is computed once per TILE by the callers (was a fresh
        // restMatrix per prop — the garden places 1500+ props/frame).
        func placeProp(_ prop: Prop, base: float4x4, ci: Int) {
            let localX = Float(prop.subCol - 1) * step + prop.offsetX
            let localY = Float(prop.subRow - 1) * step + prop.offsetY
            var placement = model.inflatedPlacement(base: base, localX: localX, localY: localY)
            if sr.isActive && sr.affectedCubies.contains(ci) { placement = sliceMat * placement }
            // NO SPIN HERE. The world's idle spin is one matrix common to every instance, so baking
            // it in per prop is what made this whole pass per-frame work: everything else a prop's
            // matrix depends on (topology, slice, roundness, relief) only changes when the world
            // does. Spin is applied once per instance at pack time instead, which leaves these
            // buckets cacheable across frames.
            let tileM = placement
                * float4x4.rotation(radians: Float(prop.facing.rawValue) * (.pi / 4), axis: SIMD3(0, 0, 1))
            switch prop.kind {
            case .importedAsset, .importedFoliage:
                guard prop.state >= 0 && prop.state < importedProps.count else { return }
                let p = importedProps[prop.state]
                // Fit the widest dimension to `target`, stand it up (Y-up OBJ → tile Z-up),
                // centre the footprint, rest the base on the floor. Garden foliage then
                // scales by its per-instance `extraScale` (trees big, flowers small).
                let dim = p.mesh.size
                let maxDim = max(dim.x, max(dim.y, dim.z))
                let userScale: Float = prop.kind == .importedFoliage ? prop.extraScale : 1
                let fs: Float = (maxDim > 0 ? p.target / maxDim : 1) * userScale
                let c = p.mesh.center
                // Y-up kits rotate +90° about X so mesh +Y becomes world +Z. An INVERTED model turns
                // the other way (−90°), which puts mesh +Y at world −Z — upside down — and then the
                // face that must rest on the floor is the mesh's TOP, so the seating height comes
                // from `boundsMax` rather than `boundsMin`, and the centring flips sign with it.
                // `laidFlat` simply declines the Y-up rotation, which leaves the model's length
                // along the ground instead of standing on end.
                let standing = p.yUp && !p.laidFlat
                let orient = standing
                    ? float4x4.rotation(radians: p.inverted ? -.pi / 2 : .pi / 2, axis: SIMD3(1, 0, 0))
                    : matrix_identity_float4x4
                let ty = standing ? (p.inverted ? -c.z * fs : c.z * fs) : -c.y * fs
                // Rest the base on the floor, then bury by `sink`·height so rounded
                // rocks/bushes seat instead of balancing on their lowest vertex.
                let heightU = (standing ? p.mesh.size.y : p.mesh.size.z) * fs
                // An INVERTED model rests on its BULK, not on its highest vertex: seating a platform
                // on a lone railing post leaves the deck hanging in the air with a spike holding it
                // up, which is exactly what Eddie circled.
                let restOn = standing ? (p.inverted ? -p.mesh.broadTopY : p.mesh.boundsMin.y)
                                      : p.mesh.boundsMin.z
                let tz = ws.floorY - restOn * fs - prop.sink * heightU
                let m = tileM * float4x4.translation(-c.x * fs, ty, tz) * float4x4.scale(fs) * orient
                emit(p.mesh, m, diffuse: p.diffuse, submeshMaterials: p.submeshMaterials)
            case .houseCorner:
                let assembly = prop.facing == .s ? houseAssemblyDoor : houseAssembly
                for piece in assembly { emit(piece.mesh, tileM * piece.local, diffuse: nil) }
            default:
                break
            }
        }

        // PERF: iterate only the facelets that CARRY props (cached per topologyVersion) instead of
        // scanning all 6×n² tiles per frame. Prop fields are read live; a twist bumps the version.
        let tPT0 = CACurrentMediaTime()
        if rebuild {
        let entries = model.propTiles()
        let tPT1 = CACurrentMediaTime()
        benchPropTilesMs += Float(tPT1 - tPT0) * 1000
        benchPropTileCount = entries.count
        for e in entries {
            // Nothing stands on a tile you have never seen. This path never checked, so in a fogged
            // world the trees and vessels floated in the mist while the walls beside them did not
            // exist yet — which is what made Scene 1 look like it was being built as Eddie walked.
            guard model.cubies[e.ci].facelets[e.fi].tileState != .unknown else { continue }
            let base = model.restMatrix(face: e.face, row: e.row, col: e.col)
            let props = model.cubies[e.ci].facelets[e.fi].props
            benchPropCount += props.count
            for prop in props { placeProp(prop, base: base, ci: e.ci) }
        }
        benchPlaceMs += Float(CACurrentMediaTime() - tPT1) * 1000
        }

        // M20 — DYNAMIC dressed walls (twist-safe stone walls). For a `.dressed` world the hedge mesh is
        // suppressed; instead we emit imported wall MODELS on every closed edge of each discovered tile,
        // re-derived from the live topology — so a slice-twist carries the walls with their tiles exactly
        // like the hedge mesh. PERF: the derivation is cached per topologyVersion (a twist/discovery
        // re-derives everything); PLACEMENT stays per-frame (placeProp applies the live slice matrix),
        // so mid-twist animation still swings the walls with their slice.
        let tDressed0 = CACurrentMediaTime()
        if rebuild, model.wallStyle == .dressed, (!wallDressingPalette.walls.isEmpty
                                           || !wallDressingPalette.rocks.isEmpty
                                           || !wallDressingPalette.bushes.isEmpty) {
            let mUnit = ws.eyeHeight / 1.7
            let wallScale = 4.0 * mUnit / 0.85            // ~4 m wide, matching the hedges they replace
            let rockScale = wallScale * 0.7, bushScale = wallScale * 0.5
            let pal = wallDressingPalette
            for entry in model.dressedWallEntries(walls: pal.walls, rocks: pal.rocks, bushes: pal.bushes,
                                                  wallScale: wallScale, rockScale: rockScale, bushScale: bushScale) {
                let base = model.restMatrix(face: entry.loc.face, row: entry.loc.row, col: entry.loc.col)
                for prop in entry.props { placeProp(prop, base: base, ci: entry.loc.ci) }
            }
        }

        benchDressedMs += Float(CACurrentMediaTime() - tDressed0) * 1000
        // PERF — pack the buckets: write each bucket's instances contiguously into the shared buffer
        // and emit ONE instanced draw command per bucket. 500 copies of the same wall piece = 1 draw
        // (was 500, and 500 more in the shadow pass). Buckets that overflow the buffer are clamped,
        // same silent-cap behaviour as the old per-instance path.
        let tPack0 = CACurrentMediaTime()
        let cull = CullFrustum(p0: cullPlanes.count == 6 ? cullPlanes[0] : SIMD4(0, 0, 0, 1),
                               p1: cullPlanes.count == 6 ? cullPlanes[1] : SIMD4(0, 0, 0, 1),
                               p2: cullPlanes.count == 6 ? cullPlanes[2] : SIMD4(0, 0, 0, 1),
                               p3: cullPlanes.count == 6 ? cullPlanes[3] : SIMD4(0, 0, 0, 1),
                               p4: cullPlanes.count == 6 ? cullPlanes[4] : SIMD4(0, 0, 0, 1),
                               p5: cullPlanes.count == 6 ? cullPlanes[5] : SIMD4(0, 0, 0, 1),
                               eyeRest: {
                                   // The world spins under a fixed camera, so the eye is moved INTO
                                   // the world's own frame once per frame rather than every prop
                                   // being spun out of it. `spin` is a pure rotation, so transposing
                                   // inverts it.
                                   // `spin.transpose` inverts a pure ROTATION. The counterpart's
                                   // spin carries the orbital translation and scale as well, so the
                                   // transpose is meaningless there — and it is only read by the
                                   // horizon test, which is off for the sky world anyway.
                                   guard !isCounterpart else { return .zero }
                                   let inv = spin.transpose
                                   let e = inv * SIMD4<Float>(cullEye, 1)
                                   return SIMD3(e.x, e.y, e.z)
                               }(),
                               // Not per-instance for the sky world: one bounding-sphere test has
                               // already decided the whole world is on screen, and at that size the
                               // per-prop test rejects almost nothing while costing a pass over
                               // every instance (8.6 ms of it, measured, on an 11³ overhead).
                               enabled: !isCounterpart && cullPlanes.count == 6 && !ablate.contains("cull"),
                               // ORBIT ONLY, and only from outside the world's bounding sphere —
                               // whose radius is the CORNER distance on a cube, faceDistance·√3, not
                               // faceDistance. The camera mode is the real gate; the radius is the
                               // belt to its braces. Anything softer is a threshold a walking player
                               // can cross, which is exactly what happened.
                               // NOT for the counterpart: this test inverts the world's own spin and
                               // compares against ITS faceDistance, both of which describe a world
                               // centred on the origin. The sky world is neither centred nor
                               // unscaled. Applying a cull gate across a boundary it was not built
                               // for is exactly what emptied the first-person view and made the
                               // corner walls vanish — twice. Frustum culling still applies, and is
                               // correct here because it works in world space after the offset.
                               horizon: !isCounterpart && !ws.interior
                                   && gameState.camera.mode == .orbit
                                   && simd_length(cullEye) > ws.faceDistance * 1.732 * 1.2,
                               roundness: model.roundness,
                               backface: cullBackfaceThreshold)
        // A1/A2 thresholds, in world units (a tile is 1.0 ≈ 18.9 m).
        //
        //   casterMinSize — below this an instance does not cast: its shadow-map footprint is a few
        //     texels bought at full vertex cost. ~0.85 m: grass, flowers, pebbles, cables stop
        //     casting; bushes, rocks, walls, platforms keep.
        //   lodMaxSize — only instances SMALLER than this participate in LOD at all. Structure never
        //     pops, whatever the distance.
        //   lodDropRatio / lodShowRatio — distance ÷ world-size. Beyond drop it goes; it must come
        //     back NEARER than it left (show < drop) or zooming shimmers at the boundary — the
        //     hysteresis the cull-margin lesson demands. At these ratios a 0.5 m plant drops ~7
        //     tiles out in first person and is gone from orbit entirely, where it was ~2 px.
        // CALIBRATED to the measured distribution (bench p10 0.096 / p50 0.197 / p90 0.237): the
        // first guess (0.045/0.035) was ~8× low and matched nothing — flowers here are 2 m, walls
        // 4 m. 0.16 ≈ 3 m: grass, flowers, small rocks, cables below; bushes, walls, trees,
        // platforms above.
        let casterMinSize: Float = 0.16
        let lodMaxSize: Float = 0.16
        let lodDropRatio: Float = 110    // a 2 m plant drops beyond ~13 units (~250 m)
        let lodShowRatio: Float = 90     // and returns nearer, so the boundary cannot shimmer
        // ORBIT-ONLY: at ground level the small contact shadows are visual texture worth their
        // cost (Eddie: "the shadow makes things look less interesting"), and first person sat at
        // the vsync floor before the subset existed — it never paid there. In orbit a 2 m shadow
        // is sub-texel in the map and the ~2.6 ms is real.
        let subsetOn = !ablate.contains("shadowsubset") && gameState.camera.mode == .orbit
        let lodOn = !ablate.contains("lod")
        // The orbital offset carries a SCALE (a 3³ moon is drawn at the M9 moon's apparent size), so
        // a prop's world-space size in the sky is its real size times that factor. Divide it back out
        // to judge props by what they are rather than by how small the sky happens to be.
        let orbitalScale = simd_length(SIMD3(offset.columns.0.x, offset.columns.0.y, offset.columns.0.z))
        let invOrbitalScale: Float = orbitalScale > 1e-6 ? 1 / orbitalScale : 1

        var inst = 0
        var dropped = 0
        for (key, bucket) in cache.buckets {
            let count = min(bucket.instances.count, cap - inst)
            dropped += bucket.instances.count - count
            guard count > 0 else { continue }
            // A2 hysteresis state, aligned to this bucket's (cached, stable) instance order.
            if cache.lodShown[key]?.count != bucket.instances.count {
                cache.lodShown[key] = [Bool](repeating: true, count: bucket.instances.count)
            }
            let base = inst
            // A1 — casters first: write casting instances straight to the buffer, hold the rest in
            // scratch, append them after. The shadow pass then draws only the front of the range.
            packScratch.removeAll(keepingCapacity: true)
            for k in 0..<count {
                var d = bucket.instances[k]
                let rest = d.modelMatrix.columns.3
                let rest3 = SIMD3(rest.x, rest.y, rest.z)
                d.modelMatrix = spin * d.modelMatrix     // the one thing that changes every frame
                let p = SIMD3(d.modelMatrix.columns.3.x, d.modelMatrix.columns.3.y, d.modelMatrix.columns.3.z)
                if cull.hides(rest: rest3, world: p) {
                    benchCulled += 1
                    // Diagnostic: anything WELL inside the view cone and close by must never be
                    // culled. This is the check the first cull test would have failed instantly.
                    if benchFramesRemaining > 0, !isCounterpart {
                        // "Plainly in view" has to mean something from BOTH cameras: near the middle
                        // of the screen, and on a surface comfortably turned toward the eye. The
                        // earlier version required the prop to be within 6 units, which never fires
                        // from orbit 26 units out — it read 0 through the whole time orbit was
                        // visibly broken. A diagnostic that cannot fail is not one.
                        // Facing is judged by the SURFACE NORMAL, not by p̂: at a cube's corners the
                        // two differ by up to 55°, and the p̂ version raised false alarms on exactly
                        // the props the normal-based cull was right to drop. The margin is wide —
                        // the cull fires at −0.2, this complains only above +0.35 — so the check is
                        // a guard rail rather than a restatement of the rule it is guarding.
                        let d = p - cullEye
                        let len = simd_length(d)
                        let rr = simd_length_squared(rest3)
                        if len > 1e-4, rr > 1e-8,
                           simd_dot(d / len, cullForward) > 0.85 {
                            let n = cull.surfaceNormal(rest3, 1 / rr.squareRoot())
                            let toEyeRest = cull.eyeRest - rest3
                            let t = simd_length(toEyeRest)
                            if t > 1e-4, simd_dot(n, toEyeRest / t) > 0.35 {
                                Renderer.benchInViewKilled += 1
                            }
                        }
                    }
                    continue
                }
                // Instance world size: mesh extent × the matrix's largest column scale (inverted
                // platforms are non-uniform, so take the max).
                let m = d.modelMatrix
                let sc = max(simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                             max(simd_length(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                                 simd_length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))))
                let worldSize = bucket.meshMaxDim * sc
                if benchFramesRemaining > 0 { Renderer.benchSizeSamples.append(worldSize) }
                // A2 — small scatter beyond its distance goes, with hysteresis.
                if isCounterpart {
                    // A DISTANCE ratio is the wrong instrument for the sky world, and measurably so:
                    // with it, scene-2 overhead packed exactly ZERO props. The counterpart is drawn
                    // scaled down to the moon's apparent size and tens of units away, so every prop
                    // is "sub-pixel" by the ratio test — individually true, collectively nonsense,
                    // because a maze's walls ARE its silhouette. Dropping them all is precisely the
                    // bare plate Eddie was complaining about.
                    //
                    // So the sky world filters on INTRINSIC size instead: keep structure (walls,
                    // trees, platforms, arches), drop scatter (grass, flowers, pebbles, cables).
                    // Same threshold, measured in the world's own units by dividing out the orbital
                    // scale. No hysteresis: there is no boundary here to shimmer across.
                    if lodOn, worldSize * invOrbitalScale < lodMaxSize { benchLODDropped += 1; continue }
                } else if lodOn, worldSize < lodMaxSize, worldSize > 1e-6 {
                    let ratio = simd_length(p - cullEye) / worldSize
                    let wasShown = cache.lodShown[key]![k]
                    let show = ratio < (wasShown ? lodDropRatio : lodShowRatio)
                    cache.lodShown[key]![k] = show
                    if !show { benchLODDropped += 1; continue }
                }
                // A1 — casters go to the buffer now; the rest wait so casters pack first.
                if subsetOn, !isCounterpart, worldSize < casterMinSize {
                    benchNonCasters += 1
                    packScratch.append(d)
                    continue
                }
                ptr[inst] = d
                inst += 1
            }
            let casters = inst - base
            for d in packScratch where inst - base < count {
                ptr[inst] = d
                inst += 1
            }
            let drawn = inst - base
            guard drawn > 0 else { continue }
            cmds.append(AssetDrawCmd(vertexBuffer: bucket.vertexBuffer, indexBuffer: bucket.indexBuffer,
                                              indexOffset: bucket.indexOffset, indexCount: bucket.indexCount,
                                              instanceIndex: base, diffuse: bucket.diffuse,
                                              cutout: bucket.cutout, instanceCount: drawn,
                                              casterCount: isCounterpart ? 0 : casters))
        }
        // DYNAMIC PROPS — the surveyor, drawn OUTSIDE the bucket cache. It is the one prop that
        // moves and changes state every frame; inside the cache it either froze (no rebuilds) or
        // forced a full rebuild per frame (the mark-spam this pass removed). One machine, appended
        // fresh each frame after the cached pack: never culled — a 3.2 m crystal that IS the point
        // does not belong to the scatter class — and always a shadow caster.
        // Skipped for the sky world: one machine on a world hundreds of metres overhead is invisible,
        // and it is the one prop that would force a rebuild every frame.
        if !isCounterpart, let tile = world.surveyorTile, let crystal = namedProp("Blocks Crystal_Big"),
           inst < cap {
            let cp = importedProps[crystal]
            var base = model.restMatrix(face: tile.face, row: tile.row, col: tile.col)
            // The slide: between the previous tile's centre and this one's, in the tile-local frame
            // (same-face steps only, exactly the semantics the prop offsets used to carry).
            var localX: Float = 0, localY: Float = 0
            if let from = world.surveyorFrom, from.face == tile.face, world.surveyorMove < 1 {
                let span = 3 * ws.subCellStep, back = 1 - world.surveyorMove
                localX = Float(from.col - tile.col) * span * back
                localY = Float(from.row - tile.row) * span * back
            }
            base = model.inflatedPlacement(base: base, localX: localX, localY: localY)
            if world.sliceRotation.isActive,
               let (ci, _) = model.faceletAt(face: tile.face, row: tile.row, col: tile.col),
               world.sliceRotation.affectedCubies.contains(ci) {
                base = world.sliceRotation.currentMatrix * base
            }
            let dim = cp.mesh.size
            let maxD = max(dim.x, max(dim.y, dim.z))
            let cfs: Float = (maxD > 0 ? 0.17 / maxD : 1)
            let cc = cp.mesh.center
            let cm = spin * base
                * float4x4.translation(-cc.x * cfs, cc.z * cfs, ws.floorY - cp.mesh.boundsMin.y * cfs)
                * float4x4.scale(cfs)
                * float4x4.rotation(radians: .pi / 2, axis: SIMD3(1, 0, 0))
            for (si, sm) in cp.mesh.submeshes.enumerated() {
                guard inst < cap else { break }
                let mat = si < cp.submeshMaterials.count ? cp.submeshMaterials[si] : nil
                let d: InstanceDataSwift
                var diffuse: MTLTexture? = nil
                // Working or idle, the crystal is always a LIT solid — the difference is a glow
                // added on top (material 37), not a swap to the sun's unlit material, which flattened
                // every facet into one pale silhouette. `surveyorWork` accumulates only while
                // filigree is actually growing and freezes while the machine walks, so beating on it
                // makes the pulse mean something: the light is on when the work is.
                diffuse = mat?.diffuse
                let pulse = world.surveyorIdle ? 0
                          : 0.55 + 0.45 * sin(world.surveyorWork * 2.2)
                if let _ = diffuse {
                    d = InstanceDataSwift(modelMatrix: cm, baseColor: SIMD4(0.82, 0.92, 1.0, 1.0),
                                          materialID: 37, tileID: 0, discoveryAmount: pulse, styleSeed: 0)
                } else {
                    // No atlas bound for this sub-mesh: fall back to the flat-lit prop path rather
                    // than sample whatever texture happens to still be bound.
                    d = InstanceDataSwift(modelMatrix: cm, baseColor: sm.color,
                                          materialID: 10, tileID: 0, discoveryAmount: 1.0, styleSeed: 0)
                }
                ptr[inst] = d
                cmds.append(AssetDrawCmd(vertexBuffer: cp.mesh.vertexBuffer, indexBuffer: cp.mesh.indexBuffer,
                                                  indexOffset: sm.indexOffset, indexCount: sm.indexCount,
                                                  instanceIndex: inst, diffuse: diffuse,
                                                  cutout: false, instanceCount: 1, casterCount: 1))
                inst += 1
            }
        }

        // NO SILENT CAPS. A clamp here deletes scenery, which looks like a level-design decision.
        if dropped > 0, !reportedAssetOverflow {
            reportedAssetOverflow = true
            NSLog("asset instance buffer full: %d of %d dropped in '%@'%@ — raise the buffer",
                  dropped, inst + dropped, world.name, isCounterpart ? " (as a SKY world)" : "")
        }
        benchPackMs += Float(CACurrentMediaTime() - tPack0) * 1000
        if isCounterpart {
            benchCounterpartAssetInstances = inst
        } else {
            benchAssetInstances = inst
            benchAssetDemand = cache.buckets.values.reduce(0) { $0 + $1.instances.count }
        }
        return cmds
    }

    static func frustumPlanes(from vp: float4x4) -> [SIMD4<Float>] {
        let r0 = SIMD4<Float>(vp.columns.0.x, vp.columns.1.x, vp.columns.2.x, vp.columns.3.x)
        let r1 = SIMD4<Float>(vp.columns.0.y, vp.columns.1.y, vp.columns.2.y, vp.columns.3.y)
        let r2 = SIMD4<Float>(vp.columns.0.z, vp.columns.1.z, vp.columns.2.z, vp.columns.3.z)
        let r3 = SIMD4<Float>(vp.columns.0.w, vp.columns.1.w, vp.columns.2.w, vp.columns.3.w)
        return [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2].map { p in
            let n = simd_length(SIMD3(p.x, p.y, p.z))
            return n > 0 ? p / n : p
        }
    }
    /// What the asset buckets were built from. Anything here changing means they must be rebuilt;
    /// nothing here changing means last frame's are still correct.
    struct AssetCacheToken: Equatable {
        let world: ObjectIdentifier
        /// The world's NAME as well as its identity: `ObjectIdentifier` is an address, and a freed
        /// world's address being handed to its replacement is not hypothetical here — that is exactly
        /// what produced the intermittent magenta (attachment residency keyed the same way).
        let worldName: String
        let topology: UInt64
        let twisting: Bool
        let twistFrame: Int
        let roundness: Float
        let relief: Float
        let paletteSize: Int
        /// Imported meshes arrive after boot, and a world whose topology has not changed since would
        /// otherwise keep serving buckets built when there was nothing to put in them.
        let assetsLoaded: Int
    }

}
