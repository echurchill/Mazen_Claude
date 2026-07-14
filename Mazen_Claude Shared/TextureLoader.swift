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
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * h)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: w, height: h, depth: 1)),
                        mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
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
}
