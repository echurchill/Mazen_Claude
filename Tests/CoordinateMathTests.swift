import Foundation
import simd

// (GameState.swift is compiled into the harness now — it supplies `verboseDebugLog`.)

/// GameState references two pure constants from TextureLoader (Metal-bound, not compiled here):
/// the CausticSymbol slice ids and progressMaskBase. This shim mirrors them EXACTLY — if the real
/// enum in TextureLoader.swift gains/reorders cases, update this copy (the compiler can't catch it).
enum TextureLoader {
    enum CausticSymbol: Int, CaseIterable {
        case blank = 0, one, two, three, four, swirl, portal, square, threeOfFour, fourFilled
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

    /// Phase 0 — the portals that used to depend on the Renderer's hardcoded name-matching must now
    /// carry their own `.push`. If either of these regresses to `.auto`, the hub's doors and the
    /// garden's temple descent would POP instead of nesting (you'd fall out of the world you're in
    /// rather than descend into the next), which is exactly the bug the name-matching existed to
    /// prevent. Cheap to assert, and it can't be caught by a headless boot.
    static func testPortalTransitionsAreExplicit() {
        // The hub's nine doors: entering a destination must PUSH so its return portal comes back here.
        let hub = GameState(size: 15, name: "portal-hub", stamp: .portalHub).cubeModel
        var hubPortals = 0
        for r in 0..<15 { for c in 0..<15 {
            guard let (ci, fi) = hub.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
            for p in hub.cubies[ci].facelets[fi].props where p.kind == .portal {
                hubPortals += 1
                check(p.transition == .push, "hub portal at (\(r),\(c)) must be .push, got \(p.transition)")
            }
        } }
        // One per entry in CubeModel's hubDestinations (the 9 legacy worlds + Scenes 1, 2 and 4; the
        // hub itself is skipped). Grows as prologue scenes are added — update alongside that list.
        // The grid grew to 4 rows × 4 columns when Scene 3 became the thirteenth destination.
        check(hubPortals == 13, "expected 13 hub portals, found \(hubPortals)")

        // The garden's temple door: a descent from an already-pushed world, so it must PUSH too.
        let garden = GameState(size: 11, name: "garden", stamp: .gardenMaze).cubeModel
        var descents = 0
        for r in 0..<11 { for c in 0..<11 {
            guard let (ci, fi) = garden.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
            for p in garden.cubies[ci].facelets[fi].props where p.kind == .portal && p.state == 1 {
                descents += 1
                check(p.transition == .push, "garden temple descent must be .push, got \(p.transition)")
            }
        } }
        check(descents == 1, "expected 1 temple-descent portal in the garden, found \(descents)")
    }

    /// Scene 2's load-bearing claim: the exit is built on a face the player cannot see, and ONE
    /// quarter-turn of the outer X slab carries it onto the player's own surface (+Z). If this ever
    /// stops holding, the scene's whole premise — "the world is carrying its own exit behind its
    /// back" — silently breaks, and no headless boot would notice.
    static func testSceneTwoHiddenFaceTurnsIntoView() {
        let gs = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo)
        let m = gs.cubeModel
        let slice = m.sceneTwoHiddenSlice()
        check(slice.strip.count == PrologueSize.sceneTwo, "the hidden strip should be one full column of +Y, got \(slice.strip.count)")

        // Find the assembly (2 obelisks + 1 portal) and confirm it starts on +Y, hidden.
        var assembly: [(id: Int, isPortal: Bool)] = []
        for t in slice.strip {
            guard let (ci, fi) = m.faceletAt(face: .positiveY, row: t.row, col: t.col) else { continue }
            let props = m.cubies[ci].facelets[fi].props
            if props.contains(where: { $0.kind == .obelisk }) {
                assembly.append((m.cubies[ci].facelets[fi].id.rawValue, false))
            } else if props.contains(where: { $0.kind == .portal }) {
                assembly.append((m.cubies[ci].facelets[fi].id.rawValue, true))
                check(m.sealedPortalCubies.contains(ci), "the hidden chamber must start SEALED (dark until it turns)")
            }
        }
        check(assembly.count == 3, "expected obelisk·chamber·obelisk on the hidden face, got \(assembly.count)")

        // Turn the slab counter-clockwise — the scripted twist the solved lock performs.
        m.applySliceRotation(axis: slice.axis, index: slice.index, angle: .pi / 2)

        // Every assembly facelet must now be on +Z, the face the player walks.
        for entry in assembly {
            var landedOn: CubeFace? = nil
            outer: for cu in m.cubies.indices {
                for f in m.cubies[cu].facelets.indices where m.cubies[cu].facelets[f].id.rawValue == entry.id {
                    let nrm = m.cubies[cu].orientation.act(m.cubies[cu].facelets[f].localFace.normal)
                    var best = CubeFace.positiveZ, bestD = -Float.infinity
                    for cf in CubeFace.allCases {
                        let d = simd_dot(nrm, cf.normal)
                        if d > bestD { bestD = d; best = cf }
                    }
                    landedOn = best
                    break outer
                }
            }
            check(landedOn == .positiveZ,
                  "assembly facelet \(entry.id) should land on +Z after the turn, landed on \(String(describing: landedOn))")
        }

