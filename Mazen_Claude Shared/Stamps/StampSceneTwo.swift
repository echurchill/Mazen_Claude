import Foundation
import simd

/// B2 — Scene 2 "The Four Corners", its hidden slice/assembly helpers included.
extension CubeModel {
    func stampSceneTwo() {
        let n = size, c = n / 2
        let R = 5                                            // play region half-extent → an (2R+1)² arena
        let rLo = max(0, c - R), rHi = min(n - 1, c + R)
        let cLo = max(0, c - R), cHi = min(n - 1, c + R)
        wallStyle = .dressed                                 // ruined stone, re-derived from topology (twist-safe)

        // A clearing at the centre — done BEFORE sealing so it can't reopen the region wall.
        stampRoom(face: .positiveZ, top: max(rLo, c - 1), left: max(cLo, c - 1), height: 3, width: 3)

        for r in rLo...rHi {
            for col in cLo...cHi {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                var op = cubies[ci].facelets[fi].mazeTile.openings
                if r == rLo { op.remove(.north) }             // seal the region border
                if r == rHi { op.remove(.south) }
                if col == cLo { op.remove(.west) }
                if col == cHi { op.remove(.east) }
                cubies[ci].facelets[fi].mazeTile.openings = op
                cubies[ci].facelets[fi].tileState = .discovered
                cubies[ci].facelets[fi].discoveryAmount = 1.0
                // Scene 2's ruin gradient runs the OPPOSITE way to the garden's: the centre is the
                // most collapsed ("age has radiated outward from the centre") and the perimeter is
                // nearly intact. wallType 0 = cleanest … 3 = most broken.
                // `d` is distance from the region EDGE, so it is largest at the centre. The mapping
                // was inverted — it made the perimeter the most broken and the centre the cleanest,
                // which is backwards from the script AND from the comment directly above it: "the
                // walls nearest the center are incomplete… farther away, the maze becomes
                // increasingly intact… age, pressure, or some unknown force has radiated outward
                // from the center." Corrected: ruin now decreases with distance from the middle.
                let d = min(min(r - rLo, rHi - r), min(col - cLo, cHi - col))
                var type = d >= 4 ? 3 : (d == 3 ? 2 : (d >= 1 ? 1 : 0))
                // 2D's NAVIGATIONAL LANGUAGE — "each quadrant may carry a subtle environmental
                // character… differing degrees of wall preservation… these distinctions help
                // orientation without turning the maze into four colour-coded zones."
                //
                // A scene whose puzzle is FINDING FOUR CORNERS gave the player nothing to tell one
                // corner from another. So each quadrant leans a step cleaner or a step more broken
                // than the gradient alone would put it — which also changes how much rubble and
                // overgrowth its walls carry, since `wallType` drives both. One step, never two:
                // enough to notice you have been here before, not enough to read as a colour code.
                // …applied to only about a third of a quadrant's tiles, chosen by hash. Shifting
                // every tile moved a quadrant's whole character by a full step, which is precisely
                // the "four colour-coded zones" the script warns against; shifting a scattering of
                // them reads as one corner having weathered differently from another.
                let quadrant = ((r < c) ? 0 : 2) + ((col < c) ? 0 : 1)
                var qh = UInt32(truncatingIfNeeded: r &* 73856093 ^ col &* 19349663 ^ quadrant &* 83492791)
                qh ^= qh >> 15; qh = qh &* 2246822519; qh ^= qh >> 13
                if qh % 100 < 34 { type += [0, 1, -1, 0][quadrant] }
                cubies[ci].facelets[fi].mazeTile.wallType = UInt8(max(0, min(3, type)))
            }
        }

        // Carve the spine so the puzzle is solvable through the procedural maze: the spawn row, the
        // four corridors out to the corner switches, and the spur north to the central plinth.
        let spread = 3
        var spine = Set<[Int]>()
        for col in (c - spread)...(c + spread) { spine.insert([c, col]) }
        for row in (c - spread)...(c + spread) { spine.insert([row, c - spread]); spine.insert([row, c + spread]) }
        for row in (c - spread)...c { spine.insert([row, c]) }
        for rc in spine {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: rc[0], col: rc[1]) else { continue }
            var op = cubies[ci].facelets[fi].mazeTile.openings
            if spine.contains([rc[0] - 1, rc[1]]) { op.insert(.north) }
            if spine.contains([rc[0] + 1, rc[1]]) { op.insert(.south) }
            if spine.contains([rc[0], rc[1] - 1]) { op.insert(.west) }
            if spine.contains([rc[0], rc[1] + 1]) { op.insert(.east) }
            cubies[ci].facelets[fi].mazeTile.openings = op
            cubies[ci].facelets[fi].mazeTile.openEdges = op
        }

