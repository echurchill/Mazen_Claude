import Foundation
import Metal
import ImageIO
import CoreGraphics

/// Bundle- and file-based `MTLTexture` loading (R2.8 — extracted verbatim from Renderer, which
/// had grown three texture decoders alongside the frame loop; logic unchanged).
enum TextureLoader {

    /// A 2D-array texture from bundled 512×512 PNGs (the maze's diffuse / normal-map stacks).
    static func loadTextureArray(device: MTLDevice, names: [String], srgb: Bool) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = srgb ? .rgba8Unorm_srgb : .rgba8Unorm
        desc.width = 512
        desc.height = 512
        desc.arrayLength = names.count
        desc.storageMode = .shared
        desc.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = srgb ? "DiffuseArray" : "NormalArray"

        let bytesPerRow = 512 * 4
        let bytesPerImage = bytesPerRow * 512
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        for (i, name) in names.enumerated() {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
                NSLog("Texture not found: %@.png", name)
                continue
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                NSLog("Failed to decode: %@.png", name)
                continue
            }

            var pixels = [UInt8](repeating: 255, count: bytesPerImage)
            guard let ctx = CGContext(data: &pixels,
                                     width: 512, height: 512,
                                     bitsPerComponent: 8,
                                     bytesPerRow: bytesPerRow,
                                     space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                continue
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 512, height: 512))

            let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                   size: MTLSize(width: 512, height: 512, depth: 1))
            texture.replace(region: region, mipmapLevel: 0, slice: i,
                           withBytes: pixels, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerImage)
        }

        return texture
    }

    /// A plain 2D texture from a bundled PNG (the skybox).
    static func loadTexture2D(device: MTLDevice, name: String, srgb: Bool) -> MTLTexture? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            NSLog("Texture not found: %@.png", name)
            return nil
        }

        let w = cgImage.width
        let h = cgImage.height
        let bytesPerRow = w * 4
        let bytesPerImage = bytesPerRow * h

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm,
            width: w, height: h, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = name

        var pixels = [UInt8](repeating: 255, count: bytesPerImage)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels,
                                 width: w, height: h,
                                 bitsPerComponent: 8,
                                 bytesPerRow: bytesPerRow,
                                 space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: w, height: h, depth: 1))
        texture.replace(region: region, mipmapLevel: 0,
                       withBytes: pixels, bytesPerRow: bytesPerRow)

        return texture
    }

    /// M12: load a texture from an arbitrary file URL (imported model textures live outside
    /// the bundle). CGImageSource decodes JPG/PNG all the same.
    static func loadTextureFromFile(url: URL, device: MTLDevice, srgb: Bool) -> MTLTexture? {
        guard let (pixels, w, h) = decodeRGBA(url) else { return nil }
        return makeTexture(device: device, srgb: srgb, pixels: pixels, w: w, h: h, label: url.lastPathComponent)
    }

    /// M20: the loader for imported-asset textures — decodes ONCE, detects whether the alpha
    /// channel is genuinely used (any texel below the 0.5 cutout threshold), and if so prepares the
    /// pixels for alpha-testing:
    ///  1. UN-PREMULTIPLIES. CoreGraphics only offers premultiplied 8-bit RGBA, but the shader
    ///     reads `.rgb` as a straight colour, so premultiplied texels would darken toward the edges.
    ///  2. DILATES the colour outward under the transparent texels. Quaternius' leaf PNGs store pure
    ///     WHITE beneath alpha 0; the bilinear filter blends across the alpha boundary, so any edge
    ///     texel that survives the cutout would drag that white in as a fringe. Bleeding the leaf
    ///     colour outward means the filter only ever mixes leaf with leaf.
    /// (Detection used to be a separate full decode of the same PNG — merged here for boot time.)
    static func loadAssetTexture(url: URL, device: MTLDevice, srgb: Bool) -> (texture: MTLTexture, cutout: Bool)? {
        // Decode + cutout prep never changes for a given source file, so the processed RGBA is
        // cached as a sidecar blob (keyed on the source's mtime+size): every boot after the first
        // is a plain read + GPU upload instead of PNG decode + un-premultiply + dilate.
        if let (pixels, w, h, cutout) = readPixelCache(url),
           let tex = makeTexture(device: device, srgb: srgb, pixels: pixels, w: w, h: h, label: url.lastPathComponent) {
            return (tex, cutout)
        }
        guard var (pixels, w, h) = decodeRGBA(url) else { return nil }
        // Same criterion the shader's discard uses: any texel below half-alpha.
        let cutout = pixels.withUnsafeBufferPointer { buf -> Bool in
            let p = buf.baseAddress!
            for i in stride(from: 3, to: buf.count, by: 4) where p[i] < 128 { return true }
            return false
        }
        if cutout { unpremultiplyAndDilate(&pixels, width: w, height: h) }
        writePixelCache(url, pixels: pixels, w: w, h: h, cutout: cutout)
        guard let tex = makeTexture(device: device, srgb: srgb, pixels: pixels, w: w, h: h, label: url.lastPathComponent) else { return nil }
        return (tex, cutout)
    }

    // ── Processed-pixel sidecar cache ────────────────────────────
    // Format: 6 little-endian Int64s (magic, version, width, height, cutoutFlag, sourceKey)
    // followed by the raw RGBA bytes. `sourceKey` folds the source file's mtime + size, so a
    // re-exported texture invalidates its cache automatically. Lives in a `.rgba-cache` dir next
    // to the textures (inside the gitignored pack). Any read failure ⇒ full pipeline, never a crash.
    private static let pixelCacheMagic: Int64 = 0x4D5A_5445_5843_4831   // "MZTEXCH1"
    private static let pixelCacheVersion: Int64 = 1

    private static func pixelCacheURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".rgba-cache/\(url.lastPathComponent).rgba")
    }

    private static func sourceKey(_ url: URL) -> Int64? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = a[.size] as? Int64,
              let mtime = a[.modificationDate] as? Date else { return nil }
        return size &* 31 &+ Int64(mtime.timeIntervalSince1970)
    }

    private static func readPixelCache(_ url: URL) -> (pixels: [UInt8], w: Int, h: Int, cutout: Bool)? {
        guard let key = sourceKey(url),
              let data = try? Data(contentsOf: pixelCacheURL(url)), data.count > 48 else { return nil }
        let header = data.prefix(48).withUnsafeBytes { $0.bindMemory(to: Int64.self) }
        let (magic, version, w64, h64, cut, srcKey) = (header[0], header[1], header[2], header[3], header[4], header[5])
        let w = Int(w64), h = Int(h64)
        guard magic == pixelCacheMagic, version == pixelCacheVersion, srcKey == key,
              w > 0, h > 0, data.count == 48 + w * h * 4 else { return nil }
        return ([UInt8](data.dropFirst(48)), w, h, cut != 0)
    }

    private static func writePixelCache(_ url: URL, pixels: [UInt8], w: Int, h: Int, cutout: Bool) {
        guard let key = sourceKey(url) else { return }
        let dst = pixelCacheURL(url)
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        var header: [Int64] = [pixelCacheMagic, pixelCacheVersion, Int64(w), Int64(h), cutout ? 1 : 0, key]
        var data = Data(bytes: &header, count: 48)
        data.append(contentsOf: pixels)
        try? data.write(to: dst)
    }

    /// Decode any CGImageSource-readable file to straight RGBA8 bytes.
    /// The buffer starts TRANSPARENT (0), never opaque white: `draw` composites source-over, so a
    /// white-filled buffer silently replaced every transparent texel with opaque white — destroying
    /// the alpha channel outright (every foliage texture arrived minAlpha=255, the cutout could
    /// never fire, and the leaf PNGs' white background rendered as solid white between the leaves).
    private static func decodeRGBA(_ url: URL) -> (pixels: [UInt8], w: Int, h: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            NSLog("Asset texture not found/decodable: %@", url.path)
            return nil
        }
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * 4 * h)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : nil
    }

    private static func makeTexture(device: MTLDevice, srgb: Bool, pixels: [UInt8], w: Int, h: Int, label: String) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = label
        texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: w, height: h, depth: 1)),
                        mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
        return texture
    }

    /// Un-premultiply, then bleed colour outward into the transparent texels (see `loadAssetTexture`).
    /// Four passes is plenty: these textures are not mipmapped, so bilinear only ever reaches one
    /// texel past an edge. Alpha is left exactly as-is — only the hidden RGB changes, so the cutout
    /// silhouette is untouched.
    ///
    /// FRONTIER-based, through unsafe buffers: dilation only ever does work at the alpha boundary
    /// ring, so each pass walks just the current frontier (boundary texels) instead of re-scanning
    /// the whole image with 9-neighbour gathers. The naive full-image version cost ~44 s of a 48 s
    /// boot across the foliage textures in a Debug build (bounds-checked array indexing, -Onone);
    /// this is the same result at a tiny fraction of the texel visits.
    private static func unpremultiplyAndDilate(_ px: inout [UInt8], width w: Int, height h: Int) {
        let count = w * h
        var filled = [Bool](repeating: false, count: count)
        var queued = [Bool](repeating: false, count: count)
        px.withUnsafeMutableBufferPointer { pb in
            let p = pb.baseAddress!
            filled.withUnsafeMutableBufferPointer { fb in
                let f = fb.baseAddress!
                // One linear pass: un-premultiply partial-alpha texels, note which carry colour.
                for i in 0..<count {
                    let a = p[i * 4 + 3]
                    f[i] = a > 0
                    if a > 0 && a < 255 {
                        let inv = 255.0 / Double(a)
                        p[i * 4]     = UInt8(min(255.0, Double(p[i * 4]) * inv))
                        p[i * 4 + 1] = UInt8(min(255.0, Double(p[i * 4 + 1]) * inv))
                        p[i * 4 + 2] = UInt8(min(255.0, Double(p[i * 4 + 2]) * inv))
                    }
                }
                queued.withUnsafeMutableBufferPointer { qb in
                    let q = qb.baseAddress!
                    // Initial frontier: every transparent texel touching a filled one.
                    var frontier: [Int32] = []
                    for y in 0..<h {
                        for x in 0..<w {
                            let i = y * w + x
                            if f[i] { continue }
                            var touches = false
                            for ny in max(0, y - 1)...min(h - 1, y + 1) where !touches {
                                for nx in max(0, x - 1)...min(w - 1, x + 1) where f[ny * w + nx] {
                                    touches = true; break
                                }
                            }
                            if touches { frontier.append(Int32(i)) }
                        }
                    }
                    for _ in 0..<4 {
                        if frontier.isEmpty { break }
                        // Gather from OLD-filled only (commit after the pass), so each pass grows
                        // the colour skirt by exactly one texel — same result as the full scan.
                        var newly: [Int32] = []
                        for i32 in frontier {
                            let i = Int(i32)
                            let x = i % w, y = i / w
                            var r = 0, g = 0, b = 0, n = 0
                            for ny in max(0, y - 1)...min(h - 1, y + 1) {
                                for nx in max(0, x - 1)...min(w - 1, x + 1) {
                                    let j = ny * w + nx
                                    if f[j] { r += Int(p[j * 4]); g += Int(p[j * 4 + 1]); b += Int(p[j * 4 + 2]); n += 1 }
                                }
                            }
                            guard n > 0 else { continue }
                            p[i * 4] = UInt8(r / n); p[i * 4 + 1] = UInt8(g / n); p[i * 4 + 2] = UInt8(b / n)
                            newly.append(i32)   // colour only — alpha stays 0, still cut out
                        }
                        for i32 in newly { f[Int(i32)] = true }
                        // Next frontier: still-unfilled neighbours of the newly coloured texels.
                        var next: [Int32] = []
                        for i32 in newly {
                            let i = Int(i32)
                            let x = i % w, y = i / w
                            for ny in max(0, y - 1)...min(h - 1, y + 1) {
                                for nx in max(0, x - 1)...min(w - 1, x + 1) {
                                    let j = ny * w + nx
                                    if !f[j] && !q[j] { q[j] = true; next.append(Int32(j)) }
                                }
                            }
                        }
                        for i32 in next { q[Int(i32)] = false }   // reset the dedup marks for reuse
                        frontier = next
                    }
                }
            }
        }
    }

    // MARK: - M16.6 Builder glyphs (caustic symbols)

    /// The plinth vocabulary. Slice index = `Prop.state`, so the order is load-bearing:
    /// 1–4 are the ordinals the four M16.3 dials are labelled with, and they are the SAME morphemes
    /// the vase sentence uses for "2 planets / 3 ringed planets" — the tutorial is the dictionary
    /// entry (see Mazen Docs/Builder Glyphs — 4D Shadows.md).
    enum CausticSymbol: Int, CaseIterable {
        case blank = 0, one, two, three, four, swirl, portal, square

        /// Target points in a centred [-1,1] square — what the caustic concentrates light into.
        /// Deliberately blob-space: a mushy dot is still a dot, so these read at zero attunement.
        var targets: [SIMD2<Float>] {
            switch self {
            case .blank: return []
            case .one:   return [SIMD2(0, 0)]
            case .two:   return [SIMD2(-0.34, 0), SIMD2(0.34, 0)]
            case .three: return [SIMD2(0, 0.38), SIMD2(-0.34, -0.22), SIMD2(0.34, -0.22)]
            case .four:  return [SIMD2(-0.32, 0.32), SIMD2(0.32, 0.32), SIMD2(-0.32, -0.32), SIMD2(0.32, -0.32)]
            case .swirl:
                // The verb: "turn / combine to produce". Drawn as the operation it names — an
                // Archimedean spiral, sampled evenly so the blobs read as one sweeping stroke.
                return (0..<44).map { i in
                    let t = Float(i) / 43.0
                    let a = t * .pi * 3.4, r = 0.10 + t * 0.74
                    return SIMD2(cos(a) * r, sin(a) * r)
                }
            case .portal:
                // The police-box portal — a thing the player has SEEN, so it teaches diegetically
                // ("the world is the Rosetta stone"). Silhouette only: posts, roof, lamp, and two
                // window bands; at plinth size the interior detail would collide into mush anyway.
                var p: [SIMD2<Float>] = []
                let x0: Float = -0.42, x1: Float = 0.42, yb: Float = -0.86, yt: Float = 0.62
                for i in 0...13 {                                   // the two uprights
                    let y = yb + (yt - yb) * Float(i) / 13.0
                    p.append(SIMD2(x0, y)); p.append(SIMD2(x1, y))
                }
                for i in 0...6 {                                    // base and lintel
                    let x = x0 + (x1 - x0) * Float(i) / 6.0
                    p.append(SIMD2(x, yb)); p.append(SIMD2(x, yt))
                }
                for i in 1...5 {                                    // the roof taper
                    let t = Float(i) / 5.0
                    let x = (x0 + 0.06) * (1 - t) + 0 * t
                    p.append(SIMD2(x, yt + 0.10 * t)); p.append(SIMD2(-x, yt + 0.10 * t))
                }
                p.append(SIMD2(0, yt + 0.20))                       // the lamp on top
                for i in 0...4 {                                    // the window band
                    let x = x0 + (x1 - x0) * Float(i) / 4.0
                    p.append(SIMD2(x, 0.30))
                }
                return p
            case .square:
                // The object: "world" — a cube's shadow is a square (square:cube :: cube:tesseract),
                // and the player literally stands on a cube whose faces are squares. Drawn as an
                // outline so it reads as a bounded face, not a filled blob. This is the glyph the
                // alignment cylinder assembles from two halves ("TURN THE WORLD").
                var p: [SIMD2<Float>] = []
                let s: Float = 0.62, n = 8
                for i in 0..<n {
                    let t = -s + 2 * s * Float(i) / Float(n - 1)
                    p.append(SIMD2(t, s)); p.append(SIMD2(t, -s))   // top + bottom edges
                    p.append(SIMD2(s, t)); p.append(SIMD2(-s, t))   // right + left edges
                }
                return p
            }
        }
    }

    /// Build the caustic symbol array — one slice per `CausticSymbol`, `Prop.state` selects it.
    ///
    /// This is the forge's poor-man's transport MINUS the inverse solve: the tutorial symbols are
    /// simple enough that splatting soft blobs at the target points IS the caustic (that's what the
    /// HTML tool's Morton-sorted cells produce anyway). `sharpness` is the blob radius and therefore
    /// the comprehension-gradient dial for free — small = crisp, large = the alien mush. Stored as
    /// single-channel intensity; the shader tints it.
    static func makeCausticArray(device: MTLDevice, size: Int = 128, sharpness: Float = 0.5) -> MTLTexture? {
        let syms = CausticSymbol.allCases
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .r8Unorm            // intensity only — light, not colour
        desc.width = size; desc.height = size
        desc.arrayLength = syms.count
        desc.storageMode = .shared; desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = "CausticSymbols"

        // Blob radius in texels: the gradient dial. Interpolated so 0 = mush, 1 = tight.
        let radius = Float(size) * (0.16 - 0.10 * max(0, min(1, sharpness)))
        let inv = 1.0 / max(radius, 1)
        let reach = Int(radius * 2.2)
        for (slice, sym) in syms.enumerated() {
            var px = [UInt8](repeating: 0, count: size * size)
            var acc = [Float](repeating: 0, count: size * size)
            for t in sym.targets {
                // [-1,1] → texel space (y flipped: texture v runs down).
                let cx = (t.x * 0.5 + 0.5) * Float(size - 1)
                let cy = (1 - (t.y * 0.5 + 0.5)) * Float(size - 1)
                let x0 = max(0, Int(cx) - reach), x1 = min(size - 1, Int(cx) + reach)
                let y0 = max(0, Int(cy) - reach), y1 = min(size - 1, Int(cy) + reach)
                guard x0 <= x1, y0 <= y1 else { continue }
                for y in y0...y1 {
                    for x in x0...x1 {
                        let dx = (Float(x) - cx) * inv, dy = (Float(y) - cy) * inv
                        let d2 = dx * dx + dy * dy
                        guard d2 < 4.84 else { continue }
                        // Gaussian-ish falloff; blobs ADD, so overlaps brighten — the piled-up
                        // look real caustics have where rays converge.
                        acc[y * size + x] += exp(-d2 * 1.9)
                    }
                }
            }
            for i in 0..<acc.count { px[i] = UInt8(max(0, min(255, acc[i] * 235))) }
            texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                              size: MTLSize(width: size, height: size, depth: 1)),
                            mipmapLevel: 0, slice: slice, withBytes: px,
                            bytesPerRow: size, bytesPerImage: size * size)
        }
        return texture
    }

    /// M20 — an alpha-cutout leaf **array**: one slice per ambientCG-style Color+Opacity pair
    /// (RGB from Color, alpha from the grayscale Opacity), so bushes can vary by sampling different
    /// slices. Downsampled to `size`² (512 default — cards are small on screen, keeps memory sane).
    /// RGBA sRGB; alpha stays linear for the discard threshold; not premultiplied (alpha-test, no
    /// blend). A slice whose files are missing stays white (fallback), never a crash.
    static func loadCutoutArray(device: MTLDevice, sets: [(color: URL, opacity: URL)], size: Int = 512) -> MTLTexture? {
        guard !sets.isEmpty else { return nil }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba8Unorm_srgb
        desc.width = size; desc.height = size
        desc.arrayLength = sets.count
        desc.storageMode = .shared; desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = "LeafArray"

        let bpr = size * 4, bpi = bpr * size
        let rgb = CGColorSpaceCreateDeviceRGB()
        func draw(_ url: URL) -> [UInt8]? {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            var px = [UInt8](repeating: 255, count: bpi)
            guard let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: bpr, space: rgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))   // scales to `size`
            return px
        }

        var loaded = 0
        for (i, set) in sets.enumerated() {
            guard var pixels = draw(set.color) else {
                NSLog("Leaf colour missing: %@", set.color.path); continue
            }
            if let op = draw(set.opacity) {
                for p in 0..<(size * size) { pixels[p * 4 + 3] = op[p * 4] }
            } else {
                NSLog("Leaf opacity missing (%@) — slice %d fully opaque", set.opacity.path, i)
            }
            texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: size, height: size, depth: 1)),
                            mipmapLevel: 0, slice: i, withBytes: pixels, bytesPerRow: bpr, bytesPerImage: bpi)
            loaded += 1
        }
        return loaded > 0 ? texture : nil
    }

    /// M20 — an array of already-alpha PNGs (misc_greenery, WenrexaTrees) into `size²` slices. Each
    /// source is fitted **preserving aspect** and centred (transparent padding), so portrait
    /// sprites aren't squished; the transparent margin is discarded by the cutout material. A
    /// missing file leaves its slice transparent, never a crash.
    static func loadRGBAArray(device: MTLDevice, urls: [URL], size: Int = 512, centerOnTrunk: Bool = false) -> MTLTexture? {
        guard !urls.isEmpty else { return nil }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba8Unorm_srgb
        desc.width = size; desc.height = size
        desc.arrayLength = urls.count
        desc.storageMode = .shared; desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = "FoliageArray"
        let bpr = size * 4, bpi = bpr * size
        let rgb = CGColorSpaceCreateDeviceRGB()

        /// The horizontal centre (native px) of the trunk: scan UP from the image bottom to the
        /// first opaque rows (the trunk base) and centre on those, so intersecting tree cards share
        /// the trunk axis rather than the canopy centre. NOTE: in this CGBitmapContext the buffer's
        /// row 0 is the image TOP, so the image bottom is the LAST rows — scan those.
        func trunkX(_ img: CGImage) -> CGFloat {
            let nw = img.width, nh = img.height, nbpr = nw * 4
            var npx = [UInt8](repeating: 0, count: nbpr * nh)
            guard let nctx = CGContext(data: &npx, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: nbpr,
                                       space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return CGFloat(nw) / 2 }
            nctx.draw(img, in: CGRect(x: 0, y: 0, width: nw, height: nh))
            var minx = nw, maxx = -1, contentRows = 0
            var row = nh - 1                              // image bottom
            while row >= 0 {
                var rmin = nw, rmax = -1
                for x in 0..<nw where npx[(row * nw + x) * 4 + 3] > 40 {
                    if x < rmin { rmin = x }; if x > rmax { rmax = x }
                }
                if rmax >= rmin {                         // this row has trunk-base content
                    minx = min(minx, rmin); maxx = max(maxx, rmax)
                    contentRows += 1
                    if contentRows >= max(3, nh / 24) { break }   // enough base rows to centre the trunk
                }
                row -= 1
            }
            return maxx >= minx ? CGFloat(minx + maxx) / 2 : CGFloat(nw) / 2
        }

        var loaded = 0
        for (i, url) in urls.enumerated() {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                NSLog("Foliage png missing: %@", url.path); continue
            }
            var px = [UInt8](repeating: 0, count: bpi)   // transparent padding
            guard let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: bpr, space: rgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            let w = CGFloat(img.width), h = CGFloat(img.height)
            let scale = min(CGFloat(size) / w, CGFloat(size) / h)
            let fw = w * scale, fh = h * scale
            // BOTTOM-align (CG y=0 = card base) so it sits on the ground regardless of source aspect.
            // Horizontally: centre the TRUNK (its detected base) on the slice centre when
            // centerOnTrunk (so intersecting tree cards share the trunk axis); else centre the image.
            let xoff = centerOnTrunk ? (CGFloat(size) / 2 - trunkX(img) * scale) : (CGFloat(size) - fw) / 2
            ctx.draw(img, in: CGRect(x: xoff, y: 0, width: fw, height: fh))
            texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: size, height: size, depth: 1)),
                            mipmapLevel: 0, slice: i, withBytes: px, bytesPerRow: bpr, bytesPerImage: bpi)
            loaded += 1
        }
        return loaded > 0 ? texture : nil
    }
}
