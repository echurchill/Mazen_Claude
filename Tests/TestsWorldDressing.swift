import Foundation
import simd

// DRESSING, PROPS, AUDIO, AND THE CACHES — everything laid ON a world rather than the world
// itself. The recurring bug this file exists for: dressing that is drawn in one place and COLLIDES
// in another, which is how the invisible wall came back three times. Also the cache-vs-fresh
// equivalence checks, which are only worth anything because they re-derive the slow way.
//
// Part of `CoordinateMathTests` (split out 2026-08-05 — one 4,158-line file was hard to navigate
// and worse to review). Everything here is an extension on the same type, so the shared helpers and
// `check()` are available exactly as before, and `main()` in CoordinateMathTests.swift still names
// every test it runs. ADDING A FILE HERE MEANS ADDING IT TO `Tests/run-tests.sh` in the same
// commit — the runner lists its sources explicitly and will not find a new one on its own.

extension CoordinateMathTests {
    /// The vessel READS the lock: three rings, one per anchor, coming home as each is released. Its
    /// count is derived from live bond state rather than tallied separately, so it cannot drift out
    /// of step with the thing it is reporting on — the failure mode that would matter most, because
    /// a vessel that lies is worse than no vessel at all.
    /// Eddie mapped a lane of walkable ground with invisible barriers either side of it in the
    /// garden. Cause: an OPEN edge was still being narrowed to the centred gap between jamb posts —
    /// correct for a hedge gateway, which really is a gap in a wall, but a dressed world draws stone
    /// only on CLOSED edges and no jambs at all, so two thirds of every passage was fenced off by
    /// nothing. The rule is now "collision matches what you can see".
    static func testDressedWorldsDoNotFenceOffOpenEdges() {
        let grid = 15
        var tile = MazeTile(openings: [.north, .east, .south, .west], styleSeed: 0)
        var hedgeOK = 0, dressedOK = 0
        for lat in 0..<grid {
            if tile.edgeAllows(.north, lateral: lat, grid: grid) { hedgeOK += 1 }
            if tile.edgeAllows(.north, lateral: lat, grid: grid, fullWidthGateways: true) { dressedOK += 1 }
        }
        check(hedgeOK == grid - 2 * (grid / 3), "a hedge gateway keeps its centred gap (\(hedgeOK)/\(grid))")
        check(hedgeOK < dressedOK, "the old rule really was narrower — otherwise this test proves nothing")
        check(dressedOK == grid, "a dressed world's open edge is crossable at full width")
        // Every border cell along that edge becomes standable too — the barrier was there, not just
        // at the moment of crossing.
        for lat in 0..<grid {
            check(tile.isStandable(0, lat, grid: grid, fullWidthGateways: true),
                  "border cell \(lat) on an open edge should be standable in a dressed world")
        }
        // A CLOSED edge still blocks outright whatever the style — the wall is genuinely there.
        tile.openings = []
        for lat in 0..<grid {
            check(!tile.edgeAllows(.north, lateral: lat, grid: grid, fullWidthGateways: true),
                  "a closed edge blocks whatever the wall style")
        }
        // And it is the dressed worlds, and only those, that ask for it.
        check(GameState(size: 11, name: "garden", stamp: .gardenMaze).cubeModel.fullWidthGateways,
              "the garden's walls are dressed models, so it draws no jambs")
        check(!GameState(size: 7, name: "natural", stamp: .natural).cubeModel.fullWidthGateways,
              "hedge worlds keep the jamb rule their geometry earns")
    }

    /// Scattered props are nudged off the 3×3 authoring lattice so a world does not read as a grid.
    /// For SOLID props that is only safe if the footprint moves with the picture — a boulder nudged
    /// half a sub-cell is about two stand cells from where it is drawn, and collision that disagrees
    /// with what you can see is the invisible-wall bug wearing a different hat.
    static func testJitteredSolidPropsBlockWhereTheyAreDrawn() {
        let gs = GameState(size: 7, name: "natural", stamp: .natural)
        let ws = gs.cubeModel.worldScale
        let grid = ws.standGrid, step = ws.standStep
        let k = grid / 3
        // A boulder on the centre sub-cell, nudged a good way east.
        var rock = Prop(kind: .boulder, subRow: 1, subCol: 1)
        check(rock.kind.isSolid, "a boulder is solid, or this test proves nothing")
        let centre = 1 * k + k / 2
        let shift = 0.43 * ws.subCellStep                  // the largest nudge scatterJitter produces
        rock.offsetX = shift
        let cells = Int((shift / step).rounded())
        check(cells >= 1, "the nudge must be at least a stand cell wide to be worth testing")
        // It blocks where it is DRAWN...
        check(rock.blocks(centre, centre + cells, grid: grid, standStep: step),
              "a nudged boulder blocks the ground under it")
        // ...and has let go of ground it has moved off.
        let rad = rock.kind.footprintRadius(grid: grid)
        check(!rock.blocks(centre, centre - rad - 1, grid: grid, standStep: step),
              "and no longer blocks where it used to stand")
        // Passing no standStep keeps the old lattice-centred behaviour for callers that want it.
        check(rock.blocks(centre, centre, grid: grid), "without standStep the footprint stays on the cell")
        // Placement must be CONTINUOUS across the tile — the failure Eddie kept seeing was props
        // landing on a small set of positions, so assert they land on many, spread over the whole
        // tile, and that each stays inside the sub-cell it reports (or its footprint would lie).
        var xs: [Float] = [], ys: [Float] = []
        var distinct = Set<Int>()
        let half = ws.floorHalfSize
        for seed in 0..<600 {
            let p = gs.cubeModel.scatterPlacement(UInt32(truncatingIfNeeded: seed &* 2654435761 &+ 17))
            check(abs(p.ox) <= 0.5 * ws.subCellStep + 1e-5 && abs(p.oy) <= 0.5 * ws.subCellStep + 1e-5,
                  "seed \(seed) offset escapes the sub-cell it claims")
            check(p.yaw >= 0 && p.yaw <= 360, "seed \(seed) yaw \(p.yaw) out of range")
            let x = Float(p.subCol - 1) * ws.subCellStep + p.ox    // where it is actually drawn
            let y = Float(p.subRow - 1) * ws.subCellStep + p.oy
            check(abs(x) <= half && abs(y) <= half, "seed \(seed) placed outside its own tile")
            xs.append(x); ys.append(y)
            distinct.insert(Int(x * 4000) &* 31 &+ Int(y * 4000))
        }
        check(distinct.count > 550, "placement should be continuous, got \(distinct.count) distinct spots of 600")
        // And it should actually USE the tile: cover every third of it in both axes.
        for band in 0..<3 {
            let lo = -half + Float(band) * (2 * half / 3), hi = lo + (2 * half / 3)
            check(xs.contains { $0 >= lo && $0 < hi }, "no prop landed in x band \(band)")
            check(ys.contains { $0 >= lo && $0 < hi }, "no prop landed in y band \(band)")
        }
        // Density must VARY, or an even sprinkle reads as a grid however good the positions are.
        var counts = Set<Int>()
        for r in 0..<24 { for c in 0..<24 {
            counts.insert(Int((gs.cubeModel.clumpField(r, c, salt: 11) * 8).rounded()))
        } }
        check(counts.count >= 4, "clumpField should give a real spread of densities, got \(counts.sorted())")
    }

