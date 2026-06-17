import simd

struct PlayerState {
    var face: CubeFace = .positiveZ
    var row: Int
    var col: Int
    var facing: SurfaceDirection = .north

    var isMoving = false
    var moveProgress: Float = 0
    var moveSpeed: Float = 2.5
    var moveFromFace: CubeFace = .positiveZ
    var moveFromRow: Int = 0
    var moveFromCol: Int = 0
    var moveToFace: CubeFace = .positiveZ
    var moveToRow: Int = 0
    var moveToCol: Int = 0
    var moveNewFacing: SurfaceDirection = .north

    var isTurning = false
    var turnProgress: Float = 0
    var turnSpeed: Float = 5.0
    var turnFromFacing: SurfaceDirection = .north
    var turnToFacing: SurfaceDirection = .north

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
            let crossedFace = moveFromFace != moveToFace
            face = moveToFace
            row = moveToRow
            col = moveToCol
            facing = moveNewFacing
            print("Arrived: \(face) (\(row),\(col)) facing \(facing)\(crossedFace ? " [CROSSED EDGE]" : "")")
            return true
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
        guard !isMoving && !isTurning else { return }
        guard let (ci, fi) = cubeModel.faceletAt(face: face, row: row, col: col) else {
            print("No facelet at \(face) (\(row),\(col))")
            return
        }
        let tile = cubeModel.cubies[ci].facelets[fi]
        print("Move: at \(face) (\(row),\(col)) facing \(facing), openings=\(tile.mazeTile.openings.rawValue)")

        guard tile.mazeTile.openings.contains(direction: facing) else {
            print("  Blocked — no opening \(facing)")
            return
        }

        let (dr, dc) = Self.deltaForDirection(facing)
        let newRow = row + dr
        let newCol = col + dc

        if newRow >= 0 && newRow < cubeModel.size && newCol >= 0 && newCol < cubeModel.size {
            if let (tci, tfi) = cubeModel.faceletAt(face: face, row: newRow, col: newCol) {
                let targetTile = cubeModel.cubies[tci].facelets[tfi]
                guard targetTile.mazeTile.openings.contains(direction: facing.opposite) else { return }
            }

            moveFromFace = face
            moveFromRow = row
            moveFromCol = col
            moveToFace = face
            moveToRow = newRow
            moveToCol = newCol
            moveNewFacing = facing
            moveProgress = 0
            isMoving = true
        } else {
            let crossing = cubeModel.edgeCrossing(face: face, direction: facing, row: row, col: col)
            let arrivalDir = crossing.facing.opposite
            if let (tci, tfi) = cubeModel.faceletAt(face: crossing.face, row: crossing.row, col: crossing.col) {
                let targetTile = cubeModel.cubies[tci].facelets[tfi]
                guard targetTile.mazeTile.openings.contains(direction: arrivalDir) else { return }
            } else {
                return
            }

            moveFromFace = face
            moveFromRow = row
            moveFromCol = col
            moveToFace = crossing.face
            moveToRow = crossing.row
            moveToCol = crossing.col
            moveNewFacing = crossing.facing
            moveProgress = 0
            isMoving = true
            print("Edge crossing: \(face) (\(row),\(col)) -> \(crossing.face) (\(crossing.row),\(crossing.col)) facing \(crossing.facing)")
        }
    }

    mutating func tryTurnLeft() {
        guard !isMoving && !isTurning else { return }
        turnFromFacing = facing
        turnToFacing = Self.turnLeft(facing)
        turnProgress = 0
        isTurning = true
    }

    mutating func tryTurnRight() {
        guard !isMoving && !isTurning else { return }
        turnFromFacing = facing
        turnToFacing = Self.turnRight(facing)
        turnProgress = 0
        isTurning = true
    }

    mutating func tryMoveBackward(cubeModel: CubeModel) {
        guard !isMoving && !isTurning else { return }
        let backDir = facing.opposite
        guard let (ci, fi) = cubeModel.faceletAt(face: face, row: row, col: col) else { return }
        let tile = cubeModel.cubies[ci].facelets[fi]
        guard tile.mazeTile.openings.contains(direction: backDir) else { return }

        let (dr, dc) = Self.deltaForDirection(backDir)
        let newRow = row + dr
        let newCol = col + dc

        if newRow >= 0 && newRow < cubeModel.size && newCol >= 0 && newCol < cubeModel.size {
            if let (tci, tfi) = cubeModel.faceletAt(face: face, row: newRow, col: newCol) {
                let targetTile = cubeModel.cubies[tci].facelets[tfi]
                guard targetTile.mazeTile.openings.contains(direction: backDir.opposite) else { return }
            }

            moveFromFace = face
            moveFromRow = row
            moveFromCol = col
            moveToFace = face
            moveToRow = newRow
            moveToCol = newCol
            moveNewFacing = facing
            moveProgress = 0
            isMoving = true
        } else {
            let crossing = cubeModel.edgeCrossing(face: face, direction: backDir, row: row, col: col)
            let arrivalDir = crossing.facing.opposite
            if let (tci, tfi) = cubeModel.faceletAt(face: crossing.face, row: crossing.row, col: crossing.col) {
                let targetTile = cubeModel.cubies[tci].facelets[tfi]
                guard targetTile.mazeTile.openings.contains(direction: arrivalDir) else { return }
            } else {
                return
            }

            moveFromFace = face
            moveFromRow = row
            moveFromCol = col
            moveToFace = crossing.face
            moveToRow = crossing.row
            moveToCol = crossing.col
            moveNewFacing = crossing.facing.opposite
            moveProgress = 0
            isMoving = true
        }
    }

    // MARK: - Direction helpers

    static func deltaForDirection(_ dir: SurfaceDirection) -> (Int, Int) {
        switch dir {
        case .north: return (-1, 0)
        case .south: return (1, 0)
        case .east:  return (0, 1)
        case .west:  return (0, -1)
        }
    }

    static func turnLeft(_ dir: SurfaceDirection) -> SurfaceDirection {
        switch dir {
        case .north: return .east
        case .east:  return .south
        case .south: return .west
        case .west:  return .north
        }
    }

    static func turnRight(_ dir: SurfaceDirection) -> SurfaceDirection {
        switch dir {
        case .north: return .west
        case .west:  return .south
        case .south: return .east
        case .east:  return .north
        }
    }
}