        // The four corner switches — three engaged, the fourth off (the one to find). Reuses the
        // proven switch cap/base pair and the shared switchMask() bookkeeping.
        let switchSpots: [(Int, Int, Int, Int)] = [
            (c - spread, c - spread, 1, 1), (c - spread, c + spread, 1, 2),
            (c + spread, c - spread, 1, 3), (c + spread, c + spread, 0, 4),
        ]
        for (r, col, engaged, ordinal) in switchSpots {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
            cubies[ci].facelets[fi].props.append(Prop(kind: .switchBase, subRow: 1, subCol: 1, facing: .n))
            var cap = Prop(kind: .switchCap, subRow: 1, subCol: 1, facing: .n, state: ordinal)
            cap.anim = Float(engaged); cap.alignAnim = Float(engaged)
            cubies[ci].facelets[fi].props.append(cap)
        }

        // The control plinth — a map of CONDITIONS, not of the maze: one dot per switch, filled when
        // that switch is engaged. `updateDoorPlinths` drives it from switchMask().
        //
        // It stands TWO tiles from where the assembly arrives (Eddie, playtest): the turn happens at
        // the world's edge, and from the middle of the face that is ~100 m away — far enough that the
        // payoff was easy to miss entirely, and invisible if you happened to be facing the other way.
        // Standing here you commit the turn and the exit swings in directly ahead of you, with only
        // the approach corridor between. It also makes the script's "nothing stands behind it" literal:
        // the empty ground beyond the plinth is exactly where the way onward will appear.
        if let (ci, fi) = faceletAt(face: .positiveZ, row: c, col: 2) {
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .plinth, subRow: 1, subCol: 1, facing: .w, state: TextureLoader.progressMaskBase + 0b0111))
            progressPlinth = (ci, fi)
        }

        // "The player stands near the southern edge of a broad, irregular clearing… Directly ahead
        // stands a single stone plinth." Arrive south of centre looking north, across the clearing to
        // the plinth — NOT at the hidden chamber, which is where the default arrival would land.
        spawnLocation = (face: .positiveZ, row: min(n - 1, c + 1), col: c, facing: .n)

        // SCENE 2I — the approach that only completes after the turn. "A route that previously
        // terminated at the far wall now continues onto the rotated slice."
        //
        // The assembly arrives in column 0 of this face (measured: the twist slab's `+Z` column), which
        // is outside the sealed play region — so a corridor runs west out of the clearing, breaches the
        // region border, and then runs the full height of column 1, ending against the world's edge.
        // Before the turn it is a dead end against blank wall. After it, column 0 holds the assembly,
        // whose tiles are open on all four sides, and the corridor simply continues onto them.
        //
        // The column-1 run is deliberately full height rather than a single spur: the rotation remaps
        // rows as well as faces, so authoring one row would be betting on where the assembly lands.
        // Meeting it along the whole edge is robust to that, and reads as a perimeter route.
        let approachRow = c
        for r in 0..<n {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: 1) else { continue }
            var op: DirectionMask = [.east, .west]                 // through to the region, and out to the edge
            if r > 0 { op.insert(.north) }
            if r < n - 1 { op.insert(.south) }
            cubies[ci].facelets[fi].mazeTile.openings = op
            cubies[ci].facelets[fi].mazeTile.openEdges = op
            cubies[ci].facelets[fi].tileState = .discovered
            cubies[ci].facelets[fi].discoveryAmount = 1.0
            cubies[ci].facelets[fi].mazeTile.wallType = 0          // the perimeter is the best-preserved stone
        }
        // Run the approach east from that corridor to the spine's western arm, breaching the region's
        // sealed west border on the way. INSERT rather than assign: this row crosses the north–south
        // corridor that serves the western corner switches, and replacing its openings would sever it.
        for col in 1...(c - spread) {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: approachRow, col: col) else { continue }
            cubies[ci].facelets[fi].mazeTile.openings.insert(.east)
            cubies[ci].facelets[fi].mazeTile.openings.insert(.west)
            cubies[ci].facelets[fi].mazeTile.openEdges.insert(.east)
            cubies[ci].facelets[fi].mazeTile.openEdges.insert(.west)
            cubies[ci].facelets[fi].tileState = .discovered
            cubies[ci].facelets[fi].discoveryAmount = 1.0
        }

        // Reveal the ENTIRE turning slab (Eddie, playtest: "as the slice rotates, it is very
        // transparent" — a band of floating fragments with sky between them).
        //
        // A slab is a plate: its `-X` face is the outer shell, and its RIM is one column each of `+Z`,
        // `-Z`, `+Y` and `-Y`. Only the `+Z` column and the three assembly tiles had ever been
        // revealed, and undiscovered tiles render nothing — so most of the plate was simply absent.
        // Revealing `-X` alone does not help either: its normal is parallel to the rotation axis, so
        // it never tilts into view; it is the rim that sweeps past the player.
        //
        // So: reveal every tile whose cubie lies in the slab, on whichever face it belongs to. The
        // plate then turns as a continuous surface, with its own dressed walls riding it.
        // Named BEFORE the reveal below, which needs to know which slab is the turning one. (Verified
        // by testSceneTwoHiddenFaceTurnsIntoView: this slab, counter-clockwise, lands `+Y` on `+Z`.)
        let hidden = sceneTwoHiddenSlice()
        scriptedTwistSlice = (axis: hidden.axis, index: hidden.index, clockwise: false)
        let turning = hidden
        for face in CubeFace.allCases {
            for r in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: col) else { continue }
                    let p = cubies[ci].position
                    let inSlab = (turning.axis == 0 && p.x == Int32(turning.index))
                              || (turning.axis == 1 && p.y == Int32(turning.index))
                              || (turning.axis == 2 && p.z == Int32(turning.index))   // (axis is 0 today; kept general)
                    guard inSlab, cubies[ci].facelets[fi].tileState != .discovered else { continue }
                    cubies[ci].facelets[fi].tileState = .discovered
                    cubies[ci].facelets[fi].discoveryAmount = 1.0
                    cubies[ci].facelets[fi].mazeTile.wallType = 0   // the outer shell is the best-preserved stone
                    // Terrain by role, now that the cut faces carry their own plating:
                    //  • `-X` — the slab's outer SHELL. Plated: it is the underside of a slab of
                    //    world, and reads as built structure rather than a floating lawn.
                    //  • `+Z` — playable ground the player walks. Left as maze, untouched.
                    //  • the rest — the slab's RIM columns. Ordinary ground, so grass: these are the
                    //    world's surface seen edge-on, not part of the machine (Eddie).
                    switch face {
                    case .negativeX: cubies[ci].facelets[fi].terrain = .plating
                    case .positiveZ: break
                    default:         cubies[ci].facelets[fi].terrain = .grass
                    }
                }
            }
        }

        stampSceneTwoHiddenAssembly()

        // The LOCK. Without a bond the rotation control could be raised before the puzzle is solved
        // (the gate is `bondedGroups.isEmpty`), and the twist itself would already be legal. Bond the
        // hidden chamber's cubie to the central plinth's: the group STRADDLES the twistable slab, so
        // `canRotateSlice` refuses the turn, and dissolving it on the fourth switch is what makes the
        // world movable. Stored in `templeDoorBond` so disengaging a switch re-applies it.
        if let pp = progressPlinth, let chamberCI = sealedPortalCubies.first {
            let bond: Set<Int> = [chamberCI, pp.ci]
            addBond(bond)
            templeDoorBond = bond
        }

        // Two-sided, and LAST, so nothing carved above can leave a way out and
        // `reconcileSharedEdges` has nothing to disagree with.
        sealRegionBorder(face: .positiveZ, rLo: rLo, rHi: rHi, cLo: cLo, cHi: cHi)
        // …and EVERY other face too. Sealing the play face was enough while the world stood still,
        // but the whole point of this scene is that a slab TURNS: tiles from other faces swing into
        // reach, and those had never been sealed, so the turn handed the player a way to walk
        // straight off the world (Eddie). Edges travel with their tiles through a twist, so sealing
        // each face now keeps every face an island however the world is rearranged.
        for face in CubeFace.allCases where face != .positiveZ {
            sealRegionBorder(face: face, rLo: 0, rHi: n - 1, cLo: 0, cHi: n - 1)
        }
    }


    /// Scene 3K — "the orb chooses a surface". The exit is not authored: it is SELECTED when the
    /// puzzle completes, from the tiles that qualify.
    ///
    /// The rules are the script's — not on the player's starting face, reachable, not on a face edge
    /// or corner (the awkward triple-points where a portal frame would straddle two surfaces), room
    /// for the structure — plus "preferably encourage the player to cross at least one more face
    /// boundary", so of the candidates the FURTHEST by walking distance wins. Deterministic, and
    /// "fixed for the current world state once made": stamped once, never reconsidered.
    /// 5K — Scene 5's own exit rule, which is NOT Scene 3's. Scene 3 puts its door as far from you
    /// as walking allows; Scene 5's placement rules are all about the circuit:
    ///
    ///   - "be reachable through the newly completed circuit route"
    ///   - "be clearly highlighted by the live current"
    ///   - "avoid appearing as an arbitrary reward disconnected from the puzzle"
    ///
    /// So the door stands at the FAR END OF THE CURRENT — the fed channel tile deepest from the
    /// source, on a face other than the one you arrived on. That satisfies 5L for free ("the player
    /// follows the live current across the world to reach the portal"): the way to it is the thing
    /// the player just repaired, and walking it means reading the route.
    ///
    /// `depths` comes from the caller because the reach walk lives with the scene's state, not here.
    @discardableResult
    func createCircuitExit(destinationID: Int, depths: [Int: Int]) -> (face: CubeFace, row: Int, col: Int)? {
        guard chosenExit == nil, let spawn = spawnLocation else { return nil }
        var best: (ci: Int, fi: Int, face: CubeFace, r: Int, c: Int, d: Int)? = nil
        for face in CubeFace.allCases where face != spawn.face {
            for r in 0..<size {
                for c in 0..<size {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: c) else { continue }
                    let f = cubies[ci].facelets[fi]
                    // ON the circuit, LIT by it, and not already occupied — a receiver, the source
                    // or a junction vessel is a thing the scene already means something by.
                    guard !f.mazeTile.channels.isEmpty, f.props.isEmpty,
                          let d = depths[f.id.rawValue] else { continue }
                    // Deterministic ties, so the door is in the same place every run.
                    if best == nil || d > best!.d
                        || (d == best!.d && (face.rawValue, r, c) < (best!.face.rawValue, best!.r, best!.c)) {
                        best = (ci, fi, face, r, c, d)
                    }
                }
            }
        }
        guard let pick = best else { return nil }
        // `.goto`, not `.push`: Scene 6 is a RETURN to a world already on the stack, and pushing
        // would put the same instance in it twice. "The player is not being sent backward. They are
        // arriving from a new direction into a world that remembers" — the world it leaves stays in
        // the registry with all its state, so replacing in place loses nothing and does not nest.
        cubies[pick.ci].facelets[pick.fi].props.append(
            Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n, state: destinationID, transition: .goto))
        styledPortals.append(StyledPortal(ci: pick.ci, fi: pick.fi, facing: .n))
        cubies[pick.ci].facelets[pick.fi].props.append(
            Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .n, state: 2))
        chosenExit = (pick.face, pick.r, pick.c)
        markTopologyChanged()
        return (pick.face, pick.r, pick.c)
    }

    @discardableResult
    func createChosenExit(destinationID: Int) -> (face: CubeFace, row: Int, col: Int)? {
        guard chosenExit == nil, let spawn = spawnLocation else { return nil }
        struct T: Hashable { let f: Int; let r: Int; let c: Int }
        var dist: [T: Int] = [:]
        let start = T(f: spawn.face.rawValue, r: spawn.row, c: spawn.col)
        dist[start] = 0
        var q = [start], head = 0
        while head < q.count {
            let t = q[head]; head += 1
            guard let face = CubeFace(rawValue: t.f),
                  let (ci, fi) = faceletAt(face: face, row: t.r, col: t.c) else { continue }
            let op = cubies[ci].facelets[fi].mazeTile.openings
            for (dir, mask, dr, dc) in [(SurfaceDirection.north, DirectionMask.north, -1, 0),
                                        (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)]
            where op.contains(mask) {
                let nr = t.r + dr, nc = t.c + dc
                let nt: T
                if nr >= 0, nr < size, nc >= 0, nc < size { nt = T(f: t.f, r: nr, c: nc) }
                else {
                    let cr = edgeCrossing(face: face, direction: dir, row: t.r, col: t.c)
                    nt = T(f: cr.face.rawValue, r: cr.row, c: cr.col)
                }
                if dist[nt] == nil { dist[nt] = dist[t]! + 1; q.append(nt) }
            }
        }
        var best: (t: T, d: Int)? = nil
        for (t, d) in dist {
            guard t.f != spawn.face.rawValue else { continue }
            guard t.r > 0, t.r < size - 1, t.c > 0, t.c < size - 1 else { continue }
            guard let face = CubeFace(rawValue: t.f),
                  let (ci, fi) = faceletAt(face: face, row: t.r, col: t.c),
                  cubies[ci].facelets[fi].props.isEmpty else { continue }
            // Ties broken by face then position, so the choice is identical every run.
            if best == nil || d > best!.d
                || (d == best!.d && (t.f, t.r, t.c) < (best!.t.f, best!.t.r, best!.t.c)) {
                best = (t, d)
            }
        }
        guard let pick = best?.t, let face = CubeFace(rawValue: pick.f),
              let (ci, fi) = faceletAt(face: face, row: pick.r, col: pick.c) else { return nil }
        cubies[ci].facelets[fi].props.append(
            Prop(kind: .portal, subRow: 1, subCol: 1, facing: .n, state: destinationID, transition: .push))
        styledPortals.append(StyledPortal(ci: ci, fi: fi, facing: .n))
        cubies[ci].facelets[fi].props.append(Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .n, state: 2))
        chosenExit = (face, pick.r, pick.c)
        markTopologyChanged()
        return chosenExit
    }

    /// The outer X-slab that carries the hidden face into view, and the `+Y` tiles riding it.
    /// Derived from live cubie positions rather than hardcoded, so it stays correct at any size.
    /// Returns the slab index plus the hidden-face tiles in it, ordered along the strip.
    func sceneTwoHiddenSlice() -> (axis: Int, index: Int, strip: [(row: Int, col: Int)]) {
        let n = size
        let index = 0                                     // the x == 0 outer slab
        var strip: [(row: Int, col: Int)] = []
        for r in 0..<n {
            for col in 0..<n {
                guard let (ci, _) = faceletAt(face: .positiveY, row: r, col: col) else { continue }
                if cubies[ci].position.x == Int32(index) { strip.append((r, col)) }
            }
        }
        return (0, index, strip)
    }


    /// Has this world's scripted turn happened — is the hidden assembly facing the player's face?
    /// Asked ACROSS worlds by Scene 6's route-keyed portal ("Scene 2's exterior world remains
    /// twisted"), so it reads current geometry rather than any remembered flag: if a later twist
    /// puts the chamber back, the fact honestly stops being true.
    var sceneTwoIsTurned: Bool {
        for cu in cubies.indices {
            for f in cubies[cu].facelets where f.props.contains(where: { $0.kind == .portal && $0.state == 13 }) {
                if let loc = locate(faceletID: f.id.rawValue) { return loc.face == .positiveZ }
            }
        }
        return false
    }
}