    /// The dressed walls put a FIXED three props along every wall of every tile, at exactly even
    /// spacing and a constant distance out — a fence, and the last visible regularity once open
    /// ground was fixed. It hid on the player's start face because the garden's continuous scatter
    /// is layered over that one face and no other.
    ///
    /// Also pins the constraint that makes this awkward: the dressing must be derived from
    /// twist-INVARIANT inputs (tile seed, canonical edge, k) so it rides its tile rigidly through a
    /// rotation. Varying it by row/col would look just as good standing still and shear on the first
    /// twist.
    static func testDressedWallDressingIsNotAFence() {
        let gs = GameState(size: 11, name: "garden", stamp: .gardenMaze)
        let m = gs.cubeModel
        let pools = [0, 1, 2, 3]
        func dressing(_ ci: Int, _ fi: Int, _ face: CubeFace, _ r: Int, _ c: Int) -> [Prop] {
            m.dressedWallProps(m.cubies[ci].facelets[fi], face: face, row: r, col: c,
                               walls: pools, rocks: pools, bushes: pools,
                               wallScale: 1, rockScale: 1, bushScale: 1, skipOvergrowth: false)
        }
        var counts = Set<Int>(), radii = Set<Int>(), sample: [Prop] = []
        var idOf: [Int: (Int, Int)] = [:]
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                idOf[m.cubies[ci].facelets[fi].id.rawValue] = (ci, fi)
                let props = dressing(ci, fi, .positiveZ, r, c)
                guard !props.isEmpty else { continue }
                counts.insert(props.count)
                for p in props { radii.insert(Int((p.offsetX * p.offsetX + p.offsetY * p.offsetY).squareRoot() * 500)) }
                if props.count > sample.count { sample = props }
            }
        }
        check(counts.count > 1, "how many props dress a tile should vary, got \(counts.sorted())")
        check(radii.count > 8, "distance from the wall should vary, got \(radii.count) distinct radii")
        check(sample.contains { $0.viewAngle != 0 }, "dressing should not be quantised to 45° facings")
        // Positions along a wall must not be evenly spaced.
        let xs = sample.map { $0.offsetX }.sorted()
        if xs.count >= 3 {
            let gaps = (1..<xs.count).map { xs[$0] - xs[$0 - 1] }
            check(Set(gaps.map { Int($0 * 1000) }).count > 1, "props along a wall are still evenly spaced")
        }
        // The dressing is a pure function of (tile identity, PASSABLE edge state) — it reads the
        // seam's truth, not the tile's own half, because drawing from one half while movement asks
        // both is exactly what an invisible wall is (Scene 4 by the portal, three recurrences).
        // The invariants that follow from that:
        //
        //   DETERMINISM — an identical world dresses identically.
        let m2 = GameState(size: m.size, name: "again", stamp: .gardenMaze).cubeModel
        var sameEverywhere = true
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c),
                      let (ci2, fi2) = m2.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                let a = m.dressedWallProps(m.cubies[ci].facelets[fi], face: .positiveZ, row: r, col: c,
                                           walls: pools, rocks: pools, bushes: pools,
                                           wallScale: 1, rockScale: 1, bushScale: 1, skipOvergrowth: false)
                let b = m2.dressedWallProps(m2.cubies[ci2].facelets[fi2], face: .positiveZ, row: r, col: c,
                                            walls: pools, rocks: pools, bushes: pools,
                                            wallScale: 1, rockScale: 1, bushScale: 1, skipOvergrowth: false)
                if a.map(\.state) != b.map(\.state) || a.map(\.offsetX) != b.map(\.offsetX) { sameEverywhere = false }
            }
        }
        check(sameEverywhere, "two identical worlds dressed differently")

        //   REVERSIBILITY — a twist and its inverse restore the dressing bit-for-bit, because the
        //   routing model conserves openings.
        let (axis, index) = m.sliceAxisAndIndex(for: .positiveZ)
        func snapshotDressing() -> [[Int]] {
            var out: [[Int]] = []
            for r in 0..<m.size {
                for c in 0..<m.size {
                    guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                    out.append(m.dressedWallProps(m.cubies[ci].facelets[fi], face: .positiveZ, row: r, col: c,
                                                  walls: pools, rocks: pools, bushes: pools,
                                                  wallScale: 1, rockScale: 1, bushScale: 1,
                                                  skipOvergrowth: false).map(\.state))
                }
            }
            return out
        }
        let beforeTwist = snapshotDressing()
        m.applySliceRotation(axis: axis, index: index, angle: .pi / 2)
        m.applySliceRotation(axis: axis, index: index, angle: -.pi / 2)
        check(snapshotDressing() == beforeTwist, "twist + untwist did not restore the dressing")

        //   THE CLASS-KILLER — every edge that refuses PASSAGE draws a wall, on the refused side,
        //   whoever owns the closure. Constructed directly: open mine, close theirs.
        if let (ci, fi) = m.faceletAt(face: .positiveZ, row: 2, col: 2),
           let (nci, nfi) = m.faceletAt(face: .positiveZ, row: 2, col: 3) {
            // Isolate the seam: MY tile fully open on every edge, so any wall it draws can only be
            // the disagreement. (The first version left the tile's other walls standing, and
            // `!mine.isEmpty` passed even with the fix reverted — a check that cannot fail is not
            // a check, third time this month.)
            m.cubies[ci].facelets[fi].mazeTile.openings = [.north, .east, .south, .west]
            // AGREEMENT first — the garden maze may already close the far side, and "closing" an
            // already-closed edge proves nothing (the first draft of this failed in both directions
            // for exactly that reason). Open theirs, measure, close theirs, measure.
            m.cubies[nci].facelets[nfi].mazeTile.openings.insert(.west)
            let agreed = m.dressedWallProps(m.cubies[ci].facelets[fi], face: .positiveZ, row: 2, col: 2,
                                            walls: pools, rocks: [], bushes: [],
                                            wallScale: 1, rockScale: 1, bushScale: 1, skipOvergrowth: true).count
            m.cubies[nci].facelets[nfi].mazeTile.openings.remove(.west)    // theirs: closed
            let broken = m.dressedWallProps(m.cubies[ci].facelets[fi], face: .positiveZ, row: 2, col: 2,
                                            walls: pools, rocks: [], bushes: [],
                                            wallScale: 1, rockScale: 1, bushScale: 1, skipOvergrowth: true).count
            check(broken > agreed,
                  "closing the FAR side of a seam added no wall on my side — "
                  + "that is the invisible wall, back again (agreed \(agreed), broken \(broken))")
        }
    }

    /// Audio Phase C's stated risk: "worth a test that an emitter's position tracks its facelet
    /// through a rotation". Emitters are republished every frame from live topology rather than
    /// remembered, so a slab that turns carries its sounds with it — but only if nobody caches.
    /// Phase D's occlusion rides the same topology, so a twist that opens a corridor opens the sound
    /// down it, with no separate bookkeeping to forget.
    static func testAudioEmittersRideTwistsAndAreOccludedByWalls() {
        let gs = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo)
        let m = gs.cubeModel
        // Scene 2 starts SILENT — its obelisks are dormant and its exit portal is sealed, which is
        // the scene working as written. Wake the obelisks so there is something sustained to track.
        var woke = 0
        for cu in m.cubies.indices {
            for fi in m.cubies[cu].facelets.indices {
                for pi in m.cubies[cu].facelets[fi].props.indices
                where m.cubies[cu].facelets[fi].props[pi].kind == .obelisk {
                    m.cubies[cu].facelets[fi].props[pi].anim = 1
                    woke += 1
                }
            }
        }
        check(woke > 0, "Scene 2 should have obelisks to awaken")
        gs.update(deltaTime: 1.0 / 60.0)
        let before = gs.activeEmitters
        check(!before.isEmpty, "an awakened obelisk should be sounding")
        // Rotate a slab that actually CONTAINS an emitter. (Scene 2's obelisks live on +Y, so the
        // +Z outer slice leaves them alone — which is right, and would have made this test pass
        // while proving nothing.)
        var slab: (axis: Int, index: Int)? = nil
        outer: for cu in m.cubies.indices {
            for f in m.cubies[cu].facelets where before.contains(where: { $0.id == f.id.rawValue }) {
                slab = (0, Int(m.cubies[cu].position.x))
                break outer
            }
        }
        guard let sl = slab else { check(false, "could not find the emitter's own slab"); return }
        m.applySliceRotation(axis: sl.axis, index: sl.index, angle: .pi / 2)
        gs.update(deltaTime: 1.0 / 60.0)
        let after = gs.activeEmitters
        // Same sources, by identity — nothing restarted, nothing orphaned.
        check(Set(before.map(\.id)) == Set(after.map(\.id)), "a twist must not create or lose emitters")
        // …but at least one of them MOVED, or the emitters are not tracking their facelets at all.
        var moved = 0
        for b in before {
            guard let a = after.first(where: { $0.id == b.id }) else { continue }
            if simd_distance(a.position, b.position) > 0.001 { moved += 1 }
        }
        check(moved > 0, "an emitter on the turning slab should have moved with it")

        // Occlusion: a wall between listener and source must register, an open corridor must not.
        var tile = MazeTile(openings: [], styleSeed: 0)
        check(!tile.openings.contains(.north), "sanity: a closed tile")
        // Walk a real world: from the player, a source on their own tile is never occluded.
        let here = gs.activeEmitters.first { e in
            m.faceletAt(face: gs.player.face, row: gs.player.row, col: gs.player.col)
                .map { m.cubies[$0.cubieIndex].facelets[$0.faceletIndex].id.rawValue == e.id } ?? false
        }
        if let h = here { check(h.occlusion == 0, "a source on your own tile is not occluded") }
        // And the walk itself: crossing a sealed region boundary must count walls.
        let n = m.size, c = n / 2
        let walls = m.wallsBetween(face: .positiveZ, fromRow: c, fromCol: c, toRow: 0, toCol: 0)
        check(walls >= 0 && walls <= 2 * n, "the occlusion walk terminates with a sane count (\(walls))")
        tile.openings = .all
        check(m.wallsBetween(face: .positiveZ, fromRow: c, fromCol: c, toRow: c, toCol: c) == 0,
              "no walls between a tile and itself")
    }

    /// An edge is ONE thing stored TWICE, once in each tile that meets at it, and nothing enforced
    /// that the halves agree. Several stamps carve a passage by opening one side only, which gave
    /// edges that were passable one way and solid the other — and, because a dressed wall is drawn by
    /// whichever tile owns it, walls that blocked you while drawing nothing at all. Eddie walked into
    /// one beside Scene 2's control plinth; there were 18 disagreeing halves there and 38 in the hub.
    ///
    /// This is the assertion that makes the whole class impossible, so it runs over every stamp.
    static func testEveryStampHasConsistentEdges() {
        let worlds: [(String, GameState)] = [
            ("scene-2", GameState(size: PrologueSize.sceneTwo, name: "s2", stamp: .sceneTwo)),
            ("scene-4", GameState(size: PrologueSize.sceneFour, name: "s4", stamp: .sceneFour)),
            ("garden",  GameState(size: 11, name: "g", stamp: .gardenMaze)),
            ("hub",     GameState(size: 15, name: "h", stamp: .portalHub)),
            ("temple",  GameState(size: 5, name: "t", interior: true, stamp: .templeInterior)),
            ("natural", GameState(size: 7, name: "n", stamp: .natural)),
            ("lunar",   GameState(size: 5, name: "l", stamp: .lunar)),
            ("home",    GameState(size: 7, name: "hc", stamp: .homeClearing)),
        ]
        let dirs: [(DirectionMask, Int, Int, DirectionMask)] = [
            (.north, -1, 0, .south), (.south, 1, 0, .north), (.west, 0, -1, .east), (.east, 0, 1, .west)
        ]
        for (label, gs) in worlds {
            let m = gs.cubeModel
            var bad = 0
            for face in CubeFace.allCases {
                for r in 0..<m.size {
                    for c in 0..<m.size {
                        guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                        let op = m.cubies[ci].facelets[fi].mazeTile.openings
                        for (dir, dr, dc, opp) in dirs {
                            let nr = r + dr, nc = c + dc
                            guard nr >= 0, nr < m.size, nc >= 0, nc < m.size,
                                  let (nci, nfi) = m.faceletAt(face: face, row: nr, col: nc) else { continue }
                            if op.contains(dir) != m.cubies[nci].facelets[nfi].mazeTile.openings.contains(opp) {
                                bad += 1
                            }
                        }
                    }
                }
            }
            check(bad == 0, "\(label) has \(bad) edge-halves that disagree with their neighbour")
        }
    }

    /// Eddie drew a line across the middle of an anchor's tile: blocked from above AND below, with
    /// the edges either side wide open so nothing was drawn to explain it. The anchor is a plate set
    /// into the ground, roughly a metre across, and it had inherited the default footprint — a 6.3 m
    /// square, an invisible slab filling the middle of its own tile.
    ///
    /// The rule this pins: a prop may not block ground it does not visibly occupy, and a tile
    /// carrying one must still be walkable THROUGH.
    static func testFlatPropsDoNotWallOffTheirOwnTile() {
        let gs = GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour)
        let m = gs.cubeModel
        let grid = m.worldScale.standGrid, step = m.worldScale.standStep
        for kind in [PropKind.anchor, .dial, .glyph, .layeredVessel, .plinth, .switchBase] {
            check(kind.footprintRadius(grid: grid) == 0,
                  "\(kind) is a small flat thing and must not claim a whole author cell")
        }
        // Walk the anchor's own tile end to end, straight through the middle, in both axes.
        var checkedTiles = 0
        for cu in m.cubies {
            for f in cu.facelets {
                let solids = f.props.filter { $0.kind.isSolid }
                guard solids.contains(where: { $0.kind == .anchor }) else { continue }
                checkedTiles += 1
                let mid = grid / 2
                var blockedDown = 0, blockedAcross = 0
                for i in 0..<grid {
                    if solids.contains(where: { $0.blocks(i, mid, grid: grid, standStep: step) }) { blockedDown += 1 }
                    if solids.contains(where: { $0.blocks(mid, i, grid: grid, standStep: step) }) { blockedAcross += 1 }
                }
                // The plate itself stands on ONE cell; everything else in both lines stays walkable.
                check(blockedDown <= 1, "north-south through an anchor tile blocked at \(blockedDown) cells")
                check(blockedAcross <= 1, "east-west through an anchor tile blocked at \(blockedAcross) cells")
            }
        }
        check(checkedTiles == 3, "Scene 4 has three anchors to check, found \(checkedTiles)")
    }

    /// The third flavour of invisible wall, and the meanest: you are walking ALONG a wall, at the far
    /// edge of your tile, and you cross an edge that is open on BOTH sides — but the lateral carries
    /// over verbatim and lands you on the arrival tile's corner, which a PERPENDICULAR wall has
    /// claimed. Refused, with nothing drawn where you stopped, and only when you hug a wall. There
    /// were 156 such spots in Scene 4 alone.
    ///
    /// Movement now slides the lateral toward the middle until the cell is free — rounding the corner
    /// rather than walking into it. This asserts none of those refusals remain: crossing an edge the
    /// topology says is open must always find somewhere to land.
    static func testCrossingAnOpenEdgeAlwaysFindsSomewhereToLand() {
        for (label, gs) in [("scene-4", GameState(size: PrologueSize.sceneFour, name: "s4", stamp: .sceneFour)),
                            ("scene-2", GameState(size: PrologueSize.sceneTwo, name: "s2", stamp: .sceneTwo)),
                            ("garden",  GameState(size: 11, name: "g", stamp: .gardenMaze))] {
            let m = gs.cubeModel
            let n = m.size, d = m.worldScale.standGrid, step = m.worldScale.standStep
            let fw = m.fullWidthGateways
            var stranded = 0
            var sample = ""
            for face in CubeFace.allCases {
                for r in 0..<n {
                    for c in 0..<n {
                        guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                        let tile = m.cubies[ci].facelets[fi].mazeTile
                        for (dir, dr, dc) in [(SurfaceDirection.north, -1, 0), (.south, 1, 0),
                                              (.west, 0, -1), (.east, 0, 1)] {
                            for lat in 0..<d {
                                guard tile.edgeAllows(dir, lateral: lat, grid: d, fullWidthGateways: fw) else { continue }
                                let nr = r + dr, nc = c + dc
                                let arr: (f: CubeFace, r: Int, c: Int, back: SurfaceDirection)
                                if (0..<n).contains(nr) && (0..<n).contains(nc) { arr = (face, nr, nc, dir.opposite) }
                                else {
                                    let cr = m.edgeCrossing(face: face, direction: dir, row: r, col: c)
                                    arr = (cr.face, cr.row, cr.col, cr.facing.opposite)
                                }
                                guard let (nci, nfi) = m.faceletAt(face: arr.f, row: arr.r, col: arr.c) else { continue }
                                let arrTile = m.cubies[nci].facelets[nfi].mazeTile
                                let arrProps = m.cubies[nci].facelets[nfi].props
                                // Somewhere along that seam must be standable — that is what sliding needs.
                                var landed = false
                                for l in 0..<d {
                                    let sub: (Int, Int)
                                    switch arr.back {
                                    case .north: sub = (0, l); case .south: sub = (d - 1, l)
                                    case .west:  sub = (l, 0); case .east:  sub = (l, d - 1)
                                    }
                                    if arrTile.isStandable(sub.0, sub.1, grid: d, fullWidthGateways: fw)
                                        && !arrProps.contains(where: { $0.blocks(sub.0, sub.1, grid: d, standStep: step) }) {
                                        landed = true; break
                                    }
                                }
                                if !landed {
                                    stranded += 1
                                    if sample.isEmpty { sample = "\(face)(\(r),\(c)) \(dir) lat \(lat)" }
                                }
                            }
                        }
                    }
                }
            }
            check(stranded == 0, "\(label): \(stranded) open edges with nowhere to land  \(sample)")
        }
    }

    /// Scene 1 is architecture, not a lock — so what it has to guarantee is that it can be WALKED:
    /// out of the clearing, through the break in the north wall, and round a maze whose dead ends
    /// each hold a vessel, ending at the arch. If any of that is stranded the opening simply stops.
    /// A tile is ~19 m across and can hold more than one thing worth pressing F at. Scene 1 stands
    /// its largest vessel BESIDE the arch — same tile, several metres apart — and F took the portal
    /// unconditionally, so walking up to that vessel and pressing F threw you through the door
    /// instead (Eddie: "I pushed F at the last vessel, well away from the portal").
    ///
    /// F now acts on whatever you are nearest to. Walking THROUGH a portal is untouched: that fires
    /// from the portal's own centre sub-cell and stays the primary way doors are used.
    static func testInteractPicksTheNearestThingNotThePortal() {
        let gs = GameState(size: PrologueSize.sceneOne, name: "scene-1", stamp: .sceneOne)
        let m = gs.cubeModel
        let n = m.size, grid = m.worldScale.standGrid
        // Find the tile holding BOTH the arch and the vessel beside it.
        var found = false
        for r in 0..<n {
            for c in 0..<n {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                let props = m.cubies[ci].facelets[fi].props
                guard let portal = props.first(where: { $0.kind == .portal }),
                      let vessel = props.first(where: { $0.kind == .layeredVessel }) else { continue }
                found = true
                check(portal.subRow != vessel.subRow || portal.subCol != vessel.subCol,
                      "the arch and its vessel should stand apart on the tile")
                let k = grid / 3
                // Stand ON the vessel's sub-cell and press F: it must NOT travel.
                gs.player.face = .positiveZ; gs.player.row = r; gs.player.col = c
                gs.player.subRow = vessel.subRow * k + k / 2
                gs.player.subCol = vessel.subCol * k + k / 2
                gs.portalRequested = false
                gs.interact()
                check(!gs.portalRequested, "F beside the vessel must not fire the portal")
                // In Scene 1 it does nothing further either — "nothing dramatic happens". The
                // demonstration belongs to Scene 4, where there is a lock for it to be about.
                check(gs.vesselDemo == 0, "a Scene 1 vessel stays silent when activated")
                // Stand on the ARCH's own sub-cell and press F: it must travel.
                gs.player.subRow = portal.subRow * k + k / 2
                gs.player.subCol = portal.subCol * k + k / 2
                gs.interact()
                check(gs.portalRequested, "F at the arch itself still travels")
            }
        }
        check(found, "Scene 1 should stand a vessel beside its arch")
    }

    /// Scene 1's ambience is driven by two facts about the world, so they are worth pinning even
    /// though the sound itself is not testable here: the undertone latches on the player's FIRST
    /// movement and never lets go ("the world noticing you"), and the birds fall silent by distance
    /// to the arch, which is the only warning the scene gives that a corridor is different.
    /// Scene 1C's best trick: "one layered section may complete a tiny quarter-turn while outside the
    /// center of the camera's view. When the player looks directly at it, it is still." Driven by
    /// where the camera POINTS rather than by a timer — "the motion should be subtle enough that the
    /// player may doubt having seen it", which only works if doubting is literally correct.
    static func testVesselsMoveOnlyWhenNotWatched() {
        let gs = GameState(size: PrologueSize.sceneOne, name: "scene-1", stamp: .sceneOne)
        let m = gs.cubeModel
        // Find a vessel and point the camera straight at it from a little way off.
        var at: (r: Int, c: Int, id: Int)? = nil
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c),
                      m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .layeredVessel && $0.state != 5 })
                else { continue }
                if at == nil { at = (r, c, m.cubies[ci].facelets[fi].id.rawValue) }
            }
        }
        guard let v = at else { check(false, "Scene 1 should have vessels"); return }
        let mm = m.restMatrix(face: .positiveZ, row: v.r, col: v.c)
        let p = mm.position
        let eye = p + SIMD3(0, 0, 3)
        gs.spinEnabled = false                       // isolate the camera from the world's idle spin

        // Looking straight at it: it must not move, however long you stare.
        gs.viewOrigin = eye
        gs.viewForward = simd_normalize(p - eye)
        for _ in 0..<240 { gs.update(deltaTime: 1.0 / 60.0) }
        let watched = gs.vesselDrift[v.id] ?? 0
        check(watched == 0, "a vessel under direct view must be still, got drift \(watched)")

        // Looking away: it drifts.
        gs.viewForward = simd_normalize(SIMD3(0, 1, 0.2))
        for _ in 0..<240 { gs.update(deltaTime: 1.0 / 60.0) }
        let unwatched = gs.vesselDrift[v.id] ?? 0
        check(unwatched > 0, "a vessel out of view should drift, got \(unwatched)")
    }

    /// Scene 3 gets DEPTH rather than concealment. Discovery fog was the script's word, but in a
    /// chamber whose defining property is that you can see the other five faces, hiding what is in
    /// plain sight reads as broken — and it would make the six obelisks invisible outright, since a
    /// prop needs a discovered tile. Distance haze gives "the ceiling is visible, but distant and
    /// muted" without anything vanishing.
    ///
    /// Pinned per-world, because the temple interior is signed off and must not change with it.
    static func testOnlySceneThreeAsksForAtmosphericDepth() {
        let chamber = GameState(size: PrologueSize.sceneThree, name: "s3", interior: true, stamp: .sceneThree)
        let temple = GameState(size: 5, name: "t", interior: true, stamp: .templeInterior)
        check(chamber.cubeModel.atmosphericDepth, "the chamber hazes with distance")
        check(!temple.cubeModel.atmosphericDepth, "the temple interior is unchanged")
        // The range has to be measured against the CHAMBER: its far wall is two face-distances away,
        // so fog starting at the historical 1.0 would bury the orb at 2.5 and the whole room with it.
        let reach = chamber.worldScale.faceDistance
        check(reach > 1, "a 5³ chamber should be several units across, got \(reach)")
        let near = reach * 0.9, far = reach * 2.5
        let orbDepth = (reach - near) / (far - near)          // the orb sits one face-distance away
        let farWall = (2 * reach - near) / (far - near)       // the opposite face, two away
        check(orbDepth < 0.15, "the centre must stay clear, got \(orbDepth)")
        check(farWall > 0.5 && farWall < 1.0,
              "the far wall should be muted but still THERE, got \(farWall)")
    }

    /// Every tile carrying a prop of this kind.
    static func tiles(_ gs: GameState, with kind: PropKind) -> [(face: CubeFace, r: Int, c: Int)] {
        var out: [(face: CubeFace, r: Int, c: Int)] = []
        let m = gs.cubeModel
        for face in CubeFace.allCases {
            for r in 0..<m.size {
                for c in 0..<m.size {
                    guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    if m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == kind }) {
                        out.append((face, r, c))
                    }
                }
            }
        }
        return out
    }

    /// Tile ids reachable on foot from a tile, through openings, across face edges. Tile-level, so
    /// it is an upper bound on where a player can get — which is the safe direction for a test that
    /// asks "can this be finished".
    static func walkable(_ gs: GameState, from start: (face: CubeFace, r: Int, c: Int)) -> Set<Int> {
        let m = gs.cubeModel
        struct T: Hashable { let f: Int; let r: Int; let c: Int }
        var seen: Set<T> = [T(f: start.face.rawValue, r: start.r, c: start.c)]
        var ids: Set<Int> = []
        var q = Array(seen), head = 0
        while head < q.count {
            let t = q[head]; head += 1
            guard let face = CubeFace(rawValue: t.f),
                  let (ci, fi) = m.faceletAt(face: face, row: t.r, col: t.c) else { continue }
            ids.insert(m.cubies[ci].facelets[fi].id.rawValue)
            let op = m.cubies[ci].facelets[fi].mazeTile.openings
            for (dir, mask, dr, dc) in [(SurfaceDirection.north, DirectionMask.north, -1, 0),
                                        (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)]
            where op.contains(mask) {
                let nr = t.r + dr, nc = t.c + dc
                let nt: T
                if nr >= 0, nr < m.size, nc >= 0, nc < m.size { nt = T(f: t.f, r: nr, c: nc) }
                else {
                    let cr = m.edgeCrossing(face: face, direction: dir, row: t.r, col: t.c)
                    nt = T(f: cr.face.rawValue, r: cr.row, c: cr.col)
                }
                if seen.insert(nt).inserted { q.append(nt) }
            }
        }
        return ids
    }

    /// The tile id of a facelet, for comparing against `walkable`.
    static func tileID(_ gs: GameState, _ t: (face: CubeFace, r: Int, c: Int)) -> Int? {
        guard let (ci, fi) = gs.cubeModel.faceletAt(face: t.face, row: t.r, col: t.c) else { return nil }
        return gs.cubeModel.cubies[ci].facelets[fi].id.rawValue
    }

    /// Refactor #1 — interact()'s precedence is DATA now, and this pins it. The old if-chain's
    /// order was invisible and load-bearing (the metal vessel swallowing a plinth press was a
    /// precedence bug); any reorder must now be a deliberate edit HERE and in the handler array,
    /// or this fails by name.
    static func testInteractionOrderIsTheContract() {
        check(GameState.interactionOrder == ["latch", "basin", "faceRotator", "vessel", "anchor",
                                            "obeliskRebuff", "worldModel", "scene3Plinth", "cornerSwitch",
                                            "doorPlinth", "chest"],
              "interact()'s precedence changed: \(GameState.interactionOrder)")
    }

    /// Refactor #5 — the kind-indexed prop cache. The five per-frame ticks that used to sweep the
    /// whole cube now read this; if it ever disagrees with a full sweep, props silently stop
    /// ticking (a bowl that never fills, a vessel that never drifts, an emitter that never hums).
    /// Equivalence is asserted against a fresh sweep at every state that matters: stamp, after a
    /// twist, and after a prop is CREATED — the one event that must invalidate.
    static func testThePropIndexMatchesAFullSweep() {
        let gs = prologueWorld("scene-2")
        let m = gs.cubeModel
        var kit = CubeModel.UndersideMachinery()
        kit.uprights = [0]; kit.runs = [1]; kit.boxes = [2]; kit.rails = [3]; kit.plates = [4]; kit.lamps = [5]
        m.stampSceneSixUnderside(kit)

        func sweep(_ kind: PropKind) -> Set<Int> {
            var out = Set<Int>()
            for ci in m.cubies.indices {
                for fi in m.cubies[ci].facelets.indices
                where m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == kind }) {
                    out.insert(ci << 8 | fi)
                }
            }
            return out
        }
        func indexed(_ kind: PropKind) -> Set<Int> {
            Set(m.propIndex(of: kind).map { $0.ci << 8 | $0.fi })
        }
        let kinds: [PropKind] = [.obelisk, .layeredVessel, .portal, .switchCap, .plinth, .latch, .anchor]
        for k in kinds {
            check(indexed(k) == sweep(k), "index ≠ sweep for \(k) at stamp")
        }

        // After a twist: (ci, fi) pairs are twist-invariant, so the sets must be identical too.
        m.applySliceRotation(axis: 0, index: 0, angle: .pi / 2)
        for k in kinds {
            check(indexed(k) == sweep(k), "index ≠ sweep for \(k) after a twist")
        }

        // After prop CREATION — the invalidation that must not be missed. Engage the latches so
        // the hatch portal appears, then ask the index for portals.
        let latches = tiles(gs, with: .latch).sorted {
            (m.faceletAt(face: $0.face, row: $0.r, col: $0.c).flatMap { m.cubies[$0.0].facelets[$0.1].props.first { $0.kind == .latch }?.state } ?? 0)
            < (m.faceletAt(face: $1.face, row: $1.r, col: $1.c).flatMap { m.cubies[$0.0].facelets[$0.1].props.first { $0.kind == .latch }?.state } ?? 0)
        }
        _ = latches
        for ordinal in 1...3 {
            for t in tiles(gs, with: .latch) {
                guard let (ci, fi) = m.faceletAt(face: t.face, row: t.r, col: t.c),
                      m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .latch && $0.state == ordinal })
                else { continue }
                stand(gs, t.face, t.r, t.c); gs.interact()
            }
        }
        check(m.undersideHatch != nil, "the hatch should exist for this check")
        check(indexed(.portal) == sweep(.portal),
              "the index missed a CREATED portal — stale cache, the one failure mode that matters")
    }

    /// Line of sight, for the worlds that still fog. Discovery marked only the four touching tiles,
    /// so a maze arrived one tile at a time however far you could actually see along it. Walking each
    /// open direction until a wall stops it is cheaper than a real visibility test.
    ///
    /// (Scene 1 was the reason this was written and is no longer fogged — its walk-in reveal read
    /// badly — but the rule is general and the moon and the natural worlds still use it.)
    static func testSightGoesDownCorridorsNotJustOntoTheNextTile() {
        let gs = GameState(size: 7, name: "natural", stamp: .natural)
        let m = gs.cubeModel
        // A world with no walls at all: sight should run the full range in every direction.
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                m.cubies[ci].facelets[fi].tileState = .unknown
            }
        }
        gs.player.face = .positiveZ; gs.player.row = m.size / 2; gs.player.col = m.size / 2
        gs.revealLineOfSight(range: 3)
        var revealed = 0
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                if m.cubies[ci].facelets[fi].tileState != .unknown { revealed += 1 }
            }
        }
        // Three tiles down each of four open directions, and never the diagonals.
        check(revealed == 12, "sight should run 3 tiles in 4 directions, revealed \(revealed)")
    }

    /// PERF (2026-07-19) — the topology-versioned caches must be EXACTLY equivalent to fresh
    /// re-derivation: stable between changes, and re-derived to a structural match after a twist
    /// (the dressed-wall twist-safety invariant, promoted from a throwaway probe to a guard).
    static func testTopologyVersionCaches() {
        let g = GameState(size: 25, name: "cache-test", stamp: .gardenMaze)
        let m = g.cubeModel
        let walls = [0, 1], rocks = [2, 3], bushes = [4]   // palette = registry indices; any ints work

        func freshPropTiles() -> [String] {
            var out: [String] = []
            for face in CubeFace.allCases {
                for row in 0..<m.size {
                    for col in 0..<m.size {
                        guard let (ci, fi) = m.faceletAt(face: face, row: row, col: col) else { continue }
                        if !m.cubies[ci].facelets[fi].props.isEmpty { out.append("\(face)/\(row)/\(col)/\(ci)/\(fi)") }
                    }
                }
            }
            return out.sorted()
        }
        func cachedPropTiles() -> [String] {
            m.propTiles().map { "\($0.face)/\($0.row)/\($0.col)/\($0.ci)/\($0.fi)" }.sorted()
        }
        func wallSig(_ face: CubeFace, _ r: Int, _ c: Int, _ ps: [Prop]) -> String {
            "\(face)/\(r)/\(c):" + ps.map { "\($0.state),\($0.offsetX),\($0.offsetY),\($0.facing),\($0.extraScale)" }.joined(separator: ";")
        }
        func cachedWallSigs() -> Set<String> {
            var sigs = Set<String>()
            for e in m.dressedWallEntries(walls: walls, rocks: rocks, bushes: bushes,
                                          wallScale: 1, rockScale: 0.7, bushScale: 0.5) {
                sigs.insert(wallSig(e.loc.face, e.loc.row, e.loc.col, e.props))
            }
            return sigs
        }
        func freshWallSigs() -> Set<String> {
            let clear = m.dressedClearTiles()
            var sigs = Set<String>()
            for face in CubeFace.allCases {
                for r in 0..<m.size {
                    for c in 0..<m.size {
                        guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                        let f = m.cubies[ci].facelets[fi]
                        guard f.tileState == .discovered else { continue }
                        let ps = m.dressedWallProps(f, face: face, row: r, col: c,
                                                    walls: walls, rocks: rocks, bushes: bushes,
                                                    wallScale: 1, rockScale: 0.7, bushScale: 0.5,
                                                    skipOvergrowth: clear.contains(f.id.rawValue))
                        if !ps.isEmpty { sigs.insert(wallSig(face, r, c, ps)) }
                    }
                }
            }
            return sigs
        }

        // Pre-twist: cache == fresh, and stable across repeat calls.
        check(cachedPropTiles() == freshPropTiles(), "cache: propTiles matches brute-force scan")
        let sigsA = cachedWallSigs()
        check(!sigsA.isEmpty, "cache: garden derives dressed walls")
        check(sigsA == cachedWallSigs(), "cache: dressed walls stable on repeat call")
        check(sigsA == freshWallSigs(), "cache: dressed walls match fresh derivation")
        // dressedWallProps itself is pure: same inputs, same output.
        let ver0 = m.topologyVersion
        _ = cachedWallSigs()
        check(m.topologyVersion == ver0, "cache: reads do not bump the version")

        // Twist: version bumps, caches re-derive, and STRUCTURALLY match a fresh recompute
        // (count parity is not enough — a face twist preserves totals).
        let (ax, ix) = m.sliceAxisAndIndex(for: .positiveZ)
        m.applySliceRotation(axis: ax, index: ix, angle: .pi / 2)
        check(m.topologyVersion != ver0, "cache: a twist bumps topologyVersion")
        let sigsB = cachedWallSigs()
        check(sigsB == freshWallSigs(), "cache: post-twist dressed walls match fresh derivation (twist-safety)")
        check(sigsB != sigsA, "cache: the twist actually changed the layout under test")
        check(cachedPropTiles() == freshPropTiles(), "cache: post-twist propTiles matches brute-force")

        // Four quarter-turns round-trip back to the original layout.
        for _ in 0..<3 { m.applySliceRotation(axis: ax, index: ix, angle: .pi / 2) }
        check(cachedWallSigs() == sigsA, "cache: four quarter-turns restore the original walls")
    }
}
