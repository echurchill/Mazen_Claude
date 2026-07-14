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

    /// M20 — compose an alpha-cutout leaf texture from an ambientCG-style pair: RGB from the Color
    /// map, alpha from the separate grayscale Opacity map. (RGBA sRGB; alpha stays linear for the
    /// discard threshold. Not premultiplied — alpha-test doesn't blend, so it uses RGB as-is.)
    static func loadCutoutTexture(device: MTLDevice, colorURL: URL, opacityURL: URL) -> MTLTexture? {
        guard let cSrc = CGImageSourceCreateWithURL(colorURL as CFURL, nil),
              let color = CGImageSourceCreateImageAtIndex(cSrc, 0, nil) else {
            NSLog("Leaf colour not found/decodable: %@", colorURL.path); return nil
        }
        let w = color.width, h = color.height
        let bpr = w * 4
        var pixels = [UInt8](repeating: 255, count: bpr * h)
        let rgb = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: rgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(color, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Opacity → alpha (its red channel; the map is grayscale so any channel works).
        if let oSrc = CGImageSourceCreateWithURL(opacityURL as CFURL, nil),
           let opacity = CGImageSourceCreateImageAtIndex(oSrc, 0, nil),
           opacity.width == w, opacity.height == h {
            var op = [UInt8](repeating: 255, count: bpr * h)
            if let octx = CGContext(data: &op, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                    space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                octx.draw(opacity, in: CGRect(x: 0, y: 0, width: w, height: h))
                for i in 0..<(w * h) { pixels[i * 4 + 3] = op[i * 4] }
            }
        } else {
            NSLog("Leaf opacity missing/size-mismatched (%@) — leaf will render fully opaque", opacityURL.path)
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.label = colorURL.deletingLastPathComponent().lastPathComponent
        texture.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: w, height: h, depth: 1)),
                        mipmapLevel: 0, withBytes: pixels, bytesPerRow: bpr)
        return texture
    }
}
