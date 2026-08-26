import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// The Mazen icon: the maze planet from the attract screen, seen against its own sky.
//
// Drawn rather than painted, so it can be re-rendered at any size and tweaked by numbers. The maze
// is generated flat and then mapped onto the disc with a radial expansion that mimics an
// orthographic sphere — detail crowds toward the rim exactly as it does on the real planet.

let S = 1024                       // master size; everything else is a downscale

enum Style { case light, dark, tinted }

/// A REAL maze, carved with a depth-first backtracker, then drawn as hedge LINES rather than filled
/// cells. The first attempt filled cells at random and read as camouflage — a maze is corridors, and
/// corridors are the gaps between thin walls.
func mazeBitmap(size: Int, style: Style) -> [UInt8] {
    let n = 14                                  // cells across; few enough to read at 60 px
    var rng: UInt64 = 0x9E3779B97F4A7C15
    func next() -> Int { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Int(rng % 0x7FFF_FFFF) }

    // wallsV[c][r] = wall on the LEFT edge of cell (r,c); wallsH[r][c] = wall on the TOP edge.
    var wallsV = [[Bool]](repeating: [Bool](repeating: true, count: n), count: n + 1)
    var wallsH = [[Bool]](repeating: [Bool](repeating: true, count: n + 1), count: n)
    var seen = [[Bool]](repeating: [Bool](repeating: false, count: n), count: n)
    var stack = [(0, 0)]
    seen[0][0] = true
    while let (r, c) = stack.last {
        var options: [(Int, Int)] = []
        if r > 0, !seen[r-1][c] { options.append((r-1, c)) }
        if r < n-1, !seen[r+1][c] { options.append((r+1, c)) }
        if c > 0, !seen[r][c-1] { options.append((r, c-1)) }
        if c < n-1, !seen[r][c+1] { options.append((r, c+1)) }
        guard !options.isEmpty else { stack.removeLast(); continue }
        let (nr, nc) = options[next() % options.count]
        if nr == r { wallsV[max(c, nc)][r] = false } else { wallsH[max(r, nr)][c] = false }
        seen[nr][nc] = true
        stack.append((nr, nc))
    }
    // Braid it a little: knock out a few more walls so the maze has loops and does not read as a
    // tree of dead ends at a glance.
    for _ in 0..<(n * 2) {
        let r = next() % n, c = next() % n
        if next() % 2 == 0 { if c > 0 { wallsV[c][r] = false } } else { if r > 0 { wallsH[r][c] = false } }
    }

    let field: CGColor, hedge: CGColor
    switch style {
    case .light:  field = CGColor(red: 0.44, green: 0.57, blue: 0.29, alpha: 1)
                  hedge = CGColor(red: 0.13, green: 0.21, blue: 0.13, alpha: 1)
    case .dark:   field = CGColor(red: 0.22, green: 0.31, blue: 0.17, alpha: 1)
                  hedge = CGColor(red: 0.05, green: 0.09, blue: 0.06, alpha: 1)
    case .tinted: field = CGColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1)
                  hedge = CGColor(red: 0.22, green: 0.22, blue: 0.22, alpha: 1)
    }

    var px = [UInt8](repeating: 0, count: size * size * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return px }
    ctx.setFillColor(field)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let cell = Double(size) / Double(n)
    ctx.setStrokeColor(hedge)
    ctx.setLineWidth(cell * 0.22)               // hedges, not hairlines
    ctx.setLineCap(.round)
    for r in 0..<n {
        for c in 0...n where c < wallsV.count && wallsV[c][r] {
            ctx.move(to: CGPoint(x: Double(c) * cell, y: Double(r) * cell))
            ctx.addLine(to: CGPoint(x: Double(c) * cell, y: Double(r + 1) * cell))
        }
    }
    for r in 0..<n {
        for c in 0..<n where wallsH[r][c] {
            ctx.move(to: CGPoint(x: Double(c) * cell, y: Double(r) * cell))
            ctx.addLine(to: CGPoint(x: Double(c + 1) * cell, y: Double(r) * cell))
        }
    }
    ctx.strokePath()
    return px
}

