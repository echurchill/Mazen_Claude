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
        // 6E — the SECOND DESCENT arrives by a face the first visit never used: the chamber is
        // entered from `+Z` originally, so the underside route lands on `-Z`, the far side of the
        // interior. "Unlike the first descent, there is no dramatic falling sensation. This time,
        // the player enters knowingly."
        arrivalSpawns["scene-6"] = (face: .negativeZ, row: n - 1, col: c, facing: .n)


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


    /// 6I — where the route-keyed portal stands: chosen like Scene 3's own exit (far from the
    /// player's arrival, walkable), but it must NOT be the nebula frame's tile — "the previous
    /// nebula portal remains as evidence of the first completion. The new portal is distinct:
    /// narrower, quieter." Deterministic, and deliberately a separate chooser: the first door is
    /// where the ORB pointed; this one answers the ROUTE.
    func createRouteKeyedExit(destinationID: Int) -> (face: CubeFace, row: Int, col: Int)? {
        guard routeKeyedExit == nil, let spawn = arrivalSpawns["scene-6"] ?? spawnLocation else { return nil }
        struct T: Hashable { let f: Int; let r: Int; let c: Int }
        var dist: [T: Int] = [T(f: spawn.face.rawValue, r: spawn.row, c: spawn.col): 0]
        var q = Array(dist.keys), head = 0
        while head < q.count {
            let t = q[head]; head += 1
            guard let face = CubeFace(rawValue: t.f) else { continue }
            let op = passableOpenings(face: face, row: t.r, col: t.c)
            for (sdir, mask, dr, dc) in [(SurfaceDirection.north, DirectionMask.north, -1, 0),
                                         (.south, .south, 1, 0), (.west, .west, 0, -1), (.east, .east, 0, 1)]
            where op.contains(mask) {
                let nr = t.r + dr, nc = t.c + dc
                let nt: T
                if nr >= 0, nr < size, nc >= 0, nc < size { nt = T(f: t.f, r: nr, c: nc) }
                else {
                    let cr = edgeCrossing(face: face, direction: sdir, row: t.r, col: t.c)
                    nt = T(f: cr.face.rawValue, r: cr.row, c: cr.col)
                }
                if dist[nt] == nil { dist[nt] = dist[T(f: t.f, r: t.r, c: t.c)]! + 1; q.append(nt) }
            }
        }
        var best: (t: T, d: Int)? = nil
        for (t, d) in dist {
            guard let face = CubeFace(rawValue: t.f),
                  let (ci, fi) = faceletAt(face: face, row: t.r, col: t.c),
                  cubies[ci].facelets[fi].props.isEmpty else { continue }
            if let ce = chosenExit, ce.face == face, ce.row == t.r, ce.col == t.c { continue }
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
        // "Less like a doorway and more like an aperture" — the field at ~0.6 of a door.
        cubies[ci].facelets[fi].props.append(
            Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .n, state: 2, extraScale: 0.6))
        routeKeyedExit = (face, pick.r, pick.c)
        markTopologyChanged()
        return routeKeyedExit
    }

    /// 6H — the METAL VESSEL, created when the scene-6 route first enters, NOT at stamp: on the
    /// first descent the chamber holds no vessel at all, and meeting one already standing there
    /// would spend the "familiar but transformed" reveal before the route that earns it (Eddie
    /// found it waiting on his first visit). Seated on searched, verified-empty ground — the fixed
    /// guess once landed on a plinth's tile and interact()'s vessel branch swallowed that plinth's
    /// press.
    func ensureMetalVessel() {
        let n = size, c = n / 2
        for cu in cubies { for f in cu.facelets {
            if f.props.contains(where: { $0.kind == .layeredVessel && $0.state == 6 }) { return }
        } }
        vessel: for dr in 1...3 {
            for dc in [-1, 1, 0, -2, 2] {
                let r = n - 1 - dr, col = c + dc
                guard r >= 0, col >= 0, col < n,
                      let (vci, vfi) = faceletAt(face: .negativeZ, row: r, col: col),
                      cubies[vci].facelets[vfi].props.isEmpty else { continue }
                cubies[vci].facelets[vfi].props.append(
                    Prop(kind: .layeredVessel, subRow: 1, subCol: 1, facing: .s, state: 6, extraScale: 1.15))
                markTopologyChanged()
                break vessel
            }
        }
    }
}
