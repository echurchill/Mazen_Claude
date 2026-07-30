import simd
import Foundation

struct PlayerState {
    var face: CubeFace = .positiveZ
    var row: Int
    var col: Int
    /// The stand grid's density (M18 Phase 0) — from `WorldScale.standGrid`. Standing
    /// spots run 0..<standGrid per axis; `standCenter` is the tile-centre cell.
    let standGrid: Int
    var standCenter: Int { standGrid / 2 }
    // Stand-cell standing spot within the tile's d×d grid (M10 Phase D, densified M18).
    // Path cells only (until M18 Phase 1 opens the grass).
    var subRow: Int
    var subCol: Int
    var facing: Heading8 = .n

    var isMoving = false
    var moveProgress: Float = 0
    // Progress-per-second across one hop → time per hop = 1/moveSpeed. A hop is one
    // stand cell; the init scales this with the stand grid so the per-TILE pace stays
    // the ~1.2s M10 Phase A dialed in, whatever the density. Tune the 2.5 to taste.
    var moveSpeed: Float = 2.5
    var moveFromFace: CubeFace = .positiveZ
    var moveFromRow: Int = 0
    var moveFromCol: Int = 0
    var moveFromSubRow: Int
    var moveFromSubCol: Int
    var moveToFace: CubeFace = .positiveZ
    var moveToRow: Int = 0
    var moveToCol: Int = 0
    var moveToSubRow: Int
    var moveToSubCol: Int
    var moveNewFacing: Heading8 = .n

    var isTurning = false
    var turnProgress: Float = 0
    var turnSpeed: Float = 6.0
    var turnFromFacing: Heading8 = .n
    var turnToFacing: Heading8 = .n

    init(size: Int, standGrid: Int = 9) {
        self.standGrid = standGrid
        row = size / 2
        col = size / 2
        let c = standGrid / 2
        subRow = c; subCol = c
        moveFromSubRow = c; moveFromSubCol = c
        moveToSubRow = c; moveToSubCol = c
        moveSpeed = 2.5 * Float(standGrid) / 3.0
    }

    // MARK: - Update

    mutating func updateMovement(deltaTime: Float) -> Bool {
        guard isMoving else { return false }
        moveProgress += deltaTime * moveSpeed
        if moveProgress >= 1.0 {
            moveProgress = 1.0
            isMoving = false
            let crossedTile = moveFromFace != moveToFace || moveFromRow != moveToRow || moveFromCol != moveToCol
            face = moveToFace
            row = moveToRow
            col = moveToCol
            subRow = moveToSubRow
            subCol = moveToSubCol
            facing = moveNewFacing
            if crossedTile && verboseDebugLog {
                NSLog("Arrived tile: %@ (%d,%d) sub(%d,%d) facing %@", "\(face)", row, col, subRow, subCol, "\(facing)")
            }
            return crossedTile
        }
        return false
    }

    mutating func updateTurn(deltaTime: Float) {
        guard isTurning else { return }
        turnProgress += deltaTime * turnSpeed
        if turnProgress >= 1.0 {
            turnProgress = 1.0
            isTurning = false
            facing = turnToFacing
        }
    }

    // MARK: - Movement commands

    mutating func tryMoveForward(cubeModel: CubeModel) {
        startMove(travel: facing, arrivalFacing: { $0 }, cubeModel: cubeModel)
    }

    mutating func tryMoveBackward(cubeModel: CubeModel) {
        startMove(travel: facing.opposite, arrivalFacing: { $0.opposite }, cubeModel: cubeModel)
    }

    mutating func tryTurnLeft() {
        guard !isMoving && !isTurning else { return }
        turnFromFacing = facing
        turnToFacing = facing.turned(steps: 1)
        turnProgress = 0
        isTurning = true
    }

    mutating func tryTurnRight() {
        guard !isMoving && !isTurning else { return }
        turnFromFacing = facing
        turnToFacing = facing.turned(steps: -1)
        turnProgress = 0
        isTurning = true
    }

    // MARK: - Movement core

