import simd
import Foundation

struct PlayerState {
    var face: CubeFace = .positiveZ
    var row: Int
    var col: Int
    // Sub-cell standing spot within the tile's 3×3 grid (M10 Phase D). Path cells only.
    var subRow: Int = 1
    var subCol: Int = 1
    var facing: Heading8 = .n

    var isMoving = false
    var moveProgress: Float = 0
    // Progress-per-second across one hop → time per hop = 1/moveSpeed. A hop is one
    // sub-cell (a third of a tile) since M10 Phase D, so ~2.5 (0.4s/hop) keeps roughly
    // the ~1.2s-per-tile pace Phase A dialed in. Tune to taste.
    var moveSpeed: Float = 2.5
    var moveFromFace: CubeFace = .positiveZ
    var moveFromRow: Int = 0
    var moveFromCol: Int = 0
    var moveFromSubRow: Int = 1
    var moveFromSubCol: Int = 1
    var moveToFace: CubeFace = .positiveZ
    var moveToRow: Int = 0
    var moveToCol: Int = 0
    var moveToSubRow: Int = 1
    var moveToSubCol: Int = 1
    var moveNewFacing: Heading8 = .n

    var isTurning = false
    var turnProgress: Float = 0
    var turnSpeed: Float = 6.0
    var turnFromFacing: Heading8 = .n
    var turnToFacing: Heading8 = .n

    init(size: Int) {
        row = size / 2
        col = size / 2
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
            if crossedTile {
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

    /// Attempt a one-hop move in `travel` direction. Within a tile the hop is between
    /// path cells; off a tile edge it crosses a gateway to the neighbor's opposite
    /// edge-middle cell. `arrivalFacing` maps the post-crossing travel heading to the
    /// facing the player ends up with (identity for forward, opposite for backward).
    private mutating func startMove(travel: Heading8, arrivalFacing: (Heading8) -> Heading8, cubeModel: CubeModel) {
        guard !isMoving && !isTurning else { return }
        guard let (ci, fi) = cubeModel.faceletAt(face: face, row: row, col: col) else { return }
        let tile = cubeModel.cubies[ci].facelets[fi].mazeTile

        let (dr, dc) = travel.subDelta
        let tr = subRow + dr, tc = subCol + dc

        if (0...2).contains(tr) && (0...2).contains(tc) {
            // Within-tile hop — target must be a path cell. (Phase G will also reject a
            // diagonal whose flanking cell is occupied by a prop.)
            guard tile.isPathCell(tr, tc) else { return }
            beginMove(toFace: face, toRow: row, toCol: col, toSub: (tr, tc), newFacing: facing)
            return
        }

        // Exiting the tile: only a cardinal move from that edge's middle cell, through
        // an open gateway, may cross.
        guard let dir = travel.cardinal else { return }
        guard (subRow, subCol) == Self.edgeMiddle(dir) else { return }
        guard tile.openings.contains(direction: dir) else { return }

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
        let arrTile = cubeModel.cubies[nci].facelets[nfi].mazeTile
        let entryDir = arrDir.opposite
        guard arrTile.openings.contains(direction: entryDir) else { return }

        let crossHeading = Heading8.from(surfaceDirection: arrDir)
        beginMove(toFace: arrFace, toRow: arrRow, toCol: arrCol,
                  toSub: Self.edgeMiddle(entryDir), newFacing: arrivalFacing(crossHeading))
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

    /// The middle sub-cell of an edge (the sub-cell a gateway opens through).
    static func edgeMiddle(_ dir: SurfaceDirection) -> (Int, Int) {
        switch dir {
        case .north: return (0, 1)
        case .south: return (2, 1)
        case .east:  return (1, 2)
        case .west:  return (1, 0)
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
