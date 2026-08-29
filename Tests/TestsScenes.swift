import Foundation
import simd

// THE PROLOGUE, SCENE BY SCENE — each scene's own rules, and the proof that each can actually be
// SOLVED by the moves a player has: press this, release that, turn the slice, walk to the arch.
// These are the tests that catch a scene going quietly unsolvable, which no amount of coordinate
// math can see.
//
// Part of `CoordinateMathTests` (split out 2026-08-05 — one 4,158-line file was hard to navigate
// and worse to review). Everything here is an extension on the same type, so the shared helpers and
// `check()` are available exactly as before, and `main()` in CoordinateMathTests.swift still names
// every test it runs. ADDING A FILE HERE MEANS ADDING IT TO `Tests/run-tests.sh` in the same
// commit — the runner lists its sources explicitly and will not find a new one on its own.

extension CoordinateMathTests {
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
            // Found as "the portal", not by its destination index: which world it leads to is a
            // routing decision that has already changed once (temple-interior → Scene 3), and this
            // test is about WHERE the chamber lands, not where it goes.
            if m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .portal }) { chamberAt = (r, col) }
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
                if m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .portal }) { target = (r, c) }
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

    /// Scene 2's puzzle is FINDING FOUR CORNERS, and until now nothing told one corner from another.
    /// 2D asks for "a subtle environmental character" per quadrant — "differing degrees of wall
    /// preservation… distinctions that help orientation without turning the maze into four
    /// colour-coded zones."
    ///
    /// So the assertion is two-sided, and the second half is the one that matters: the quadrants
    /// must differ, and must NOT differ so much that they read as four zones.
    static func testSceneTwoQuadrantsDifferButAreNotColourCoded() {
        let gs = GameState(size: PrologueSize.sceneTwo, name: "s2", stamp: .sceneTwo)
        let m = gs.cubeModel
        let n = m.size, c = n / 2
        var sums = [Int](repeating: 0, count: 4), counts = [Int](repeating: 0, count: 4)
        for r in 0..<n {
            for col in 0..<n {
                guard let (ci, fi) = m.faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                let q = ((r < c) ? 0 : 2) + ((col < c) ? 0 : 1)
                sums[q] += Int(m.cubies[ci].facelets[fi].mazeTile.wallType)
                counts[q] += 1
            }
        }
        var means: [Double] = []
        for q in 0..<4 {
            check(counts[q] > 0, "quadrant \(q) has tiles")
            means.append(Double(sums[q]) / Double(counts[q]))
        }
        let lo = means.min()!, hi = means.max()!
        check(hi - lo > 0.15, "the quadrants should feel different, spread is only \(hi - lo)")
        // The ceiling is the point: wallType runs 0…3, so a spread approaching that would mean one
        // quadrant pristine and another rubble — which is a colour code, not a character.
        check(hi - lo < 1.2, "too different — this reads as four zones, spread \(hi - lo)")
        // And the gradient the scene is actually built on must survive: the centre stays the most
        // collapsed, "age has radiated outward from the centre".
        guard let (cci, cfi) = m.faceletAt(face: .positiveZ, row: c, col: c),
              let (eci, efi) = m.faceletAt(face: .positiveZ, row: 0, col: c) else { return }
        check(m.cubies[cci].facelets[cfi].mazeTile.wallType > m.cubies[eci].facelets[efi].mazeTile.wallType,
              "the centre must still be more ruined than the perimeter")
    }

    /// Scene 5's puzzle, and the property that makes it a SCENE rather than a checklist.
    ///
    /// It is authored by breaking: the circuit is carved complete, then scrambled by known turns, so
    /// a solution exists by construction — hand-authoring a three-receiver puzzle on a twisting 7³
    /// gives no such guarantee. The scramble itself was chosen by search, and this pins what the
    /// search was looking for: not merely solvable, but solvable in a way that can be got WRONG.
    /// "One turn may connect the current to a receiver while disconnecting an earlier path."
    static func testSceneFiveIsSolvableAndCanBeMadeWorse() {
        func fresh() -> GameState { GameState(size: PrologueSize.sceneFive, name: "s5", stamp: .sceneFive) }
        let gs = fresh()
        let m = gs.cubeModel
        check(m.channelReceivers.count == 3, "three receivers, got \(m.channelReceivers.count)")
        check(m.channelSource != nil, "a source to feed them from")

        func fedCount(_ g: GameState) -> Int {
            let fed = g.channelReach
            return g.cubeModel.channelReceivers.filter { fed.contains($0) }.count
        }
        let start = fedCount(gs)
        check(start > 0, "the player should arrive with SOME of the circuit alive, got \(start)")
        check(start < 3, "but not all of it — there would be no puzzle")
        check(!gs.liveCircuit, "so the circuit is not live at the start")

        // Every outer-slice turn available to the player.
        var moves: [(Int, Int, Float)] = []
        for a in 0..<3 { for i in [0, m.size - 1] { for cw in [Float.pi / 2, -.pi / 2] { moves.append((a, i, cw)) } } }

        // SOLVABLE — within three turns, which is what the scramble was chosen to require.
        var solved = false
        outer: for a in moves {
            for b in moves {
                for c in moves {
                    let g = fresh()
                    for t in [a, b, c] { g.cubeModel.applySliceRotation(axis: t.0, index: t.1, angle: t.2) }
                    if g.liveCircuit { solved = true; break outer }
                }
            }
        }
        check(solved, "no sequence of three turns completes the circuit — the scene is unwinnable")

        // …and CAN BE MADE WORSE. Without this the scene is a monotone climb, which teaches nothing.
        var regressed = false
        for t in moves {
            let g = fresh()
            g.cubeModel.applySliceRotation(axis: t.0, index: t.1, angle: t.2)
            if fedCount(g) < start { regressed = true; break }
        }
        check(regressed, "no turn can disconnect a receiver — every turn helps, so nothing is at stake")
    }

    /// SCENE 2, THE WHOLE SOLVE. Eddie's walkthrough found the four-corner lock completely dead: F
    /// did nothing at any switch, so the scene could not be finished at all.
    ///
    /// The cause is worth remembering. `templeDoorStillSealed()` — the guard that makes the switches
    /// inert once the door is open — identified the door as "the portal whose destination is 1",
    /// i.e. `temple-interior`, the world Scene 2's chamber pointed at before Scene 3 was built.
    /// Repointing the chamber to Scene 3 left that lookup finding nothing, falling through to
    /// `false`, and rejecting every press. No crash, no log, nothing on screen — the switches simply
    /// stopped answering, and stayed that way through every session since.
    ///
    /// So this test walks the whole chain rather than any one link, because what broke was not a
    /// step but the connection between two of them.
    static func testSceneTwoCanActuallyBeSolved() {
        let gs = GameState(size: PrologueSize.sceneTwo, name: "scene-2", stamp: .sceneTwo)
        let m = gs.cubeModel
        func stand(_ face: CubeFace, _ r: Int, _ c: Int) {
            gs.player.face = face; gs.player.row = r; gs.player.col = c
            gs.player.subRow = gs.player.standCenter; gs.player.subCol = gs.player.standCenter
        }
        func tiles(with kind: PropKind) -> [(face: CubeFace, r: Int, c: Int)] {
            var out: [(face: CubeFace, r: Int, c: Int)] = []
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
        func cap(_ t: (face: CubeFace, r: Int, c: Int)) -> Float {
            guard let (ci, fi) = m.faceletAt(face: t.face, row: t.r, col: t.c) else { return -1 }
            return m.cubies[ci].facelets[fi].props.first(where: { $0.kind == .switchCap })?.alignAnim ?? -1
        }

        let switches = tiles(with: .switchCap)
        check(switches.count == 4, "Scene 2 has four corner switches, found \(switches.count)")
        // EVERY switch answers F, in both directions. Three start engaged and one does not, so a
        // test that only pressed one could pass while the other direction was broken.
        for t in switches {
            let before = cap(t)
            stand(t.face, t.r, t.c); gs.interact()
            check(cap(t) != before, "the switch at \(t.face) r\(t.r) c\(t.c) ignored F")
            gs.interact()
            check(cap(t) == before, "the switch at \(t.face) r\(t.r) c\(t.c) would not go back")
        }

        check(m.bondedGroups.count == 1, "the lock should be on before all four are engaged")
        // Engage the one that starts disengaged: that completes the set and dissolves the lock.
        if let off = switches.first(where: { cap($0) < 0.5 }) {
            stand(off.face, off.r, off.c); gs.interact()
        }
        check(m.bondedGroups.isEmpty, "four engaged switches should dissolve the lock")

        // The control plinth: F raises the cylinder, then F again turns the world.
        guard let plinth = tiles(with: .plinth).first else { check(false, "Scene 2 has no control plinth"); return }
        stand(plinth.face, plinth.r, plinth.c)
        gs.interact()
        // Scene 2 wears the PIPES, not the drum (Eddie, 2026-08-28) — named explicitly, because the
        // kind is what the animation cache is keyed on and a kind missing from it never animates:
        // the pipes rose to nothing, the second press found them unfinished, and the world silently
        // failed to turn. That is what the two checks below caught.
        check(!tiles(with: .alignmentPipes).isEmpty, "the first press should raise the pipes")
        for _ in 0..<600 { gs.update(deltaTime: 1.0 / 60.0) }
        gs.interact()
        for _ in 0..<600 { gs.update(deltaTime: 1.0 / 60.0) }

        // The payoff: the hidden assembly has turned into view and its chamber is live.
        var chamberSealed = true, chamberFace: CubeFace? = nil
        for face in CubeFace.allCases {
            for r in 0..<m.size {
                for c in 0..<m.size {
                    guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    if m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .portal && $0.state == 13 }) {
                        chamberFace = face
                        chamberSealed = m.sealedPortalCubies.contains(ci)
                    }
                }
            }
        }
        check(chamberFace == .positiveZ, "the turn should bring the chamber onto the played face, got \(String(describing: chamberFace))")
        check(!chamberSealed, "the chamber portal should be live once the world has turned")
    }


    // MARK: - PUZZLE INTEGRITY SUITE
    //
    // Scene 2's four-corner lock was dead for weeks (see `testSceneTwoCanActuallyBeSolved`) and
    // every existing test still passed, because they all checked PARTS: the switches were stamped,
    // the lock was bonded, the turn moved the right slab. What broke was the join — a guard that
    // identified the door by the world behind it, in a world whose door had been repointed.
    //
    // So these tests do not check parts. Each one PLAYS its scene using only what a player has —
    // stand on a tile, press F, turn a slab — and asserts the scene can be finished. They are slow
    // and blunt on purpose; the failure they exist to catch is silent, and looks exactly like a
    // working game until someone tries to play it.

    /// SCENE 1 — no lock to undo; the scene is finished by FINDING the arch. So what has to hold is
    /// that the arch exists, leads on to Scene 2, and can actually be walked to from where the
    /// player wakes up. A maze whose exit is walled off reads exactly like a maze you have not
    /// solved yet, which is the worst kind of bug: indistinguishable from the game working.
    static func testSceneOneCanBeWalkedToItsArch() {
        let gs = prologueWorld("scene-1")
        guard let spawn = gs.cubeModel.spawnLocation else { check(false, "Scene 1 states its spawn"); return }
        let doors = tiles(gs, with: .portal)
        check(doors.count == 1, "Scene 1 has exactly one way on, found \(doors.count)")
        guard let arch = doors.first, let archID = tileID(gs, arch) else { return }
        let reach = walkable(gs, from: (spawn.face, spawn.row, spawn.col))
        check(reach.contains(archID), "Scene 1's arch cannot be reached on foot from the spawn")
        check(!gs.twistEnabled, "Scene 1 withholds the twist")
    }

    /// SCENE 3 — six plinths, each waking ONE obelisk elsewhere by its mark; the exit exists only
    /// once every obelisk is awake. Played through F, including the beat that teaches the rule:
    /// pressing F on an obelisk itself must NOT wake it.
    static func testSceneThreeCanBeSolvedByPressingItsPlinths() {
        let gs = prologueWorld("scene-3")
        let m = gs.cubeModel
        check(m.symbolPairedPlinths, "Scene 3 pairs plinths to obelisks by symbol")
        let obelisks = tiles(gs, with: .obelisk)
        check(obelisks.count == 6, "Scene 3 has six obelisks, found \(obelisks.count)")

        // 3D — the obelisk refuses: "activating an obelisk directly does nothing".
        if let ob = obelisks.first {
            stand(gs, ob.face, ob.r, ob.c)
            gs.interact()
            check(!gs.sceneThreeAllObelisksAwake, "touching an obelisk should not solve anything")
            if let (ci, fi) = m.faceletAt(face: ob.face, row: ob.r, col: ob.c) {
                check(m.cubies[ci].facelets[fi].props.first(where: { $0.kind == .obelisk })?.anim ?? 1 <= 0.01,
                      "an obelisk woke from being touched — the control is supposed to be elsewhere")
            }
        }

        let plinths = tiles(gs, with: .switchCap)
        check(plinths.count == 6, "Scene 3 has six plinths, found \(plinths.count)")
        check(m.chosenExit == nil, "Scene 3's way out must not exist before the chamber is awake")
        for (i, p) in plinths.enumerated() {
            stand(gs, p.face, p.r, p.c)
            gs.interact()
            gs.update(deltaTime: 1.0 / 60.0)
            if i < plinths.count - 1 {
                check(!gs.sceneThreeAllObelisksAwake,
                      "the chamber woke after only \(i + 1) of \(plinths.count) plinths")
            }
        }
        check(gs.sceneThreeAllObelisksAwake, "pressing all six plinths should wake every obelisk")
        guard let exit = m.chosenExit else { check(false, "an awake chamber creates its way out"); return }
        // And it must be somewhere the player can get to.
        if let spawn = m.spawnLocation, let exitID = tileID(gs, (exit.face, exit.row, exit.col)) {
            check(walkable(gs, from: (spawn.face, spawn.row, spawn.col)).contains(exitID),
                  "Scene 3's exit is not reachable on foot from where the player arrives")
        }
    }

    /// SCENE 4 — three anchors, released by F in any order, each release permanent. The twist stays
    /// refused until the last one is gone, and only then does the scripted turn connect the route to
    /// the portal. This is the scene that hands the player the verb, so "the twist is still refused"
    /// and "the twist is finally allowed" are both load-bearing.
    static func testSceneFourReleasesItsAnchorsAndThenTurns() {
        let gs = prologueWorld("scene-4")
        let m = gs.cubeModel
        let anchors = tiles(gs, with: .anchor)
        check(anchors.count == 3, "Scene 4 has three anchors, found \(anchors.count)")
        check(!m.bondedGroups.isEmpty, "Scene 4 starts locked")

        // THE ANCHORS WAIT FOR THE VESSEL (Eddie, 2026-08-03). Until it has been used they are not
        // controls: they wear its mark and refuse. This ordering is what makes the scene teachable —
        // and it is also what stops the player stranding themselves, since releasing every anchor
        // first used to leave the vessel with no lock to demonstrate against and no twist ever
        // granted. Both halves are asserted, because either alone can regress into a dead end.
        check(m.vesselTeachesTheTwist, "Scene 4's vessel is the one that teaches the twist")
        let lockedGroups = m.bondedGroups.count
        for a in anchors { stand(gs, a.face, a.r, a.c); gs.interact() }
        check(m.bondedGroups.count == lockedGroups,
              "the anchors released before the vessel was used — the scene can be stranded")
        check(!gs.twistEnabled, "the twist should still be withheld")

        // Now the vessel. It must work whatever the player has already tried.
        guard let vessel = tiles(gs, with: .layeredVessel).first else {
            check(false, "Scene 4 has a vessel"); return
        }
        stand(gs, vessel.face, vessel.r, vessel.c)
        gs.interact()
        for _ in 0..<900 { gs.update(deltaTime: 1.0 / 60.0) }
        check(gs.twistEnabled, "using the vessel is what hands over the twist")

        let (axis, index) = m.sliceAxisAndIndex(for: m.spawnLocation?.face ?? .positiveZ)
        check(m.bondsBlocking(axis: axis, index: index) > 0, "the player's slab starts bonded")

        for (i, a) in anchors.enumerated() {
            stand(gs, a.face, a.r, a.c)
            gs.interact()
            gs.update(deltaTime: 1.0 / 60.0)
            if i < anchors.count - 1 {
                check(!m.bondedGroups.isEmpty, "the lock let go after only \(i + 1) of 3 anchors")
            }
            // "Each release is permanent" — pressing it again must not put the bond back.
            let groups = m.bondedGroups.count
            gs.interact()
            check(m.bondedGroups.count == groups, "pressing a released anchor changed the lock")
        }
        check(m.bondedGroups.isEmpty, "releasing all three anchors should free the world")
        check(m.bondsBlocking(axis: axis, index: index) == 0, "the slab is still refused after every anchor is gone")
    }

    /// SCENE 5 — the broken circuit. Played the way the world is: turn slabs until the current
    /// reaches all three receivers, and only then does the way out exist.
    static func testSceneFiveCanBeSolvedByTurningItBack() {
        let gs = prologueWorld("scene-5")
        let m = gs.cubeModel
        check(!gs.liveCircuit, "Scene 5 starts broken")
        check(m.chosenExit == nil, "Scene 5's way out must not exist before the circuit is live")
        check(m.channelReceivers.count == 3, "Scene 5 has three receivers, found \(m.channelReceivers.count)")

        // The stamp's scramble, undone — the sequence a player finds by reading the grooves.
        for (axis, index) in [(2, 0), (0, 0), (0, 0)] {
            m.applySliceRotation(axis: axis, index: index, angle: -.pi / 2)
        }
        check(gs.liveCircuit, "undoing the scramble should complete the circuit")
        gs.update(deltaTime: 1.0 / 60.0)
        guard let exit = m.chosenExit, let exitID = tileID(gs, (exit.face, exit.row, exit.col)) else {
            check(false, "a live circuit creates the way out"); return
        }
        check(gs.channelDepths[exitID] != nil, "5K: the exit must stand on the live current")
        if let spawn = m.spawnLocation {
            check(walkable(gs, from: (spawn.face, spawn.row, spawn.col)).contains(exitID),
                  "Scene 5's exit is not reachable on foot")
        }
    }

    /// THE PROPERTY EVERY SCENE SHARES, checked in one place: a scene's way out does not exist
    /// before its puzzle is done. A door that is already there is not a puzzle, and this is the
    /// cheapest way to notice that a scene has quietly started solving itself.
    static func testNoSceneHandsOutItsExitEarly() {
        for name in ["scene-3", "scene-4", "scene-5"] {
            let gs = prologueWorld(name)
            check(gs.cubeModel.chosenExit == nil, "\(name) already has its exit at stamp")
        }
        // Scene 2's door EXISTS from the first frame — it is sealed and unreachable rather than
        // absent, which is the scene's whole image ("a portal is present, but the maze does not
        // connect to it"). So what must hold there is that it is SEALED.
        let two = prologueWorld("scene-2")
        var chamberSealed = false
        for cu in two.cubeModel.cubies.indices {
            for f in two.cubeModel.cubies[cu].facelets
            where f.props.contains(where: { $0.kind == .portal && $0.state == 13 }) {
                chamberSealed = two.cubeModel.sealedPortalCubies.contains(cu)
            }
        }
        check(chamberSealed, "Scene 2's chamber should be sealed until the world turns")
    }

    /// SCENE 6C's dressing. The underside is scenery, and scenery must not change the shape of the
    /// world: the region has to stay walkable, and — the property Scene 6 depends on — it must stay
    /// UNREACHABLE from Scene 2's own spawn. Machinery that blocked a lane, or a prop that somehow
    /// opened one, would break the scene in a way that looks like level design.
    static func testTheUndersideIsDressedWithoutChangingIt() {
        let gs = prologueWorld("scene-2")
        let m = gs.cubeModel
        guard let home = m.spawnLocation, let six = m.spawn(arrivingFrom: "scene-5") else {
            check(false, "Scene 2 states both arrivals"); return
        }
        let before = walkable(gs, from: (home.face, home.row, home.col))
        let regionBefore = walkable(gs, from: (six.face, six.row, six.col))

        // A stand-in kit: the stamp asks for roles, not for particular models, so the test does not
        // depend on which pack is installed or on the Renderer being able to load anything.
        // Dress it the way `buildWorld` does — vegetation first, so the clearing has something to
        // clear. Without this the test would pass on a face that was never planted.
        var flora = CubeModel.GardenFlora()
        flora.bushes = [90]; flora.rocks = [91]; flora.grasses = [92]; flora.flowers = [93]
        m.stampGardenVegetation(flora)
        var planted = 0
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (ci, fi) = m.faceletAt(face: .negativeX, row: r, col: c) else { continue }
                planted += m.cubies[ci].facelets[fi].props.filter { $0.kind == .importedFoliage }.count
            }
        }
        check(planted > 0, "the test needs the underside planted before it can prove it gets cleared")

        var kit = CubeModel.UndersideMachinery()
        kit.uprights = [0, 1]; kit.runs = [2, 3]; kit.boxes = [4]; kit.rails = [5]
        kit.plates = [6]; kit.lamps = [7]
        m.stampSceneSixUnderside(kit)
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (ci, fi) = m.faceletAt(face: .negativeX, row: r, col: c) else { continue }
                for p in m.cubies[ci].facelets[fi].props where p.kind == .importedFoliage {
                    check(p.state < 90, "a plant survived on the underside (model \(p.state))")
                }
            }
        }

        var dressed = 0, nearEdge = 0, farSide = 0
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (ci, fi) = m.faceletAt(face: .negativeX, row: r, col: c) else { continue }
                let props = m.cubies[ci].facelets[fi].props.filter { $0.kind == .importedFoliage }
                if !props.isEmpty {
                    dressed += 1
                    if c >= m.size - 3 { nearEdge += 1 }
                    if c <= 2 { farSide += 1 }
                }
                // Nothing solid: the underside is something to read, not to squeeze past.
                for p in props { check(!p.kind.isSolid, "underside machinery should not block a stand cell") }
            }
        }
        check(dressed > 20, "the underside should actually be dressed, got \(dressed) tiles")
        // A MIX, not a single verdict repeated. The first version of the raise decision tested
        // `(h >> 27) % 100 < 55` — five bits, maximum 31 — so it was always true and every deck came
        // up on a pillar. One 32-bit hash does not hold six independent choices, and "it looked
        // varied" would never have caught it: measured, it was 32 of 32.
        var decks = 0, raisedDecks = 0
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (ci, fi) = m.faceletAt(face: .negativeX, row: r, col: c) else { continue }
                for p in m.cubies[ci].facelets[fi].props
                where p.kind == .importedFoliage && kit.plates.contains(p.state) {
                    decks += 1
                    if p.sink < 0 { raisedDecks += 1 }
                }
            }
        }
        check(decks >= 8, "the underside should carry platform decks, got \(decks)")
        check(raisedDecks > 0 && raisedDecks < decks,
              "decks should be a MIX of seated and pillar-raised, got \(raisedDecks) of \(decks)")
        // NOTHING GROWS ON THE UNDERSIDE (Eddie, 2026-08-03). Scene 2 scatters ground foliage over
        // every face but +Z — this one included — and a bush on the back of a turning slab is the one
        // thing that stops it reading as machinery. The stamp clears the face before dressing it, and
        // the wall dressing treats the whole face as "keep clear" so no overgrowth returns.
        check(m.undersideFace == .negativeX, "the underside should name its own face")
        check(m.dressedClearTiles().count >= m.size * m.size,
              "the underside's walls should be exempt from overgrowth")
        check(nearEdge > farSide,
              "machinery should thicken toward the assembly edge (\(nearEdge) near vs \(farSide) far)")

        // Shape unchanged, in both directions.
        check(walkable(gs, from: (home.face, home.row, home.col)) == before,
              "dressing the underside changed what Scene 2's own route can reach")
        check(walkable(gs, from: (six.face, six.row, six.col)) == regionBefore,
              "dressing the underside changed the shape of the arrival region")
        guard let sixID = tileID(gs, (six.face, six.row, six.col)) else { return }
        check(!before.contains(sixID), "the arrival became reachable from Scene 2's spawn")

        // Deterministic: the same world every run, or a twist would carry different props each time.
        let again = prologueWorld("scene-2")
        again.cubeModel.stampSceneSixUnderside(kit)
        var same = true
        for r in 0..<m.size {
            for c in 0..<m.size {
                guard let (a, b) = m.faceletAt(face: .negativeX, row: r, col: c),
                      let (x, y) = again.cubeModel.faceletAt(face: .negativeX, row: r, col: c) else { continue }
                let l = m.cubies[a].facelets[b].props.map { "\($0.kind)\($0.state)" }
                let rr = again.cubeModel.cubies[x].facelets[y].props.map { "\($0.kind)\($0.state)" }
                if l != rr { same = false }
            }
        }
        check(same, "the underside dressing is not deterministic")
    }

    /// A scripted turn is fired by an ANIMATION finishing — the plinth's alignment reaching 1 — which
    /// lands on whatever frame it lands on. If the player happened to be mid-step or mid-turn at that
    /// instant, `startScriptedSliceRotation` returned early and the turn was gone: a raised, aligned
    /// rotator and a world that had not moved, needing another press to fire it again. The world owes
    /// the turn from the moment the control was used; it may wait for the player to settle, but it
    /// may not forget.
    static func testAScriptedTurnWaitsRatherThanVanishing() {
        let gs = prologueWorld("scene-2")
        let m = gs.cubeModel
        guard let s = m.scriptedTwistSlice else { check(false, "Scene 2 names the slab its lock turns"); return }
        // Undo the lock first: a bonded slab refuses the turn for a REASON, and testing the
        // deferral against a refusal that is supposed to happen proves nothing. (This is why the
        // first run of this test failed — the test was wrong, not the code.)
        for t in tiles(gs, with: .switchCap) {
            guard let (ci, fi) = m.faceletAt(face: t.face, row: t.r, col: t.c) else { continue }
            if (m.cubies[ci].facelets[fi].props.first { $0.kind == .switchCap }?.alignAnim ?? 0) < 0.5 {
                stand(gs, t.face, t.r, t.c); gs.interact()
            }
        }
        check(m.bondedGroups.isEmpty, "the lock should be undone before testing the turn")
        let before = m.cubies.map { $0.position }

        // The player is mid-stride when the alignment completes.
        gs.player.isMoving = true
        gs.startScriptedSliceRotation(axis: s.axis, index: s.index, clockwise: s.clockwise)
        check(!gs.sliceRotation.isActive, "a turn should not start under a walking player")
        check(m.cubies.map { $0.position } == before, "the world turned while the player was mid-step")
        check(gs.pendingScriptedTwist != nil, "the turn was dropped instead of being remembered")

        // They stop. The world pays what it owes, without another press.
        gs.player.isMoving = false
        gs.update(deltaTime: 1.0 / 60.0)
        check(gs.sliceRotation.isActive || m.cubies.map { $0.position } != before,
              "the owed turn never happened once the player stood still")
        for _ in 0..<300 { gs.update(deltaTime: 1.0 / 60.0) }
        check(m.cubies.map { $0.position } != before, "the slab never actually moved")
        check(gs.pendingScriptedTwist == nil, "the owed turn should be cleared once paid")
    }

    /// SCENE 5's ROTATORS (Eddie, 2026-08-03). Q/E are keyboard-only, which is no use on a touch
    /// screen, so the world carries six standing controls — one per face — each turning the slab it
    /// stands on. The test that matters is not that they exist but that they are ENOUGH: the scene
    /// must be completable by walking up to controls and pressing them, with the keyboard verb never
    /// used. If it is not, the touch player is stuck in a world they can see the answer to.
    static func testSceneFiveCanBeSolvedByItsModelPlinthsAlone() {
        let gs = prologueWorld("scene-5")
        let m = gs.cubeModel
        check(m.worldModelPlinths, "Scene 5 should carry its world-model plinths")

        // One per face, and never on the circuit or on top of something else.
        var perFace: [CubeFace: Int] = [:]
        for face in CubeFace.allCases {
            for r in 0..<m.size {
                for c in 0..<m.size {
                    guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    let f = m.cubies[ci].facelets[fi]
                    guard f.props.contains(where: { $0.kind == .worldModel }) else { continue }
                    perFace[face, default: 0] += 1
                    check(f.mazeTile.channels.isEmpty, "a plinth stands on a channel at \(face) r\(r) c\(c)")
                    check(!f.props.contains { $0.kind == .channelBowl || $0.kind == .layeredVessel || $0.kind == .channelBasin },
                          "a plinth shares a tile with a fixture at \(face)")
                }
            }
        }
        for face in CubeFace.allCases {
            check(perFace[face] == 1, "\(face) should carry exactly one plinth, has \(perFace[face] ?? 0)")
        }

        /// Walk to the plinth currently on `face` and press it ONCE, then let the turn finish.
        /// One press must mean one turn: the model wakes because you approached it, so there is no
        /// raise-then-act press to spend first (Eddie has rejected that shape before).
        func press(_ face: CubeFace) {
            for r in 0..<m.size {
                for c in 0..<m.size {
                    guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    guard m.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .worldModel })
                    else { continue }
                    stand(gs, face, r, c)
                    check(gs.hasInteractableHere, "a tap on the plinth's tile should reach it")
                    gs.interact()
                    for _ in 0..<180 { gs.update(deltaTime: 1.0 / 60.0) }
                    return
                }
            }
            check(false, "no plinth found on \(face)")
        }

        // The scramble was three quarter-turns: (0,0) twice and (2,0) once — which are the outer
        // slabs of −X and −Z, so exactly two of the six controls can undo it. Each press turns one
        // quarter the other way, so: −Z once, −X twice.
        check(!gs.liveCircuit, "Scene 5 starts broken")
        press(.negativeZ)
        press(.negativeX)
        press(.negativeX)
        check(gs.liveCircuit, "the six model plinths should complete the circuit without Q/E")
        gs.update(deltaTime: 1.0 / 60.0)
        check(m.chosenExit != nil, "completing it by plinth should still create the way out")
    }

    /// The order-independence itself, as its own test, because it is the property that broke: Eddie
    /// released all three anchors, then pressed the vessel, and the scene was over — the vessel only
    /// performed while a lock still existed, so with the lock gone it said nothing and the twist was
    /// never handed over. Nothing on screen said why.
    ///
    /// Two separate guarantees now hold it up, and this asserts both from the player's side:
    ///   • the anchors refuse until the vessel has been used (so the bad order cannot be entered);
    ///   • the vessel performs regardless of the lock's state (so if it ever is, nothing is lost).
    static func testSceneFourCannotBeStrandedByOrder() {
        for anchorsFirst in [true, false] {
            let gs = prologueWorld("scene-4")
            let m = gs.cubeModel
            let anchors = tiles(gs, with: .anchor)
            guard let vessel = tiles(gs, with: .layeredVessel).first else {
                check(false, "Scene 4 has a vessel"); return
            }
            if anchorsFirst {
                for a in anchors { stand(gs, a.face, a.r, a.c); gs.interact() }
            }
            stand(gs, vessel.face, vessel.r, vessel.c)
            gs.interact()
            for _ in 0..<900 { gs.update(deltaTime: 1.0 / 60.0) }
            check(gs.twistEnabled,
                  "the vessel failed to hand over the twist (anchors first: \(anchorsFirst))")
            for a in anchors { stand(gs, a.face, a.r, a.c); gs.interact() }
            check(m.bondedGroups.isEmpty,
                  "the anchors did not release (anchors first: \(anchorsFirst))")
            let (axis, index) = m.sliceAxisAndIndex(for: gs.player.face)
            check(m.bondsBlocking(axis: axis, index: index) == 0,
                  "the slab is still refused (anchors first: \(anchorsFirst))")
        }
        // THE BELT, tested apart from the braces. With the anchors waiting, a player can no longer
        // reach a state where the lock is gone but the vessel is untouched — so the second guarantee
        // (the vessel performs regardless of the lock) is unreachable through play, and a mutation
        // that removes it passes every player-level test. That is exactly the kind of quiet
        // regression that put the softlock here in the first place, so it is asserted directly:
        // dissolve the bonds through the model, then press the vessel.
        do {
            let gs = prologueWorld("scene-4")
            let m = gs.cubeModel
            for cu in m.cubies.indices where !m.bondedGroups.isEmpty { m.removeBond(containing: cu) }
            check(m.bondedGroups.isEmpty, "the bonds should be gone for this check")
            guard let v = tiles(gs, with: .layeredVessel).first else { check(false, "no vessel"); return }
            stand(gs, v.face, v.r, v.c)
            gs.interact()
            for _ in 0..<900 { gs.update(deltaTime: 1.0 / 60.0) }
            check(gs.twistEnabled,
                  "with no lock left, the vessel went silent — the old softlock is back")
        }

        // Scene 1's vessels stay scenery: "if the player approaches the vessels, nothing dramatic
        // happens". The distinction is a property of the WORLD now, not of whether a lock survives.
        let one = prologueWorld("scene-1")
        check(!one.cubeModel.vesselTeachesTheTwist, "Scene 1's vessels are not teachers")
        if let v = tiles(one, with: .layeredVessel).first {
            stand(one, v.face, v.r, v.c)
            one.interact()
            for _ in 0..<300 { one.update(deltaTime: 1.0 / 60.0) }
            check(!one.twistEnabled, "Scene 1 must not hand over the twist")
        }
    }

    /// The Scene 5 polish pass (2026-08-03): the source is a BASIN, the receivers are BOWLS with
    /// three states, F at the basin fires the diagnostic pulse, a live circuit runs seamlessly, and
    /// completion blooms the world. Played, not inspected — each behaviour through the same calls
    /// the player's inputs make.
    static func testSceneFiveFixturesAndCompletion() {
        let gs = prologueWorld("scene-5")
        let m = gs.cubeModel

        // The fixtures exist and are the scripted kinds.
        var basins = 0, bowls = 0
        for face in CubeFace.allCases {
            for r in 0..<m.size {
                for c in 0..<m.size {
                    guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    for p in m.cubies[ci].facelets[fi].props {
                        if p.kind == .channelBasin { basins += 1 }
                        if p.kind == .channelBowl { bowls += 1 }
                    }
                }
            }
        }
        check(basins == 1, "one source basin, found \(basins)")
        check(bowls == 3, "three receiver bowls, found \(bowls)")

        // 5C — the DIAGNOSTIC PULSE: F at the basin releases a bright front immediately.
        guard let src = m.channelSource else { check(false, "no source"); return }
        for _ in 0..<40 { gs.update(deltaTime: 1.0 / 60.0) }   // natural cycle underway
        gs.pendingAudioCues.removeAll()
        stand(gs, src.face, src.row, src.col)
        check(gs.hasInteractableHere, "the basin should answer a tap")
        gs.interact()
        check(gs.pulseFront == 0, "the diagnostic pulse should start from the source at once")
        check(gs.pulseBright == 1, "the diagnostic pulse is the bright one")
        check(gs.pendingAudioCues.contains { if case .channelPulse = $0 { return true }; return false },
              "the release should be heard")

        // 5D — THREE STATES. Find a single rotator turn that feeds at least one receiver without
        // completing the circuit (5E promises the first fix is available and plainly correct).
        var fedTurn: (axis: Int, index: Int)? = nil
        outer: for face in CubeFace.allCases {
            let (axis, index) = m.sliceAxisAndIndex(for: face)
            m.applySliceRotation(axis: axis, index: index, angle: .pi / 2)
            let reach = gs.channelDepths
            let feeds = m.channelReceivers.contains { reach[$0] != nil }
            if feeds && !gs.liveCircuit { fedTurn = (axis, index); break outer }
            m.applySliceRotation(axis: axis, index: index, angle: -.pi / 2)   // undo and try the next
        }
        check(fedTurn != nil, "5E: some single turn should feed a receiver while the circuit stays broken")
        if fedTurn != nil {
            for _ in 0..<300 { gs.update(deltaTime: 1.0 / 60.0) }
            var filling = 0, locked = 0
            for cu in m.cubies { for f in cu.facelets {
                for p in f.props where p.kind == .channelBowl {
                    if abs(p.anim - 0.55) < 0.05 { filling += 1 }
                    if p.anim > 0.9 { locked += 1 }
                }
            } }
            check(filling >= 1, "a fed-but-not-locked receiver should sit at the FILLING level")
            check(locked == 0, "no receiver may read LOCKED while the circuit is broken")
        }

        // Solve it (fresh world so the state is known).
        let gs2 = prologueWorld("scene-5")
        let m2 = gs2.cubeModel
        for (axis, index) in [(2, 0), (0, 0), (0, 0)] {
            m2.applySliceRotation(axis: axis, index: index, angle: -.pi / 2)
        }
        check(gs2.liveCircuit, "the known solution should complete the circuit")

        // 5I — SEAMLESS: no incomplete tone ever again, the front keeps cycling, and the fixtures
        // lock full. 5J — the bloom fires, peaks, and settles to a resting glow.
        var releases = 0, breaks = 0
        var peak: Float = 0
        // 22 s: the route is ~7 steps deep and the pulse walks at ~0.83 tiles/s, so a lap is
        // ~8.4 s — the first version of this ran 14 s, saw 2 releases, and blamed the rhythm.
        for _ in 0..<(60 * 22) {
            gs2.update(deltaTime: 1.0 / 60.0)
            peak = max(peak, gs2.worldBloom)
            for cue in gs2.pendingAudioCues {
                if case .channelPulse = cue { releases += 1 }
                if case .channelIncomplete = cue { breaks += 1 }
            }
            gs2.pendingAudioCues.removeAll()
        }
        check(breaks == 0, "a live circuit must never sound its incomplete tone, heard \(breaks)")
        check(releases >= 3, "the live circuit should keep its rhythm, heard \(releases) releases")
        check(gs2.pulseFront >= 0, "the live front must never go dark")
        check(peak > 0.95, "the 5J bloom should reach full, peaked at \(peak)")
        check(gs2.worldBloom > 0.25 && gs2.worldBloom < 0.5,
              "the bloom should settle to a resting glow, ended at \(gs2.worldBloom)")
        var full = 0
        for cu in m2.cubies { for f in cu.facelets {
            for p in f.props where (p.kind == .channelBowl || p.kind == .channelBasin) && p.anim > 0.95 { full += 1 }
        } }
        check(full == 4, "the basin and all three bowls should lock full, got \(full)")
    }

    /// SCENE 6's CRITICAL PATH, played: the latches in and out of order, the hatch, the route name
    /// that tells the second descent from the first, and the route-keyed portal that opens only when
    /// three facts hold at once. "The scene depends on trust."
    static func testSceneSixLatchesHatchAndRouteKeyedPortal() {
        // 6D — the latches. Scene 6's world is Scene 2 with the underside dressed.
        let gs = prologueWorld("scene-2")
        let m = gs.cubeModel
        var kit = CubeModel.UndersideMachinery()
        kit.uprights = [0]; kit.runs = [1]; kit.boxes = [2]; kit.rails = [3]; kit.plates = [4]; kit.lamps = [5]
        m.stampSceneSixUnderside(kit)

        var latches: [Int: (face: CubeFace, r: Int, c: Int)] = [:]
        for face in CubeFace.allCases {
            for r in 0..<m.size {
                for c in 0..<m.size {
                    guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    for p in m.cubies[ci].facelets[fi].props where p.kind == .latch {
                        latches[p.state] = (face, r, c)
                        check(face == .negativeX, "a latch is off the underside, at \(face)")
                    }
                }
            }
        }
        check(latches.count == 3, "three latches, found \(latches.count)")
        func latchAnim(_ ordinal: Int) -> Float {
            guard let t = latches[ordinal], let (ci, fi) = m.faceletAt(face: t.face, row: t.r, col: t.c)
            else { return -1 }
            return m.cubies[ci].facelets[fi].props.first { $0.kind == .latch && $0.state == ordinal }?.anim ?? -1
        }

        // Out of order: the third refuses, and nothing opens.
        stand(gs, latches[3]!.face, latches[3]!.r, latches[3]!.c)
        gs.interact()
        check(latchAnim(3) < 0.5, "latch 3 engaged out of order")
        check(m.undersideHatch == nil, "the hatch opened early")

        // In order: each engages, the third opens the hatch — a portal to the interior.
        for ordinal in 1...3 {
            let t = latches[ordinal]!
            stand(gs, t.face, t.r, t.c)
            check(gs.hasInteractableHere, "a latch should answer a tap")
            gs.interact()
            check(latchAnim(ordinal) > 0.5, "latch \(ordinal) should engage in order")
        }
        guard let hatch = m.undersideHatch else { check(false, "three latches should open the hatch"); return }
        check(hatch.face == .negativeX, "the hatch belongs to the underside")
        if let (hci, hfi) = m.faceletAt(face: hatch.face, row: hatch.row, col: hatch.col) {
            let door = m.cubies[hci].facelets[hfi].props.first { $0.kind == .portal }
            check(door?.state == 13, "the hatch descends into Scene 3, got \(String(describing: door?.state))")
            check(door?.transition == .push, "the second descent pushes, like the first")
        }

        // The ROUTE: both descents depart a world named scene-2; only the one whose Scene 2 was
        // itself entered from Scene 5 counts as scene-6. This rule is what everything below keys on.
        check(WorldCatalog.routeName(departingWorld: "scene-2", itsOrigin: "scene-5") == "scene-6",
              "the underside descent should count as the scene-6 route")
        check(WorldCatalog.routeName(departingWorld: "scene-2", itsOrigin: "scene-1") == "scene-2",
              "the first descent must stay the scene-2 route")

        // 6E/6F/6I — the interior, entered by the new route, still solved, with Scene 2's state
        // carried across as a fact. Solve the chamber, then supply the facts the swap would stamp.
        let three = prologueWorld("scene-3")
        guard let second = three.cubeModel.spawn(arrivingFrom: "scene-6") else {
            check(false, "Scene 3 names its second entrance"); return
        }
        check(second.face != three.cubeModel.spawnLocation?.face,
              "the second descent must land on a face the first never used")
        // 6H — the metal vessel must NOT exist on the first visit (Eddie met it early): it arrives
        // with the scene-6 route, so the "familiar but transformed" reveal is earned by the route.
        func metalVessels() -> Int {
            var n = 0
            for cu in three.cubeModel.cubies { for f in cu.facelets {
                for p in f.props where p.kind == .layeredVessel && p.state == 6 { n += 1 }
            } }
            return n
        }
        check(metalVessels() == 0, "the metal vessel appeared before the scene-6 route entered")

        for t in tiles(three, with: .switchCap) { stand(three, t.face, t.r, t.c); three.interact() }
        for _ in 0..<10 { three.update(deltaTime: 1.0 / 60.0) }
        check(three.sceneThreeAllObelisksAwake, "the chamber should solve")
        check(three.cubeModel.routeKeyedExit == nil,
              "the route-keyed portal must NOT open from being solved alone")

        three.routeFacts.insert("via-underside")
        three.update(deltaTime: 1.0 / 60.0)
        check(three.cubeModel.routeKeyedExit == nil,
              "two facts are not three: scene-2-turned is still missing")
        check(metalVessels() == 1, "the scene-6 route should bring exactly one metal vessel, got \(metalVessels())")

        three.routeFacts.insert("scene-2-turned")
        three.update(deltaTime: 1.0 / 60.0)
        guard let rk = three.cubeModel.routeKeyedExit else {
            check(false, "all three facts should open the route-keyed portal"); return
        }
        if let ce = three.cubeModel.chosenExit {
            check(!(rk.face == ce.face && rk.row == ce.row && rk.col == ce.col),
                  "the new portal must not stand on the nebula frame's tile")
        }
        // And Scene 2's fact is honest geometry: turned before, not after undoing.
        let two2 = prologueWorld("scene-2")
        check(!two2.cubeModel.sceneTwoIsTurned, "an unsolved Scene 2 is not turned")
    }

    /// THE SURVEYOR (Eddie's mobile-builder). The laws that make it decoration rather than danger:
    /// filigree NEVER conducts and NEVER blocks; it grows only beside channels that were LIVE when
    /// grown; the machine stalls when its trunk goes dead and resumes when repaired; and everything
    /// it does rides twists, because it lives on facelets like everything else.
    static func testTheSurveyorBuildsOnlyFromLiveCurrent() {
        let gs = prologueWorld("scene-5")
        let m = gs.cubeModel

        func channelMasks() -> [Int: UInt8] {
            var out: [Int: UInt8] = [:]
            for cu in m.cubies { for f in cu.facelets { out[f.id.rawValue] = f.mazeTile.channels.rawValue } }
            return out
        }
        func totalGrowth() -> Float {
            var t: Float = 0
            for cu in m.cubies { for f in cu.facelets { t += f.filigreeGrowth } }
            return t
        }
        let masksAtStart = channelMasks()

        // Let it work a while on the BROKEN circuit — it should grow only along the live segment.
        for _ in 0..<(60 * 60) { gs.update(deltaTime: 1.0 / 60.0) }
        check(gs.surveyorTile != nil, "the surveyor should exist on Scene 5")
        let grown = totalGrowth()
        check(grown > 0.5, "an hour of minutes should have grown something, got \(grown)")
        check(channelMasks() == masksAtStart, "FILIGREE MUST NEVER CONDUCT: the channel masks changed")

        // Every grown tile: no channels of its own, and its entry faces a REAL channel tile.
        let n = m.size
        for face in CubeFace.allCases {
            for r in 0..<n {
                for c in 0..<n {
                    guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    let f = m.cubies[ci].facelets[fi]
                    guard f.filigreeGrowth > 0 else { continue }
                    check(f.mazeTile.channels.isEmpty, "filigree grew ON a channel tile")
                    check(f.filigreeEntry.rawValue != 0 && f.filigreeEntry.rawValue & (f.filigreeEntry.rawValue - 1) == 0,
                          "filigree entry should be exactly one edge")
                    let e = f.filigreeEntry
                    let (sdir, dr, dc): (SurfaceDirection, Int, Int) =
                        e.contains(.north) ? (.north, -1, 0) : e.contains(.south) ? (.south, 1, 0)
                        : e.contains(.west) ? (.west, 0, -1) : (.east, 0, 1)
                    var ploc: (face: CubeFace, row: Int, col: Int)
                    if r + dr >= 0, r + dr < n, c + dc >= 0, c + dc < n { ploc = (face, r + dr, c + dc) }
                    else {
                        let cr = m.edgeCrossing(face: face, direction: sdir, row: r, col: c)
                        ploc = (cr.face, cr.row, cr.col)
                    }
                    guard let (pci, pfi) = m.faceletAt(face: ploc.face, row: ploc.row, col: ploc.col) else {
                        check(false, "filigree entry points off the world"); continue
                    }
                    let parent = m.cubies[pci].facelets[pfi]
                    check(!parent.mazeTile.channels.isEmpty || parent.filigreeGrowth > 0,
                          "filigree's entry faces neither a channel nor grown filigree")
                    check(f.filigreeRing >= 1 && f.filigreeRing <= GameState.filigreeMaxRing,
                          "filigree ring \(f.filigreeRing) out of bounds")
                    if !parent.mazeTile.channels.isEmpty {
                        check(f.filigreeRing == 1, "a branch beside the trunk must be ring 1")
                    }
                }
            }
        }

        // The scene still solves with the surveyor's work all over it.
        for (axis, index) in [(2, 0), (0, 0), (0, 0)] {
            m.applySliceRotation(axis: axis, index: index, angle: -.pi / 2)
        }
        check(gs.liveCircuit, "the surveyor's filigree must never break solvability")

        // THE RING CAP, directly: a play-through cannot reach ring 4 in any affordable window, so
        // the guard is tested at the seam it lives on. A finished branch at the cap must offer no
        // further target; one ring below it must.
        do {
            let g3 = prologueWorld("scene-5")
            let m3 = g3.cubeModel
            var spot: (CubeFace, Int, Int)? = nil
            var bare: [(CubeFace, Int, Int)] = []
            for face in CubeFace.allCases {
                for r in 1..<(m3.size - 1) {
                    for c in 1..<(m3.size - 1) {
                        guard let (ci, fi) = m3.faceletAt(face: face, row: r, col: c) else { continue }
                        let f = m3.cubies[ci].facelets[fi]
                        if f.mazeTile.channels.isEmpty, f.props.isEmpty { bare.append((face, r, c)) }
                    }
                }
            }
            // A bare tile whose neighbours are also bare, so the only thing that could stop growth
            // is the ring rule itself.
            spot = bare.first { t in
                bare.contains { $0.0 == t.0 && $0.1 == t.1 - 1 && $0.2 == t.2 }
                    && bare.contains { $0.0 == t.0 && $0.1 == t.1 + 1 && $0.2 == t.2 }
            }
            if let (sf, sr2, sc2) = spot, let (ci, fi) = m3.faceletAt(face: sf, row: sr2, col: sc2) {
                m3.cubies[ci].facelets[fi].filigreeGrowth = 1
                m3.cubies[ci].facelets[fi].filigreeEntry = .west
                m3.cubies[ci].facelets[fi].filigreeRing = GameState.filigreeMaxRing - 1
                check(g3.filigreeTarget(of: (sf, sr2, sc2)) != nil,
                      "one ring below the cap should still offer work")
                m3.cubies[ci].facelets[fi].filigreeRing = GameState.filigreeMaxRing
                check(g3.filigreeTarget(of: (sf, sr2, sc2)) == nil,
                      "a branch AT the ring cap must offer no further target — the filigree would tile the world")
            } else {
                check(false, "no isolated bare tile found to test the ring cap on")
            }
        }

        // STALL: a fresh world, wait for first growth, then sever the trunk under the machine —
        // growth freezes while it idles, and resumes when the world is turned back.
        let gs2 = prologueWorld("scene-5")
        let m2 = gs2.cubeModel
        for _ in 0..<(60 * 30) { gs2.update(deltaTime: 1.0 / 60.0) }
        func growth2() -> Float {
            var t: Float = 0
            for cu in m2.cubies { for f in cu.facelets { t += f.filigreeGrowth } }
            return t
        }
        let beforeSever = growth2()
        check(beforeSever > 0, "the second surveyor should also have worked")
        // Sever: turn the slab under its tile (its trunk leaves the reach set in most configurations;
        // if this particular turn does not sever it, the assertion below still holds trivially, so
        // sever by force: rotate the source's own slab a quarter — the reach collapses to nothing).
        let (sx, si) = m2.sliceAxisAndIndex(for: .positiveZ)
        m2.applySliceRotation(axis: sx, index: si, angle: .pi / 2)
        let reachNow = gs2.channelDepths
        if let tile = gs2.surveyorTile, let (ci, fi) = m2.faceletAt(face: tile.face, row: tile.row, col: tile.col),
           !m2.cubies[ci].facelets[fi].mazeTile.channels.isEmpty,   // v2 walks its own filigree too;
           reachNow[m2.cubies[ci].facelets[fi].id.rawValue] == nil {   // the exact stall law is channel-tile
            for _ in 0..<(60 * 10) { gs2.update(deltaTime: 1.0 / 60.0) }
            check(gs2.surveyorIdle, "a surveyor whose trunk is dead should stand idle")
            check(abs(growth2() - beforeSever) < 0.001,
                  "a stalled surveyor must not grow (\(beforeSever) → \(growth2()))")
            m2.applySliceRotation(axis: sx, index: si, angle: -.pi / 2)
            for _ in 0..<(60 * 20) { gs2.update(deltaTime: 1.0 / 60.0) }
            check(growth2() > beforeSever, "the repaired trunk should put it back to work")
        }
    }

    static func testSceneFivePulseStopsWhereTheRouteDoes() {
        let gs = GameState(size: PrologueSize.sceneFive, name: "s5", stamp: .sceneFive)
        let depths = gs.channelDepths
        check(!depths.isEmpty, "Scene 5 should have a reachable circuit to pulse through")
        guard let src = gs.cubeModel.channelSource,
              let (sci, sfi) = gs.cubeModel.faceletAt(face: src.face, row: src.row, col: src.col) else {
            check(false, "Scene 5 has no channel source"); return
        }
        check(depths[gs.cubeModel.cubies[sci].facelets[sfi].id.rawValue] == 0,
              "the source is zero steps from itself")
        let maxDepth = Float(depths.values.max() ?? 0)
        check(maxDepth > 0, "the current should reach past the source tile")
        check(!gs.liveCircuit, "Scene 5 starts broken, so the pulse should fail somewhere")

        var releases = 0, breaks = 0, overshoot: Float = 0
        for _ in 0..<3600 {                              // a minute at 60 fps — several cycles
            gs.update(deltaTime: 1.0 / 60.0)
            overshoot = max(overshoot, gs.pulseFront - maxDepth)
            for cue in gs.pendingAudioCues {
                if case .channelPulse = cue { releases += 1 }
                if case .channelIncomplete = cue { breaks += 1 }
            }
            gs.pendingAudioCues.removeAll()
        }
        check(overshoot <= 0.001,
              "the pulse ran \(overshoot) steps PAST the end of the route — it has to die at the break")
        check(releases >= 2, "the pulse should repeat; the source released \(releases) times")
        check(breaks >= 2, "a broken circuit should sound its incomplete tone every cycle, got \(breaks)")
        check(abs(releases - breaks) <= 1, "every cycle that starts should end, \(releases) vs \(breaks)")
    }

    /// 5K — "be reachable through the newly completed circuit route… be clearly highlighted by the
    /// live current… avoid appearing as an arbitrary reward disconnected from the puzzle." Scene 5
    /// borrowed Scene 3's chooser for a while, which picks the tile FARTHEST TO WALK TO and knows
    /// nothing about channels — so it could put the door on a tile the current never reaches, which
    /// is precisely the "arbitrary reward" the script rules out. Undo the stamp's scramble to make
    /// the circuit live, then check where the door landed.
    static func testSceneFiveExitStandsAtTheEndOfTheCurrent() {
        let gs = GameState(size: PrologueSize.sceneFive, name: "s5", stamp: .sceneFive)
        let m = gs.cubeModel
        guard let spawn = m.spawnLocation else { check(false, "Scene 5 has no spawn"); return }
        // The inverse of the stamp's scramble, in reverse order.
        for (axis, index) in [(2, 0), (0, 0), (0, 0)] {
            m.applySliceRotation(axis: axis, index: index, angle: -.pi / 2)
        }
        check(gs.liveCircuit, "undoing the scramble should complete the circuit")
        gs.update(deltaTime: 1.0 / 60.0)
        guard let exit = m.chosenExit else { check(false, "a live circuit should create the exit"); return }
        check(exit.face != spawn.face, "5K: the exit opens on a face other than the arrival face")
        guard let (ci, fi) = m.faceletAt(face: exit.face, row: exit.row, col: exit.col) else {
            check(false, "the exit is not a real tile"); return
        }
        let f = m.cubies[ci].facelets[fi]
        check(!f.mazeTile.channels.isEmpty, "5K: the exit tile carries a channel, so the current can highlight it")
        let depths = gs.channelDepths
        guard let d = depths[f.id.rawValue] else {
            check(false, "5K: the exit stands on a tile the current never reaches"); return
        }
        // The FAR end of the current: nothing the current reaches, and could hold a door, is deeper.
        var deeper = 0
        for face in CubeFace.allCases where face != spawn.face {
            for r in 0..<m.size {
                for c in 0..<m.size {
                    guard let (ci2, fi2) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    let g = m.cubies[ci2].facelets[fi2]
                    guard !g.mazeTile.channels.isEmpty, let dd = depths[g.id.rawValue] else { continue }
                    // The chosen tile now carries the portal props, so only OTHER empties compete.
                    if dd > d, g.props.isEmpty { deeper += 1 }
                }
            }
        }
        check(deeper == 0, "5K: \(deeper) fed channel tiles lie farther along the current than the door")
    }

    static func testSceneFiveVesselsMirrorLocalTruthNotProgress() {
        let gs = GameState(size: PrologueSize.sceneFive, name: "s5", stamp: .sceneFive)
        let m = gs.cubeModel
        var junctions = 0
        var sourceVessels = 0
        for face in CubeFace.allCases {
            for r in 0..<m.size {
                for c in 0..<m.size {
                    guard let (ci, fi) = m.faceletAt(face: face, row: r, col: c) else { continue }
                    let f = m.cubies[ci].facelets[fi]
                    guard f.props.contains(where: { $0.kind == .layeredVessel }) else { continue }
                    junctions += 1
                    if let src = m.channelSource,
                       src.face == face, src.row == r, src.col == c { sourceVessels += 1 }
                    // Every vessel stands ON a channel — "their bases touch the luminous grooves".
                    check(!f.mazeTile.channels.isEmpty, "a vessel at (\(r),\(c)) stands on no channel")
                }
            }
        }
        // `junctions > 0` was a WEAK CHECK: the channel SOURCE carries a vessel by construction, so
        // the count was 1 and the test passed green while the scene had no junction vessels at all
        // — the fault Eddie's screenshot showed. Count only vessels that are NOT the source.
        check(junctions - sourceVessels >= 3,
              "Scene 5 should stand vessels at its junctions, not only at the source "
              + "(found \(junctions) vessels, \(sourceVessels) of them the source)")
        // Settle, then check at least one vessel reads live while the circuit as a whole is not.
        for _ in 0..<240 { gs.update(deltaTime: 1.0 / 60.0) }
        check(!gs.liveCircuit, "the scene starts with the circuit broken")
        var anyLive = false
        for cu in m.cubies {
            for f in cu.facelets {
                for p in f.props where p.kind == .layeredVessel && p.anim > 0.5 { anyLive = true }
            }
        }
        check(anyLive, "a vessel on a fed junction should read live even though the circuit is not")
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

    /// THE MINIATURE MUST STAY ON ITS PEDESTAL THROUGH A TWIST.
    ///
    /// The world-model plinth rides its facelet like every other prop, so its grid coordinates are
    /// only true until the next turn. Cached at build time they named a slot the plinth had been
    /// rotated out of, and the miniature unfolded metres away across the stone with the pedestal
    /// that summoned it left bare (Eddie, 2026-08-27 — twist first, then press F).
    ///
    /// The check is the invariant rather than a particular pair of coordinates: wherever the plinth
    /// prop actually IS after a turn is where `worldModelTile` must point.
    static func testTheWorldModelFollowsItsPlinthThroughATwist() {
        let gs = prologueWorld("scene-5")
        let m = gs.cubeModel
        guard m.worldModelPlinths else {
            check(false, "scene 5 should stamp world-model plinths"); return
        }

        /// The plinth on the face the player is standing on, found by looking rather than by
        /// remembering — that is the one the model belongs to.
        func plinthBySearch() -> (face: CubeFace, row: Int, col: Int)? {
            let f = gs.player.face
            for r in 0..<gs.cubeModel.size {
                for c in 0..<gs.cubeModel.size {
                    guard let (ci, fi) = gs.cubeModel.faceletAt(face: f, row: r, col: c) else { continue }
                    if gs.cubeModel.cubies[ci].facelets[fi].props.contains(where: { $0.kind == .worldModel }) {
                        return (f, r, c)
                    }
                }
            }
            return nil
        }

        gs.update(deltaTime: 1.0 / 60.0)
        guard let before = plinthBySearch(), let tileBefore = gs.worldModelTile else {
            check(false, "the plinth and its tile must both resolve before any turn"); return
        }
        check(tileBefore == before,
              "before a turn the model sits on the plinth (\(tileBefore) vs \(before))")

        // Take a turn, and let it run to completion so the facelets have actually moved.
        gs.twistEnabled = true
        gs.startSliceRotation(clockwise: true)
        for _ in 0..<600 where gs.sliceRotation.isActive { gs.update(deltaTime: 1.0 / 60.0) }
        gs.update(deltaTime: 1.0 / 60.0)

        guard let after = plinthBySearch(), let tileAfter = gs.worldModelTile else {
            check(false, "the plinth and its tile must both still resolve after a turn"); return
        }
        check(tileAfter == after,
              "after a turn the model must follow the plinth (\(tileAfter) vs \(after))")
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

}