    /// Attempt a one-hop move in `travel` direction. Within a tile any standable cell is a
    /// destination (M18 Phase 1: grass is walkable; walls claim their border cells). Off a
    /// tile edge, the hop crosses wherever the edge geometry has a gap — from ANY border
    /// cell, preserving the lateral position across the seam (a straight walk stays
    /// straight), including diagonal exits (decomposed as a cardinal crossing with the
    /// lateral shift applied). `arrivalFacing` maps the post-crossing travel heading to the
    /// facing the player ends up with (identity for forward, opposite for backward).
    private mutating func startMove(travel: Heading8, arrivalFacing: (Heading8) -> Heading8, cubeModel: CubeModel) {
        guard !isMoving && !isTurning else { return }
        guard let (ci, fi) = cubeModel.faceletAt(face: face, row: row, col: col) else { return }
        let tile = cubeModel.cubies[ci].facelets[fi].mazeTile
        let props = cubeModel.cubies[ci].facelets[fi].props

        let d = standGrid
        let (dr, dc) = travel.subDelta
        let tr = subRow + dr, tc = subCol + dc

        if (0..<d).contains(tr) && (0..<d).contains(tc) {
            // Within-tile hop — target must be standable (grass minus walls) and clear of
            // any solid prop's footprint (M18 Phase 2 — stand-point removal).
            guard tile.isStandable(tr, tc, grid: d, fullWidthGateways: cubeModel.fullWidthGateways) else { return }
            guard !props.contains(where: { $0.blocks(tr, tc, grid: d, standStep: cubeModel.worldScale.standStep) }) else { return }
            beginMove(toFace: face, toRow: row, toCol: col, toSub: (tr, tc), newFacing: facing)
            return
        }

        // Exiting the tile. Exactly one axis may leave the grid — a corner-to-corner
        // diagonal (both out) would cross two edges at once; step around it.
        let rowOut = !(0..<d).contains(tr), colOut = !(0..<d).contains(tc)
        guard rowOut != colOut else { return }
        let dir: SurfaceDirection = rowOut ? (tr < 0 ? .north : .south)
                                           : (tc < 0 ? .west : .east)
        // Lateral index on the departure edge — with a diagonal's sideways shift applied,
        // so a NE walk exits the north edge one cell east of where it stood.
        let depLat = rowOut ? tc : tr
        guard (0..<d).contains(depLat) else { return }
        guard tile.edgeAllows(dir, lateral: depLat, grid: d, fullWidthGateways: cubeModel.fullWidthGateways) else { return }

        let n = cubeModel.size
        let (tdr, tdc) = Self.deltaForDirection(dir)
        let nRow = row + tdr, nCol = col + tdc

        let arrFace: CubeFace, arrRow: Int, arrCol: Int, arrDir: SurfaceDirection
        if (0..<n).contains(nRow) && (0..<n).contains(nCol) {
            arrFace = face; arrRow = nRow; arrCol = nCol; arrDir = dir
        } else {
            let cr = cubeModel.edgeCrossing(face: face, direction: dir, row: row, col: col)
            arrFace = cr.face; arrRow = cr.row; arrCol = cr.col; arrDir = cr.facing
        }

        guard let (nci, nfi) = cubeModel.faceletAt(face: arrFace, row: arrRow, col: arrCol) else { return }
        // M19: water is not walkable — you follow the shore around it.
        guard cubeModel.cubies[nci].facelets[nfi].terrain != .water else { return }
        let arrTile = cubeModel.cubies[nci].facelets[nfi].mazeTile
        let arrProps = cubeModel.cubies[nci].facelets[nfi].props
        let entryDir = arrDir.opposite

        // Carry the lateral position across the seam. Same-face crossings keep it verbatim;
        // cube-edge crossings ask the crossing itself which way the lateral axis runs on the
        // far side (probe a laterally adjacent departure tile — same trick as the twist's
        // sub-cell remap, but sourced from EdgeCrossing so exterior AND interior conjugation
        // are automatically consistent).
        let c = standCenter
        let sign = (arrFace == face && arrDir == dir)
            ? 1
            : Self.lateralSign(cubeModel: cubeModel, face: face, dir: dir, row: row, col: col)
        let arrLat = c + sign * (depLat - c)
        let toSub: (Int, Int)
        switch entryDir {
        case .north: toSub = (0, arrLat)
        case .south: toSub = (d - 1, arrLat)
        case .west:  toSub = (arrLat, 0)
        case .east:  toSub = (arrLat, d - 1)
        }
        guard arrTile.isStandable(toSub.0, toSub.1, grid: d, fullWidthGateways: cubeModel.fullWidthGateways) else { return }
        guard !arrProps.contains(where: { $0.blocks(toSub.0, toSub.1, grid: d, standStep: cubeModel.worldScale.standStep) }) else { return }

        // Rotate the travel heading by however much the crossing rotated the surface frame
        // (same-face: not at all — a diagonal walk stays diagonal), then let arrivalFacing
        // keep forward forward and backward backward.
        let depHeading = Heading8.from(surfaceDirection: dir)
        let arrHeading = Heading8.from(surfaceDirection: arrDir)
        let turned = Heading8(rawValue: (travel.rawValue + arrHeading.rawValue - depHeading.rawValue + 8) % 8) ?? arrHeading
        beginMove(toFace: arrFace, toRow: arrRow, toCol: arrCol,
                  toSub: toSub, newFacing: arrivalFacing(turned))
    }