        // WHERE it lands is load-bearing, not incidental: the control plinth is authored two tiles
        // from the chamber so the exit swings in directly ahead of the player. If the rotation ever
        // remapped rows differently, the plinth would end up pointing at empty ground and the scene's
        // payoff would quietly stop reading — with nothing failing.
        let c = m.size / 2
        var chamberAt: (Int, Int)? = nil
        for r in 0..<m.size { for col in 0..<m.size {
            guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: col) else { continue }
            if m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .portal && $0.state == 1 }) { chamberAt = (r, col) }
        } }
        check(chamberAt?.0 == c && chamberAt?.1 == 0,
              "the chamber should land at (centre row, col 0); landed at \(String(describing: chamberAt))")
        if let pp = m.progressPlinth {
            // The plinth must be on the same row, a short line of sight away.
            var plinthAt: (Int, Int)? = nil
            for r in 0..<m.size { for col in 0..<m.size {
                if let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: col), ci == pp.ci, fi == pp.fi { plinthAt = (r, col) }
            } }
            check(plinthAt?.0 == c, "the control plinth must share the chamber's row so the turn arrives in view")
        }

        // A prop's `facing` is NOT rotated by a twist, so the chamber is authored in its FINAL
        // orientation: facing EAST, toward the plinth the player triggers it from. Authored as north
        // it arrived edge-on and read as a slab rather than a doorway (Eddie, playtest).
        if let ch = chamberAt, let (ci, fi) = m.faceletAt(face: .positiveZ, row: ch.0, col: ch.1),
           let portal = m.cubies[ci].facelets[fi].props.first(where: { $0.kind == .portal }) {
            check(portal.facing == .e, "the chamber must face east (the approach side); got \(portal.facing)")
        }

        // EVERY tile of the turning slab must be revealed, on whichever face it belongs to —
        // undiscovered tiles render nothing, and a partly-revealed slab turns as a band of floating
        // fragments with sky between them. Checked on a FRESH model: `m` has already been rotated.
        let fresh = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo).cubeModel
        let slab = fresh.scriptedTwistSlice!
        var inSlab = 0, revealed = 0
        for face in CubeFace.allCases {
            for r in 0..<fresh.size { for col in 0..<fresh.size {
                guard let (ci, fi) = fresh.faceletAt(face: face, row: r, col: col) else { continue }
                let p = fresh.cubies[ci].position
                guard (slab.axis == 0 && p.x == Int32(slab.index))
                   || (slab.axis == 1 && p.y == Int32(slab.index))
                   || (slab.axis == 2 && p.z == Int32(slab.index)) else { continue }
                inSlab += 1
                if fresh.cubies[ci].facelets[fi].tileState == .discovered { revealed += 1 }
            } }
        }
        check(inSlab > 0 && revealed == inSlab,
              "the whole turning slab must be revealed so it reads as a plate; \(revealed)/\(inSlab)")
    }

    /// Scene 2 must land the player in the maze, not on the hidden face. The default arrival picks
    /// `firstPortalLocation()`, and CubeFace order searches +Y before +Z — so the hidden chamber was
    /// found first and the player spawned sealed inside the three-tile assembly strip. The world now
    /// states its arrival point; this pins that it is on the playable face and standable.
    static func testSceneTwoSpawnsInTheMaze() {
        let m = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo).cubeModel
        guard let spawn = m.spawnLocation else { check(false, "Scene 2 must author its arrival point"); return }
        check(spawn.face == .positiveZ, "Scene 2 spawns on the playable face, got \(spawn.face)")
        guard let (ci, fi) = m.faceletAt(face: spawn.face, row: spawn.row, col: spawn.col) else {
            check(false, "Scene 2 spawn tile must exist"); return
        }
        check(m.cubies[ci].facelets[fi].tileState == .discovered, "the spawn tile must be revealed, not fogged")
        // Not walled in: the arrival tile must open onto at least one neighbour.
        check(!m.cubies[ci].facelets[fi].mazeTile.openings.isEmpty, "the spawn tile must not be sealed on all four sides")
        // And it must not be the hidden assembly.
        check(!m.sealedPortalCubies.contains(ci), "the player must not spawn on the sealed hidden chamber")
    }

    /// Scene 2I — the turn must make the exit WALKABLE, not merely visible. Flood-fills the playable
    /// face from the arrival tile across open edges and checks the chamber: unreachable before the
    /// turn (the corridor dead-ends against the world's edge) and reachable after it (the assembly has
    /// rotated into that column). This is the payoff the whole scene is built on, and it depends on a
    /// rotation that remaps rows and faces — far too easy to get subtly wrong by eye.
    static func testSceneTwoExitIsWalkableOnlyAfterTheTurn() {
        func chamberReachable(_ m: CubeModel) -> Bool {
            let n = m.size
            guard let spawn = m.spawnLocation else { return false }
            // Locate the chamber (the portal that leads onward) on the playable face.
            var target: (Int, Int)? = nil
            for r in 0..<n { for c in 0..<n {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                if m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .portal && $0.state == 1 }) { target = (r, c) }
            } }
            guard let goal = target else { return false }
            // Flood fill across open edges, staying on the playable face.
            var seen = Set([[spawn.row, spawn.col]])
            var queue = [[spawn.row, spawn.col]]
            while let cur = queue.popLast() {
                if cur[0] == goal.0 && cur[1] == goal.1 { return true }
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: cur[0], col: cur[1]) else { continue }
                let op = m.cubies[ci].facelets[fi].mazeTile.openings
                for (dir, dr, dc) in [(DirectionMask.north, -1, 0), (.south, 1, 0), (.west, 0, -1), (.east, 0, 1)] {
                    guard op.contains(dir) else { continue }
                    let nxt = [cur[0] + dr, cur[1] + dc]
                    guard nxt[0] >= 0, nxt[0] < n, nxt[1] >= 0, nxt[1] < n, !seen.contains(nxt) else { continue }
                    seen.insert(nxt); queue.append(nxt)
                }
            }
            return false
        }

        let before = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo).cubeModel
        check(!chamberReachable(before), "before the turn the exit must NOT be walkable (the route dead-ends)")

        let after = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo).cubeModel
        let s = after.scriptedTwistSlice!
        after.bondedGroups.removeAll()                       // what the fourth switch does
        after.applySliceRotation(axis: s.axis, index: s.index, angle: s.clockwise ? -.pi / 2 : .pi / 2)
        check(chamberReachable(after), "after the turn the exit must be walkable from the arrival point")
    }





    /// Releasing an anchor must make the world visibly GIVE more, even while the turn is still
    /// refused — "partial progress may weaken a lock without yet making a turn legal". With a fixed
    /// strain, three anchors felt exactly like one and the middle of the puzzle read as no progress.
    /// Scene 4's script hangs the larger Scene 2 world overhead, and that is the ONLY thing in
    /// sight that stays put when the player's whole face rotates. Authored on the stamp, so the
    /// fact travels with the scene rather than living at the Renderer's build site.
    static func testSceneFourHangsSceneTwoOverhead() {
        check(WorldStamp.sceneFour.skyCounterpart == "scene-2", "Scene 4 authors Scene 2 as its sky")
        check(GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour)
                .skyCounterpart == "scene-2", "the built world carries the authored sky")
        // Every other world keeps the default rule (world beneath you, else the moon edge).
        for st in [WorldStamp.sceneTwo, .gardenMaze, .portalHub, .lunar, .homeClearing, .bare] {
            check(st.skyCounterpart == nil, "\(st) leaves its sky to the default rule")
        }
    }

    /// The world overhead must be the SAME INSTANCE as the one behind the door. Scene 4 builds
    /// Scene 2 for its sky before the player has necessarily been there, so a second Scene 2
    /// created later by the hub door would diverge on the first twist — you'd walk into a world
    /// that wasn't the one you'd been looking at.
    static func testSkyCounterpartIsTheSameWorldYouCanVisit() {
        let reg = WorldRegistry()
        let sceneTwo = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo)
        reg.bind(WorldKey(destination: "scene-2", origin: "scene-4"), to: sceneTwo)   // the sky edge
        check(reg.anyNamed("scene-2") === sceneTwo, "the sky-bound world is findable by name")
        check(reg.anyNamed("scene-9") == nil, "a world never built is not conjured")
        // The hub door then resolves to that same instance (the Renderer's prologue single-instance
        // rule), so a twist made in the sky copy is present in the one you walk into.
        let hubEdge = WorldKey(destination: "scene-2", origin: "portal-hub")
        let walked = reg.world(for: hubEdge) { reg.anyNamed("scene-2") ?? sceneTwo }
        check(walked === sceneTwo, "walking in from the hub reaches the world that was overhead")
        check(reg.allWorlds.count == 1, "two edges, one Scene 2 — not a divergent copy")
    }

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
        // Twist-rigidity: a tile's own OVERGROWTH follows the tile, not its position on the face.
        // (Structural wall pieces are excluded — a shared wall is drawn by one of the two tiles that
        // meet at it, and which one legitimately changes when a twist changes who is adjacent.)
        func overgrowth(_ ci: Int, _ fi: Int, _ r: Int, _ c: Int) -> [Int] {
            m.dressedWallProps(m.cubies[ci].facelets[fi], face: .positiveZ, row: r, col: c,
                               walls: [], rocks: pools, bushes: pools,
                               wallScale: 1, rockScale: 1, bushScale: 1, skipOvergrowth: false)
                .map(\.state).sorted()   // as a MULTISET: the edges are visited in N/E/S/W order of
        }                                 // the CURRENT rotation, so the sequence turns with the tile
        let (axis, index) = m.sliceAxisAndIndex(for: .positiveZ)
        let before = idOf.mapValues { overgrowth($0.0, $0.1, 0, 0) }
        m.applySliceRotation(axis: axis, index: index, angle: .pi / 2)
        var checkedTiles = 0
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                let id = m.cubies[ci].facelets[fi].id.rawValue
                guard let was = before[id] else { continue }
                check(overgrowth(ci, fi, r, c) == was,
                      "tile \(id) regrew its overgrowth differently after a twist")
                checkedTiles += 1
            }
        }
        check(checkedTiles > 0, "the twist should have left tiles on this face to re-check")
    }

    /// The vessel is meant to be READ up close — three seams and a glyph on its cap. It inherited the
    /// default prop footprint, a 5×5 block of stand cells, which held the player about 4 m back from
    /// a vase roughly 1 m across (Eddie: "I can't get very close to the vessel").
    /// Scene 4D's real payload: the twist is not in a control list, it is LEARNED from an object.
    /// "After the vessel is inspected, player-controlled twist input becomes available… the vessel
    /// does not perform the twist for the player. It introduces the possibility."
    static func testVesselInspectionGrantsTheTwist() {
        let gs = GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour)
        // Note: the WORLD is what withholds the verb (Renderer sets twistEnabled=false when it builds
        // scene-4), so set up the same starting condition the scene ships with.
        gs.twistEnabled = false
        check(!gs.vesselInspected, "the vessel starts unread")
        // Q does nothing at all before the vessel has spoken — not refused, not even attempted.
        gs.startSliceRotation(clockwise: true)
        check(!gs.sliceRotation.isActive, "the player's twist must be withheld until the vessel is read")
        gs.beginVesselDemo(at: nil)
        check(gs.vesselDemo > 0, "activating the vessel starts its demonstration")
        check(!gs.twistEnabled, "and does NOT hand over the verb before it has finished")
        // Run it to completion.
        for _ in 0..<400 where gs.vesselDemo > 0 { gs.update(deltaTime: 1.0 / 60.0) }
        check(gs.vesselInspected, "the demonstration completes")
        check(gs.twistEnabled, "and grants the twist")
        // Now the twist is available — and immediately REFUSED, which is Scene 4E. Both halves of
        // the lesson: the slice can move, and something crossing its boundary prevents it.
        gs.startSliceRotation(clockwise: true)
        check(gs.sliceRotation.isActive, "the twist is now the player's to attempt")
        check(gs.sliceRotation.isRefusal, "and the anchors still refuse it")
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

    /// Every prologue door in the hub must be a DARSIT, not a TARDIS (Eddie). The livery is keyed to
    /// a set of destination ids, and it is easy to add a scene and forget to add its id — at which
    /// point its door silently comes up blue and looks like a dev world.
    static func testEveryPrologueSceneHasADarsitDoor() {
        // The prologue worlds that exist so far, by destination index.
        let prologue = [10, 11]
        let hub = GameState(size: 15, name: "portal-hub", stamp: .portalHub).cubeModel
        var found = Set<Int>()
        for r in 0..<15 { for c in 0..<15 {
            guard let (ci, fi) = hub.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
            for p in hub.cubies[ci].facelets[fi].props where p.kind == .portal {
                if prologue.contains(p.state) { found.insert(p.state) }
            }
        } }
        check(found == Set(prologue),
              "every prologue scene needs a hub door: expected \(prologue), found \(found.sorted())")
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

    /// Scene 4's three anchors must gate the player's own twist, and must do it with NO new lock
    /// machinery: each anchor is one bond straddling the slab the player stands on, so
    /// `canRotateSlice` refuses while any remain. Releasing them one at a time must keep the turn
    /// refused until the third is gone — "partial progress may weaken a lock without yet making a
    /// turn legal" — and only then become legal.
    static func testSceneFourAnchorsGateThePlayersTwist() {
        let gs = GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour)
        let m = gs.cubeModel
        let (axis, index) = m.sliceAxisAndIndex(for: .positiveZ)

        check(m.bondedGroups.count == 3, "expected three anchor bonds, got \(m.bondedGroups.count)")
        let slab = Set(m.cubieIndicesInSlice(axis: axis, index: index))
        for g in m.bondedGroups {
            check(!g.isDisjoint(with: slab) && !g.isSubset(of: slab),
                  "each anchor bond must STRADDLE the player's slab, or it would not refuse the turn")
        }
        check(!m.canRotateSlice(axis: axis, index: index), "the turn must be refused while anchored")

        // Release them one at a time: still refused until the last.
        for remaining in [2, 1, 0] {
            m.bondedGroups.removeLast()
            check(m.bondedGroups.count == remaining, "bond bookkeeping")
            let legal = m.canRotateSlice(axis: axis, index: index)
            check(legal == (remaining == 0),
                  "with \(remaining) anchors left the turn should be \(remaining == 0 ? "legal" : "refused")")
        }

        // The gate is NOT sealed — the obstacle is the ROUTE now (see the reachability test), one
        // idea rather than two locks. The player must own the verb here, though.
        check(m.sealedPortalCubies.isEmpty, "Scene 4's portal is present and lit, not dark")
        check(gs.twistEnabled, "Scene 4 is where the player is GRANTED the twist")
    }

    /// Scene 4's bond bands must actually trace the lock. A bond is otherwise invisible — the turn
    /// refuses and the reason is nowhere — so this is what turns a refusal into information.
    /// Checks the three properties the script demands: one band per bond, each band genuinely
    /// CONNECTED (every step adjacent, including where it bends around a face edge), reaching the
    /// cubies it ties together, and gone the moment the bond is released.
    static func testSceneFourBondBandsTraceTheLock() {
        let m = GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour).cubeModel
        let bands = m.bondBands()
        check(bands.count == m.bondedGroups.count,
              "one band per bond: \(bands.count) bands for \(m.bondedGroups.count) bonds")

        for (i, band) in bands.enumerated() {
            check(band.count >= 2, "band \(i) should span tiles, got \(band.count)")
            // Endpoints must be cubies of the bond it describes.
            if let first = band.first, let last = band.last {
                let group = m.bondedGroups[i]
                check(group.contains(first.ci) && group.contains(last.ci),
                      "band \(i) must run between the cubies its bond ties together")
            }
            // Every consecutive pair must be neighbours — same face and adjacent, or across an edge.
            for k in 1..<band.count {
                let a = band[k - 1], b = band[k]
                var adjacent = false
                if a.face == b.face {
                    adjacent = abs(a.row - b.row) + abs(a.col - b.col) == 1
                } else {
                    for dir in [SurfaceDirection.north, .east, .south, .west] {
                        let x = m.edgeCrossing(face: a.face, direction: dir, row: a.row, col: a.col)
                        if x.face == b.face && x.row == b.row && x.col == b.col { adjacent = true; break }
                    }
                }
                check(adjacent, "band \(i) breaks between (\(a.face),\(a.row),\(a.col)) and (\(b.face),\(b.row),\(b.col))")
            }
        }

        // Release one anchor: that band must go, and only that one.
        let before = bands.count
        m.removeBond(containing: m.bondedGroups[0].first!)
        m.markTopologyChanged()
        check(m.bondBands().count == before - 1, "releasing a bond must remove exactly its band")
    }

    static func testSceneFourStrainGrowsAsAnchorsRelease() {
        let gs = GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour)
        let m = gs.cubeModel
        let (axis, index) = m.sliceAxisAndIndex(for: .positiveZ)

        check(m.bondsBlocking(axis: axis, index: index) == 3, "three anchors should block the turn")
        var amplitudes: [Float] = []
        for expected in [3, 2, 1] {
            check(m.bondsBlocking(axis: axis, index: index) == expected,
                  "expected \(expected) blocking bonds")
            gs.startSliceRotation(clockwise: true)
            check(gs.sliceRotation.isRefusal, "the turn must still be refused with \(expected) anchors")
            amplitudes.append(gs.sliceRotation.strainAmplitude)
            gs.sliceRotation = GameState.SliceRotation()      // clear for the next attempt
            m.removeBond(containing: m.bondedGroups[0].first!)
        }
        check(amplitudes[0] < amplitudes[1] && amplitudes[1] < amplitudes[2],
              "strain must grow as anchors are released, got \(amplitudes)")
    }

    static func testSceneFourVesselReadsTheLock() {
        let gs = GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour)
        let m = gs.cubeModel
        var vessels: [Prop] = [], anchors = 0
        for cu in m.cubies {
            for f in cu.facelets {
                vessels += f.props.filter { $0.kind == .layeredVessel }
                anchors += f.props.filter { $0.kind == .anchor }.count
            }
        }
        check(vessels.count == 1, "Scene 4 stands exactly one layered vessel")
        check(vessels.first?.anim == 0, "it starts with no ring home — the lock is whole")
        check(anchors == 3, "one ring per anchor: three")
        check(anchors == m.bondedGroups.count, "each anchor holds exactly one bond")
        // Releasing anchors raises the count the vessel reports (target = total − remaining bonds).
        for expected in 1...3 {
            m.removeBond(containing: m.bondedGroups[0].first!)
            check(anchors - m.bondedGroups.count == expected,
                  "\(expected) ring(s) should be home after \(expected) release(s)")
        }
        check(m.bondedGroups.isEmpty, "the last release frees the slab")
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
        let p = SIMD3(mm.columns.3.x, mm.columns.3.y, mm.columns.3.z)
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

    /// A sealed world has to STAY sealed. The stamps closed their region border one-sidedly, which
    /// was enough while movement was tested on the departing tile — you could not step out. Then
    /// `reconcileSharedEdges` arrived to fix the invisible walls, resolving disagreements in favour
    /// of OPEN, and silently undid every one of those seals: Eddie walked off Scene 2's face and
    /// across to a portal that was not meant to be reachable.
    ///
    /// This walks the whole cube from the spawn and asserts the player cannot leave the play face —
    /// the property that actually matters, rather than the state of any particular edge.
    static func testSealedWorldsCannotBeWalkedOutOf() {
        for (label, gs) in [("scene-1", GameState(size: PrologueSize.sceneOne, name: "s1", stamp: .sceneOne)),
                            ("scene-2", GameState(size: PrologueSize.sceneTwo, name: "s2", stamp: .sceneTwo)),
                            ("garden",  GameState(size: 11, name: "g", stamp: .gardenMaze)),
                            ("hub",     GameState(size: 15, name: "h", stamp: .portalHub))] {
            let m = gs.cubeModel
            let n = m.size
            struct T: Hashable { let f: Int; let r: Int; let c: Int }
            let start = T(f: gs.player.face.rawValue, r: gs.player.row, c: gs.player.col)
            var seen: Set<T> = [start], q = [start], head = 0
            while head < q.count {
                let t = q[head]; head += 1
                guard let face = CubeFace(rawValue: t.f),
                      let (ci, fi) = m.faceletAt(face: face, row: t.r, col: t.c) else { continue }
                let op = m.cubies[ci].facelets[fi].mazeTile.openings
                for (dir, mask, dr, dc) in [(SurfaceDirection.north, DirectionMask.north, -1, 0),
                                            (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)] {
                    guard op.contains(mask) else { continue }
                    let nr = t.r + dr, nc = t.c + dc
                    let nt: T
                    if nr >= 0, nr < n, nc >= 0, nc < n { nt = T(f: t.f, r: nr, c: nc) }
                    else {
                        let cr = m.edgeCrossing(face: face, direction: dir, row: t.r, col: t.c)
                        nt = T(f: cr.face.rawValue, r: cr.row, c: cr.col)
                    }
                    if !seen.contains(nt) { seen.insert(nt); q.append(nt) }
                }
            }
            // Guard against a vacuous pass: if the walk explored almost nothing, "did not escape"
            // means nothing either.
            check(seen.count > 20, "\(label): the walk only reached \(seen.count) tiles")
            let escaped = seen.filter { $0.f != start.f }
            check(escaped.isEmpty,
                  "\(label): the player can walk off the play face onto \(Set(escaped.map { $0.f }).sorted())")
        }
    }

    /// …and it has to stay sealed AFTER a twist, which is the case that actually bit. Sealing the
    /// play face was enough while the world stood still; turning a slab swings tiles from other
    /// faces into reach, and those had never been sealed, so the payoff of Scene 2 also handed the
    /// player a way to walk off the world (Eddie).
    static func testSealSurvivesTheScriptedTurn() {
        let gs = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo)
        let m = gs.cubeModel
        let n = m.size
        guard let slice = m.scriptedTwistSlice else { check(false, "Scene 2 names a slab to turn"); return }
        // Dissolve the lock so the turn is legal, then take it.
        while !m.bondedGroups.isEmpty { m.removeBond(containing: m.bondedGroups[0].first!) }
        m.applySliceRotation(axis: slice.axis, index: slice.index, angle: .pi / 2)

        struct T: Hashable { let f: Int; let r: Int; let c: Int }
        let start = T(f: gs.player.face.rawValue, r: gs.player.row, c: gs.player.col)
        var seen: Set<T> = [start], q = [start], head = 0
        while head < q.count {
            let t = q[head]; head += 1
            guard let face = CubeFace(rawValue: t.f),
                  let (ci, fi) = m.faceletAt(face: face, row: t.r, col: t.c) else { continue }
            let tile = m.cubies[ci].facelets[fi].mazeTile
            for (dir, mask, dr, dc) in [(SurfaceDirection.north, DirectionMask.north, -1, 0),
                                        (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)] {
                // Use the real movement rule, so a border left open only in `openEdges` counts.
                guard tile.openings.contains(mask) || tile.openEdges.contains(mask) else { continue }
                let nr = t.r + dr, nc = t.c + dc
                let nt: T
                if nr >= 0, nr < n, nc >= 0, nc < n { nt = T(f: t.f, r: nr, c: nc) }
                else {
                    let cr = m.edgeCrossing(face: face, direction: dir, row: t.r, col: t.c)
                    nt = T(f: cr.face.rawValue, r: cr.row, c: cr.col)
                }
                if !seen.contains(nt) { seen.insert(nt); q.append(nt) }
            }
        }
        check(seen.count > 20, "the walk after the turn only reached \(seen.count) tiles")
        let escaped = Set(seen.filter { $0.f != start.f }.map { $0.f }).sorted()
        check(escaped.isEmpty, "after the turn the player reaches faces \(escaped)")
    }

    /// Scene 3's mechanism: six plinths, six obelisks, matched by SYMBOL, and never on the same face
    /// — "each pairing therefore requires the player to connect a remote control with a distant
    /// response". Cumulative, irreversible, and the way out exists only once all six are lit.
    static func testSceneThreePairsPlinthsToDistantObelisks() {
        let gs = GameState(size: PrologueSize.sceneThree, name: "scene-3", interior: true, stamp: .sceneThree)
        let m = gs.cubeModel
        let n = m.size

        var obelisks: [(face: CubeFace, r: Int, c: Int, symbol: Int)] = []
        var plinths: [(face: CubeFace, r: Int, c: Int, symbol: Int)] = []
        for face in CubeFace.allCases {
            for r in 0..<n {
                for c in 0..<n {
                    guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    for p in m.cubies[ci].facelets[fi].props {
                        if p.kind == .obelisk { obelisks.append((face, r, c, p.state)) }
                        if p.kind == .switchCap { plinths.append((face, r, c, p.state)) }
                    }
                }
            }
        }
        check(obelisks.count == 6, "one obelisk per face, got \(obelisks.count)")
        check(plinths.count == 6, "six plinths, got \(plinths.count)")
        check(Set(obelisks.map(\.symbol)).count == 6, "every obelisk carries a DISTINCT symbol")
        check(Set(obelisks.map(\.face)).count == 6, "one per face, not two on any")
        // The rule the scene is built on.
        for p in plinths {
            guard let match = obelisks.first(where: { $0.symbol == p.symbol }) else {
                check(false, "plinth symbol \(p.symbol) matches no obelisk"); continue
            }
            check(match.face != p.face,
                  "a plinth must not share a face with the obelisk it wakes (symbol \(p.symbol))")
        }
        // Obelisks stand in the middle of their face, pointing inward at the orb.
        for o in obelisks { check(o.r == n / 2 && o.c == n / 2, "obelisk on \(o.face) is off-centre") }

        // Activation: cumulative, and the exit appears only at the end.
        check(!gs.sceneThreeAllObelisksAwake, "the chamber starts dark")
        check(m.chosenExit == nil, "there is no way out yet — the orb has not chosen one")
        for (i, p) in plinths.enumerated() {
            gs.player.face = p.face; gs.player.row = p.r; gs.player.col = p.c
            let grid = m.worldScale.standGrid
            gs.player.subRow = grid / 2; gs.player.subCol = grid / 2
            gs.interact()
            // The obelisk that woke is the one carrying this plinth's symbol, and it is elsewhere.
            var awake = 0
            for cu in m.cubies { for f in cu.facelets {
                awake += f.props.filter { $0.kind == .obelisk && $0.anim > 0 }.count
            } }
            check(awake == i + 1, "after \(i + 1) plinths, \(awake) obelisks are lit")
            if i < plinths.count - 1 {
                check(m.chosenExit == nil, "the exit must not appear early")
            }
        }
        check(gs.sceneThreeAllObelisksAwake, "all six lit")
        // 3K — "the orb chooses a surface", and its rules are the point.
        guard let exit = m.chosenExit else { check(false, "the orb should have chosen an exit"); return }
        guard let spawn = m.spawnLocation else { return }
        check(exit.face != spawn.face, "not on the player's starting face")
        check(exit.row > 0 && exit.row < n - 1 && exit.col > 0 && exit.col < n - 1,
              "not on a face edge or corner triple-point, got (\(exit.row),\(exit.col))")
        var hasPortal = false
        if let (ci, fi) = m.faceletAt(face: exit.face, row: exit.row, col: exit.col) {
            hasPortal = m.cubies[ci].facelets[fi].props.contains { $0.kind == .portal }
        }
        check(hasPortal, "and a portal actually stands there")
    }

    /// Scene 3's staged responses (3I) and its completion (3J) hang on two numbers the model owns:
    /// how awake the chamber is, and whether the wave has run. Both are worth pinning because the
    /// stages are keyed to thresholds — an off-by-one in the count silently skips a beat.
    static func testSceneThreeWakesInStagesAndFiresItsWaveOnce() {
        let gs = GameState(size: PrologueSize.sceneThree, name: "s3", interior: true, stamp: .sceneThree)
        let m = gs.cubeModel
        check(gs.chamberWoken == 0, "the chamber starts dark")
        check(gs.chamberWave == 0, "and the wave has not run")

        var plinths: [(CubeFace, Int, Int)] = []
        for face in CubeFace.allCases {
            for r in 0..<m.size {
                for c in 0..<m.size {
                    guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    if m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .switchCap }) {
                        plinths.append((face, r, c))
                    }
                }
            }
        }
        check(plinths.count == 6, "six plinths")
        let grid = m.worldScale.standGrid
        for (i, p) in plinths.enumerated() {
            gs.player.face = p.0; gs.player.row = p.1; gs.player.col = p.2
            gs.player.subRow = grid / 2; gs.player.subCol = grid / 2
            gs.interact()
            gs.update(deltaTime: 1.0 / 60.0)
            let expected = Float(i + 1) / 6
            check(abs(gs.chamberWoken - expected) < 0.001,
                  "after \(i + 1) plinths the chamber should be \(expected) awake, got \(gs.chamberWoken)")
            // The wave belongs to the SIXTH, not to any earlier one.
            if i < 5 { check(gs.chamberWave == 0, "the wave must not start at \(i + 1) obelisks") }
        }
        // It runs, and it runs once.
        for _ in 0..<400 { gs.update(deltaTime: 1.0 / 60.0) }
        check(gs.chamberWave >= 1, "the wave completes")
        for _ in 0..<400 { gs.update(deltaTime: 1.0 / 60.0) }
        check(gs.chamberWave == 1, "and does not restart — 'then the chamber returns to its darker state'")
    }

    /// A world says where you stand, and that has to hold however you got there. `spawnLocation` was
    /// applied only on arrival THROUGH A PORTAL, so a world entered any other way — the boot world
    /// above all — left the player at PlayerState's default, the centre of the front face.
    ///
    /// Harmless while every world revealed itself at build; fatal once one keeps its fog. It put the
    /// player in the middle of Scene 1's maze with only the clearing revealed, which reads as three
    /// separate bugs at once: no walls, fog where the ground should be, and no clearing in sight.
    static func testWorldsPlaceThePlayerWhereTheySay() {
        for (label, gs) in [("scene-1", GameState(size: PrologueSize.sceneOne, name: "s1", stamp: .sceneOne)),
                            ("scene-2", GameState(size: PrologueSize.sceneTwo, name: "s2", stamp: .sceneTwo)),
                            ("scene-4", GameState(size: PrologueSize.sceneFour, name: "s4", stamp: .sceneFour))] {
            guard let spawn = gs.cubeModel.spawnLocation else {
                check(false, "\(label) should author a spawn"); continue
            }
            check(gs.player.face == spawn.face && gs.player.row == spawn.row && gs.player.col == spawn.col,
                  "\(label) starts the player at (\(gs.player.row),\(gs.player.col)), authored (\(spawn.row),\(spawn.col))")
            check(gs.player.facing == spawn.facing, "\(label) starts the player facing \(spawn.facing)")
            // And the tile under them is one they can see — standing in fog is not a start.
            guard let (ci, fi) = gs.cubeModel.faceletAt(face: gs.player.face, row: gs.player.row, col: gs.player.col)
            else { check(false, "\(label) spawn is off the grid"); continue }
            check(gs.cubeModel.cubies[ci].facelets[fi].tileState != .unknown,
                  "\(label) must not start the player on an unrevealed tile")
        }
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

    static func testSceneOneAmbienceTriggers() {
        let gs = GameState(size: PrologueSize.sceneOne, name: "scene-1", stamp: .sceneOne)
        let m = gs.cubeModel
        check(!gs.hasMoved, "the opening has not been disturbed yet")
        gs.update(deltaTime: 1.0 / 60.0)
        check(!gs.hasMoved, "standing still is not moving")
        // Distance to the arch is measured, and from the clearing it is far.
        guard let far = gs.tilesToNearestPortal else { check(false, "Scene 1 has an arch to be near"); return }
        check(far > 2, "the clearing is not near the arch (got \(far))")
        // Stand ON the arch's tile and it is near.
        var portalAt: (Int, Int)? = nil
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                if m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .portal }) { portalAt = (r, c) }
            }
        }
        guard let pa = portalAt else { return }
        gs.player.row = pa.0; gs.player.col = pa.1
        gs.update(deltaTime: 1.0 / 60.0)
        check((gs.tilesToNearestPortal ?? 99) == 0, "standing at the arch reads as zero tiles away")
        // And the latch: once it has moved, it stays moved.
        gs.player.isMoving = true
        gs.update(deltaTime: 1.0 / 60.0)
        gs.player.isMoving = false
        gs.update(deltaTime: 1.0 / 60.0)
        check(gs.hasMoved, "the undertone latches on: it does not come and go with the player")
    }

    static func testSceneOneCanBeWalkedFromClearingToArch() {
        let gs = GameState(size: PrologueSize.sceneOne, name: "scene-1", stamp: .sceneOne)
        let m = gs.cubeModel
        let n = m.size
        guard let sp = m.spawnLocation else { check(false, "Scene 1 needs a spawn"); return }
        // "Facing roughly north, but not directly toward the opening. The gap rests near the EDGE of
        // the initial view." Due north from the break's own column made it the first thing you saw.
        check(sp.face == .positiveZ, "the player starts on the clearing's face")
        check([Heading8.n, .ne, .nw].contains(sp.facing), "roughly north: got \(sp.facing)")
        // The real assertion is not the compass bearing but that the break is NOT straight ahead:
        // the player must not spawn on the gap's own column looking up it.
        var breakCol: Int? = nil
        for c in 0..<n {
            guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: n - 3, col: c) else { continue }
            if m.cubies[ci].facelets[fi].mazeTile.openings.contains(.north) { breakCol = c }
        }
        check(breakCol != nil, "the clearing needs its break")
        check(breakCol != sp.col, "the break must not be dead ahead of the spawn")

        // Walk the face from the spawn.
        var seen = Set([[sp.row, sp.col]]), q = [[sp.row, sp.col]], head = 0
        while head < q.count {
            let t = q[head]; head += 1
            guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: t[0], col: t[1]) else { continue }
            let op = m.cubies[ci].facelets[fi].mazeTile.openings
            for (mask, dr, dc) in [(DirectionMask.north, -1, 0), (.south, 1, 0), (.west, 0, -1), (.east, 0, 1)]
            where op.contains(mask) {
                let nt = [t[0] + dr, t[1] + dc]
                guard nt[0] >= 0, nt[0] < n, nt[1] >= 0, nt[1] < n, !seen.contains(nt) else { continue }
                seen.insert(nt); q.append(nt)
            }
        }
        // The maze is "approximately three times the playable area of the original clearing" (9 tiles).
        check(seen.count >= 30, "the clearing and maze should be one walkable space, got \(seen.count) tiles")

        var portalAt: [Int]? = nil, vesselTiles = 0, vessels = 0
        for r in 0..<n {
            for c in 0..<n {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                let props = m.cubies[ci].facelets[fi].props
                if props.contains(where: { $0.kind == .portal }) { portalAt = [r, c] }
                let v = props.filter { $0.kind == .layeredVessel }.count
                if v > 0 { vesselTiles += 1; vessels += v }
            }
        }
        guard let pa = portalAt else { check(false, "Scene 1 needs its archway"); return }
        check(seen.contains(pa), "the arch must be reachable — it is the only way out of the scene")
        // "By the fourth, the vessels no longer feel like decoration." There have to BE four.
        check(vesselTiles >= 4, "the maze needs several vessel sites, got \(vesselTiles)")
        check(vessels > vesselTiles, "some sites hold groups, not just solitary vessels")
        for r in 0..<n {
            for c in 0..<n {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c),
                      m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .layeredVessel }) else { continue }
                check(seen.contains([r, c]) || [r, c] == pa, "a vessel at (\(r),\(c)) is walled off")
            }
        }
        // Scene 1 is revealed in full: the walk-in reveal read as blocks lifting off rather than as
        // distance resolving, because the fog is a volume and not a horizon (Eddie). The gradual
        // scale the script wants needs a different mechanism, not this one.
        var discovered = 0
        for r in 0..<n {
            for c in 0..<n {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: c) else { continue }
                if m.cubies[ci].facelets[fi].tileState == .discovered { discovered += 1 }
            }
        }
        check(discovered == n * n, "Scene 1 starts fully revealed, got \(discovered) of \(n * n)")
        // The verb does not exist yet, and nothing here is bonded — Scene 1 has no lock at all.
        check(m.bondedGroups.isEmpty, "Scene 1 has no lock; it is an opening, not a puzzle")
    }

    static func testVesselCanBeApproached() {
        let gs = GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour)
        let m = gs.cubeModel
        let grid = m.worldScale.standGrid, step = m.worldScale.standStep
        check(PropKind.layeredVessel.footprintRadius(grid: grid) == 0,
              "a vase narrower than one stand cell should block only the cell it stands on")
        var found = false
        for cu in m.cubies {
            for f in cu.facelets {
                guard let vessel = f.props.first(where: { $0.kind == .layeredVessel }) else { continue }
                found = true
                let k = grid / 3
                let rc = vessel.subRow * k + k / 2, cc = vessel.subCol * k + k / 2
                check(vessel.blocks(rc, cc, grid: grid, standStep: step), "it still stands somewhere")
                // Every neighbouring stand cell is free, so you can walk right up to it and look.
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1)] {
                    check(!vessel.blocks(rc + dr, cc + dc, grid: grid, standStep: step),
                          "the cell at (\(dr),\(dc)) beside the vessel should be walkable")
                    check(f.mazeTile.isStandable(rc + dr, cc + dc, grid: grid, fullWidthGateways: m.fullWidthGateways),
                          "the tile itself should allow standing at (\(dr),\(dc))")
                }
            }
        }
        check(found, "Scene 4 should have a vessel to approach")
    }

    /// The arrival doorway closes behind you (Scene 2A) — and must take ONLY itself with it. Its veil
    /// and ring are the same two prop kinds the scene's real exit portal uses, so a cleanup that
    /// matched by kind swept the whole world and stripped the exit of its visuals.
    static func testClosingDoorwayLeavesTheRealPortalAlone() {
        let gs = GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour)
        let m = gs.cubeModel
        func portalDressing() -> Int {
            var n = 0
            for cu in m.cubies { for f in cu.facelets {
                n += f.props.filter { ($0.kind == .portalField || $0.kind == .portalRing) && $0.anim <= 0.5 }.count
            } }
            return n
        }
        let before = portalDressing()
        check(before > 0, "Scene 4's exit portal should have a veil and a ring to protect")
        gs.closeArrivalDoorway()
        check(portalDressing() == before, "closing must not disturb the real portal's dressing")
        for _ in 0..<300 { gs.update(deltaTime: 1.0 / 60.0) }
        check(portalDressing() == before, "and the real portal still has them once it is gone")
        var arrivals = 0
        for cu in m.cubies { for f in cu.facelets {
            arrivals += f.props.filter { ($0.kind == .portalField || $0.kind == .portalRing) && $0.anim > 0.5 }.count
        } }
        check(arrivals == 0, "the arrival doorway itself is gone, not merely invisible")
    }

    /// Scene 4's payoff, end to end, and the assertion the whole scene rests on: the portal is
    /// UNREACHABLE until the turn, and reachable after it.
    ///
    /// "A portal is present, but the maze does not connect to it… the maze route leading toward it
    /// terminates against a closed wall at the boundary between the current outer slice and the rest
    /// of the world."
    ///
    /// The boundary is the only thing a turn can edit: the slab is the whole +Z face plus a one-tile
    /// ring, all of which rotates together, so a turn cannot change reachability WITHIN +Z. This
    /// walks the real thing — every face, crossing cube edges properly — because that conjugation is
    /// exactly what intuition gets wrong.
    static func testSceneFourRouteCompletesOnlyAfterTheTurn() {
        let gs = GameState(size: PrologueSize.sceneFour, name: "scene-4", stamp: .sceneFour)
        let m = gs.cubeModel
        let n = m.size

        struct T: Hashable { let f: Int; let r: Int; let c: Int }
        func reachable(from s: T) -> Set<T> {
            var seen: Set<T> = [s]; var q = [s]; var h = 0
            while h < q.count {
                let t = q[h]; h += 1
                guard let face = CubeFace(rawValue: t.f),
                      let (ci, fi) = m.faceletAt(face: face, row: t.r, col: t.c) else { continue }
                let op = m.cubies[ci].facelets[fi].mazeTile.openings
                for (dir, mask, dr, dc) in [(SurfaceDirection.north, DirectionMask.north, -1, 0),
                                            (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)] {
                    guard op.contains(mask) else { continue }
                    let nr = t.r + dr, nc = t.c + dc
                    let nt: T
                    if nr >= 0, nr < n, nc >= 0, nc < n { nt = T(f: t.f, r: nr, c: nc) }
                    else {
                        let cr = m.edgeCrossing(face: face, direction: dir, row: t.r, col: t.c)
                        nt = T(f: cr.face.rawValue, r: cr.row, c: cr.col)
                    }
                    if !seen.contains(nt) { seen.insert(nt); q.append(nt) }
                }
            }
            return seen
        }
        func locate(_ kind: PropKind) -> [T] {
            var out: [T] = []
            for f in CubeFace.allCases {
                for r in 0..<n {
                    for c in 0..<n {
                        guard let (ci, fi) = m.faceletAt(face: f, row: r, col: c) else { continue }
                        if m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == kind }) {
                            out.append(T(f: f.rawValue, r: r, c: c))
                        }
                    }
                }
            }
            return out
        }
        guard let sp = m.spawnLocation else { check(false, "Scene 4 needs a spawn"); return }

        var seen = reachable(from: T(f: sp.face.rawValue, r: sp.row, c: sp.col))
        let portal = locate(.portal)
        check(portal.count == 1, "Scene 4 has one portal")
        check(!seen.contains(portal[0]), "the portal must NOT be reachable before the turn")
        // …but the puzzle must be solvable: every anchor has to be walkable to, or the scene is a
        // dead end rather than a lock. This is the half that a route puzzle most easily breaks.
        let anchors = locate(.anchor)
        check(anchors.count == 3, "three anchors")
        for a in anchors { check(seen.contains(a), "anchor at (\(a.f),\(a.r),\(a.c)) must be reachable") }
        // The VESSEL above all: it grants the twist, so if it is stranded the scene deadlocks —
        // no verb, no turn, no route, nothing the player can do. Sealing the portal's corner
        // orphaned it once already, because its only path ran through that corner.
        let vessel = locate(.layeredVessel)
        check(vessel.count == 1, "one vessel")
        check(seen.contains(vessel[0]), "the vessel MUST be reachable or the scene cannot be started")
        // Nothing else on the start face should be walled off by accident. Only the portal's own
        // corner is meant to be unreachable, and that is the puzzle.
        var strandedOnStartFace = 0
        for r in 0..<n {
            for c in 0..<n where !seen.contains(T(f: CubeFace.positiveZ.rawValue, r: r, c: c)) {
                strandedOnStartFace += 1
            }
        }
        check(strandedOnStartFace == 4,
              "only the portal's 4-tile corner should be cut off, found \(strandedOnStartFace)")

        // Release the anchors and take the turn.
        while !m.bondedGroups.isEmpty { m.removeBond(containing: m.bondedGroups[0].first!) }
        gs.twistEnabled = true
        gs.startSliceRotation(clockwise: true)
        check(gs.sliceRotation.isActive && !gs.sliceRotation.isRefusal,
              "with no bonds left the turn must be permitted")
        for _ in 0..<600 where gs.sliceRotation.isActive { gs.update(deltaTime: 1.0 / 60.0) }

        guard let sp2 = m.spawnLocation else { return }
        seen = reachable(from: T(f: sp2.face.rawValue, r: sp2.row, c: sp2.col))
        let after = locate(.portal)
        check(after.count == 1 && seen.contains(after[0]),
              "after the turn a route to the portal exists")
        // And the door is not ALSO sealed: the obstacle is the route, one idea, not two locks.
        check(m.sealedPortalCubies.isEmpty, "Scene 4's portal is present and lit, just unreachable")
    }

    /// Scene 2's lock must actually gate the turn. Before the fourth switch the bond straddles the
    /// twistable slab, so the world refuses to move and the rotation control cannot be raised; after
    /// it, the turn is legal. Without this the control is available from the first frame and the
    /// puzzle is decorative.
    static func testSceneTwoLockGatesTheTurn() {
        let gs = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo)
        let m = gs.cubeModel
        guard let s = m.scriptedTwistSlice else { check(false, "Scene 2 must name the slab its lock turns"); return }

        check(!m.bondedGroups.isEmpty, "Scene 2 must start bonded (else the control is free from frame one)")
        check(!m.canRotateSlice(axis: s.axis, index: s.index), "the designated slab must be REFUSED while bonded")

        // The bond has to straddle the slab — inside it only, or outside it only, would not refuse.
        let slab = Set(m.cubieIndicesInSlice(axis: s.axis, index: s.index))
        for g in m.bondedGroups {
            check(!g.isDisjoint(with: slab) && !g.isSubset(of: slab),
                  "the lock bond must straddle the twistable slab to refuse it")
        }

        // Dissolving it (what the fourth switch does) makes the same turn legal.
        m.bondedGroups.removeAll()
        check(m.canRotateSlice(axis: s.axis, index: s.index), "the slab must turn once the lock is dissolved")
    }

    /// Regression (Eddie, size-11 garden): a maze that fills the WHOLE face makes dressedWallProps'
    /// `neighbor()` ask faceletAt for out-of-face (row±1/col±1) tiles. faceletAt must return nil there,
    /// not crash "Index out of range" on the `cachedProjection[face]![row][col]` subscript. This never
    /// fired while the garden was an interior region of a size-25 face.
    static func testFaceletAtBoundsFullFace() {
        let m = GameState(size: 11, name: "garden", stamp: .gardenMaze).cubeModel
        check(m.faceletAt(face: .positiveZ, row: -1, col: 0) == nil, "faceletAt row -1 must be nil")
        check(m.faceletAt(face: .positiveZ, row: 11, col: 0) == nil, "faceletAt row=size must be nil")
        check(m.faceletAt(face: .positiveZ, row: 0, col: -1) == nil, "faceletAt col -1 must be nil")
        check(m.faceletAt(face: .positiveZ, row: 0, col: 11) == nil, "faceletAt col=size must be nil")
        check(m.faceletAt(face: .positiveZ, row: 5, col: 5) != nil, "faceletAt in-range must resolve")
        // The render-time dressed-wall pass drives faceletAt at the face boundary — must not crash.
        let e = m.dressedWallEntries(walls: [8, 9], rocks: [7], bushes: [3, 4],
                                     wallScale: 1, rockScale: 1, bushScale: 1)
        check(e.count > 0, "full-face garden should emit dressed-wall entries")
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

    /// M17 Phase 0 — the player-global knowledge container: memories, glyphs, and the attunement
    /// gradient with its never-fully-clear ceiling.
    static func testPlayerKnowledge() {
        let k = PlayerKnowledge()
        check(k.isEmpty, "fresh knowledge is empty")
        check(!k.hasMemory("temple") && !k.knows(glyph: "mark") && k.attunement(family: "cube") == 0,
              "fresh knowledge queries are all negative/zero")

        // Memories: receive returns true only the first time; then hasMemory holds.
        check(k.receive(memory: "temple"), "first receive is new")
        check(!k.receive(memory: "temple"), "second receive is not new (idempotent)")
        check(k.hasMemory("temple") && !k.hasMemory("moon"), "hasMemory tracks exactly what was received")
        check(!k.isEmpty, "knowledge is no longer empty after a receive")

        // Glyphs: learn is idempotent; queries are exact.
        k.learn(glyph: "temple-mark"); k.learn(glyph: "temple-mark")
        check(k.knows(glyph: "temple-mark") && !k.knows(glyph: "unknown"), "knows tracks learned glyphs")

        // Attunement: rises with learning, monotone, clamped to [0, ceiling], never reaching 1.
        let fam = "hypercube"
        var last = k.attunement(family: fam)
        check(last == 0, "attunement starts at 0")
        for _ in 0..<50 {
            k.attune(family: fam, by: 0.1)
            let now = k.attunement(family: fam)
            check(now >= last, "attunement is monotone non-decreasing")
            check(now <= PlayerKnowledge.attunementCeiling + 1e-6, "attunement never exceeds the ceiling")
            last = now
        }
        check(abs(last - PlayerKnowledge.attunementCeiling) < 1e-6, "attunement saturates AT the ceiling")
        check(PlayerKnowledge.attunementCeiling < 1.0, "the ceiling is below full clarity (never fully understand)")
        // A negative nudge floors at 0, doesn't go negative.
        let fam2 = "twospots"
        k.attune(family: fam2, by: -5)
        check(k.attunement(family: fam2) == 0, "attunement floors at 0")
        // Families are independent.
        check(k.attunement(family: fam) > 0 && k.attunement(family: "untouched") == 0, "per-family attunement is independent")
    }

    /// M19 relief (CPU half) — pins the height field and the displacement so the GPU (Metal) side
    /// can be transcribed to match, and proves amplitude 0 is a strict no-op.
    static func testReliefField() {
        // Bounds: the field is a mean of three sinusoids ⇒ within [−1, 1].
        // Continuity: Lipschitz — a small direction step gives a small height step.
        var prev = CubeModel.reliefHeight(SIMD3(1, 0, 0))
        for i in 0...200 {
            let a = Float(i) / 200.0 * 6.2831853
            let dir = normalize(SIMD3(cosf(a), sinf(a) * 0.6, sinf(a * 0.5)))
            let h = CubeModel.reliefHeight(dir)
            check(h >= -1.0001 && h <= 1.0001, "relief height in range: \(h)")
            // Continuous (no jumps): a ~1.8° direction step gives a bounded height step. Crater
            // rims are legitimately steeper than the open sinusoids, hence the 0.45 bound.
            check(abs(h - prev) < 0.45, "relief height continuous step: \(abs(h - prev))")
            prev = h
        }

        // amplitude 0 ⇒ inflatedUnitPoint is byte-identical to the plain inflation.
        for n in [5, 7] {
            let flat = CubeModel(size: n); flat.roundness = 1.0; flat.reliefAmplitude = 0
            let bumpy = CubeModel(size: n); bumpy.roundness = 1.0; bumpy.reliefAmplitude = 0.05
            let samples: [(Float, Float, Float)] = [(0.3, 0.2, 1.0), (-0.5, 0.9, 0.1), (1.0, -0.4, 0.6)]
            for (px, py, pz) in samples {
                let p = SIMD3<Float>(px, py, pz)
                let base = flat.inflatedUnitPoint(p)
                let bumped = bumpy.inflatedUnitPoint(p)
                // No-op at amplitude 0: bumpy must equal a hand-applied radial push of base.
                let lensq: Float = base.x*base.x + base.y*base.y + base.z*base.z
                let len = lensq.squareRoot()
                let dir = base / len
                let scale: Float = 1 + 0.05 * CubeModel.reliefHeight(dir)
                let expected = base * scale
                check(approx(bumped, expected, 1e-5), "relief displacement matches formula (size \(n))")
                // And amplitude 0 leaves it exactly at base.
                let noop = CubeModel(size: n); noop.roundness = 1.0
                check(approx(noop.inflatedUnitPoint(p), base, 1e-6), "relief amplitude 0 is a no-op")
            }
        }
    }

    /// M18 Phase 2 — a solid prop removes exactly the k×k stand block of its author sub-cell;
    /// a walk-through prop removes nothing.
    static func testPropFootprint() {
        for d in [3, 9, 15] {
            let k = d / 3
            for ar in 0..<3 { for ac in 0..<3 {
                let solid = Prop(kind: .topiary, subRow: ar, subCol: ac)   // a DEFAULT-footprint solid prop
                let walkThrough = Prop(kind: .portal, subRow: ar, subCol: ac)
                for sr in 0..<d { for sc in 0..<d {
                    let inBlock = sr >= ar * k && sr < ar * k + k && sc >= ac * k && sc < ac * k + k
                    check(solid.blocks(sr, sc, grid: d) == inBlock,
                          "footprint d=\(d) topiary@(\(ar),\(ac)): cell (\(sr),\(sc)) expected \(inBlock)")
                    check(!walkThrough.blocks(sr, sc, grid: d),
                          "footprint d=\(d) portal@(\(ar),\(ac)): cell (\(sr),\(sc)) must be walk-through")
                } }
            } }
            // The three author cells tile the axis with no overlap and no gap. Probe along
            // author row 0 (stand row 0 sits inside author row 0's block).
            var covered = Array(repeating: 0, count: d)
            for ac in 0..<3 {
                // Use a DEFAULT-footprint prop. This used to be a dial, which now blocks only its own
                // cell — small flat things set into the ground had inherited a 6.3 m footprint and
                // were fencing off the middle of their own tiles invisibly.
                let p = Prop(kind: .topiary, subRow: 0, subCol: ac)
                for sc in 0..<d where p.blocks(0, sc, grid: d) { covered[sc] += 1 }
            }
            check(covered.allSatisfy { $0 == 1 }, "footprint d=\(d): author thirds tile the stand grid exactly")
        }
    }

    /// M18 Phase 2 — the connectivity guard: in every authored world, no prop footprint may
    /// sever a tile — whichever gateway you enter by, you can reach every other gateway of
    /// that tile. BFS (8-connected, matching movement) over walkable stand cells; assert all
    /// walkable border cells land in one component. This is what turns an authoring mistake
    /// (a prop dropped across the only route) into a red test instead of an unwinnable maze.
    static func testPropConnectivity() {
        let cases: [(String, WorldStamp, Int, Bool)] = [
            ("overworld", .overworldDemo, 9, false),
            ("overworld", .overworldDemo, 5, false),
            ("moon",      .moonDemo,      5, false),
            ("temple",    .templeInterior, 5, true),
            ("natural",   .natural,       7, false),
            ("natural",   .natural,       3, false),
            ("lunar",     .lunar,         3, false),
            ("lunar",     .lunar,         5, false),
        ]
        for (label, stamp, n, interior) in cases {
            let m = CubeModel(worldScale: WorldScale(cubeSize: n, interior: interior), stamp: stamp)
            let d = m.worldScale.standGrid
            for face in CubeFace.allCases {
                for r in 0..<n { for c in 0..<n {
                    guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    let tile = m.cubies[ci].facelets[fi].mazeTile
                    let props = m.cubies[ci].facelets[fi].props
                    func walk(_ sr: Int, _ sc: Int) -> Bool {
                        tile.isStandable(sr, sc, grid: d) && !props.contains { $0.blocks(sr, sc, grid: d) }
                    }
                    var border: [(Int, Int)] = []
                    for i in 0..<d {
                        if walk(0, i)     { border.append((0, i)) }
                        if walk(d - 1, i) { border.append((d - 1, i)) }
                        if walk(i, 0)     { border.append((i, 0)) }
                        if walk(i, d - 1) { border.append((i, d - 1)) }
                    }
                    guard let start = border.first else { continue }
                    var seen = Set<Int>([start.0 * d + start.1])
                    var stack = [start]
                    while let (sr, sc) = stack.popLast() {
                        for ddr in -1...1 { for ddc in -1...1 where !(ddr == 0 && ddc == 0) {
                            let nr = sr + ddr, nc = sc + ddc
                            guard (0..<d).contains(nr), (0..<d).contains(nc), walk(nr, nc) else { continue }
                            if seen.insert(nr * d + nc).inserted { stack.append((nr, nc)) }
                        } }
                    }
                    for (br, bc) in border {
                        check(seen.contains(br * d + bc),
                              "\(label) n=\(n) \(face)(\(r),\(c)): gateway cell (\(br),\(bc)) severed by a prop footprint")
                    }
                } }
            }
        }
    }

    /// M18 Phase 1 — hand-derived walkability truths (non-circular: expectations written out
    /// case by case, not recomputed from the same formula).
    static func testStandableRules() {
        let d = 9, c = 4
        // A north-gateway corridor tile: gap cells on the north border only, everything
        // interior walkable (grass), all other borders wall-claimed.
        let gate = MazeTile(openings: [.north], styleSeed: 0)
        check(gate.isStandable(0, c, grid: d), "gateway: north gap centre standable")
        check(gate.isStandable(0, 3, grid: d) && gate.isStandable(0, 5, grid: d), "gateway: full gap third standable")
        check(!gate.isStandable(0, 2, grid: d) && !gate.isStandable(0, 6, grid: d), "gateway: jamb cells blocked")
        check(!gate.isStandable(0, 0, grid: d) && !gate.isStandable(0, d - 1, grid: d), "gateway: north corners blocked")
        check(!gate.isStandable(d - 1, c, grid: d), "gateway: closed south border blocked")
        check(!gate.isStandable(c, 0, grid: d) && !gate.isStandable(c, d - 1, grid: d), "gateway: closed west/east borders blocked")
        check(gate.isStandable(1, 1, grid: d) && gate.isStandable(c, c, grid: d) && gate.isStandable(d - 2, d - 2, grid: d),
              "gateway: interior grass standable everywhere")
        // A room-interior tile (north fully open): whole north border standable except the
        // corners its closed side edges claim.
        let room = MazeTile(openings: [.north], styleSeed: 0, openEdges: [.north])
        check(room.isStandable(0, 1, grid: d) && room.isStandable(0, c, grid: d) && room.isStandable(0, d - 2, grid: d),
              "open edge: border standable")
        check(!room.isStandable(0, 0, grid: d) && !room.isStandable(0, d - 1, grid: d),
              "open edge: corners still claimed by the closed side edges")
        // The natural world: everything open ⇒ every cell standable, corners included.
        let all: DirectionMask = [.north, .east, .south, .west]
        let field = MazeTile(openings: all, styleSeed: 0, openEdges: all)
        for r in 0..<d { for cl in 0..<d {
            check(field.isStandable(r, cl, grid: d), "natural: (\(r),\(cl)) standable")
        } }
    }

    /// M18 Phase 1 — world-position-pinned crossing continuity on the stand grid (the M15
    /// technique): walk over every tile seam and cube edge, exterior and interior, cardinal
    /// AND diagonal, from every lateral cell — and pin the world geometry:
    ///   • same-face: the arrival cell's world position must equal the departure tile's
    ///     linear extrapolation (seam invisible by construction);
    ///   • cube-edge: the lateral coordinate along the shared edge axis must be preserved
    ///     (cardinal) or shifted by exactly one stand step (diagonal) — a straight or
    ///     diagonal walk never skips sideways at a fold.
    static func testStandGridCrossing(size n: Int, interior: Bool) {
        let model = CubeModel(worldScale: WorldScale(cubeSize: n, interior: interior), stamp: .natural)
        model.roundness = 0
        // This test isolates crossing GEOMETRY continuity; strip the natural world's water
        // (which correctly refuses entry) and props so every seam is genuinely open — the
        // water-blocks-entry rule is exercised separately in the app, not here.
        for ci in model.cubies.indices {
            for fi in model.cubies[ci].facelets.indices {
                model.cubies[ci].facelets[fi].terrain = .grass
                model.cubies[ci].facelets[fi].props.removeAll()
            }
        }
        let ws = model.worldScale
        let d = ws.standGrid, c = d / 2
        let step = ws.standStep * ws.cellSpacing
        let tag = interior ? "int" : "ext"

        func pos(_ f: CubeFace, _ r: Int, _ cl: Int, _ sr: Int, _ sc: Int) -> SIMD3<Float> {
            col3(model.inflatedPlacement(face: f, row: r, col: cl,
                                         localX: Float(sc - c) * ws.standStep,
                                         localY: Float(sr - c) * ws.standStep), 3)
        }
        // Border cell of edge `dir` at lateral index `lat`.
        func borderCell(_ dir: SurfaceDirection, _ lat: Int) -> (Int, Int) {
            switch dir {
            case .north: return (0, lat)
            case .south: return (d - 1, lat)
            case .west:  return (lat, 0)
            case .east:  return (lat, d - 1)
            }
        }
        // Travel headings that exit through `dir`: the cardinal and its two diagonals.
        func travels(_ dir: SurfaceDirection) -> [Heading8] {
            let card = Heading8.from(surfaceDirection: dir)
            let left = Heading8(rawValue: (card.rawValue + 1) % 8)!
            let right = Heading8(rawValue: (card.rawValue + 7) % 8)!
            return [card, left, right]
        }

        for face in CubeFace.allCases {
            for dir in [SurfaceDirection.north, .south, .east, .west] {
                // One tile mid-face (same-face seam) and one on the cube edge (fold).
                let mid = n / 2
                let edgeTile: (Int, Int)
                let midTile: (Int, Int)
                switch dir {
                case .north: edgeTile = (0, mid); midTile = (mid, mid)
                case .south: edgeTile = (n - 1, mid); midTile = (mid == 0 ? 0 : mid - 1, mid)
                case .west:  edgeTile = (mid, 0); midTile = (mid, mid)
                case .east:  edgeTile = (mid, n - 1); midTile = (mid, mid == 0 ? 0 : mid - 1)
                }
                for (row, col) in [edgeTile, midTile] {
                    for lat in 0..<d {
                        for travel in travels(dir) {
                            let (sr, sc) = borderCell(dir, lat)
                            var p = PlayerState(size: n, standGrid: d)
                            p.face = face; p.row = row; p.col = col
                            p.subRow = sr; p.subCol = sc
                            p.facing = travel
                            p.tryMoveForward(cubeModel: model)

                            // Does this hop exit at all? The lateral shift must stay on the edge;
                            // a shifted-out diagonal is a legal *within-tile*… no — from a border
                            // cell every travel through `dir` leaves the grid. Shift out of range ⇒
                            // refused (corner-to-corner), which is the spec.
                            let (dr, dc) = travel.subDelta
                            let shifted = (dir == .north || dir == .south) ? sc + dc : sr + dr
                            guard (0..<d).contains(shifted) else {
                                check(!p.isMoving, "size \(n) \(tag) \(face) \(dir) lat \(lat) \(travel): corner exit must refuse")
                                continue
                            }
                            check(p.isMoving, "size \(n) \(tag) \(face) \(dir) lat \(lat) \(travel): crossing must start")
                            guard p.isMoving else { continue }
                            _ = p.updateMovement(deltaTime: 10)

                            let dep = pos(face, row, col, sr, sc)
                            let arr = pos(p.face, p.row, p.col, p.subRow, p.subCol)
                            let lateralShift = Float(abs(travel.rawValue % 2 == 0 ? 0 : 1)) * step

                            if p.face == face {
                                // Same-face: exact — the neighbor's cell IS the linear extrapolation.
                                let expected = pos(face, row, col, sr + dr, sc + dc)
                                check(approx(arr, expected, 2e-4),
                                      "size \(n) \(tag) \(face) \(dir) lat \(lat) \(travel): same-face seam exact")
                            } else {
                                // Cube edge: lateral position along the shared edge axis is pinned.
                                let axis = normalize(cross(face.normal, p.face.normal))
                                let latErr = abs(abs(dot(arr - dep, axis)) - lateralShift)
                                check(latErr < 2e-4,
                                      "size \(n) \(tag) \(face) \(dir) lat \(lat) \(travel): edge lateral drift \(latErr)")
                                check(length(arr - dep) < 1.6 * step,
                                      "size \(n) \(tag) \(face) \(dir) lat \(lat) \(travel): fold distance \(length(arr - dep))")
                            }
                        }
                    }
                }
            }
        }
    }

    /// M18 Phase 0 — the generalized stand-grid path cross must agree with the legacy 3×3
    /// rule at every density: cross cells walkable exactly per openings, everything off the
    /// centre row/column never walkable, and the d-grid cross a strict scale-up of the 3×3.
    static func testStandGridPathCross() {
        let combos: [DirectionMask] = {
            var out: [DirectionMask] = []
            for bits in 0..<16 {
                var m = DirectionMask()
                if bits & 1 != 0 { m.insert(.north) }
                if bits & 2 != 0 { m.insert(.east) }
                if bits & 4 != 0 { m.insert(.south) }
                if bits & 8 != 0 { m.insert(.west) }
                out.append(m)
            }
            return out
        }()
        for openings in combos {
            let tile = MazeTile(openings: openings, styleSeed: 0)
            for d in [3, 9, 15] {
                let c = d / 2
                for r in 0..<d {
                    for cl in 0..<d {
                        let walkable = tile.isPathCell(r, cl, grid: d)
                        let expected: Bool
                        if cl == c && r == c { expected = true }
                        else if cl == c { expected = openings.contains(r < c ? .north : .south) }
                        else if r == c { expected = openings.contains(cl < c ? .west : .east) }
                        else { expected = false }
                        check(walkable == expected,
                              "standGrid d=\(d) openings=\(openings.rawValue): cell (\(r),\(cl)) expected \(expected)")
                    }
                }
                // The centre cell is always standable; the four edge-middles gate on openings.
                check(tile.isPathCell(c, c, grid: d), "standGrid d=\(d): centre must be path")
                check(tile.isPathCell(0, c, grid: d) == openings.contains(.north), "standGrid d=\(d): north edge-middle")
                check(tile.isPathCell(d - 1, c, grid: d) == openings.contains(.south), "standGrid d=\(d): south edge-middle")
                check(tile.isPathCell(c, 0, grid: d) == openings.contains(.west), "standGrid d=\(d): west edge-middle")
                check(tile.isPathCell(c, d - 1, grid: d) == openings.contains(.east), "standGrid d=\(d): east edge-middle")
            }
            // Legacy agreement: the default grid is the old 3×3 rule verbatim.
            for r in 0...2 {
                for cl in 0...2 {
                    check(tile.isPathCell(r, cl) == tile.isPathCell(r, cl, grid: 3),
                          "legacy 3×3 default disagrees at (\(r),\(cl))")
                }
            }
        }
    }

    // MARK: - Helpers

    static func delta(_ a: SIMD3<Int32>, _ b: SIMD3<Int32>) -> SIMD3<Int32> {
        SIMD3(b.x - a.x, b.y - a.y, b.z - a.z)
    }

    static func intStep(_ v: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(Int32(v.x.rounded()), Int32(v.y.rounded()), Int32(v.z.rounded()))
    }

    static func borderCell(dir: SurfaceDirection, i: Int, n: Int) -> (row: Int, col: Int) {
        switch dir {
        case .north: return (0, i)
        case .south: return (n - 1, i)
        case .east:  return (i, n - 1)
        case .west:  return (i, 0)
        }
    }

    static func checkBijection(_ model: CubeModel, size n: Int, label: String) {
        var seen = Set<Int>()
        for face in CubeFace.allCases {
            for row in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = model.faceletAt(face: face, row: row, col: col) else {
                        check(false, "size \(n) \(label): faceletAt(\(face),\(row),\(col)) is nil")
                        continue
                    }
                    let id = model.cubies[ci].facelets[fi].id.rawValue
                    check(!seen.contains(id), "size \(n) \(label): duplicate facelet \(id) at (\(face),\(row),\(col))")
                    seen.insert(id)
                }
            }
        }
        check(seen.count == 6 * n * n, "size \(n) \(label): expected \(6 * n * n) unique facelets, got \(seen.count)")
    }

    // MARK: - Tests

    static func testProjectionBijection(size n: Int) {
        checkBijection(CubeModel(size: n), size: n, label: "initial")
    }

    static func testGridWorldConsistency(size n: Int) {
        let model = CubeModel(size: n)
        for face in CubeFace.allCases {
            let tan = intStep(face.tangent)
            let bit = intStep(face.bitangent)
            for row in 0..<n {
                for col in 0..<n {
                    guard let (ci, _) = model.faceletAt(face: face, row: row, col: col) else { continue }
                    let p = model.cubies[ci].position
                    if col + 1 < n, let (ci2, _) = model.faceletAt(face: face, row: row, col: col + 1) {
                        let d = delta(p, model.cubies[ci2].position)
                        check(d == tan, "size \(n) \(face): col step (\(row),\(col))→(\(row),\(col + 1)) expected \(tan) got \(d)")
                    }
                    if row + 1 < n, let (ci2, _) = model.faceletAt(face: face, row: row + 1, col: col) {
                        let d = delta(p, model.cubies[ci2].position)
                        check(d == bit, "size \(n) \(face): row step (\(row),\(col))→(\(row + 1),\(col)) expected \(bit) got \(d)")
                    }
                }
            }
        }
    }

    static func testEdgeCrossingRoundTrip(size n: Int) {
        for face in CubeFace.allCases {
            for dir in SurfaceDirection.allCases {
                for i in 0..<n {
                    let (r, c) = borderCell(dir: dir, i: i, n: n)
                    let out = EdgeCrossing.cross(face: face, direction: dir, row: r, col: c, cubeSize: n)
                    let back = EdgeCrossing.cross(face: out.face, direction: out.facing.opposite, row: out.row, col: out.col, cubeSize: n)
                    check(back.face == face && back.row == r && back.col == c,
                          "size \(n): roundtrip \(face) \(dir) (\(r),\(c)) → \(out.face)(\(out.row),\(out.col)) f=\(out.facing) → back \(back.face)(\(back.row),\(back.col))")
                    check(back.facing == dir.opposite,
                          "size \(n): roundtrip facing \(face) \(dir): back facing \(back.facing) expected \(dir.opposite)")
                }
            }
        }
    }

    static func testSliceRotation(size n: Int) {
        let model = CubeModel(size: n)
        let orig = model.cubies.map { $0.position }
        let axis = 2, index = n - 1
        let angle: Float = -.pi / 2

        // Stamp a prop on a facelet of a cubie in this slice, to verify props ride the rotation
        // end-to-end (applySliceRotation → Prop.rotate) and a full 4-turn cycle restores them —
        // the M12-E house-split invariant, exercised through the real machinery, not in isolation.
        let sliceCubies = model.cubieIndicesInSlice(axis: axis, index: index)
        var propCubie = -1
        if let ci = sliceCubies.first(where: { !model.cubies[$0].facelets.isEmpty }) {
            propCubie = ci
            model.cubies[ci].facelets[0].props.append(Prop(kind: .topiary, subRow: 0, subCol: 1, facing: .n))
        }

        model.applySliceRotation(axis: axis, index: index, angle: angle)
        checkBijection(model, size: n, label: "after 1 z-rotation")

        model.applySliceRotation(axis: axis, index: index, angle: angle)
        model.applySliceRotation(axis: axis, index: index, angle: angle)
        model.applySliceRotation(axis: axis, index: index, angle: angle)
        for i in model.cubies.indices {
            check(model.cubies[i].position == orig[i],
                  "size \(n): cubie \(i) pos after 4 z-turns \(model.cubies[i].position) != orig \(orig[i])")
        }
        checkBijection(model, size: n, label: "after 4 z-rotations")

        // The stamped prop rode all four turns and returned to its original sub-cell + facing.
        if propCubie >= 0, let p = model.cubies[propCubie].facelets[0].props.first {
            check(p.subRow == 0 && p.subCol == 1 && p.facing == .n,
                  "size \(n): prop after 4 z-turns (\(p.subRow),\(p.subCol),\(p.facing)) != (0,1,n)")
        }
    }

    static func testDirectionMaskRotation() {
        for raw in 0..<16 {
            let m = DirectionMask(rawValue: UInt8(raw))
            let masked = m.rawValue & 0x0F
            check(m.rotated(quarterTurns: 4).rawValue == masked, "mask \(raw): 4-turn identity")
            check(m.rotated(quarterTurns: 0).rawValue == masked, "mask \(raw): 0-turn identity")
            var r = m
            for _ in 0..<4 { r = r.rotated(quarterTurns: 1) }
            check(r.rawValue == masked, "mask \(raw): 1×4 identity")
            check(m.rotated(quarterTurns: -1).rawValue == m.rotated(quarterTurns: 3).rawValue, "mask \(raw): -1 == 3")
        }
        // Bit layout N=1<<0, E=1<<1, S=1<<2, W=1<<3 → +1 turn shifts N→E→S→W.
        check(DirectionMask.north.rotated(quarterTurns: 1).rawValue == DirectionMask.east.rawValue, "north→east on +1 turn")
        check(DirectionMask.east.rotated(quarterTurns: 1).rawValue == DirectionMask.south.rawValue, "east→south on +1 turn")
        check(DirectionMask.south.rotated(quarterTurns: 1).rawValue == DirectionMask.west.rawValue, "south→west on +1 turn")
        check(DirectionMask.west.rotated(quarterTurns: 1).rawValue == DirectionMask.north.rawValue, "west→north on +1 turn")
    }

    /// Find the cubie whose integer position matches (x,y,z), if it exists.
    static func cubieIndex(_ m: CubeModel, _ x: Int, _ y: Int, _ z: Int) -> Int? {
        m.cubies.firstIndex { $0.position == SIMD3<Int32>(Int32(x), Int32(y), Int32(z)) }
    }

    /// Bandaging (M13): a slice twist is legal iff every bonded group is entirely inside or entirely
    /// outside the rotating slice. A group that straddles the slice would be torn → refused.
    static func testBandagedLegality(size n: Int) {
        // A bare world: the overworld stamp now ships with the M16.1 temple bond built in,
        // so bandaging invariants are tested on an unstamped model.
        let m = CubeModel(worldScale: WorldScale(cubeSize: n), stamp: .bare)
        // No bonds → every slice is legal.
        for axis in 0..<3 {
            for index in 0..<n {
                check(m.canRotateSlice(axis: axis, index: index), "size \(n): no bonds → (\(axis),\(index)) legal")
            }
        }
        // Bond two cubies that share the z=n-1 and y=0 slices but differ in x — a straddle across x.
        guard let a = cubieIndex(m, 0, 0, n - 1), let b = cubieIndex(m, n - 1, 0, n - 1) else {
            check(false, "size \(n): bond cubies not found"); return
        }
        m.addBond([a, b])
        // Slices holding BOTH bonded cubies → legal (the whole bond moves together).
        check(m.canRotateSlice(axis: 2, index: n - 1), "size \(n): z=n-1 holds both → legal")
        check(m.canRotateSlice(axis: 1, index: 0),     "size \(n): y=0 holds both → legal")
        // Slices holding exactly ONE → illegal (would tear the bond).
        check(!m.canRotateSlice(axis: 0, index: 0),     "size \(n): x=0 holds only a → illegal")
        check(!m.canRotateSlice(axis: 0, index: n - 1), "size \(n): x=n-1 holds only b → illegal")
        // Slices holding NEITHER → legal.
        check(m.canRotateSlice(axis: 2, index: 0), "size \(n): z=0 holds neither → legal")
        // The bond survives a full 4-turn cycle of a legal (fully-in) slice: indices stay valid,
        // positions restore, and the same straddle is illegal again.
        for _ in 0..<4 { m.applySliceRotation(axis: 2, index: n - 1, angle: -.pi / 2) }
        check(!m.canRotateSlice(axis: 0, index: 0),    "size \(n): after 4 turns, x=0 straddle still illegal")
        check(m.canRotateSlice(axis: 2, index: n - 1), "size \(n): after 4 turns, z=n-1 still legal")

        // M16.1 groundwork — removeBond (understanding undoes a lock). Both bonds straddle the
        // x=0 slice, so it only becomes legal when BOTH are gone: removing one leaves the other
        // enforcing (bonds are independent), removing the second restores legality, and a repeat
        // remove is a no-op.
        guard let c = cubieIndex(m, 0, n - 1, 0), let d = cubieIndex(m, n - 1, n - 1, 0) else {
            check(false, "size \(n): second-bond cubies not found"); return
        }
        m.addBond([c, d])   // second, independent bond — also straddles x (c at x=0, d at x=n-1)
        check(m.removeBond(containing: a), "size \(n): removeBond finds bond 1 via a member")
        check(!m.canRotateSlice(axis: 0, index: 0), "size \(n): x=0 still illegal — bond 2 untouched")
        check(m.removeBond(containing: c), "size \(n): removeBond finds bond 2 via a member")
        check(m.canRotateSlice(axis: 0, index: 0), "size \(n): x=0 legal once fully unbonded")
        check(!m.removeBond(containing: a), "size \(n): repeat remove is a no-op")
    }

    static func testPropRotation() {
        // A placed prop must stay glued to its tile through a slice rotation: `Prop.rotate`
        // rotates the sub-cell offset and facing in the DirectionMask.rotated sense (N→E).
        // Exhaustively check the round-trip / identity laws over every sub-cell and facing.
        for subRow in 0...2 {
            for subCol in 0...2 {
                for facing in Heading8.allCases {
                    let base = Prop(kind: .topiary, subRow: subRow, subCol: subCol, facing: facing)
                    let tag = "(\(subRow),\(subCol),\(facing))"

                    // 0-turn is a no-op.
                    var p0 = base; p0.rotate(quarterTurns: 0)
                    check(p0.subRow == subRow && p0.subCol == subCol && p0.facing == facing,
                          "prop 0-turn identity \(tag)")

                    // Four single quarter-turns restore the prop exactly.
                    var pFour = base; for _ in 0..<4 { pFour.rotate(quarterTurns: 1) }
                    check(pFour.subRow == subRow && pFour.subCol == subCol && pFour.facing == facing,
                          "prop 1×4 identity \(tag) → (\(pFour.subRow),\(pFour.subCol),\(pFour.facing))")

                    // A single call of 4 is the same identity.
                    var pQuad = base; pQuad.rotate(quarterTurns: 4)
                    check(pQuad.subRow == subRow && pQuad.subCol == subCol && pQuad.facing == facing,
                          "prop 4-in-one identity \(tag)")

                    // −1 turn equals +3 turns (and neither escapes the 3×3 grid).
                    var pNeg = base; pNeg.rotate(quarterTurns: -1)
                    var pPos = base; pPos.rotate(quarterTurns: 3)
                    check(pNeg.subRow == pPos.subRow && pNeg.subCol == pPos.subCol && pNeg.facing == pPos.facing,
                          "prop −1 == 3 \(tag)")
                    check((0...2).contains(pNeg.subRow) && (0...2).contains(pNeg.subCol),
                          "prop stays in 3×3 grid \(tag) → (\(pNeg.subRow),\(pNeg.subCol))")
                }
            }
        }

        // Rotation sense: the centre sub-cell is fixed; +1 quarter-turn carries the north
        // sub-cell (0,1) to the east (1,2) and advances facing N→E — matching DirectionMask.
        var centre = Prop(kind: .chest, subRow: 1, subCol: 1, facing: .n); centre.rotate(quarterTurns: 1)
        check(centre.subRow == 1 && centre.subCol == 1, "prop centre fixed under rotation")
        check(centre.facing == .e, "prop centre facing N→E on +1 turn")

        var north = Prop(kind: .chest, subRow: 0, subCol: 1, facing: .n); north.rotate(quarterTurns: 1)
        check(north.subRow == 1 && north.subCol == 2, "prop north sub-cell → east (got \(north.subRow),\(north.subCol))")
        check(north.facing == .e, "prop north facing N→E on +1 turn")
    }

    // MARK: - M14b placement invariants (R2.5)

    static func col3(_ m: float4x4, _ i: Int) -> SIMD3<Float> {
        let c = i == 0 ? m.columns.0 : i == 1 ? m.columns.1 : i == 2 ? m.columns.2 : m.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    static func approx(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps
    }

    /// R2.5a — the rest placement is the flat cube placement, independently re-derived:
    /// basis = (tangent, bitangent, normal), center = normal·halfN + tangent·colF + bitangent·rowF.
    /// Also: `inflatedPlacement` at roundness 0 == rest basis with the origin offset in-plane,
    /// and the rest frame must NOT change with roundness (it is the pre-inflation frame).
    static func testRestPlacement(size n: Int) {
        let m = CubeModel(size: n)
        let halfN = Float(n) / 2.0
        let spacing = m.worldScale.cellSpacing
        for face in CubeFace.allCases {
            for row in 0..<n {
                for col in 0..<n {
                    let colF = (Float(col) + 0.5 - halfN) * spacing
                    let rowF = (Float(row) + 0.5 - halfN) * spacing
                    let center = face.normal * halfN + face.tangent * colF + face.bitangent * rowF

                    m.roundness = 0
                    let rest = m.restMatrix(face: face, row: row, col: col)
                    check(approx(col3(rest, 0), face.tangent, 1e-6) &&
                          approx(col3(rest, 1), face.bitangent, 1e-6) &&
                          approx(col3(rest, 2), face.normal, 1e-6),
                          "size \(n): rest basis (\(face),\(row),\(col))")
                    check(approx(col3(rest, 3), center, 1e-5), "size \(n): rest center (\(face),\(row),\(col))")

                    // roundness must not leak into the rest frame
                    m.roundness = 0.7
                    let restR = m.restMatrix(face: face, row: row, col: col)
                    check(approx(col3(restR, 3), center, 1e-5) && approx(col3(restR, 2), face.normal, 1e-6),
                          "size \(n): rest is roundness-independent (\(face),\(row),\(col))")

                    // flat inflatedPlacement == rest basis + in-plane offset origin
                    m.roundness = 0
                    let off = m.inflatedPlacement(face: face, row: row, col: col, localX: 0.25, localY: -0.4)
                    let expected = center + face.tangent * 0.25 + face.bitangent * (-0.4)
                    check(approx(col3(off, 0), face.tangent, 1e-6) && approx(col3(off, 2), face.normal, 1e-6),
                          "size \(n): flat placement basis (\(face),\(row),\(col))")
                    check(approx(col3(off, 3), expected, 1e-5), "size \(n): flat placement origin (\(face),\(row),\(col))")
                }
            }
        }
    }

    /// R2.5b — footprint continuity: adjacent tiles' shared-edge placements coincide (position AND
    /// frame) at several roundness values. This is the property that makes the curved surface
    /// seamless — tile A's east edge and its east neighbour's west edge are the SAME cube point,
    /// so they must inflate to the same place with the same local frame.
    static func testFootprintContinuity(size n: Int) {
        let m = CubeModel(size: n)
        let h = m.worldScale.cellSpacing / 2
        for r: Float in [0.0, 0.3, 1.0] {
            m.roundness = r
            for face in CubeFace.allCases {
                for row in 0..<n {
                    for col in 0..<(n - 1) {   // col-adjacent pair, shared edge at +localX / −localX
                        let a = m.inflatedPlacement(face: face, row: row, col: col, localX: h, localY: 0.2)
                        let b = m.inflatedPlacement(face: face, row: row, col: col + 1, localX: -h, localY: 0.2)
                        check(approx(col3(a, 3), col3(b, 3), 1e-4), "size \(n) r=\(r): col-seam pos (\(face),\(row),\(col))")
                        check(approx(col3(a, 0), col3(b, 0), 1e-4) && approx(col3(a, 2), col3(b, 2), 1e-4),
                              "size \(n) r=\(r): col-seam frame (\(face),\(row),\(col))")
                    }
                }
                for row in 0..<(n - 1) {
                    for col in 0..<n {         // row-adjacent pair, shared edge at +localY / −localY
                        let a = m.inflatedPlacement(face: face, row: row, col: col, localX: -0.3, localY: h)
                        let b = m.inflatedPlacement(face: face, row: row + 1, col: col, localX: -0.3, localY: -h)
                        check(approx(col3(a, 3), col3(b, 3), 1e-4), "size \(n) r=\(r): row-seam pos (\(face),\(row),\(col))")
                        check(approx(col3(a, 2), col3(b, 2), 1e-4), "size \(n) r=\(r): row-seam normal (\(face),\(row),\(col))")
                    }
                }
            }
            // Cross-face: +Z's east edge meets +X's west edge at the same cube point — positions
            // must coincide there too (frames legitimately differ; each face has its own basis).
            for row in 0..<n {
                let a = m.inflatedPlacement(face: .positiveZ, row: row, col: n - 1, localX: h, localY: 0)
                let b = m.inflatedPlacement(face: .positiveX, row: row, col: 0, localX: -h, localY: 0)
                check(approx(col3(a, 3), col3(b, 3), 1e-4), "size \(n) r=\(r): cross-face edge pos row \(row)")
            }
        }
    }

    /// R2.5d — golden values for the Cobb cube→sphere map. These constants were computed
    /// independently (double-precision, outside this codebase) and double as the spec that BOTH
    /// twin implementations must match: `CubeModel.inflatedUnitPoint` (tested here) and
    /// `m14bInflate` in Shaders.metal (same math on the GPU; guarded by review + this spec).
    static func testInflateGoldens() {
        let m = CubeModel(size: 3)
        let cases: [(p: SIMD3<Float>, r: Float, want: SIMD3<Float>)] = [
            (SIMD3( 1.0, 0.5, -0.25), 0.5, SIMD3( 0.9606947,  0.4249256, -0.2096254)),
            (SIMD3( 1.0, 0.5, -0.25), 1.0, SIMD3( 0.9213893,  0.3498512, -0.1692508)),
            (SIMD3( 0.2, -0.8,  0.6), 0.5, SIMD3( 0.1759474, -0.7588426,  0.5452917)),
            (SIMD3( 0.2, -0.8,  0.6), 1.0, SIMD3( 0.1518947, -0.7176852,  0.4905833)),
            (SIMD3( 1.0,  1.0,  1.0), 1.0, SIMD3( 0.5773503,  0.5773503,  0.5773503)),  // corner → 1/√3
            (SIMD3( 1.0,  1.0,  1.0), 0.5, SIMD3( 0.7886751,  0.7886751,  0.7886751)),
            (SIMD3( 0.0,  0.0,  1.0), 1.0, SIMD3( 0.0,        0.0,        1.0)),        // face centre fixed
            (SIMD3(-0.7,  0.3,  1.0), 0.5, SIMD3(-0.5937468,  0.2470180,  0.9256466)),
            (SIMD3(-0.7,  0.3,  1.0), 1.0, SIMD3(-0.4874936,  0.1940361,  0.8512931)),
        ]
        for c in cases {
            m.roundness = c.r
            let got = m.inflatedUnitPoint(c.p)
            check(approx(got, c.want, 5e-6), "inflate golden p=\(c.p) r=\(c.r): got \(got), want \(c.want)")
        }
        // r == 0 is the exact identity (the guard path).
        m.roundness = 0
        let p = SIMD3<Float>(0.37, -0.91, 1.0)
        check(m.inflatedUnitPoint(p) == p, "inflate r=0 identity")
    }

    // MARK: - M15.1 interior-world invariants

    /// Interior placement: the tile sits on the same face plane but is seen from inside — basis
    /// (tangent, −bitangent, −normal), right-handed, with the row *placement* mirrored to match,
    /// so tile-local geometry stays aligned with grid logic.
    static func testInteriorPlacement(size n: Int) {
        let m = CubeModel(worldScale: WorldScale(cubeSize: n, interior: true))
        let halfN = Float(n) / 2.0
        let spacing = m.worldScale.cellSpacing
        for face in CubeFace.allCases {
            for row in [0, n / 2, n - 1] {
                for col in [0, n / 2, n - 1] {
                    let colF = (Float(col) + 0.5 - halfN) * spacing
                    let rowF = (Float(row) + 0.5 - halfN) * spacing
                    let center = face.normal * halfN + face.tangent * colF - face.bitangent * rowF
                    let rest = m.restMatrix(face: face, row: row, col: col)
                    check(approx(col3(rest, 0), face.tangent, 1e-6) &&
                          approx(col3(rest, 1), -face.bitangent, 1e-6) &&
                          approx(col3(rest, 2), -face.normal, 1e-6),
                          "size \(n): interior basis (\(face),\(row),\(col))")
                    check(approx(col3(rest, 3), center, 1e-5), "size \(n): interior center (\(face),\(row),\(col))")
                    // Right-handed: cross(right, up) == forward (det +1 — winding/culling safe).
                    let cr = cross(col3(rest, 0), col3(rest, 1))
                    check(approx(cr, col3(rest, 2), 1e-6), "size \(n): interior handedness (\(face),\(row),\(col))")
                }
            }
        }
    }

    /// Edge-crossing continuity, pinned to WORLD positions: walking off a border cell arrives at a
    /// cell whose shared-edge midpoint is the SAME world point. Run on the exterior first (which
    /// validates the test against the proven table), then on the interior (which validates the
    /// M15.1 conjugated crossing). Also: interior crossings round-trip home.
    static func testEdgeContinuity(size n: Int, interior: Bool) {
        let m = CubeModel(worldScale: WorldScale(cubeSize: n, interior: interior))
        let half = m.worldScale.cellSpacing / 2
        let tag = interior ? "interior" : "exterior"

        // World direction of a grid heading on a face = ± the placement basis columns
        // (grid north = tile-local −y = −up; east = +right) — orientation handled by restMatrix.
        func gridDirWorld(_ rest: float4x4, _ d: SurfaceDirection) -> SIMD3<Float> {
            switch d {
            case .north: return -col3(rest, 1)
            case .south: return  col3(rest, 1)
            case .east:  return  col3(rest, 0)
            case .west:  return -col3(rest, 0)
            }
        }

        for face in CubeFace.allCases {
            for dir in SurfaceDirection.allCases {
                for i in [0, n / 2, n - 1] {
                    let (row, col) = borderCell(dir: dir, i: i, n: n)
                    let rest1 = m.restMatrix(face: face, row: row, col: col)
                    let edge1 = col3(rest1, 3) + gridDirWorld(rest1, dir) * half

                    let x = m.edgeCrossing(face: face, direction: dir, row: row, col: col)
                    let rest2 = m.restMatrix(face: x.face, row: x.row, col: x.col)
                    let edge2 = col3(rest2, 3) + gridDirWorld(rest2, x.facing.opposite) * half
                    check(approx(edge1, edge2, 1e-4),
                          "size \(n) \(tag): edge continuity (\(face),\(dir),\(row),\(col)) → (\(x.face),\(x.row),\(x.col))")

                    // Round-trip: cross back through the edge you came in by.
                    let back = m.edgeCrossing(face: x.face, direction: x.facing.opposite, row: x.row, col: x.col)
                    check(back.face == face && back.row == row && back.col == col,
                          "size \(n) \(tag): round-trip (\(face),\(dir),\(row),\(col))")
                }
            }
        }
    }

    /// R2.16 — the hard size cap: WorldScale clamps cubeSize to maxSupportedSize (25), so a world
    /// bigger than the renderer's instance buffers can hold is impossible to construct.
    static func testSizeCap() {
        check(WorldScale(cubeSize: 99).cubeSize == WorldScale.maxSupportedSize, "size 99 clamps to cap")
        check(WorldScale(cubeSize: 25).cubeSize == 25, "cap itself passes through")
        check(WorldScale(cubeSize: 7).cubeSize == 7, "normal sizes untouched")
        check(WorldScale(cubeSize: 1).cubeSize == 2, "floor clamps to 2")
        check(CubeModel(size: 99).size == WorldScale.maxSupportedSize, "CubeModel inherits the cap")
    }

    /// M20 — the walk-through portal trigger (the two regressions Eddie hit, as permanent guards):
    /// (a) tile-entry must NOT fire it — only reaching the portal's own centre sub-cell does
    ///     ("sensitive" bug: fired half a tile early);
    /// (b) the continuous check must fire when you settle on the centre — not only on tile
    ///     crossings (dead-centre-nothing-happens bug);
    /// (c) priming: a portal you spawn on, stand on, or that re-primes under you (a twist) must
    ///     not teleport you — you have to walk OFF and back ON.
    static func testWalkThroughPortalGating() {
        func makeState() -> GameState {
            let g = GameState(size: 5, name: "portal-test", stamp: .bare)
            let c = g.cubeModel.size / 2
            if let (ci, fi) = g.cubeModel.faceletAt(face: .positiveZ, row: c + 1, col: c) {
                g.cubeModel.cubies[ci].facelets[fi].props.append(
                    Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n, state: 3))
            }
            return g
        }
        let dt: Float = 1.0 / 60.0
        let g = makeState()
        let c = g.cubeModel.size / 2
        let center = g.player.standCenter
        // (prime) player settled off-portal: first update records position, no fire
        g.update(deltaTime: dt)
        check(!g.portalRequested, "portal: no fire while off the portal tile")
        // (a) step onto the portal TILE but at its edge sub-cell — must NOT fire
        g.player.row = c + 1; g.player.col = c
        g.player.subRow = 0; g.player.subCol = center
        g.update(deltaTime: dt)
        check(!g.portalRequested, "portal: entering the tile edge does not fire (the 'sensitive' bug)")
        // (b) reach the CENTRE sub-cell — must fire, with the portal's destination
        g.player.subRow = center; g.player.subCol = center
        g.update(deltaTime: dt)
        check(g.portalRequested, "portal: settling on the centre sub-cell fires")
        check(g.portalDestinationID == 3, "portal: destination rides Prop.state")
        // (c1) standing still must not re-fire
        g.portalRequested = false
        g.update(deltaTime: dt)
        check(!g.portalRequested, "portal: standing on it does not re-fire (edge-triggered)")
        // (c2) re-prime (what a finalized twist does) with the player ON the portal: no fire
        g.reprimePortalZone()
        g.update(deltaTime: dt)
        check(!g.portalRequested, "portal: re-prime on the portal (twist case) does not teleport")
        // walk off and back on — fires again
        g.player.subRow = 0
        g.update(deltaTime: dt)
        g.player.subRow = center
        g.update(deltaTime: dt)
        check(g.portalRequested, "portal: off then back on fires again")
        // (c3) spawn directly on a portal: the first evaluations must not fire
        let g2 = makeState()
        g2.player.row = c + 1; g2.player.col = c
        g2.player.subRow = center; g2.player.subCol = center
        g2.update(deltaTime: dt)
        g2.update(deltaTime: dt)
        check(!g2.portalRequested, "portal: spawning on a portal does not teleport (priming)")
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
