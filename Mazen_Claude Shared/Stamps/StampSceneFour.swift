import Foundation
import simd

/// B2 — Scene 4 "The First Turn", moved verbatim.
extension CubeModel {
    func stampSceneFour() {
        let n = size, c = n / 2
        wallStyle = .dressed
        vesselTeachesTheTwist = true

        // Reveal EVERY face. The anchors are deliberately spread across the world so releasing them
        // circumnavigates it, and the script asks for "fog of discovery: minimal or disabled" — a
        // world you are meant to walk right around should not be hidden from you.
        for face in CubeFace.allCases {
            for r in 0..<n {
                for col in 0..<n {
                    guard let (ci, fi) = faceletAt(face: face, row: r, col: col) else { continue }
                    cubies[ci].facelets[fi].tileState = .discovered
                    cubies[ci].facelets[fi].discoveryAmount = 1.0
                    cubies[ci].facelets[fi].mazeTile.wallType = 0
                }
            }
        }
        for r in 0..<n {
            for col in 0..<n {
                guard let (ci, fi) = faceletAt(face: .positiveZ, row: r, col: col) else { continue }
                cubies[ci].facelets[fi].tileState = .discovered
                cubies[ci].facelets[fi].discoveryAmount = 1.0
                cubies[ci].facelets[fi].mazeTile.wallType = 0
            }
        }

        // The player TWISTS here, so the slab that moves is the one under their feet: the outer slice
        // of the face they walk. Everything the scene needs — portal, route, bonds — is arranged
        // around that one slab.
        let (tAxis, tIndex) = sliceAxisAndIndex(for: .positiveZ)
        scriptedTwistSlice = (axis: tAxis, index: tIndex, clockwise: false)   // used by the debug replay key

        // ── THE MISALIGNED ROUTE (Scene 4's actual puzzle) ─────────────────────────────────────
        // "A portal is present, but the maze does not connect to it. The necessary route already
        // exists in pieces… the maze route leading toward it terminates against a closed wall at the
        // boundary between the current outer slice and the rest of the world."
        //
        // That boundary is the only thing a turn can change. Measured: the slab is the WHOLE +Z face
        // plus a one-tile ring around it (five tiles on each side face); everything in it rotates
        // together, so within-+Z reachability is untouched by a turn. The 20 places where that ring
        // meets the static shell are the entire editable surface, and a 90° turn slides each ring
        // tile a quarter of the way round — so a doorway that opened onto a dead end now opens onto
        // somewhere else entirely.
        //
        // So: the portal's corner of +Z is walled off from the rest of the face, and its ONE way out
        // is a single ring tile whose along-ring edges are shut. Before the turn that tile's outer
        // door faces a sealed pocket — the route reaching the boundary and stopping, which is what
        // the player is meant to walk up to and read. After the turn the same door faces the live
        // shell, and the world is joined up. Nothing is created; a piece is brought into line.
        let portalCorner = [(0, 0), (0, 1), (1, 0), (1, 1)]
        for (r, cc) in portalCorner {
            // Seal the corner from the REST of +Z (its own four tiles stay open to each other).
            for (dir, dr, dc) in [(SurfaceDirection.north, -1, 0), (.south, 1, 0), (.west, 0, -1), (.east, 0, 1)] {
                let nr = r + dr, nc = cc + dc
                let insideCorner = portalCorner.contains { $0 == (nr, nc) }
                let leavesFace = nr < 0 || nr >= n || nc < 0 || nc >= n
                if insideCorner { setSharedEdge(face: .positiveZ, row: r, col: cc, dir, open: true) }
                else if !leavesFace { setSharedEdge(face: .positiveZ, row: r, col: cc, dir, open: false) }
                else { setSharedEdge(face: .positiveZ, row: r, col: cc, dir, open: false) }
            }
        }
        // The one way out: west from +Z(1,0) onto the ring tile -X(1,4).
        setSharedEdge(face: .positiveZ, row: 1, col: 0, .west, open: true)
        // That ring tile is a doorway, not a corridor: shut along the ring so it cannot be walked
        // around to, and open OUTWARD so the route continues — into a pocket, for now.
        setSharedEdge(face: .negativeX, row: 1, col: 4, .north, open: false)
        setSharedEdge(face: .negativeX, row: 1, col: 4, .south, open: false)
        setSharedEdge(face: .negativeX, row: 1, col: 4, .west, open: true)
        // The pocket it currently opens onto — one tile, sealed on every other side. This is the
        // "closed wall at the boundary" the script asks the player to find.
        for dir in [SurfaceDirection.north, .south, .west] {
            setSharedEdge(face: .negativeX, row: 1, col: 3, dir, open: false)
        }
        // Where that same doorway lands after a 90° turn (measured, not derived): -Y(4,3), opening
        // onto -Y(3,3). Make sure THAT tile is joined to the shell, so the turn completes the route.
        for dir in [SurfaceDirection.north, .south, .west, .east] {
            setSharedEdge(face: .negativeY, row: 3, col: 3, dir, open: true)
        }

        // The vessel stands BESIDE the arrival — "met before anything else" — so guarantee that one
        // step rather than hoping the generated maze provides it.
        setSharedEdge(face: .positiveZ, row: min(n - 1, c + 1), col: c, .north, open: true)

        // Sealing the portal's corner can ORPHAN tiles that only reached the rest of the face
        // THROUGH it — which is exactly what happened: the vessel at the centre of +Z, and the two
        // tiles beside the corner, were cut off along with the portal, so the scene had a puzzle
        // piece the player could not walk to (Eddie: "I don't see how to get to the vessel").
        //
        // Repair afterwards rather than trying to author around it: flood from the spawn and open
        // one edge from any stranded tile back toward reached ground. The portal corner is exempt —
        // being unreachable is its entire job.
        var reached = Set<[Int]>([[min(n - 1, c + 1), c]])
        var frontier = Array(reached)
        while let t = frontier.popLast() {
            guard let (ci, fi) = faceletAt(face: .positiveZ, row: t[0], col: t[1]) else { continue }
            let op = cubies[ci].facelets[fi].mazeTile.openings
            for (mask, dr, dc) in [(DirectionMask.north, -1, 0), (.south, 1, 0), (.west, 0, -1), (.east, 0, 1)]
            where op.contains(mask) {
                let nt = [t[0] + dr, t[1] + dc]
                guard nt[0] >= 0, nt[0] < n, nt[1] >= 0, nt[1] < n, !reached.contains(nt) else { continue }
                reached.insert(nt); frontier.append(nt)
            }
        }
        for r in 0..<n {
            for cc in 0..<n where !reached.contains([r, cc]) && !portalCorner.contains(where: { $0 == (r, cc) }) {
                for (dir, dr, dc) in [(SurfaceDirection.north, -1, 0), (.south, 1, 0), (.west, 0, -1), (.east, 0, 1)] {
                    let nt = [r + dr, cc + dc]
                    guard reached.contains(nt), !portalCorner.contains(where: { $0 == (nt[0], nt[1]) }) else { continue }
                    setSharedEdge(face: .positiveZ, row: r, col: cc, dir, open: true)
                    reached.insert([r, cc])
                    break
                }
            }
        }

        // Arrival, and the gate it cannot yet reach.
        spawnLocation = (face: .positiveZ, row: min(n - 1, c + 1), col: c, facing: .n)
        var portalCubie: Int? = nil
        if let (ci, fi) = faceletAt(face: .positiveZ, row: max(0, c - 1), col: max(0, c - 1)) {
            // → SCENE 5, the pale world. This pointed at temple-interior while Scene 5 did not
            // exist; now the prologue runs 1 → 2 → 3 → 4 → 5 unbroken.
            cubies[ci].facelets[fi].props.append(
                Prop(kind: .portal, subRow: 1, subCol: 1, facing: .s, state: 14, transition: .push))
            styledPortals.append(StyledPortal(ci: ci, fi: fi, facing: .s, fieldStyle: 2))
            cubies[ci].facelets[fi].props.append(Prop(kind: .portalField, subRow: 1, subCol: 1, facing: .s, state: 2))
            // NOT sealed. "A portal is present, but the maze does not connect to it" — the obstacle
            // is the route, not a dark door, and two locks at once would blur the one idea the turn
            // is meant to land. It is lit and alive from the moment the player arrives, and simply
            // cannot be walked to.
            portalCubie = ci
        }

        // The layered vessel (Scene 4D): the object from Scene 1, arranged differently — three major
        // rings whose luminous seams do not align, and which come home one at a time as the anchors
        // release. It reflects the state of the lock, so it can be READ from across the world before
        // the player has any idea what a bond is. Stands beside the arrival, met before anything else.
        if let (ci, fi) = faceletAt(face: .positiveZ, row: c, col: c) {
            var vessel = Prop(kind: .layeredVessel, subRow: 1, subCol: 1, facing: .s)
            vessel.anim = 0                              // rings aligned so far, 0…3
            cubies[ci].facelets[fi].props.append(vessel)
        }

        // THREE ANCHORS, on three different faces, so releasing them circumnavigates the world.
        // Each is a switch (a plate with a recessed control — the same interaction, and it already
        // has the engaged/flush animation), and each anchors one bond.
        let anchorSpots: [(CubeFace, Int, Int)] = [
            (.negativeZ, c, c),          // directly opposite: the far side
            (.positiveY, c, c),          // over the top edge
            (.negativeY, c, c),          // and under the bottom
        ]
        guard let pc = portalCubie else { return }
        for (i, spot) in anchorSpots.enumerated() {
            guard let (ci, fi) = faceletAt(face: spot.0, row: spot.1, col: spot.2) else { continue }
            cubies[ci].facelets[fi].tileState = .discovered
            cubies[ci].facelets[fi].discoveryAmount = 1.0
            cubies[ci].facelets[fi].props.append(Prop(kind: .switchBase, subRow: 1, subCol: 1, facing: .n))
            var plate = Prop(kind: .anchor, subRow: 1, subCol: 1, facing: .n, state: i + 1)
            plate.anim = 1                          // 1 = still holding its bond; 0 = released
            cubies[ci].facelets[fi].props.append(plate)
            // One bond per anchor, straddling the twistable slab: the portal's cubie is inside it,
            // the anchor's is outside, so `canRotateSlice` refuses while ANY of the three remain.
            addBond([pc, ci])
        }
    }

}
