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
    ///
    /// `cutout` is for alpha-tested foliage. It does two things a plain load must not:
    ///  1. UN-PREMULTIPLIES. CoreGraphics only offers premultiplied 8-bit RGBA, but the shader
    ///     reads `.rgb` as a straight colour, so premultiplied texels would darken toward the edges.
    ///  2. DILATES the colour outward under the transparent texels. Quaternius' leaf PNGs store pure
    ///     WHITE beneath alpha 0; the bilinear filter blends across the alpha boundary, so any edge
    ///     texel that survives the cutout would drag that white in as a fringe. Bleeding the leaf
    ///     colour outward means the filter only ever mixes leaf with leaf.
    static func loadTextureFromFile(url: URL, device: MTLDevice, srgb: Bool, cutout: Bool = false) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            NSLog("Asset texture not found/decodable: %@", url.path)
            return nil
        }
        let w = cgImage.width, h = cgImage.height
        let bytesPerRow = w * 4
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = url.lastPathComponent
        // Start TRANSPARENT, not opaque white. `draw` composites source-over, so a white-filled
        // buffer silently replaced every transparent texel with opaque white — destroying the alpha
        // channel outright (every foliage texture arrived minAlpha=255, so the cutout could never
        // fire and the leaf PNG's white background rendered as solid white between the leaves).
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        if cutout { unpremultiplyAndDilate(&pixels, width: w, height: h) }
        texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: w, height: h, depth: 1)),
                        mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        return texture
    }

    /// Un-premultiply, then bleed colour outward into the transparent texels (see `loadTextureFromFile`).
    /// Four passes is plenty: these textures are not mipmapped, so bilinear only ever reaches one
    /// texel past an edge. Alpha is left exactly as-is — only the hidden RGB changes, so the cutout
    /// silhouette is untouched.
    private static func unpremultiplyAndDilate(_ px: inout [UInt8], width w: Int, height h: Int) {
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = px[i + 3]
            guard a > 0, a < 255 else { continue }
            let inv = 255.0 / Double(a)
            px[i]     = UInt8(min(255, Double(px[i]) * inv))
            px[i + 1] = UInt8(min(255, Double(px[i + 1]) * inv))
            px[i + 2] = UInt8(min(255, Double(px[i + 2]) * inv))
        }
        // `filled` tracks which texels carry a real colour; transparent ones get one from a
        // neighbour, spreading outward a texel per pass.
        var filled = [Bool](repeating: false, count: w * h)
        for p in 0..<(w * h) { filled[p] = px[p * 4 + 3] > 0 }
        for _ in 0..<4 {
            var next = filled
            for y in 0..<h {
                for x in 0..<w {
                    let p = y * w + x
                    if filled[p] { continue }
                    var r = 0, g = 0, b = 0, n = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                            let q = ny * w + nx
                            guard filled[q] else { continue }
                            r += Int(px[q * 4]); g += Int(px[q * 4 + 1]); b += Int(px[q * 4 + 2]); n += 1
                        }
                    }
                    guard n > 0 else { continue }
                    px[p * 4] = UInt8(r / n); px[p * 4 + 1] = UInt8(g / n); px[p * 4 + 2] = UInt8(b / n)
                    next[p] = true          // colour only — alpha stays 0, so it is still cut out
                }
            }
            filled = next
        }
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
