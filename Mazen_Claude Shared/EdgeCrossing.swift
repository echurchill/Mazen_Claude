import simd

struct EdgeCrossing {
    static func cross(face: CubeFace, direction: SurfaceDirection, row: Int, col: Int, cubeSize: Int) -> (face: CubeFace, row: Int, col: Int, facing: SurfaceDirection) {
        let n = cubeSize - 1
        switch (face, direction) {
        case (.positiveZ, .north): return (.negativeY,     n,   col, .north)
        case (.positiveZ, .south): return (.positiveY,     0,   col, .south)
        case (.positiveZ, .east):  return (.positiveX,   row,     0, .east)
        case (.positiveZ, .west):  return (.negativeX,   row,     n, .west)

        case (.negativeZ, .north): return (.negativeY,     0, n-col, .south)
        case (.negativeZ, .south): return (.positiveY,     n, n-col, .north)
        case (.negativeZ, .east):  return (.negativeX,   row,     0, .east)
        case (.negativeZ, .west):  return (.positiveX,   row,     n, .west)

        case (.positiveX, .north): return (.negativeY, n-col,     n, .west)
        case (.positiveX, .south): return (.positiveY,   col,     n, .west)
        case (.positiveX, .east):  return (.negativeZ,   row,     0, .east)
        case (.positiveX, .west):  return (.positiveZ,   row,     n, .west)

        case (.negativeX, .north): return (.negativeY,   col,     0, .east)
        case (.negativeX, .south): return (.positiveY, n-col,     0, .east)
        case (.negativeX, .east):  return (.positiveZ,   row,     0, .east)
        case (.negativeX, .west):  return (.negativeZ,   row,     n, .west)

        case (.positiveY, .north): return (.positiveZ,     n,   col, .north)
        case (.positiveY, .south): return (.negativeZ,     n, n-col, .north)
        case (.positiveY, .east):  return (.positiveX,     n,   row, .north)
        case (.positiveY, .west):  return (.negativeX,     n, n-row, .north)

        case (.negativeY, .north): return (.negativeZ,     0, n-col, .south)
        case (.negativeY, .south): return (.positiveZ,     0,   col, .south)
        case (.negativeY, .east):  return (.positiveX,     0, n-row, .south)
        case (.negativeY, .west):  return (.negativeX,     0,   row, .south)
        }
    }
}