    /// Which way the lateral (along-edge) axis runs after a cube-edge crossing: +1 if the
    /// arrival lateral coordinate grows with the departure one, −1 if it mirrors. Probed by
    /// crossing from a laterally adjacent tile on the same edge and comparing arrivals —
    /// EdgeCrossing is the single source of truth, so interiors' conjugated crossings come
    /// out right for free.
    static func lateralSign(cubeModel: CubeModel, face: CubeFace, dir: SurfaceDirection, row: Int, col: Int) -> Int {
        let n = cubeModel.size
        let alongCol = (dir == .north || dir == .south)   // lateral tile axis for this edge
        let delta: Int
        if alongCol { delta = col + 1 < n ? 1 : -1 } else { delta = row + 1 < n ? 1 : -1 }
        let r2 = alongCol ? row : row + delta
        let c2 = alongCol ? col + delta : col
        let a = cubeModel.edgeCrossing(face: face, direction: dir, row: row, col: col)
        let b = cubeModel.edgeCrossing(face: face, direction: dir, row: r2, col: c2)
        let arrAlongCol = (a.facing == .north || a.facing == .south)
        let arrDelta = arrAlongCol ? (b.col - a.col) : (b.row - a.row)
        return arrDelta == delta ? 1 : -1
    }

    private mutating func beginMove(toFace: CubeFace, toRow: Int, toCol: Int, toSub: (Int, Int), newFacing: Heading8) {
        moveFromFace = face; moveFromRow = row; moveFromCol = col
        moveFromSubRow = subRow; moveFromSubCol = subCol
        moveToFace = toFace; moveToRow = toRow; moveToCol = toCol
        moveToSubRow = toSub.0; moveToSubCol = toSub.1
        moveNewFacing = newFacing
        moveProgress = 0
        isMoving = true
    }

    // MARK: - Direction helpers

    /// The middle stand cell of an edge (the cell a gateway opens through).
    func edgeMiddle(_ dir: SurfaceDirection) -> (Int, Int) {
        let c = standCenter
        switch dir {
        case .north: return (0, c)
        case .south: return (standGrid - 1, c)
        case .east:  return (c, standGrid - 1)
        case .west:  return (c, 0)
        }
    }

    /// Tile-grid step (row, col) for a surface direction.
    static func deltaForDirection(_ dir: SurfaceDirection) -> (Int, Int) {
        switch dir {
        case .north: return (-1, 0)
        case .south: return (1, 0)
        case .east:  return (0, 1)
        case .west:  return (0, -1)
        }
    }
}
