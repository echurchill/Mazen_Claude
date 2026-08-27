import Foundation
import simd

/// B2 — Scene 5 "The Broken Meridian" + its six face rotators, moved verbatim.
extension CubeModel {
    /// A pale world whose luminous channels have been broken by misaligned slices. The player must
    /// route one live current to three receivers AT ONCE — and the difficulty is not finding three
    /// switches, it is that "one turn may connect the current to a receiver while disconnecting an
    /// earlier path. A turn that is locally beautiful may be globally wrong."
    ///
    /// AUTHORED BY BREAKING, not by designing. The circuit is carved COMPLETE — source to all three
    /// receivers — and then a few known twists are applied to misalign it. That guarantees a
    /// solution exists by construction, which hand-authoring a three-receiver puzzle on a twisting
    /// 7³ absolutely does not; and because those scrambling twists share slabs, undoing one disturbs
    /// another, which is the exact experience the scene is about. The script permits this: "the
    /// exact sequence can be authored for engine constraints, but the dramatic shape should remain."
    func stampSceneFive() {
        let n = size, c = n / 2

        // Open ground: "low ridges, shallow channel beds, and raised causeways rather than enclosed
        // corridors". The channels carry the puzzle; walls would only obstruct reading it.
        for face in CubeFace.allCases {
            for r in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: col) else { continue }
                    cubies[ci].facelets[fi].mazeTile.openings = [.north, .east, .south, .west]
                    cubies[ci].facelets[fi].mazeTile.openEdges = [.north, .east, .south, .west]
                    // Scene 5 is "smooth pale stone", not Scene 3's ironwork. It wore plating because that was
                    // what existed, and a dark, high-contrast floor is the worst possible ground for a
                    // world whose whole subject is light running through it.
                    cubies[ci].facelets[fi].terrain = .paleStone
                    cubies[ci].facelets[fi].tileState = .discovered
                    cubies[ci].facelets[fi].discoveryAmount = 1.0
                }
            }
        }

        /// Walk a channel `steps` tiles from a starting tile, CROSSING FACES properly.
        ///
        /// The first attempt laid runs within a single face and assumed the tile across a cube edge
        /// was the one with the same row/col. It is not — `edgeCrossing` conjugates both the tile and
        /// the direction — so every run stopped dead at the first edge with a groove pointing at a
        /// blank tile, and the circuit could not be completed by any sequence of turns. Walking it
        /// asks the crossing where the next tile is instead of guessing.
        ///
        /// Returns where it ended, so the caller can put a receiver at the end of a run rather than
        /// computing that position a second time and getting it wrong the same way.
        @discardableResult
        func layRun(from start: (face: CubeFace, row: Int, col: Int),
                    heading: SurfaceDirection, steps: Int) -> (face: CubeFace, row: Int, col: Int) {
            var here = start
            var dir = heading
            for _ in 0..<steps {
                let (dr, dc) = dir == .north ? (-1, 0) : dir == .south ? (1, 0)
                            : dir == .west ? (0, -1) : (0, 1)
                let nr = here.row + dr, nc = here.col + dc
                let next: (face: CubeFace, row: Int, col: Int)
                let back: SurfaceDirection
                if nr >= 0, nr < n, nc >= 0, nc < n {
                    next = (here.face, nr, nc); back = dir.opposite
                } else {
                    let cr = edgeCrossing(face: here.face, direction: dir, row: here.row, col: here.col)
                    next = (cr.face, cr.row, cr.col); back = cr.facing.opposite
                    dir = cr.facing            // keep going the same way ON THE NEW FACE
                }
                let outMask: DirectionMask = back == .north ? .south : back == .south ? .north
                                           : back == .west ? .east : .west
                let backMask: DirectionMask = back == .north ? .north : back == .south ? .south
                                            : back == .west ? .west : .east
                if let (ci, fi) = faceletAt(face: here.face, row: here.row, col: here.col) {
                    cubies[ci].facelets[fi].mazeTile.channels.insert(outMask)
                }
                if let (nci, nfi) = faceletAt(face: next.face, row: next.row, col: next.col) {
                    cubies[nci].facelets[nfi].mazeTile.channels.insert(backMask)
                }
                here = next
            }
            return here
        }

        // THE SOURCE, and three runs out of it, each crossing onto a different face — the receivers
        // are deliberately not reachable "by extending the current path through a single obvious
        // turn". Long enough to cross an edge and continue on the far side.
        channelSource = (face: .positiveZ, row: c, col: c)
        let src = (face: CubeFace.positiveZ, row: c, col: c)
        let ends = [layRun(from: src, heading: .north, steps: c + 1 + c),
                    layRun(from: src, heading: .south, steps: c + 1 + c),
                    layRun(from: src, heading: .west,  steps: c + 1 + c)]

        channelReceivers = []
        for end in ends {
            guard let (ci, fi) = faceletAt(face: end.face, row: end.row, col: end.col) else { continue }
            // 5D — "a raised crescent or bowl-like structure embedded into a channel junction."
            // Was a scaled obelisk while the scene was being proven; the bowl is the scripted
            // object, and its shape is also what makes the three receiver STATES readable — an
            // empty bowl, a bowl filling while the pulse feeds it, a bowl locked full.
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .channelBowl, subRow: 1, subCol: 1))
            channelReceivers.append(cubies[ci].facelets[fi].id.rawValue)
        }

        if let (ci, fi) = faceletAt(face: src.face, row: src.row, col: src.col) {
            // 5C — "a low circular basin set into the ground, surrounded by three nested rings of
            // translucent mineral. At its center, liquid light gathers and releases a slow pulse."
            // It was a layered vessel while the scene was being proven, and that actively muddied
            // 5F: the scene argues vessels OBSERVE the circuit, and the source IS the circuit — the
            // one thing here that must not be a vessel. F on the basin fires the diagnostic pulse.
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .channelBasin, subRow: 1, subCol: 1))
        }

        // 5F — VESSELS AT THE JUNCTIONS. "Their bases touch the luminous grooves. Their rings contain
        // small gaps or windows that show whether nearby channels are currently aligned… They do not
        // give instructions. They mirror local truth."
        //
        // Placed where a channel BRANCHES — three arms or more — because a junction is where local
        // truth is worth reading: it is the tile whose alignment decides which way the current can
        // go. Their rings are driven per frame from live channel state (see tickChannelCircuit), so
        // a vessel is never telling you anything the world is not.
        // Where a channel crosses a FACE EDGE. Looking for three-armed junctions found nothing but
        // the source itself — three runs radiating from one tile has exactly one branch point — and
        // a vessel that only ever stands where the current begins mirrors nothing.
        //
        // A face edge is the interesting place regardless: it is where the slabs part, so it is
        // precisely where a turn can break the route. "Their rings contain small gaps or windows
        // that show whether nearby channels are currently aligned."
        for face in CubeFace.allCases {
            for r in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: col) else { continue }
                    let ch = cubies[ci].facelets[fi].mazeTile.channels
                    guard !ch.isEmpty else { continue }
                    let onEdge = (r == 0 || r == n - 1 || col == 0 || col == n - 1)
                    guard onEdge else { continue }
                    guard !cubies[ci].facelets[fi].props.contains(where: { $0.kind == .layeredVessel }) else { continue }
                    var v = Prop(kind: .layeredVessel, subRow: 1, subCol: 1, facing: .s,
                                 state: 4, extraScale: 0.85, offsetX: 0.18, offsetY: 0.18)
                    v.anim = 0
                    cubies[ci].facelets[fi].props.append(v)
                }
            }
        }

        // NOW BREAK IT — with a scramble chosen by SEARCH rather than by taste.
        //
        // The first one I picked by hand was solvable in two turns and every turn helped, so the
        // scene taught nothing: a monotone climb is a checklist, not a configuration problem. This
        // one was found by enumerating three-turn scrambles and keeping those where the shortest
        // solution is three turns, the player arrives with most of the circuit already working, and
        // at least one available turn makes things WORSE. That last condition is the whole scene —
        // "a turn that is locally beautiful may be globally wrong."
        //
        // Two turns on the same slab is a half-turn, which is why it appears twice: it displaces the
        // channels further without adding an axis, so undoing it cannot be stumbled into.
        for (axis, index) in [(0, 0), (0, 0), (2, 0)] {
            applySliceRotation(axis: axis, index: index, angle: .pi / 2)
        }

        // AFTER the scramble, deliberately: the rotators are placed on the world as the player
        // finds it, so "off the channels" is true of the world they will actually walk. Stamped
        // before, the scramble would carry them onto whatever tiles it liked.
        stampFaceRotators()
        stampWorldModelPlinth()

        spawnLocation = (face: .positiveZ, row: c + 1, col: c, facing: .n)
    }

    // MARK: - Prologue Scene 3 — "The Heart of the World"

    /// Scene 5's six rotators — one near the middle of each face, kept off the channels and off
    /// anything already standing there (the source, the receivers, the junction vessels). Searched
    /// outward from the face centre rather than placed at it, because the centre of `+Z` IS the
    /// source: the natural spot is taken on exactly the face the player arrives on.
    /// PROTOTYPE — one world-model plinth, on the face the player arrives on, a few tiles from the
    /// spawn so it is met early but is not the first thing underfoot.
    ///
    /// Scene 5 is the right place to try it: its channels run ACROSS faces, and a cross-face routing
    /// puzzle is exactly what cannot be held in the head from ground level. If the idea works
    /// anywhere it works here — and if it does not work here it probably does not work.
    func stampWorldModelPlinth() {
        let n = size, c = n / 2
        // Searched rather than placed: the middle of `+Z` is the source, and the rotator has already
        // taken the nearest free tile to it.
        for radius in 1..<n {
            for dr in -radius...radius {
                for dc in -radius...radius where abs(dr) == radius || abs(dc) == radius {
                    let r = c + dr, col = c + dc
                    guard r >= 0, r < n, col >= 0, col < n,
                          let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                    let f = cubies[ci].facelets[fi]
                    guard f.props.isEmpty, f.mazeTile.channels.isEmpty else { continue }
                    cubies[ci].facelets[fi].props.append(
                        Prop(kind: .worldModel, subRow: 1, subCol: 1, facing: .s, state: 5))
                    worldModelPlinthAt = (CubeFace.positiveZ, r, col)
                    markTopologyChanged()
                    return
                }
            }
        }
    }

    func stampFaceRotators() {
        let n = size, c = n / 2
        faceRotators = true
        for face in CubeFace.allCases {
            var best: (r: Int, col: Int, d: Int)? = nil
            for r in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: col) else { continue }
                    let f = cubies[ci].facelets[fi]
                    guard f.props.isEmpty, f.mazeTile.channels.isEmpty else { continue }
                    // Manhattan distance from the middle: nearest free tile wins, ties by row then
                    // column so the six controls land in the same place every run.
                    let d = abs(r - c) + abs(col - c)
                    if best == nil || d < best!.d { best = (r, col, d) }
                }
            }
            guard let spot = best, let (ci, fi) = faceletAt(face: face, row: spot.r, col: spot.col) else { continue }
            cubies[ci].facelets[fi].props.append(Prop(kind: .plinth, subRow: 1, subCol: 1, facing: .n))
            // Already risen: Scene 2's rotator grows out of its disc once, as a reveal. This one is
            // a tool the player uses over and over, so it stands ready — the ceremony belongs to a
            // one-off, not to something pressed a dozen times while reading a route.
            var cyl = Prop(kind: .alignmentCylinder, subRow: 1, subCol: 1, facing: .n, state: 0)
            cyl.anim = 1
            cubies[ci].facelets[fi].props.append(cyl)
        }
    }

}
