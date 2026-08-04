import Foundation
import simd

/// B2 — Scene 3 "The Heart of the World", moved verbatim.
extension CubeModel {
    /// The inside of Scene 2's world. Six interior faces under one continuous maze, an obelisk
    /// standing inward from the middle of each, and six plinths that control them REMOTELY — no
    /// plinth on the same face as the obelisk it wakes, so every pairing is a journey.
    ///
    /// The scene's real subject is the chamber's geometry: every surface's "up" points at the same
    /// centre, so the orb hangs in the same place above you whichever face you are on, and crossing
    /// a face reorients the world around you rather than moving you through it. The puzzle exists to
    /// make you walk all six.
    func stampSceneThree() {
        let n = size, c = n / 2
        wallStyle = .metal          // patchwork iron, brass, steel, copper — see `WallStyle`
        symbolPairedPlinths = true
        atmosphericDepth = true     // distance, not discovery — see the flag

        // The six symbols. Distinct but visibly of one language — they are all caustic glyphs, which
        // is the Builders' hand. (The script asks for six purpose-made marks; these stand in until
        // that art exists, and the pairing logic does not care which slices they are.)
        let symbols = GameState.sceneThreeVoices
        let faces: [CubeFace] = [.positiveZ, .positiveY, .negativeX, .negativeZ, .positiveX, .negativeY]

        // AN OBELISK IN THE MIDDLE OF EVERY FACE, pointing inward at the orb. Inactive: "they are
        // dark and silent", and interacting with one does nothing — the control is somewhere else.
        for (i, face) in faces.enumerated() {
            guard let (ci, fi) = faceletAt(face: face, row: c, col: c) else { continue }
            for dir in [SurfaceDirection.north, .east, .south, .west] {
                setSharedEdge(face: face, row: c, col: c, dir, open: true)   // reachable from anywhere
            }
            var ob = Prop(kind: .obelisk, subRow: 1, subCol: 1, state: symbols[i])
            ob.anim = 0
            cubies[ci].facelets[fi].props.append(ob)
        }

        // THE PLINTHS. Face i's obelisk is controlled from face i+1 — a six-cycle, so no pairing is
        // the opposite face and none is local. "The exact mapping may be authored for navigational
        // rhythm, but should not follow an immediately obvious opposite-face rule for all six."
        // Positions vary per face so the six do not sit on a pattern either.
        let spots = [(1, 1), (1, c + 1), (c + 1, 1), (c + 1, c + 1), (1, c), (c + 1, c)]
        for (i, _) in faces.enumerated() {
            let host = faces[(i + 1) % faces.count]          // the face the CONTROL stands on
            let spot = spots[i]
            guard let (ci, fi) = faceletAt(face: host, row: spot.0, col: spot.1) else { continue }
            for dir in [SurfaceDirection.north, .east, .south, .west] {
                setSharedEdge(face: host, row: spot.0, col: spot.1, dir, open: true)
            }
            cubies[ci].facelets[fi].props.append(Prop(kind: .switchBase, subRow: 1, subCol: 1, facing: .n))
            // `state` is the SYMBOL, which is the whole binding: the plinth wakes whichever obelisk
            // carries the same mark, and nothing has to remember a pairing table.
            var cap = Prop(kind: .switchCap, subRow: 1, subCol: 1, facing: .n, state: symbols[i])
            cap.alignAnim = 0                                // 0 = flush and dark; 1 = raised, lit
            cubies[ci].facelets[fi].props.append(cap)
        }

        // Arrival: on the floor, looking across the chamber. "The player enters from above" — the
        // descent from Scene 2 lands them on a surface, and every surface here is a floor.
        spawnLocation = (face: .positiveZ, row: n - 1, col: c, facing: .n)

        // Fog stays ON (the script asks for it), but the six faces are large and the maze is the
        // point — reveal the arrival tile's surroundings so the first frame is not a wall of grey.
        for face in CubeFace.allCases {
            for r in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: col) else { continue }
                    cubies[ci].facelets[fi].tileState = .discovered
                    cubies[ci].facelets[fi].discoveryAmount = 1.0
                }
            }
        }
    }

    // MARK: - Prologue Scene 2 — "The Four Corners"

    /// Scene 2: four corner switches control a hidden slab, and the way onward is already built on a
    /// face the player cannot see. Solving the lock raises a control; turning it rotates that slab so
    /// the exit swings into view. Nothing is spawned by the puzzle — the assembly exists from the
    /// first frame, riding facelets on the hidden face (props travel with their tiles through a twist,
    /// so this needs no special support).
    ///
    /// **Geometry** (measured, not assumed — see `sceneTwoHiddenSlice`): the player walks `+Z`; the
    /// assembly sits on `+Y`, the face over the top edge; both have tiles in the outer **X** slab.
    /// One counter-clockwise quarter-turn of that slab carries `+Y` tiles onto `+Z` — the exit arrives
    /// on the player's own surface. The same slab also carries one edge column of `+Z`, which is why
    /// the far side of the maze visibly travels with it.
    // MARK: - Prologue Scene 4 — "The First Turn"

    /// Scene 4: the player is handed the twist, and the world refuses it.
    ///
    /// The portal is present from the first frame but **sealed**, and the route to it does not line
    /// up. Turning the slab would fix both — except three anchors bind that slab to the rest of the
    /// world, so the turn strains and springs back. Releasing all three makes the turn *legal*; the
    /// player still has to perform it. "Understanding prepares the world. Choice moves it."
    ///
    /// **The lock needs no new engine code.** Each anchor is its own BOND, and `canRotateSlice`
    /// already refuses a turn when *any* bonded group straddles the slice, while `dissolveBond`
    /// already removes one. So three bonds, each with one cubie inside the twistable slab and one
    /// outside, reproduce the scripted behaviour exactly — including the turn staying refused until
    /// the third is gone — using only machinery the garden's temple lock already proved.
    /// Set BOTH halves of a shared edge at once. An edge lives in two tiles, and `reconcileSharedEdges`
    /// resolves any disagreement in favour of OPEN — so closing one half alone does nothing at all.
    /// Every deliberate wall has to be written on both sides, which is exactly the mistake that put
    /// invisible walls in Scene 2 and the hub.
    /// Seal a rectangular play region's border on BOTH halves of every edge.
    ///
    /// The stamps used to do this with a one-sided `op.remove(.north)` on the inside tile, which was
    /// enough while movement was tested on the departing tile — you simply could not step out. Then
    /// `reconcileSharedEdges` arrived to fix the invisible walls, resolving disagreements in favour
    /// of OPEN, and quietly undid every one of those seals: the neighbour still said the edge was
    /// open, so the border re-opened and the player could walk off the world (Eddie, Scene 2).
    ///
    /// The reasoning that justified "open wins" was that every one-sided edit in this file is an
    /// insert. That was wrong, and wrong in a way a grep for `openings.remove` could not see: these
    /// six sites mutate a local `op` and assign it back. Hence this, and hence `setSharedEdge`.
    func sealRegionBorder(face: CubeFace, rLo: Int, rHi: Int, cLo: Int, cHi: Int) {
        for r in rLo...rHi {
            setSharedEdge(face: face, row: r, col: cLo, .west, open: false)
            setSharedEdge(face: face, row: r, col: cHi, .east, open: false)
        }
        for c in cLo...cHi {
            setSharedEdge(face: face, row: rLo, col: c, .north, open: false)
            setSharedEdge(face: face, row: rHi, col: c, .south, open: false)
        }
    }

    func setSharedEdge(face: CubeFace, row: Int, col: Int, _ dir: SurfaceDirection, open: Bool) {
        let mask: DirectionMask = dir == .north ? .north : dir == .south ? .south : dir == .west ? .west : .east
        guard let (ci, fi) = faceletAt(face: face, row: row, col: col) else { return }
        // Closing an edge must clear it from openEdges too. That mask means "fully open, no geometry
        // at all" (a merged room's interior) and `edgeAllows` checks it FIRST — so an edge closed
        // only in `openings` stayed walkable, and a sealed border made of such tiles still let the
        // player out. Opening does NOT set it: a gateway is not a room.
        if open { cubies[ci].facelets[fi].mazeTile.openings.insert(mask) }
        else {
            cubies[ci].facelets[fi].mazeTile.openings.remove(mask)
            cubies[ci].facelets[fi].mazeTile.openEdges.remove(mask)
        }

        let (dr, dc) = dir == .north ? (-1, 0) : dir == .south ? (1, 0) : dir == .west ? (0, -1) : (0, 1)
        let nr = row + dr, nc = col + dc
        let far: (face: CubeFace, row: Int, col: Int, back: SurfaceDirection)
        if nr >= 0, nr < size, nc >= 0, nc < size {
            far = (face, nr, nc, dir.opposite)
        } else {
            let cr = edgeCrossing(face: face, direction: dir, row: row, col: col)
            far = (cr.face, cr.row, cr.col, cr.facing.opposite)
        }
        guard let (nci, nfi) = faceletAt(face: far.face, row: far.row, col: far.col) else { return }
        let backMask: DirectionMask = far.back == .north ? .north : far.back == .south ? .south
                                    : far.back == .west ? .west : .east
        if open { cubies[nci].facelets[nfi].mazeTile.openings.insert(backMask) }
        else {
            cubies[nci].facelets[nfi].mazeTile.openings.remove(backMask)
            cubies[nci].facelets[nfi].mazeTile.openEdges.remove(backMask)
        }
    }

}
