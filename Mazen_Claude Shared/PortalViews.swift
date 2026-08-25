import Foundation
import Metal
import ImageIO
import CoreGraphics
import simd

#if os(macOS)
import AppKit
#endif

/// WHAT YOU SEE THROUGH A DOOR — captured, not rendered.
///
/// A portal used to show a procedural vortex. It can now show **the actual view you will have when
/// you step out the other side**, taken from the game itself at the arrival point and played back
/// in the arch with a parallax shift, so it reads as a window rather than a poster.
///
/// Rendering the destination live was the obvious idea and the wrong one: a second world already
/// costs a full `SceneBuilder.build` when it merely hangs in the sky (see
/// `Mazen Docs/Sky Worlds — Dressing the Counterpart.md`), and a door shows a view from a *different
/// place and angle* than the sky world does, so nothing would be shared. A captured image is free at
/// runtime and can be art-directed.
///
/// **The images are a moment, and that is the point.** What a door shows is the destination *as it
/// was when the capture was taken* — so a world you have since twisted will not match. In a game
/// whose whole sixth scene is "worlds remember what was done to them", a door that shows you the
/// place as you last knew it is the right kind of wrong. (Eddie's call, 2026-08-06.)
enum PortalViews {

    /// Square, because a texture array demands one size for every slice, and because the aperture
    /// is roughly as tall as it is wide. Sources of any shape are centre-cropped to fit.
    static let edge = 1024

    /// Filename → slice, filled at load. Names are route keys: `<destination>--from--<origin>`,
    /// with a bare `<destination>` as the fallback for "however you got here".
    private(set) static var slices: [String: Int] = [:]

    static func routeKey(destination: String, origin: String?) -> String {
        guard let origin else { return destination }
        return "\(destination)--from--\(origin)"
    }

    /// The slice for a door leading to `destination` from the world the player is standing in.
    /// Route-keyed first, then the plain destination, then nil — and nil means the portal keeps its
    /// old procedural look, so a missing capture degrades to what shipped before rather than a hole.
    static func slice(destination: String, origin: String?) -> Int? {
        slices[routeKey(destination: destination, origin: origin)] ?? slices[destination]
    }

    /// Read from here (bundle when there is one).
    static var directory: URL { URL(fileURLWithPath: ResourcePaths.portalViews) }
    /// …but WRITE here, always the repo. See `ResourcePaths.portalViewsWritable`.
    static var writeDirectory: URL { URL(fileURLWithPath: ResourcePaths.portalViewsWritable) }

    // MARK: - Load

    /// Load every PNG in `PortalViews/` into one array texture. Sorted by name so slice indices are
    /// stable between runs — a portal stores no index, it looks its own up by name, but a stable
    /// order keeps bench output and logs comparable.
    static func loadArray(device: MTLDevice) -> MTLTexture? {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".png") }.sorted()
        guard !files.isEmpty else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
                                                            width: edge, height: edge, mipmapped: false)
        desc.textureType = .type2DArray
        desc.arrayLength = files.count
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.label = "PortalViews"   // so the residency guard can name it if it is ever unregistered

        var map: [String: Int] = [:]
        for (i, f) in files.enumerated() {
            let name = String(f.dropLast(4))
            guard let px = squarePixels(at: directory.appendingPathComponent(f)) else {
                NSLog("[PortalViews] could not read %@", f); continue
            }
            px.withUnsafeBufferPointer { buf in
                tex.replace(region: MTLRegionMake2D(0, 0, edge, edge), mipmapLevel: 0, slice: i,
                            withBytes: buf.baseAddress!, bytesPerRow: edge * 4, bytesPerImage: edge * edge * 4)
            }
            map[name] = i
        }
        slices = map
        NSLog("[PortalViews] %d view(s): %@", map.count, map.keys.sorted().joined(separator: ", "))
        return tex
    }

    /// Decode any image and centre-crop it to `edge`×`edge` RGBA8. Centre-crop rather than squash:
    /// a squashed capture reads as a funhouse mirror the moment there is a straight wall in it.
    private static func squarePixels(at url: URL) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: edge * edge * 4)
        guard let ctx = CGContext(data: &pixels, width: edge, height: edge, bitsPerComponent: 8,
                                  bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let side = min(w, h)
        let scale = CGFloat(edge) / side
        // Draw the source scaled so its SHORT side fills the square, centred — the long side spills
        // off both ends equally.
        ctx.draw(img, in: CGRect(x: (CGFloat(edge) - w * scale) / 2, y: (CGFloat(edge) - h * scale) / 2,
                                 width: w * scale, height: h * scale))
        return pixels
    }

    // MARK: - Write

    /// Write one capture, centre-cropped square, as a PNG named for its route.
    ///
    /// macOS ONLY, and deliberately so: the write target is the SOURCE TREE (see
    /// `ResourcePaths.portalViewsWritable`), which does not exist on a device — an iPad would spend
    /// the work and then log a failure it can do nothing about. Capturing is an authoring act
    /// performed where the repo is.
    @discardableResult
    static func write(bgraPixels: [UInt8], width: Int, height: Int, name: String) -> URL? {
#if !os(macOS)
        NSLog("[PortalViews] capture ignored: there is no repo to write to on this platform")
        return nil
#else
        // The frame arrives as BGRA (the drawable's format); swizzle to RGBA for CoreGraphics.
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            rgba[i]     = bgraPixels[i + 2]
            rgba[i + 1] = bgraPixels[i + 1]
            rgba[i + 2] = bgraPixels[i]
            rgba[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let full = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true,
                                 intent: .defaultIntent) else { return nil }

        var square = [UInt8](repeating: 0, count: edge * edge * 4)
        guard let ctx = CGContext(data: &square, width: edge, height: edge, bitsPerComponent: 8,
                                  bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height), scale = CGFloat(edge) / min(w, h)
        ctx.draw(full, in: CGRect(x: (CGFloat(edge) - w * scale) / 2, y: (CGFloat(edge) - h * scale) / 2,
                                  width: w * scale, height: h * scale))
        guard let out = ctx.makeImage() else { return nil }

        try? FileManager.default.createDirectory(at: writeDirectory, withIntermediateDirectories: true)
        let url = writeDirectory.appendingPathComponent("\(name).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else {
            NSLog("[PortalViews] WRITE FAILED: %@ (sandboxed build? captures need the Debug config)", url.path)
            return nil
        }
        NSLog("[PortalViews] captured %@", url.path)
        return url
#endif
    }
}