func renderIcon(style: Style) -> CGImage? {
    let size = S
    let src = mazeBitmap(size: size, style: style)
    var out = [UInt8](repeating: 0, count: size * size * 4)

    // Sky, and the planet's radius within the square. 0.40 leaves the breathing room an icon wants —
    // a shape that touches the edges looks bigger but reads as clutter on a home screen.
    let R = Double(size) * 0.40
    let cxp = Double(size) * 0.5, cyp = Double(size) * 0.5

    let skyTop: (Double, Double, Double)
    let skyBottom: (Double, Double, Double)
    switch style {
    case .light:  skyTop = (0.80, 0.86, 0.93); skyBottom = (0.64, 0.75, 0.87)
    case .dark:   skyTop = (0.05, 0.07, 0.12); skyBottom = (0.02, 0.03, 0.06)
    case .tinted: skyTop = (0.0, 0.0, 0.0);    skyBottom = (0.0, 0.0, 0.0)
    }

    // Light from the upper right, matching the attract screen's low sun.
    let lx = 0.48, ly = -0.55, lz = 0.68
    let ll = (lx * lx + ly * ly + lz * lz).squareRoot()
    let L = (lx / ll, ly / ll, lz / ll)

    for y in 0..<size {
        for x in 0..<size {
            let i = (y * size + x) * 4
            let t = Double(y) / Double(size - 1)
            var r = skyTop.0 + (skyBottom.0 - skyTop.0) * t
            var g = skyTop.1 + (skyBottom.1 - skyTop.1) * t
            var b = skyTop.2 + (skyBottom.2 - skyTop.2) * t
            var a = 1.0

            // A warm bloom where the sun sits, off the planet's shoulder.
            if style != .tinted {
                let sx = Double(x) - Double(size) * 0.74, sy = Double(y) - Double(size) * 0.20
                let sd = (sx * sx + sy * sy).squareRoot() / (Double(size) * 0.55)
                let glow = max(0, 1 - sd) * (style == .light ? 0.35 : 0.12)
                r += glow * 0.9; g += glow * 0.7; b += glow * 0.5
            }
            if style == .tinted { a = 0 }   // tinted icons are a mask: only the planet is drawn

            // The planet.
            let dx = (Double(x) - cxp) / R, dy = (Double(y) - cyp) / R
            let rad = (dx * dx + dy * dy).squareRoot()
            if rad <= 1.0 {
                // Orthographic-ish remap: push the flat maze outward so detail crowds the rim.
                let k = rad > 1e-6 ? (asin(min(1, rad)) / (Double.pi / 2)) / rad : 1
                let su = (dx * k * 0.5 + 0.5), sv = (dy * k * 0.5 + 0.5)
                let sx = min(size - 1, max(0, Int(su * Double(size))))
                let sy = min(size - 1, max(0, Int(sv * Double(size))))
                let j = (sy * size + sx) * 4
                var pr = Double(src[j]) / 255, pg = Double(src[j + 1]) / 255, pb = Double(src[j + 2]) / 255

                // Sphere shading.
                let nz = (max(0, 1 - rad * rad)).squareRoot()
                let ndl = max(0, dx * L.0 + dy * L.1 + nz * L.2)
                let shade = 0.30 + 0.85 * ndl
                pr *= shade; pg *= shade; pb *= shade

                // A cool rim light so the silhouette separates from the sky.
                let rim = pow(max(0, rad - 0.82) / 0.18, 1.5) * 0.35
                pr += rim * 0.55; pg += rim * 0.68; pb += rim * 0.85

                // Antialias the edge.
                let edge = min(1.0, (1.0 - rad) * Double(size) * 0.02)
                r = r * (1 - edge) + pr * edge
                g = g * (1 - edge) + pg * edge
                b = b * (1 - edge) + pb * edge
                a = max(a, edge)
            }

            out[i]     = UInt8(max(0, min(255, r * 255)))
            out[i + 1] = UInt8(max(0, min(255, g * 255)))
            out[i + 2] = UInt8(max(0, min(255, b * 255)))
            out[i + 3] = UInt8(max(0, min(255, a * 255)))
        }
    }

    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &out, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    return ctx.makeImage()
}

func write(_ img: CGImage, to path: String, size: Int) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let scaled = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, scaled, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path) @\(size)")
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for (style, name) in [(Style.light, "icon"), (Style.dark, "icon-dark"), (Style.tinted, "icon-tinted")] {
    guard let img = renderIcon(style: style) else { continue }
    write(img, to: "\(outDir)/\(name)-1024.png", size: 1024)
    if style == .light {
        for s in [512, 256, 128, 64, 32, 16] { write(img, to: "\(outDir)/\(name)-\(s).png", size: s) }
    }
}
